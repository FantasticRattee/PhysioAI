import XCTest
@testable import PhysioAINative

final class NativeBottleGrabFullCycleTests: XCTestCase {
    func testFullFrozenOrderCycleCountsOnceOnlyAfterFinalRest() {
        let policy = NativeBottleGrabFullCyclePolicy(minStablePredictions: 2)
        policy.setCountingEnabled(true)
        var timestamp = 0

        emit("start_or_rest", to: policy, timestamp: &timestamp)
        emit("reach", to: policy, timestamp: &timestamp)
        emit("preshape", to: policy, timestamp: &timestamp)
        emit("grasp", to: policy, timestamp: &timestamp)
        emit("release", to: policy, timestamp: &timestamp)
        emit("return", to: policy, timestamp: &timestamp)

        XCTAssertEqual(policy.totalCycles, 0)
        XCTAssertEqual(policy.currentPhase, "return")

        emit("start_or_rest", to: policy, timestamp: &timestamp)

        XCTAssertEqual(policy.totalCycles, 1)
        XCTAssertEqual(policy.currentPhase, "start_or_rest")
        XCTAssertNil(policy.lastResetReason)
    }

    func testReachReturnWithoutGraspAndReleaseNeverCounts() {
        let policy = NativeBottleGrabFullCyclePolicy(minStablePredictions: 2)
        policy.setCountingEnabled(true)
        var timestamp = 0

        emit("start_or_rest", to: policy, timestamp: &timestamp)
        emit("reach", to: policy, timestamp: &timestamp)
        emit("preshape", to: policy, timestamp: &timestamp)
        emit("return", to: policy, timestamp: &timestamp)

        XCTAssertEqual(policy.totalCycles, 0)
        XCTAssertEqual(policy.lastResetReason, "out_of_order_phase")

        // A new rest baseline after the rejected segment may be accepted, but
        // it cannot retroactively complete the skipped grasp/release path.
        emit("start_or_rest", to: policy, timestamp: &timestamp)
        XCTAssertEqual(policy.totalCycles, 0)
    }

    func testPreshapeBeforeReachIsRejectedRatherThanRelabelled() {
        let policy = NativeBottleGrabFullCyclePolicy(minStablePredictions: 2)
        policy.setCountingEnabled(true)
        var timestamp = 0

        emit("start_or_rest", to: policy, timestamp: &timestamp)
        emit("preshape", to: policy, timestamp: &timestamp)

        XCTAssertEqual(policy.totalCycles, 0)
        XCTAssertEqual(policy.lastResetReason, "out_of_order_phase")
    }

    func testPhasePolicyRequiresANewRestBaselineAfterPracticeStarts() {
        let policy = NativeBottleGrabFullCyclePolicy(minStablePredictions: 2)
        var timestamp = 0

        // Positioning/countdown endpoints are never retained.
        emit("start_or_rest", to: policy, timestamp: &timestamp)
        emit("reach", to: policy, timestamp: &timestamp)
        policy.setCountingEnabled(true)

        // The remaining tail of that pre-start attempt cannot complete.
        emit("preshape", to: policy, timestamp: &timestamp)
        emit("grasp", to: policy, timestamp: &timestamp)
        emit("release", to: policy, timestamp: &timestamp)
        emit("return", to: policy, timestamp: &timestamp)
        emit("start_or_rest", to: policy, timestamp: &timestamp)
        XCTAssertEqual(policy.totalCycles, 0)

        // A fresh active rest→…→return→rest sequence can count.
        emit("reach", to: policy, timestamp: &timestamp)
        emit("preshape", to: policy, timestamp: &timestamp)
        emit("grasp", to: policy, timestamp: &timestamp)
        emit("release", to: policy, timestamp: &timestamp)
        emit("return", to: policy, timestamp: &timestamp)
        emit("start_or_rest", to: policy, timestamp: &timestamp)
        XCTAssertEqual(policy.totalCycles, 1)
    }

    func testSetupGateTreatsAFullBodyFramingMissAsWarningNotModelBlocker() {
        let ready = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        XCTAssertEqual(NativeBottleGrabSetupGate.evaluate(ready).reason, nil)

        var missingAnkle = ready
        var pose = missingAnkle.pose
        pose[27] = NativeLandmark(x: 0.5, y: 0.98, z: 0, visibility: 0.2)
        missingAnkle = NativeFrameSnapshot(
            timestampMs: ready.timestampMs,
            pose: pose,
            hand: ready.hand,
            handSide: ready.handSide,
            handScore: ready.handScore,
            detectorLatencyMs: ready.detectorLatencyMs,
        )
        // PhaseNet V2 does not consume the ankle. A transient ankle miss must
        // not continually clear the valid left-arm + hand input window.
        XCTAssertNil(NativeBottleGrabSetupGate.evaluate(missingAnkle).reason)

        let wrongSide = NativeFrameSnapshot(
            timestampMs: ready.timestampMs,
            pose: ready.pose,
            hand: ready.hand,
            handSide: "Right",
            handScore: 0.98,
            detectorLatencyMs: ready.detectorLatencyMs,
        )
        XCTAssertEqual(NativeBottleGrabSetupGate.evaluate(wrongSide).reason, "wrong_anatomical_side")
    }

    func testSetupGateNamesAMissingRequiredArmFeature() {
        let ready = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = ready.pose
        pose[13] = NativeLandmark(x: 0.32, y: 0.53, z: 0, visibility: 0.2)
        let missingElbow = NativeFrameSnapshot(
            timestampMs: ready.timestampMs,
            pose: pose,
            hand: ready.hand,
            handSide: ready.handSide,
            handScore: ready.handScore,
            detectorLatencyMs: ready.detectorLatencyMs,
        )

        XCTAssertEqual(
            NativeBottleGrabSetupGate.evaluate(missingElbow).reason,
            "missing_required_pose_13",
        )
    }

    func testSetupGateRejectsAnOutOfFrameHandLandmark() {
        var snapshot = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var hand = snapshot.hand
        hand[8] = NativeLandmark(x: 1.10, y: hand[8].y, z: hand[8].z, visibility: hand[8].visibility)
        snapshot = NativeFrameSnapshot(
            timestampMs: snapshot.timestampMs,
            pose: snapshot.pose,
            hand: hand,
            handSide: snapshot.handSide,
            handScore: snapshot.handScore,
            detectorLatencyMs: snapshot.detectorLatencyMs,
        )

        XCTAssertEqual(NativeBottleGrabSetupGate.evaluate(snapshot).reason, "missing_left_hand")
    }

    func testPracticeActivationCancelsCountdownWhenReadinessDrops() {
        XCTAssertEqual(
            NativePracticeActivationPolicy.phaseAfterReadinessUpdate(
                current: .positioning,
                isTrackingReady: true,
            ),
            .countdown,
        )
        XCTAssertEqual(
            NativePracticeActivationPolicy.phaseAfterReadinessUpdate(
                current: .countdown,
                isTrackingReady: false,
            ),
            .positioning,
        )
        XCTAssertEqual(
            NativePracticeActivationPolicy.phaseAtCountdownCompletion(
                isTrackingReady: false,
            ),
            .positioning,
        )
    }

    func testEngineBuffersAFeatureReadyFrameDespiteASoftFramingWarning() {
        let engine = NativeBottleGrabEngine(phaseTracker: NativeFixturePhaseTracker())
        let ready = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = ready.pose
        pose[27] = NativeLandmark(x: 0.5, y: 0.98, z: 0, visibility: 0.2)
        let ankleWarningOnly = NativeFrameSnapshot(
            timestampMs: ready.timestampMs,
            pose: pose,
            hand: ready.hand,
            handSide: ready.handSide,
            handScore: ready.handScore,
            detectorLatencyMs: ready.detectorLatencyMs,
        )

        let output = engine.ingest(ankleWarningOnly)

        XCTAssertEqual(output.captureQC, "can_assess")
        XCTAssertEqual(output.setupState, "baselining")
        XCTAssertEqual(output.bufferedFrames, 1)
        XCTAssertEqual(output.framingWarning, "framing_low_visibility_pose_27")
        XCTAssertNil(output.setupReason)
    }

    func testPhaseWindowRejectsTimelineGapAndDoesNotBridgeStaleFrames() {
        var accumulator = NativePhaseNetV2WindowAccumulator()
        for frame in 0..<3 {
            let result = accumulator.push(
                features: Array(repeating: Float(frame), count: 20),
                timestampMs: frame * 67,
            )
            XCTAssertEqual(result.status, "buffering")
        }

        let reset = accumulator.push(
            features: Array(repeating: 4, count: 20),
            timestampMs: 400,
        )
        XCTAssertEqual(reset.status, "reset")
        XCTAssertEqual(reset.reason, "source_timeline_discontinuity")
        XCTAssertEqual(accumulator.bufferedFrameCount, 0)
    }

    func testEngineResetsPartialCycleWhenCaptureSourceGenerationChanges() {
        let engine = NativeBottleGrabEngine(phaseTracker: NativeFixturePhaseTracker())

        // The scripted tracker has armed rest and accepted the first `reach`
        // by this point. A replacement source must clear that partial cycle
        // rather than let it continue under a new camera/lens configuration.
        for frame in 1...34 {
            _ = engine.ingest(NativeFixtureProvider.fullBodySnapshot(frame: frame))
        }
        let old = NativeFixtureProvider.fullBodySnapshot(frame: 35)
        let replacement = NativeFrameSnapshot(
            timestampMs: old.timestampMs + 1_000,
            sourceGeneration: 1,
            pose: old.pose,
            hand: old.hand,
            handSide: old.handSide,
            handScore: old.handScore,
            detectorLatencyMs: old.detectorLatencyMs,
        )

        let output = engine.ingest(replacement)

        XCTAssertEqual(output.totalReps, 0)
        XCTAssertEqual(output.bufferedFrames, 1)
        XCTAssertEqual(output.setupState, "baselining")
    }

    func testRealPhaseNetTrackerEmitsOnePredictionForContiguous15HzFixtureFrames() {
        let tracker = NativePhaseNetV2Tracker(bundle: Bundle(for: NativePhaseNetV2Runtime.self))
        var result: NativePhaseTrackingResult?

        for frame in 1...NativePhaseNetV2WindowAccumulator.sequenceLength {
            result = tracker.ingest(NativeFixtureProvider.fullBodySnapshot(frame: frame))
        }

        XCTAssertEqual(result?.status, "phase_ready")
        XCTAssertTrue(result?.isNewPrediction ?? false)
        XCTAssertNotNil(result?.prediction)
        XCTAssertEqual(result?.prediction?.probabilities.count, NativePhaseNetV2Runtime.classOrder.count)
    }

    func testTrackerDoesNotReturnAStalePredictionForASubCadenceFrame() {
        let tracker = NativePhaseNetV2Tracker(bundle: Bundle(for: NativePhaseNetV2Runtime.self))
        var result: NativePhaseTrackingResult?
        for frame in 1...NativePhaseNetV2WindowAccumulator.sequenceLength {
            result = tracker.ingest(NativeFixtureProvider.fullBodySnapshot(frame: frame))
        }
        XCTAssertTrue(result?.isNewPrediction ?? false)
        let latest = NativeFixtureProvider.fullBodySnapshot(frame: NativePhaseNetV2WindowAccumulator.sequenceLength)
        let subCadence = NativeFrameSnapshot(
            timestampMs: latest.timestampMs + 10,
            pose: latest.pose,
            hand: latest.hand,
            handSide: latest.handSide,
            handScore: latest.handScore,
            detectorLatencyMs: latest.detectorLatencyMs,
        )

        let sampled = tracker.ingest(subCadence)

        XCTAssertEqual(sampled.status, "sampling")
        XCTAssertNil(sampled.prediction)
        XCTAssertFalse(sampled.isNewPrediction)
    }

    func testNativeCueUsesTheBaseline4FixedFingerMessageAfterSufficientEvidence() {
        let engine = NativeBottleGrabEngine(phaseTracker: NativeFixturePhaseTracker())
        var output: NativeBottleGrabOutput?
        for frame in 1...5 {
            let base = NativeFixtureProvider.fullBodySnapshot(frame: frame)
            output = engine.ingest(NativeFrameSnapshot(
                timestampMs: base.timestampMs,
                pose: base.pose,
                hand: qualifiedRuleWrapHand(anchoredAt: base.pose[15]),
                handSide: "Left",
                handScore: 0.98,
                detectorLatencyMs: base.detectorLatencyMs,
            ))
        }

        XCTAssertEqual(
            output?.cue,
            "While grasping the bottle, try wrapping your fingers around it more completely.",
        )
        XCTAssertEqual(output?.cueThai, "ขณะกำขวด ลองโอบนิ้วรอบขวดให้ครบขึ้น")
    }

    func testActivePhaseFullCycleIsTheOnlyPatientVisibleRepSource() {
        // PhaseNet's ordered endpoint sequence is the approved experimental
        // patient-visible repetition boundary. These frames deliberately keep
        // hand geometry static, so the V7/V8 host diagnostic cannot complete
        // a geometry cycle and cannot be the source of this rep.
        let engine = NativeBottleGrabEngine(
            phaseTracker: PhaseScriptTracker(phases: fullPhaseCycle()),
        )
        engine.setCountingEnabled(true)

        var output: NativeBottleGrabOutput?
        for (index, _) in fullPhaseCycle().enumerated() {
            output = engine.ingest(NativeFixtureProvider.fullBodySnapshot(frame: index + 1))
        }

        XCTAssertEqual(output?.totalReps, 1)
        XCTAssertEqual(
            output?.repCounterProvenance,
            "experimental_native_phasenet_v2_full_cycle_lifecycle_v1",
        )
        XCTAssertEqual(output?.hostDiagnosticCycles, 0)
    }

    func testConfiguredTwoByTwoPlanFinishesAtTheFourthCounterOwnedCycle() {
        let oneCycle = fullPhaseCycle()
        let phases = Array(repeating: oneCycle, count: 4).flatMap { $0 }
        let engine = NativeBottleGrabEngine(
            phaseTracker: PhaseScriptTracker(phases: phases),
        )
        engine.configure(exercise: NativeExercise(
            id: NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
            title: "Bottle Grab",
            titleThai: "หยิบขวด",
            detail: "fixture",
            detailThai: "fixture",
            isExperimental: true,
            reps: 2,
            sets: 2,
            holdSec: 0.5,
            target: 105,
            rest: 55,
            tolerance: 18,
            primaryJoint: "left_elbow",
        ))
        engine.setCountingEnabled(true)

        var output: NativeBottleGrabOutput?
        for index in phases.indices {
            let base = NativeFixtureProvider.fullBodySnapshot(frame: index + 1)
            output = engine.ingest(NativeFrameSnapshot(
                timestampMs: (index + 1) * 67,
                pose: base.pose,
                hand: base.hand,
                handSide: base.handSide,
                handScore: base.handScore,
                detectorLatencyMs: base.detectorLatencyMs,
            ))
            if (index + 1).isMultiple(of: oneCycle.count) {
                let completedCycles = (index + 1) / oneCycle.count
                XCTAssertEqual(output?.totalReps, completedCycles)
                XCTAssertEqual(output?.finished, completedCycles == 4)
            }
        }

        XCTAssertEqual(output?.totalReps, 4)
        XCTAssertEqual(output?.setsDone, 2)
        XCTAssertEqual(output?.totalSets, 2)
        XCTAssertTrue(output?.finished ?? false)
    }

    func testDebugCaptureQCBypassExposesPhaseDiagnosticsWithoutCounting() {
        let engine = NativeBottleGrabEngine(
            phaseTracker: PhaseScriptTracker(phases: fullPhaseCycle()),
            debugCaptureQCBypass: true,
        )
        engine.setCountingEnabled(true)

        var output: NativeBottleGrabOutput?
        for (index, _) in fullPhaseCycle().enumerated() {
            let base = NativeFixtureProvider.fullBodySnapshot(frame: index + 1)
            output = engine.ingest(NativeFrameSnapshot(
                timestampMs: base.timestampMs,
                pose: base.pose,
                hand: base.hand,
                handSide: "Right",
                handScore: base.handScore,
                detectorLatencyMs: base.detectorLatencyMs,
            ))
        }

        XCTAssertEqual(output?.captureQC, "debug_bypass_wrong_anatomical_side")
        XCTAssertEqual(output?.phaseStatus, "phase_ready")
        XCTAssertNotNil(output?.phase)
        XCTAssertEqual(output?.totalReps, 0)
    }

    func testDebugCaptureQCBypassAllowsPhaseNetToObserveWrongSideForDiagnostics() {
        let tracker = NativePhaseNetV2Tracker(
            bundle: Bundle(for: NativePhaseNetV2Runtime.self),
            debugCaptureQCBypass: true,
        )
        var result: NativePhaseTrackingResult?

        for frame in 1...NativePhaseNetV2WindowAccumulator.sequenceLength {
            let base = NativeFixtureProvider.fullBodySnapshot(frame: frame)
            result = tracker.ingest(NativeFrameSnapshot(
                timestampMs: base.timestampMs,
                pose: base.pose,
                hand: base.hand,
                handSide: "Right",
                handScore: base.handScore,
                detectorLatencyMs: base.detectorLatencyMs,
            ))
        }

        XCTAssertEqual(result?.status, "phase_ready")
        XCTAssertTrue(result?.isNewPrediction ?? false)
        XCTAssertNotNil(result?.prediction)
    }

    func testPhasePolicyDoesNotBridgeAnAttemptThatStartedBeforePracticeActivation() {
        // Start/reach evidence observed during positioning or countdown must
        // never become a patient-visible rep after the user presses Start.
        let phases = fullPhaseCycle()
        let engine = NativeBottleGrabEngine(
            phaseTracker: PhaseScriptTracker(phases: phases),
        )
        var output: NativeBottleGrabOutput?

        for (index, _) in phases.prefix(4).enumerated() {
            output = engine.ingest(NativeFixtureProvider.fullBodySnapshot(frame: index + 1))
        }
        engine.setCountingEnabled(true)
        for (offset, _) in phases.dropFirst(4).enumerated() {
            output = engine.ingest(NativeFixtureProvider.fullBodySnapshot(frame: offset + 5))
        }

        XCTAssertEqual(output?.totalReps, 0)
    }

    func testPhaseCounterNeverSumsAHostDiagnosticCycle() {
        // The first fourteen motion rows contain one real host geometry
        // cycle. The same fourteen frames carry one full phase cycle. A
        // patient-visible total of two would prove an unsafe sum of both
        // lanes; only the PhaseNet full-cycle policy may own the total.
        let phases = fullPhaseCycle()
        let engine = NativeBottleGrabEngine(
            phaseTracker: PhaseScriptTracker(phases: phases),
        )
        engine.setCountingEnabled(true)
        var output: NativeBottleGrabOutput?

        for snapshot in hostCompletionSequence().prefix(phases.count) {
            output = engine.ingest(snapshot)
        }

        XCTAssertEqual(output?.totalReps, 1)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
    }

    func testHostCounterStaysDiagnosticWithoutPhasePredictions() {
        // The host lane may still observe a full open → reach → close →
        // reopen movement, but it must never make a patient-visible rep
        // without an ordered PhaseNet endpoint cycle.
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var output: NativeBottleGrabOutput?

        for snapshot in hostCompletionSequence() {
            output = engine.ingest(snapshot)
        }

        XCTAssertEqual(output?.captureQC, "can_assess")
        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
    }

    func testAppV6ParallelGeometryCounterOwnsTotalRepsWhenPhaseNetIsSilent() {
        let engine = NativeBottleGrabEngine(
            phaseTracker: SilentPhaseTracker(),
            counterMode: .parallelGeometryFirst,
        )
        engine.setCountingEnabled(true)
        var output: NativeBottleGrabOutput?

        for snapshot in hostCompletionSequence() {
            output = engine.ingest(snapshot)
        }

        XCTAssertEqual(output?.totalReps, 1)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
        XCTAssertEqual(output?.phaseDiagnosticCycles, 0)
        XCTAssertEqual(output?.counterMode, "parallel_geometry_first")
        XCTAssertEqual(
            output?.repCounterProvenance,
            NativeBottleGrabHostCompletionCounter.v6Provenance,
        )
    }

    func testAppV6GeometryCounterRemainsIndependentWhenPhaseNetCannotAssess() {
        let engine = NativeBottleGrabEngine(
            phaseTracker: CannotAssessPhaseTracker(),
            counterMode: .parallelGeometryFirst,
        )
        engine.setCountingEnabled(true)
        var output: NativeBottleGrabOutput?

        for snapshot in hostCompletionSequence() {
            output = engine.ingest(snapshot)
        }

        XCTAssertEqual(output?.phaseStatus, "cannot_assess")
        XCTAssertEqual(output?.phaseDiagnosticCycles, 0)
        XCTAssertEqual(output?.totalReps, 1)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
        XCTAssertTrue(output?.isTrackingReady ?? false)
    }

    func testHostReadinessDoesNotStartWhenPhaseRuntimeCannotAssess() {
        // A geometry baseline alone must not make the UI enter its countdown
        // when the PhaseNet sidecar reports an actual feature/runtime failure.
        // Otherwise a visible "ready" state would claim the local model is
        // usable while its model-facing feature adapter is not.
        let engine = NativeBottleGrabEngine(phaseTracker: CannotAssessPhaseTracker())
        var output: NativeBottleGrabOutput?

        for snapshot in hostCompletionSequence().prefix(5) {
            output = engine.ingest(snapshot)
        }

        XCTAssertEqual(output?.phaseStatus, "cannot_assess")
        XCTAssertEqual(output?.setupState, "positioning")
        XCTAssertFalse(output?.isTrackingReady ?? true)
    }

    func testHostCounterDoesNotCountWhilePhaseRuntimeCannotAssess() {
        // No geometry-only fallback may write patient-facing reps while the
        // model-side runtime itself is unavailable. This protects against an
        // accidental "working" counter when MediaPipe/PhaseNet input fails.
        let engine = NativeBottleGrabEngine(phaseTracker: CannotAssessPhaseTracker())
        engine.setCountingEnabled(true)
        var output: NativeBottleGrabOutput?

        for snapshot in hostCompletionSequence() {
            output = engine.ingest(snapshot)
        }

        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertFalse(output?.isTrackingReady ?? true)
    }

    func testHostDiagnosticCanAdvanceWhenPhaseWindowReacquiresButPatientCounterDoesNot() {
        // A native detector may temporarily lose PhaseNet's required 15 Hz
        // window. The host diagnostic can still report its geometry event,
        // but the lifecycle-gated PhaseNet counter must fail closed.
        let engine = NativeBottleGrabEngine(phaseTracker: TemporalResetPhaseTracker())
        engine.setCountingEnabled(true)
        var output: NativeBottleGrabOutput?

        for snapshot in hostCompletionSequence() {
            output = engine.ingest(snapshot)
        }

        XCTAssertEqual(output?.phaseStatus, "reset")
        XCTAssertEqual(output?.setupState, "phase_reacquiring")
        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
    }

    func testHostCounterDoesNotCountMovementStartedBeforePracticeActivation() {
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        let sequence = hostCompletionSequence()
        var output: NativeBottleGrabOutput?

        // A patient moves during positioning/countdown. Enabling later must
        // clear the pre-start reference so this partial movement cannot count.
        for snapshot in sequence.prefix(11) {
            output = engine.ingest(snapshot)
        }
        engine.setCountingEnabled(true)
        for snapshot in sequence.dropFirst(11) {
            output = engine.ingest(snapshot)
        }

        XCTAssertEqual(output?.totalReps, 0)
    }

    func testHostDiagnosticDoesNotBridgeAFrameGapOutsideNativeDeliveryEnvelope() {
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var timestamp = 0
        var output: NativeBottleGrabOutput?
        func ingest(_ wristX: Float, closed: Bool, count: Int, gapBefore: Int = 67) {
            for index in 0..<count {
                timestamp += index == 0 ? gapBefore : 67
                output = engine.ingest(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: wristX,
                    wristY: 0.62,
                    closed: closed,
                ))
            }
        }

        ingest(0.30, closed: false, count: 5)
        ingest(0.45, closed: false, count: 3)
        ingest(0.45, closed: true, count: 2)
        ingest(0.45, closed: true, count: 1, gapBefore: 500)
        ingest(0.45, closed: false, count: 3)
        ingest(0.30, closed: false, count: 3)

        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostDiagnosticCycles, 0)
    }

    func testHostCounterCountsRealGeometryAtTheBoundedNativeDeliveryCadence() {
        // The native live transport may take up to 350 ms to finish a joined
        // Pose + Hand inference before it admits the newest camera frame.
        // These are still three independent, real observations for each
        // open/close/reopen edge; no feature is padded or interpolated. The
        // host diagnostic must not reset the attempt solely because its old
        // browser-replay gap was narrower than the native transport budget.
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var timestamp = 0
        var output: NativeBottleGrabOutput?
        func ingest(closed: Bool, count: Int) {
            for _ in 0..<count {
                timestamp += 350
                output = engine.ingest(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: 0.45,
                    wristY: 0.62,
                    closed: closed,
                ))
            }
        }

        ingest(closed: false, count: 3)
        ingest(closed: true, count: 3)
        ingest(closed: false, count: 3)

        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
    }

    func testHostCounterResetsAStalledGraspAtThePublishedNoProgressLimit() {
        // The V1.1 contract already defines an 8-second no-progress limit.
        // A live UI must not remain in “grasped” forever after tracking has
        // stopped making semantic progress; the next attempt needs a fresh
        // open baseline instead of inheriting a stale hand closure.
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var timestamp = 0
        var output: NativeBottleGrabOutput?
        func ingest(_ wristX: Float, closed: Bool, count: Int, firstGap: Int = 67) {
            for index in 0..<count {
                timestamp += index == 0 ? firstGap : 67
                output = engine.ingest(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: wristX,
                    wristY: 0.62,
                    closed: closed,
                ))
            }
        }

        ingest(0.30, closed: false, count: 3)
        ingest(0.45, closed: true, count: 3)
        // Keep receiving real 15 Hz observations but never reopen the hand.
        // A multi-second *gap* is independently rejected at 450 ms; this
        // covers the distinct no-progress case under continuous tracking.
        ingest(0.45, closed: true, count: 121)

        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostCounterStatus, "collecting_rest")
        XCTAssertEqual(output?.hostCounterReason, "no_progress_timeout")
    }

    func testHostCounterRejectsTimestampRegressionAndRequiresNewBaseline() {
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var output: NativeBottleGrabOutput?
        for snapshot in hostCompletionSequence().prefix(8) {
            output = engine.ingest(snapshot)
        }
        let late = hostMotionSnapshot(
            timestampMs: 67,
            wristX: 0.45,
            wristY: 0.62,
            closed: true,
        )
        output = engine.ingest(late)
        XCTAssertEqual(output?.totalReps, 0)

        for snapshot in hostCompletionSequence().dropFirst(8) {
            output = engine.ingest(NativeFrameSnapshot(
                timestampMs: snapshot.timestampMs + 2_000,
                sourceGeneration: snapshot.sourceGeneration,
                pose: snapshot.pose,
                hand: snapshot.hand,
                handSide: snapshot.handSide,
                handScore: snapshot.handScore,
                detectorLatencyMs: snapshot.detectorLatencyMs,
            ))
        }
        XCTAssertEqual(output?.totalReps, 0)
    }

    func testHostCounterDoesNotArmFromClosedStaticHand() {
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var output: NativeBottleGrabOutput?
        for frame in 1...8 {
            output = engine.ingest(hostMotionSnapshot(
                timestampMs: frame * 67,
                wristX: 0.30,
                wristY: 0.62,
                closed: true,
            ))
        }

        XCTAssertFalse(output?.isTrackingReady ?? true)
        XCTAssertEqual(output?.totalReps, 0)
    }

    func testHostCounterResetsAfterMissingHandGapExceedsBoundedContinuityWindow() {
        // A missing hand is never geometry. The native host policy can retain
        // a partial cycle only for a brief detector dropout; after 450 ms it
        // must require a new baseline so a stale grasp cannot bridge to a
        // later release.
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var timestamp = 0
        var output: NativeBottleGrabOutput?
        func ingest(_ wristX: Float, closed: Bool, count: Int) {
            for _ in 0..<count {
                timestamp += 67
                output = engine.ingest(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: wristX,
                    wristY: 0.62,
                    closed: closed,
                ))
            }
        }

        ingest(0.30, closed: false, count: 5)
        ingest(0.45, closed: false, count: 3)
        ingest(0.45, closed: true, count: 3)

        timestamp += 500
        let validButUnavailable = hostMotionSnapshot(
            timestampMs: timestamp,
            wristX: 0.45,
            wristY: 0.62,
            closed: true,
        )
        output = engine.ingest(NativeFrameSnapshot(
            timestampMs: validButUnavailable.timestampMs,
            pose: validButUnavailable.pose,
            hand: [],
            handSide: nil,
            handScore: 0,
            detectorLatencyMs: validButUnavailable.detectorLatencyMs,
        ))
        XCTAssertEqual(output?.captureQC, "cannot_assess_missing_left_hand")

        ingest(0.45, closed: false, count: 3)
        ingest(0.30, closed: false, count: 3)
        XCTAssertEqual(output?.totalReps, 0)
    }

    func testHostCounterToleratesOneMissingHandFrameInsideTheBoundedContinuityWindow() {
        // MediaPipe may transiently miss the hand for one camera frame even
        // though the surrounding real geometry is continuous. The missing
        // frame itself is never evidence and the UI remains positioning for
        // it, but a <450 ms interruption must not erase an already-confirmed
        // grasp before three new real release frames can arrive.
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var timestamp = 0
        var output: NativeBottleGrabOutput?
        func ingest(_ wristX: Float, closed: Bool, count: Int) {
            for _ in 0..<count {
                timestamp += 67
                output = engine.ingest(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: wristX,
                    wristY: 0.62,
                    closed: closed,
                ))
            }
        }

        ingest(0.30, closed: false, count: 3)
        ingest(0.45, closed: true, count: 3)

        timestamp += 67
        let missingHand = hostMotionSnapshot(
            timestampMs: timestamp,
            wristX: 0.45,
            wristY: 0.62,
            closed: true,
        )
        output = engine.ingest(NativeFrameSnapshot(
            timestampMs: missingHand.timestampMs,
            pose: missingHand.pose,
            hand: [],
            handSide: nil,
            handScore: 0,
            detectorLatencyMs: missingHand.detectorLatencyMs,
        ))
        XCTAssertEqual(output?.captureQC, "cannot_assess_missing_left_hand")
        XCTAssertEqual(output?.totalReps, 0)

        ingest(0.45, closed: false, count: 3)
        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
    }

    func testHostCounterCountsReleaseWhenReturnPrecedesHandReopen() {
        // A real camera can report the wrist's return before Hand Landmarker
        // delivers the stable reopened geometry. Return is allowed patient
        // movement, but release is the actual completion boundary; do not
        // throw away a later true release just because the two detectors
        // arrive on adjacent frames.
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var timestamp = 0
        var output: NativeBottleGrabOutput?
        func ingest(_ wristX: Float, closed: Bool, count: Int) {
            for _ in 0..<count {
                timestamp += 67
                output = engine.ingest(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: wristX,
                    wristY: 0.62,
                    closed: closed,
                ))
            }
        }

        ingest(0.30, closed: false, count: 5)
        ingest(0.45, closed: false, count: 3)
        ingest(0.45, closed: true, count: 3)
        ingest(0.30, closed: true, count: 3)
        ingest(0.30, closed: false, count: 3)

        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
    }

    func testHostCounterCountsStableReleaseWithoutRequiringArmReturn() {
        // The frozen continuous-grasp contract ends at release OR return.
        // A valid release cannot be discarded solely because the patient has
        // not yet brought the arm all the way back to the rest wrist point.
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var timestamp = 0
        var output: NativeBottleGrabOutput?
        func ingest(_ wristX: Float, closed: Bool, count: Int) {
            for _ in 0..<count {
                timestamp += 67
                output = engine.ingest(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: wristX,
                    wristY: 0.62,
                    closed: closed,
                ))
            }
        }

        ingest(0.30, closed: false, count: 5)
        ingest(0.45, closed: false, count: 3)
        ingest(0.45, closed: true, count: 3)
        ingest(0.45, closed: false, count: 3)

        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
    }

    func testHostCounterCountsStableOpenCloseReleaseWhenHandIsAlreadyAtBottle() {
        // The frozen continuous-grasp contract owns a hand-action boundary:
        // real stable open → grasp → release. A patient may begin with the
        // working hand already in the bottle work area, so wrist departure is
        // useful guidance but must not be a hidden counting prerequisite.
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var timestamp = 0
        var output: NativeBottleGrabOutput?
        func ingest(closed: Bool, count: Int) {
            for _ in 0..<count {
                timestamp += 67
                output = engine.ingest(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: 0.45,
                    wristY: 0.62,
                    closed: closed,
                ))
            }
        }

        ingest(closed: false, count: 5)
        ingest(closed: true, count: 3)
        ingest(closed: false, count: 3)

        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
    }

    func testHostCounterUsesThreeRealOpenRowsForTheInitialReference() {
        // The frozen continuous-grasp contract defines the initial open
        // reference from three consecutive real geometry rows. Requiring five
        // rows delays readiness and diverges from the model-side contract.
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var timestamp = 0
        var output: NativeBottleGrabOutput?
        func ingest(closed: Bool, count: Int) {
            for _ in 0..<count {
                timestamp += 67
                output = engine.ingest(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: 0.45,
                    wristY: 0.62,
                    closed: closed,
                ))
            }
        }

        ingest(closed: false, count: 3)
        ingest(closed: true, count: 3)
        ingest(closed: false, count: 3)

        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostDiagnosticCycles, 1)
    }

    func testHostCounterRearmsFromReleaseAndCountsASecondContinuousCycle() {
        // A Bottle Grab set is continuous: the three real reopened rows that
        // complete one grasp are also valid open evidence for the next one.
        // Requiring a separate rest pose makes normal repeated
        // grab → release actions disappear from the counter.
        let engine = NativeBottleGrabEngine(phaseTracker: SilentPhaseTracker())
        engine.setCountingEnabled(true)
        var timestamp = 0
        var output: NativeBottleGrabOutput?
        func ingest(closed: Bool, count: Int) {
            for _ in 0..<count {
                timestamp += 67
                output = engine.ingest(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: 0.45,
                    wristY: 0.62,
                    closed: closed,
                ))
            }
        }

        ingest(closed: false, count: 5)
        ingest(closed: true, count: 3)
        ingest(closed: false, count: 3)
        ingest(closed: true, count: 3)
        ingest(closed: false, count: 3)

        XCTAssertEqual(output?.totalReps, 0)
        XCTAssertEqual(output?.hostDiagnosticCycles, 2)
    }

    func testEngineRejectsLateOlderSourceGenerationAfterReplacement() {
        let engine = NativeBottleGrabEngine(phaseTracker: NativeFixturePhaseTracker())
        _ = engine.ingest(NativeFixtureProvider.fullBodySnapshot(frame: 1, sourceGeneration: 0))
        _ = engine.ingest(NativeFixtureProvider.fullBodySnapshot(frame: 2, sourceGeneration: 1))
        let late = NativeFixtureProvider.fullBodySnapshot(frame: 3, sourceGeneration: 0)

        let output = engine.ingest(late)

        XCTAssertEqual(output.captureQC, "cannot_assess_stale_source_generation")
        XCTAssertEqual(output.setupReason, "stale_source_generation")
        XCTAssertEqual(output.bufferedFrames, 0)
    }

    private func emit(
        _ phase: String,
        to policy: NativeBottleGrabFullCyclePolicy,
        timestamp: inout Int,
    ) {
        for _ in 0..<2 {
            timestamp += 200
            policy.ingest(
                NativePhasePrediction(
                    phase: phase,
                    probability: 0.98,
                    endpointTimestampMs: timestamp,
                ),
            )
        }
    }

    private func fullPhaseCycle() -> [String] {
        [
            "start_or_rest", "start_or_rest",
            "reach", "reach",
            "preshape", "preshape",
            "grasp", "grasp",
            "release", "release",
            "return", "return",
            "start_or_rest", "start_or_rest",
        ]
    }

    private func qualifiedRuleWrapHand(anchoredAt wrist: NativeLandmark) -> [NativeLandmark] {
        func point(_ x: Float, _ y: Float) -> NativeLandmark {
            NativeLandmark(x: x, y: y, z: 0, visibility: 0.98)
        }
        var hand = Array(repeating: wrist, count: 21)
        hand[0] = wrist
        hand[1] = point(wrist.x + 0.03, wrist.y - 0.02)
        hand[2] = point(wrist.x + 0.05, wrist.y - 0.06)
        hand[3] = point(wrist.x + 0.06, wrist.y - 0.10)
        hand[4] = point(wrist.x + 0.16, wrist.y - 0.16)
        // Straight index: low flexion.
        hand[5] = point(wrist.x + 0.03, wrist.y - 0.04)
        hand[6] = point(wrist.x + 0.03, wrist.y - 0.09)
        hand[7] = point(wrist.x + 0.03, wrist.y - 0.14)
        hand[8] = point(wrist.x + 0.03, wrist.y - 0.19)
        // Bent middle/ring/pinky chains create both frozen Rule-Wrap signal
        // families (pinky–index gap and visible-finger spread).
        for base in [9, 13, 17] {
            hand[base] = point(wrist.x + Float(base - 5) * 0.008, wrist.y - 0.04)
            hand[base + 1] = point(wrist.x + Float(base - 5) * 0.008, wrist.y - 0.09)
            hand[base + 2] = point(wrist.x + Float(base - 5) * 0.008 + 0.05, wrist.y - 0.09)
            hand[base + 3] = point(wrist.x + Float(base - 5) * 0.008 + 0.05, wrist.y - 0.14)
        }
        return hand
    }

    private func hostCompletionSequence() -> [NativeFrameSnapshot] {
        var timestamp = 0
        var frames: [NativeFrameSnapshot] = []
        func append(_ wristX: Float, _ wristY: Float, closed: Bool, count: Int) {
            for _ in 0..<count {
                timestamp += 67
                frames.append(hostMotionSnapshot(
                    timestampMs: timestamp,
                    wristX: wristX,
                    wristY: wristY,
                    closed: closed,
                ))
            }
        }

        // Stable open baseline → reach → grasp → release. A bottle lift is
        // intentionally absent, and return rows are not required for count.
        append(0.30, 0.62, closed: false, count: 5)
        append(0.45, 0.62, closed: false, count: 3)
        append(0.45, 0.62, closed: true, count: 3)
        append(0.45, 0.62, closed: false, count: 3)
        append(0.30, 0.62, closed: false, count: 3)
        return frames
    }

    private func hostMotionSnapshot(
        timestampMs: Int,
        wristX: Float,
        wristY: Float,
        closed: Bool,
    ) -> NativeFrameSnapshot {
        let base = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = base.pose
        let shoulder = NativeLandmark(x: 0.50, y: 0.38, z: 0, visibility: 0.98)
        let elbow = NativeLandmark(x: 0.40, y: 0.50, z: 0, visibility: 0.98)
        let wrist = NativeLandmark(x: wristX, y: wristY, z: 0, visibility: 0.98)
        pose[11] = shoulder
        pose[13] = elbow
        pose[15] = wrist
        pose[17] = NativeLandmark(x: wristX + 0.01, y: wristY - 0.02, z: 0, visibility: 0.98)
        pose[19] = NativeLandmark(x: wristX + 0.02, y: wristY - 0.03, z: 0, visibility: 0.98)
        pose[21] = NativeLandmark(x: wristX + 0.03, y: wristY - 0.04, z: 0, visibility: 0.98)
        return NativeFrameSnapshot(
            timestampMs: timestampMs,
            pose: pose,
            hand: hostMotionHand(anchoredAt: wrist, closed: closed),
            handSide: "Left",
            handScore: 0.98,
            detectorLatencyMs: 3.2,
        )
    }

    private func hostMotionHand(anchoredAt wrist: NativeLandmark, closed: Bool) -> [NativeLandmark] {
        func point(_ x: Float, _ y: Float) -> NativeLandmark {
            NativeLandmark(x: x, y: y, z: 0, visibility: 0.98)
        }

        var hand = Array(repeating: wrist, count: 21)
        hand[0] = wrist
        // Keep palm scale fixed, so the aperture ratio remains comparable
        // across the open/grasp/release sequence.
        hand[9] = point(wrist.x, wrist.y - 0.10)

        if closed {
            // Bent chains raise mean flexion. Thumb/index tips meet, creating
            // a real aperture drop rather than a phase-only synthetic event.
            hand[1] = point(wrist.x + 0.04, wrist.y)
            hand[2] = point(wrist.x + 0.07, wrist.y - 0.02)
            hand[3] = point(wrist.x + 0.04, wrist.y - 0.05)
            hand[4] = point(wrist.x + 0.01, wrist.y - 0.09)
            for base in [5, 9, 13, 17] {
                hand[base] = point(wrist.x, wrist.y - (base == 9 ? 0.10 : 0.04))
                hand[base + 1] = point(wrist.x + 0.04, wrist.y - 0.05)
                hand[base + 2] = point(wrist.x + 0.02, wrist.y - 0.09)
                hand[base + 3] = point(wrist.x + 0.01, wrist.y - 0.09)
            }
            hand[8] = point(wrist.x + 0.01, wrist.y - 0.09)
        } else {
            // Straight chains keep the normalized flexion low while the
            // thumb/index aperture is visibly open.
            hand[1] = point(wrist.x + 0.04, wrist.y)
            hand[2] = point(wrist.x + 0.08, wrist.y)
            hand[3] = point(wrist.x + 0.12, wrist.y)
            hand[4] = point(wrist.x + 0.16, wrist.y)
            for base in [5, 9, 13, 17] {
                hand[base] = point(wrist.x, wrist.y - (base == 9 ? 0.10 : 0.04))
                hand[base + 1] = point(wrist.x, wrist.y - 0.09)
                hand[base + 2] = point(wrist.x, wrist.y - 0.14)
                hand[base + 3] = point(wrist.x, wrist.y - 0.19)
            }
        }
        return hand
    }
}

private final class PhaseScriptTracker: NativeBottleGrabPhaseTracking {
    private let phases: [String]
    private var index = 0

    init(phases: [String]) {
        self.phases = phases
    }

    func reset(reason: String) {
        index = 0
    }

    func ingest(_ snapshot: NativeFrameSnapshot) -> NativePhaseTrackingResult {
        guard phases.indices.contains(index) else {
            return NativePhaseTrackingResult(
                status: "buffering",
                reason: nil,
                bufferedFrames: 0,
                prediction: nil,
                isNewPrediction: false,
                modelStatus: "test_phase_script_complete",
            )
        }
        defer { index += 1 }
        return NativePhaseTrackingResult(
            status: "phase_ready",
            reason: nil,
            bufferedFrames: NativePhaseNetV2WindowAccumulator.sequenceLength,
            prediction: NativePhasePrediction(
                phase: phases[index],
                probability: 0.98,
                endpointTimestampMs: snapshot.timestampMs,
            ),
            isNewPrediction: true,
            modelStatus: "test_phase_script",
        )
    }
}

private final class SilentPhaseTracker: NativeBottleGrabPhaseTracking {
    func reset(reason: String) {}

    func ingest(_ snapshot: NativeFrameSnapshot) -> NativePhaseTrackingResult {
        NativePhaseTrackingResult(
            status: "buffering",
            reason: nil,
            bufferedFrames: 0,
            prediction: nil,
            isNewPrediction: false,
            modelStatus: "test_silent_phase_tracker",
        )
    }
}

private final class CannotAssessPhaseTracker: NativeBottleGrabPhaseTracking {
    func reset(reason: String) {}

    func ingest(_ snapshot: NativeFrameSnapshot) -> NativePhaseTrackingResult {
        NativePhaseTrackingResult(
            status: "cannot_assess",
            reason: "host_test_phase_feature_failure",
            bufferedFrames: 0,
            prediction: nil,
            isNewPrediction: false,
            modelStatus: "test_cannot_assess_phase_tracker",
        )
    }
}

private final class TemporalResetPhaseTracker: NativeBottleGrabPhaseTracking {
    func reset(reason: String) {}

    func ingest(_ snapshot: NativeFrameSnapshot) -> NativePhaseTrackingResult {
        NativePhaseTrackingResult(
            status: "reset",
            reason: "invalid_15hz_window_span",
            bufferedFrames: 0,
            prediction: nil,
            isNewPrediction: false,
            modelStatus: "test_loaded_phasenet_reacquiring_window",
        )
    }
}
