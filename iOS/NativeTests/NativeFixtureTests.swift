import XCTest
import AVFoundation
@testable import PhysioAINative

final class NativeFixtureTests: XCTestCase {
    func testLandmarkOverlayReservesTheEntireBottomHUDBeforeDrawingSkeleton() {
        XCTAssertEqual(
            NativePracticeOverlayLayout.visibleLandmarkHeight(
                containerHeight: 900,
                lensMenuOpen: false,
            ),
            566,
        )
        XCTAssertEqual(
            NativePracticeOverlayLayout.visibleLandmarkHeight(
                containerHeight: 900,
                lensMenuOpen: true,
            ),
            438,
        )
        // A compact device must fail safely by hiding the overlay rather than
        // painting landmarks through controls that need to stay tappable.
        XCTAssertEqual(
            NativePracticeOverlayLayout.visibleLandmarkHeight(
                containerHeight: 300,
                lensMenuOpen: true,
            ),
            0,
        )
    }

    func testAspectFillMapperUsesCameraCropInsteadOfStretchingLandmarks() {
        let canvas = CGSize(width: 390, height: 844)
        let left = NativePreviewCoordinateMapper.point(
            normalizedX: 0,
            normalizedY: 0.5,
            mirrored: false,
            sourceAspectRatio: 9 / 16,
            destinationSize: canvas,
        )
        let centre = NativePreviewCoordinateMapper.point(
            normalizedX: 0.5,
            normalizedY: 0.5,
            mirrored: false,
            sourceAspectRatio: 9 / 16,
            destinationSize: canvas,
        )
        let mirroredLeft = NativePreviewCoordinateMapper.point(
            normalizedX: 0,
            normalizedY: 0.5,
            mirrored: true,
            sourceAspectRatio: 9 / 16,
            destinationSize: canvas,
        )

        // Portrait 9:16 fills this slightly narrower iPhone canvas by
        // cropping ~42.4 pt from each horizontal side. A direct width/height
        // scale would incorrectly put the left point at x == 0.
        XCTAssertEqual(left.x, -42.375, accuracy: 0.001)
        XCTAssertEqual(centre.x, 195, accuracy: 0.001)
        XCTAssertEqual(mirroredLeft.x, 432.375, accuracy: 0.001)
        XCTAssertEqual(centre.y, 422, accuracy: 0.001)
    }

    func testBottleGrabOverlayShowsFullBodyOnlyForCrediblePoseAnchors() {
        let fullBody = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        XCTAssertTrue(
            NativeSkeletonOverlayPolicy.showsBodyPose(
                exerciseID: "bottle_grab",
                snapshot: fullBody,
            ),
        )

        var partialPose = fullBody.pose
        partialPose[27] = NativeLandmark(x: 0.44, y: 0.96, z: 0, visibility: 0.2)
        let weakBody = NativeFrameSnapshot(
            timestampMs: fullBody.timestampMs,
            pose: partialPose,
            hand: fullBody.hand,
            handSide: fullBody.handSide,
            handScore: fullBody.handScore,
            detectorLatencyMs: fullBody.detectorLatencyMs,
        )
        XCTAssertFalse(
            NativeSkeletonOverlayPolicy.showsBodyPose(
                exerciseID: "bottle_grab",
                snapshot: weakBody,
            ),
        )
        XCTAssertTrue(
            NativeSkeletonOverlayPolicy.showsBodyPose(
                exerciseID: "lateral_arm_raise",
                snapshot: nil,
            ),
        )
        XCTAssertTrue(
            NativeSkeletonOverlayPolicy.showsBodyPose(
                exerciseID: nil,
                snapshot: nil,
            ),
        )
    }

    func testSourceGenerationGateRejectsAQueuedFrameAfterCameraReset() {
        var gate = NativeSourceGenerationGate()
        gate.reset(to: 4)
        XCTAssertTrue(gate.accepts(4))

        gate.reset(to: 5)
        XCTAssertFalse(gate.accepts(4))
        XCTAssertTrue(gate.accepts(5))
    }

    func testSpeechRecoveryPolicyOnlyReactivatesAfterResumableAudioEvents() {
        XCTAssertFalse(
            NativeSpeechRecoveryPolicy.shouldReactivateAfterInterruption(
                began: true,
                shouldResume: true,
            ),
        )
        XCTAssertFalse(
            NativeSpeechRecoveryPolicy.shouldReactivateAfterInterruption(
                began: false,
                shouldResume: false,
            ),
        )
        XCTAssertTrue(
            NativeSpeechRecoveryPolicy.shouldReactivateAfterInterruption(
                began: false,
                shouldResume: true,
            ),
        )
        XCTAssertTrue(NativeSpeechRecoveryPolicy.shouldReactivateAfterRouteChange)
    }

    func testSetupSpeechPolicySpeaksTheInitialReasonButDoesNotAutoRepeatSpecificGuidance() {
        XCTAssertTrue(
            NativeSetupSpeechPolicy.shouldSpeak(
                reason: "wrong_anatomical_side",
                speechEnabled: true,
                visualOnly: false,
                lastReason: nil,
                elapsedSinceLastSpeech: 0,
            ),
        )
        XCTAssertFalse(
            NativeSetupSpeechPolicy.shouldSpeak(
                reason: "wrong_anatomical_side",
                speechEnabled: true,
                visualOnly: false,
                lastReason: "wrong_anatomical_side",
                elapsedSinceLastSpeech: 1,
            ),
        )
        XCTAssertFalse(
            NativeSetupSpeechPolicy.shouldSpeak(
                reason: "wrong_anatomical_side",
                speechEnabled: true,
                visualOnly: false,
                lastReason: "wrong_anatomical_side",
                elapsedSinceLastSpeech: 30,
            ),
        )
        XCTAssertFalse(
            NativeSetupSpeechPolicy.shouldSpeak(
                reason: "wrong_anatomical_side",
                speechEnabled: true,
                visualOnly: true,
                lastReason: nil,
                elapsedSinceLastSpeech: 0,
            ),
        )
    }

    func testSetupGuidanceUsesNoParticipantCopyOnlyForAnEmptyPoseSnapshot() {
        let noParticipant = NativeSetupGuidancePolicy.resolve(
            rawReason: "missing_required_pose",
            poseLandmarkCount: 0,
            isSitToStand: false,
            isThai: true,
            snapshotTimestampMs: 101,
        )
        XCTAssertEqual(noParticipant?.semanticKey, NativeSetupSpeechPolicy.noParticipantSemanticReason)
        XCTAssertEqual(noParticipant?.detail, "เข้ากรอบให้เห็นแขนซ้ายครับ")

        let partialPose = NativeSetupGuidancePolicy.resolve(
            rawReason: "missing_required_pose",
            poseLandmarkCount: 33,
            isSitToStand: false,
            isThai: true,
            snapshotTimestampMs: 102,
        )
        XCTAssertEqual(partialPose?.semanticKey, "left_arm_framing")
    }

    func testCountedRepSpeechCopyUsesTheAuthoritativeRepNumberInBothLanguages() {
        XCTAssertEqual(
            NativeTtsCopyPolicy.motionText(
                status: "counted_rep_3",
                isSitToStand: true,
                isThai: true,
                fallback: "fallback",
            ),
            "รอบที่ 3",
        )
        XCTAssertEqual(
            NativeTtsCopyPolicy.motionText(
                status: "counted_rep_3",
                isSitToStand: false,
                isThai: false,
                fallback: "fallback",
            ),
            "Rep 3",
        )
    }

    func testCalmActionCuePolicyWaitsForDwellAndHoldsACompletedRep() {
        var policy = NativeActionCuePresentationPolicy()

        XCTAssertNil(policy.observe(
            rawStatus: "seated_rest",
            totalReps: 0,
            isSitToStand: true,
            isThai: true,
            fallback: "fallback",
            now: 0,
        ))
        XCTAssertEqual(policy.observe(
            rawStatus: "seated_rest",
            totalReps: 0,
            isSitToStand: true,
            isThai: true,
            fallback: "fallback",
            now: 0.45,
        )?.visualText, "ดีมาก ลุกขึ้นได้เลย")

        XCTAssertEqual(policy.observe(
            rawStatus: "lowering",
            totalReps: 1,
            isSitToStand: true,
            isThai: true,
            fallback: "fallback",
            now: 0.50,
        )?.visualText, "รอบ 1 สำเร็จ")
        XCTAssertEqual(policy.observe(
            rawStatus: "lowering",
            totalReps: 1,
            isSitToStand: true,
            isThai: true,
            fallback: "fallback",
            now: 1.69,
        )?.visualText, "รอบ 1 สำเร็จ")
    }

    func testCalmActionCuePolicyKeepsAutomaticModelAndHandCommentsVisualOnly() {
        XCTAssertFalse(NativeActiveCoachingSpeechPolicy.automaticallySpeaksModelCues)
        XCTAssertFalse(NativeActiveCoachingSpeechPolicy.automaticallySpeaksHandCues)
    }

    func testSetupSpeechSnapshotRecheckOnlyRunsForANewerLiveFrame() {
        XCTAssertTrue(
            NativeSetupSpeechPolicy.shouldRecheckForSnapshot(
                timestampMs: 1_001,
                lastCheckedTimestampMs: 1_000,
            ),
        )
        XCTAssertFalse(
            NativeSetupSpeechPolicy.shouldRecheckForSnapshot(
                timestampMs: 1_000,
                lastCheckedTimestampMs: 1_000,
            ),
        )
        XCTAssertFalse(
            NativeSetupSpeechPolicy.shouldRecheckForSnapshot(
                timestampMs: nil,
                lastCheckedTimestampMs: nil,
            ),
        )
    }

    func testCameraStartsOnRearPosition() {
        let camera = CameraSession()

        XCTAssertEqual(camera.position, .back)
    }

    func testBottleGrabCaptureDefaultsUseOneXInferenceZoom() {
        XCTAssertEqual(NativeCaptureDefaults.defaultZoomFactor, 1)
    }

    func testV7BottleDetectorSelectsBottleAndRejectsAmbiguousCandidates() {
        let bottle = NativeBottleDetection(
            sourceGeneration: 1,
            timestampMs: 1_000,
            label: "bottle",
            score: 0.82,
            boundingBox: CGRect(x: 0.62, y: 0.30, width: 0.16, height: 0.38),
        )
        let selected = NativeBottleDetectionSelector.select(
            detections: [
                NativeBottleDetection(
                    sourceGeneration: 1,
                    timestampMs: 1_000,
                    label: "chair",
                    score: 0.99,
                    boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.4, height: 0.4),
                ),
                bottle,
            ],
            sourceGeneration: 1,
            timestampMs: 1_000,
        )

        XCTAssertEqual(selected.detection, bottle)
        XCTAssertEqual(selected.reason, "bottle_selected")

        let ambiguous = NativeBottleDetectionSelector.select(
            detections: [
                bottle,
                NativeBottleDetection(
                    sourceGeneration: 1,
                    timestampMs: 1_000,
                    label: "bottle",
                    score: 0.80,
                    boundingBox: CGRect(x: 0.12, y: 0.30, width: 0.16, height: 0.38),
                ),
            ],
            sourceGeneration: 1,
            timestampMs: 1_000,
        )
        XCTAssertNil(ambiguous.detection)
        XCTAssertEqual(ambiguous.reason, "bottle_ambiguous")
    }

    func testV7BottleDetectorContainmentUsesExpandedNormalizedROI() {
        let detection = NativeBottleDetection(
            sourceGeneration: 1,
            timestampMs: 1_000,
            label: "bottle",
            score: 0.8,
            boundingBox: CGRect(x: 0.5, y: 0.4, width: 0.2, height: 0.3),
        )

        XCTAssertTrue(
            NativeBottleDetectionSelector.contains(
                point: CGPoint(x: 0.49, y: 0.55),
                in: detection,
                margin: 0.02,
            ),
        )
        XCTAssertFalse(
            NativeBottleDetectionSelector.contains(
                point: CGPoint(x: 0.46, y: 0.55),
                in: detection,
                margin: 0.02,
            ),
        )
    }

    func testV7ProximityCounterCountsPoseOnlyOutsideInsideOutsideWithoutHand() {
        let counter = NativeBottleProximityCounter()
        counter.setCountingEnabled(true)
        let bottle = NativeBottleDetection(
            sourceGeneration: 1,
            timestampMs: 0,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.65, y: 0.35, width: 0.2, height: 0.35),
        )
        var result = counter.currentResult()
        for index in 0..<3 {
            result = counter.ingest(
                NativeFrameSnapshot(
                    timestampMs: index * 67,
                    sourceGeneration: 1,
                    pose: v7Pose(wristX: 0.25),
                    hand: [],
                    handSide: nil,
                    handScore: 0,
                    detectorLatencyMs: 4,
                    bottleDetection: bottleAt(bottle, timestampMs: index * 67),
                ),
            )
        }
        XCTAssertTrue(result.isArmed)

        for index in 3..<6 {
            result = counter.ingest(
                NativeFrameSnapshot(
                    timestampMs: index * 67,
                    sourceGeneration: 1,
                    pose: v7Pose(wristX: 0.72),
                    hand: [],
                    handSide: nil,
                    handScore: 0,
                    detectorLatencyMs: 4,
                    bottleDetection: bottleAt(bottle, timestampMs: index * 67),
                ),
            )
        }
        XCTAssertEqual(result.status, "inside_bottle_zone")

        for index in 6..<9 {
            result = counter.ingest(
                NativeFrameSnapshot(
                    timestampMs: index * 67,
                    sourceGeneration: 1,
                    pose: v7Pose(wristX: 0.25),
                    hand: [],
                    handSide: nil,
                    handScore: 0,
                    detectorLatencyMs: 4,
                    bottleDetection: bottleAt(bottle, timestampMs: index * 67),
                ),
            )
        }
        XCTAssertTrue(result.didCompleteCycle)
        XCTAssertEqual(result.totalCycles, 1)
    }

    func testV7ProximityCounterArmsForCountdownBeforeCountingIsEnabled() {
        let counter = NativeBottleProximityCounter()
        let bottle = NativeBottleDetection(
            sourceGeneration: 1,
            timestampMs: 0,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.65, y: 0.35, width: 0.2, height: 0.35),
        )

        let result = counter.ingest(
            NativeFrameSnapshot(
                timestampMs: 0,
                sourceGeneration: 1,
                pose: v7Pose(wristX: 0.25),
                hand: [],
                handSide: nil,
                handScore: 0,
                detectorLatencyMs: 4,
                bottleDetection: bottle,
            ),
        )

        XCTAssertTrue(result.isArmed)
        XCTAssertEqual(result.status, "armed_outside_zone")
        XCTAssertEqual(result.totalCycles, 0)
        XCTAssertEqual(result.reason, "practice_not_active")
    }

    func testV7ProximityCounterDoesNotCountStaleOrAmbiguousBottleDetection() {
        let counter = NativeBottleProximityCounter(maximumDetectionAgeMs: 200)
        counter.setCountingEnabled(true)
        let stale = NativeBottleDetection(
            sourceGeneration: 1,
            timestampMs: 0,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.65, y: 0.35, width: 0.2, height: 0.35),
        )
        let result = counter.ingest(
            NativeFrameSnapshot(
                timestampMs: 1_000,
                sourceGeneration: 1,
                pose: v7Pose(wristX: 0.72),
                hand: [],
                handSide: nil,
                handScore: 0,
                detectorLatencyMs: 4,
                bottleDetection: stale,
            ),
        )
        XCTAssertFalse(result.didCompleteCycle)
        XCTAssertEqual(result.reason, "bottle_detection_stale")
        XCTAssertEqual(result.totalCycles, 0)
    }

    func testV7NativeEngineCountsWithPoseAndBottleWithoutHandOrPhaseNet() {
        let engine = NativeBottleGrabEngine(counterMode: .bottleDetectorProximity)
        engine.setCountingEnabled(true)
        let bottle = NativeBottleDetection(
            sourceGeneration: 1,
            timestampMs: 0,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.65, y: 0.35, width: 0.2, height: 0.35),
        )
        var output: NativeBottleGrabOutput?
        for index in 0..<9 {
            let x: Float = index < 3 || index >= 6 ? 0.25 : 0.72
            output = engine.ingest(
                NativeFrameSnapshot(
                    timestampMs: index * 67,
                    sourceGeneration: 1,
                    pose: v7Pose(wristX: x),
                    hand: [],
                    handSide: nil,
                    handScore: 0,
                    detectorLatencyMs: 4,
                    bottleDetection: bottleAt(bottle, timestampMs: index * 67),
                ),
            )
        }

        XCTAssertEqual(output?.counterMode, "bottle_detector_proximity")
        XCTAssertEqual(output?.totalReps, 1)
        XCTAssertEqual(output?.handPoints, 0)
        XCTAssertEqual(output?.phaseStatus, "positioning")
        XCTAssertEqual(output?.repCounterProvenance, NativeBottleProximityCounter.provenance)
    }

    func testV7EngineReportsReadyForCountdownBeforeCountingIsEnabled() {
        let engine = NativeBottleGrabEngine(counterMode: .bottleDetectorProximity)
        let bottle = NativeBottleDetection(
            sourceGeneration: 1,
            timestampMs: 0,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.65, y: 0.35, width: 0.2, height: 0.35),
        )

        let output = engine.ingest(
            NativeFrameSnapshot(
                timestampMs: 0,
                sourceGeneration: 1,
                pose: v7Pose(wristX: 0.25),
                hand: [],
                handSide: nil,
                handScore: 0,
                detectorLatencyMs: 4,
                bottleDetection: bottle,
            ),
        )

        XCTAssertTrue(output.isTrackingReady)
        XCTAssertEqual(output.hostCounterStatus, "armed_outside_zone")
        XCTAssertEqual(output.totalReps, 0)
    }

    func testV7AIModuleExposesOneStableReusableModuleIdentityAndEngineRegistry() {
        XCTAssertEqual(NativeBottleGrabV7AIModule.moduleID, "bottle_grab_v7_ai_module")
        XCTAssertEqual(NativeBottleGrabV7AIModule.moduleVersion, "1.1.0-dev")
        XCTAssertEqual(NativeBottleGrabV7AIModule.baselineID, "bottle_grab_native_v7_ai_module_baseline_5")
        XCTAssertEqual(NativeBottleGrabV7AIModule.baselineNumber, 5)
        XCTAssertEqual(NativeBottleGrabV7AIModule.baselineVersion, "app-v7-bottle-detector-pose-proximity-0.1.0-dev")
        XCTAssertTrue(NativeBottleGrabV7AIModule.engineIDs.contains("bottle_grab_v7_bottle_detector"))
        XCTAssertTrue(NativeBottleGrabV7AIModule.engineIDs.contains("bottle_grab_v7_stable_bottle_anchor_v1"))
        XCTAssertTrue(NativeBottleGrabV7AIModule.engineIDs.contains("bottle_grab_v7_pose_proximity_counter_v1"))
        XCTAssertTrue(NativeBottleGrabV7AIModule.engineIDs.contains("bottle_grab_phasenet_v2_context_v1"))
    }

    func testV7AIModuleFacadeRunsThePoseBottleCounterWithoutHand() {
        let module = NativeBottleGrabV7AIModule()
        module.setCountingEnabled(true)
        let bottle = NativeBottleDetection(
            sourceGeneration: 1,
            timestampMs: 0,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.65, y: 0.35, width: 0.2, height: 0.35),
        )
        var output: NativeBottleGrabOutput?
        for index in 0..<9 {
            let x: Float = index < 3 || index >= 6 ? 0.25 : 0.72
            output = module.ingest(
                NativeFrameSnapshot(
                    timestampMs: index * 67,
                    sourceGeneration: 1,
                    pose: v7Pose(wristX: x),
                    hand: [],
                    handSide: nil,
                    handScore: 0,
                    detectorLatencyMs: 4,
                    bottleDetection: bottleAt(bottle, timestampMs: index * 67),
                ),
            )
        }
        XCTAssertEqual(output?.counterMode, "bottle_detector_proximity")
        XCTAssertEqual(output?.totalReps, 1)
    }

    func testV8FaultEvidenceFacadeRecordsDerivedCoverageWithoutChangingCounterAuthority() {
        let module = NativeBottleGrabV7AIModule()
        let bottle = NativeBottleDetection(
            sourceGeneration: 1,
            timestampMs: 0,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.65, y: 0.35, width: 0.2, height: 0.35),
        )
        let output = module.ingest(
            NativeFrameSnapshot(
                timestampMs: 0,
                sourceGeneration: 1,
                pose: v7Pose(wristX: 0.25),
                hand: [],
                handSide: nil,
                handScore: 0,
                detectorLatencyMs: 4,
                bottleDetection: bottle,
            ),
        )

        let evidence = module.currentFaultEvidenceRecord()
        XCTAssertTrue(NativeBottleGrabV7AIModule.supplementalObserverEngineIDs.contains(NativeFaultEvidenceV8Module.moduleID))
        XCTAssertEqual(evidence.coverage.observedFrames, 1)
        XCTAssertEqual(evidence.coverage.assessableFrames, 1)
        XCTAssertEqual(evidence.repetitionSummary.totalReps, 0)
        XCTAssertNil(evidence.repetitionSummary.correctRepCount)
        XCTAssertNil(evidence.repetitionSummary.incorrectRepCount)
        XCTAssertTrue(evidence.faultObservations.isEmpty)
        XCTAssertTrue(evidence.commentObservations.isEmpty)
        let encoded = try? module.encodedCurrentFaultEvidenceRecord()
        XCTAssertNotNil(encoded)
        XCTAssertEqual(output.totalReps, 0)
    }

    private func v7Pose(wristX: Float) -> [NativeLandmark] {
        var pose = Array(
            repeating: NativeLandmark(x: 0.25, y: 0.6, z: 0, visibility: 0.9),
            count: 33,
        )
        pose[11] = NativeLandmark(x: 0.25, y: 0.4, z: 0, visibility: 0.9)
        pose[13] = NativeLandmark(x: wristX * 0.8, y: 0.5, z: 0, visibility: 0.9)
        pose[15] = NativeLandmark(x: wristX, y: 0.55, z: 0, visibility: 0.9)
        pose[17] = NativeLandmark(x: wristX, y: 0.55, z: 0, visibility: 0.9)
        pose[19] = NativeLandmark(x: wristX, y: 0.55, z: 0, visibility: 0.9)
        pose[21] = NativeLandmark(x: wristX, y: 0.55, z: 0, visibility: 0.9)
        return pose
    }

    private func bottleAt(_ detection: NativeBottleDetection, timestampMs: Int) -> NativeBottleDetection {
        NativeBottleDetection(
            sourceGeneration: detection.sourceGeneration,
            timestampMs: timestampMs,
            label: detection.label,
            score: detection.score,
            boundingBox: detection.boundingBox,
        )
    }

    func testMediaPipeDelegatePreferenceHonorsDebugArguments() {
        XCTAssertEqual(
            NativeMediaPipeDelegatePreference.resolve(arguments: ["app", "--native-mediapipe-cpu"]),
            .cpu,
        )
        XCTAssertEqual(
            NativeMediaPipeDelegatePreference.resolve(arguments: ["app", "--native-mediapipe-gpu"]),
            .gpu,
        )
        XCTAssertEqual(
            NativeMediaPipeDelegatePreference.resolve(arguments: ["app"]),
            .automatic,
        )
    }

    func testV7BottleDetectorDelegatePolicyForcesCPUOnTheCrashAffectedIPhone12Mini() {
        XCTAssertEqual(
            NativeV7BottleDelegatePolicy.resolve(
                requested: .automatic,
                hardwareIdentifier: "iPhone13,1",
            ),
            .cpu,
        )
        XCTAssertEqual(
            NativeV7BottleDelegatePolicy.resolve(
                requested: .gpu,
                hardwareIdentifier: "iPhone13,1",
            ),
            .cpu,
        )
    }

    func testV731BottleDetectorDelegatePolicyNeverUsesGPUOnPhysicalHardware() {
        XCTAssertEqual(
            NativeV7BottleDelegatePolicy.resolve(
                requested: .automatic,
                hardwareIdentifier: "iPhone18,1",
            ),
            .cpu,
        )
        XCTAssertEqual(
            NativeV7BottleDelegatePolicy.resolve(
                requested: .gpu,
                hardwareIdentifier: "iPhone18,1",
            ),
            .cpu,
        )
        XCTAssertEqual(
            NativeV7BottleDelegatePolicy.resolve(
                requested: .cpu,
                hardwareIdentifier: "iPhone18,1",
            ),
            .cpu,
        )
    }

    func testV731BottleDetectorGateSeparatesSlowDetectorCadenceFromPoseCadence() {
        var gate = NativeBottleDetectorAdmissionGate()

        XCTAssertEqual(
            gate.admit(timestampMs: 1_000, now: 1),
            .admitted(expiredTimestampMs: nil),
        )
        XCTAssertEqual(
            gate.admit(timestampMs: 1_067, now: 1.067),
            .throttled,
        )

        gate.complete(timestampMs: 1_000)
        XCTAssertEqual(
            gate.admit(timestampMs: 1_150, now: 1.15),
            .admitted(expiredTimestampMs: nil),
        )
    }

    func testV731BottleDetectionCacheStaysUsableOnlyInsideFrozenFreshnessWindow() {
        let bottle = NativeBottleDetection(
            sourceGeneration: 4,
            timestampMs: 1_000,
            label: "bottle",
            score: 0.91,
            boundingBox: CGRect(x: 0.55, y: 0.25, width: 0.2, height: 0.5),
        )

        XCTAssertEqual(
            NativeBottleDetectionSelector.select(
                detections: [bottle],
                sourceGeneration: 4,
                timestampMs: 1_350,
            ).detection,
            bottle,
        )
        XCTAssertNil(
            NativeBottleDetectionSelector.select(
                detections: [bottle],
                sourceGeneration: 4,
                timestampMs: 1_351,
            ).detection,
        )
    }

    func testV731DetectorCadenceKeepsTheFrozenCounterUsableWithoutSameFrameBottleResults() {
        let counter = NativeBottleProximityCounter()
        counter.setCountingEnabled(true)
        let timestamps = [0, 67, 134, 201, 268, 335, 402, 469, 536]
        let wristPositions: [Float] = [0.25, 0.25, 0.25, 0.70, 0.70, 0.70, 0.25, 0.25, 0.25]
        let refreshedDetectionTimestamps = [0, 0, 0, 201, 201, 201, 402, 402, 402]
        var final = counter.currentResult()

        for (index, timestamp) in timestamps.enumerated() {
            final = counter.ingest(
                NativeFrameSnapshot(
                    timestampMs: timestamp,
                    sourceGeneration: 1,
                    pose: v7Pose(wristX: wristPositions[index]),
                    hand: [],
                    handSide: nil,
                    handScore: 0,
                    detectorLatencyMs: 4,
                    bottleDetection: NativeBottleDetection(
                        sourceGeneration: 1,
                        timestampMs: refreshedDetectionTimestamps[index],
                        label: "bottle",
                        score: 0.9,
                        boundingBox: CGRect(x: 0.65, y: 0.35, width: 0.2, height: 0.35),
                    ),
                ),
            )
        }

        XCTAssertTrue(final.didCompleteCycle)
        XCTAssertEqual(final.totalCycles, 1)
    }

    func testV734StableBottleAnchorContractExistsBeforeChangingCounterAuthority() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let nativeRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PhysioAINative")
        let detectionSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("NativeBottleDetection.swift"),
            encoding: .utf8,
        )
        let engineSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("NativeBottleGrabEngine.swift"),
            encoding: .utf8,
        )

        XCTAssertTrue(detectionSource.contains("final class NativeBottleAnchorTracker"))
        XCTAssertTrue(detectionSource.contains("anchor_held"))
        XCTAssertTrue(engineSource.contains("let bottleAnchor: NativeBottleAnchor?"))
    }

    func testV734BottleAnchorRequiresTwoNearbyDetectionsThenHoldsOriginalCheckpointAcrossMiss() {
        let tracker = NativeBottleAnchorTracker()
        let first = NativeBottleDetection(
            sourceGeneration: 7,
            timestampMs: 1_000,
            label: "bottle",
            score: 0.61,
            boundingBox: CGRect(x: 0.62, y: 0.30, width: 0.16, height: 0.38),
        )
        let provisional = tracker.observe(
            detection: first,
            sourceGeneration: 7,
            timestampMs: 1_000,
        )
        XCTAssertNil(provisional.anchor)
        XCTAssertEqual(provisional.state, .provisional)

        let confirmed = tracker.observe(
            detection: bottleAt(first, timestampMs: 1_150),
            sourceGeneration: 7,
            timestampMs: 1_150,
        )
        XCTAssertEqual(confirmed.state, .confirmed)
        XCTAssertEqual(confirmed.anchor?.detection.timestampMs, 1_000)
        XCTAssertEqual(confirmed.anchor?.lastConfirmedAtMs, 1_150)

        let held = tracker.observe(
            detection: nil,
            sourceGeneration: 7,
            timestampMs: 2_000,
        )
        XCTAssertEqual(held.state, .held)
        XCTAssertEqual(held.anchor?.detection.timestampMs, 1_000)
        XCTAssertEqual(held.anchor?.detection.boundingBox, first.boundingBox)
    }

    func testV734BottleAnchorDoesNotMoveForOneFarBoxButRelocatesAfterSecondMatchingFarBox() {
        let tracker = NativeBottleAnchorTracker()
        let original = NativeBottleDetection(
            sourceGeneration: 2,
            timestampMs: 1_000,
            label: "bottle",
            score: 0.88,
            boundingBox: CGRect(x: 0.15, y: 0.28, width: 0.16, height: 0.38),
        )
        _ = tracker.observe(detection: original, sourceGeneration: 2, timestampMs: 1_000)
        _ = tracker.observe(detection: bottleAt(original, timestampMs: 1_150), sourceGeneration: 2, timestampMs: 1_150)

        let relocatedCandidate = NativeBottleDetection(
            sourceGeneration: 2,
            timestampMs: 1_300,
            label: "bottle",
            score: 0.76,
            boundingBox: CGRect(x: 0.68, y: 0.28, width: 0.16, height: 0.38),
        )
        let relocationProvisional = tracker.observe(
            detection: relocatedCandidate,
            sourceGeneration: 2,
            timestampMs: 1_300,
        )
        XCTAssertEqual(relocationProvisional.state, .relocationProvisional)
        XCTAssertEqual(relocationProvisional.anchor?.detection.boundingBox, original.boundingBox)

        let relocated = tracker.observe(
            detection: bottleAt(relocatedCandidate, timestampMs: 1_450),
            sourceGeneration: 2,
            timestampMs: 1_450,
        )
        XCTAssertEqual(relocated.state, .relocated)
        XCTAssertEqual(relocated.anchor?.detection.boundingBox, relocatedCandidate.boundingBox)
        XCTAssertEqual(relocated.anchor?.detection.timestampMs, 1_300)
    }

    func testV734ConfirmedAnchorLetsCounterFinishCycleAfterFreshDetectorWindowExpires() {
        let counter = NativeBottleProximityCounter(maximumDetectionAgeMs: 200)
        counter.setCountingEnabled(true)
        let detection = NativeBottleDetection(
            sourceGeneration: 4,
            timestampMs: 0,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.65, y: 0.35, width: 0.2, height: 0.35),
        )
        let anchor = NativeBottleAnchor(
            sourceGeneration: 4,
            detection: detection,
            acquiredAtMs: 150,
            lastConfirmedAtMs: 150,
            state: .confirmed,
        )
        let timestamps = [700, 767, 834, 901, 968, 1_035, 1_102, 1_169, 1_236]
        let wristPositions: [Float] = [0.25, 0.25, 0.25, 0.70, 0.70, 0.70, 0.25, 0.25, 0.25]
        var final = counter.currentResult()

        for (index, timestamp) in timestamps.enumerated() {
            final = counter.ingest(
                NativeFrameSnapshot(
                    timestampMs: timestamp,
                    sourceGeneration: 4,
                    pose: v7Pose(wristX: wristPositions[index]),
                    hand: [],
                    handSide: nil,
                    handScore: 0,
                    detectorLatencyMs: 4,
                    bottleAnchor: anchor,
                ),
            )
        }

        XCTAssertTrue(final.didCompleteCycle)
        XCTAssertEqual(final.totalCycles, 1)
        XCTAssertNotEqual(final.reason, "bottle_detection_stale")
    }

    func testV734BottleAnchorClearsWhenSourceGenerationChanges() {
        let tracker = NativeBottleAnchorTracker()
        let bottle = NativeBottleDetection(
            sourceGeneration: 9,
            timestampMs: 1_000,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.62, y: 0.30, width: 0.16, height: 0.38),
        )
        _ = tracker.observe(detection: bottle, sourceGeneration: 9, timestampMs: 1_000)
        _ = tracker.observe(detection: bottleAt(bottle, timestampMs: 1_150), sourceGeneration: 9, timestampMs: 1_150)

        let afterSourceChange = tracker.observe(
            detection: nil,
            sourceGeneration: 10,
            timestampMs: 1_300,
        )
        XCTAssertNil(afterSourceChange.anchor)
        XCTAssertEqual(afterSourceChange.state, .waiting)
    }

    func testV734BottleAnchorIgnoresOutOfOrderDetectorCallbacks() {
        let tracker = NativeBottleAnchorTracker()
        let original = NativeBottleDetection(
            sourceGeneration: 3,
            timestampMs: 1_000,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.15, y: 0.28, width: 0.16, height: 0.38),
        )
        _ = tracker.observe(detection: original, sourceGeneration: 3, timestampMs: 1_000)
        _ = tracker.observe(detection: bottleAt(original, timestampMs: 1_150), sourceGeneration: 3, timestampMs: 1_150)
        _ = tracker.observe(detection: nil, sourceGeneration: 3, timestampMs: 1_400)

        let lateFarBox = NativeBottleDetection(
            sourceGeneration: 3,
            timestampMs: 1_300,
            label: "bottle",
            score: 0.9,
            boundingBox: CGRect(x: 0.68, y: 0.28, width: 0.16, height: 0.38),
        )
        let afterLateCallback = tracker.observe(
            detection: lateFarBox,
            sourceGeneration: 3,
            timestampMs: 1_300,
        )

        XCTAssertEqual(afterLateCallback.state, .held)
        XCTAssertEqual(afterLateCallback.anchor?.detection.boundingBox, original.boundingBox)
    }

    func testV734PipelineFeedsConfirmedAnchorToCounterWithoutRewritingDetectorFreshness() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let nativeRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PhysioAINative")
        let source = try String(
            contentsOf: nativeRoot.appendingPathComponent("MediaPipePipeline.swift"),
            encoding: .utf8,
        )

        XCTAssertTrue(source.contains("private var bottleAnchorTracker = NativeBottleAnchorTracker()"))
        XCTAssertTrue(source.contains("bottleAnchorTracker.observe("))
        XCTAssertTrue(source.contains("bottleAnchorTracker.reset()"))
        XCTAssertTrue(source.contains("bottleAnchor: bottleAnchorSnapshot.anchor"))
    }

    func testV734DiagnosticsShowAnchorStateSeparatelyFromRawDetectorFreshness() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let nativeRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PhysioAINative")
        let detectionSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("NativeBottleDetection.swift"),
            encoding: .utf8,
        )
        let viewSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("NativePracticeView.swift"),
            encoding: .utf8,
        )

        XCTAssertTrue(detectionSource.contains("let anchorState: NativeBottleAnchorState"))
        XCTAssertTrue(detectionSource.contains("func attaching(anchorSnapshot:"))
        XCTAssertTrue(viewSource.contains("bottleAnchorStatusCopy"))
    }

    func testV735TouchFocusUsesMountedPreviewCoordinatesAndBottleGrabCaptureGuard() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let nativeRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PhysioAINative")
        let previewSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("CameraPreview.swift"),
            encoding: .utf8,
        )
        let sessionSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("CameraSession.swift"),
            encoding: .utf8,
        )
        let practiceSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("NativePracticeView.swift"),
            encoding: .utf8,
        )

        XCTAssertTrue(previewSource.contains("captureDevicePointConverted(fromLayerPoint:"))
        XCTAssertTrue(previewSource.contains("onFocusPoint"))
        XCTAssertTrue(sessionSource.contains("func focus(at point:"))
        XCTAssertTrue(sessionSource.contains("NativeCaptureFocusPolicy"))
        XCTAssertTrue(practiceSource.contains("NativeBottleGrabCapturePolicy"))
        XCTAssertTrue(practiceSource.contains("onFocusPoint: camera.focus(at:)"))
    }

    func testV735FocusPolicyClampsInvalidPreviewPoints() {
        XCTAssertEqual(
            NativeCaptureFocusPolicy.clampedDevicePoint(CGPoint(x: -0.2, y: 1.3)),
            CGPoint(x: 0, y: 1),
        )
        XCTAssertEqual(
            NativeCaptureFocusPolicy.clampedDevicePoint(CGPoint(x: CGFloat.nan, y: CGFloat.nan)),
            CGPoint(x: 0.5, y: 0.5),
        )
    }

    func testV735BottleGrabCaptureGuardRetainsOneXAndLeavesOtherExercisesUnchanged() {
        let wide = NativeLensOption(id: "wide", title: "0.5×", zoomFactor: 0.5, deviceTypeRawValue: nil)
        let standard = NativeLensOption(id: "standard", title: "1×", zoomFactor: 1, deviceTypeRawValue: nil)

        XCTAssertEqual(
            NativeBottleGrabCapturePolicy.clampedZoom(
                0.5,
                exerciseID: "bottle_grab",
                deviceMinimumZoom: 0.5,
            ),
            1,
        )
        XCTAssertEqual(
            NativeBottleGrabCapturePolicy.clampedZoom(
                0.5,
                exerciseID: "sit_to_stand",
                deviceMinimumZoom: 0.5,
            ),
            0.5,
        )
        XCTAssertEqual(
            NativeBottleGrabCapturePolicy.visibleLensOptions([wide, standard], exerciseID: "bottle_grab"),
            [standard],
        )
        XCTAssertEqual(
            NativeBottleGrabCapturePolicy.visibleLensOptions([wide, standard], exerciseID: "sit_to_stand"),
            [wide, standard],
        )
    }

    func testV736SitToStandPresenceGateSuppressesRejectedRawPoseOverlay() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let nativeRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PhysioAINative")
        let sitToStandSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("NativeSitToStandV72AIModule.swift"),
            encoding: .utf8,
        )
        let practiceSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("NativePracticeView.swift"),
            encoding: .utf8,
        )

        XCTAssertTrue(sitToStandSource.contains("enum NativeSitToStandPresencePolicy"))
        XCTAssertTrue(sitToStandSource.contains("func shouldRenderRawPose"))
        XCTAssertTrue(sitToStandSource.contains("waitingForParticipantCopy"))
        XCTAssertTrue(practiceSource.contains("NativeSitToStandPresencePolicy.shouldRenderRawPose"))
        XCTAssertTrue(practiceSource.contains("snapshot: shouldRenderRawPoseOverlay ? latestSnapshot : nil"))
    }

    func testV733SplitsAuthoritativePoseBottleAndSecondaryHandOutputLanes() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let sourceURL = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PhysioAINative/MediaPipePipeline.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("private let onCounterSnapshot"))
        XCTAssertTrue(source.contains("private let onHandCommentSnapshot"))
        XCTAssertTrue(source.contains("private func publishCounterSnapshotIfReady"))
        XCTAssertTrue(source.contains("private func publishHandCommentSnapshotIfReady"))
        XCTAssertTrue(source.contains("poseLandmarker.detectAsync(image: image, timestampInMilliseconds: input.timestampMs)"))
        XCTAssertTrue(source.contains("handLandmarker.detectAsync(image: image, timestampInMilliseconds: input.timestampMs)"))
        XCTAssertTrue(source.contains("submitBottleDetectorIfScheduled(image: image, input: input, pixelBuffer: pixelBuffer)"))
        XCTAssertTrue(source.contains("bottleDetector.detectAsync(image: image, timestampInMilliseconds: input.timestampMs)"))
        XCTAssertFalse(
            source.contains("if enableHand, handLandmarker != nil, item.handCandidates == nil"),
            "The authoritative Pose+Bottle counter lane must never wait for Hand.",
        )

        let nativeRoot = sourceURL.deletingLastPathComponent()
        let moduleSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("NativeBottleGrabV7AIModule.swift"),
            encoding: .utf8,
        )
        XCTAssertTrue(moduleSource.contains("onHandCommentSnapshot"))
        XCTAssertTrue(moduleSource.contains("handCommentAdapter.ingest(snapshot)"))

        let cameraSessionSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("CameraSession.swift"),
            encoding: .utf8,
        )
        XCTAssertTrue(cameraSessionSource.contains("latestFingerComment"))
        XCTAssertTrue(cameraSessionSource.contains("consumeFingerComment"))
        XCTAssertTrue(cameraSessionSource.contains("latest.timestampMs > snapshot.timestampMs"))
    }

    func testV733BottleDetectorDiagnosticsAreVisibleWithoutChangingCounterAuthority() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let nativeRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PhysioAINative")

        let detectionSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("NativeBottleDetection.swift"),
            encoding: .utf8,
        )
        XCTAssertTrue(detectionSource.contains("struct NativeBottleDetectorDiagnostics"))
        XCTAssertTrue(detectionSource.contains("rawDetectionCount"))
        XCTAssertTrue(detectionSource.contains("acceptedBottleCount"))
        XCTAssertTrue(detectionSource.contains("topLabel"))
        XCTAssertTrue(detectionSource.contains("ageMs"))

        let pipelineSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("MediaPipePipeline.swift"),
            encoding: .utf8,
        )
        XCTAssertTrue(pipelineSource.contains("lastBottleDiagnostics"))
        XCTAssertTrue(pipelineSource.contains("bottleDiagnostics:"))

        let practiceSource = try String(
            contentsOf: nativeRoot.appendingPathComponent("NativePracticeView.swift"),
            encoding: .utf8,
        )
        XCTAssertTrue(practiceSource.contains("bottleDetectorStatusCopy"))
        XCTAssertTrue(practiceSource.contains("Bottle detector diagnostics"))
        XCTAssertFalse(practiceSource.contains("V7.3.2 same-frame Hand join"))
    }

    func testV733BottleDiagnosticsShowFreshAcceptanceThenStalenessWithoutChangingCounterInput() {
        let detection = NativeBottleDetection(
            sourceGeneration: 7,
            timestampMs: 1_000,
            label: "bottle",
            score: 0.82,
            boundingBox: CGRect(x: 0.5, y: 0.2, width: 0.2, height: 0.4),
        )
        let diagnostics = NativeBottleDetectorDiagnostics.result(
            sourceGeneration: 7,
            callbackTimestampMs: 1_000,
            selection: NativeBottleDetectionSelection(
                detection: detection,
                reason: "bottle_selected",
                candidateCount: 1,
            ),
            rawDetectionCount: 2,
            topLabel: "bottle",
            topScore: 0.82,
        )

        let fresh = diagnostics.observing(sourceGeneration: 7, timestampMs: 1_120)
        XCTAssertEqual(fresh.status, "bottle_detected")
        XCTAssertEqual(fresh.ageMs, 120)
        XCTAssertEqual(fresh.rawDetectionCount, 2)
        XCTAssertEqual(fresh.acceptedBottleCount, 1)
        XCTAssertEqual(fresh.acceptedDetection, detection)

        let stale = diagnostics.observing(sourceGeneration: 7, timestampMs: 1_351)
        XCTAssertEqual(stale.status, "bottle_stale")
        XCTAssertEqual(stale.ageMs, 351)
        XCTAssertNil(stale.acceptedDetection)
    }

    func testMediaPipeTelemetryTracksAndResetsAggregateDeliveryEvidence() {
        var telemetry = NativeMediaPipeTelemetry()
        telemetry.recordSubmitted()
        telemetry.recordCoalesced()
        telemetry.recordPoseCallback()
        telemetry.recordHandCallback(candidateCount: 0)
        telemetry.recordJoined(handCandidateCount: 0, selectedSide: nil, latencyMs: 120)

        XCTAssertEqual(telemetry.submittedFrames, 1)
        XCTAssertEqual(telemetry.coalescedFrames, 1)
        XCTAssertEqual(telemetry.poseCallbacks, 1)
        XCTAssertEqual(telemetry.handCallbacks, 1)
        XCTAssertEqual(telemetry.joinedSnapshots, 1)
        XCTAssertEqual(telemetry.emptyHandSnapshots, 1)
        XCTAssertEqual(telemetry.fallbackOrNoLeftSnapshots, 1)
        XCTAssertEqual(telemetry.totalLatencyMs, 120)

        telemetry.reset()
        XCTAssertEqual(telemetry, NativeMediaPipeTelemetry())
    }

    func testBottleGrabPoseDetectorMatchesTheTrainingFullAsset() {
        XCTAssertEqual(
            NativeBottleGrabPoseDetectorContract.assetName,
            "pose_landmarker_full",
        )
    }

    func testFullPoseAndHandTasksLoadForTheNativePipeline() {
        var status = ""
        let pipeline = MediaPipePipeline(
            onSnapshot: { _ in },
            onStatus: { status = $0 },
            enableBottleDetector: false,
        )

        XCTAssertNil(pipeline.setupError)
        XCTAssertEqual(pipeline.inferenceDelegateName, "CPU")
        XCTAssertEqual(status, "Native MediaPipe Pose Full · CPU live stream")
    }

    func testV7BottleDetectorLoadsTheBundledOnDeviceObjectDetector() {
        var status = ""
        let pipeline = MediaPipePipeline(
            onSnapshot: { _ in },
            onStatus: { status = $0 },
            enableBottleDetector: true,
        )

        XCTAssertNil(pipeline.setupError)
        XCTAssertEqual(pipeline.inferenceDelegateName, "CPU")
        XCTAssertTrue(status.contains("Bottle Detector"))
        XCTAssertEqual(NativeBottleDetectorContract.assetName, "efficientdet_lite0")
        XCTAssertEqual(NativeBottleDetectorContract.assetExtension, "tflite")
    }

    func testInferenceCaptureCadenceRequiresADeviceRangeContaining15Hz() {
        XCTAssertTrue(
            NativeInferenceCaptureCadencePolicy.supportsTargetFrameRate(
                minimum: 1,
                maximum: 30,
            ),
        )
        XCTAssertTrue(
            NativeInferenceCaptureCadencePolicy.supportsTargetFrameRate(
                minimum: 15,
                maximum: 15,
            ),
        )
        XCTAssertFalse(
            NativeInferenceCaptureCadencePolicy.supportsTargetFrameRate(
                minimum: 24,
                maximum: 60,
            ),
        )
        XCTAssertFalse(
            NativeInferenceCaptureCadencePolicy.supportsTargetFrameRate(
                minimum: .nan,
                maximum: 30,
            ),
        )
    }

    func testSourceTimestampClockRejectsOldFramesAndSeparatesCameraGenerations() {
        var clock = NativeSourceTimestampClock()

        XCTAssertEqual(clock.normalize(rawTimestampMs: 1_000), 1_000)
        XCTAssertEqual(clock.normalize(rawTimestampMs: 1_067), 1_067)
        XCTAssertNil(clock.normalize(rawTimestampMs: 1_067))

        clock.beginNewSource()
        XCTAssertEqual(clock.generation, 1)
        let replacementFirstFrame = clock.normalize(rawTimestampMs: 0)
        XCTAssertNotNil(replacementFirstFrame)
        XCTAssertGreaterThan(replacementFirstFrame ?? 0, 1_067)
        XCTAssertEqual((clock.normalize(rawTimestampMs: 67) ?? 0) - (replacementFirstFrame ?? 0), 67)
    }

    func testHandednessIsNormalizedForMirroredAndUnmirroredCameraInputs() {
        XCTAssertEqual(
            NativeHandedness.anatomicalSide(detectorSide: "Left", inputIsMirrored: true),
            "Left",
        )
        XCTAssertEqual(
            NativeHandedness.anatomicalSide(detectorSide: "Left", inputIsMirrored: false),
            "Right",
        )
        XCTAssertEqual(
            NativeHandedness.anatomicalSide(detectorSide: "Right", inputIsMirrored: false),
            "Left",
        )
        XCTAssertNil(NativeHandedness.anatomicalSide(detectorSide: "Unknown", inputIsMirrored: false))
    }

    func testPoseWristAssociationCorrectsLeftSideWhenContralateralWristIsOccluded() {
        let source = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = source.pose
        // Side-view capture can preserve the working left wrist while the
        // contralateral wrist falls below Pose visibility. The detector label
        // is intentionally inconsistent so the Pose association must win.
        pose[16] = NativeLandmark(
            x: pose[16].x,
            y: pose[16].y,
            z: pose[16].z,
            visibility: 0.2,
        )

        let resolution = NativeHandedness.resolve(
            detectorSide: "Left",
            inputIsMirrored: false,
            pose: pose,
            hand: source.hand,
        )

        XCTAssertEqual(resolution.side, "Left")
        XCTAssertEqual(resolution.source, "pose_left_wrist_corrected_unilateral")
    }

    func testHandCandidateSelectorAcceptsAssociatedLeftCandidateWithOneVisiblePoseWrist() {
        let source = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = source.pose
        pose[16] = NativeLandmark(
            x: pose[16].x,
            y: pose[16].y,
            z: pose[16].z,
            visibility: 0.2,
        )

        let selection = NativeHandCandidateSelector.select(
            candidates: [
                NativeHandCandidate(
                    index: 0,
                    landmarks: source.hand,
                    detectorSide: "Left",
                    score: 0.78,
                ),
            ],
            pose: pose,
            inputIsMirrored: false,
        )

        XCTAssertEqual(selection.side, "Left")
        XCTAssertEqual(selection.candidate?.landmarks[0], pose[15])
        XCTAssertTrue(selection.source.contains("pose_left_wrist_corrected_unilateral"))
    }

    func testPoseWristAssociationCorrectsAnInconsistentDetectorLabel() {
        let source = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = source.pose
        // Make the right arm/wrist credible too, so side selection is a real
        // same-frame geometry decision rather than the detector fallback.
        pose[12] = NativeLandmark(x: 0.60, y: 0.39, z: 0, visibility: 0.97)
        pose[14] = NativeLandmark(x: 0.68, y: 0.50, z: 0, visibility: 0.96)
        pose[16] = NativeLandmark(x: 0.72, y: 0.62, z: 0, visibility: 0.96)

        // In an unmirrored input this detector label would normally be
        // swapped to Right. The hand wrist is visibly anchored to pose[15],
        // so the same-frame association must restore anatomical Left.
        let resolution = NativeHandedness.resolve(
            detectorSide: "Left",
            inputIsMirrored: false,
            pose: pose,
            hand: source.hand,
        )
        XCTAssertEqual(resolution.side, "Left")
        XCTAssertEqual(resolution.source, "pose_left_wrist_corrected")
    }

    func testHandCandidateSelectorChoosesAssociatedLeftCandidateWhenRightComesFirst() {
        let source = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = source.pose
        pose[12] = NativeLandmark(x: 0.60, y: 0.39, z: 0, visibility: 0.97)
        pose[14] = NativeLandmark(x: 0.68, y: 0.50, z: 0, visibility: 0.96)
        pose[16] = NativeLandmark(x: 0.72, y: 0.62, z: 0, visibility: 0.96)

        let leftHand = source.hand
        let offsetX = pose[16].x - leftHand[0].x
        let offsetY = pose[16].y - leftHand[0].y
        let rightHand = leftHand.map { point in
            NativeLandmark(
                x: point.x + offsetX,
                y: point.y + offsetY,
                z: point.z,
                visibility: point.visibility,
            )
        }

        for candidates in [
            [
                NativeHandCandidate(index: 0, landmarks: rightHand, detectorSide: "Left", score: 0.99),
                NativeHandCandidate(index: 1, landmarks: leftHand, detectorSide: "Left", score: 0.70),
            ],
            [
                NativeHandCandidate(index: 0, landmarks: leftHand, detectorSide: "Left", score: 0.70),
                NativeHandCandidate(index: 1, landmarks: rightHand, detectorSide: "Left", score: 0.99),
            ],
        ] {
            let selection = NativeHandCandidateSelector.select(
                candidates: candidates,
                pose: pose,
                inputIsMirrored: false,
            )

            XCTAssertEqual(selection.side, "Left")
            XCTAssertEqual(selection.candidate?.landmarks[0], pose[15])
            XCTAssertTrue(selection.source.contains("pose_left_wrist"))
        }
    }

    func testHandCandidateSelectorKeepsRightCandidateOnlyForFailClosedDiagnostics() {
        let source = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = source.pose
        pose[12] = NativeLandmark(x: 0.60, y: 0.39, z: 0, visibility: 0.97)
        pose[14] = NativeLandmark(x: 0.68, y: 0.50, z: 0, visibility: 0.96)
        pose[16] = NativeLandmark(x: 0.72, y: 0.62, z: 0, visibility: 0.96)
        let offsetX = pose[16].x - source.hand[0].x
        let offsetY = pose[16].y - source.hand[0].y
        let rightHand = source.hand.map { point in
            NativeLandmark(
                x: point.x + offsetX,
                y: point.y + offsetY,
                z: point.z,
                visibility: point.visibility,
            )
        }

        let selection = NativeHandCandidateSelector.select(
            candidates: [
                NativeHandCandidate(index: 0, landmarks: rightHand, detectorSide: "Left", score: 0.98),
            ],
            pose: pose,
            inputIsMirrored: false,
        )

        XCTAssertEqual(selection.side, "Right")
        XCTAssertNil(selection.candidate)
        XCTAssertTrue(selection.source.contains("fallback_no_left"))
    }

    func testHandCandidateSelectorNeverPassesRightFallbackLandmarksIntoTheModelInput() {
        let source = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = source.pose
        pose[12] = NativeLandmark(x: 0.60, y: 0.39, z: 0, visibility: 0.97)
        pose[14] = NativeLandmark(x: 0.68, y: 0.50, z: 0, visibility: 0.96)
        pose[16] = NativeLandmark(x: 0.72, y: 0.62, z: 0, visibility: 0.96)
        let offsetX = pose[16].x - source.hand[0].x
        let offsetY = pose[16].y - source.hand[0].y
        let rightHand = source.hand.map { point in
            NativeLandmark(
                x: point.x + offsetX,
                y: point.y + offsetY,
                z: point.z,
                visibility: point.visibility,
            )
        }

        let selection = NativeHandCandidateSelector.select(
            candidates: [
                NativeHandCandidate(index: 0, landmarks: rightHand, detectorSide: "Left", score: 0.98),
            ],
            pose: pose,
            inputIsMirrored: false,
        )

        // A real right-hand result remains useful as diagnostics, but it
        // must never become the 21-point input supplied to the left-trained
        // PhaseNet path.
        XCTAssertNil(selection.candidate)
        XCTAssertEqual(selection.side, "Right")
        XCTAssertTrue(selection.source.contains("fallback_no_left"))
    }

    func testHandCandidateSelectorPublishesAggregateEvidenceForEveryReturnedHand() {
        let source = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = source.pose
        pose[12] = NativeLandmark(x: 0.60, y: 0.39, z: 0, visibility: 0.97)
        pose[14] = NativeLandmark(x: 0.68, y: 0.50, z: 0, visibility: 0.96)
        pose[16] = NativeLandmark(x: 0.72, y: 0.62, z: 0, visibility: 0.96)
        let offsetX = pose[16].x - source.hand[0].x
        let offsetY = pose[16].y - source.hand[0].y
        let rightHand = source.hand.map { point in
            NativeLandmark(
                x: point.x + offsetX,
                y: point.y + offsetY,
                z: point.z,
                visibility: point.visibility,
            )
        }

        let selection = NativeHandCandidateSelector.select(
            candidates: [
                NativeHandCandidate(index: 0, landmarks: rightHand, detectorSide: "Left", score: 0.98),
                NativeHandCandidate(index: 1, landmarks: source.hand, detectorSide: "Left", score: 0.70),
            ],
            pose: pose,
            inputIsMirrored: false,
        )

        XCTAssertEqual(selection.candidateTrace.count, 2)
        XCTAssertEqual(selection.candidateTrace[0].index, 0)
        XCTAssertEqual(selection.candidateTrace[1].index, 1)
        XCTAssertEqual(selection.candidateTrace[0].resolvedSide, "Right")
        XCTAssertEqual(selection.candidateTrace[1].resolvedSide, "Left")
        XCTAssertNotNil(selection.candidateTrace[0].leftWristDistance)
        XCTAssertNotNil(selection.candidateTrace[0].rightWristDistance)
        XCTAssertTrue(selection.compactCandidateTrace.hasPrefix("mirrored=false"))
        XCTAssertTrue(selection.compactCandidateTrace.contains("c1"))
        XCTAssertTrue(selection.compactCandidateTrace.contains("c2"))
    }

    func testCandidateTraceLogPolicyEmitsOnStateChangeOrAtOneSecondIntervals() {
        XCTAssertTrue(
            NativeCandidateTraceLogPolicy.shouldEmit(
                previousState: nil,
                previousTimestampMs: nil,
                nextState: "generation=1|side=Left",
                timestampMs: 100,
            ),
        )
        XCTAssertFalse(
            NativeCandidateTraceLogPolicy.shouldEmit(
                previousState: "generation=1|side=Left",
                previousTimestampMs: 100,
                nextState: "generation=1|side=Left",
                timestampMs: 1_099,
            ),
        )
        XCTAssertTrue(
            NativeCandidateTraceLogPolicy.shouldEmit(
                previousState: "generation=1|side=Left",
                previousTimestampMs: 100,
                nextState: "generation=1|side=Left",
                timestampMs: 1_100,
            ),
        )
        XCTAssertTrue(
            NativeCandidateTraceLogPolicy.shouldEmit(
                previousState: "generation=1|side=Left",
                previousTimestampMs: 100,
                nextState: "generation=1|side=Right",
                timestampMs: 101,
            ),
        )
    }

    func testHandCandidateSelectorRequestsTwoHandsAndIsOrderIndependentUnderStress() {
        XCTAssertEqual(NativeHandCandidateSelector.maximumHandCandidates, 2)

        let source = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        var pose = source.pose
        pose[12] = NativeLandmark(x: 0.60, y: 0.39, z: 0, visibility: 0.97)
        pose[14] = NativeLandmark(x: 0.68, y: 0.50, z: 0, visibility: 0.96)
        pose[16] = NativeLandmark(x: 0.72, y: 0.62, z: 0, visibility: 0.96)
        let offsetX = pose[16].x - source.hand[0].x
        let offsetY = pose[16].y - source.hand[0].y
        let rightHand = source.hand.map { point in
            NativeLandmark(
                x: point.x + offsetX,
                y: point.y + offsetY,
                z: point.z,
                visibility: point.visibility,
            )
        }

        for iteration in 0..<5_000 {
            let candidates: [NativeHandCandidate]
            if iteration.isMultiple(of: 2) {
                candidates = [
                    NativeHandCandidate(index: 0, landmarks: rightHand, detectorSide: "Left", score: 0.99),
                    NativeHandCandidate(index: 1, landmarks: source.hand, detectorSide: "Left", score: 0.70),
                ]
            } else {
                candidates = [
                    NativeHandCandidate(index: 0, landmarks: source.hand, detectorSide: "Left", score: 0.70),
                    NativeHandCandidate(index: 1, landmarks: rightHand, detectorSide: "Left", score: 0.99),
                ]
            }
            let selection = NativeHandCandidateSelector.select(
                candidates: candidates,
                pose: pose,
                inputIsMirrored: false,
            )

            XCTAssertEqual(selection.side, "Left")
            XCTAssertEqual(selection.candidate?.landmarks[0], pose[15])
            XCTAssertTrue(selection.source.contains("selected_left"))
            let expectedCandidatePosition = iteration.isMultiple(of: 2) ? 2 : 1
            XCTAssertTrue(selection.source.contains("candidate_\(expectedCandidatePosition)_of_2"))
        }
    }

    func testHandCandidateSelectionRetainsAllFullBodyPoseEvidenceForShoulderConsumers() {
        let source = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        let originalPose = source.pose
        XCTAssertEqual(originalPose.count, 33)
        XCTAssertGreaterThanOrEqual(originalPose[11].visibility, 0.5) // left shoulder
        XCTAssertGreaterThanOrEqual(originalPose[12].visibility, 0.5) // right shoulder
        XCTAssertGreaterThanOrEqual(originalPose[23].visibility, 0.5) // left hip
        XCTAssertGreaterThanOrEqual(originalPose[24].visibility, 0.5) // right hip

        let selection = NativeHandCandidateSelector.select(
            candidates: [
                NativeHandCandidate(index: 0, landmarks: source.hand, detectorSide: "Left", score: 0.98),
            ],
            pose: originalPose,
            inputIsMirrored: true,
        )

        XCTAssertEqual(selection.side, "Left")
        XCTAssertEqual(originalPose, source.pose)
        XCTAssertEqual(originalPose.count, 33)
    }

    func testRearLensCatalogUsesReportedPhysicalDevices() {
        let options = NativeLensCatalog.make(
            position: .back,
            availableDeviceTypes: [
                AVCaptureDevice.DeviceType.builtInUltraWideCamera.rawValue,
                AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue,
                AVCaptureDevice.DeviceType.builtInTelephotoCamera.rawValue,
            ],
            minZoom: 1,
            maxZoom: 13.8,
            displayZoomByDeviceType: [
                AVCaptureDevice.DeviceType.builtInUltraWideCamera.rawValue: 0.5,
                AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue: 1,
                AVCaptureDevice.DeviceType.builtInTelephotoCamera.rawValue: 4,
            ],
        )

        XCTAssertEqual(options.map(\.title), ["0.5×", "1×", "4×"])
        XCTAssertFalse(options.contains { $0.title.localizedCaseInsensitiveContains("max") })
        XCTAssertEqual(
            options[0].deviceTypeRawValue,
            AVCaptureDevice.DeviceType.builtInUltraWideCamera.rawValue,
        )
        XCTAssertEqual(
            options[2].deviceTypeRawValue,
            AVCaptureDevice.DeviceType.builtInTelephotoCamera.rawValue,
        )
    }

    func testRearLensCatalogSupportsAFlattenedTripleCameraInventory() {
        let options = NativeLensCatalog.make(
            position: .back,
            availableDeviceTypes: [
                AVCaptureDevice.DeviceType.builtInTripleCamera.rawValue,
                AVCaptureDevice.DeviceType.builtInUltraWideCamera.rawValue,
                AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue,
                AVCaptureDevice.DeviceType.builtInTelephotoCamera.rawValue,
            ],
            minZoom: 1,
            maxZoom: 14,
            displayZoomByDeviceType: [
                AVCaptureDevice.DeviceType.builtInUltraWideCamera.rawValue: 0.5,
                AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue: 1,
                AVCaptureDevice.DeviceType.builtInTelephotoCamera.rawValue: 4,
            ],
        )

        XCTAssertEqual(options.map(\.id), ["ultra-wide", "wide", "tele"])
        XCTAssertEqual(options.map(\.title), ["0.5×", "1×", "4×"])
    }

    func testVirtualCameraLensCatalogUsesItsActualSwitchOverFactors() {
        let options = NativeLensCatalog.make(
            position: .back,
            availableDeviceTypes: [AVCaptureDevice.DeviceType.builtInTripleCamera.rawValue],
            minZoom: 0.5,
            maxZoom: 14,
            virtualDeviceZoomFactors: [1, 4],
            displayZoomMultiplier: 1,
        )

        XCTAssertEqual(options.map(\.title), ["0.5×", "1×", "4×"])
        XCTAssertEqual(options.map(\.zoomFactor), [0.5, 1, 4])
        XCTAssertTrue(options.allSatisfy { $0.deviceTypeRawValue == nil })
    }

    func testVirtualLensSegmentsResetOnlyAtReportedSwitchOverBoundaries() {
        let factors: [CGFloat] = [1, 4]
        XCTAssertEqual(
            NativeLensCatalog.virtualLensSegment(
                zoom: 0.75,
                minimumZoom: 0.5,
                switchOverFactors: factors,
            ),
            0,
        )
        XCTAssertEqual(
            NativeLensCatalog.virtualLensSegment(
                zoom: 1.0,
                minimumZoom: 0.5,
                switchOverFactors: factors,
            ),
            1,
        )
        XCTAssertEqual(
            NativeLensCatalog.virtualLensSegment(
                zoom: 3.9,
                minimumZoom: 0.5,
                switchOverFactors: factors,
            ),
            1,
        )
        XCTAssertEqual(
            NativeLensCatalog.virtualLensSegment(
                zoom: 4.0,
                minimumZoom: 0.5,
                switchOverFactors: factors,
            ),
            2,
        )
    }

    func testInferenceAdmissionGateDropsBacklogAndIgnoresLateCompletion() {
        var gate = NativeInferenceAdmissionGate()
        XCTAssertEqual(
            gate.admit(timestampMs: 100, now: 0),
            .admitted(expiredTimestampMs: nil),
        )
        XCTAssertEqual(gate.admit(timestampMs: 167, now: 0.05), .throttled)
        XCTAssertEqual(
            gate.admit(timestampMs: 500, now: 0.36),
            .admitted(expiredTimestampMs: 100),
        )
        // A callback from the expired frame cannot release the newer frame.
        gate.complete(timestampMs: 100)
        XCTAssertEqual(gate.inFlightTimestampMs, 500)
        gate.complete(timestampMs: 500)
        XCTAssertNil(gate.inFlightTimestampMs)
    }

    func testLensCatalogFallsBackWhenPhysicalDevicesAreAbsent() {
        let options = NativeLensCatalog.make(
            position: .back,
            availableDeviceTypes: [],
            minZoom: 1,
            maxZoom: 1,
        )

        XCTAssertEqual(options.map(\.title), ["1×"])
        XCTAssertNil(options[0].deviceTypeRawValue)
    }

    func testFrontLensCatalogDoesNotExposeRearPhysicalDevices() {
        let options = NativeLensCatalog.make(
            position: .front,
            availableDeviceTypes: [
                AVCaptureDevice.DeviceType.builtInUltraWideCamera.rawValue,
                AVCaptureDevice.DeviceType.builtInTelephotoCamera.rawValue,
            ],
            minZoom: 1,
            maxZoom: 5,
        )

        XCTAssertEqual(options.map(\.title), ["1×"])
        XCTAssertTrue(options.allSatisfy { $0.deviceTypeRawValue == nil })
    }

    func testCatalogExposesBottleGrabAndSitToStand() async {
        let app = await MainActor.run { NativeAppModel() }
        let catalog = await MainActor.run { app.catalog }
        XCTAssertEqual(catalog.map(\.id), NativeAppBuildProfile.catalog(for: NativeAppBuildProfile.active).map(\.id))
    }

    func testFixtureFramesAreAssessableByNativeAdapter() {
        let engine = NativeBottleGrabEngine()
        var output: NativeBottleGrabOutput?
        for frame in 1...16 {
            output = engine.ingest(NativeFixtureProvider.snapshot(frame: frame))
        }
        XCTAssertEqual(output?.captureQC, "can_assess")
        XCTAssertEqual(output?.posePoints, 33)
        XCTAssertEqual(output?.handPoints, 21)
        XCTAssertEqual(output?.handSide, "Left")
    }

    func testFixtureUsesPhaseNetCadenceAndAssociatedFullBodyLeftHand() {
        let first = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        let second = NativeFixtureProvider.fullBodySnapshot(frame: 2)

        XCTAssertEqual(second.timestampMs - first.timestampMs, 67)
        XCTAssertEqual(first.hand[0].x, first.pose[15].x, accuracy: 0.000_001)
        XCTAssertEqual(first.hand[0].y, first.pose[15].y, accuracy: 0.000_001)
        XCTAssertNil(NativeBottleGrabSetupGate.evaluate(first).reason)
    }

    func testBottleGrabFixtureCountsOnlyScriptedFullCycles() {
        let engine = NativeBottleGrabEngine(phaseTracker: NativeFixturePhaseTracker())
        engine.setCountingEnabled(true)
        var output: NativeBottleGrabOutput?
        for frame in 1...230 {
            output = engine.ingest(NativeFixtureProvider.snapshot(frame: frame))
        }

        XCTAssertEqual(output?.captureQC, "can_assess")
        XCTAssertEqual(output?.totalReps, 1)
        XCTAssertTrue(output?.experimental == true)
    }

    func testNativeZoomPolicyDoesNotExposeRawDigitalMaxAsLens() {
        XCTAssertEqual(NativeZoomPolicy.effectiveMax(rawMax: 123.8, recommendedMax: 14), 14, accuracy: 0.0001)
        XCTAssertEqual(NativeZoomPolicy.effectiveMax(rawMax: 123.8, recommendedMax: nil), 123.8, accuracy: 0.0001)
    }

    func testLensTapCancelsQueuedPinchZoomBeforeItCanOverwriteTheLensSelection() {
        let mailbox = NativeZoomRequestMailbox()

        XCTAssertTrue(mailbox.submit(3))
        mailbox.cancelPending()

        XCTAssertNil(mailbox.takeNewest())
        // A later, genuine pinch remains valid after the cancelled stale one
        // has been consumed by the already queued camera-session callback.
        XCTAssertTrue(mailbox.submit(0.5))
        guard let laterPinch = mailbox.takeNewest() else {
            return XCTFail("A new pinch must remain available after cancelling stale work")
        }
        XCTAssertEqual(laterPinch, 0.5, accuracy: 0.0001)
    }

    func testStaticPlanAdapterProducesNonExperimentalComparatorOutput() {
        let engine = NativeExerciseEngine()
        let exercise = NativeExercise.from(id: "lateral_arm_raise")!
        engine.configure(exercise: exercise)

        var pose = Array(repeating: NativeLandmark(x: 0.5, y: 0.5, z: 0, visibility: 0.95), count: 33)
        // Left shoulder angle (elbow -> shoulder -> hip) is deliberately
        // non-degenerate so the static comparator can assess a frame.
        pose[13] = NativeLandmark(x: 0.40, y: 0.55, z: 0, visibility: 0.95)
        pose[11] = NativeLandmark(x: 0.40, y: 0.40, z: 0, visibility: 0.95)
        pose[23] = NativeLandmark(x: 0.55, y: 0.40, z: 0, visibility: 0.95)

        let output = engine.ingest(NativeFrameSnapshot(
            timestampMs: 0,
            pose: pose,
            hand: [],
            handSide: nil,
            handScore: 0,
            detectorLatencyMs: 3.1,
        ))

        XCTAssertEqual(output.captureQC, "can_assess")
        XCTAssertEqual(output.experimental, false)
        XCTAssertEqual(output.modelStatus, "native_static_angle_comparator")
        XCTAssertNotNil(output.primaryAngle)
    }

    func testSessionFlowReachesSummaryWithoutClinicalResult() async {
        await MainActor.run {
            let app = NativeAppModel()
            app.continueAsSimulatorPatient()
            app.openExercise(.bottleGrab)
            XCTAssertEqual(app.route, .practice)
            app.finishPractice(cuesPresented: 1, startedAt: Date().addingTimeInterval(-3))
            XCTAssertEqual(app.route, .summary)
            XCTAssertTrue(app.latestSummary?.experimentalOnly == true)
        }
    }
}
