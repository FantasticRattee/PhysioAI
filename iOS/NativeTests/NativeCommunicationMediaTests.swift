import XCTest
@testable import PhysioAINative

final class NativeCommunicationMediaTests: XCTestCase {
    private func session(_ media: String) throws -> NativeCallSession {
        let json = """
        {"callId":"call","patientId":"patient","signalingSessionId":"signals","isInitiator":false,"iceServers":[],"expiresIn":3600\(media)}
        """
        return try JSONDecoder().decode(NativeCallSession.self, from: Data(json.utf8))
    }

    func testAudioSessionUsesVoiceOnlyMode() throws {
        XCTAssertTrue(try session(",\"mediaType\":\"audio\"").isAudioOnly)
    }

    func testVideoAndLegacySessionsKeepVideoMode() throws {
        XCTAssertFalse(try session(",\"mediaType\":\"video\"").isAudioOnly)
        XCTAssertFalse(try session("").isAudioOnly)
    }

    func testUnknownMediaFailsDecodingInsteadOfOpeningCamera() {
        XCTAssertThrowsError(try session(",\"mediaType\":\"unknown\""))
    }

    func testIncomingCallCarriesAudioMediaType() throws {
        let data = Data("""
        {"id":"call","patient_id":"patient","therapist_id":"therapist","initiated_by":"therapist","signaling_session_id":"signals","status":"ringing","media_type":"audio"}
        """.utf8)
        XCTAssertEqual(try JSONDecoder().decode(NativeActiveCall.self, from: data).mediaType, .audio)
    }

    func testCallHistoryExcludesRingingAndUsesServerEndTime() throws {
        let data = Data("""
        {"id":"call","patient_id":"patient","therapist_id":"therapist","initiated_by":"patient","signaling_session_id":"signals","status":"ended","media_type":"video","created_at":"2026-09-10T00:00:00Z","connected_at":"2026-09-10T00:01:00.000Z","ended_at":"2026-09-10T01:25:35.000Z"}
        """.utf8)
        let call = try JSONDecoder().decode(NativeActiveCall.self, from: data)
        XCTAssertTrue(call.isEnded)
        XCTAssertEqual(call.durationSeconds, 5075)
        XCTAssertEqual(call.historyDetail(own: true), "1 ชม. 24 นาที 35 วิ")
    }

    func testTerminalPollWorksWithoutAHangupSignal() throws {
        let data = Data("""
        {"signals":[],"call":{"id":"call","patient_id":"patient","therapist_id":"therapist","initiated_by":"patient","signaling_session_id":"signals","status":"cancelled"}}
        """.utf8)
        let batch = try JSONDecoder().decode(NativeSignalsEnvelope.self, from: data)
        XCTAssertTrue(batch.call?.isEnded == true)
        XCTAssertNil(batch.call?.durationSeconds)
        XCTAssertEqual(batch.call?.historyDetail(own: false), "สายที่ไม่ได้รับ")
    }
}
