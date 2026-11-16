import Foundation

enum NativeMediaUploadError: Error {
    case http(stage: String, status: Int)
}

struct NativeSessionMediaAPIClient {
    var baseURL: URL? = NativeConfig.apiBaseURL
    var tokenProvider: (String?) async throws -> String = {
        try await NativeSupabaseAuthClient.accessToken(refreshing: $0)
    }
    var send: (URLRequest) async throws -> (Data, URLResponse) = {
        try await URLSession.shared.data(for: $0)
    }

    func start(mediaSessionID: String, exerciseID: String) async throws {
        _ = try await request(
            path: "/api/session-media/start",
            body: ["id": mediaSessionID, "exerciseId": exerciseID]
        )
    }

    func request(path: String, body: [String: Any]) async throws -> Data {
        guard let baseURL,
              let url = URL(string: path, relativeTo: baseURL) else {
            throw NativeAPIError.notConfigured
        }
        let token = try await tokenProvider(nil)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        var (data, response) = try await send(request)
        if (response as? HTTPURLResponse)?.statusCode == 401 {
            let renewedToken = try await tokenProvider(token)
            request.setValue("Bearer \(renewedToken)", forHTTPHeaderField: "Authorization")
            (data, response) = try await send(request)
        }
        guard let http = response as? HTTPURLResponse else { throw NativeAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw NativeMediaUploadError.http(stage: path, status: http.statusCode)
        }
        return data
    }
}

/// Durable foreground queue. MP4 files and metadata survive an app restart;
/// Every API call gets a valid session from the shared Supabase SDK.
final class NativeSessionMediaUploader: @unchecked Sendable {
    static let shared = NativeSessionMediaUploader()

    private struct PendingAsset: Codable, Identifiable {
        let id: UUID
        let mediaSessionID: String
        let index: Int
        var fileURL: URL
        let byteCount: Int64
        let durationMilliseconds: Int
        let startOffsetMilliseconds: Int
        var attempts: Int
        var nextAttemptAt: Date? = nil
        var lastError: String? = nil
    }

    private struct PendingCompletion: Codable, Identifiable {
        let id: UUID
        let mediaSessionID: String
        let videoSegments: Int
        var attempts: Int
        var nextAttemptAt: Date? = nil
        var lastError: String? = nil
    }

    private struct DurableQueue: Codable {
        var assets: [PendingAsset] = []
        var completions: [PendingCompletion] = []
    }

    private struct PreparedUpload: Decodable { let uploadUrl: URL }
    private struct DriveFile: Decodable { let id: String }

    private let queue = DispatchQueue(label: "com.physioai.session-upload", qos: .utility)
    private let urlSession: URLSession
    private let rootURL: URL
    private let queueURL: URL
    private let api = NativeSessionMediaAPIClient()
    private var durableQueue = DurableQueue()
    private var processing = false
    private var retryWork: DispatchWorkItem?

    private init(fileManager: FileManager = .default) {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 60 * 60
        urlSession = URLSession(configuration: configuration)
        let support = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        rootURL = support.appendingPathComponent("PhysioAISessions", isDirectory: true)
        queueURL = rootURL.appendingPathComponent("upload-queue.json")
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: queueURL),
           let saved = try? JSONDecoder().decode(DurableQueue.self, from: data) {
            durableQueue = saved
            rebaseURLs(fileManager)
        }
        queue.async { [weak self] in self?.processNext() }
    }

    func enqueue(_ capture: NativeSessionVideoCapture) {
        queue.async { [weak self] in
            guard let self else { return }
            for segment in capture.segments {
                durableQueue.assets.append(PendingAsset(
                    id: UUID(),
                    mediaSessionID: capture.mediaSessionID,
                    index: segment.index,
                    fileURL: segment.fileURL,
                    byteCount: segment.byteCount,
                    durationMilliseconds: segment.durationMilliseconds,
                    startOffsetMilliseconds: segment.startOffsetMilliseconds,
                    attempts: 0
                ))
            }
            durableQueue.completions.append(PendingCompletion(
                id: UUID(),
                mediaSessionID: capture.mediaSessionID,
                videoSegments: capture.segments.count,
                attempts: 0
            ))
            persist()
            processNext()
        }
    }

    func resume() {
        queue.async { [weak self] in self?.processNext() }
    }

    private func processNext() {
        guard !processing else { return }
        let now = Date()
        if let index = durableQueue.assets.firstIndex(where: { ($0.nextAttemptAt ?? .distantPast) <= now }) {
            processing = true
            durableQueue.assets[index].attempts += 1
            let asset = durableQueue.assets[index]
            persist()
            Task { [weak self] in
                do { try await self?.upload(asset); self?.finish(asset, error: nil) }
                catch { self?.finish(asset, error: error) }
            }
            return
        }
        if let index = durableQueue.completions.firstIndex(where: { completion in
            (completion.nextAttemptAt ?? .distantPast) <= now &&
            !durableQueue.assets.contains(where: { $0.mediaSessionID == completion.mediaSessionID })
        }) {
            processing = true
            durableQueue.completions[index].attempts += 1
            let completion = durableQueue.completions[index]
            persist()
            Task { [weak self] in
                do { try await self?.complete(completion); self?.finish(completion, error: nil) }
                catch { self?.finish(completion, error: error) }
            }
            return
        }
        scheduleNextRetry()
    }

    private func upload(_ asset: PendingAsset) async throws {
        guard FileManager.default.fileExists(atPath: asset.fileURL.path) else { throw URLError(.fileDoesNotExist) }
        let preparedData = try await api.request(path: "/api/session-media/uploads", body: [
            "mediaSessionId": asset.mediaSessionID,
            "index": asset.index,
            "size": asset.byteCount,
            "mimeType": "video/mp4",
        ])
        let prepared = try JSONDecoder().decode(PreparedUpload.self, from: preparedData)
        var uploadRequest = URLRequest(url: prepared.uploadUrl)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue(String(asset.byteCount), forHTTPHeaderField: "Content-Length")
        uploadRequest.setValue("bytes 0-\(asset.byteCount - 1)/\(asset.byteCount)", forHTTPHeaderField: "Content-Range")
        let (driveData, driveResponse) = try await urlSession.upload(for: uploadRequest, fromFile: asset.fileURL)
        try requireSuccess(driveResponse, data: driveData)
        let driveFile = try JSONDecoder().decode(DriveFile.self, from: driveData)
        _ = try await api.request(path: "/api/session-media/segments/complete", body: [
            "mediaSessionId": asset.mediaSessionID,
            "index": asset.index,
            "fileId": driveFile.id,
            "durationMs": asset.durationMilliseconds,
            "startOffsetMs": asset.startOffsetMilliseconds,
        ])
    }

    private func complete(_ completion: PendingCompletion) async throws {
        _ = try await api.request(path: "/api/session-media/complete", body: [
            "mediaSessionId": completion.mediaSessionID,
            "videoSegments": completion.videoSegments,
        ])
    }

    private func finish(_ asset: PendingAsset, error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            processing = false
            if error == nil {
                durableQueue.assets.removeAll { $0.id == asset.id }
                try? FileManager.default.removeItem(at: asset.fileURL)
                persist()
                processNext()
            } else {
                if let index = durableQueue.assets.firstIndex(where: { $0.id == asset.id }) {
                    durableQueue.assets[index].nextAttemptAt = Date().addingTimeInterval(60)
                    durableQueue.assets[index].lastError = diagnostic(error!)
                }
                persist()
                processNext()
            }
        }
    }

    private func finish(_ completion: PendingCompletion, error: Error?) {
        queue.async { [weak self] in
            guard let self else { return }
            processing = false
            if error == nil {
                durableQueue.completions.removeAll { $0.id == completion.id }
                persist()
                processNext()
            } else {
                if let index = durableQueue.completions.firstIndex(where: { $0.id == completion.id }) {
                    durableQueue.completions[index].nextAttemptAt = Date().addingTimeInterval(60)
                    durableQueue.completions[index].lastError = diagnostic(error!)
                }
                persist()
                processNext()
            }
        }
    }

    private func scheduleNextRetry() {
        retryWork?.cancel()
        let dates = durableQueue.assets.compactMap(\.nextAttemptAt) + durableQueue.completions.filter { completion in
            !durableQueue.assets.contains { $0.mediaSessionID == completion.mediaSessionID }
        }.compactMap(\.nextAttemptAt)
        guard let next = dates.min() else { return }
        let work = DispatchWorkItem { [weak self] in self?.processNext() }
        retryWork = work
        queue.asyncAfter(deadline: .now() + max(1, next.timeIntervalSinceNow), execute: work)
    }

    // Persist only controlled diagnostics, never response bodies, tokens or signed URLs.
    private func diagnostic(_ error: Error) -> String {
        if case let NativeMediaUploadError.http(stage, status) = error {
            return "\(stage): HTTP \(status)"
        }
        if let error = error as? URLError { return "network_or_file: \(error.code.rawValue)" }
        return "authentication_or_upload_failed"
    }

    private func requireSuccess(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NativeMediaUploadError.http(stage: "drive_upload", status: (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func rebaseURLs(_ fileManager: FileManager) {
        for index in durableQueue.assets.indices where !fileManager.fileExists(atPath: durableQueue.assets[index].fileURL.path) {
            let item = durableQueue.assets[index]
            durableQueue.assets[index].fileURL = rootURL
                .appendingPathComponent(item.mediaSessionID, isDirectory: true)
                .appendingPathComponent(item.fileURL.lastPathComponent)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(durableQueue) else { return }
        try? data.write(to: queueURL, options: .atomic)
    }
}
