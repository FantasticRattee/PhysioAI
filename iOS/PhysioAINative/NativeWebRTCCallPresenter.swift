import AVFoundation
import CoreMedia
import SwiftUI
import UIKit
import WebRTC

@MainActor
enum NativeWebRTCCallPresenter {
    static func present(session: NativeCallSession, userId: String, onEnded: @escaping @MainActor () async -> Void) {
        let controller = UIHostingController(rootView: NativeWebRTCCallView(session: session, userId: userId, onEnded: onEnded))
        controller.modalPresentationStyle = .fullScreen
        topViewController()?.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let root = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        var current = root
        while let presented = current?.presentedViewController { current = presented }
        return current
    }
}

private struct NativeWebRTCCallView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var engine: NativeWebRTCEngine
    @State private var finished = false
    let onEnded: @MainActor () async -> Void

    init(session: NativeCallSession, userId: String, onEnded: @escaping @MainActor () async -> Void) {
        _engine = StateObject(wrappedValue: NativeWebRTCEngine(session: session, userId: userId))
        self.onEnded = onEnded
    }

    var body: some View {
        ZStack {
            Color(red: 0.03, green: 0.08, blue: 0.06).ignoresSafeArea()
            if engine.isAudioOnly {
                VStack(spacing: 18) {
                    Image(systemName: "phone.fill").font(.system(size: 46))
                        .frame(width: 120, height: 120)
                        .background(.white.opacity(0.12), in: Circle())
                    Text("โทรด้วยเสียง").font(.system(size: 28, weight: .bold))
                    Text("สนทนาผ่านอินเทอร์เน็ต · ไม่เปิดกล้อง")
                        .font(.system(size: 15)).foregroundColor(.white.opacity(0.7))
                }.foregroundColor(.white)
            } else {
                NativeRTCVideoView(track: engine.remoteVideoTrack, mirrored: false).ignoresSafeArea()
            }
            VStack {
                Text(engine.status).font(.system(size: 13, weight: .bold)).foregroundColor(.white)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(.black.opacity(0.55), in: Capsule()).padding(.top, 18)
                Spacer()
                if !engine.isAudioOnly {
                    HStack(alignment: .bottom) {
                        Spacer()
                        NativeRTCVideoView(track: engine.localVideoTrack, mirrored: true)
                            .frame(width: 122, height: 170).clipShape(RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.8), lineWidth: 2))
                    }.padding(.horizontal, 18)
                }
                HStack(spacing: 10) {
                    Button { engine.toggleMute() } label: {
                        Label(engine.isMuted ? "เปิดไมค์" : "ปิดไมค์", systemImage: engine.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                            .padding(.horizontal, 12).frame(minHeight: 48).background(.white.opacity(0.18), in: Capsule())
                    }
                    if engine.isAudioOnly {
                        Button { engine.toggleSpeaker() } label: {
                            Label("ลำโพง", systemImage: engine.isSpeakerOn ? "speaker.wave.2.fill" : "speaker.fill")
                                .font(.system(size: 14, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 12).frame(minHeight: 48)
                                .background(.white.opacity(engine.isSpeakerOn ? 0.35 : 0.18), in: Capsule())
                        }
                        .accessibilityLabel(engine.isSpeakerOn ? "ปิดลำโพง" : "เปิดลำโพง")
                    }
                    Button { finish() } label: {
                        Label("วางสาย", systemImage: "phone.down.fill").font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white).padding(.horizontal, 14).frame(minHeight: 48)
                            .background(Color.red.opacity(0.9), in: Capsule())
                    }
                }.padding(.vertical, 20)
            }
        }
        .task { await engine.start() }
        .onChange(of: engine.remoteEnded) { ended in if ended { finish() } }
        .onDisappear { engine.stop() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        engine.stop()
        dismiss()
        Task { await onEnded() }
    }
}

private struct NativeRTCVideoView: UIViewRepresentable {
    let track: RTCVideoTrack?
    let mirrored: Bool

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero)
        view.videoContentMode = .scaleAspectFill
        view.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(view)
            track?.add(view)
            context.coordinator.track = track
        }
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) { coordinator.track?.remove(view) }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var track: RTCVideoTrack? }
}

private final class NativeWebRTCEngine: NSObject, ObservableObject {
    @Published var status = "กำลังเปิดกล้อง…"
    @Published var isMuted = false
    @Published var isSpeakerOn = false
    @Published var localVideoTrack: RTCVideoTrack?
    @Published var remoteVideoTrack: RTCVideoTrack?
    @Published var remoteEnded = false

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    private let session: NativeCallSession
    private let userId: String
    private let api = NativeCommunicationAPIClient()
    private var peer: RTCPeerConnection?
    private var capturer: RTCCameraVideoCapturer?
    private var audioTrack: RTCAudioTrack?
    private var processed = Set<String>()
    private var queuedCandidates: [RTCIceCandidate] = []
    private var remoteDescriptionReady = false
    private var pollingTask: Task<Void, Never>?
    private var credentialTask: Task<Void, Never>?
    private var stopped = false
    private var reportedConnected = false
    private var disconnectTask: Task<Void, Never>?

    var isAudioOnly: Bool { session.isAudioOnly }

    init(session: NativeCallSession, userId: String) {
        self.session = session
        // Otherwise our own lowercase sender_id can look like a remote signal.
        self.userId = userId.lowercased()
        status = session.isAudioOnly ? "กำลังเปิดไมโครโฟน…" : "กำลังเปิดกล้อง…"
        isSpeakerOn = !session.isAudioOnly
    }

    @MainActor
    func start() async {
        do {
            let microphoneAllowed: Bool = await withCheckedContinuation { continuation in
                if #available(iOS 17.0, *) {
                    AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
                } else {
                    AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
                }
            }
            guard microphoneAllowed else { throw NativeAPIError.message("กรุณาอนุญาตไมโครโฟนใน Settings") }
            guard !stopped, !Task.isCancelled else { return }
            try configurePeer()
            try await startCapture()
            guard !stopped, !Task.isCancelled else { return }
            pollingTask = Task { [weak self] in await self?.pollSignals() }
            credentialTask = Task { [weak self] in await self?.refreshCredentials() }
            if session.isInitiator {
                let offer = try await createOffer()
                guard !stopped, !Task.isCancelled else { return }
                try await api.sendSignal(callId: session.callId, type: "offer", payload: ["type": .string("offer"), "sdp": .string(offer.sdp)])
                status = "กำลังรอนักกายภาพรับสาย…"
            } else {
                status = "กำลังรับสาย…"
            }
        } catch {
            guard !stopped, !Task.isCancelled else { return }
            stop()
            status = "เริ่ม\(isAudioOnly ? "โทรเสียง" : "วิดีโอคอล")ไม่สำเร็จ: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func configurePeer() throws {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherContinually
        configuration.iceServers = session.iceServers.map {
            RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        guard let connection = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: self) else {
            throw NativeAPIError.message("สร้าง WebRTC connection ไม่สำเร็จ")
        }
        peer = connection
        let audioSource = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let audio = Self.factory.audioTrack(with: audioSource, trackId: "audio0")
        audioTrack = audio
        connection.add(audio, streamIds: ["physioai"])
        if !isAudioOnly {
            let videoSource = Self.factory.videoSource()
            let video = Self.factory.videoTrack(with: videoSource, trackId: "video0")
            localVideoTrack = video
            connection.add(video, streamIds: ["physioai"])
            capturer = RTCCameraVideoCapturer(delegate: videoSource)
        }
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        defer { audioSession.unlockForConfiguration() }
        try audioSession.setCategory(.playAndRecord)
        try audioSession.setMode(isAudioOnly ? .voiceChat : .videoChat)
        try audioSession.overrideOutputAudioPort(isSpeakerOn ? .speaker : .none)
        try audioSession.setActive(true)
    }

    private func startCapture() async throws {
        // Voice-only calls must not enumerate, request, or start any camera.
        guard !isAudioOnly else { return }
        guard let capturer,
              let camera = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
                ?? RTCCameraVideoCapturer.captureDevices().first,
              let format = RTCCameraVideoCapturer.supportedFormats(for: camera).max(by: {
                  let left = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
                  let right = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                  return left.width * left.height < right.width * right.height
              }) else { throw NativeAPIError.message("ไม่พบกล้องที่ใช้วิดีโอคอลได้") }
        let fps = min(30, Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            capturer.startCapture(with: camera, format: format, fps: fps) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func createOffer() async throws -> RTCSessionDescription {
        guard let peer else { throw NativeAPIError.invalidResponse }
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": isAudioOnly ? "false" : "true"], optionalConstraints: nil)
        let offer = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? NativeAPIError.invalidResponse) }
            }
        }
        try await setLocal(offer)
        return offer
    }

    private func createAnswer() async throws -> RTCSessionDescription {
        guard let peer else { throw NativeAPIError.invalidResponse }
        let constraints = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": isAudioOnly ? "false" : "true"], optionalConstraints: nil)
        let answer = try await withCheckedThrowingContinuation { continuation in
            peer.answer(for: constraints) { sdp, error in
                if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? NativeAPIError.invalidResponse) }
            }
        }
        try await setLocal(answer)
        return answer
    }

    private func setLocal(_ sdp: RTCSessionDescription) async throws {
        guard let peer, !stopped else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(sdp) { error in error == nil ? continuation.resume() : continuation.resume(throwing: error!) }
        }
    }

    private func setRemote(_ sdp: RTCSessionDescription) async throws {
        guard let peer, !stopped else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(sdp) { error in error == nil ? continuation.resume() : continuation.resume(throwing: error!) }
        }
        remoteDescriptionReady = true
        for candidate in queuedCandidates { try await add(candidate) }
        queuedCandidates.removeAll()
    }

    private func add(_ candidate: RTCIceCandidate) async throws {
        guard let peer, !stopped else { throw CancellationError() }
        guard remoteDescriptionReady else { queuedCandidates.append(candidate); return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.add(candidate) { error in error == nil ? continuation.resume() : continuation.resume(throwing: error!) }
        }
    }

    @MainActor
    private func pollSignals() async {
        while !Task.isCancelled && !stopped {
            do {
                let batch = try await api.fetchSignals(callId: session.callId)
                guard !stopped, !Task.isCancelled else { return }
                if batch.call?.isEnded == true {
                    await finishRemote()
                    return
                }
                for signal in batch.signals where signal.senderId.lowercased() != userId && !processed.contains(signal.id) {
                    guard !stopped, !Task.isCancelled else { return }
                    processed.insert(signal.id)
                    if signal.signalType == "offer", !session.isInitiator,
                       let sdp = signal.payload["sdp"]?.string {
                        try await setRemote(RTCSessionDescription(type: .offer, sdp: sdp))
                        let answer = try await createAnswer()
                        try await api.sendSignal(callId: session.callId, type: "answer", payload: ["type": .string("answer"), "sdp": .string(answer.sdp)])
                    } else if signal.signalType == "answer", session.isInitiator, !remoteDescriptionReady,
                              let sdp = signal.payload["sdp"]?.string {
                        try await setRemote(RTCSessionDescription(type: .answer, sdp: sdp))
                    } else if signal.signalType == "ice", let candidate = signal.payload["candidate"]?.string {
                        let mid = signal.payload["sdpMid"]?.string
                        let line = signal.payload["sdpMLineIndex"]?.int32 ?? 0
                        try await add(RTCIceCandidate(sdp: candidate, sdpMLineIndex: line, sdpMid: mid))
                    } else if signal.signalType == "hangup" {
                        await finishRemote()
                        return
                    }
                }
            } catch {
                await MainActor.run { if !self.stopped { self.status = "สัญญาณขัดข้อง กำลังลองใหม่…" } }
            }
            try? await Task.sleep(nanoseconds: 650_000_000)
        }
    }

    @MainActor
    private func refreshCredentials() async {
        var expiresIn = session.expiresIn
        while !Task.isCancelled && !stopped {
            let delay = max(240, Int(Double(expiresIn) * 0.8))
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled && !stopped else { return }
            do {
                let refreshed = try await api.callSession(patientId: session.patientId, callId: session.callId)
                guard !stopped, !Task.isCancelled else { return }
                let configuration = peer?.configuration ?? RTCConfiguration()
                configuration.iceServers = refreshed.iceServers.map {
                    RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential)
                }
                peer?.setConfiguration(configuration)
                expiresIn = refreshed.expiresIn
            } catch {
                await MainActor.run { if !self.stopped { self.status = "ต่ออายุการเชื่อมต่อไม่สำเร็จ กรุณาวางสายแล้วโทรใหม่" } }
                return
            }
        }
    }

    @MainActor
    private func finishRemote() {
        guard !stopped else { return }
        stop()
        remoteEnded = true
    }

    @MainActor
    private func reportConnected() {
        guard !stopped, !reportedConnected else { return }
        reportedConnected = true
        Task {
            do {
                let call = try await api.updateCall(callId: session.callId, status: "live")
                if call?.isEnded == true { finishRemote() }
            } catch { reportedConnected = false }
        }
    }

    @MainActor
    func toggleMute() {
        isMuted.toggle()
        audioTrack?.isEnabled = !isMuted
    }

    @MainActor
    func toggleSpeaker() {
        let next = !isSpeakerOn
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        defer { audioSession.unlockForConfiguration() }
        do {
            try audioSession.overrideOutputAudioPort(next ? .speaker : .none)
            isSpeakerOn = next
        } catch {
            status = "เปลี่ยนลำโพงไม่สำเร็จ"
        }
    }

    @MainActor
    func stop() {
        guard !stopped else { return }
        stopped = true
        pollingTask?.cancel()
        credentialTask?.cancel()
        disconnectTask?.cancel()
        capturer?.stopCapture()
        audioTrack?.isEnabled = false
        localVideoTrack?.isEnabled = false
        peer?.close()
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        try? audioSession.overrideOutputAudioPort(.none)
        try? audioSession.setActive(false)
        audioSession.unlockForConfiguration()
        // The presenter's onEnded persists the durable terminal state with
        // retries. Do not race a separate fire-and-forget signal against it.
    }
}

extension NativeWebRTCEngine: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first { DispatchQueue.main.async { self.remoteVideoTrack = track } }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let label: String
        switch newState {
        case .connected, .completed: label = "เชื่อมต่อแล้ว · เข้ารหัส WebRTC"
        case .checking: label = "กำลังเชื่อมต่อ…"
        case .disconnected: label = "สัญญาณขาดหาย กำลังเชื่อมใหม่…"
        case .failed: label = "เชื่อมต่อไม่สำเร็จ"
        case .closed: label = "วางสายแล้ว"
        default: return
        }
        Task { @MainActor in
            guard !self.stopped else { return }
            self.disconnectTask?.cancel()
            if newState == .disconnected {
                self.disconnectTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !Task.isCancelled, !self.stopped { self.status = label }
                }
                return
            }
            self.status = label
            if newState == .connected || newState == .completed { self.reportConnected() }
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        guard !stopped else { return }
        var payload: [String: NativeJSONValue] = [
            "candidate": .string(candidate.sdp),
            "sdpMLineIndex": .number(Double(candidate.sdpMLineIndex)),
        ]
        payload["sdpMid"] = candidate.sdpMid.map(NativeJSONValue.string) ?? .null
        Task { try? await api.sendSignal(callId: session.callId, type: "ice", payload: payload) }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        if let track = transceiver.receiver.track as? RTCVideoTrack { DispatchQueue.main.async { self.remoteVideoTrack = track } }
    }
}
