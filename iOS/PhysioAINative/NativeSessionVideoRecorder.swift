import AVFoundation
import CoreMedia
import Foundation

struct NativeSessionVideoSegment: Equatable, Sendable {
    let index: Int
    let fileURL: URL
    let byteCount: Int64
    let durationMilliseconds: Int
    let startOffsetMilliseconds: Int
}

struct NativeSessionVideoCapture: Equatable, Sendable {
    let mediaSessionID: String
    let segments: [NativeSessionVideoSegment]
}

enum NativeSessionVideoRecorderError: LocalizedError {
    case alreadyRecording
    case invalidSessionID
    case writerUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording: return "A session recording is already active."
        case .invalidSessionID: return "The media session ID is invalid."
        case .writerUnavailable: return "The video writer could not be created."
        }
    }
}

/// Passive H.264 recorder for the same sample buffers already delivered to
/// the exercise pipeline. All disk encoding runs on a utility queue and never
/// participates in pose, handedness, detector, or repetition decisions.
final class NativeSessionVideoRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.physioai.session-video", qos: .utility)
    private let writerGroup = DispatchGroup()
    private let fileManager: FileManager

    private var mediaSessionID: String?
    private var directoryURL: URL?
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var segmentIndex = 0
    private var segmentStartPTS: CMTime?
    private var recordingStartPTS: CMTime?
    private var lastPTS: CMTime?
    private var completedSegments: [NativeSessionVideoSegment] = []
    private var isRecording = false
    private var segmentDurationSeconds = 60.0

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func start(mediaSessionID: String, segmentDurationSeconds: Double = 60) throws {
        try queue.sync {
            guard !isRecording else { throw NativeSessionVideoRecorderError.alreadyRecording }
            let safeID = mediaSessionID
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
            guard !safeID.isEmpty else { throw NativeSessionVideoRecorderError.invalidSessionID }
            let support = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let root = support.appendingPathComponent("PhysioAISessions", isDirectory: true)
            let directory = root.appendingPathComponent(safeID, isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

            self.mediaSessionID = mediaSessionID
            directoryURL = directory
            self.segmentDurationSeconds = max(10, segmentDurationSeconds)
            writer = nil
            writerInput = nil
            segmentIndex = 0
            segmentStartPTS = nil
            recordingStartPTS = nil
            lastPTS = nil
            completedSegments = []
            isRecording = true
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [weak self] in self?.appendOnQueue(sampleBuffer) }
    }

    func finish(completion: @escaping @MainActor @Sendable (Result<NativeSessionVideoCapture?, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            guard isRecording, let mediaSessionID else {
                Task { @MainActor in completion(.success(nil)) }
                return
            }
            isRecording = false
            finishCurrentSegment()
            writerGroup.notify(queue: queue) { [weak self] in
                guard let self else { return }
                let capture = NativeSessionVideoCapture(
                    mediaSessionID: mediaSessionID,
                    segments: completedSegments.sorted { $0.index < $1.index }
                )
                reset()
                Task { @MainActor in completion(.success(capture)) }
            }
        }
    }

    func cancelAndDelete() {
        queue.async { [weak self] in
            guard let self else { return }
            isRecording = false
            writerInput?.markAsFinished()
            writer?.cancelWriting()
            let directory = directoryURL
            reset()
            if let directory { try? fileManager.removeItem(at: directory) }
        }
    }

    private func appendOnQueue(_ sampleBuffer: CMSampleBuffer) {
        guard isRecording, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let start = segmentStartPTS,
           CMTimeGetSeconds(CMTimeSubtract(pts, start)) >= segmentDurationSeconds {
            finishCurrentSegment()
        }
        do {
            if writer == nil { try beginSegment(sampleBuffer, pts: pts) }
            guard let writer, let writerInput, writer.status == .writing else { return }
            if writerInput.isReadyForMoreMediaData, writerInput.append(sampleBuffer) { lastPTS = pts }
        } catch {
#if DEBUG
            print("[PhysioAI Media] Recorder error: \(error.localizedDescription)")
#endif
        }
    }

    private func beginSegment(_ sampleBuffer: CMSampleBuffer, pts: CMTime) throws {
        guard let directoryURL,
              let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw NativeSessionVideoRecorderError.writerUnavailable
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let url = directoryURL.appendingPathComponent(String(format: "video-%04d.mp4", segmentIndex))
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        let nextWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 2_500_000,
                    AVVideoExpectedSourceFrameRateKey: 15,
                    AVVideoMaxKeyFrameIntervalKey: 30,
                ],
            ],
            sourceFormatHint: format
        )
        input.expectsMediaDataInRealTime = true
        guard nextWriter.canAdd(input) else { throw NativeSessionVideoRecorderError.writerUnavailable }
        nextWriter.add(input)
        guard nextWriter.startWriting() else { throw nextWriter.error ?? NativeSessionVideoRecorderError.writerUnavailable }
        nextWriter.startSession(atSourceTime: pts)
        writer = nextWriter
        writerInput = input
        segmentStartPTS = pts
        recordingStartPTS = recordingStartPTS ?? pts
        lastPTS = pts
    }

    private func finishCurrentSegment() {
        guard let writer, let writerInput, let startPTS = segmentStartPTS else { return }
        let index = segmentIndex
        let url = writer.outputURL
        let endPTS = lastPTS ?? startPTS
        let duration = max(0, Int(CMTimeGetSeconds(CMTimeSubtract(endPTS, startPTS)) * 1_000))
        let offset = max(0, Int(CMTimeGetSeconds(CMTimeSubtract(startPTS, recordingStartPTS ?? startPTS)) * 1_000))
        self.writer = nil
        self.writerInput = nil
        segmentStartPTS = nil
        lastPTS = nil
        segmentIndex += 1
        writerInput.markAsFinished()
        writerGroup.enter()
        writer.finishWriting { [weak self] in
            guard let self else { return }
            queue.async {
                defer { self.writerGroup.leave() }
                guard writer.status == .completed,
                      let attributes = try? self.fileManager.attributesOfItem(atPath: url.path),
                      let bytes = attributes[.size] as? NSNumber,
                      bytes.int64Value > 0 else { return }
                self.completedSegments.append(NativeSessionVideoSegment(
                    index: index,
                    fileURL: url,
                    byteCount: bytes.int64Value,
                    durationMilliseconds: duration,
                    startOffsetMilliseconds: offset
                ))
            }
        }
    }

    private func reset() {
        mediaSessionID = nil
        directoryURL = nil
        writer = nil
        writerInput = nil
        segmentStartPTS = nil
        recordingStartPTS = nil
        lastPTS = nil
    }
}
