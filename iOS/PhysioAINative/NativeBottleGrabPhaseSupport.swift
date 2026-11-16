import Foundation
import simd

/// A single PhaseNet V2 endpoint. This stays phase-only: it does not represent
/// contact, a secure hold, lift, form quality, correctness, or a score.
struct NativePhasePrediction: Equatable {
    let phase: String
    let probability: Float
    let endpointTimestampMs: Int
    let probabilities: [Double]

    init(
        phase: String,
        probability: Float,
        endpointTimestampMs: Int,
        probabilities: [Double] = [],
    ) {
        self.phase = phase
        self.probability = probability
        self.endpointTimestampMs = endpointTimestampMs
        self.probabilities = probabilities
    }
}

/// Preserves the frozen PhaseNet V2 order and emits one experimental
/// patient-visible movement cycle after `return → start_or_rest`. This policy
/// decodes model endpoints; it does not change PhaseNet's frozen weights,
/// feature contract, phase labels, or probability output. It is not a form,
/// contact, lift, correctness, score, or clinical-adherence decision.
///
/// The separately versioned geometry host lane remains diagnostic-only. A
/// single source of truth is deliberate: a geometry and phase event from the
/// same movement must never be summed into two repetitions.
final class NativeBottleGrabFullCyclePolicy {
    static let counterProvenance = "experimental_native_phasenet_v2_full_cycle_lifecycle_v1"
    static let phaseOrder = [
        "start_or_rest",
        "reach",
        "preshape",
        "grasp",
        "release",
        "return",
    ]

    private let minStablePredictions: Int
    private let minProbability: Float
    private var candidatePhase: String?
    private var candidateCount = 0
    private var lastEndpointTimestampMs: Int?
    /// Positioning/countdown predictions are intentionally discarded. The
    /// user must begin a new `start_or_rest` baseline after practice becomes
    /// active, so a partial pre-start movement cannot become a counted rep.
    private var countingEnabled = false

    private(set) var currentPhase: String?
    private(set) var totalCycles = 0
    private(set) var lastResetReason: String?

    init(minStablePredictions: Int = 2, minProbability: Float = 0.5) {
        self.minStablePredictions = max(1, minStablePredictions)
        self.minProbability = minProbability
    }

    func setCountingEnabled(_ enabled: Bool) {
        guard countingEnabled != enabled else { return }
        countingEnabled = enabled
        // Keep previously completed cycles, but never bridge endpoint
        // evidence over the practice lifecycle boundary.
        resetPartialCycle(reason: enabled ? "practice_started_phase_rebaseline" : "practice_not_active")
    }

    @discardableResult
    func ingest(_ prediction: NativePhasePrediction) -> Bool {
        guard countingEnabled else { return false }
        guard prediction.probability.isFinite, prediction.probability >= minProbability else {
            resetPartialCycle(reason: "low_confidence_phase")
            return false
        }
        guard Self.phaseOrder.contains(prediction.phase) else {
            resetPartialCycle(reason: "unknown_phase")
            return false
        }
        if let lastEndpointTimestampMs, prediction.endpointTimestampMs <= lastEndpointTimestampMs {
            resetPartialCycle(reason: "non_monotonic_phase_endpoint")
            return false
        }
        lastEndpointTimestampMs = prediction.endpointTimestampMs

        if candidatePhase == prediction.phase {
            candidateCount += 1
        } else {
            candidatePhase = prediction.phase
            candidateCount = 1
        }
        guard candidateCount >= minStablePredictions else { return false }
        return acceptStablePhase(prediction.phase)
    }

    func resetPartialCycle(reason: String) {
        currentPhase = nil
        candidatePhase = nil
        candidateCount = 0
        lastEndpointTimestampMs = nil
        lastResetReason = reason
    }

    func resetAll(reason: String?) {
        totalCycles = 0
        countingEnabled = false
        resetPartialCycle(reason: reason ?? "explicit_reset")
    }

    private func acceptStablePhase(_ phase: String) -> Bool {
        if currentPhase == phase {
            candidatePhase = nil
            candidateCount = 0
            return false
        }

        guard let currentPhase else {
            guard phase == "start_or_rest" else {
                resetPartialCycle(reason: "out_of_order_phase")
                return false
            }
            self.currentPhase = phase
            candidatePhase = nil
            candidateCount = 0
            lastResetReason = nil
            return false
        }

        guard let currentIndex = Self.phaseOrder.firstIndex(of: currentPhase) else {
            resetPartialCycle(reason: "unknown_current_phase")
            return false
        }
        let expected = currentIndex == Self.phaseOrder.count - 1
            ? "start_or_rest"
            : Self.phaseOrder[currentIndex + 1]
        guard phase == expected else {
            resetPartialCycle(reason: "out_of_order_phase")
            return false
        }

        let completed = currentPhase == "return" && phase == "start_or_rest"
        self.currentPhase = phase
        candidatePhase = nil
        candidateCount = 0
        lastResetReason = nil
        if completed { totalCycles += 1 }
        return completed
    }
}

struct NativeBottleGrabSetupAssessment: Equatable {
    /// A missing value that the frozen PhaseNet V2 feature adapter actually
    /// needs. Only this condition may prevent a frame entering the 30×20
    /// model window or reset an in-progress development cycle.
    let requiredReason: String?
    /// A patient-facing framing/QC warning. Full-body framing is useful for
    /// safe setup, but ankles, knees, and other non-feature landmarks must
    /// not erase valid left-arm + hand evidence when they briefly flicker.
    let framingWarning: String?

    /// Compatibility shorthand for existing callers. This deliberately means
    /// a hard blocker, never a soft full-body warning.
    var reason: String? { requiredReason }

    var isReadyForSampling: Bool { requiredReason == nil }
}

/// Setup QC is deliberately separate from PhaseNet's 20 input features. It
/// makes "whole body and left hand in frame" a visible condition without
/// changing the frozen model input contract.
enum NativeBottleGrabSetupGate {
    private static let fullBodyIndices = [0, 11, 12, 13, 15, 17, 19, 21, 23, 24, 25, 26, 27, 28]
    /// This is exactly the pose subset consumed by the frozen 20-feature
    /// PhaseNet V2 adapter. Do not broaden it here without changing the
    /// model contract.
    private static let requiredPoseIndices = [11, 13, 15, 17, 19, 21]

    static func evaluate(_ snapshot: NativeFrameSnapshot) -> NativeBottleGrabSetupAssessment {
        guard snapshot.pose.count > (requiredPoseIndices.max() ?? 0) else {
            return NativeBottleGrabSetupAssessment(
                requiredReason: "missing_required_pose",
                framingWarning: fullBodyFramingWarning(snapshot),
            )
        }
        for index in requiredPoseIndices {
            let landmark = snapshot.pose[index]
            guard validRequiredPosePoint(landmark) else {
                return NativeBottleGrabSetupAssessment(
                    requiredReason: "missing_required_pose_\(index)",
                    framingWarning: fullBodyFramingWarning(snapshot),
                )
            }
        }
        guard snapshot.hand.count == 21,
              snapshot.hand.allSatisfy(validHandPoint) else {
            return NativeBottleGrabSetupAssessment(
                requiredReason: "missing_left_hand",
                framingWarning: fullBodyFramingWarning(snapshot),
            )
        }
        guard let side = snapshot.handSide?.lowercased(), !side.isEmpty else {
            return NativeBottleGrabSetupAssessment(
                requiredReason: "missing_hand_side",
                framingWarning: fullBodyFramingWarning(snapshot),
            )
        }
        guard side.contains("left") else {
            return NativeBottleGrabSetupAssessment(
                requiredReason: "wrong_anatomical_side",
                framingWarning: fullBodyFramingWarning(snapshot),
            )
        }
        guard snapshot.handScore.isFinite, snapshot.handScore >= 0.5 else {
            return NativeBottleGrabSetupAssessment(
                requiredReason: "unreliable_hand_side",
                framingWarning: fullBodyFramingWarning(snapshot),
            )
        }

        let shoulder = snapshot.pose[11]
        let elbow = snapshot.pose[13]
        let leftWrist = snapshot.pose[15]
        // Association used to depend on hip 23, which is not a PhaseNet
        // input. Use the visible working-arm scale instead so a weak hip or
        // ankle never becomes an accidental hard model blocker.
        let armScale = max(nativeDistance(shoulder, elbow) + nativeDistance(elbow, leftWrist), 0.00001)
        let maximumAssociationDistance = max(0.18, armScale * 0.85)
        guard nativeDistance(snapshot.hand[0], leftWrist) <= maximumAssociationDistance else {
            return NativeBottleGrabSetupAssessment(
                requiredReason: "unassociated_left_hand",
                framingWarning: fullBodyFramingWarning(snapshot),
            )
        }
        return NativeBottleGrabSetupAssessment(
            requiredReason: nil,
            framingWarning: fullBodyFramingWarning(snapshot),
        )
    }

    /// V7's proximity counter does not require Hand Landmarker to count, but
    /// it still requires the body landmarks used for the Pose hand proxy.
    /// Keep this separate from the frozen PhaseNet gate so V5/V6 contracts do
    /// not silently lose their anatomical-left hand requirement.
    static func evaluatePoseOnly(_ snapshot: NativeFrameSnapshot) -> NativeBottleGrabSetupAssessment {
        guard snapshot.pose.count > (requiredPoseIndices.max() ?? 0) else {
            return NativeBottleGrabSetupAssessment(
                requiredReason: "missing_required_pose",
                framingWarning: fullBodyFramingWarning(snapshot),
            )
        }
        for index in requiredPoseIndices {
            let landmark = snapshot.pose[index]
            guard validRequiredPosePoint(landmark) else {
                return NativeBottleGrabSetupAssessment(
                    requiredReason: "missing_required_pose_\(index)",
                    framingWarning: fullBodyFramingWarning(snapshot),
                )
            }
        }
        return NativeBottleGrabSetupAssessment(
            requiredReason: nil,
            framingWarning: fullBodyFramingWarning(snapshot),
        )
    }

    private static func validRequiredPosePoint(_ point: NativeLandmark) -> Bool {
        point.x.isFinite && point.y.isFinite && point.visibility.isFinite
            && point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
            && point.visibility >= 0.5
    }

    private static func validHandPoint(_ point: NativeLandmark) -> Bool {
        point.x.isFinite && point.y.isFinite
            && point.x >= 0 && point.x <= 1 && point.y >= 0 && point.y <= 1
    }

    private static func fullBodyFramingWarning(_ snapshot: NativeFrameSnapshot) -> String? {
        guard snapshot.pose.count > (fullBodyIndices.max() ?? 0) else {
            return "framing_missing_full_body"
        }
        for index in fullBodyIndices {
            let landmark = snapshot.pose[index]
            guard landmark.x.isFinite, landmark.y.isFinite, landmark.visibility.isFinite else {
                return "framing_invalid_pose_\(index)"
            }
            guard landmark.x >= 0, landmark.x <= 1, landmark.y >= 0, landmark.y <= 1 else {
                return "framing_out_of_bounds_pose_\(index)"
            }
            guard landmark.visibility >= 0.5 else {
                return "framing_low_visibility_pose_\(index)"
            }
        }
        return nil
    }
}

struct NativePhaseFeatureFrame: Equatable {
    let timestampMs: Int
    let features: [Float]
}

struct NativePhaseFeatureResult: Equatable {
    let captureQC: String
    let frame: NativePhaseFeatureFrame?
}

/// Scalar port of the frozen PhaseNet V2 feature adapter. It is intentionally
/// phase-only and uses the same left-side QC, 20 feature order, and no-padding
/// policy as the source browser bundle.
enum NativePhaseNetV2FeatureAdapter {
    private static let poseIndices = [11, 13, 15, 17, 19, 21]
    static let maxContiguousGapMs = 100

    static func makeFeatureFrame(
        snapshot: NativeFrameSnapshot,
        previous: NativePhaseFeatureFrame?,
        bypassCaptureQC: Bool = false,
    ) -> NativePhaseFeatureResult {
        guard snapshot.pose.count > (poseIndices.max() ?? 0) else {
            return NativePhaseFeatureResult(captureQC: "cannot_assess_missing_pose", frame: nil)
        }
        guard snapshot.hand.count == 21 else {
            return NativePhaseFeatureResult(captureQC: "cannot_assess_missing_hand", frame: nil)
        }
        if !bypassCaptureQC {
            guard let side = snapshot.handSide?.lowercased(), side.contains("left") else {
                return NativePhaseFeatureResult(captureQC: "cannot_assess_wrong_anatomical_side", frame: nil)
            }
            guard snapshot.handScore.isFinite, snapshot.handScore >= 0.5 else {
                return NativePhaseFeatureResult(captureQC: "cannot_assess_unreliable_hand_side", frame: nil)
            }
        }
        guard poseIndices.allSatisfy({ index in
            let point = snapshot.pose[index]
            return point.x.isFinite && point.y.isFinite && point.visibility.isFinite
                && (bypassCaptureQC || point.visibility >= 0.5)
        }) else {
            return NativePhaseFeatureResult(captureQC: "cannot_assess_unreliable_pose", frame: nil)
        }
        // Keep feature-adapter parity with the frozen browser contract: its
        // hand reliability gate requires finite x/y coordinates, not an
        // artificial [0, 1] screen-bound restriction. Camera framing/QC is
        // handled separately; adding bounds here rejects valid golden
        // fixtures and silently changes model input behavior.
        guard snapshot.hand.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return NativePhaseFeatureResult(captureQC: "cannot_assess_unreliable_hand", frame: nil)
        }

        guard let poseValues = poseStatic(snapshot.pose), let handValues = handStatic(snapshot.hand) else {
            return NativePhaseFeatureResult(captureQC: "cannot_assess_degenerate_geometry", frame: nil)
        }

        let previousFeatures: [Float]?
        if let previous,
           snapshot.timestampMs > previous.timestampMs,
           snapshot.timestampMs - previous.timestampMs <= maxContiguousGapMs,
           previous.features.count == 20 {
            previousFeatures = previous.features
        } else {
            previousFeatures = nil
        }
        let poseDelta = previousFeatures.map { previous in
            poseValues.enumerated().map { index, value in value - previous[index] }
        } ?? Array(repeating: 0, count: 5)
        let handDelta = previousFeatures.map { previous in
            [
                handValues[6] - previous[16],
                handValues[5] - previous[15],
                handValues[3] - previous[13],
            ]
        } ?? Array(repeating: 0, count: 3)
        let features = poseValues + poseDelta + handValues + handDelta
        guard features.count == 20, features.allSatisfy(\.isFinite) else {
            return NativePhaseFeatureResult(captureQC: "cannot_assess_invalid_feature_vector", frame: nil)
        }
        return NativePhaseFeatureResult(
            captureQC: "can_assess",
            frame: NativePhaseFeatureFrame(timestampMs: snapshot.timestampMs, features: features),
        )
    }

    private static func poseStatic(_ pose: [NativeLandmark]) -> [Float]? {
        let shoulder = pose[11]
        let elbow = pose[13]
        let wrist = pose[15]
        let coarse = [pose[17], pose[19], pose[21]]
        let armScale = nativeDistance(shoulder, elbow) + nativeDistance(elbow, wrist)
        guard armScale > 0.00000001, let elbowFlexion = flexionNorm(shoulder, elbow, wrist) else { return nil }
        let centroidX = coarse.reduce(Float.zero) { $0 + $1.x } / Float(coarse.count)
        let centroidY = coarse.reduce(Float.zero) { $0 + $1.y } / Float(coarse.count)
        return [
            elbowFlexion,
            (wrist.x - shoulder.x) / armScale,
            (wrist.y - shoulder.y) / armScale,
            (centroidX - wrist.x) / armScale,
            (centroidY - wrist.y) / armScale,
        ]
    }

    private static func handStatic(_ hand: [NativeLandmark]) -> [Float]? {
        let palmScale = nativeDistance(hand[0], hand[9])
        guard palmScale > 0.00000001,
              let thumbMCP = flexionNorm(hand[1], hand[2], hand[3]),
              let thumbIP = flexionNorm(hand[2], hand[3], hand[4]),
              let indexMCP = flexionNorm(hand[0], hand[5], hand[6]),
              let indexPIP = flexionNorm(hand[5], hand[6], hand[7]),
              let indexDIP = flexionNorm(hand[6], hand[7], hand[8]) else { return nil }

        let chains = [
            [0, 5, 6, 7, 8],
            [0, 9, 10, 11, 12],
            [0, 13, 14, 15, 16],
            [0, 17, 18, 19, 20],
        ]
        var allFingerFlexions: [Float] = []
        for chain in chains {
            guard let first = flexionNorm(hand[chain[0]], hand[chain[1]], hand[chain[2]]),
                  let second = flexionNorm(hand[chain[1]], hand[chain[2]], hand[chain[3]]),
                  let third = flexionNorm(hand[chain[2]], hand[chain[3]], hand[chain[4]]) else {
                return nil
            }
            allFingerFlexions += [first, second, third]
        }
        let meanFlexion = allFingerFlexions.reduce(0, +) / Float(allFingerFlexions.count)
        return [
            thumbMCP,
            thumbIP,
            indexMCP,
            indexPIP,
            indexDIP,
            meanFlexion,
            nativeDistance(hand[4], hand[8]) / palmScale,
        ]
    }

    private static func flexionNorm(_ first: NativeLandmark, _ vertex: NativeLandmark, _ third: NativeLandmark) -> Float? {
        let left = SIMD2<Float>(first.x - vertex.x, first.y - vertex.y)
        let right = SIMD2<Float>(third.x - vertex.x, third.y - vertex.y)
        let leftLength = simd_length(left)
        let rightLength = simd_length(right)
        guard leftLength > 0.00000001, rightLength > 0.00000001 else { return nil }
        let cosine = max(-1, min(1, simd_dot(left, right) / (leftLength * rightLength)))
        let value = 1 - acos(Double(cosine)) / Double.pi
        return Float(max(0, min(1, value)))
    }
}

struct NativePhaseWindowResult {
    let status: String
    let reason: String?
    let window: [[Float]]?
    let endpointTimestampMs: Int?
}

/// The frozen model owns a 30×20, 15 Hz causal window. This accumulator never
/// resamples, pads, interpolates, or bridges a stale snapshot.
struct NativePhaseNetV2WindowAccumulator {
    static let sequenceLength = 30
    static let featureCount = 20
    static let sampleIntervalMs = 1000.0 / 15.0
    static let maxContiguousGapMs = 100
    static let strideFrames = 3

    private var frames: [NativePhaseFeatureFrame] = []
    private var framesSinceEmission = 0
    private var hasEmitted = false
    private(set) var lastResetReason: String?

    var bufferedFrameCount: Int { frames.count }

    mutating func reset(reason: String) {
        frames.removeAll(keepingCapacity: true)
        framesSinceEmission = 0
        hasEmitted = false
        lastResetReason = reason
    }

    mutating func push(features: [Float], timestampMs: Int) -> NativePhaseWindowResult {
        guard features.count == Self.featureCount, features.allSatisfy(\.isFinite) else {
            reset(reason: "invalid_feature_vector")
            return NativePhaseWindowResult(status: "reset", reason: lastResetReason, window: nil, endpointTimestampMs: nil)
        }
        if let previous = frames.last {
            let gap = timestampMs - previous.timestampMs
            guard gap > 0, gap <= Self.maxContiguousGapMs else {
                reset(reason: "source_timeline_discontinuity")
                return NativePhaseWindowResult(status: "reset", reason: lastResetReason, window: nil, endpointTimestampMs: nil)
            }
        }
        frames.append(NativePhaseFeatureFrame(timestampMs: timestampMs, features: features))
        if frames.count > Self.sequenceLength { frames.removeFirst() }
        guard frames.count == Self.sequenceLength else {
            return NativePhaseWindowResult(status: "buffering", reason: nil, window: nil, endpointTimestampMs: nil)
        }

        let expectedSpan = Double(Self.sequenceLength - 1) * Self.sampleIntervalMs
        let actualSpan = Double((frames.last?.timestampMs ?? 0) - (frames.first?.timestampMs ?? 0))
        guard abs(actualSpan - expectedSpan) <= Self.sampleIntervalMs else {
            reset(reason: "invalid_15hz_window_span")
            return NativePhaseWindowResult(status: "reset", reason: lastResetReason, window: nil, endpointTimestampMs: nil)
        }
        if hasEmitted {
            framesSinceEmission += 1
            guard framesSinceEmission >= Self.strideFrames else {
                return NativePhaseWindowResult(status: "buffering", reason: nil, window: nil, endpointTimestampMs: nil)
            }
        }
        hasEmitted = true
        framesSinceEmission = 0
        return NativePhaseWindowResult(
            status: "window_ready",
            reason: nil,
            window: frames.map(\.features),
            endpointTimestampMs: frames.last?.timestampMs,
        )
    }
}

struct NativePhaseTrackingResult: Equatable {
    let status: String
    let reason: String?
    let bufferedFrames: Int
    let prediction: NativePhasePrediction?
    /// A prediction is available only at a newly emitted 15 Hz endpoint. The
    /// tracker never bridges a stale endpoint into another camera frame.
    let isNewPrediction: Bool
    let modelStatus: String
    /// Whether the frozen PhaseNet runtime is usable as a parallel diagnostic
    /// while the separately versioned host completion lane receives this
    /// frame. A temporary temporal-window reset caused by real live-camera
    /// cadence does not make the loaded runtime unavailable; hard feature,
    /// import, or inference failures do.
    let permitsHostCompletion: Bool

    init(
        status: String,
        reason: String?,
        bufferedFrames: Int,
        prediction: NativePhasePrediction?,
        isNewPrediction: Bool,
        modelStatus: String,
        permitsHostCompletion: Bool = true,
    ) {
        self.status = status
        self.reason = reason
        self.bufferedFrames = bufferedFrames
        self.prediction = prediction
        self.isNewPrediction = isNewPrediction
        self.modelStatus = modelStatus
        self.permitsHostCompletion = permitsHostCompletion
    }
}

protocol NativeBottleGrabPhaseTracking: AnyObject {
    func ingest(_ snapshot: NativeFrameSnapshot) -> NativePhaseTrackingResult
    func reset(reason: String)
}

/// Native sampler + frozen-runtime adapter. The upstream camera can run at its
/// own rate; only valid snapshots spaced at approximately 15 Hz reach PhaseNet.
final class NativePhaseNetV2Tracker: NativeBottleGrabPhaseTracking {
    // Timestamp values are integer milliseconds. 66 ms is the closest lower
    // integer cadence to the frozen 1000 / 15 ms source interval; 60 ms can
    // accumulate a 30-frame window outside the contract's permitted span.
    private static let minimumSampleIntervalMs = 66
    private let runtime: NativePhaseNetV2Runtime?
    private let runtimeError: String?
    private let bypassCaptureQC: Bool
    private var accumulator = NativePhaseNetV2WindowAccumulator()
    private var previousFeature: NativePhaseFeatureFrame?
    private var lastIncomingTimestampMs: Int?
    private var lastSampleTimestampMs: Int?

    init(bundle: Bundle = .main, debugCaptureQCBypass: Bool = false) {
        self.bypassCaptureQC = debugCaptureQCBypass
        do {
            runtime = try NativePhaseNetV2Runtime.loadBundled(from: bundle)
            runtimeError = nil
        } catch {
            runtime = nil
            runtimeError = error.localizedDescription
        }
    }

    func reset(reason: String) {
        accumulator.reset(reason: reason)
        previousFeature = nil
        lastIncomingTimestampMs = nil
        lastSampleTimestampMs = nil
    }

    func ingest(_ snapshot: NativeFrameSnapshot) -> NativePhaseTrackingResult {
        guard let runtime else {
            return NativePhaseTrackingResult(
                status: "unavailable",
                reason: runtimeError ?? "runtime_unavailable",
                bufferedFrames: accumulator.bufferedFrameCount,
                prediction: nil,
                isNewPrediction: false,
                modelStatus: "experimental_phasenet_v2_native_runtime_unavailable",
                permitsHostCompletion: false,
            )
        }
        if let lastIncomingTimestampMs {
            let gap = snapshot.timestampMs - lastIncomingTimestampMs
            guard gap > 0, gap <= NativePhaseNetV2WindowAccumulator.maxContiguousGapMs else {
                reset(reason: "source_timeline_discontinuity")
                return NativePhaseTrackingResult(
                    status: "reset",
                    reason: "source_timeline_discontinuity",
                    bufferedFrames: 0,
                    prediction: nil,
                    isNewPrediction: false,
                    modelStatus: "experimental_phasenet_v2_native_sidecar_phase_only",
                )
            }
        }
        lastIncomingTimestampMs = snapshot.timestampMs
        if let lastSampleTimestampMs,
           snapshot.timestampMs - lastSampleTimestampMs < Self.minimumSampleIntervalMs {
            return NativePhaseTrackingResult(
                status: "sampling",
                reason: nil,
                bufferedFrames: accumulator.bufferedFrameCount,
                prediction: nil,
                isNewPrediction: false,
                modelStatus: "experimental_phasenet_v2_native_sidecar_phase_only",
            )
        }

        let feature = NativePhaseNetV2FeatureAdapter.makeFeatureFrame(
            snapshot: snapshot,
            previous: previousFeature,
            bypassCaptureQC: bypassCaptureQC,
        )
        guard let frame = feature.frame else {
            reset(reason: feature.captureQC)
            return NativePhaseTrackingResult(
                status: "cannot_assess",
                reason: feature.captureQC,
                bufferedFrames: 0,
                prediction: nil,
                isNewPrediction: false,
                modelStatus: "experimental_phasenet_v2_native_sidecar_phase_only",
                permitsHostCompletion: false,
            )
        }
        previousFeature = frame
        lastSampleTimestampMs = snapshot.timestampMs
        let window = accumulator.push(features: frame.features, timestampMs: frame.timestampMs)
        guard window.status == "window_ready", let values = window.window, let endpoint = window.endpointTimestampMs else {
            return NativePhaseTrackingResult(
                status: window.status,
                reason: window.reason,
                bufferedFrames: accumulator.bufferedFrameCount,
                prediction: nil,
                isNewPrediction: false,
                modelStatus: "experimental_phasenet_v2_native_sidecar_phase_only",
            )
        }
        do {
            let inference = try runtime.predict(window: values)
            let prediction = NativePhasePrediction(
                phase: inference.phase,
                probability: Float(inference.probabilities[inference.argmaxIndex]),
                endpointTimestampMs: endpoint,
                probabilities: inference.probabilities,
            )
            return NativePhaseTrackingResult(
                status: "phase_ready",
                reason: nil,
                bufferedFrames: accumulator.bufferedFrameCount,
                prediction: prediction,
                isNewPrediction: true,
                modelStatus: "experimental_phasenet_v2_native_sidecar_phase_only",
            )
        } catch {
            return NativePhaseTrackingResult(
                status: "phase_error",
                reason: error.localizedDescription,
                bufferedFrames: accumulator.bufferedFrameCount,
                prediction: nil,
                isNewPrediction: false,
                modelStatus: "experimental_phasenet_v2_native_sidecar_phase_only",
                permitsHostCompletion: false,
            )
        }
    }
}

/// Simulator-only deterministic phase sequence. It verifies the SwiftUI state
/// transitions and counter policy without asserting that a simulator camera or
/// synthetic pose frames are live-device model-performance evidence.
final class NativeFixturePhaseTracker: NativeBottleGrabPhaseTracking {
    private let sequence = [
        "start_or_rest", "start_or_rest",
        "reach", "reach",
        "preshape", "preshape",
        "grasp", "grasp",
        "release", "release",
        "return", "return",
        "start_or_rest", "start_or_rest",
    ]
    private var sampleCount = 0

    func reset(reason: String) {
        sampleCount = 0
    }

    func ingest(_ snapshot: NativeFrameSnapshot) -> NativePhaseTrackingResult {
        sampleCount += 1
        guard sampleCount > NativePhaseNetV2WindowAccumulator.sequenceLength else {
            return NativePhaseTrackingResult(
                status: "buffering",
                reason: nil,
                bufferedFrames: sampleCount,
                prediction: nil,
                isNewPrediction: false,
                modelStatus: "fixture_phase_script_for_ui_only",
            )
        }
        // A single scripted completion is enough for the Simulator route
        // check. Repeating this tiny fixture loop would turn an unattended
        // screenshot into an implausible stream of completed reps, which
        // conceals whether the full-cycle boundary itself is visible. The
        // real PhaseNet tracker remains continuous and can count later valid
        // cycles from live input.
        let sequenceIndex = sampleCount - NativePhaseNetV2WindowAccumulator.sequenceLength - 1
        let phase = sequence.indices.contains(sequenceIndex)
            ? sequence[sequenceIndex]
            : "start_or_rest"
        return NativePhaseTrackingResult(
            status: "phase_ready",
            reason: nil,
            bufferedFrames: NativePhaseNetV2WindowAccumulator.sequenceLength,
            prediction: NativePhasePrediction(phase: phase, probability: 0.98, endpointTimestampMs: snapshot.timestampMs),
            isNewPrediction: true,
            modelStatus: "fixture_phase_script_for_ui_only",
        )
    }
}

func nativeDistance(_ a: NativeLandmark, _ b: NativeLandmark) -> Float {
    hypotf(a.x - b.x, a.y - b.y)
}
