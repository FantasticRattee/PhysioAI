import Foundation

/// A local, developer-only movement-boundary counter for the Bottle Grab
/// native preview. It deliberately reuses the PhaseNet V2 feature adapter's
/// wrist/finger geometry but is **not** the frozen V1.1 hybrid decoder:
/// V1.1 requires all PhaseNet phases and is not app-authorized. This host
/// policy never fabricates a phase; it records an explicit geometry-only
/// completion when a real open → reach → grasp → release sequence is
/// observed. Return motion is useful patient guidance, but it is not an
/// additional hidden requirement for the repetition boundary.
///
/// Decision scope: experimental repetition boundary only. It does not infer
/// bottle contact, grip force, correctness, a score, or clinical adherence.
struct NativeBottleGrabHostCompletionResult: Equatable {
    let totalCycles: Int
    let didCompleteCycle: Bool
    let status: String
    let reason: String?
    let isArmed: Bool

    // V8 retains the frozen continuous-grasp geometry evidence but aligns the
    // host transport envelope with the bounded native Pose + Hand delivery:
    // three real stable reopen rows after a stable grasp complete the cycle.
    // The contract has no mandatory wrist-departure, wrist-return, or
    // terminal-rest gate: a patient may already be in the bottle work area.
    // The geometry lane observes release directly and never fabricates a
    // phase. Keep this identity distinct from every frozen model/baseline
    // artifact.
    static let counterProvenance = "experimental_native_host_completion_v8_bounded_native_delivery_continuous_grasp_diagnostic"
}

private struct NativeBottleGrabHostMotionObservation: Equatable {
    let timestampMs: Int
    let sourceGeneration: Int
    let wristX: Float
    let wristY: Float
    let aperture: Float
    let flexion: Float

    static func make(from snapshot: NativeFrameSnapshot) -> NativeBottleGrabHostMotionObservation? {
        // Share the frozen PhaseNet V2 static-feature calculation. Passing no
        // predecessor means motion deltas are unused; all four values below
        // are direct same-frame geometry rather than interpolated evidence.
        guard let frame = NativePhaseNetV2FeatureAdapter.makeFeatureFrame(
            snapshot: snapshot,
            previous: nil,
        ).frame,
        frame.features.count == 20 else {
            return nil
        }
        return NativeBottleGrabHostMotionObservation(
            timestampMs: snapshot.timestampMs,
            sourceGeneration: snapshot.sourceGeneration,
            wristX: frame.features[1],
            wristY: frame.features[2],
            aperture: frame.features[16],
            flexion: frame.features[15],
        )
    }
}

/// Host-side reliability lane for physical camera preview. App-V5 exposes it
/// as a diagnostic comparison; App V6 uses the same geometry-first policy as
/// its authoritative experimental repetition counter.
///
/// The numeric thresholds are copied from the frozen real-input V1.1/V1.2
/// completion contracts, while its semantic policy is intentionally new and
/// separately versioned: a stable *open* rest reference is used in place of a
/// PhaseNet `preshape` endpoint because a causal 30-frame PhaseNet window may
/// arrive after the user has already started reaching. It is therefore an
/// experimental native policy, not V1.1 parity and not a Baseline #4 runtime.
final class NativeBottleGrabHostCompletionCounter {
    static let provenance = NativeBottleGrabHostCompletionResult.counterProvenance
    static let v6Provenance = "experimental_app_v6_1_hand_robustness_geometry_first_counter_v1"

    private static let minimumSampleIntervalMs = 66
    /// CameraSession may hold one joined Pose + Hand inference for up to
    /// 350 ms before admitting the newest real source frame. 450 ms accepts
    /// that bounded delivery envelope without padding, interpolation, stale
    /// feature reuse, or phase fabrication. This is V8 host-diagnostic
    /// transport policy, not a change to any frozen PhaseNet/V1.x artifact.
    private static let maximumObservationGapMs = 450
    private static let restSampleCount = 3
    private static let restWristStabilityArmScale: Float = 0.08
    private static let apertureCloseDeltaPalmRatio: Float = 0.25
    private static let flexionCloseDeltaNormalized: Float = 0.12
    private static let apertureOpenDeltaPalmRatio: Float = 0.25
    private static let flexionOpenDeltaNormalized: Float = 0.12
    // Reuse the published V1.1 development-contract temporal guardrails.
    // They are lifecycle protection, not values fitted against unseen traces.
    private static let maximumRepetitionDurationMs = 20_000
    private static let maximumNoProgressDurationMs = 8_000
    /// The V1.1/V1.2 geometry contracts require three consecutive real
    /// geometry observations. Use that same count for the closing/reopening
    /// edge; a single jittery Hand Landmarker frame may not create a grasp or
    /// release.
    private static let stableGeometryObservationCount = 3

    private enum Stage: String {
        case collectingRest = "collecting_rest"
        case armed = "armed"
        case grasped = "grasped"
    }

    private struct RestReference {
        let openAperture: Float
        let openFlexion: Float
    }

    private var stage: Stage = .collectingRest
    private var restSamples: [NativeBottleGrabHostMotionObservation] = []
    private var restReference: RestReference?
    private var sourceGeneration: Int?
    private var lastIncomingTimestampMs: Int?
    private var lastSampleTimestampMs: Int?
    private var closeCount = 0
    private var reopenCount = 0
    private var reopenSamples: [NativeBottleGrabHostMotionObservation] = []
    private var closedApertureMinimum: Float?
    private var closedFlexionMaximum: Float?
    private var cycleStartedAtMs: Int?
    private var lastProgressAtMs: Int?
    /// Positioning may collect a baseline, but a patient-facing repetition is
    /// not allowed to complete until the countdown has finished. Enabling a
    /// session discards that pre-start baseline so movement during countdown
    /// cannot become the first counted repetition. After a completed release,
    /// the real reopened rows re-arm the next continuous repetition.
    private var countingEnabled = false
    private(set) var totalCycles = 0
    private(set) var lastResetReason: String?

    func resetAll(reason: String) {
        totalCycles = 0
        sourceGeneration = nil
        countingEnabled = false
        resetPartial(reason: reason)
    }

    func setCountingEnabled(_ enabled: Bool) {
        guard countingEnabled != enabled else { return }
        countingEnabled = enabled
        // Never bridge a positioning/countdown baseline into an active
        // session. Completed cycles remain visible, but the first one must
        // establish fresh three-frame open evidence after activation.
        resetPartial(reason: enabled ? "practice_started_rebaseline" : "practice_not_active")
    }

    /// Returns state for an observation the engine intentionally refuses to
    /// ingest (for example, a late callback from an older capture source).
    /// It is side-effect free: rejected input must never rewrite a valid
    /// source timeline or revive a partial movement.
    func currentResult(reason: String? = nil) -> NativeBottleGrabHostCompletionResult {
        result(didCompleteCycle: false, reason: reason)
    }

    /// Preserves previously completed developer cycles but discards all
    /// evidence that could otherwise bridge a source/camera/lens change.
    func resetPartial(reason: String) {
        stage = .collectingRest
        restSamples.removeAll(keepingCapacity: true)
        restReference = nil
        lastIncomingTimestampMs = nil
        lastSampleTimestampMs = nil
        closeCount = 0
        reopenCount = 0
        reopenSamples.removeAll(keepingCapacity: true)
        closedApertureMinimum = nil
        closedFlexionMaximum = nil
        cycleStartedAtMs = nil
        lastProgressAtMs = nil
        lastResetReason = reason
    }

    /// A temporarily missing pose/hand callback never turns into synthetic
    /// geometry. It is tolerated only within the V8 450 ms bounded native
    /// delivery envelope; a longer interruption discards the partial cycle.
    @discardableResult
    func noteUnavailable(snapshot: NativeFrameSnapshot, reason: String) -> NativeBottleGrabHostCompletionResult {
        if let sourceGeneration, sourceGeneration != snapshot.sourceGeneration {
            self.sourceGeneration = snapshot.sourceGeneration
            resetPartial(reason: "source_generation_changed")
        } else if sourceGeneration == nil {
            sourceGeneration = snapshot.sourceGeneration
        }
        if let lastIncomingTimestampMs,
           snapshot.timestampMs <= lastIncomingTimestampMs {
            resetPartial(reason: "timestamp_regression")
            self.lastIncomingTimestampMs = snapshot.timestampMs
            return result(didCompleteCycle: false, reason: "timestamp_regression")
        }
        if let lastSampleTimestampMs,
           snapshot.timestampMs - lastSampleTimestampMs > Self.maximumObservationGapMs {
            resetPartial(reason: reason)
        }
        // An unavailable callback is still a real timeline event. Preserve
        // its timestamp after a reset so a late old callback cannot evade the
        // next timestamp-regression guard.
        lastIncomingTimestampMs = snapshot.timestampMs
        return result(didCompleteCycle: false, reason: reason)
    }

    @discardableResult
    func ingest(_ snapshot: NativeFrameSnapshot) -> NativeBottleGrabHostCompletionResult {
        guard let observation = NativeBottleGrabHostMotionObservation.make(from: snapshot) else {
            return noteUnavailable(snapshot: snapshot, reason: "host_feature_unavailable")
        }
        return ingest(observation)
    }

    private func ingest(_ observation: NativeBottleGrabHostMotionObservation) -> NativeBottleGrabHostCompletionResult {
        if let sourceGeneration, sourceGeneration != observation.sourceGeneration {
            self.sourceGeneration = observation.sourceGeneration
            resetPartial(reason: "source_generation_changed")
        } else if sourceGeneration == nil {
            sourceGeneration = observation.sourceGeneration
        }

        if let lastIncomingTimestampMs,
           observation.timestampMs <= lastIncomingTimestampMs {
            resetPartial(reason: "timestamp_regression")
            self.lastIncomingTimestampMs = observation.timestampMs
            return result(didCompleteCycle: false, reason: "timestamp_regression")
        }

        if let lastSampleTimestampMs {
            let gap = observation.timestampMs - lastSampleTimestampMs
            if gap > Self.maximumObservationGapMs {
                resetPartial(reason: "observation_gap")
            } else if gap < Self.minimumSampleIntervalMs {
                return result(didCompleteCycle: false, reason: nil)
            }
        }
        // `resetPartial` intentionally clears the timeline. Record this
        // accepted real observation afterwards so the next late callback is
        // still rejected as a regression.
        lastIncomingTimestampMs = observation.timestampMs
        lastSampleTimestampMs = observation.timestampMs

        let didCompleteCycle: Bool
        switch stage {
        case .collectingRest:
            collectRest(observation)
            didCompleteCycle = false
        case .armed, .grasped:
            didCompleteCycle = advanceCycle(with: observation)
        }
        return result(didCompleteCycle: didCompleteCycle, reason: nil)
    }

    private func collectRest(_ observation: NativeBottleGrabHostMotionObservation) {
        restSamples.append(observation)
        if restSamples.count > Self.restSampleCount {
            restSamples.removeFirst(restSamples.count - Self.restSampleCount)
        }
        guard restSamples.count == Self.restSampleCount else { return }

        let wristX = median(restSamples.map(\.wristX))
        let wristY = median(restSamples.map(\.wristY))
        let apertureValues = restSamples.map(\.aperture)
        let flexionValues = restSamples.map(\.flexion)
        let wristIsStable = restSamples.allSatisfy {
            hypotf($0.wristX - wristX, $0.wristY - wristY) <= Self.restWristStabilityArmScale
        }
        let apertureIsStable = (apertureValues.max() ?? 0) - (apertureValues.min() ?? 0)
            <= Self.apertureCloseDeltaPalmRatio
        let flexionIsStable = (flexionValues.max() ?? 0) - (flexionValues.min() ?? 0)
            <= Self.flexionCloseDeltaNormalized
        let openAperture = apertureValues.max() ?? observation.aperture
        let openFlexion = flexionValues.min() ?? observation.flexion
        // This is a deliberately conservative *open* test using the existing
        // contract deltas. It prevents a fully closed, static hand from being
        // accepted as a fresh "open → close" reference without inventing a
        // dataset-tuned absolute threshold.
        let looksOpen = openAperture >= Self.apertureCloseDeltaPalmRatio
            && openFlexion <= 1 - Self.flexionCloseDeltaNormalized
        guard wristIsStable, apertureIsStable, flexionIsStable, looksOpen else {
        // Keep a sliding real-frame window. The patient does not have to
            // restart manually after a brief movement or landmark jitter.
            lastResetReason = "unstable_open_rest"
            return
        }

        restReference = RestReference(
            // A stable open reference is calculated from real, same-frame
            // observations only. It is not a fabricated `preshape` phase.
            openAperture: openAperture,
            openFlexion: openFlexion,
        )
        restSamples.removeAll(keepingCapacity: true)
        stage = .armed
        lastResetReason = nil
    }

    private func advanceCycle(with observation: NativeBottleGrabHostMotionObservation) -> Bool {
        guard let restReference else {
            resetPartial(reason: "missing_rest_reference")
            return false
        }
        if stage != .armed,
           let cycleStartedAtMs,
           observation.timestampMs - cycleStartedAtMs > Self.maximumRepetitionDurationMs {
            resetPartial(reason: "repetition_timeout")
            collectRest(observation)
            return false
        }
        if stage != .armed,
           let lastProgressAtMs,
           observation.timestampMs - lastProgressAtMs > Self.maximumNoProgressDurationMs {
            // Never leave a patient-facing UI silently armed in a stale
            // movement state. This uses the frozen V1.1 no-progress lifetime
            // and requires a fresh open baseline before another attempt.
            resetPartial(reason: "no_progress_timeout")
            collectRest(observation)
            return false
        }
        if stage == .armed {
            // A user may move during the countdown. That attempt must not be
            // counted later because enabling always clears this baseline and
            // requires a new three-row open reference.
            guard countingEnabled else { return false }
            let closedNow = observation.aperture
                <= restReference.openAperture - Self.apertureCloseDeltaPalmRatio
                && observation.flexion
                >= restReference.openFlexion + Self.flexionCloseDeltaNormalized
            closeCount = closedNow ? closeCount + 1 : 0
            if closedNow {
                closedApertureMinimum = min(closedApertureMinimum ?? observation.aperture, observation.aperture)
                closedFlexionMaximum = max(closedFlexionMaximum ?? observation.flexion, observation.flexion)
            } else {
                // Do not combine a low aperture from one noisy frame with a
                // high flexion from another. Both must co-occur, repeatedly.
                closedApertureMinimum = nil
                closedFlexionMaximum = nil
            }
            if closeCount >= Self.stableGeometryObservationCount {
                stage = .grasped
                cycleStartedAtMs = observation.timestampMs
                lastProgressAtMs = observation.timestampMs
            }
            return false
        }

        if stage == .grasped {
            let apertureReference = closedApertureMinimum ?? observation.aperture
            let flexionReference = closedFlexionMaximum ?? observation.flexion
            let reopenedNow = observation.aperture
                >= apertureReference + Self.apertureOpenDeltaPalmRatio
                && observation.flexion
                <= flexionReference - Self.flexionOpenDeltaNormalized
            reopenCount = reopenedNow ? reopenCount + 1 : 0
            if reopenedNow {
                reopenSamples.append(observation)
                if reopenSamples.count > Self.stableGeometryObservationCount {
                    reopenSamples.removeFirst(reopenSamples.count - Self.stableGeometryObservationCount)
                }
            } else {
                // The next completion must use a consecutive real release
                // sequence rather than a mixture of separated noisy rows.
                reopenSamples.removeAll(keepingCapacity: true)
            }
            if reopenedNow,
               reopenCount >= Self.stableGeometryObservationCount {
                lastProgressAtMs = observation.timestampMs
                // A stable re-open after a confirmed grasp is the direct
                // real-geometry representation of release. The frozen V1.2
                // contract accepts release OR return; do not reject a true
                // release merely because the wrist has not returned yet.
                return completeCycle()
            }
        }

        return false
    }

    private func completeCycle() -> Bool {
        totalCycles += 1
        // V1.2 continuous-grasp semantics re-arm from the three real
        // reopened rows that ended this cycle. This still requires a fresh
        // close transition for the next count, but does not make the patient
        // pause for another three-row set-start baseline between repetitions.
        let rearmReference: RestReference? = reopenSamples.count == Self.stableGeometryObservationCount
            ? RestReference(
                openAperture: reopenSamples.map(\.aperture).max() ?? 0,
                openFlexion: reopenSamples.map(\.flexion).min() ?? 1,
            )
            : nil
        stage = rearmReference == nil ? .collectingRest : .armed
        restSamples.removeAll(keepingCapacity: true)
        self.restReference = rearmReference
        closeCount = 0
        reopenCount = 0
        reopenSamples.removeAll(keepingCapacity: true)
        closedApertureMinimum = nil
        closedFlexionMaximum = nil
        cycleStartedAtMs = nil
        lastProgressAtMs = nil
        lastResetReason = nil
        return true
    }

    private func result(didCompleteCycle: Bool, reason: String?) -> NativeBottleGrabHostCompletionResult {
        NativeBottleGrabHostCompletionResult(
            totalCycles: totalCycles,
            didCompleteCycle: didCompleteCycle,
            status: stage.rawValue,
            reason: reason ?? lastResetReason,
            isArmed: stage != .collectingRest,
        )
    }

    private func median(_ values: [Float]) -> Float {
        let ordered = values.sorted()
        guard !ordered.isEmpty else { return 0 }
        let middle = ordered.count / 2
        return ordered.count.isMultiple(of: 2)
            ? (ordered[middle - 1] + ordered[middle]) / 2
            : ordered[middle]
    }
}
