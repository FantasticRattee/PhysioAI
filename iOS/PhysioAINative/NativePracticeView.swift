import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct NativeBottleExampleVideo: View {
    let isThai: Bool
    var resourceName = "grabbottle"
    var titleThai = "ตัวอย่างท่าหยิบขวด"
    var titleEnglish = "Bottle grab example"
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    Text(isThai ? "ไม่พบวิดีโอตัวอย่าง" : "Example video unavailable")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(isThai ? titleThai : titleEnglish)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isThai ? "ปิด" : "Close") { dismiss() }
                }
            }
        }
        .onAppear {
            guard player == nil, let url = Bundle.main.url(forResource: resourceName, withExtension: "mov") else { return }
            player = AVPlayer(url: url)
            player?.play()
        }
        .onDisappear { player?.pause(); player = nil }
    }
}

enum NativePracticePhase: Equatable {
    case positioning
    case countdown
    case active
}

/// Pure lifecycle policy for the camera practice surface. Keeping countdown
/// transitions separate from SwiftUI lets XCTest prove that a lost required
/// pose/hand signal cannot silently activate counting after three seconds.
enum NativePracticeActivationPolicy {
    static func phaseAfterReadinessUpdate(
        current: NativePracticePhase,
        isTrackingReady: Bool,
    ) -> NativePracticePhase {
        switch current {
        case .positioning:
            return isTrackingReady ? .countdown : .positioning
        case .countdown:
            return isTrackingReady ? .countdown : .positioning
        case .active:
            return .active
        }
    }

    static func phaseAtCountdownCompletion(isTrackingReady: Bool) -> NativePracticePhase {
        isTrackingReady ? .active : .positioning
    }
}

/// Keeps the camera landmark layer behind the patient-facing HUD. The camera
/// preview itself may remain full-bleed, but drawing a skeleton through the
/// cue, lens picker, or camera buttons makes the controls look broken and can
/// obscure their labels. These values reserve the measured lower HUD space on
/// the supported compact iPhone layout; the function fails closed on an
/// unusually short container rather than allowing landmark paint into the
/// protected controls.
enum NativePracticeOverlayLayout {
    private static let bottomHUDHeight: CGFloat = 334
    private static let lensPickerHeight: CGFloat = 128

    static func visibleLandmarkHeight(
        containerHeight: CGFloat,
        lensMenuOpen: Bool,
    ) -> CGFloat {
        let protectedHeight = bottomHUDHeight + (lensMenuOpen ? lensPickerHeight : 0)
        return max(0, containerHeight - protectedHeight)
    }
}

/// Owns one speech synthesizer for the lifetime of a SwiftUI practice screen.
/// A `let AVSpeechSynthesizer()` stored directly on a View can be recreated as
/// SwiftUI refreshes the value type after camera-frame updates, which makes
/// spoken cues intermittent. Keeping it in `@StateObject` preserves one
/// coordinator-owned active phrase and one latest pending phrase across view
/// refreshes.
enum NativeSpeechRecoveryPolicy {
    static func shouldReactivateAfterInterruption(
        began: Bool,
        shouldResume: Bool,
    ) -> Bool {
        !began && shouldResume
    }

    static var shouldReactivateAfterRouteChange: Bool { true }
}

final class NativeSpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var lastError: String?
    @Published private(set) var state = "idle"
    @Published private(set) var selectedVoiceIdentifier: String?

    private let synthesizer = AVSpeechSynthesizer()
    private var audioSessionConfigured = false
    private var audioNotificationTokens: [NSObjectProtocol] = []
    private var coordinator = NativeSpeechCommentCoordinator()
    private var explicitStopRequested = false

    override init() {
        super.init()
        synthesizer.delegate = self
        let center = NotificationCenter.default
        audioNotificationTokens = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main,
            ) { [weak self] notification in
                self?.handleAudioInterruption(notification)
            },
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main,
            ) { [weak self] _ in
                self?.handleAudioRouteChange()
            },
        ]
    }

    deinit {
        let center = NotificationCenter.default
        audioNotificationTokens.forEach(center.removeObserver)
    }

    @discardableResult
    func configure() -> Bool {
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audio.setActive(true, options: [])
            audioSessionConfigured = true
            lastError = nil
            state = "audio_ready"
            return true
        } catch {
            audioSessionConfigured = false
            lastError = error.localizedDescription
            state = "audio_error"
            return false
        }
    }

    @discardableResult
    func submit(_ request: NativeSpeechRequest) -> Bool {
#if REAL_V7 || REAL_V72
        return startLegacy(request)
#else
        let now = Date().timeIntervalSinceReferenceDate
        let decision = coordinator.submit(
            request,
            now: now,
            isSpeaking: synthesizer.isSpeaking,
        )
        return enact(decision)
#endif
    }

    /// V7 and V7.2 retain the pre-V7.1 speech behavior. They deliberately do
    /// not coalesce requests through `NativeSpeechCommentCoordinator`; the
    /// coordinator is enabled only for the V7.1 and V7.3 profiles.
    @discardableResult
    private func startLegacy(_ request: NativeSpeechRequest) -> Bool {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        return start(request)
    }

    /// Retained for the diagnostic voice button and legacy callers. All normal
    /// cue producers should call `submit` with a stable semantic key instead.
    @discardableResult
    func speak(_ text: String, language: String) -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        return submit(
            NativeSpeechRequest(
                semanticKey: "manual:\(UUID().uuidString)",
                text: text,
                language: language,
                priority: .system,
                observedAt: now,
            ),
        )
    }

    func resetPresentationState() {
        coordinator.reset()
    }

    /// Keeps semantic speech episodes synchronized with the current visible
    /// guidance. A cue only re-arms after it has truly left the presentation.
    func observeVisibleKeys(_ keys: Set<String>) {
        coordinator.observeVisibleKeys(
            keys,
            now: Date().timeIntervalSinceReferenceDate,
        )
    }

    private func enact(_ decision: NativeSpeechCommentCoordinatorDecision) -> Bool {
        switch decision {
        case let .speakNow(request):
            let started = start(request)
            if !started { coordinator.didNotStart() }
            return started
        case .queueLatest:
            state = "queued"
            return true
        case .suppress, .none:
            return false
        }
    }

    private func start(_ request: NativeSpeechRequest) -> Bool {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if !audioSessionConfigured, !configure() { return false }
        guard audioSessionConfigured else { return false }
        guard let voice = resolvedVoice(language: request.language) else {
            lastError = "No installed speech voice for \(request.language)."
            state = "voice_unavailable"
            return false
        }
#if !REAL_V7 && !REAL_V72
        // V7.1's coordinator calls this only when there is no active
        // utterance. Do not cut a sentence off for an ordinary live frame.
        guard !synthesizer.isSpeaking else { return false }
#endif
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.voice = voice
        utterance.rate = 0.48
        selectedVoiceIdentifier = voice.identifier
        state = "queued"
        lastError = nil
        synthesizer.speak(utterance)
        return true
    }

    /// A physical-device diagnostic control. `didStart`/`didFinish` report
    /// speech-engine lifecycle, while the route makes a Bluetooth/headphone
    /// output visible. Neither is misrepresented as proof that a user heard
    /// the sound.
    @discardableResult
    func testVoice(language: String) -> Bool {
        let text = language.lowercased().hasPrefix("th")
            ? "ทดสอบเสียง PhysioAI"
            : "PhysioAI voice test."
        return speak(text, language: language)
    }

    var diagnosticSummary: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let route = outputs.isEmpty
            ? "no output route"
            : outputs.map(\.portName).joined(separator: ", ")
        let voice = selectedVoiceIdentifier ?? "voice not selected"
        return "TTS \(state) · \(voice) · \(route)"
    }

    func stop() {
        coordinator.reset()
        explicitStopRequested = synthesizer.isSpeaking
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        if audioSessionConfigured {
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            audioSessionConfigured = false
        }
        state = "stopped"
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        state = "started"
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        state = "finished"
        let now = Date().timeIntervalSinceReferenceDate
        _ = enact(coordinator.didFinish(now: now))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        state = "cancelled"
        if explicitStopRequested {
            explicitStopRequested = false
            return
        }
        let now = Date().timeIntervalSinceReferenceDate
        _ = enact(coordinator.didFinish(now: now))
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            audioSessionConfigured = false
            return
        }
        let began = type == .began
        audioSessionConfigured = false
        state = began ? "interrupted" : "resuming"
        guard !began else { return }
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
        if NativeSpeechRecoveryPolicy.shouldReactivateAfterInterruption(
            began: began,
            shouldResume: options.contains(.shouldResume),
        ) {
            _ = configure()
        }
    }

    private func handleAudioRouteChange() {
        audioSessionConfigured = false
        state = "route_changed"
        if NativeSpeechRecoveryPolicy.shouldReactivateAfterRouteChange {
            _ = configure()
        }
    }

    private func resolvedVoice(language: String) -> AVSpeechSynthesisVoice? {
        if let exact = AVSpeechSynthesisVoice(language: language) {
            return exact
        }
        let prefix = language.split(separator: "-").first?.lowercased()
        return AVSpeechSynthesisVoice.speechVoices().first {
            guard let prefix else { return false }
            return $0.language.lowercased().hasPrefix("\(prefix)-")
        }
    }
}

struct NativePracticeView: View {
    // Presentation only: set either value to 1 to restore that existing layer.
    // Keep diagnostics, coaching, readiness, and their lifecycle mounted.
    private let developerDiagnosticsOpacity: Double = 0
    private let positioningCommentOpacity: Double = 0

    @EnvironmentObject private var app: NativeAppModel
    @State private var showingExampleVideo = false
    @State private var startedAt = Date()
    @State private var isRunning = CommandLine.arguments.contains("--native-fixture-active")
    @State private var phase: NativePracticePhase = .positioning
    @State private var countdown = 0
    @State private var stableSince: Date?
    @State private var phaseTask: Task<Void, Never>?
    @State private var speechEnabled = true
    @State private var actionCuePresentation = NativeActionCuePresentationPolicy()
    @State private var presentedActionCue: NativeActionCuePresentation?
    @State private var lastAnnouncedRepTotal = 0
    @State private var lastSpokenSetupReason: String?
    @State private var lastSetupSpokenAt = Date.distantPast
    @State private var setupSpeechSessionStartedAt: Date?
    @State private var participantPresenceSince: Date?
    @State private var lastSetupSpeechSnapshotTimestamp: Int?
    @State private var lensMenuOpen = CommandLine.arguments.contains("--native-fixture-lens-menu")
    @State private var completionPolicy = NativePracticeCompletionPolicy()
    @State private var isFinishing = false
    @State private var finishTask: Task<Void, Never>?
    @State private var mediaSetupTask: Task<Void, Never>?
    @State private var mediaRecorder: NativeSessionVideoRecorder?
    @State private var mediaSessionID: String?
    @State private var didFinalizeMedia = false
    @StateObject private var speech = NativeSpeechController()

#if targetEnvironment(simulator)
    @StateObject private var fixture = NativeFixtureController()
    @StateObject private var sitToStandFixture = NativeSitToStandFixtureController()
    @State private var simulatedPosition: NativeCameraPosition = .back
    @State private var simulatedLensTitle = "1×"
    @State private var simulatedZoomFactor: CGFloat = 1
    @State private var simulatedPinchBase: CGFloat?
#else
    @StateObject private var camera = CameraSession()
    @State private var pinchBaseZoom: CGFloat?
#endif
    @StateObject private var liveAssist = NativeLiveAssistController()

    var body: some View {
        Group {
            if isRunning {
                activeSurface
            } else {
                readySurface
            }
        }
    }

    private var isAppV7BottleDetector: Bool {
        NativeBottleDetectorContract.isV7Enabled
    }

    private var isSitToStand: Bool {
        app.selectedExercise?.id == NativeSitToStandV72AIModule.exerciseID
    }

    /// Sit-to-Stand keeps Pose inference live while the camera is empty so it
    /// can discover an arriving participant. Its overlay, however, may only
    /// draw a raw pose after the exercise feature/QC path has accepted it.
    /// Bottle Grab deliberately keeps its frozen V7.3.5 overlay behavior.
    private var shouldRenderRawPoseOverlay: Bool {
        guard isSitToStand else { return true }
        return NativeSitToStandPresencePolicy.shouldRenderRawPose(
            isTrackingReady: latestOutput?.isTrackingReady == true,
        )
    }

    /// The V7 Hand stream is comment-only. Keep it distinct from
    /// `latestOutput`, whose repetition fields are owned exclusively by the
    /// Pose+Bottle counter lane.
    private var secondaryFingerCue: NativeBottleGrabCuePreview? {
#if targetEnvironment(simulator)
        return nil
#else
        return camera.latestFingerComment
#endif
    }

    /// V7.3.4 keeps raw detector freshness observable while separately showing
    /// a confirmed Bottle checkpoint. The accepted fresh ROI is outlined
    /// locally; a retained checkpoint never masquerades as a fresh box.
    private var bottleDetectorDiagnostics: NativeBottleDetectorDiagnostics? {
#if targetEnvironment(simulator)
        return nil
#else
        return camera.latestBottleDetectorDiagnostics
#endif
    }

    /// PhaseNet needs a selected Hand to create context, but V7 proximity
    /// counting does not. Do not turn that optional-context reason into a
    /// patient-facing hard setup failure after Pose-only QC has passed.
    private var countReadinessReason: String? {
        guard let output = latestOutput else { return nil }
        guard isAppV7BottleDetector,
              output.captureQC == "can_assess",
              let reason = output.setupReason else {
            return output.setupReason
        }
        let phaseOnlyHandReasons = [
            "missing_left_hand",
            "missing_hand_side",
            "wrong_anatomical_side",
            "unreliable_hand_side",
            "unassociated_left_hand",
        ]
        return phaseOnlyHandReasons.contains(reason) ? nil : reason
    }

    /// The visual setup card and the spoken setup cue are derived from the
    /// same snapshot, so a stale TTS phrase cannot disagree with the display.
    private var setupGuidance: NativeSetupGuidance? {
        NativeSetupGuidancePolicy.resolve(
            rawReason: countReadinessReason,
            poseLandmarkCount: latestSnapshot?.pose.count,
            isSitToStand: isSitToStand,
            isThai: app.isThai,
            snapshotTimestampMs: latestSnapshot?.timestampMs,
        )
    }

    private var hasObservedNoParticipant: Bool {
        setupGuidance?.semanticKey == NativeSetupSpeechPolicy.noParticipantSemanticReason
    }

    private var bottleDetectorStatusCopy: String {
        guard isAppV7BottleDetector else { return "" }
        guard let diagnostics = bottleDetectorDiagnostics else {
            return app.isThai ? "Detector: รอผลตรวจขวด" : "Detector: awaiting bottle result"
        }
        let score = diagnostics.topScore.map { String(format: "%.2f", $0) }
        let age = diagnostics.ageMs.map { "\($0) ms" } ?? "—"
        switch diagnostics.status {
        case "bottle_detected":
            return app.isThai
                ? "Detector: พบขวด \(score ?? "—") · \(age)"
                : "Detector: bottle \(score ?? "—") · \(age)"
        case "bottle_missing":
            return app.isThai
                ? "Detector: ทำงาน · ไม่พบขวด (\(diagnostics.rawDetectionCount))"
                : "Detector: running · no bottle (\(diagnostics.rawDetectionCount))"
        case "bottle_ambiguous":
            return app.isThai ? "Detector: พบขวดหลายตำแหน่ง" : "Detector: bottle ROI ambiguous"
        case "bottle_stale", "detector_stale":
            return app.isThai ? "Detector: ROI เก่า · \(age)" : "Detector: stale ROI · \(age)"
        case "detector_error":
            return app.isThai ? "Detector: เกิดข้อผิดพลาด" : "Detector: error"
        case "source_changed":
            return app.isThai ? "Detector: เปลี่ยนกล้อง · กำลังเริ่มใหม่" : "Detector: source changed · restarting"
        default:
            return app.isThai ? "Detector: รอ callback" : "Detector: awaiting callback"
        }
    }

    private var bottleCounterStatusCopy: String {
        guard isAppV7BottleDetector else { return "" }
        let stage = latestOutput?.hostCounterStatus ?? "waiting_for_bottle"
        let reason = latestOutput?.hostCounterReason
        return "Counter: \(stage)\(reason.map { " · \($0)" } ?? "")"
    }

    /// Detector freshness is evidence about the latest callback. This separate
    /// line makes it clear when the counter is intentionally using a retained
    /// checkpoint rather than pretending an old box is a new detection.
    private var bottleAnchorStatusCopy: String {
        guard let diagnostics = bottleDetectorDiagnostics else {
            return app.isThai ? "Checkpoint: รอยืนยันตำแหน่งขวด" : "Checkpoint: awaiting confirmation"
        }
        switch diagnostics.anchorState {
        case .waiting:
            return app.isThai ? "Checkpoint: รอยืนยันตำแหน่งขวด" : "Checkpoint: awaiting confirmation"
        case .provisional:
            return app.isThai ? "Checkpoint: พบครั้งแรก · กำลังยืนยัน" : "Checkpoint: first observation · confirming"
        case .confirmed:
            return app.isThai ? "Checkpoint: ยึดตำแหน่งขวดแล้ว" : "Checkpoint: bottle position fixed"
        case .held:
            return app.isThai ? "Checkpoint: ใช้ตำแหน่งขวดเดิม" : "Checkpoint: retaining prior position"
        case .reconfirmed:
            return app.isThai ? "Checkpoint: ยืนยันตำแหน่งเดิม" : "Checkpoint: prior position reconfirmed"
        case .relocationProvisional:
            return app.isThai ? "Checkpoint: พบตำแหน่งใหม่ · กำลังยืนยัน" : "Checkpoint: new position · confirming"
        case .relocated:
            return app.isThai ? "Checkpoint: ย้ายตำแหน่งขวดแล้ว" : "Checkpoint: bottle position relocated"
        }
    }

    private var bottleDetectorDebugCopy: String {
        guard let diagnostics = bottleDetectorDiagnostics else {
            return "Bottle detector diagnostics · awaiting callback"
        }
        let score = diagnostics.topScore.map { String(format: "%.2f", $0) } ?? "—"
        let age = diagnostics.ageMs.map(String.init) ?? "—"
        return "Bottle detector diagnostics · \(diagnostics.status) reason=\(diagnostics.selectionReason) raw=\(diagnostics.rawDetectionCount) accepted=\(diagnostics.acceptedBottleCount) top=\(diagnostics.topLabel ?? "—")/\(score) age=\(age)ms anchor=\(diagnostics.anchorState.rawValue) anchorTimestamp=\(diagnostics.anchorTimestampMs.map(String.init) ?? "—")"
    }

    private var experimentalStatusHeadline: String {
        if isSitToStand {
            return app.isThai
                ? "Geometry: นั่ง → ยืน → นั่ง · PhaseNet comment แยก"
                : "Geometry: sit → stand → sit · independent PhaseNet comments"
        }
        if isAppV7BottleDetector { return bottleDetectorStatusCopy }
        return app.isThai
            ? "Geometry First: อ้ามือ → กำ → ปล่อย"
            : "Geometry First: open → grasp → release"
    }

    private var experimentalStatusDetail: String {
        if isSitToStand {
            return app.isThai
                ? "PhaseNet V1: comment แยกจากตัวนับรอบ"
                : "PhaseNet V1: comments independent from counter"
        }
        if isAppV7BottleDetector { return "\(bottleCounterStatusCopy) · \(bottleAnchorStatusCopy)" }
        return app.isThai
            ? "PhaseNet V2: ใช้เป็น phase context เท่านั้น"
            : "PhaseNet V2: context only"
    }

    private var readySurface: some View {
        NativePageBackground(horizontalPadding: 0, verticalPadding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                NativeBackButton(title: app.isThai ? "ย้อนกลับ" : "Back") { app.backHome() }
                    .padding(.bottom, 4)

                Text(app.isThai ? NativeAppBuildProfile.activeHeaderThai : NativeAppBuildProfile.activeHeaderEnglish)
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .tracking(0.2)
                    .foregroundColor(NativeTheme.forest)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(NativeTheme.brandSoft, in: Capsule())

                Text(app.isThai ? (app.selectedExercise?.titleThai ?? "หยิบขวด") : (app.selectedExercise?.title ?? "Bottle Grab"))
                    .font(.system(size: 32, weight: .heavy))
                    .kerning(-0.8)
                    .foregroundColor(NativeTheme.ink)
                    .padding(.top, 16)
                Text(app.isThai ? (app.selectedExercise?.detailThai ?? "เอื้อม หยิบ ปล่อย และกลับท่าเดิม") : (app.selectedExercise?.detail ?? "Reach, grasp, release and return"))
                    .font(.system(size: 14))
                    .foregroundColor(NativeTheme.ink2)
                    .padding(.top, 6)

                Text(app.isThai
                     ? (isSitToStand
                        ? "Pose geometry นับรอบแยก · PhaseNet สร้าง comment แยก"
                        : (isAppV7BottleDetector
                           ? "Bottle Detector + Pose เป็นตัวนับรอบ · Hand ตรวจนิ้ว · PhaseNet ให้ phase context"
                           : "Geometry First Counter เป็นตัวนับรอบ · PhaseNet V2 ให้ phase context"))
                     : (isSitToStand
                        ? "Pose geometry owns reps independently · PhaseNet owns comments independently"
                        : (isAppV7BottleDetector
                           ? "Bottle Detector + Pose owns proximity reps · Hand comments · PhaseNet context"
                           : "Geometry First Counter owns reps · PhaseNet V2 provides phase context")))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(NativeTheme.forest)
                    .padding(.top, 8)

                VStack(alignment: .leading, spacing: 0) {
                    readyRow(app.isThai ? "เป้าหมาย" : "Target", "\(Int(app.selectedExercise?.target ?? 105))°")
                    readyRow(app.isThai ? "จำนวน" : "Dose", doseText)
                }
                .padding(18)
                .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(NativeTheme.line, lineWidth: 1))
                .padding(.top, 20)

                VStack(alignment: .leading, spacing: 9) {
                    Text(app.isThai ? "เลือกโหมด" : "CHOOSE MODE")
                        .font(.system(size: 13, weight: .heavy))
                        .tracking(0.6)
                        .foregroundColor(NativeTheme.ink)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(NativePresentationMode.allCases) { mode in
                            modeChoice(mode)
                        }
                    }
                }
                .padding(.top, 18)

                Spacer(minLength: 24)
                Text(app.isThai
                     ? "เมื่อเปิดกล้อง ระบบจะบันทึกวิดีโอของ session แบบไม่มีเสียงและอัปโหลดแบบส่วนตัว เพื่อให้นักกายภาพที่เชื่อมกับคุณดูย้อนหลัง"
                     : "Starting the camera records this session without audio and uploads it privately for review by your assigned therapist.")
                    .font(.system(size: 12.5))
                    .foregroundColor(NativeTheme.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)
                if app.selectedExercise?.id == NativeExercise.bottleGrab.id || isSitToStand {
                    Button {
                        showingExampleVideo = true
                    } label: {
                        Label(app.isThai ? "ดูวิดีโอตัวอย่าง" : "Watch example video", systemImage: "play.circle")
                            .font(.system(size: 17, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .foregroundColor(NativeTheme.forest)
                            .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).stroke(NativeTheme.line, lineWidth: 1))
                    }
                    .accessibilityIdentifier("practice.exampleVideo")
                    .padding(.top, 10)
                }
                Button {
                    beginCameraSession()
                } label: {
                    Text(app.isThai ? "เปิดกล้อง" : "Start camera")
                }
                .buttonStyle(NativePrimaryButtonStyle())
                .padding(.top, 10)
            }
            .padding(20)
            .frame(maxWidth: 560, minHeight: 760, alignment: .top)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showingExampleVideo) {
            NativeBottleExampleVideo(
                isThai: app.isThai,
                resourceName: isSitToStand ? "sit-to-stand" : "grabbottle",
                titleThai: isSitToStand ? "ตัวอย่างท่าลุกนั่ง" : "ตัวอย่างท่าหยิบขวด",
                titleEnglish: isSitToStand ? "Sit-to-Stand example" : "Bottle grab example"
            )
        }
    }

    private var activeSurface: some View {
        ZStack {
#if targetEnvironment(simulator)
            simulatorSurface
#else
            deviceSurface
#endif
            VStack(spacing: 0) {
                topBar
                progressPanel
#if DEBUG
                nativeDeveloperDiagnostics
                    .opacity(developerDiagnosticsOpacity)
                    .allowsHitTesting(developerDiagnosticsOpacity > 0)
                    .accessibilityHidden(developerDiagnosticsOpacity == 0)
#endif
                Spacer()
                if app.presentationMode == .audioOnly {
                    audioOnlyHud
                } else if app.presentationMode == .visualOnly {
                    visualOnlyHud
                } else {
                    cueCard
                }
                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
            if phase != .active {
                phaseOverlay
                    // Anchor the positioning card below the progress header.
                    // Its previous full-height frame was centred by the
                    // ZStack, so on compact iPhones it could sit on top of
                    // the cue and camera controls. The overlay now owns only
                    // its intrinsic card height and reserves the lower HUD.
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 164)
                    .padding(.horizontal, 24)
                    .opacity(phase == .countdown ? 1 : positioningCommentOpacity)
                    .accessibilityHidden(phase != .countdown && positioningCommentOpacity == 0)
            }
        }
        .preferredColorScheme(.light)
        .onAppear {
            print("[PhysioAINative] NativePracticeView appeared")
            startedAt = Date()
            phase = .positioning
            countdown = 0
            stableSince = nil
            lastAnnouncedRepTotal = 0
            resetActionCuePresentation(totalReps: 0)
            beginSetupSpeechSession()
            completionPolicy.reset()
            isFinishing = false
            didFinalizeMedia = false
#if targetEnvironment(simulator)
            if isSitToStand {
                sitToStandFixture.start()
            } else {
                fixture.start()
            }
#else
            let exerciseID = app.selectedExercise?.id ?? NativeBottleGrabCapturePolicy.bottleGrabExerciseID
            camera.setCaptureMinimumZoom(NativeBottleGrabCapturePolicy.requestedMinimumZoom(for: exerciseID))
            camera.setExercise(app.selectedExercise ?? .bottleGrab)
            camera.setPracticeCountingEnabled(false)
            camera.requestPermissionAndStart()
            beginSessionMediaRecording()
#endif
            liveAssist.start(exerciseID: app.selectedExercise?.id ?? "bottle_grab", language: app.language, enabled: !app.fixtureMode)
            speech.configure()
        }
        .onDisappear {
#if targetEnvironment(simulator)
            if isSitToStand {
                sitToStandFixture.stop()
            } else {
                fixture.stop()
            }
#else
            mediaSetupTask?.cancel()
            mediaSetupTask = nil
            camera.attachSessionVideoRecorder(nil)
            if !didFinalizeMedia { mediaRecorder?.cancelAndDelete() }
            mediaRecorder = nil
            camera.stop()
#endif
            liveAssist.stop()
            phaseTask?.cancel()
            phaseTask = nil
            finishTask?.cancel()
            finishTask = nil
            speech.stop()
        }
        // The fixture/camera publishes a new output for every frame. Required
        // left-arm + hand QC plus a stable real open-rest baseline decide
        // readiness; PhaseNet remains a parallel sidecar. Full-body framing
        // remains a soft warning so a flickering ankle cannot erase evidence.
        .onChange(of: latestOutput) { _ in
            updatePositioningState()
            updatePresentedActionCue()
            refreshSpeechEpisodes()
            speakRepAnnouncementIfNeeded(totalReps: latestOutput?.totalReps ?? 0)
            evaluateAutomaticPlanCompletion()
        }
#if targetEnvironment(simulator)
        .onChange(of: isSitToStand ? sitToStandFixture.captureSourceGeneration : fixture.captureSourceGeneration) { _ in
            handleCaptureSourceReplacement()
        }
#else
        .onChange(of: camera.captureSourceGeneration) { _ in
            handleCaptureSourceReplacement()
        }
#endif
        .onChange(of: latestOutput?.cue) { cue in
            guard NativeActiveCoachingSpeechPolicy.automaticallySpeaksModelCues,
                  let cue,
                  speechEnabled,
                  app.presentationMode != .visualOnly else {
                return
            }
            refreshSpeechEpisodes()
            _ = submitSpeech(
                semanticKey: "model-cue:\(cue)",
                text: NativeTtsCopyPolicy.modelText(
                    semanticKey: "model-cue:\(cue)",
                    visibleText: app.isThai ? (latestOutput?.cueThai ?? cue) : cue,
                    isThai: app.isThai,
                ),
                priority: .form,
            )
        }
        .onChange(of: secondaryFingerCue?.cueID) { _ in
            guard NativeActiveCoachingSpeechPolicy.automaticallySpeaksHandCues,
                  let cue = secondaryFingerCue,
                  speechEnabled,
                  app.presentationMode != .visualOnly else {
                return
            }
            refreshSpeechEpisodes()
            _ = submitSpeech(
                semanticKey: "hand-cue:\(cue.cueID)",
                text: NativeTtsCopyPolicy.modelText(
                    semanticKey: "hand-cue:\(cue.cueID)",
                    visibleText: app.isThai ? cue.thai : cue.english,
                    isThai: app.isThai,
                ),
                priority: .form,
            )
        }
        .onChange(of: latestSnapshot?.timestampMs) { timestampMs in
            updateNoParticipantEpisode()
            guard NativeSetupSpeechPolicy.shouldRecheckForSnapshot(
                timestampMs: timestampMs,
                lastCheckedTimestampMs: lastSetupSpeechSnapshotTimestamp,
            ) else {
                return
            }
            lastSetupSpeechSnapshotTimestamp = timestampMs
            // Dwell must advance on every observation, even when all values
            // in the Equatable output stay identical while the user holds still.
            updatePresentedActionCue()
            refreshSpeechEpisodes()
            speakSetupStatusIfNeeded(guidance: setupGuidance)
        }
        .onChange(of: presentedActionCue?.semanticKey) { _ in
            speakPresentedActionCueIfNeeded()
        }
        .onChange(of: liveAssist.activeEvent?.id) { _ in
            guard let event = liveAssist.activeEvent,
                  let text = event.text(language: app.language),
                  speechEnabled,
                  app.presentationMode != .visualOnly else {
                return
            }
            refreshSpeechEpisodes()
            _ = submitSpeech(
                semanticKey: "live-assist:\(event.id)",
                text: text,
                priority: .setup,
            )
        }
    }

    private var doseText: String {
        let exercise = app.selectedExercise ?? .bottleGrab
        let item = app.selectedDose
        let reps = item?.reps ?? exercise.reps
        let sets = item?.sets ?? exercise.sets
        let hold = item?.holdSec ?? exercise.holdSec
        return exercise.type == "hold"
            ? (app.isThai ? "\(Int(hold)) วิ · \(sets) เซ็ต" : "\(Int(hold))s hold · \(sets) sets")
            : (app.isThai ? "\(reps) ครั้ง · \(sets) เซ็ต" : "\(reps) reps · \(sets) sets")
    }

    private func readyRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundColor(NativeTheme.ink2).fontWeight(.semibold)
            Spacer()
            Text(value).fontWeight(.heavy).foregroundColor(NativeTheme.ink)
        }
        .font(.system(size: 14))
        .padding(.vertical, 6)
    }

    private func modeChoice(_ mode: NativePresentationMode) -> some View {
        let selected = app.presentationMode == mode
        return Button {
            app.setPresentationMode(mode)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(modeTitle(mode))
                    .font(.system(size: 12.5, weight: .heavy))
                    .foregroundColor(selected ? NativeTheme.inverse : NativeTheme.ink)
                    .lineLimit(2)
                Text(modeHint(mode))
                    .font(.system(size: 10.5))
                    .foregroundColor(selected ? NativeTheme.inverse.opacity(0.76) : NativeTheme.ink2)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
            .padding(10)
            .background(selected ? NativeTheme.forest : NativeTheme.paper, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(selected ? NativeTheme.forest : NativeTheme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func modeTitle(_ mode: NativePresentationMode) -> String {
        switch mode {
        case .standard: return app.isThai ? "มาตรฐาน" : "Standard"
        case .audioOnly: return app.isThai ? "โหมดเสียงอย่างเดียว" : "Audio-Only"
        case .visualOnly: return app.isThai ? "โหมดภาพอย่างเดียว" : "Visual-Only"
        }
    }

    private func modeHint(_ mode: NativePresentationMode) -> String {
        switch mode {
        case .standard: return app.isThai ? "เซสชันสดพร้อมฟีดแบคท่าทางแบบเรียลไทม์" : "Live session with real-time pose feedback"
        case .audioOnly: return app.isThai ? "นำทางด้วยเสียง — สำหรับผู้พิการทางสายตา" : "Voice-guided — for patients with visual impairment"
        case .visualOnly: return app.isThai ? "คำบรรยายและสัญญาณสี — สำหรับผู้พิการทางการได้ยิน" : "Captions & color cues — for deaf / hard-of-hearing"
        }
    }

    private var latestSnapshot: NativeFrameSnapshot? {
#if targetEnvironment(simulator)
        return isSitToStand ? sitToStandFixture.latestSnapshot : fixture.latestSnapshot
#else
        return camera.latestSnapshot
#endif
    }

    private var latestOutput: NativePracticeOutput? {
#if targetEnvironment(simulator)
        if isSitToStand {
            return sitToStandFixture.latestOutput.map { NativePracticeOutput(sitToStand: $0, exercise: app.selectedExercise ?? .sitToStand) }
        }
        return fixture.latestOutput.map(NativePracticeOutput.init(bottle:))
#else
        if isSitToStand {
            return camera.latestSitToStandOutput.map { NativePracticeOutput(sitToStand: $0, exercise: app.selectedExercise ?? .sitToStand) }
        }
        return camera.latestOutput.map(NativePracticeOutput.init(bottle:))
#endif
    }

    private var cameraStatus: String {
#if targetEnvironment(simulator)
        return "Simulator fixture · no physical camera"
#else
        return camera.cameraStatus
#endif
    }

    private var detectorStatus: String {
#if targetEnvironment(simulator)
        return "Simulator fixture · no physical detector"
#else
        return camera.detectorStatus
#endif
    }

    private var inferenceCadenceStatus: String {
#if targetEnvironment(simulator)
        return "Simulator fixture · no physical source cadence"
#else
        return camera.inferenceCadenceStatus
#endif
    }

    private var droppedFrames: Int {
#if targetEnvironment(simulator)
        return 0
#else
        return camera.droppedFrames
#endif
    }

#if targetEnvironment(simulator)
    private var simulatorSurface: some View {
        ZStack {
            NativeTheme.surface3
                .ignoresSafeArea()
            if app.presentationMode != .audioOnly {
                protectedLandmarkOverlay(
                    mirrored: false,
                    lineColor: NativeTheme.ink.opacity(0.72),
                    pointColor: NativeTheme.forest,
                    handLineColor: NativeTheme.forest.opacity(0.86),
                    handPointColor: NativeTheme.ink.opacity(0.72),
                )
            }
        }
        .contentShape(Rectangle())
        .simultaneousGesture(simulatorPinchGesture)
    }
#else
    private var deviceSurface: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.authorization == .authorized {
                CameraPreview(session: camera.captureSession, onFocusPoint: camera.focus(at:))
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .simultaneousGesture(devicePinchGesture)
                if app.presentationMode != .audioOnly {
                    protectedLandmarkOverlay(mirrored: camera.position == .front)
                }
                if !camera.cameraStatus.hasPrefix("Live") && !camera.cameraStatus.hasPrefix("Camera paused") {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.slash")
                            .font(.system(size: 30, weight: .semibold))
                        Text(app.isThai ? "กล้องยังไม่พร้อม" : "Camera is not ready")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text(camera.cameraStatus)
                            .font(.system(size: 13, design: .rounded))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white.opacity(0.72))
                        Button(app.isThai ? "ลองเปิดใหม่" : "Retry camera") {
                            camera.requestPermissionAndStart()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .foregroundColor(.white)
                    .padding(22)
                    .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 20))
                    .padding(28)
                }
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 32))
                    Text(camera.authorization == .denied ? "Camera permission is off" : "Camera permission is required")
                        .font(.headline)
                    if camera.authorization == .denied {
                        Button("Open Settings") {
                            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                            UIApplication.shared.open(url)
                        }
                        .buttonStyle(.borderedProminent)
                    } else {
                        Button("Allow Camera") { camera.requestPermissionAndStart() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .foregroundColor(.white)
            }
        }
    }
#endif

    /// Draw with the original full camera geometry, then mask only the
    /// lower HUD. Reducing the overlay's own frame would rescale every
    /// normalized landmark vertically, which is worse than the overlap it
    /// tries to prevent.
    private func protectedLandmarkOverlay(
        mirrored: Bool,
        lineColor: Color = .white.opacity(0.78),
        pointColor: Color = .mint,
        handLineColor: Color = .mint.opacity(0.95),
        handPointColor: Color = .white,
    ) -> some View {
#if targetEnvironment(simulator)
        let sourceAspectRatio = NativePreviewCoordinateMapper.portraitHDAspectRatio
#else
        let sourceAspectRatio = camera.previewSourceAspectRatio
#endif
        return GeometryReader { proxy in
            LandmarkOverlay(
                snapshot: shouldRenderRawPoseOverlay ? latestSnapshot : nil,
                bottleDetection: bottleDetectorDiagnostics?.acceptedDetection,
                mirrored: mirrored,
                sourceAspectRatio: sourceAspectRatio,
                showsBodyPose: NativeSkeletonOverlayPolicy.showsBodyPose(
                    exerciseID: app.selectedExercise?.id,
                    snapshot: latestSnapshot,
                ),
                lineColor: lineColor,
                pointColor: pointColor,
                handLineColor: handLineColor,
                handPointColor: handPointColor,
            )
            .frame(width: proxy.size.width, height: proxy.size.height)
            .mask(alignment: .top) {
                Rectangle()
                    .frame(
                        width: proxy.size.width,
                        height: NativePracticeOverlayLayout.visibleLandmarkHeight(
                            containerHeight: proxy.size.height,
                            lensMenuOpen: lensMenuOpen,
                        ),
                    )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var topBar: some View {
        let exercise = app.selectedExercise ?? .bottleGrab
        return HStack(spacing: 8) {
            Button {
                app.backHome()
            } label: {
                Text("‹ " + (app.isThai ? exercise.titleThai : exercise.title))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(NativeTheme.ink)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(NativeTheme.paper.opacity(0.94), in: Capsule())
                    .overlay(Capsule().stroke(NativeTheme.line, lineWidth: 1))
            }
            Spacer()
            Text(app.fixtureMode ? (app.isThai ? "โหมดสาธิต" : "Demo mode") : (app.isThai ? "กล้องสด" : "Live camera"))
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(NativeTheme.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(NativeTheme.paper.opacity(0.94), in: Capsule())
                .overlay(Capsule().stroke(NativeTheme.line, lineWidth: 1))
        }
        .padding(.top, 2)
    }

    /// A plan is auto-completable only when its selected native exercise owns
    /// an authoritative repetition total. The chosen exercise—not a Bottle
    /// Grab-only UI branch—defines eligibility, so Sit-to-Stand receives the
    /// same `reps × sets` completion contract while extra practice stays manual.
    private var isPrescribedRepCountPlan: Bool {
        guard app.selectedKind == "plan", app.selectedDose != nil else { return false }
        switch app.selectedExercise?.id {
        case NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
             NativeSitToStandV72AIModule.exerciseID:
            return true
        default:
            return false
        }
    }

    private var prescribedPlanTotalReps: Int? {
        guard isPrescribedRepCountPlan, let exercise = app.selectedExercise else { return nil }
        return max(1, exercise.reps) * max(1, exercise.sets)
    }

    private var prescribedPlanProgressText: String? {
        guard let exercise = app.selectedExercise,
              let total = prescribedPlanTotalReps else {
            return nil
        }
        let repsPerSet = max(1, exercise.reps)
        let totalSets = max(1, exercise.sets)
        let completed = min(total, latestOutput?.totalReps ?? 0)
        if completed >= total {
            return app.isThai
                ? "ครบ \(totalSets)/\(totalSets) เซ็ต · \(completed)/\(total) ครั้ง"
                : "Complete \(totalSets)/\(totalSets) sets · \(completed)/\(total) reps"
        }
        let currentSet = min(totalSets, completed / repsPerSet + 1)
        let currentRep = completed % repsPerSet + 1
        return app.isThai
            ? "เซ็ต \(currentSet)/\(totalSets) · ครั้ง \(currentRep)/\(repsPerSet) · รวม \(completed)/\(total)"
            : "Set \(currentSet)/\(totalSets) · Rep \(currentRep)/\(repsPerSet) · Total \(completed)/\(total)"
    }

    private var progressPanel: some View {
        let output = latestOutput
        let rawReps = app.selectedExercise?.isExperimental == true
            ? (output?.totalReps ?? 0)
            : (output?.reps ?? 0)
        let repTarget = max(1, output?.repsTarget ?? (app.selectedExercise?.reps ?? 1))
        let target = prescribedPlanTotalReps ?? repTarget
        let reps = prescribedPlanTotalReps == nil ? rawReps : min(target, rawReps)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(0..<target, id: \.self) { index in
                    Capsule()
                        .fill(index < min(reps, target) ? NativeTheme.accent : NativeTheme.line.opacity(0.9))
                        .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 4)
                }
            }
            Text(prescribedPlanProgressText
                 ?? (app.selectedExercise?.isExperimental == true
                     ? (app.isThai
                        ? "\(NativeAppBuildProfile.activeContentThai) · \(isSitToStand ? "geometry" : "Bottle proximity") รอบทดลอง \(reps) · ไม่ใช้ตัดสินคะแนน"
                        : "\(NativeAppBuildProfile.activeContentEnglish) · \(isSitToStand ? "geometry" : "Bottle proximity") development reps \(reps) · no score")
                     : (app.isThai ? "ครั้งที่ \(min(reps + 1, target)) จาก \(target) · เซ็ต \((output?.setsDone ?? 0) + 1)/\(output?.totalSets ?? 1)" : "Rep \(min(reps + 1, target)) of \(target) · sets \((output?.setsDone ?? 0) + 1)/\(output?.totalSets ?? 1)")))
                .font(.system(size: 11, weight: .heavy))
                .tracking(0.8)
                .foregroundColor(NativeTheme.ink)
        }
        .padding(.top, 12)
    }

    private var cueCard: some View {
        let therapistText = liveAssist.activeEvent?.text(language: app.language)
        return VStack(alignment: .leading, spacing: 9) {
            Text(liveAssist.activeEvent != nil ? (app.isThai ? "จากนักกายภาพ" : "From Therapist") : (app.isThai ? "คำแนะนำ" : "Cue"))
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.1)
                .foregroundColor(NativeTheme.ink3)
            Text(therapistText ?? actionCueCopy)
                .font(.system(size: 17, weight: .heavy))
                .foregroundColor(NativeTheme.forest)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if liveAssist.activeEvent != nil {
                Text(app.isThai ? "คำแนะนำนี้ไม่เปลี่ยนคะแนน AI" : "This correction does not change the AI score")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(NativeTheme.ink2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeTheme.paper.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(NativeTheme.line, lineWidth: 1))
        .padding(.bottom, 12)
    }

#if DEBUG
    /// A compact physical-device evidence panel. It is compiled only into the
    /// Debug app, lives above the content spacer, and cannot overlap camera
    /// controls or consume touches from the preview. It turns an otherwise
    /// generic “waiting for left hand” message into the exact live gate state.
    private var nativeDeveloperDiagnostics: some View {
        let output = latestOutput
        let handSnapshot = latestSnapshot
        let side = handSnapshot?.handSide ?? output?.handSide ?? "—"
        let source = handSnapshot?.handSideSource ?? output?.handSideSource ?? "—"
        let setup = countReadinessReason ?? output?.setupState ?? "—"
        let phaseContext = output?.setupReason ?? "—"
        let counter = output?.hostCounterStatus ?? "—"
        let counterReason = output?.hostCounterReason
        // Four compact diagnostic rows fit in the same vertical budget as the
        // previous three rows, so this debug-only evidence never pushes the
        // live camera HUD toward the controls below it.
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text("DEBUG")
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .foregroundColor(NativeTheme.inverse)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(NativeTheme.forest, in: Capsule())
                Text("Pose \(output?.posePoints ?? 0)/33 · Hand \(handSnapshot?.hand.count ?? 0)/21 · \(side)")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundColor(NativeTheme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(app.isThai ? "ทดสอบเสียง" : "Test voice") {
                    _ = speech.testVoice(language: app.isThai ? "th-TH" : "en-US")
                }
                .font(.system(size: 10, weight: .bold))
                .buttonStyle(.bordered)
            }
            Text("Gate \(setup) · phase \(phaseContext) · side \(source) · counter \(counter)\(counterReason.map { "/\($0)" } ?? "")")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(NativeTheme.ink2)
                .lineLimit(1)
            Text(isSitToStand
                 ? "V8.0.15 STS \(output?.counterDiagnostic ?? "waiting for pose")"
                 : (isAppV7BottleDetector
                    ? bottleDetectorDebugCopy
                    : "V6.1 \(output?.counterMode ?? "—") · Bottle \(output?.bottleStatus ?? "—") · PhaseNet \(output?.phaseStatus ?? "—") · phase cycles \(output?.phaseDiagnosticCycles ?? 0)"))
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(NativeTheme.ink3)
                .lineLimit(1)
            Text(speech.lastError ?? speech.diagnosticSummary)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(speech.lastError == nil ? NativeTheme.ink3 : .red)
                .lineLimit(1)
            Text(detectorStatus)
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(NativeTheme.ink3)
                .lineLimit(1)
            Text("Cadence \(inferenceCadenceStatus)")
                .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                .foregroundColor(NativeTheme.ink3)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeTheme.paper.opacity(0.94), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(NativeTheme.line, lineWidth: 1))
        .padding(.top, 6)
    }
#endif

    private var audioOnlyHud: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app.isThai ? "โหมดเสียงอย่างเดียว" : "AUDIO-ONLY")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(NativeTheme.mint)
            Text(liveAssist.activeEvent?.text(language: app.language) ?? (latestOutput?.cueThai ?? latestOutput?.cue ?? (app.isThai ? "กำลังรอคำแนะนำเสียง" : "Voice guidance ready")))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                Text(app.isThai ? "เสียงจะนำทางคุณ · กล้องยังทำงานบนเครื่อง" : "Voice guidance is active · camera stays on-device")
            }
            .font(.system(size: 12, design: .rounded))
            .foregroundColor(.white.opacity(0.70))
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
    }

    private var visualOnlyHud: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(app.isThai ? "โหมดภาพอย่างเดียว · ไม่มีเสียง" : "VISUAL-ONLY · SILENT")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(NativeTheme.mint)
            Text(liveAssist.activeEvent?.text(language: app.language) ?? (latestOutput?.cueThai ?? latestOutput?.cue ?? (app.isThai ? "กำลังรอตรวจจับท่าทาง" : "Waiting for pose")))
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Text(app.isThai ? "ทำตามคำแนะนำบนหน้าจอ" : "Follow the on-screen guidance")
                .font(.system(size: 13, design: .rounded))
                .foregroundColor(.white.opacity(0.70))
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 18))
    }

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                if app.selectedExercise?.isExperimental == true {
                    Text("\(latestOutput?.totalReps ?? 0)")
                        .font(.system(size: 20, weight: .heavy, design: .monospaced))
                        .foregroundColor(NativeTheme.forest)
                        .frame(width: 58, height: 58)
                        .background(NativeTheme.brandSoft, in: Circle())
                } else {
                    NativeMiniScoreRing(value: latestOutput?.score, size: 58, color: NativeTheme.forest)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(isPrescribedRepCountPlan
                         ? (app.isThai ? "แผนจากนักกายภาพ" : "THERAPIST PLAN")
                         : (app.selectedExercise?.isExperimental == true
                            ? (app.isThai ? "รอบทดลอง" : "DEV REPS")
                            : (app.isThai ? "ความแม่นยำ" : "ACCURACY")))
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.1)
                        .foregroundColor(NativeTheme.ink3)
            Text(prescribedPlanProgressText
                 ?? (app.selectedExercise?.isExperimental == true
                     ? experimentalStatusHeadline
                     : (latestOutput?.score.map { "\($0)%" } ?? (app.isThai ? "กำลังรอท่าทาง" : "Waiting for pose"))))
                        .font(.system(size: isAppV7BottleDetector ? 11.5 : 15, weight: .heavy, design: .monospaced))
                        .foregroundColor(NativeTheme.ink)
                        .lineLimit(isAppV7BottleDetector ? 1 : nil)
                    if app.selectedExercise?.isExperimental == true && !isPrescribedRepCountPlan {
                        Text(experimentalStatusDetail)
                            .font(.system(size: isAppV7BottleDetector ? 9 : 10, weight: .semibold, design: .monospaced))
                            .foregroundColor(NativeTheme.ink3)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            }
            if lensMenuOpen {
                lensPickerPanel
            }
            // Keep the movement summary independent from camera controls.
            // On a compact iPhone, fitting these three items into one HStack
            // caused the summary and the word “Front” to collapse into a
            // vertical column. Two explicit rows keep both tap targets and
            // Thai/English text legible at every Dynamic Type width.
            HStack(spacing: 10) {
                Button {
#if targetEnvironment(simulator)
                    simulatedPosition = simulatedPosition == .back ? .front : .back
                    simulatedLensTitle = "1×"
                    simulatedZoomFactor = 1
                    replaceSimulatorCaptureSource()
#else
                    camera.switchCamera()
#endif
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.rotate")
                        Text(displayCameraPosition == .back ? "Front" : "Back")
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .nativePracticePill()

                Button {
                    withAnimation(.easeOut(duration: 0.16)) { lensMenuOpen.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "camera.aperture")
                        Text(displayLensTitle)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .nativePracticePill()
            }

            Button {
                requestSessionFinish()
            } label: {
                Label(
                    isFinishing
                        ? (app.isThai ? "กำลังเตรียมสรุป" : "Preparing summary")
                        : (app.isThai ? "จบและดูผล" : "End & view result"),
                    systemImage: "checkmark.circle",
                )
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .nativePracticePill(fill: NativeTheme.forest)
            .disabled(latestOutput == nil || isFinishing)
        }
        .padding(14)
        .background(NativeTheme.paper.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(NativeTheme.line, lineWidth: 1))
        .padding(.bottom, 12)
    }

    private var lensPickerPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(app.isThai ? "เลนส์จากกล้องเครื่องนี้" : "CAMERA LENSES")
                    .font(.system(size: 10, weight: .heavy, design: .monospaced))
                    .tracking(0.8)
                    .foregroundColor(NativeTheme.ink3)
                Spacer()
                Text(app.isThai ? "แตะภาพเพื่อโฟกัส · ใช้สองนิ้วซูม" : "Tap preview to focus · pinch to zoom")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(NativeTheme.ink2)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 8)], spacing: 8) {
                ForEach(displayLensOptions) { option in
                    Button {
#if targetEnvironment(simulator)
                        simulatedLensTitle = option.title
                        simulatedZoomFactor = option.zoomFactor
                        replaceSimulatorCaptureSource()
#else
                        camera.selectLens(option)
#endif
                        withAnimation(.easeOut(duration: 0.16)) { lensMenuOpen = false }
                    } label: {
                        Text(option.title)
                            .font(.system(size: 13, weight: .heavy, design: .rounded))
                            .foregroundColor(option.title == displayLensTitle ? NativeTheme.inverse : NativeTheme.ink)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(option.title == displayLensTitle ? NativeTheme.forest : NativeTheme.surface2, in: Capsule())
                            .overlay(Capsule().stroke(NativeTheme.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(10)
        .background(NativeTheme.surface2.opacity(0.96), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(NativeTheme.line, lineWidth: 1))
    }

#if targetEnvironment(simulator)
    private var displayCameraPosition: NativeCameraPosition { simulatedPosition }
    private var displayLensTitle: String { simulatedLensTitle }
    private var displayLensOptions: [NativeLensOption] {
        NativeBottleGrabCapturePolicy.visibleLensOptions(
            NativeFixtureProvider.simulatedLensOptions,
            exerciseID: app.selectedExercise?.id ?? NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
        )
    }

    private var simulatorPinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let base = simulatedPinchBase ?? simulatedZoomFactor
                if simulatedPinchBase == nil { simulatedPinchBase = base }
                let requested = NativeBottleGrabCapturePolicy.clampedZoom(
                    base * scale,
                    exerciseID: app.selectedExercise?.id ?? NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
                    deviceMinimumZoom: 0.5,
                )
                simulatedZoomFactor = min(8, requested)
                simulatedLensTitle = String(format: "%.1f×", Double(simulatedZoomFactor))
            }
            .onEnded { _ in simulatedPinchBase = nil }
    }
#else
    private var displayCameraPosition: NativeCameraPosition { camera.position }
    private var displayLensTitle: String { camera.selectedLensTitle }
    private var displayLensOptions: [NativeLensOption] {
        NativeBottleGrabCapturePolicy.visibleLensOptions(
            camera.lensOptions,
            exerciseID: app.selectedExercise?.id ?? NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
        )
    }

    private var devicePinchGesture: some Gesture {
        MagnificationGesture()
            .onChanged { scale in
                let base = pinchBaseZoom ?? camera.currentZoomFactor
                if pinchBaseZoom == nil { pinchBaseZoom = base }
                camera.setZoomFactor(
                    NativeBottleGrabCapturePolicy.clampedZoom(
                        base * scale,
                        exerciseID: app.selectedExercise?.id ?? NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
                        deviceMinimumZoom: camera.minZoomFactor,
                    ),
                )
            }
            .onEnded { _ in pinchBaseZoom = nil }
    }
#endif

    private var phaseOverlay: some View {
        VStack(spacing: 12) {
            if phase == .countdown {
                Text("\(countdown)")
                    .font(.system(size: 118, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.45), radius: 12)
            } else {
                Text(positioningOverlayCopy.title)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundColor(NativeTheme.ink)
                Text(positioningOverlayCopy.detail)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(NativeTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .background(.white.opacity(phase == .countdown ? 0.08 : 0.94), in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 360)
        .allowsHitTesting(false)
    }

    private func updatePositioningState() {
        let isTrackingReady = latestOutput?.isTrackingReady == true
        let next = NativePracticeActivationPolicy.phaseAfterReadinessUpdate(
            current: phase,
            isTrackingReady: isTrackingReady,
        )
        if phase == .countdown, next == .positioning {
            // Hard pose/hand QC or the model runtime changed while the
            // patient was counting down. Cancel visibly; do not enter Active
            // with a counter that has already been re-baselined internally.
            resetToPositioning()
            return
        }
        guard phase == .positioning, next == .countdown else {
            if !isTrackingReady { stableSince = nil }
            return
        }
        // `isTrackingReady` means the required pose/hand QC is satisfied and
        // the host completion lane has collected three real open-rest samples.
        // PhaseNet keeps building its causal 30-frame context in parallel, so
        // it must not hold the patient behind the positioning overlay.
        beginCountdown()
    }

    private var positioningOverlayCopy: (title: String, detail: String) {
        if let setupGuidance {
            return (setupGuidance.title, setupGuidance.visualDetail)
        }
        if isSitToStand {
            if latestOutput?.isTrackingReady == true {
                return app.isThai
                    ? ("กำลังเตรียม Sit-to-Stand", "เห็นลำตัว ขา เท้า และเก้าอี้แล้ว กำลังเก็บ baseline ท่านั่ง")
                    : ("Preparing Sit-to-Stand", "Your body, legs, feet, and chair framing are visible; collecting a seated baseline")
            }
            let reason = latestOutput?.setupReason
            if reason == nil || reason == "pose_only_capture_qc_failed" {
                return NativeSitToStandPresencePolicy.waitingForParticipantCopy(isThai: app.isThai)
            }
            if let reason {
                return hardSetupCopy(reason)
            }
            return app.isThai
                ? ("จัดท่าให้พร้อม", "หันกล้องให้เห็นตัวเต็ม เก้าอี้ เข่า และเท้าทั้งสองข้าง")
                : ("Get into position", "Frame your full body, chair, knees, and both feet")
        }
        if let reason = countReadinessReason {
            return hardSetupCopy(reason)
        }
        let state = latestOutput?.setupState ?? "positioning"
        switch state {
        case "baselining":
            return app.isThai
                ? ("กำลังสร้าง baseline", "เห็นแขนและมือซ้ายแล้ว กำลังเก็บข้อมูลท่าทาง")
                : ("Building baseline", "Your left arm and hand are visible; collecting motion data")
        case "buffering_phase_window":
            let count = latestOutput?.bufferedFrames ?? 0
            return app.isThai
                ? ("กำลังเตรียมการติดตาม", "เก็บข้อมูลท่าทาง \(count)/30 เฟรม")
                : ("Preparing motion tracking", "Collecting motion data: \(count)/30 frames")
        case "phase_reacquiring":
            return app.isThai
                ? ("กำลังปรับข้อมูลการเคลื่อนไหว", "ค้างแขนและมือซ้ายให้นิ่งสักครู่ ระบบนับรอบยังใช้ข้อมูลจริงจากกล้อง")
                : ("Refreshing motion context", "Hold your left arm and hand still briefly; the live geometry counter stays on real camera input.")
        case "tracking":
            return app.isThai
                ? ("กำลังตรวจสอบการเคลื่อนไหว", "เริ่มอ้ามือ เอื้อม กำ แล้วปล่อยขวด")
                : ("Checking the movement", "Open your hand, reach, grasp, then release the bottle")
        case "unavailable":
            return app.isThai
                ? ("ยังไม่พร้อมใช้งาน", "โมเดลทดลองบนเครื่องไม่พร้อม กรุณาเริ่มใหม่")
                : ("Not ready", "The local experimental model is unavailable. Please restart.")
        default:
            return app.isThai
                ? ("จัดท่าให้พร้อม", "ให้แขนและมือซ้ายเห็นชัดในกรอบ แล้วค้างไว้สักครู่")
                : ("Get into position", "Keep your left arm and hand clearly in frame, then hold still")
        }
    }

    private var setupCueCopy: String {
        if let setupGuidance {
            return setupGuidance.visualDetail
        }
        if isSitToStand {
            if latestOutput?.isTrackingReady == true {
                return app.isThai
                    ? "ให้เห็นศีรษะ ไหล่ สะโพก เข่า เท้า และเก้าอี้ในกรอบกล้อง"
                    : "Keep your head, shoulders, hips, knees, feet, and chair visible in the camera frame."
            }
            let reason = latestOutput?.setupReason
            if reason == nil || reason == "pose_only_capture_qc_failed" {
                return NativeSitToStandPresencePolicy.waitingForParticipantCopy(isThai: app.isThai).detail
            }
            if let reason {
                return hardSetupCopy(reason).detail
            }
            return app.isThai
                ? "ให้เห็นศีรษะ ไหล่ สะโพก เข่า เท้า และเก้าอี้ในกรอบกล้อง"
                : "Keep your head, shoulders, hips, knees, feet, and chair visible in the camera frame."
        }
        if let reason = countReadinessReason {
            return hardSetupCopy(reason).detail
        }
        if latestOutput?.framingWarning != nil {
            return app.isThai
                ? "เห็นแขนและมือซ้ายแล้ว ลองถอยให้เห็นตัวเพิ่มขึ้นเพื่อจัดกรอบที่ดีขึ้น"
                : "Your arm and hand are visible. Step back slightly for a better full-body frame."
        }
        return app.isThai
            ? "ให้แขนและมือซ้ายเห็นชัดในกรอบ"
            : "Keep your left arm and hand clearly in frame."
    }

    private var actionCueCopy: String {
        if let presentedActionCue {
            return presentedActionCue.visualText
        }
        return modelCueCopy ?? setupCueCopy
    }

    private var modelCueCopy: String? {
        if app.isThai {
            return secondaryFingerCue?.thai ?? latestOutput?.cueThai ?? latestOutput?.cue
        }
        return secondaryFingerCue?.english ?? latestOutput?.cue ?? latestOutput?.cueThai
    }

    private func hardSetupCopy(_ reason: String) -> (title: String, detail: String) {
        if isSitToStand {
            if reason == "source_mirrored" {
                return app.isThai
                    ? ("เปลี่ยนเป็นภาพไม่กลับด้าน", "ใช้กล้องหลังหรือภาพที่ไม่กลับซ้าย–ขวา แล้วจัดให้เห็นตัวเต็ม เก้าอี้ เข่า และเท้าทั้งสองข้าง")
                    : ("Use an unmirrored view", "Use the rear camera or an unmirrored source, then frame your full body, chair, knees, and both feet.")
            }
            return app.isThai
                ? ("รอข้อมูลทั้งตัว", "ให้เห็นศีรษะ ไหล่ สะโพก เข่า เท้า และเก้าอี้ในกรอบกล้อง")
                : ("Waiting for full-body data", "Keep your head, shoulders, hips, knees, feet, and chair visible in the camera frame.")
        }
        switch reason {
        case "missing_left_hand", "missing_hand_side", "wrong_anatomical_side", "unreliable_hand_side", "unassociated_left_hand":
            return app.isThai
                ? ("รอข้อมูลมือซ้าย", "หันฝ่ามือซ้ายเข้าหากล้อง และให้เห็นมือทั้งมือ")
                : ("Waiting for left-hand data", "Show your full left hand clearly to the camera.")
        default:
            return app.isThai
                ? ("รอข้อมูลแขนซ้าย", "ให้ไหล่ ข้อศอก ข้อมือ และมือซ้ายเห็นชัดในกรอบ")
                : ("Waiting for left-arm data", "Keep your left shoulder, elbow, wrist, and hand visible.")
        }
    }

    private func beginCountdown() {
        guard phase == .positioning else { return }
        phase = .countdown
        countdown = 3
        stableSince = nil
        if app.presentationMode == .audioOnly { speak("3") }
        phaseTask?.cancel()
        phaseTask = Task { @MainActor in
            for value in stride(from: 2, through: 1, by: -1) {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                countdown = value
                if app.presentationMode == .audioOnly { speak("\(value)") }
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard NativePracticeActivationPolicy.phaseAtCountdownCompletion(
                isTrackingReady: latestOutput?.isTrackingReady == true,
            ) == .active else {
                resetToPositioning()
                return
            }
            countdown = 0
            phase = .active
            beginActivePracticeCounting()
            refreshSpeechEpisodes()
            speakPresentedActionCueIfNeeded()
        }
    }

    private func beginActivePracticeCounting() {
#if targetEnvironment(simulator)
        setSimulatorCountingEnabled(true)
#else
        camera.setPracticeCountingEnabled(true)
#endif
        lastAnnouncedRepTotal = 0
        actionCuePresentation.rebase(totalReps: latestOutput?.totalReps ?? 0)
    }

    private func handleCaptureSourceReplacement() {
        // A camera, physical lens, or virtual-lens segment change invalidates
        // every partial geometry/window. Do not leave the active HUD showing
        // a silently unarmed counter; visibly return to setup and countdown.
        speech.resetPresentationState()
        guard isRunning, phase != .positioning else { return }
        resetToPositioning()
    }

    private func resetToPositioning() {
        phaseTask?.cancel()
        phaseTask = nil
        countdown = 0
        stableSince = nil
        phase = .positioning
        speech.resetPresentationState()
        lastAnnouncedRepTotal = 0
        resetActionCuePresentation(totalReps: 0)
        beginSetupSpeechSession()
#if targetEnvironment(simulator)
        setSimulatorCountingEnabled(false)
#else
        camera.setPracticeCountingEnabled(false)
#endif
    }

#if targetEnvironment(simulator)
    private func replaceSimulatorCaptureSource() {
        if isSitToStand {
            sitToStandFixture.replaceCaptureSource()
        } else {
            fixture.replaceCaptureSource()
        }
    }

    private func setSimulatorCountingEnabled(_ enabled: Bool) {
        if isSitToStand {
            sitToStandFixture.setPracticeCountingEnabled(enabled)
        } else {
            fixture.setPracticeCountingEnabled(enabled)
        }
    }
#endif

    private func nativeStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.48))
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
    }

    @discardableResult
    private func speak(_ text: String) -> Bool {
        submitSpeech(
            semanticKey: "system:\(text)",
            text: text,
            priority: .system,
        )
    }

    @discardableResult
    private func submitSpeech(
        semanticKey: String,
        text: String,
        priority: NativeSpeechRequestPriority,
        repeatPolicy: NativeSpeechRepeatPolicy = .oncePerEpisode,
    ) -> Bool {
        speech.submit(
            NativeSpeechRequest(
                semanticKey: semanticKey,
                text: text,
                language: app.isThai ? "th-TH" : "en-US",
                priority: priority,
                observedAt: Date().timeIntervalSinceReferenceDate,
                repeatPolicy: repeatPolicy,
            ),
        )
    }

    private func updatePresentedActionCue() {
        guard NativeGuidedStartPresentationPhasePolicy.showsActionCue(in: phase) else { return }
        let fallback = modelCueCopy
            ?? (app.isThai ? "กำลังติดตามท่า" : "Tracking movement.")
        presentedActionCue = actionCuePresentation.observe(
            rawStatus: latestOutput?.actionCueStatus ?? latestOutput?.hostCounterStatus,
            totalReps: latestOutput?.totalReps ?? 0,
            isSitToStand: isSitToStand,
            isThai: app.isThai,
            fallback: fallback,
            now: Date().timeIntervalSinceReferenceDate,
        )
    }

    private func resetActionCuePresentation(totalReps: Int) {
        actionCuePresentation.reset(totalReps: totalReps)
        presentedActionCue = nil
    }

    private func refreshSpeechEpisodes() {
        var keys = Set<String>()
        if let cue = latestOutput?.cue, !cue.isEmpty {
            keys.insert("model-cue:\(cue)")
        }
        if let cueID = secondaryFingerCue?.cueID, !cueID.isEmpty {
            keys.insert("hand-cue:\(cueID)")
        }
        if let setupGuidance {
            keys.insert("setup:\(setupGuidance.semanticKey)")
        }
        if let action = presentedActionCue, action.speechText != nil {
            keys.insert("action:\(action.semanticKey)")
        }
        if let eventID = liveAssist.activeEvent?.id, !eventID.isEmpty {
            keys.insert("live-assist:\(eventID)")
        }
        speech.observeVisibleKeys(keys)
    }

    private func speakPresentedActionCueIfNeeded() {
        guard NativeGuidedStartPresentationPhasePolicy.speaksActionCue(in: phase),
              speechEnabled,
              app.presentationMode != .visualOnly,
              let action = presentedActionCue,
              let text = action.speechText else { return }
        _ = submitSpeech(
            semanticKey: "action:\(action.semanticKey)",
            text: text,
            priority: .setup,
        )
    }

    private func speakRepAnnouncementIfNeeded(totalReps: Int) {
        let normalizedTotal = max(0, totalReps)
        if normalizedTotal < lastAnnouncedRepTotal {
            lastAnnouncedRepTotal = normalizedTotal
            return
        }
        guard phase == .active,
              speechEnabled,
              app.presentationMode != .visualOnly,
              normalizedTotal > lastAnnouncedRepTotal else {
            return
        }
        lastAnnouncedRepTotal = normalizedTotal
        let status = "counted_rep_\(normalizedTotal)"
        _ = submitSpeech(
            semanticKey: "rep:\(app.selectedExercise?.id ?? "exercise"):\(normalizedTotal)",
            text: NativeTtsCopyPolicy.motionText(
                status: status,
                isSitToStand: isSitToStand,
                isThai: app.isThai,
                fallback: status,
            ),
            priority: .lifecycle,
        )
    }

    private func evaluateAutomaticPlanCompletion() {
        guard phase == .active,
              let target = prescribedPlanTotalReps,
              let completed = latestOutput?.totalReps else {
            return
        }
        let decision = completionPolicy.observe(
            isPrescribedPlan: isPrescribedRepCountPlan,
            completedReps: completed,
            targetTotalReps: target,
        )
        if decision == .finishOnce {
            requestSessionFinish()
        }
    }

    private func requestSessionFinish() {
        guard !isFinishing else { return }
        isFinishing = true
#if targetEnvironment(simulator)
        finishCurrentSession()
#else
        // Freeze count admission before allowing the paired Hand callback a
        // short grace period. This prevents an additional repetition from
        // entering while the V8 derived record finishes its final join.
        camera.setPracticeCountingEnabled(false)
        finishTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            finishCurrentSession()
        }
#endif
    }

    private func finishCurrentSession() {
        var evidence: Data?
#if !targetEnvironment(simulator)
        let exerciseID = app.selectedExercise?.id ?? NativeBottleGrabCapturePolicy.bottleGrabExerciseID
        if exerciseID == NativeBottleGrabCapturePolicy.bottleGrabExerciseID {
            do {
                evidence = try camera.encodedFinalizedBottleGrabRuleBasedSession()
            } catch {
                app.persistenceMessage = app.isThai
                    ? "เตรียม Evidence JSON ไม่สำเร็จ: \(error.localizedDescription)"
                    : "Evidence JSON could not be prepared: \(error.localizedDescription)"
            }
        } else if exerciseID == NativeSitToStandV72AIModule.exerciseID {
            do {
                evidence = try camera.encodedFinalizedSitToStandRuleBasedSession()
            } catch {
                app.persistenceMessage = app.isThai
                    ? "เตรียม Evidence JSON ท่าลุก-นั่งไม่สำเร็จ: \(error.localizedDescription)"
                    : "Sit-to-Stand Evidence JSON could not be prepared: \(error.localizedDescription)"
            }
        }
#endif
        let output = rawBottleOutput
#if targetEnvironment(simulator)
        app.finishPractice(
            cuesPresented: 0,
            startedAt: startedAt,
            output: output,
            completedReps: latestOutput?.totalReps,
            ruleBasedEvidenceJSON: evidence
        )
#else
        didFinalizeMedia = true
        mediaSetupTask?.cancel()
        mediaSetupTask = nil
        camera.attachSessionVideoRecorder(nil)
        guard let recorder = mediaRecorder, let pendingMediaSessionID = mediaSessionID else {
            app.finishPractice(
                cuesPresented: 0,
                startedAt: startedAt,
                output: output,
                completedReps: latestOutput?.totalReps,
                ruleBasedEvidenceJSON: evidence
            )
            return
        }
        mediaRecorder = nil
        mediaSessionID = nil
        recorder.finish { result in
            let linkedMediaSessionID: String?
            if case .success(let capture?) = result, !capture.segments.isEmpty {
                NativeSessionMediaUploader.shared.enqueue(capture)
                linkedMediaSessionID = pendingMediaSessionID
            } else {
                linkedMediaSessionID = nil
            }
            app.finishPractice(
                cuesPresented: 0,
                startedAt: startedAt,
                output: output,
                completedReps: latestOutput?.totalReps,
                ruleBasedEvidenceJSON: evidence,
                sessionID: linkedMediaSessionID,
                mediaSessionID: linkedMediaSessionID
            )
        }
#endif
    }

#if !targetEnvironment(simulator)
    private func beginSessionMediaRecording() {
        guard !app.fixtureMode, let exerciseID = app.selectedExercise?.id else { return }
        let nextMediaSessionID = UUID().uuidString.lowercased()
        mediaSetupTask?.cancel()
        mediaSetupTask = Task { @MainActor in
            do {
                try await NativeSessionMediaAPIClient().start(
                    mediaSessionID: nextMediaSessionID,
                    exerciseID: exerciseID
                )
                guard !Task.isCancelled, !didFinalizeMedia else { return }
                let recorder = NativeSessionVideoRecorder()
                try recorder.start(mediaSessionID: nextMediaSessionID)
                mediaRecorder = recorder
                mediaSessionID = nextMediaSessionID
                camera.attachSessionVideoRecorder(recorder)
            } catch is CancellationError {
                return
            } catch {
#if DEBUG
                print("[PhysioAI Media] Recording unavailable: \(error.localizedDescription)")
#endif
            }
        }
    }
#endif

    private var rawBottleOutput: NativeBottleGrabOutput? {
#if targetEnvironment(simulator)
        return isSitToStand ? nil : fixture.latestOutput
#else
        return isSitToStand ? nil : camera.latestOutput
#endif
    }

    private func speakSetupStatusIfNeeded(guidance: NativeSetupGuidance?) {
        guard isRunning,
              let setupSpeechSessionStartedAt else {
            return
        }
        let now = Date()
        guard now.timeIntervalSince(setupSpeechSessionStartedAt) >= NativeSetupSpeechPolicy.initialSettlingInterval else {
            return
        }
        guard let guidance else { return }
        let reason = guidance.semanticKey
        guard NativeSetupSpeechPolicy.shouldSpeak(
            reason: reason,
            speechEnabled: speechEnabled,
            visualOnly: app.presentationMode == .visualOnly,
            lastReason: lastSpokenSetupReason,
            elapsedSinceLastSpeech: now.timeIntervalSince(lastSetupSpokenAt),
        ) else {
            return
        }
        let semanticReason = guidance.semanticKey
        let isNoParticipantReminder = semanticReason == NativeSetupSpeechPolicy.noParticipantSemanticReason
            && NativeSetupSpeechPolicy.isNoParticipant(lastSpokenSetupReason)
            && lastSpokenSetupReason != NativeSetupSpeechPolicy.noParticipantReminderDeliveredKey
        guard submitSpeech(
            semanticKey: "setup:\(semanticReason)",
            text: guidance.detail,
            priority: .setup,
            repeatPolicy: semanticReason == NativeSetupSpeechPolicy.noParticipantSemanticReason
                ? .reminder(after: NativeSetupSpeechPolicy.noParticipantReminderInterval)
                : .oncePerEpisode,
        ) else {
            return
        }
        lastSpokenSetupReason = isNoParticipantReminder
            ? NativeSetupSpeechPolicy.noParticipantReminderDeliveredKey
            : semanticReason
        lastSetupSpokenAt = now
    }

    private func beginCameraSession() {
        isRunning = true
        lastAnnouncedRepTotal = 0
        resetActionCuePresentation(totalReps: 0)
        beginSetupSpeechSession()
    }

    private func beginSetupSpeechSession() {
        setupSpeechSessionStartedAt = Date()
        participantPresenceSince = nil
        lastSpokenSetupReason = nil
        lastSetupSpokenAt = .distantPast
        lastSetupSpeechSnapshotTimestamp = nil
    }

    private func updateNoParticipantEpisode() {
        guard isRunning else { return }
        guard !hasObservedNoParticipant else {
            participantPresenceSince = nil
            return
        }
        guard NativeSetupSpeechPolicy.isNoParticipant(lastSpokenSetupReason) else { return }
        let now = Date()
        if participantPresenceSince == nil {
            participantPresenceSince = now
            return
        }
        guard let participantPresenceSince,
              now.timeIntervalSince(participantPresenceSince) >= NativeSetupSpeechPolicy.participantPresenceRearmInterval else {
            return
        }
        lastSpokenSetupReason = nil
        lastSetupSpokenAt = .distantPast
    }
}

private extension View {
    func nativePracticePill(fill: Color = .black, foreground: Color = .white) -> some View {
        font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundColor(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(fill.opacity(0.70), in: Capsule())
    }
}

private struct NativeMiniScoreRing: View {
    let value: Int?
    let size: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(NativeTheme.brandSoft, lineWidth: 7)
            if let value {
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, value))) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(value.map { "\($0)%" } ?? "—")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundColor(color)
        }
        .frame(width: size, height: size)
    }
}
