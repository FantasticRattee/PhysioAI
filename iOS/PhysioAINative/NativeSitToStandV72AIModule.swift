import AVFoundation
import Foundation

/// One derived, label-free Sit-to-Stand Pose feature row. This is the sole
/// shared input to the parallel counter and NN/comment path; neither path
/// consumes the other's state or output.
struct NativeSitToStandFeatureFrame: Equatable {
    let timestampMs: Int
    let sourceGeneration: Int
    let featureVector: [Float]?
    let pelvisHeightAboveAnklesNorm: Float?
    /// Derived mean knee extension for the geometry counter's V8.0.14
    /// camera-scale adaptation. No raw landmarks leave the extractor.
    let meanKneeAngleDeg: Float?
    let wristSpanNorm: Float?
    let reason: String?
    /// Privacy-safe, derived-only inputs for the V8.0.12 evidence observer.
    /// They are not raw landmarks and do not affect either the counter or the
    /// PhaseNet comment path.
    let evidenceMetrics: NativeSitToStandEvidenceMetrics?

    var featureReady: Bool { featureVector != nil && reason == nil }
}

/// Pose-only admission result for the exercise's explicit hands-together
/// contract. This deliberately measures wrist proximity, not finger
/// interlacing: the Sit-to-Stand module does not instantiate MediaPipe Hand.
struct NativeSitToStandHandsTogetherResult: Equatable {
    let status: String
    let isAdmitted: Bool
    let cue: String?
    let cueThai: String?
}

/// A small, deterministic gate that runs alongside (not through) PhaseNet.
/// It uses the existing Pose wrist points and torso-normalized wrist span so
/// camera scale does not become a hidden part of the form requirement.
struct NativeSitToStandHandsTogetherGate {
    static let minimumVisibility: Float = 0.40
    static let maximumWristSpanNorm: Float = 0.35
    static let persistenceFrames = 3

    private var consecutiveTogetherFrames = 0
    /// A successful entry check authorizes exactly one active geometry cycle.
    /// Later Pose wrist jitter must not erase the seated baseline mid-cycle.
    private var isLatchedForActiveCycle = false

    static func hasBothVisibleWrists(_ pose: [NativeLandmark]) -> Bool {
        guard pose.indices.contains(15), pose.indices.contains(16) else { return false }
        let left = pose[15]
        let right = pose[16]
        return left.visibility >= minimumVisibility
            && right.visibility >= minimumVisibility
            && left.x.isFinite && left.y.isFinite && left.z.isFinite
            && right.x.isFinite && right.y.isFinite && right.z.isFinite
    }

    mutating func reset() {
        consecutiveTogetherFrames = 0
        isLatchedForActiveCycle = false
    }

    /// A counted return to seated starts a new cycle. The next rise must pass
    /// the same entry-only check, without rewriting the completed total.
    mutating func rearmForNextCycle() {
        consecutiveTogetherFrames = 0
        isLatchedForActiveCycle = false
    }

    mutating func ingest(wristSpanNorm: Float?) -> NativeSitToStandHandsTogetherResult {
        if isLatchedForActiveCycle {
            return result(status: "hands_together_latched", isAdmitted: true, cue: nil, cueThai: nil)
        }
        guard let wristSpanNorm, wristSpanNorm.isFinite else {
            reset()
            return result(
                status: "hands_not_assessable",
                isAdmitted: false,
                cue: "Keep both hands visible in the camera before starting.",
                cueThai: "ให้เห็นมือทั้งสองข้างในกล้องก่อนเริ่ม",
            )
        }
        guard wristSpanNorm <= Self.maximumWristSpanNorm else {
            reset()
            return result(
                status: "hands_together_required",
                isAdmitted: false,
                cue: "Keep both hands together before starting.",
                cueThai: "โปรดประสานมือทั้งสองข้างก่อนเริ่ม",
            )
        }

        consecutiveTogetherFrames += 1
        guard consecutiveTogetherFrames >= Self.persistenceFrames else {
            return result(
                status: "hands_together_collecting",
                isAdmitted: false,
                cue: "Keep both hands together briefly before starting.",
                cueThai: "ประสานมือทั้งสองข้างแล้วค้างสักครู่ก่อนเริ่ม",
            )
        }
        isLatchedForActiveCycle = true
        return result(status: "hands_together_latched", isAdmitted: true, cue: nil, cueThai: nil)
    }

    private func result(
        status: String,
        isAdmitted: Bool,
        cue: String?,
        cueThai: String?,
    ) -> NativeSitToStandHandsTogetherResult {
        NativeSitToStandHandsTogetherResult(
            status: status,
            isAdmitted: isAdmitted,
            cue: cue,
            cueThai: cueThai,
        )
    }
}

/// Presentation-only policy for Pose outputs that are not yet credible enough
/// for Sit-to-Stand geometry. MediaPipe must continue sampling an empty scene
/// so it can discover an arriving participant, but a rejected raw pose must
/// not be rendered as if the exercise module had accepted a person.
enum NativeSitToStandPresencePolicy {
    static func shouldRenderRawPose(isTrackingReady: Bool) -> Bool {
        isTrackingReady
    }

    static func waitingForParticipantCopy(isThai: Bool) -> (title: String, detail: String) {
        isThai
            ? (
                "รอให้ผู้ฝึกเข้ากล้อง",
                "ให้เห็นศีรษะ ลำตัว เก้าอี้ เข่า และเท้าทั้งสองข้างในกรอบกล้อง",
            )
            : (
                "Waiting for participant",
                "Move into view until your head, body, chair, knees, and both feet are visible.",
            )
    }
}

struct NativeSitToStandGeometryResult: Equatable {
    let status: String
    let totalReps: Int
    let repetitionCompleted: Bool
    let reason: String?
    var baselineHeight: Float? = nil
}

enum NativeSitToStandBodyPosture: String, Equatable {
    case seated, standing, transitioning, unknown
}

/// Counter-only image-plane measurements. In portrait capture, normalized
/// image Z can dwarf the visible torso span and invert the old height ratio.
/// Y/Y ratios use one coordinate scale and cannot change when only Z changes.
/// The frozen PhaseNet feature vector and evidence metrics remain separate.
struct NativeSitToStandCounterObservation: Equatable {
    static let seatedMaximumThighShinRatio: Float = 0.55
    static let standingMinimumThighShinRatio: Float = 0.85
    let pelvisHeightInShins: Float
    let thighShinRatio: Float
    let posture: NativeSitToStandBodyPosture
    let wristSpanNorm: Float

    static func extract(_ snapshot: NativeFrameSnapshot) -> Self? {
        let required = [0, 11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28, 31, 32]
        guard !snapshot.inputIsMirrored, required.allSatisfy({ index in
            guard snapshot.pose.indices.contains(index) else { return false }
            let point = snapshot.pose[index]
            return point.visibility.isFinite && point.visibility >= 0.40
                && point.x.isFinite && point.y.isFinite && point.z.isFinite
                && (0...1).contains(point.x) && (0...1).contains(point.y)
        }) else { return nil }
        let pose = snapshot.pose
        let leftShin = pose[27].y - pose[25].y
        let rightShin = pose[28].y - pose[26].y
        guard leftShin > 0.015, rightShin > 0.015 else { return nil }
        let leftRatio = (pose[25].y - pose[23].y) / leftShin
        let rightRatio = (pose[26].y - pose[24].y) / rightShin
        guard leftRatio.isFinite, rightRatio.isFinite,
              leftRatio > -0.5, rightRatio > -0.5,
              leftRatio < 3, rightRatio < 3 else { return nil }
        let ratio = (leftRatio + rightRatio) / 2
        let posture: NativeSitToStandBodyPosture
        if ratio <= seatedMaximumThighShinRatio, max(leftRatio, rightRatio) <= 0.70 {
            posture = .seated
        } else if ratio >= standingMinimumThighShinRatio, min(leftRatio, rightRatio) >= 0.65 {
            posture = .standing
        } else {
            posture = .transitioning
        }
        // Preserve the existing wrist-admission measurement/threshold, including
        // its depth convention, independently of PhaseNet's temporal QC.
        let shoulderX = (pose[11].x + pose[12].x) / 2
        let shoulderY = (pose[11].y + pose[12].y) / 2
        let shoulderZ = (pose[11].z + pose[12].z) / 2
        let hipX = (pose[23].x + pose[24].x) / 2
        let hipY = (pose[23].y + pose[24].y) / 2
        let hipZ = (pose[23].z + pose[24].z) / 2
        let torso = sqrt(pow(shoulderX - hipX, 2) + pow(shoulderY - hipY, 2) + pow(shoulderZ - hipZ, 2))
        guard torso > 0.000_001 else { return nil }
        let wristDistance = sqrt(pow(pose[15].x - pose[16].x, 2) + pow(pose[15].y - pose[16].y, 2) + pow(pose[15].z - pose[16].z, 2))
        return Self(pelvisHeightInShins: 1 + ratio, thighShinRatio: ratio,
                    posture: posture, wristSpanNorm: wristDistance / torso)
    }
}

/// Versioned, derived-only calibration for the Sit-to-Stand geometry state
/// machine. These are capture/runtime gates, not clinical thresholds.
private struct NativeSitToStandGeometryCounterConfiguration {
    static let v8_0_14 = Self(
        seatedCeiling: 0.80,
        legacyStandingMinimum: 1.10,
        adaptiveStandingMinimumKneeExtensionDeg: 150,
        minimumBaselineFrames: 3,
        seatedStabilitySpan: 0.15,
        seatedDwellMs: 2_250,
        riseDelta: 0.10,
        standingDelta: 0.25,
        lowerStartDelta: 0.15,
        seatedReturnDelta: 0.10,
        minimumStandingHoldMs: 200,
    )

    let seatedCeiling: Float
    /// Retained front-view capture calibration from the pre-V8.0.14 counter.
    let legacyStandingMinimum: Float
    /// Adaptive V8.0.14 guard. A baseline-relative rise below the legacy
    /// absolute height must still show an extended mean knee angle.
    let adaptiveStandingMinimumKneeExtensionDeg: Float
    let minimumBaselineFrames: Int
    let seatedStabilitySpan: Float
    let seatedDwellMs: Int
    let riseDelta: Float
    let standingDelta: Float
    let lowerStartDelta: Float
    let seatedReturnDelta: Float
    let minimumStandingHoldMs: Int
}

/// Geometry-only counter. It receives no PhaseNet class, probability, comment,
/// or state, making the parallel boundary explicit and testable.
struct NativeSitToStandGeometryCounter {
    private enum State: String {
        case awaitingSeatedBaseline = "awaiting_seated_baseline"
        case seatedRest = "seated_rest"
        case rising
        case standingHold = "standing_hold"
        case lowering
    }

    private static let configuration = NativeSitToStandGeometryCounterConfiguration.v8_0_14

    private var state: State = .awaitingSeatedBaseline
    private var countingEnabled = false
    private var totalReps = 0
    private var baselineSamples: [Float] = []
    private var baselineHeight: Float?
    private var seatedStartedAtMs: Int?
    private var standingStartedAtMs: Int?
    private var standingLastQualifiedAtMs: Int?

    var completedReps: Int { totalReps }

    mutating func setCountingEnabled(_ enabled: Bool) {
        countingEnabled = enabled
        if !enabled {
            resetPartial()
        }
    }

    mutating func resetPartial() {
        state = .awaitingSeatedBaseline
        baselineSamples.removeAll(keepingCapacity: true)
        baselineHeight = nil
        seatedStartedAtMs = nil
        standingStartedAtMs = nil
        standingLastQualifiedAtMs = nil
    }

    mutating func resetForNewCaptureSource() {
        resetPartial()
        countingEnabled = false
    }

    mutating func ingest(
        pelvisHeightAboveAnklesNorm height: Float,
        averageKneeAngleDeg: Float? = nil,
        bodyPosture: NativeSitToStandBodyPosture? = nil,
        timestampMs: Int,
        movementAuthorized: Bool = true,
    ) -> NativeSitToStandGeometryResult {
        guard height.isFinite else {
            resetPartial()
            return NativeSitToStandGeometryResult(
                status: "cannot_assess",
                totalReps: totalReps,
                repetitionCompleted: false,
                reason: "non_finite_pelvis_height",
            )
        }

        switch state {
        case .awaitingSeatedBaseline:
            // V8.0.15 runtime explicitly verifies seated leg geometry. The nil
            // path retains the V8.0.14 scalar contract for older callers/tests.
            let isSeated = bodyPosture.map { $0 == .seated }
                ?? (height <= Self.configuration.seatedCeiling)
            guard isSeated else {
                baselineSamples.removeAll(keepingCapacity: true)
                return result(reason: "awaiting_seated_baseline")
            }
            baselineSamples.append(height)
            if baselineSamples.count > Self.configuration.minimumBaselineFrames {
                baselineSamples.removeFirst(baselineSamples.count - Self.configuration.minimumBaselineFrames)
            }
            guard baselineSamples.count == Self.configuration.minimumBaselineFrames,
                  let minimum = baselineSamples.min(),
                  let maximum = baselineSamples.max(),
                  maximum - minimum <= Self.configuration.seatedStabilitySpan else {
                return result(reason: "collecting_seated_baseline")
            }
            baselineHeight = baselineSamples.reduce(0, +) / Float(baselineSamples.count)
            seatedStartedAtMs = timestampMs
            state = .seatedRest
            return result()

        case .seatedRest:
            guard countingEnabled else { return result(reason: "counting_disabled") }
            guard let baselineHeight, let seatedStartedAtMs else {
                resetPartial()
                return result(reason: "baseline_missing")
            }
            guard movementAuthorized else {
                // Preserve a seated baseline while the entry-only hand gate
                // collects. If the person rises before entry is admitted,
                // discard that attempted cycle rather than silently counting
                // a rise that began without the contract check.
                if height > baselineHeight + Self.configuration.seatedReturnDelta {
                    resetPartial()
                    return result(reason: "hands_not_admitted_before_rise")
                }
                return result(reason: "awaiting_hands_together")
            }
            let elapsed = timestampMs - seatedStartedAtMs
            if bodyPosture != nil, elapsed < Self.configuration.seatedDwellMs {
                return result(reason: "seated_settling")
            }
            if elapsed >= Self.configuration.seatedDwellMs,
               height >= baselineHeight + Self.configuration.riseDelta {
                state = .rising
            }
            return result()

        case .rising:
            guard let baselineHeight else {
                resetPartial()
                return result(reason: "baseline_missing")
            }
            if qualifiesStanding(
                height: height,
                baselineHeight: baselineHeight,
                averageKneeAngleDeg: averageKneeAngleDeg,
                bodyPosture: bodyPosture,
            ) {
                standingStartedAtMs = timestampMs
                standingLastQualifiedAtMs = timestampMs
                state = .standingHold
                return result(reason: bodyPosture == nil ? nil : "standing_hold_pending")
            } else if height <= baselineHeight + Self.configuration.seatedReturnDelta {
                state = .seatedRest
                seatedStartedAtMs = timestampMs
            } else {
                return result(reason: "standing_qualification_pending")
            }
            return result()

        case .standingHold:
            guard let baselineHeight else {
                resetPartial()
                return result(reason: "baseline_missing")
            }
            let isStillStanding = qualifiesStanding(
                height: height,
                baselineHeight: baselineHeight,
                averageKneeAngleDeg: averageKneeAngleDeg,
                bodyPosture: bodyPosture,
            )
            if isStillStanding {
                standingLastQualifiedAtMs = timestampMs
                let heldForMs = timestampMs - (standingStartedAtMs ?? timestampMs)
                return result(reason: bodyPosture != nil && heldForMs < Self.configuration.minimumStandingHoldMs
                    ? "standing_hold_pending" : nil)
            }

            // Lowering is baseline-relative rather than a one-frame drop.
            // Require a sustained stand before a return toward seated can enter
            // the lowering state; otherwise an isolated scale spike would turn
            // into a false completed repetition.
            let holdEndMs = bodyPosture == nil ? timestampMs : (standingLastQualifiedAtMs ?? timestampMs)
            let heldForMs = holdEndMs - (standingStartedAtMs ?? timestampMs)
            if height - baselineHeight < Self.configuration.lowerStartDelta {
                if heldForMs >= Self.configuration.minimumStandingHoldMs {
                    state = .lowering
                } else {
                    state = .seatedRest
                    seatedStartedAtMs = timestampMs
                    standingStartedAtMs = nil
                    standingLastQualifiedAtMs = nil
                }
            }
            return result()

        case .lowering:
            guard let baselineHeight else {
                resetPartial()
                return result(reason: "baseline_missing")
            }
            if height <= baselineHeight + Self.configuration.seatedReturnDelta {
                totalReps += 1
                state = .seatedRest
                seatedStartedAtMs = timestampMs
                standingStartedAtMs = nil
                standingLastQualifiedAtMs = nil
                return NativeSitToStandGeometryResult(
                    status: State.seatedRest.rawValue,
                    totalReps: totalReps,
                    repetitionCompleted: true,
                    reason: nil,
                    baselineHeight: baselineHeight,
                )
            }
            return result()
        }
    }

    /// V8.0.14 preserves the legacy absolute-height path and adds a bounded,
    /// session-relative alternative for cameras where the same full stand
    /// renders below 1.10. The latter needs independent knee extension so a
    /// partial rise cannot become a count merely by lowering an absolute gate.
    private func qualifiesStanding(
        height: Float,
        baselineHeight: Float,
        averageKneeAngleDeg: Float?,
        bodyPosture: NativeSitToStandBodyPosture?,
    ) -> Bool {
        let baselineRise = height - baselineHeight
        if let bodyPosture {
            return bodyPosture == .standing && baselineRise >= Self.configuration.standingDelta
        }
        let legacy = height >= Self.configuration.legacyStandingMinimum
            && baselineRise >= Self.configuration.standingDelta
        let adaptive = baselineRise >= Self.configuration.standingDelta
            && (averageKneeAngleDeg?.isFinite ?? false)
            && (averageKneeAngleDeg ?? 0) >= Self.configuration.adaptiveStandingMinimumKneeExtensionDeg
        return legacy || adaptive
    }

    private func result(reason: String? = nil) -> NativeSitToStandGeometryResult {
        NativeSitToStandGeometryResult(
            status: state.rawValue,
            totalReps: totalReps,
            repetitionCompleted: false,
            reason: reason,
            baselineHeight: baselineHeight,
        )
    }
}

/// Stateful Pose-only feature extractor matching the model-owned 30-feature
/// order. It refuses missing/invalid points instead of filling feature values
/// with zero. The app never retains raw landmarks after this method returns.
final class NativeSitToStandFeatureExtractor {
    static let featureCount = 30
    static let minimumVisibility: Float = 0.40
    private static let minimumFrameIntervalMs = 45
    private static let maximumFrameIntervalMs = 100

    private var previousMeasurements: Measurements?
    private var previousTimestampMs: Int?
    private var sourceGeneration: Int?

    func reset() {
        previousMeasurements = nil
        previousTimestampMs = nil
        sourceGeneration = nil
    }

    func extract(_ snapshot: NativeFrameSnapshot) -> NativeSitToStandFeatureFrame {
        if let sourceGeneration, snapshot.sourceGeneration != sourceGeneration {
            reset()
        }
        sourceGeneration = snapshot.sourceGeneration
        guard !snapshot.inputIsMirrored else {
            previousMeasurements = nil
            previousTimestampMs = nil
            return NativeSitToStandFeatureFrame(
                timestampMs: snapshot.timestampMs,
                sourceGeneration: snapshot.sourceGeneration,
                featureVector: nil,
                pelvisHeightAboveAnklesNorm: nil,
                meanKneeAngleDeg: nil,
                wristSpanNorm: nil,
                reason: "source_mirrored",
                evidenceMetrics: nil,
            )
        }
        guard let current = measurements(from: snapshot.pose) else {
            previousMeasurements = nil
            previousTimestampMs = nil
            return NativeSitToStandFeatureFrame(
                timestampMs: snapshot.timestampMs,
                sourceGeneration: snapshot.sourceGeneration,
                featureVector: nil,
                pelvisHeightAboveAnklesNorm: nil,
                meanKneeAngleDeg: nil,
                wristSpanNorm: nil,
                reason: "pose_only_capture_qc_failed",
                evidenceMetrics: nil,
            )
        }

        var elapsedSeconds: Float?
        if let priorTimestampMs = previousTimestampMs {
            let elapsedMs = snapshot.timestampMs - priorTimestampMs
            guard elapsedMs >= Self.minimumFrameIntervalMs,
                  elapsedMs <= Self.maximumFrameIntervalMs else {
                previousMeasurements = nil
                previousTimestampMs = nil
                return NativeSitToStandFeatureFrame(
                    timestampMs: snapshot.timestampMs,
                    sourceGeneration: snapshot.sourceGeneration,
                    featureVector: nil,
                    pelvisHeightAboveAnklesNorm: nil,
                    meanKneeAngleDeg: nil,
                    wristSpanNorm: nil,
                    reason: "source_timeline_discontinuity",
                    evidenceMetrics: nil,
                )
            }
            elapsedSeconds = Float(elapsedMs) / 1_000
        }

        let prior = previousMeasurements
        let vector = current.featureVector(previous: prior, elapsedSeconds: elapsedSeconds)
        previousMeasurements = current
        previousTimestampMs = snapshot.timestampMs
        guard vector.count == Self.featureCount, vector.allSatisfy(\.isFinite) else {
            return NativeSitToStandFeatureFrame(
                timestampMs: snapshot.timestampMs,
                sourceGeneration: snapshot.sourceGeneration,
                featureVector: nil,
                pelvisHeightAboveAnklesNorm: nil,
                meanKneeAngleDeg: nil,
                wristSpanNorm: nil,
                reason: "non_finite_derived_feature",
                evidenceMetrics: nil,
            )
        }
        return NativeSitToStandFeatureFrame(
            timestampMs: snapshot.timestampMs,
            sourceGeneration: snapshot.sourceGeneration,
            featureVector: vector,
            pelvisHeightAboveAnklesNorm: current.pelvisHeightAboveAnklesNorm,
            meanKneeAngleDeg: current.meanKneeAngleDeg,
            wristSpanNorm: current.wristSpanNorm,
            reason: nil,
            evidenceMetrics: NativeSitToStandEvidenceMetrics(
                trunkViewPlaneTiltDeg: current.trunkViewPlaneTiltDeg,
                trunkLateralOffsetNorm: current.trunkLateralOffsetNorm,
                hipAngleDifferenceDeg: abs(current.leftHipAngleDeg - current.rightHipAngleDeg),
                kneeAngleDifferenceDeg: abs(current.leftKneeAngleDeg - current.rightKneeAngleDeg),
                footCenterOffsetFromPelvisNorm: current.footCenterOffsetFromPelvisNorm,
            ),
        )
    }

    private struct Point {
        let x: Float
        let y: Float
        let z: Float

        static func average(_ first: Point, _ second: Point) -> Point {
            Point(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2, z: (first.z + second.z) / 2)
        }
    }

    private struct Measurements {
        let pelvisHeightAboveAnklesNorm: Float
        let pelvisViewPlaneOffsetFromAnklesNorm: Float
        let trunkViewPlaneTiltDeg: Float
        let trunkLateralOffsetNorm: Float
        let leftHipAngleDeg: Float
        let rightHipAngleDeg: Float
        let leftKneeAngleDeg: Float
        let rightKneeAngleDeg: Float
        let leftAnkleProxyAngleDeg: Float
        let rightAnkleProxyAngleDeg: Float
        let stanceWidthNorm: Float
        let footCenterOffsetFromPelvisNorm: Float
        let leftWristToShoulderXNorm: Float
        let leftWristToShoulderYNorm: Float
        let rightWristToShoulderXNorm: Float
        let rightWristToShoulderYNorm: Float
        let leftElbowAngleDeg: Float
        let rightElbowAngleDeg: Float
        let leftArmElevationDeg: Float
        let rightArmElevationDeg: Float
        let wristSpanNorm: Float
        let torsoScale: Float
        let leftWrist: Point
        let rightWrist: Point

        var meanKneeAngleDeg: Float {
            (leftKneeAngleDeg + rightKneeAngleDeg) / 2
        }

        func featureVector(previous: Measurements?, elapsedSeconds: Float?) -> [Float] {
            let elapsed = elapsedSeconds ?? 0
            func delta(_ current: Float, _ prior: Float?) -> Float {
                guard let prior, elapsed > 0 else { return 0 }
                return (current - prior) / elapsed
            }
            func wristSpeed(_ current: Point, _ prior: Point?) -> Float {
                guard let prior, elapsed > 0 else { return 0 }
                return hypot(current.x - prior.x, current.y - prior.y) / torsoScale / elapsed
            }
            let pelvisHeightVelocity = delta(pelvisHeightAboveAnklesNorm, previous?.pelvisHeightAboveAnklesNorm)
            let pelvisOffsetVelocity = delta(pelvisViewPlaneOffsetFromAnklesNorm, previous?.pelvisViewPlaneOffsetFromAnklesNorm)
            let trunkTiltVelocity = delta(trunkViewPlaneTiltDeg, previous?.trunkViewPlaneTiltDeg)
            let trunkLateralVelocity = delta(trunkLateralOffsetNorm, previous?.trunkLateralOffsetNorm)
            return [
                pelvisHeightAboveAnklesNorm,
                pelvisHeightVelocity,
                pelvisViewPlaneOffsetFromAnklesNorm,
                pelvisOffsetVelocity,
                trunkViewPlaneTiltDeg / 90,
                Float(tanh(Double(trunkTiltVelocity / 90))),
                trunkLateralOffsetNorm,
                trunkLateralVelocity,
                leftHipAngleDeg / 180,
                rightHipAngleDeg / 180,
                abs(leftHipAngleDeg - rightHipAngleDeg) / 180,
                leftKneeAngleDeg / 180,
                rightKneeAngleDeg / 180,
                abs(leftKneeAngleDeg - rightKneeAngleDeg) / 180,
                leftAnkleProxyAngleDeg / 180,
                rightAnkleProxyAngleDeg / 180,
                abs(leftAnkleProxyAngleDeg - rightAnkleProxyAngleDeg) / 180,
                stanceWidthNorm,
                footCenterOffsetFromPelvisNorm,
                leftWristToShoulderXNorm,
                leftWristToShoulderYNorm,
                rightWristToShoulderXNorm,
                rightWristToShoulderYNorm,
                wristSpeed(leftWrist, previous?.leftWrist),
                wristSpeed(rightWrist, previous?.rightWrist),
                leftElbowAngleDeg / 180,
                rightElbowAngleDeg / 180,
                leftArmElevationDeg / 180,
                rightArmElevationDeg / 180,
                wristSpanNorm,
            ]
        }
    }

    private func measurements(from pose: [NativeLandmark]) -> Measurements? {
        func point(_ index: Int) -> Point? {
            guard pose.indices.contains(index) else { return nil }
            let value = pose[index]
            guard value.visibility >= Self.minimumVisibility,
                  value.x.isFinite, value.y.isFinite, value.z.isFinite else { return nil }
            return Point(x: value.x, y: value.y, z: value.z)
        }
        guard let nose = point(0),
              let leftShoulder = point(11), let rightShoulder = point(12),
              let leftElbow = point(13), let rightElbow = point(14),
              let leftWrist = point(15), let rightWrist = point(16),
              let leftHip = point(23), let rightHip = point(24),
              let leftKnee = point(25), let rightKnee = point(26),
              let leftAnkle = point(27), let rightAnkle = point(28),
              let leftFoot = point(31), let rightFoot = point(32) else {
            return nil
        }
        _ = nose
        let shoulderCenter = Point.average(leftShoulder, rightShoulder)
        let hipCenter = Point.average(leftHip, rightHip)
        let ankleCenter = Point.average(leftAnkle, rightAnkle)
        let footCenter = Point.average(leftFoot, rightFoot)
        let scale = distance(shoulderCenter, hipCenter)
        guard scale > 0.000_001 else { return nil }
        guard let leftHipAngle = angle(shoulderCenter, leftHip, leftKnee),
              let rightHipAngle = angle(shoulderCenter, rightHip, rightKnee),
              let leftKneeAngle = angle(leftHip, leftKnee, leftAnkle),
              let rightKneeAngle = angle(rightHip, rightKnee, rightAnkle),
              let leftAnkleAngle = angle(leftKnee, leftAnkle, leftFoot),
              let rightAnkleAngle = angle(rightKnee, rightAnkle, rightFoot),
              let leftElbowAngle = angle(leftShoulder, leftElbow, leftWrist),
              let rightElbowAngle = angle(rightShoulder, rightElbow, rightWrist),
              let trunkTilt = viewPlaneTilt(shoulderCenter, hipCenter),
              let leftArmElevation = armElevation(leftShoulder, leftElbow),
              let rightArmElevation = armElevation(rightShoulder, rightElbow) else {
            return nil
        }
        return Measurements(
            pelvisHeightAboveAnklesNorm: (ankleCenter.y - hipCenter.y) / scale,
            pelvisViewPlaneOffsetFromAnklesNorm: (hipCenter.x - ankleCenter.x) / scale,
            trunkViewPlaneTiltDeg: trunkTilt,
            trunkLateralOffsetNorm: (shoulderCenter.x - hipCenter.x) / scale,
            leftHipAngleDeg: leftHipAngle,
            rightHipAngleDeg: rightHipAngle,
            leftKneeAngleDeg: leftKneeAngle,
            rightKneeAngleDeg: rightKneeAngle,
            leftAnkleProxyAngleDeg: leftAnkleAngle,
            rightAnkleProxyAngleDeg: rightAnkleAngle,
            stanceWidthNorm: abs(leftAnkle.x - rightAnkle.x) / scale,
            footCenterOffsetFromPelvisNorm: (footCenter.x - hipCenter.x) / scale,
            leftWristToShoulderXNorm: (leftWrist.x - leftShoulder.x) / scale,
            leftWristToShoulderYNorm: (leftWrist.y - leftShoulder.y) / scale,
            rightWristToShoulderXNorm: (rightWrist.x - rightShoulder.x) / scale,
            rightWristToShoulderYNorm: (rightWrist.y - rightShoulder.y) / scale,
            leftElbowAngleDeg: leftElbowAngle,
            rightElbowAngleDeg: rightElbowAngle,
            leftArmElevationDeg: leftArmElevation,
            rightArmElevationDeg: rightArmElevation,
            wristSpanNorm: distance(leftWrist, rightWrist) / scale,
            torsoScale: scale,
            leftWrist: leftWrist,
            rightWrist: rightWrist,
        )
    }

    private func distance(_ left: Point, _ right: Point) -> Float {
        sqrt(pow(left.x - right.x, 2) + pow(left.y - right.y, 2) + pow(left.z - right.z, 2))
    }

    private func angle(_ first: Point, _ vertex: Point, _ third: Point) -> Float? {
        let left = (first.x - vertex.x, first.y - vertex.y, first.z - vertex.z)
        let right = (third.x - vertex.x, third.y - vertex.y, third.z - vertex.z)
        let leftNorm = sqrt(left.0 * left.0 + left.1 * left.1 + left.2 * left.2)
        let rightNorm = sqrt(right.0 * right.0 + right.1 * right.1 + right.2 * right.2)
        guard leftNorm > 0.000_001, rightNorm > 0.000_001 else { return nil }
        let cosine = max(-1, min(1, (left.0 * right.0 + left.1 * right.1 + left.2 * right.2) / (leftNorm * rightNorm)))
        return Float(acos(Double(cosine)) * 180 / .pi)
    }

    private func viewPlaneTilt(_ shoulder: Point, _ hip: Point) -> Float? {
        let horizontal = shoulder.x - hip.x
        let vertical = hip.y - shoulder.y
        guard hypot(horizontal, vertical) > 0.000_001 else { return nil }
        return Float(atan2(Double(horizontal), Double(vertical)) * 180 / .pi)
    }

    private func armElevation(_ shoulder: Point, _ elbow: Point) -> Float? {
        let horizontal = elbow.x - shoulder.x
        let vertical = elbow.y - shoulder.y
        guard hypot(horizontal, vertical) > 0.000_001 else { return nil }
        return Float(atan2(Double(horizontal), Double(vertical)) * 180 / .pi)
    }
}

struct NativeSitToStandOutput: Equatable {
    let captureQC: String
    let setupReason: String?
    let featureFrameCount: Int
    let geometryStatus: String
    let geometryReason: String?
    let geometryTotalReps: Int
    let geometryRepetitionCompleted: Bool
    let handsTogetherStatus: String
    let phase: String?
    let phaseStatus: String
    let phaseProbabilities: [Double]?
    let commentStatus: String
    let cue: String?
    let cueThai: String?
    let commentRepetitionCount: Int
    let isTrackingReady: Bool
    let evidenceMetrics: NativeSitToStandEvidenceMetrics?
    var bodyPosture: NativeSitToStandBodyPosture = .unknown
    var actionCueStatus: String? = nil
    var counterDiagnostic: String? = nil

    var totalReps: Int { geometryTotalReps }
}

/// UI-only normalized projection. It keeps camera/HUD rendering independent
/// from Bottle Grab's internal output type while preserving each module's
/// separate engine ownership and provenance.
struct NativePracticeOutput: Equatable {
    let phase: String?
    let captureQC: String
    let cue: String?
    let cueThai: String?
    let bufferedFrames: Int
    let posePoints: Int
    let handPoints: Int
    let handSide: String?
    let handSideSource: String?
    let detectorLatencyMs: Double
    let bottleStatus: String?
    let modelStatus: String
    let phaseStatus: String
    let hostCounterStatus: String?
    let hostCounterReason: String?
    let counterMode: String
    let setupState: String
    let setupReason: String?
    let framingWarning: String?
    let phaseDiagnosticCycles: Int?
    let isTrackingReady: Bool
    let score: Int?
    let reps: Int
    let totalReps: Int
    let repsTarget: Int
    let setsDone: Int
    let totalSets: Int
    let actionCueStatus: String?
    let counterDiagnostic: String?

    init(bottle output: NativeBottleGrabOutput) {
        actionCueStatus = nil
        counterDiagnostic = nil
        phase = output.phase
        captureQC = output.captureQC
        cue = output.cue
        cueThai = output.cueThai
        bufferedFrames = output.bufferedFrames
        posePoints = output.posePoints
        handPoints = output.handPoints
        handSide = output.handSide
        handSideSource = output.handSideSource
        detectorLatencyMs = output.detectorLatencyMs
        bottleStatus = output.bottleStatus
        modelStatus = output.modelStatus
        phaseStatus = output.phaseStatus
        hostCounterStatus = output.hostCounterStatus
        hostCounterReason = output.hostCounterReason
        counterMode = output.counterMode
        setupState = output.setupState
        setupReason = output.setupReason
        framingWarning = output.framingWarning
        phaseDiagnosticCycles = output.phaseDiagnosticCycles
        isTrackingReady = output.isTrackingReady
        score = output.score
        reps = output.reps
        totalReps = output.totalReps
        repsTarget = output.repsTarget
        setsDone = output.setsDone
        totalSets = output.totalSets
    }

    init(sitToStand output: NativeSitToStandOutput, exercise: NativeExercise) {
        actionCueStatus = output.actionCueStatus
        counterDiagnostic = output.counterDiagnostic
        phase = output.phase
        captureQC = output.captureQC
        cue = output.cue
        cueThai = output.cueThai
        bufferedFrames = output.featureFrameCount
        posePoints = output.isTrackingReady ? 33 : 0
        handPoints = 0
        handSide = nil
        handSideSource = nil
        detectorLatencyMs = 0
        bottleStatus = nil
        modelStatus = "sit_to_stand_v8_0_15_image_plane_geometry_experimental"
        phaseStatus = output.phaseStatus
        hostCounterStatus = output.geometryStatus
        hostCounterReason = output.geometryReason
        counterMode = "parallel_geometry_counter"
        setupState = output.isTrackingReady ? "tracking" : "positioning"
        setupReason = output.setupReason
        framingWarning = nil
        phaseDiagnosticCycles = output.commentRepetitionCount
        isTrackingReady = output.isTrackingReady
        score = nil
        reps = output.geometryTotalReps
        totalReps = output.geometryTotalReps
        repsTarget = exercise.reps
        setsDone = 0
        totalSets = exercise.sets
    }
}

/// V7.2 façade. Its Counter path and PhaseNet-comment path consume a feature
/// frame in parallel. The Pose-wrist admission gate is a deterministic counter
/// precondition; PhaseNet neither supplies it nor owns the repetition total.
final class NativeSitToStandV72AIModule {
    static let moduleID = "sit_to_stand_v7_ai_module"
    static let moduleVersion = "1.3.0-dev-image-plane-posture"
    static let exerciseID = "sit_to_stand"
    static let trackingProfile = "pose_only"
    static let engineIDs = [
        "mediapipe_pose_full_v1",
        "sit_to_stand_capture_qc_v1",
        "sit_to_stand_pose_wrist_admission_gate_v2",
        "sit_to_stand_geometry_counter_v2_image_plane",
        "sit_to_stand_phasenet_v1_comment_context",
        "sit_to_stand_normal_reference_comment_v1",
    ]

    typealias OutputHandler = (NativeFrameSnapshot, NativeSitToStandOutput) -> Void

    private let onOutput: OutputHandler
    private var pipeline: MediaPipePipeline!
    private let featureExtractor = NativeSitToStandFeatureExtractor()
    private var handsTogetherGate = NativeSitToStandHandsTogetherGate()
    private var geometryCounter = NativeSitToStandGeometryCounter()
    private let phaseCommentEngine = NativeSitToStandPhaseCommentEngine()
    /// Records only derived rule inputs after the existing counter/feature
    /// pipeline has made its decisions. It is strictly observer-only.
    private let ruleBasedEvidence = NativeSitToStandRuleBasedEvidenceV12Module()
    private var activeSourceGeneration: Int?
    private var lastGeometryTimestampMs: Int?

    var setupError: String? { pipeline.setupError }
    var inferenceDelegateName: String { pipeline.inferenceDelegateName }

    init(
        onOutput: @escaping OutputHandler = { _, _ in },
        onStatus: @escaping (String) -> Void = { _ in },
    ) {
        self.onOutput = onOutput
        self.pipeline = MediaPipePipeline(
            onSnapshot: { [weak self] snapshot in
                guard let self else { return }
                let output = self.ingest(snapshot)
                onOutput(snapshot, output)
            },
            onStatus: onStatus,
            enableBottleDetector: false,
            enableHand: false,
        )
    }

    func setCountingEnabled(_ enabled: Bool) {
        geometryCounter.setCountingEnabled(enabled)
        if !enabled {
            handsTogetherGate.reset()
        }
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
        resetForNewCaptureSource()
    }

    func resetForNewCaptureSource() {
        featureExtractor.reset()
        handsTogetherGate.reset()
        geometryCounter.resetForNewCaptureSource()
        phaseCommentEngine.reset()
        ruleBasedEvidence.resetForNewCaptureSource()
        activeSourceGeneration = nil
        lastGeometryTimestampMs = nil
    }

    /// A newly selected native exercise begins a separate local evidence
    /// session. Camera/lens replacements during that session use
    /// `resetForNewCaptureSource()` and retain already completed repetitions.
    func resetForNewSession() {
        featureExtractor.reset()
        handsTogetherGate.reset()
        geometryCounter.resetForNewCaptureSource()
        phaseCommentEngine.reset()
        ruleBasedEvidence.resetForNewSession()
        activeSourceGeneration = nil
        lastGeometryTimestampMs = nil
    }

    func currentRuleBasedSessionRecord() -> RuleBasedSessionRecord {
        ruleBasedEvidence.currentRecord()
    }

    func encodedCurrentRuleBasedSessionRecord() throws -> Data {
        try ruleBasedEvidence.encodedCurrentRecord()
    }

    func encodedFinalizedCurrentRuleBasedSessionRecord() throws -> Data {
        try ruleBasedEvidence.encodedFinalizedCurrentRecord()
    }

    @discardableResult
    func ingest(_ snapshot: NativeFrameSnapshot) -> NativeSitToStandOutput {
        if let activeSourceGeneration, snapshot.sourceGeneration != activeSourceGeneration {
            resetForNewCaptureSource()
        }
        activeSourceGeneration = snapshot.sourceGeneration
        let frame = featureExtractor.extract(snapshot)
        let observation = NativeSitToStandCounterObservation.extract(snapshot)
        // PhaseNet's 45–100 ms feature cadence is not a pose-detection gate.
        // A missed 15-Hz callback must not erase a visible, continuous cycle.
        // A real interruption still requires a fresh seated baseline.
        if let previous = lastGeometryTimestampMs {
            let interval = snapshot.timestampMs - previous
            if interval <= 0 || interval > 500 {
                geometryCounter.resetPartial()
                handsTogetherGate.reset()
            }
        }
        lastGeometryTimestampMs = snapshot.timestampMs
        let geometry: NativeSitToStandGeometryResult
        let handsTogether: NativeSitToStandHandsTogetherResult
        if let observation {
            handsTogether = handsTogetherGate.ingest(wristSpanNorm: observation.wristSpanNorm)
        } else {
            handsTogetherGate.reset()
            handsTogether = NativeSitToStandHandsTogetherResult(
                status: NativeSitToStandHandsTogetherGate.hasBothVisibleWrists(snapshot.pose)
                    ? "hands_not_evaluated"
                    : "hands_not_assessable",
                isAdmitted: false,
                cue: NativeSitToStandHandsTogetherGate.hasBothVisibleWrists(snapshot.pose)
                    ? nil
                    : "Keep both hands visible in the camera before starting.",
                cueThai: NativeSitToStandHandsTogetherGate.hasBothVisibleWrists(snapshot.pose)
                    ? nil
                    : "ให้เห็นมือทั้งสองข้างในกล้องก่อนเริ่ม",
            )
        }
        if let observation {
            geometry = geometryCounter.ingest(
                pelvisHeightAboveAnklesNorm: observation.pelvisHeightInShins,
                bodyPosture: observation.posture,
                timestampMs: frame.timestampMs,
                movementAuthorized: handsTogether.isAdmitted,
            )
        } else {
            geometryCounter.resetPartial()
            geometry = NativeSitToStandGeometryResult(
                status: frame.featureReady ? handsTogether.status : (handsTogether.status == "hands_not_assessable" ? handsTogether.status : "cannot_assess"),
                totalReps: geometryCounter.completedReps,
                repetitionCompleted: false,
                reason: frame.featureReady ? handsTogether.status : (frame.reason ?? handsTogether.status),
            )
        }
        if geometry.repetitionCompleted {
            handsTogetherGate.rearmForNextCycle()
        }
        let phase = phaseCommentEngine.ingest(frame)
        let gateCue = handsTogether.isAdmitted ? nil : handsTogether.cue
        let gateCueThai = handsTogether.isAdmitted ? nil : handsTogether.cueThai
        let output = NativeSitToStandOutput(
            // Pose Full can establish feature continuity, but it cannot
            // verify chair/seat/floor visibility or force/weight-bearing.
            // Do not label that narrower evidence as full Capture-QC.
            captureQC: observation != nil ? "pose_geometry_only" : "cannot_assess",
            setupReason: observation == nil ? (frame.reason ?? "pose_only_capture_qc_failed") : nil,
            featureFrameCount: phase.bufferedFrames,
            geometryStatus: handsTogether.isAdmitted ? geometry.status : handsTogether.status,
            geometryReason: handsTogether.isAdmitted ? geometry.reason : handsTogether.status,
            geometryTotalReps: geometry.totalReps,
            geometryRepetitionCompleted: geometry.repetitionCompleted,
            handsTogetherStatus: handsTogether.status,
            phase: phase.phase,
            phaseStatus: phase.status,
            phaseProbabilities: phase.probabilities,
            commentStatus: gateCue == nil ? phase.commentStatus : "pose_wrist_admission_gate",
            cue: gateCue ?? phase.cue,
            cueThai: gateCueThai ?? phase.cueThai,
            commentRepetitionCount: phase.completedCommentCycles,
            isTrackingReady: observation != nil,
            evidenceMetrics: frame.evidenceMetrics,
            bodyPosture: observation?.posture ?? .unknown,
            actionCueStatus: actionCueStatus(observation: observation, geometry: geometry, hands: handsTogether),
            counterDiagnostic: observation.map {
                let baseline = geometry.baselineHeight.map { String(format: "%.2f", $0) } ?? "—"
                return "\($0.posture.rawValue) · leg \(String(format: "%.2f", $0.thighShinRatio)) · base \(baseline) · \(geometry.status)"
            } ?? "posture unknown · \(frame.reason ?? "pose_geometry_invalid")",
        )
        ruleBasedEvidence.ingest(frame: frame, output: output)
        return output
    }

    private func actionCueStatus(
        observation: NativeSitToStandCounterObservation?,
        geometry: NativeSitToStandGeometryResult,
        hands: NativeSitToStandHandsTogetherResult,
    ) -> String {
        guard let observation else { return "posture_unknown" }
        guard hands.isAdmitted else { return hands.status }
        switch geometry.status {
        case "awaiting_seated_baseline":
            if observation.posture == .standing { return "awaiting_seated_baseline" }
            return observation.posture == .seated ? "seated_settling" : "posture_unknown"
        case "seated_rest":
            guard observation.posture == .seated else { return "posture_unknown" }
            return geometry.reason == "seated_settling" || geometry.reason == "counting_disabled"
                ? "seated_settling" : "seated_rest"
        case "standing_hold":
            return geometry.reason == "standing_hold_pending" ? "standing_hold" : "standing_ready_to_sit"
        default:
            return geometry.status
        }
    }
}
