import XCTest
@testable import PhysioAINative

final class NativeSitToStandV72Tests: XCTestCase {
    func testStandingAtEntryCannotBecomeASeatedBaselineWhenDepthIsLarge() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)
        let outputs = (0..<55).map {
            module.ingest(realisticPostureSnapshot(timestampMs: $0 * 67, extension: 1))
        }
        XCTAssertEqual(outputs.last?.geometryStatus, "awaiting_seated_baseline")
        XCTAssertEqual(outputs.last?.geometryTotalReps, 0)
    }

    func testRealModuleCountsThreeWholeBodyCyclesWithChangingDepthStartingStanding() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)
        var timeline = Array(repeating: Float(1), count: 55)
        for _ in 0..<3 {
            timeline += stride(from: Float(0.9), through: 0, by: -0.1).map { $0 }
            timeline += Array(repeating: Float(0), count: 45)
            timeline += (1...10).map { Float($0) / 10 }
            timeline += Array(repeating: Float(1), count: 12)
            timeline += stride(from: Float(0.9), through: 0, by: -0.1).map { $0 }
            timeline += Array(repeating: Float(0), count: 8)
        }
        let outputs = timeline.enumerated().map { index, extensionValue in
            module.ingest(realisticPostureSnapshot(timestampMs: index * 67, extension: extensionValue))
        }
        XCTAssertEqual(outputs.last?.geometryTotalReps, 3)
        XCTAssertEqual(outputs.filter(\.geometryRepetitionCompleted).count, 3)
    }

    func testRealModuleStartingSeatedCanCompleteOneCycle() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)
        let timeline = Array(repeating: Float(0), count: 45)
            + (1...10).map { Float($0) / 10 }
            + Array(repeating: Float(1), count: 12)
            + stride(from: Float(0.9), through: 0, by: -0.1).map { $0 }
            + Array(repeating: Float(0), count: 8)
        let outputs = timeline.enumerated().map { index, extensionValue in
            module.ingest(realisticPostureSnapshot(timestampMs: index * 67, extension: extensionValue))
        }
        XCTAssertEqual(outputs.last?.geometryTotalReps, 1)
    }

    func testShortCameraCadenceGapDoesNotEraseAValidCycle() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)
        let timeline = Array(repeating: Float(0), count: 45)
            + (1...10).map { Float($0) / 10 }
            + Array(repeating: Float(1), count: 12)
            + stride(from: Float(0.9), through: 0, by: -0.1).map { $0 }
            + Array(repeating: Float(0), count: 8)
        var timestamp = 0
        let outputs = timeline.enumerated().map { index, extensionValue in
            // One dropped frame during rising; every observed pose is valid.
            timestamp += index == 52 ? 134 : 67
            return module.ingest(realisticPostureSnapshot(timestampMs: timestamp, extension: extensionValue))
        }
        XCTAssertEqual(outputs.last?.geometryTotalReps, 1)
    }

    func testHandsTogetherAloneDoesNotImplyThePatientIsSeated() {
        var policy = NativeActionCuePresentationPolicy()
        var result: NativeActionCuePresentation?
        for frame in 0..<35 {
            result = policy.observe(
                rawStatus: "hands_together_latched", totalReps: 0,
                isSitToStand: true, isThai: true,
                fallback: "กำลังตรวจท่านั่งหรือยืน", now: Double(frame) * 0.067
            )
        }
        XCTAssertFalse(result?.visualText.contains("ลุกขึ้น") ?? false)
    }

    func testInitialSitInstructionRemainsAvailableAfterCountdownWhileStillStanding() {
        var policy = NativeActionCuePresentationPolicy()
        var result: NativeActionCuePresentation?
        for frame in 0...50 {
            result = policy.observe(rawStatus: "awaiting_seated_baseline", totalReps: 0,
                isSitToStand: true, isThai: true, fallback: "", now: Double(frame) * 0.067)
        }
        // Voice is disabled during countdown. Showing the card must not
        // consume the instruction before Active can submit it to TTS.
        XCTAssertEqual(result?.speechText, "ดีมาก นั่งลงได้เลย")
        XCTAssertEqual(result?.semanticKey, "sts:initial_seat")
    }

    func testFirstRiseInstructionKeepsItsSpeechKeyWhileThePatientRemainsSeated() {
        var policy = NativeActionCuePresentationPolicy()
        var result: NativeActionCuePresentation?
        for frame in 0...50 {
            result = policy.observe(rawStatus: "seated_rest", totalReps: 0,
                isSitToStand: true, isThai: true, fallback: "", now: Double(frame) * 0.067)
        }
        XCTAssertEqual(result?.speechText, "ดีมาก ลุกขึ้นได้เลย")
        XCTAssertEqual(result?.semanticKey, "sts:first_rise")
    }

    func testGuidedStartChecksStandingThenSeatedBeforeGivingFirstRiseCue() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)
        var policy = NativeActionCuePresentationPolicy()
        var frame = 0
        var presentation: NativeActionCuePresentation?
        var spokenChanges: [String] = []
        var lastKey: String?
        func step(_ extensionValue: Float, frames: Int) {
            for _ in 0..<frames {
                let output = module.ingest(realisticPostureSnapshot(timestampMs: frame * 67, extension: extensionValue))
                presentation = policy.observe(rawStatus: output.actionCueStatus,
                    totalReps: output.totalReps, isSitToStand: true, isThai: true,
                    fallback: "กำลังตรวจท่านั่งหรือยืน", now: Double(frame) * 0.067)
                if let presentation, presentation.semanticKey != lastKey {
                    if let speech = presentation.speechText { spokenChanges.append(speech) }
                    lastKey = presentation.semanticKey
                }
                frame += 1
            }
        }
        step(1, frames: 55)
        XCTAssertTrue(presentation?.visualText.contains("นั่งลง") ?? false)
        XCTAssertFalse(spokenChanges.contains(where: { $0.contains("ลุกขึ้น") }))
        step(0, frames: 10)
        XCTAssertFalse(spokenChanges.contains(where: { $0.contains("ลุกขึ้น") }), "Do not ask for a rise before seated baseline dwell.")
        step(0, frames: 45)
        XCTAssertEqual(spokenChanges.filter { $0 == "ดีมาก ลุกขึ้นได้เลย" }.count, 1)
        XCTAssertEqual(spokenChanges.filter { $0 == "ดีมาก นั่งลงได้เลย" }.count, 1)
    }

    func testRealModuleDoesNotCountAPartialRise() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)
        let timeline = Array(repeating: Float(0), count: 45)
            + Array(repeating: Float(0.5), count: 20)
            + Array(repeating: Float(0), count: 10)
        let outputs = timeline.enumerated().map {
            module.ingest(realisticPostureSnapshot(timestampMs: $0.offset * 67, extension: $0.element))
        }
        XCTAssertEqual(outputs.last?.totalReps, 0)
    }

    func testRealModuleDoesNotTurnAShortStandingSpikeAndSlowDescentIntoAHeldStand() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)
        let timeline = Array(repeating: Float(0), count: 45)
            + [Float(1), 1]
            + Array(repeating: Float(0.55), count: 12)
            + Array(repeating: Float(0), count: 10)
        let outputs = timeline.enumerated().map {
            module.ingest(realisticPostureSnapshot(timestampMs: $0.offset * 67, extension: $0.element))
        }
        XCTAssertEqual(outputs.last?.totalReps, 0)
    }

    func testLongCameraGapDiscardsTheUnfinishedCycle() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)
        let timeline = Array(repeating: Float(0), count: 45)
            + (1...10).map { Float($0) / 10 }
            + Array(repeating: Float(1), count: 12)
            + stride(from: Float(0.9), through: 0, by: -0.1).map { $0 }
            + Array(repeating: Float(0), count: 8)
        var timestamp = 0
        let outputs = timeline.enumerated().map { index, extensionValue in
            timestamp += index == 52 ? 800 : 67
            return module.ingest(realisticPostureSnapshot(timestampMs: timestamp, extension: extensionValue))
        }
        XCTAssertEqual(outputs.last?.totalReps, 0)
    }

    /// Synthetic regression pose with an upright torso that moves with the
    /// hips. It deliberately varies estimated depth; it is not a landmark
    /// extraction or a numeric replay of the user's screen recording.
    private func realisticPostureSnapshot(timestampMs: Int, extension value: Float) -> NativeFrameSnapshot {
        var pose = makePoseOnlySnapshot(timestampMs: timestampMs).pose
        let hipY: Float = 0.68 - 0.15 * value
        let shoulderY = hipY - 0.22
        let depth: Float = 0.05 + 0.60 * value
        let points: [Int: (Float, Float, Float)] = [
            0: (0.5, shoulderY - 0.10, -depth),
            11: (0.40, shoulderY, -depth), 12: (0.60, shoulderY, -depth),
            13: (0.42, shoulderY + 0.09, -depth * 0.6), 14: (0.58, shoulderY + 0.09, -depth * 0.6),
            15: (0.49, hipY - 0.03, -0.02), 16: (0.51, hipY - 0.03, -0.02),
            23: (0.43, hipY, 0), 24: (0.57, hipY, 0),
            25: (0.42, 0.72, -0.20 * (1-value)), 26: (0.58, 0.72, -0.20 * (1-value)),
            27: (0.42, 0.88, 0), 28: (0.58, 0.88, 0),
            31: (0.39, 0.92, -0.01), 32: (0.61, 0.92, -0.01),
        ]
        for (index, point) in points {
            pose[index] = NativeLandmark(x: point.0, y: point.1, z: point.2, visibility: 0.99)
        }
        return NativeFrameSnapshot(timestampMs: timestampMs, pose: pose, hand: [], handSide: nil, handScore: 0, detectorLatencyMs: 0)
    }

    func testGeometryCounterCompletesOneCycleWithoutAnyPhaseNetInput() {
        var counter = NativeSitToStandGeometryCounter()
        counter.setCountingEnabled(true)

        let samples: [(Int, Float)] = [
            (0, 0.52), (67, 0.50), (134, 0.51),
            (2_400, 0.50), (2_467, 0.64), (2_534, 0.83),
            (2_601, 1.04), (2_668, 1.12), (2_735, 1.14),
            (2_802, 0.91), (2_869, 0.70), (2_936, 0.57),
            (3_003, 0.55),
        ]

        let outputs = samples.map { timestamp, height in
            counter.ingest(pelvisHeightAboveAnklesNorm: height, timestampMs: timestamp)
        }

        XCTAssertEqual(outputs.last?.totalReps, 1)
        XCTAssertTrue(outputs.contains(where: \.repetitionCompleted))
        XCTAssertEqual(outputs.last?.status, "seated_rest")
    }

    func testGeometryCounterDoesNotCountAnIncompleteStand() {
        var counter = NativeSitToStandGeometryCounter()
        counter.setCountingEnabled(true)

        let samples: [(Int, Float)] = [
            (0, 0.52), (67, 0.50), (134, 0.51),
            (2_400, 0.50), (2_467, 0.64), (2_534, 0.83),
            (2_601, 0.91), (2_668, 0.82), (2_735, 0.55),
        ]

        let outputs = samples.map { timestamp, height in
            counter.ingest(pelvisHeightAboveAnklesNorm: height, timestampMs: timestamp)
        }

        XCTAssertEqual(outputs.last?.totalReps, 0)
        XCTAssertFalse(outputs.contains(where: \.repetitionCompleted))
    }

    func testGeometryCounterCountsGradualLoweringAfterStableStand() {
        var counter = NativeSitToStandGeometryCounter()
        counter.setCountingEnabled(true)

        let samples: [(Int, Float)] = [
            (0, 0.52), (67, 0.50), (134, 0.51),
            (2_400, 0.50), (2_467, 0.64), (2_534, 0.83),
            (2_601, 1.03), (2_668, 1.11), (2_735, 1.14),
            (2_802, 1.08), (2_869, 1.01), (2_936, 0.94),
            (3_003, 0.82), (3_070, 0.68), (3_137, 0.57), (3_204, 0.55),
        ]

        let outputs = samples.map { timestamp, height in
            counter.ingest(pelvisHeightAboveAnklesNorm: height, timestampMs: timestamp)
        }

        XCTAssertEqual(outputs.last?.totalReps, 1)
        XCTAssertTrue(outputs.contains(where: \.repetitionCompleted))
    }

    func testGeometryCounterRequiresTheContractFrontStandingThreshold() {
        var counter = NativeSitToStandGeometryCounter()
        counter.setCountingEnabled(true)

        let samples: [(Int, Float)] = [
            (0, 0.52), (67, 0.50), (134, 0.51),
            (2_400, 0.50), (2_467, 0.64), (2_534, 0.83),
            (2_601, 1.04), (2_668, 1.08), (2_735, 1.09),
            (2_802, 0.90), (2_869, 0.70), (2_936, 0.55),
        ]

        let outputs = samples.map { timestamp, height in
            counter.ingest(pelvisHeightAboveAnklesNorm: height, timestampMs: timestamp)
        }

        XCTAssertEqual(outputs.last?.totalReps, 0)
        XCTAssertFalse(outputs.contains(where: \.repetitionCompleted))
    }

    func testGeometryCounterCountsBaselineRelativeFullStandBelowLegacyAbsoluteThreshold() {
        var counter = NativeSitToStandGeometryCounter()
        counter.setCountingEnabled(true)

        // Synthetic V8.0.14 scalar-contract example only. This is not the
        // measured geometry of the physical-device recording; V8.0.15's
        // real module tests cover depth changes and whole-body posture.
        let samples: [(Int, Float, Float)] = [
            (0, 0.52, 96), (67, 0.50, 95), (134, 0.51, 97),
            (2_400, 0.50, 96), (2_467, 0.64, 118), (2_534, 0.83, 142),
            (2_601, 0.94, 154), (2_668, 0.98, 160), (2_735, 0.98, 162), (2_802, 0.98, 162),
            (2_936, 0.90, 148), (3_003, 0.70, 118), (3_070, 0.57, 98), (3_137, 0.55, 96),
        ]

        let outputs = samples.map { timestamp, height, kneeAngle in
            counter.ingest(
                pelvisHeightAboveAnklesNorm: height,
                averageKneeAngleDeg: kneeAngle,
                timestampMs: timestamp,
            )
        }

        XCTAssertEqual(outputs.last?.totalReps, 1)
        XCTAssertTrue(outputs.contains(where: \.repetitionCompleted))
    }

    func testGeometryCounterDoesNotCountBaselineRelativePartialRiseWithBentKnees() {
        var counter = NativeSitToStandGeometryCounter()
        counter.setCountingEnabled(true)

        let samples: [(Int, Float, Float)] = [
            (0, 0.52, 96), (67, 0.50, 95), (134, 0.51, 97),
            (2_400, 0.50, 96), (2_467, 0.64, 112), (2_534, 0.83, 125),
            (2_601, 0.94, 132), (2_668, 0.98, 134), (2_735, 0.98, 134),
            (2_802, 0.90, 126), (2_869, 0.70, 110), (2_936, 0.55, 96),
        ]

        let outputs = samples.map { timestamp, height, kneeAngle in
            counter.ingest(
                pelvisHeightAboveAnklesNorm: height,
                averageKneeAngleDeg: kneeAngle,
                timestampMs: timestamp,
            )
        }

        XCTAssertEqual(outputs.last?.totalReps, 0)
        XCTAssertFalse(outputs.contains(where: \.repetitionCompleted))
        XCTAssertEqual(outputs[7].reason, "standing_qualification_pending")
    }

    func testGeometryCounterDoesNotCountATwoFrameStandingSpike() {
        var counter = NativeSitToStandGeometryCounter()
        counter.setCountingEnabled(true)

        // The first two high values are a plausible short-lived scale error,
        // not a human reaching and holding a stable stand. Returning straight
        // to seated must re-arm the counter rather than create a completed rep.
        let samples: [(Int, Float)] = [
            (0, 0.52), (67, 0.50), (134, 0.51),
            (2_400, 0.50), (2_467, 0.64),
            (2_534, 1.12), (2_601, 1.14),
            (2_668, 0.55), (2_735, 0.52),
        ]

        let outputs = samples.map { timestamp, height in
            counter.ingest(pelvisHeightAboveAnklesNorm: height, timestampMs: timestamp)
        }

        XCTAssertEqual(outputs.last?.totalReps, 0)
        XCTAssertFalse(outputs.contains(where: \.repetitionCompleted))
    }

    func testGeometryCounterCompletesTwoSitStandSitCyclesWithSeatedRearm() {
        var counter = NativeSitToStandGeometryCounter()
        counter.setCountingEnabled(true)

        let samples: [(Int, Float)] = [
            (0, 0.52), (67, 0.50), (134, 0.51),
            (2_400, 0.50), (2_467, 0.64),
            (2_534, 0.83), (2_601, 1.12), (2_668, 1.14), (2_735, 1.14), (2_802, 1.13), (2_869, 1.12),
            (2_936, 0.91), (3_003, 0.70), (3_070, 0.57), (3_137, 0.52),
            (5_500, 0.51), (5_567, 0.64), (5_634, 0.83), (5_701, 1.12), (5_768, 1.14), (5_835, 1.14), (5_902, 1.13), (5_969, 1.12),
            (6_036, 0.91), (6_103, 0.70), (6_170, 0.57), (6_237, 0.52),
        ]

        let outputs = samples.map { timestamp, height in
            counter.ingest(pelvisHeightAboveAnklesNorm: height, timestampMs: timestamp)
        }

        XCTAssertEqual(outputs.last?.totalReps, 2)
        XCTAssertEqual(outputs.filter(\.repetitionCompleted).count, 2)
        XCTAssertEqual(outputs.last?.status, "seated_rest")
    }

    func testPoseOnlyFeatureExtractorAcceptsFullBodyPoseWithoutHandLandmarks() {
        let snapshot = makePoseOnlySnapshot(timestampMs: 0)

        let frame = NativeSitToStandFeatureExtractor().extract(snapshot)

        XCTAssertTrue(frame.featureReady)
        XCTAssertEqual(frame.featureVector?.count, 30)
        XCTAssertTrue(frame.meanKneeAngleDeg?.isFinite ?? false)
        XCTAssertEqual(frame.reason, nil)
    }

    func testPoseOnlyFeatureExtractorRejectsMirroredInputForFrontReferenceContract() {
        var snapshot = makePoseOnlySnapshot(timestampMs: 0)
        snapshot = NativeFrameSnapshot(
            timestampMs: snapshot.timestampMs,
            inputIsMirrored: true,
            pose: snapshot.pose,
            hand: snapshot.hand,
            handSide: snapshot.handSide,
            handScore: snapshot.handScore,
            detectorLatencyMs: snapshot.detectorLatencyMs,
        )

        let frame = NativeSitToStandFeatureExtractor().extract(snapshot)

        XCTAssertFalse(frame.featureReady)
        XCTAssertEqual(frame.reason, "source_mirrored")
    }

    func testV72ModuleDeclaresSeparateParallelEngines() {
        XCTAssertEqual(NativeSitToStandV72AIModule.moduleID, "sit_to_stand_v7_ai_module")
        XCTAssertEqual(NativeSitToStandV72AIModule.exerciseID, "sit_to_stand")
        XCTAssertEqual(NativeSitToStandV72AIModule.trackingProfile, "pose_only")
        XCTAssertTrue(NativeSitToStandV72AIModule.engineIDs.contains("sit_to_stand_pose_wrist_admission_gate_v2"))
        XCTAssertTrue(NativeSitToStandV72AIModule.engineIDs.contains("sit_to_stand_geometry_counter_v2_image_plane"))
        XCTAssertTrue(NativeSitToStandV72AIModule.engineIDs.contains("sit_to_stand_phasenet_v1_comment_context"))
    }

    func testFacadeGeometryCountDoesNotWaitForPhaseCommentCycle() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)

        var outputs: [NativeSitToStandOutput] = []
        for frame in 1...72 {
            outputs.append(module.ingest(NativeFixtureProvider.sitToStandSnapshot(frame: frame)))
        }

        XCTAssertGreaterThanOrEqual(outputs.last?.geometryTotalReps ?? 0, 1)
        XCTAssertTrue(outputs.contains(where: { $0.geometryRepetitionCompleted }))
        XCTAssertFalse(outputs.last?.phaseStatus.isEmpty ?? true)
    }

    func testPoseOnlySeparatedWristsBlockARepetitionAndProvideHandsTogetherCue() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)

        let outputs = (1...72).map { frame in
            module.ingest(
                withWristPositions(
                    NativeFixtureProvider.sitToStandSnapshot(frame: frame),
                    left: (0.31, 0.56),
                    right: (0.69, 0.56),
                ),
            )
        }

        XCTAssertEqual(outputs.last?.geometryTotalReps, 0)
        XCTAssertTrue(outputs.contains(where: { $0.geometryStatus == "hands_together_required" }))
        XCTAssertTrue(outputs.contains(where: { $0.cueThai == "โปรดประสานมือทั้งสองข้างก่อนเริ่ม" }))
    }

    func testPoseOnlyMissingWristBlocksARepetitionAndProvidesVisibilityCue() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)

        let outputs = (1...72).map { frame in
            module.ingest(
                withRightWristVisibility(
                    NativeFixtureProvider.sitToStandSnapshot(frame: frame),
                    visibility: 0.10,
                ),
            )
        }

        XCTAssertEqual(outputs.last?.geometryTotalReps, 0)
        XCTAssertTrue(outputs.contains(where: { $0.geometryStatus == "hands_not_assessable" }))
        XCTAssertTrue(outputs.contains(where: { $0.cueThai == "ให้เห็นมือทั้งสองข้างในกล้องก่อนเริ่ม" }))
    }

    func testPoseOnlyCloseWristsAllowARepetitionWithoutHandLandmarks() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)

        let outputs = (1...72).map { frame in
            module.ingest(
                withWristPositions(
                    NativeFixtureProvider.sitToStandSnapshot(frame: frame),
                    left: (0.49, 0.56),
                    right: (0.51, 0.56),
                ),
            )
        }

        XCTAssertGreaterThanOrEqual(outputs.last?.geometryTotalReps ?? 0, 1)
        XCTAssertTrue(outputs.contains(where: \.geometryRepetitionCompleted))
        XCTAssertEqual(outputs.last?.captureQC, "pose_geometry_only")
    }

    func testModuleReportsPoseGeometryOnlyInsteadOfFullCaptureQC() {
        let module = NativeSitToStandV72AIModule()

        let output = module.ingest(NativeFixtureProvider.sitToStandSnapshot(frame: 1))

        XCTAssertEqual(output.captureQC, "pose_geometry_only")
        XCTAssertTrue(output.isTrackingReady)
    }

    func testV736PresencePolicyHidesRawPoseUntilSitToStandQCIsReady() {
        XCTAssertFalse(NativeSitToStandPresencePolicy.shouldRenderRawPose(isTrackingReady: false))
        XCTAssertTrue(NativeSitToStandPresencePolicy.shouldRenderRawPose(isTrackingReady: true))

        let thai = NativeSitToStandPresencePolicy.waitingForParticipantCopy(isThai: true)
        let english = NativeSitToStandPresencePolicy.waitingForParticipantCopy(isThai: false)
        XCTAssertEqual(thai.title, "รอให้ผู้ฝึกเข้ากล้อง")
        XCTAssertEqual(english.title, "Waiting for participant")
    }

    func testModulePreservesCompletedCountAcrossATemporaryPoseQCFailure() {
        let module = NativeSitToStandV72AIModule()
        module.setCountingEnabled(true)

        var lastGood: NativeSitToStandOutput?
        for frame in 1...72 {
            lastGood = module.ingest(NativeFixtureProvider.sitToStandSnapshot(frame: frame))
        }
        let invalid = NativeFrameSnapshot(
            timestampMs: 5_000,
            pose: [],
            hand: [],
            handSide: nil,
            handScore: 0,
            detectorLatencyMs: 0,
        )

        let afterFailure = module.ingest(invalid)

        XCTAssertGreaterThanOrEqual(lastGood?.geometryTotalReps ?? 0, 1)
        XCTAssertEqual(afterFailure.captureQC, "cannot_assess")
        XCTAssertEqual(afterFailure.geometryTotalReps, lastGood?.geometryTotalReps)
    }

    func testSitToStandIsAnExplicitSelectableExperimentalExercise() {
        let exercise = NativeExercise.from(id: "sit_to_stand")

        XCTAssertEqual(exercise?.id, "sit_to_stand")
        XCTAssertEqual(exercise?.titleThai, "ลุก-นั่งจากเก้าอี้")
        XCTAssertTrue(exercise?.isExperimental ?? false)
    }

    @MainActor
    func testNativeUserCatalogIncludesSitToStandAlongsideBottleGrab() {
        let app = NativeAppModel()

        XCTAssertEqual(app.catalog.map(\.id), ["bottle_grab", "sit_to_stand"])
    }

    private func makePoseOnlySnapshot(timestampMs: Int) -> NativeFrameSnapshot {
        var pose = Array(repeating: NativeLandmark(x: 0.5, y: 0.5, z: 0, visibility: 0.99), count: 33)
        let points: [Int: (Float, Float)] = [
            0: (0.50, 0.12),
            11: (0.40, 0.28), 12: (0.60, 0.28),
            13: (0.35, 0.42), 14: (0.65, 0.42),
            15: (0.31, 0.56), 16: (0.69, 0.56),
            23: (0.42, 0.55), 24: (0.58, 0.55),
            25: (0.43, 0.70), 26: (0.57, 0.70),
            27: (0.44, 0.88), 28: (0.56, 0.88),
            31: (0.40, 0.94), 32: (0.60, 0.94),
        ]
        for (index, point) in points {
            pose[index] = NativeLandmark(x: point.0, y: point.1, z: 0, visibility: 0.99)
        }
        return NativeFrameSnapshot(
            timestampMs: timestampMs,
            pose: pose,
            hand: [],
            handSide: nil,
            handScore: 0,
            detectorLatencyMs: 0,
        )
    }

    private func withWristPositions(
        _ snapshot: NativeFrameSnapshot,
        left: (Float, Float),
        right: (Float, Float),
    ) -> NativeFrameSnapshot {
        var pose = snapshot.pose
        pose[15] = NativeLandmark(x: left.0, y: left.1, z: 0, visibility: 0.99)
        pose[16] = NativeLandmark(x: right.0, y: right.1, z: 0, visibility: 0.99)
        return NativeFrameSnapshot(
            timestampMs: snapshot.timestampMs,
            sourceGeneration: snapshot.sourceGeneration,
            inputIsMirrored: snapshot.inputIsMirrored,
            pose: pose,
            hand: snapshot.hand,
            handSide: snapshot.handSide,
            handScore: snapshot.handScore,
            detectorLatencyMs: snapshot.detectorLatencyMs,
        )
    }

    private func withRightWristVisibility(
        _ snapshot: NativeFrameSnapshot,
        visibility: Float,
    ) -> NativeFrameSnapshot {
        var pose = snapshot.pose
        let right = pose[16]
        pose[16] = NativeLandmark(x: right.x, y: right.y, z: right.z, visibility: visibility)
        return NativeFrameSnapshot(
            timestampMs: snapshot.timestampMs,
            sourceGeneration: snapshot.sourceGeneration,
            inputIsMirrored: snapshot.inputIsMirrored,
            pose: pose,
            hand: snapshot.hand,
            handSide: snapshot.handSide,
            handScore: snapshot.handScore,
            detectorLatencyMs: snapshot.detectorLatencyMs,
        )
    }
}
