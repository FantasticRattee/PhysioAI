import Foundation
import simd

/// Numeric, on-device-only evidence exchanged between MediaPipe and the native
/// Bottle Grab sidecar. It intentionally contains no image bytes.
struct NativeLandmark: Equatable {
    let x: Float
    let y: Float
    let z: Float
    let visibility: Float
}

struct NativeFrameSnapshot: Equatable {
    let timestampMs: Int
    /// Capture-source identity assigned by `CameraSession`. It is deliberately
    /// separate from `timestampMs`: a lens/camera replacement resets model
    /// state, and late MediaPipe callbacks from the previous source must be
    /// rejected even if their timestamp is otherwise monotonic.
    let sourceGeneration: Int
    /// Exact camera-buffer mirror state. Pose-only Sit-to-Stand reference
    /// geometry refuses a mirrored source instead of silently reversing its
    /// camera-plane feature contract.
    let inputIsMirrored: Bool
    let pose: [NativeLandmark]
    let hand: [NativeLandmark]
    let handSide: String?
    /// Detector/geometry decision provenance used only by the developer
    /// diagnostics HUD. It is not an input feature, model output, or score.
    let handSideSource: String?
    /// Aggregate-only trace of every Hand Landmarker candidate considered for
    /// this frame. It is DEBUG evidence, not a model feature or session field.
    let handCandidateTrace: String?
    let handScore: Float
    let detectorLatencyMs: Double
    /// V7's selected bottle ROI from the same capture generation. V5/V6
    /// snapshots leave this nil and retain their existing Pose+Hand contract.
    let bottleDetection: NativeBottleDetection?
    /// V7.3.4's confirmed checkpoint. Unlike `bottleDetection`, its original
    /// callback timestamp may be older than the fresh detector window.
    let bottleAnchor: NativeBottleAnchor?

    init(
        timestampMs: Int,
        sourceGeneration: Int = 0,
        inputIsMirrored: Bool = false,
        pose: [NativeLandmark],
        hand: [NativeLandmark],
        handSide: String?,
        handSideSource: String? = nil,
        handCandidateTrace: String? = nil,
        handScore: Float,
        detectorLatencyMs: Double,
        bottleDetection: NativeBottleDetection? = nil,
        bottleAnchor: NativeBottleAnchor? = nil,
    ) {
        self.timestampMs = timestampMs
        self.sourceGeneration = sourceGeneration
        self.inputIsMirrored = inputIsMirrored
        self.pose = pose
        self.hand = hand
        self.handSide = handSide
        self.handSideSource = handSideSource
        self.handCandidateTrace = handCandidateTrace
        self.handScore = handScore
        self.detectorLatencyMs = detectorLatencyMs
        self.bottleDetection = bottleDetection
        self.bottleAnchor = bottleAnchor
    }
}

/// Selects which repetition policy owns the native Bottle Grab total.
/// App-V5 keeps the PhaseNet full-cycle policy; App V6 makes the direct
/// geometry policy authoritative while retaining PhaseNet as a parallel
/// diagnostic/context stream.
enum NativeBottleGrabCounterMode: String, Equatable {
    case phaseNetFullCycle = "phasenet_full_cycle"
    case parallelGeometryFirst = "parallel_geometry_first"
    case bottleDetectorProximity = "bottle_detector_proximity"
}

struct NativeBottleGrabOutput: Equatable {
    let phase: String?
    let captureQC: String
    let cue: String?
    let cueThai: String?
    let bufferedFrames: Int
    let assessableFrames: Int
    let posePoints: Int
    let handPoints: Int
    let handSide: String?
    /// The hand-side resolver source for DEBUG diagnostics. It must not be
    /// surfaced as a patient result or persisted in a session.
    let handSideSource: String?
    let detectorLatencyMs: Double
    /// V7 object-detector state. Nil on V5/V6 routes.
    let bottleStatus: String?
    let bottleInZone: Bool?
    let bottleScore: Float?
    let modelStatus: String
    /// The latest native tracker state, for diagnostic UI/tests. This is not
    /// a model prediction and must never be mistaken for a clinical result.
    let phaseStatus: String
    /// Aggregate-safe native host-counter state. In V5 this remains diagnostic;
    /// in App V6 it is the experimental patient-visible development rep source
    /// (still not a score, persisted adherence result, or clinical decision).
    let hostCounterStatus: String?
    let hostCounterReason: String?
    /// Geometry-cycle total. In App-V5 this is diagnostic; in App V6 it is the
    /// authoritative total because Geometry First owns the repetition boundary.
    let hostDiagnosticCycles: Int?
    /// PhaseNet full-cycle total retained as a comparison/diagnostic stream in
    /// App V6. It never changes the V6 authoritative geometry total.
    let phaseDiagnosticCycles: Int?
    let counterMode: String
    let setupState: String
    let setupReason: String?
    /// Soft full-body framing feedback. Unlike `setupReason`, this never
    /// blocks a valid frozen PhaseNet feature frame from being sampled.
    let framingWarning: String?
    /// Optional development provenance for a cue. This is intentionally
    /// separate from PhaseNet, form correctness, clinical logic, and scoring.
    let cueProvenance: String?
    /// Provenance for the sole patient-visible experimental repetition
    /// policy. This identifies the lifecycle decoder, not a clinical/form
    /// result and not a Baseline #4 deployment claim.
    let repCounterProvenance: String?
    let isTrackingReady: Bool
    let phaseConfidence: Float?
    let score: Int?
    let poseScore: Int?
    let primaryAngle: Float?
    let targetAngle: Float?
    let reps: Int
    /// Development-only completed movement cycles. This remains independent of
    /// score, form class, correctness, and persisted adherence.
    let totalReps: Int
    let repsTarget: Int
    let setsDone: Int
    let totalSets: Int
    let formClass: String?
    let hasPose: Bool
    let finished: Bool
    let experimental: Bool

    init(
        phase: String?,
        captureQC: String,
        cue: String?,
        cueThai: String?,
        bufferedFrames: Int,
        assessableFrames: Int,
        posePoints: Int,
        handPoints: Int,
        handSide: String?,
        handSideSource: String? = nil,
        detectorLatencyMs: Double,
        bottleStatus: String? = nil,
        bottleInZone: Bool? = nil,
        bottleScore: Float? = nil,
        modelStatus: String,
        phaseStatus: String = "positioning",
        hostCounterStatus: String? = nil,
        hostCounterReason: String? = nil,
        hostDiagnosticCycles: Int? = nil,
        phaseDiagnosticCycles: Int? = nil,
        counterMode: String = NativeBottleGrabCounterMode.phaseNetFullCycle.rawValue,
        setupState: String = "positioning",
        setupReason: String? = nil,
        framingWarning: String? = nil,
        cueProvenance: String? = nil,
        repCounterProvenance: String? = nil,
        isTrackingReady: Bool = false,
        phaseConfidence: Float? = nil,
        score: Int? = nil,
        poseScore: Int? = nil,
        primaryAngle: Float? = nil,
        targetAngle: Float? = nil,
        reps: Int = 0,
        totalReps: Int = 0,
        repsTarget: Int = 1,
        setsDone: Int = 0,
        totalSets: Int = 1,
        formClass: String? = nil,
        hasPose: Bool = false,
        finished: Bool = false,
        experimental: Bool = true,
    ) {
        self.phase = phase
        self.captureQC = captureQC
        self.cue = cue
        self.cueThai = cueThai
        self.bufferedFrames = bufferedFrames
        self.assessableFrames = assessableFrames
        self.posePoints = posePoints
        self.handPoints = handPoints
        self.handSide = handSide
        self.handSideSource = handSideSource
        self.detectorLatencyMs = detectorLatencyMs
        self.bottleStatus = bottleStatus
        self.bottleInZone = bottleInZone
        self.bottleScore = bottleScore
        self.modelStatus = modelStatus
        self.phaseStatus = phaseStatus
        self.hostCounterStatus = hostCounterStatus
        self.hostCounterReason = hostCounterReason
        self.hostDiagnosticCycles = hostDiagnosticCycles
        self.phaseDiagnosticCycles = phaseDiagnosticCycles
        self.counterMode = counterMode
        self.setupState = setupState
        self.setupReason = setupReason
        self.framingWarning = framingWarning
        self.cueProvenance = cueProvenance
        self.repCounterProvenance = repCounterProvenance
        self.isTrackingReady = isTrackingReady
        self.phaseConfidence = phaseConfidence
        self.score = score
        self.poseScore = poseScore
        self.primaryAngle = primaryAngle
        self.targetAngle = targetAngle
        self.reps = reps
        self.totalReps = totalReps
        self.repsTarget = repsTarget
        self.setsDone = setsDone
        self.totalSets = totalSets
        self.formClass = formClass
        self.hasPose = hasPose
        self.finished = finished
        self.experimental = experimental
    }
}

private func nativeAngle(_ a: NativeLandmark, _ vertex: NativeLandmark, _ c: NativeLandmark) -> Float? {
    let left = SIMD2<Float>(a.x - vertex.x, a.y - vertex.y)
    let right = SIMD2<Float>(c.x - vertex.x, c.y - vertex.y)
    let leftLength = simd_length(left)
    let rightLength = simd_length(right)
    guard leftLength > 0.00001, rightLength > 0.00001 else { return nil }
    let cosine = max(-1, min(1, simd_dot(left, right) / (leftLength * rightLength)))
    return acos(cosine) * 180 / .pi
}

private func nativeFlexionDegrees(_ a: NativeLandmark, _ vertex: NativeLandmark, _ c: NativeLandmark) -> Float? {
    guard let interior = nativeAngle(a, vertex, c) else { return nil }
    return 180 - interior
}

/// Native development sidecar for the train-only PhaseNet V2 artifact. The
/// phase graph is reproduced locally, but its output remains phase-only and is
/// never promoted to a clinical/form/score decision.
final class NativeBottleGrabEngine {
    static let exerciseID = "bottle_grab"
    static let modelID = NativePhaseNetV2Runtime.modelID
    static let modelVersion = "phasenet-v2-native-sidecar-0.1.0-dev"
    static let appV6Version = "app-v6-1-hand-robustness-0.1.0-dev"
    static let appV7Version = "app-v7-bottle-detector-pose-proximity-0.1.0-dev"

    private var exercise = NativeExercise.bottleGrab
    private var frames: [NativeFrameSnapshot] = []
    /// Defense in depth for any future caller that bypasses `CameraSession`.
    /// A capture source replacement must never let a partial PhaseNet window
    /// or a partial cycle continue into the next source generation.
    private var currentSourceGeneration: Int?
    private let phaseTracker: NativeBottleGrabPhaseTracking
    private let fullCyclePolicy: NativeBottleGrabFullCyclePolicy
    private let counterMode: NativeBottleGrabCounterMode
    /// Debug-only phase observation mode. It preserves the Capture-QC reason
    /// but lets the frozen PhaseNet adapter observe real finite Pose+Hand rows
    /// that would otherwise be blocked by side/association gates. It never
    /// enables `totalReps`, never ships in Release, and is only activated by
    /// the explicit Simulator/Debug launch argument or an injected test value.
    private let debugCaptureQCBypass: Bool
    /// Independent direct-geometry lane. It is deliberately separate from
    /// PhaseNet V2, V1.1 hybrid completion, and Baseline #4. V5 treats it as
    /// diagnostic; App V6 promotes it to the experimental `totalReps` owner.
    private let hostCompletionCounter: NativeBottleGrabHostCompletionCounter
    private let proximityCounter: NativeBottleProximityCounter
    /// This does not replace PhaseNet V2 or assert Baseline #4 deployment.
    /// It is a narrow, versioned native preview of fixed Rule-Wrap cue policy.
    private let ruleWrapCuePreview = NativeBottleGrabRuleWrapCuePreviewAdapter()

    init(
        phaseTracker: NativeBottleGrabPhaseTracking? = nil,
        fullCyclePolicy: NativeBottleGrabFullCyclePolicy = NativeBottleGrabFullCyclePolicy(),
        hostCompletionCounter: NativeBottleGrabHostCompletionCounter = NativeBottleGrabHostCompletionCounter(),
        proximityCounter: NativeBottleProximityCounter = NativeBottleProximityCounter(),
        counterMode: NativeBottleGrabCounterMode = .phaseNetFullCycle,
        debugCaptureQCBypass: Bool = NativeBottleGrabEngine.defaultDebugCaptureQCBypass,
    ) {
#if DEBUG
        let effectiveDebugCaptureQCBypass = debugCaptureQCBypass
#else
        let effectiveDebugCaptureQCBypass = false
#endif
        self.debugCaptureQCBypass = effectiveDebugCaptureQCBypass
        self.phaseTracker = phaseTracker ?? NativePhaseNetV2Tracker(
            debugCaptureQCBypass: effectiveDebugCaptureQCBypass,
        )
        self.fullCyclePolicy = fullCyclePolicy
        self.hostCompletionCounter = hostCompletionCounter
        self.proximityCounter = proximityCounter
        self.counterMode = counterMode
    }

    private static var defaultDebugCaptureQCBypass: Bool {
#if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--native-debug-bypass-capture-qc")
#else
        return false
#endif
    }

    func configure(exercise: NativeExercise) {
        self.exercise = exercise
        reset()
    }

    func reset() {
        frames.removeAll(keepingCapacity: true)
        currentSourceGeneration = nil
        phaseTracker.reset(reason: "explicit_reset")
        fullCyclePolicy.resetAll(reason: "explicit_reset")
        hostCompletionCounter.resetAll(reason: "explicit_reset")
        proximityCounter.resetAll(reason: "explicit_reset")
        ruleWrapCuePreview.reset()
    }

    /// Begins or pauses the patient-facing repetition boundary. Positioning
    /// may gather a real rest reference while disabled, but no rep can bridge
    /// the countdown because enabling always requests a fresh baseline.
    func setCountingEnabled(_ enabled: Bool) {
        fullCyclePolicy.setCountingEnabled(enabled)
        hostCompletionCounter.setCountingEnabled(enabled)
        proximityCounter.setCountingEnabled(enabled)
    }

    /// A camera/lens input replacement is not a new exercise session. Keep
    /// already completed development reps visible, but clear every partial
    /// PhaseNet/geometry state so observations never bridge hardware sources.
    func resetForNewCaptureSource() {
        frames.removeAll(keepingCapacity: true)
        currentSourceGeneration = nil
        phaseTracker.reset(reason: "capture_source_replaced")
        fullCyclePolicy.setCountingEnabled(false)
        fullCyclePolicy.resetPartialCycle(reason: "capture_source_replaced")
        hostCompletionCounter.setCountingEnabled(false)
        hostCompletionCounter.resetPartial(reason: "capture_source_replaced")
        proximityCounter.setCountingEnabled(false)
        proximityCounter.resetPartial(reason: "capture_source_replaced")
        ruleWrapCuePreview.reset()
    }

    func ingest(_ snapshot: NativeFrameSnapshot) -> NativeBottleGrabOutput {
        // CameraSession filters delayed callbacks before they reach this
        // engine, but retain the same fail-closed rule here for future/direct
        // callers. A source generation may advance, never regress.
        if let currentSourceGeneration,
           snapshot.sourceGeneration < currentSourceGeneration {
            let setup = counterMode == .bottleDetectorProximity
                ? NativeBottleGrabSetupGate.evaluatePoseOnly(snapshot)
                : NativeBottleGrabSetupGate.evaluate(snapshot)
            let assessableCount = frames.reduce(into: 0) { count, frame in
                let assessment = counterMode == .bottleDetectorProximity
                    ? NativeBottleGrabSetupGate.evaluatePoseOnly(frame)
                    : NativeBottleGrabSetupGate.evaluate(frame)
                if assessment.isReadyForSampling { count += 1 }
            }
            return makeOutput(
                snapshot: snapshot,
                phase: nil,
                captureQC: "cannot_assess_stale_source_generation",
                tracker: nil,
                setupState: "positioning",
                setupReason: "stale_source_generation",
                framingWarning: setup.framingWarning,
                cue: nil,
                isTrackingReady: false,
                assessableCount: assessableCount,
            hostCompletion: hostCompletionCounter.currentResult(reason: "stale_source_generation"),
                bottleResult: counterMode == .bottleDetectorProximity ? proximityCounter.currentResult(reason: "stale_source_generation") : nil,
            )
        }
        if let currentSourceGeneration,
           currentSourceGeneration != snapshot.sourceGeneration {
            frames.removeAll(keepingCapacity: true)
            phaseTracker.reset(reason: "source_generation_changed")
            // Earlier complete development cycles remain visible, but an
            // incomplete cycle may not bridge a camera/lens replacement.
            fullCyclePolicy.setCountingEnabled(false)
            fullCyclePolicy.resetPartialCycle(reason: "source_generation_changed")
            hostCompletionCounter.setCountingEnabled(false)
            hostCompletionCounter.resetPartial(reason: "source_generation_changed")
            proximityCounter.setCountingEnabled(false)
            proximityCounter.resetPartial(reason: "source_generation_changed")
            ruleWrapCuePreview.reset()
        }
        currentSourceGeneration = snapshot.sourceGeneration
        frames.append(snapshot)
        if frames.count > 90 { frames.removeFirst(frames.count - 90) }

        let setup = counterMode == .bottleDetectorProximity
            ? NativeBottleGrabSetupGate.evaluatePoseOnly(snapshot)
            : NativeBottleGrabSetupGate.evaluate(snapshot)
        let assessableCount = frames.reduce(into: 0) { count, frame in
            let assessment = counterMode == .bottleDetectorProximity
                ? NativeBottleGrabSetupGate.evaluatePoseOnly(frame)
                : NativeBottleGrabSetupGate.evaluate(frame)
            if assessment.isReadyForSampling { count += 1 }
        }
        let captureQCBypassActive = debugCaptureQCBypass && !setup.isReadyForSampling
        guard setup.isReadyForSampling || debugCaptureQCBypass else {
            let reason = setup.reason ?? "cannot_assess"
            phaseTracker.reset(reason: reason)
            fullCyclePolicy.resetPartialCycle(reason: reason)
            ruleWrapCuePreview.reset()
            if counterMode == .bottleDetectorProximity {
                proximityCounter.resetPartial(reason: "hard_setup_\(reason)")
                return makeOutput(
                    snapshot: snapshot,
                    phase: nil,
                    captureQC: "cannot_assess_\(reason)",
                    tracker: nil,
                    setupState: "positioning",
                    setupReason: reason,
                    framingWarning: setup.framingWarning,
                    cue: nil,
                    isTrackingReady: false,
                    assessableCount: assessableCount,
                    hostCompletion: NativeBottleGrabHostCompletionResult(
                        totalCycles: proximityCounter.totalCycles,
                        didCompleteCycle: false,
                        status: "pose_unavailable",
                        reason: reason,
                        isArmed: false,
                    ),
                    bottleResult: proximityCounter.currentResult(reason: reason),
                )
            }
            // A missing Hand Landmarker result is never made into geometry.
            // It may, however, be a one-frame detector dropout while the
            // surrounding real capture stream is continuous. Preserve only
            // the host counter's existing bounded native-delivery evidence
            // window
            // for that one non-evidence case; `noteUnavailable` resets it as
            // soon as the interruption is too long. Laterality, association,
            // pose, and confidence failures still invalidate the partial
            // movement immediately because they could represent a different
            // anatomical input rather than a transient absent detection.
            if reason != "missing_left_hand" {
                hostCompletionCounter.resetPartial(reason: "hard_setup_\(reason)")
            }
            let hostCompletion = hostCompletionCounter.noteUnavailable(snapshot: snapshot, reason: reason)
            return makeOutput(
                snapshot: snapshot,
                phase: nil,
                captureQC: "cannot_assess_\(reason)",
                tracker: nil,
                setupState: "positioning",
                setupReason: reason,
                framingWarning: setup.framingWarning,
                cue: nil,
                isTrackingReady: false,
                assessableCount: assessableCount,
                hostCompletion: hostCompletion,
            )
        }

        let phaseSetup = NativeBottleGrabSetupGate.evaluate(snapshot)
        let tracker: NativePhaseTrackingResult?
        if counterMode == .bottleDetectorProximity && !phaseSetup.isReadyForSampling {
            // V7 keeps PhaseNet as optional context. A missing Hand stream must
            // not block the Pose + Bottle proximity counter.
            tracker = nil
        } else {
            tracker = phaseTracker.ingest(snapshot)
        }
        // PhaseNet's frozen 30×20 window has a strict 15 Hz contract.
        // A temporal reset discards only the partial phase-order attempt; it
        // never fabricates an endpoint or preserves it across a gap. Import,
        // feature, and inference failures likewise fail closed.
        let phaseRuntimeAvailable = tracker?.permitsHostCompletion == true
            && tracker?.status != "unavailable"
            && tracker?.status != "cannot_assess"
            && tracker?.status != "phase_error"

        // This uses direct, same-frame wrist/hand geometry and has its own
        // versioned provenance. It does not use, repeat, or fabricate a
        // PhaseNet prediction. It runs only as a diagnostic alongside a live
        // PhaseNet runtime and is never a patient-visible fallback.
        let hostCompletion: NativeBottleGrabHostCompletionResult
        let bottleResult: NativeBottleProximityResult?
        let cue: NativeBottleGrabCuePreview?
        if debugCaptureQCBypass {
            hostCompletionCounter.resetPartial(reason: "debug_capture_qc_bypass")
            hostCompletion = hostCompletionCounter.noteUnavailable(snapshot: snapshot, reason: "debug_phase_only")
            bottleResult = nil
            cue = nil
        } else if counterMode == .bottleDetectorProximity {
            let proximity = proximityCounter.ingest(snapshot)
            hostCompletion = NativeBottleGrabHostCompletionResult(
                totalCycles: proximity.totalCycles,
                didCompleteCycle: proximity.didCompleteCycle,
                status: proximity.status,
                reason: proximity.reason,
                isArmed: proximity.isArmed,
            )
            bottleResult = proximity
            cue = phaseRuntimeAvailable ? ruleWrapCuePreview.ingest(snapshot) : nil
        } else if counterMode == .parallelGeometryFirst {
            // App V6 deliberately keeps the geometry counter independent of
            // PhaseNet availability. Both branches still consume the same
            // accepted real Pose+Hand snapshot, but PhaseNet cannot gate or
            // erase a valid geometry repetition.
            hostCompletion = hostCompletionCounter.ingest(snapshot)
            bottleResult = nil
            cue = phaseRuntimeAvailable ? ruleWrapCuePreview.ingest(snapshot) : nil
        } else if phaseRuntimeAvailable {
            hostCompletion = hostCompletionCounter.ingest(snapshot)
            bottleResult = nil
            cue = ruleWrapCuePreview.ingest(snapshot)
        } else {
            let runtimeReason = tracker?.reason ?? tracker?.status ?? "phase_context_unavailable"
            hostCompletionCounter.resetPartial(reason: "phase_runtime_\(runtimeReason)")
            hostCompletion = hostCompletionCounter.noteUnavailable(snapshot: snapshot, reason: runtimeReason)
            bottleResult = nil
            ruleWrapCuePreview.reset()
            cue = nil
        }
        if let tracker,
           tracker.status == "cannot_assess" || tracker.status == "reset" || tracker.status == "phase_error" {
            fullCyclePolicy.resetPartialCycle(reason: tracker.reason ?? tracker.status)
        }
        if !debugCaptureQCBypass, tracker?.isNewPrediction == true, let prediction = tracker?.prediction {
            _ = fullCyclePolicy.ingest(prediction)
        }

        // A stable three-frame open-rest reference is enough to start the
        // V6 geometry-first flow. PhaseNet can continue buffering or
        // reacquiring its causal context in parallel; it must not trap the
        // user behind a late phase endpoint. V5 retains its old readiness
        // requirement so the comparison route is unchanged.
        let isReady = !debugCaptureQCBypass
            && hostCompletion.isArmed
            && (counterMode == .parallelGeometryFirst
                || counterMode == .bottleDetectorProximity
                || phaseRuntimeAvailable)
        let state: String
        let reason: String?
        switch tracker?.status {
        case "sampling", "buffering":
            state = (tracker?.bufferedFrames ?? 0) < 15 ? "baselining" : "buffering_phase_window"
            reason = nil
        case "phase_ready":
            state = isReady ? "ready" : "tracking"
            reason = nil
        case "reset":
            state = phaseRuntimeAvailable ? "phase_reacquiring" : "positioning"
            reason = tracker?.reason
        case "unavailable":
            state = "unavailable"
            reason = tracker?.reason
        case nil:
            state = counterMode == .bottleDetectorProximity
                ? (isReady ? "ready" : "tracking")
                : "positioning"
            reason = counterMode == .bottleDetectorProximity
                ? (phaseSetup.reason == nil ? "phase_context_unavailable" : phaseSetup.reason)
                : "phase_context_unavailable"
        default:
            state = "positioning"
            reason = tracker?.reason ?? tracker?.status
        }
        let effectiveCaptureQC: String
        if debugCaptureQCBypass {
            effectiveCaptureQC = captureQCBypassActive
                ? "debug_bypass_\(setup.reason ?? "capture_qc")"
                : "debug_phase_only"
        } else {
            effectiveCaptureQC = "can_assess"
        }
        return makeOutput(
            snapshot: snapshot,
            phase: tracker?.prediction?.phase,
            captureQC: effectiveCaptureQC,
            tracker: tracker,
            setupState: state,
            setupReason: reason,
            framingWarning: setup.framingWarning,
            cue: cue,
            isTrackingReady: isReady,
            assessableCount: assessableCount,
            hostCompletion: hostCompletion,
            bottleResult: bottleResult,
        )
    }

    private func makeOutput(
        snapshot: NativeFrameSnapshot,
        phase: String?,
        captureQC: String,
        tracker: NativePhaseTrackingResult?,
        setupState: String,
        setupReason: String?,
        framingWarning: String?,
        cue: NativeBottleGrabCuePreview?,
        isTrackingReady: Bool,
        assessableCount: Int,
        hostCompletion: NativeBottleGrabHostCompletionResult,
        bottleResult: NativeBottleProximityResult? = nil,
    ) -> NativeBottleGrabOutput {
        let target = max(1, exercise.reps)
        let totalSets = max(1, exercise.sets)
        let completed: Int
        if counterMode == .bottleDetectorProximity {
            completed = proximityCounter.totalCycles
        } else if counterMode == .parallelGeometryFirst {
            completed = hostCompletionCounter.totalCycles
        } else {
            completed = fullCyclePolicy.totalCycles
        }
        let setsDone = min(totalSets, completed / target)
        let repsInCurrentSet = setsDone >= totalSets ? 0 : completed % target
        return NativeBottleGrabOutput(
            phase: phase,
            captureQC: captureQC,
            cue: cue?.english,
            cueThai: cue?.thai,
            bufferedFrames: tracker?.bufferedFrames ?? 0,
            assessableFrames: assessableCount,
            posePoints: snapshot.pose.count,
            handPoints: snapshot.hand.count,
            handSide: snapshot.handSide,
            handSideSource: snapshot.handSideSource,
            detectorLatencyMs: snapshot.detectorLatencyMs,
            bottleStatus: bottleResult?.status,
            bottleInZone: bottleResult?.bottleInZone,
            bottleScore: bottleResult?.bottleScore,
            modelStatus: counterMode == .bottleDetectorProximity
                ? (tracker?.modelStatus ?? "experimental_bottle_detector_pose_proximity_phase_context")
                : (tracker?.modelStatus ?? "experimental_phasenet_v2_native_sidecar_phase_only"),
            phaseStatus: tracker?.status ?? "positioning",
            hostCounterStatus: hostCompletion.status,
            hostCounterReason: hostCompletion.reason,
            hostDiagnosticCycles: hostCompletion.totalCycles,
            phaseDiagnosticCycles: fullCyclePolicy.totalCycles,
            counterMode: counterMode.rawValue,
            setupState: setupState,
            setupReason: setupReason,
            framingWarning: framingWarning,
            cueProvenance: cue?.provenance,
            repCounterProvenance: counterMode == .bottleDetectorProximity
                ? NativeBottleProximityCounter.provenance
                : counterMode == .parallelGeometryFirst
                ? NativeBottleGrabHostCompletionCounter.v6Provenance
                : NativeBottleGrabFullCyclePolicy.counterProvenance,
            isTrackingReady: isTrackingReady,
            phaseConfidence: tracker?.prediction?.probability,
            reps: repsInCurrentSet,
            totalReps: completed,
            repsTarget: target,
            setsDone: setsDone,
            totalSets: totalSets,
            hasPose: !snapshot.pose.isEmpty,
            finished: setsDone >= totalSets,
            experimental: true,
        )
    }

}
