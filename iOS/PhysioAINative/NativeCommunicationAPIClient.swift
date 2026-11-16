import Foundation

enum NativeCallMediaType: String, Codable {
    case audio, video
}

struct NativeActiveCall: Decodable, Equatable, Identifiable {
    let id: String
    let patientId: String
    let therapistId: String
    let initiatedBy: String
    let signalingSessionId: String
    let status: String
    let mediaType: NativeCallMediaType?
    let createdAt: String?
    let connectedAt: String?
    let endedAt: String?

    var isEnded: Bool { status == "ended" || status == "cancelled" }
    var createdDate: Date { Self.date(createdAt) ?? .distantPast }
    var durationSeconds: Int? {
        guard let start = Self.date(connectedAt), let end = Self.date(endedAt), end >= start else { return nil }
        return Int(end.timeIntervalSince(start))
    }
    func historyDetail(own: Bool) -> String {
        guard let seconds = durationSeconds else {
            return status == "cancelled" ? (own ? "ไม่ได้รับสาย" : "สายที่ไม่ได้รับ") : "สิ้นสุดการโทร"
        }
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        return [hours > 0 ? "\(hours) ชม." : "", minutes > 0 ? "\(minutes) นาที" : "", "\(seconds % 60) วิ"]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    private static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    enum CodingKeys: String, CodingKey {
        case id, status
        case patientId = "patient_id"
        case therapistId = "therapist_id"
        case initiatedBy = "initiated_by"
        case signalingSessionId = "signaling_session_id"
        case mediaType = "media_type"
        case createdAt = "created_at"
        case connectedAt = "connected_at"
        case endedAt = "ended_at"
    }
}

struct NativeICEServer: Decodable {
    let urls: [String]
    let username: String?
    let credential: String?

    enum CodingKeys: CodingKey { case urls, username, credential }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let list = try? container.decode([String].self, forKey: .urls) {
            urls = list
        } else {
            urls = [try container.decode(String.self, forKey: .urls)]
        }
        username = try container.decodeIfPresent(String.self, forKey: .username)
        credential = try container.decodeIfPresent(String.self, forKey: .credential)
    }
}

struct NativeCallSession: Decodable {
    let callId: String
    let patientId: String
    let signalingSessionId: String
    let isInitiator: Bool
    let iceServers: [NativeICEServer]
    let expiresIn: Int
    let mediaType: NativeCallMediaType?

    var isAudioOnly: Bool { mediaType == .audio }
}

struct NativeCallSignal: Decodable, Identifiable {
    let id: String
    let senderId: String
    let signalType: String
    let payload: [String: NativeJSONValue]

    enum CodingKeys: String, CodingKey {
        case id, payload
        case senderId = "sender_id"
        case signalType = "signal_type"
    }
}

enum NativeJSONValue: Codable {
    case string(String), number(Double), bool(Bool), object([String: NativeJSONValue]), array([NativeJSONValue]), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode([String: NativeJSONValue].self) { self = .object(item) }
        else { self = .array(try value.decode([NativeJSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var int32: Int32? { if case .number(let value) = self { Int32(value) } else { nil } }
}

private struct NativeActiveCallEnvelope: Decodable { let call: NativeActiveCall? }
struct NativeSignalsEnvelope: Decodable { let signals: [NativeCallSignal]; let call: NativeActiveCall? }
private struct NativeCallHistoryEnvelope: Decodable { let calls: [NativeActiveCall] }
private struct NativeCallRequest: Encodable { let patientId: String; let callId: String?; let mediaType: NativeCallMediaType? }
private struct NativeSignalRequest: Encodable {
    let callId: String
    let type: String
    let payload: [String: NativeJSONValue]
}

struct NativeCommunicationAPIClient {
    func fetchActiveCall() async throws -> NativeActiveCall? {
        let data = try await request(path: "/api/cloudflare/calls", method: "GET", body: nil)
        return try JSONDecoder().decode(NativeActiveCallEnvelope.self, from: data).call
    }

    func fetchCallHistory(patientId: String) async throws -> [NativeActiveCall] {
        let encoded = patientId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? patientId
        let data = try await request(path: "/api/cloudflare/calls?history=true&patientId=\(encoded)", method: "GET", body: nil)
        return try JSONDecoder().decode(NativeCallHistoryEnvelope.self, from: data).calls
    }

    func callSession(patientId: String, callId: String? = nil, mediaType: NativeCallMediaType? = nil) async throws -> NativeCallSession {
        let body = try JSONEncoder().encode(NativeCallRequest(patientId: patientId, callId: callId, mediaType: mediaType))
        let data = try await request(path: "/api/cloudflare/calls", method: "POST", body: body)
        let session = try JSONDecoder().decode(NativeCallSession.self, from: data)
        guard mediaType != .audio || session.isAudioOnly else {
            throw NativeAPIError.message("เซิร์ฟเวอร์ยังไม่พร้อมสำหรับสายเสียง กรุณาอัปเดตเซิร์ฟเวอร์ก่อน")
        }
        return session
    }

    func fetchSignals(callId: String) async throws -> NativeSignalsEnvelope {
        let encoded = callId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? callId
        let data = try await request(path: "/api/cloudflare/signals?callId=\(encoded)", method: "GET", body: nil)
        return try JSONDecoder().decode(NativeSignalsEnvelope.self, from: data)
    }

    func sendSignal(callId: String, type: String, payload: [String: NativeJSONValue]) async throws {
        let body = try JSONEncoder().encode(NativeSignalRequest(callId: callId, type: type, payload: payload))
        _ = try await request(path: "/api/cloudflare/signals", method: "POST", body: body)
    }

    func updateCall(callId: String, status: String) async throws -> NativeActiveCall? {
        let payload = try JSONSerialization.data(withJSONObject: ["callId": callId, "status": status])
        for attempt in 0..<3 {
            do {
                let data = try await request(path: "/api/cloudflare/calls", method: "PATCH", body: payload)
                return try JSONDecoder().decode(NativeActiveCallEnvelope.self, from: data).call
            } catch {
                if Task.isCancelled || attempt == 2 { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 300_000_000)
            }
        }
        return nil
    }

    private func request(path: String, method: String, body: Data?) async throws -> Data {
        guard let baseURL = NativeConfig.apiBaseURL else { throw NativeAPIError.notConfigured }
        guard let url = URL(string: path, relativeTo: baseURL) else { throw NativeAPIError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = NativeKeychainStore.token() { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NativeAPIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let errorCode = (try? JSONSerialization.jsonObject(with: data) as? [String: String])?["error"]
            throw NativeAPIError.message(errorCode ?? "HTTP \(http.statusCode)")
        }
        return data
    }
}
