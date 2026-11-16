import Foundation
import AVFoundation

/// Reusable V7 Bottle Grab AI façade. Consumers that need the whole module
/// call this boundary instead of wiring the detector, Pose/Hand pipeline,
/// Capture-QC, proximity counter, PhaseNet context, and finger-comment branch
/// independently.
final class NativeBottleGrabV7AIModule {
    static let moduleID = "bottle_grab_v7_ai_module"
    static let moduleVersion = "1.1.0-dev"
    static let baselineID = "bottle_grab_native_v7_ai_module_baseline_5"
    static let baselineNumber = 5
    static let baselineVersion = "app-v7-bottle-detector-pose-proximity-0.1.0-dev"
    static let decisionScope = "experimental_local_device_proximity_only"
    static let engineIDs = [
        "bottle_grab_v7_bottle_detector",
        "bottle_grab_v7_stable_bottle_anchor_v1",
        "mediapipe_pose_full_v1",
        "mediapipe_hand_landmarker_secondary_v1",
        "pose_hand_proxy_v1",
        "bottle_grab_v7_pose_proximity_counter_v1",
        "hand_finger_quality_comment_v1",
        "bottle_grab_phasenet_v2_context_v1",
    ]
    /// V8 adds an observer beside, not inside, the frozen Baseline #5
    /// decision engines. It cannot alter the module's counter, cue, score, or
    /// PhaseNet output and exports no data by itself.
    static let supplementalObserverEngineIDs = [
        NativeFaultEvidenceV8Module.moduleID,
        NativeRuleBasedSessionV8Module.moduleID,
    ]

    typealias OutputHandler = (NativeFrameSnapshot, NativeBottleGrabOutput) -> Void
    typealias HandCommentHandler = (NativeFrameSnapshot, NativeBottleGrabCuePreview?) -> Void
    typealias BottleDiagnosticsHandler = (NativeBottleDetectorDiagnostics) -> Void

    private let pipeline: MediaPipePipeline
    private let engine: NativeBottleGrabEngine
    private let onOutput: OutputHandler
    private let onHandComment: HandCommentHandler
    private let faultEvidence: NativeFaultEvidenceV8Module
    private let ruleBasedSession: NativeRuleBasedSessionV8Module
    /// This owns only the optional finger-wrap cue. It is deliberately not the
    /// authoritative V7 counter engine and cannot mutate its repetitions.
    private let handCommentAdapter = NativeBottleGrabRuleWrapCuePreviewAdapter()
    private let handCommentLock = NSLock()

    var setupError: String? { pipeline.setupError }
    var inferenceDelegateName: String { pipeline.inferenceDelegateName }

    func localFaultEvidenceRecord() -> NativeFaultEvidenceRecord {
        faultEvidence.localRecord()
    }

    func encodedLocalFaultEvidenceRecord() throws -> Data {
        try faultEvidence.encodedLocalRecord()
    }

    /// Non-mutating local validation/export surface. Unlike the historical
    /// `localFaultEvidenceRecord()` finalizer, this can be read while the
    /// camera is live without splitting an active qualified comment event.
    func currentFaultEvidenceRecord() -> NativeFaultEvidenceRecord {
        faultEvidence.currentRecord()
    }

    func encodedCurrentFaultEvidenceRecord() throws -> Data {
        try faultEvidence.encodedCurrentRecord()
    }

    /// Local-only V8 JSON for a host or the bundled visualizer. It contains
    /// derived completed-repetition rule evidence and never sends data.
    func currentRuleBasedSessionRecord() -> NativeRuleBasedSessionRecord {
        ruleBasedSession.currentRecord()
    }

    func encodedCurrentRuleBasedSessionRecord() throws -> Data {
        try ruleBasedSession.encodedCurrentRecord()
    }

    /// Final local read used only after the host stops the prescribed session.
    /// Any still-unpaired derived output frame is completed as no fault rather
    /// than inventing an incorrect repetition.
    func encodedFinalizedCurrentRuleBasedSessionRecord() throws -> Data {
        try ruleBasedSession.encodedFinalizedCurrentRecord()
    }

    init(
        onOutput: @escaping OutputHandler = { _, _ in },
        onHandComment: @escaping HandCommentHandler = { _, _ in },
        onBottleDiagnostics: @escaping BottleDiagnosticsHandler = { _ in },
        onStatus: @escaping (String) -> Void = { _ in },
    ) {
        let decisionEngine = NativeBottleGrabEngine(counterMode: .bottleDetectorProximity)
        let evidenceModule = NativeFaultEvidenceV8Module(exerciseID: "bottle_grab")
        let ruleSession = NativeRuleBasedSessionV8Module(exerciseID: "bottle_grab")
        self.engine = decisionEngine
        self.faultEvidence = evidenceModule
        self.ruleBasedSession = ruleSession
        self.onOutput = onOutput
        self.onHandComment = onHandComment
        self.pipeline = MediaPipePipeline(
            onSnapshot: { snapshot in
                let output = decisionEngine.ingest(snapshot)
                evidenceModule.ingestOutput(snapshot: snapshot, output: output)
                ruleSession.ingestOutput(snapshot: snapshot, output: output)
                onOutput(snapshot, output)
            },
            onHandCommentSnapshot: { [handCommentAdapter, handCommentLock, onHandComment, evidenceModule, ruleSession] snapshot in
                handCommentLock.lock()
                let cue = handCommentAdapter.ingest(snapshot)
                handCommentLock.unlock()
                evidenceModule.ingestHandComment(snapshot: snapshot, cue: cue)
                ruleSession.ingestHandComment(snapshot: snapshot, cue: cue)
                onHandComment(snapshot, cue)
            },
            onBottleDiagnostics: { onBottleDiagnostics($0) },
            onStatus: onStatus,
            enableBottleDetector: true,
        )
    }

    func setCountingEnabled(_ enabled: Bool) {
        engine.setCountingEnabled(enabled)
    }

    /// Passes the selected plan's effective dose to the existing engine without
    /// changing detection, Capture-QC, thresholds, PhaseNet, or TTS.
    func configure(exercise: NativeExercise) {
        engine.configure(exercise: exercise)
    }

    func process(
        sampleBuffer: CMSampleBuffer,
        timestampMs: Int,
        inputIsMirrored: Bool,
        sourceGeneration: Int,
    ) {
        pipeline.process(
            sampleBuffer: sampleBuffer,
            timestampMs: timestampMs,
            inputIsMirrored: inputIsMirrored,
            sourceGeneration: sourceGeneration,
        )
    }

    func resetPendingFrames(sourceGeneration: Int) {
        pipeline.resetPendingFrames(sourceGeneration: sourceGeneration)
        engine.resetForNewCaptureSource()
        faultEvidence.resetForNewCaptureSource()
        ruleBasedSession.resetForNewCaptureSource()
        handCommentLock.lock()
        handCommentAdapter.reset()
        handCommentLock.unlock()
    }

    func resetForNewCaptureSource() {
        engine.resetForNewCaptureSource()
        faultEvidence.resetForNewCaptureSource()
        ruleBasedSession.resetForNewCaptureSource()
        handCommentLock.lock()
        handCommentAdapter.reset()
        handCommentLock.unlock()
    }

    @discardableResult
    func ingest(_ snapshot: NativeFrameSnapshot) -> NativeBottleGrabOutput {
        let output = engine.ingest(snapshot)
        faultEvidence.ingestOutput(snapshot: snapshot, output: output)
        ruleBasedSession.ingestOutput(snapshot: snapshot, output: output)
        ruleBasedSession.ingestHandComment(snapshot: snapshot, cue: nil)
        onOutput(snapshot, output)
        return output
    }
}
