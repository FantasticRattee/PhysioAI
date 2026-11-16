import Foundation

enum NativeAPIError: LocalizedError {
    case notConfigured
    case invalidResponse
    case message(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Cloud API is not configured. Enable Simulator fixture mode or set an API base URL."
        case .invalidResponse: return "The API returned an invalid response."
        case let .message(value): return value
        }
    }
}

struct NativeAPIClient {
    private let baseURL: URL?

    init() {
        baseURL = NativeConfig.apiBaseURL
    }

    func login(email: String, password: String) async throws -> NativeAuthResponse {
        try await post(path: "/auth/login", body: ["email": email, "password": password], authenticated: false)
    }

    func register(name: String, email: String, password: String) async throws -> NativeAuthResponse {
        try await post(path: "/auth/register", body: ["name": name, "email": email, "password": password, "role": "patient"], authenticated: false)
    }

    func fetchPlan() async throws -> NativePlan? {
        let data = try await request(path: "/plans", method: "GET", body: nil, authenticated: true)
        if data.isEmpty || String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
            return nil
        }
        do {
            return try JSONDecoder().decode(NativePlan.self, from: data)
        } catch {
            throw NativeAPIError.invalidResponse
        }
    }

    func fetchSessions() async throws -> [NativeSessionRecord] {
        let data = try await request(path: "/sessions", method: "GET", body: nil, authenticated: true)
        do {
            return try JSONDecoder().decode([NativeSessionRecord].self, from: data)
        } catch {
            throw NativeAPIError.invalidResponse
        }
    }

    func fetchLiveAssist(after cursor: String? = nil, exerciseId: String? = nil) async throws -> NativeLiveAssistBatch {
        var components = URLComponents(string: "/live-assist/corrections")
        var query: [URLQueryItem] = []
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "after", value: cursor)) }
        if let exerciseId, !exerciseId.isEmpty { query.append(URLQueryItem(name: "exerciseId", value: exerciseId)) }
        components?.queryItems = query.isEmpty ? nil : query
        let path = components?.string ?? "/live-assist/corrections"
        let data = try await request(path: path, method: "GET", body: nil, authenticated: true)
        do {
            return try JSONDecoder().decode(NativeLiveAssistBatch.self, from: data)
        } catch {
            throw NativeAPIError.invalidResponse
        }
    }

    func acknowledgeLiveAssist(id: String) async throws {
        _ = try await request(path: "/live-assist/corrections/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)/ack", method: "POST", body: nil, authenticated: true)
    }

    func logSession(_ payload: NativeSessionPayload) async throws {
        _ = try await request(
            path: "/sessions",
            method: "POST",
            body: try JSONEncoder().encode(payload),
            authenticated: true,
        )
    }

    /// Requests a server-side review after the immutable session row has been
    /// stored. The OpenAI key remains on Railway and never enters the iPhone app.
    func createAutomaticSessionReview(sessionID: String) async throws {
        _ = try await request(
            path: "/api/session-reviews",
            method: "POST",
            body: try JSONEncoder().encode(["sessionId": sessionID]),
            authenticated: true,
        )
    }

    private func post<T: Decodable>(path: String, body: [String: String], authenticated: Bool) async throws -> T {
        let data = try await request(
            path: path,
            method: "POST",
            body: try JSONEncoder().encode(body),
            authenticated: authenticated,
        )
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw NativeAPIError.invalidResponse
        }
    }

    private func request(path: String, method: String, body: Data?, authenticated: Bool) async throws -> Data {
        guard let baseURL else { throw NativeAPIError.notConfigured }
        guard let url = URL(string: path, relativeTo: baseURL) else { throw NativeAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authenticated, let token = NativeKeychainStore.token() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = payload["error"] as? String {
                throw NativeAPIError.message(code)
            }
            throw NativeAPIError.message("Request failed with HTTP \(http.statusCode).")
        }
        return data
    }
}
