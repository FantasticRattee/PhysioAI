import XCTest
@testable import PhysioAINative

final class NativeSitToStandRuleBasedEvidenceV12Tests: XCTestCase {
    func testPersistentTrunkTiltFinalizesAnIncorrectCompletedRepetition() throws {
        let recorder = NativeSitToStandRuleBasedEvidenceV12Module()
        for timestamp in stride(from: 0, through: 490, by: 70) {
            recorder.ingest(
                frame: makeFrame(timestampMs: timestamp, metrics: highTrunkTiltMetrics),
                output: makeOutput(totalReps: 0, status: "rising"),
            )
        }
        recorder.ingest(
            frame: makeFrame(timestampMs: 560, metrics: neutralMetrics),
            output: makeOutput(totalReps: 1, status: "seated_rest", repetitionCompleted: true),
        )

        let record = recorder.currentRecord()
        XCTAssertEqual(record.schema, "physioai.rule_based_sit_to_stand_session.v1")
        XCTAssertEqual(record.exerciseID, NativeSitToStandV72AIModule.exerciseID)
        XCTAssertEqual(record.summary.totalReps, 1)
        XCTAssertEqual(record.summary.incorrectRepCount, 1)
        XCTAssertEqual(record.repetitions.first?.outcome, .incorrect)
        XCTAssertEqual(record.repetitions.first?.severity, "high")
        XCTAssertEqual(record.repetitions.first?.faultTags, ["trunk_view_plane_tilt"])
        XCTAssertEqual(record.repetitions.first?.bodyRegions, ["trunk"])
    }

    func testOneFrameGeometryExcursionDoesNotCreateAnIncorrectFormClaim() {
        let recorder = NativeSitToStandRuleBasedEvidenceV12Module()
        recorder.ingest(
            frame: makeFrame(timestampMs: 0, metrics: highTrunkTiltMetrics),
            output: makeOutput(totalReps: 0, status: "rising"),
        )
        for timestamp in stride(from: 70, through: 490, by: 70) {
            recorder.ingest(
                frame: makeFrame(timestampMs: timestamp, metrics: neutralMetrics),
                output: makeOutput(totalReps: 0, status: "rising"),
            )
        }
        recorder.ingest(
            frame: makeFrame(timestampMs: 560, metrics: neutralMetrics),
            output: makeOutput(totalReps: 1, status: "seated_rest", repetitionCompleted: true),
        )

        let record = recorder.currentRecord()
        XCTAssertEqual(record.summary.correctRepCount, 1)
        XCTAssertEqual(record.summary.incorrectRepCount, 0)
        XCTAssertEqual(record.repetitions.first?.outcome, .correct)
        XCTAssertTrue(record.repetitions.first?.faultTags.isEmpty ?? false)
    }

    func testThresholdConfigurationCoversAllApprovedBodyRegionFamilies() {
        let signals = NativeSitToStandEvidenceThresholds.developmentDefault.qualifiedSignals(
            for: NativeSitToStandEvidenceMetrics(
                trunkViewPlaneTiltDeg: 40,
                trunkLateralOffsetNorm: 0.40,
                hipAngleDifferenceDeg: 45,
                kneeAngleDifferenceDeg: 45,
                footCenterOffsetFromPelvisNorm: 0.60,
            ),
        )

        XCTAssertEqual(
            Set(signals.map(\.semanticID)),
            Set([
                "trunk_view_plane_tilt",
                "trunk_lateral_offset",
                "hip_left_right_asymmetry",
                "knee_left_right_asymmetry",
                "foot_base_offset",
            ]),
        )
        XCTAssertEqual(
            Set(signals.map(\.bodyRegion)),
            Set([
                "trunk",
                "left_hip", "right_hip",
                "left_knee", "right_knee",
                "left_foot", "right_foot",
            ]),
        )
        XCTAssertTrue(signals.allSatisfy { $0.severity == "high" })
    }

    func testNoAssessableMovementFramesIsCoverageNotAFault() {
        let recorder = NativeSitToStandRuleBasedEvidenceV12Module()
        recorder.ingest(
            frame: makeFrame(timestampMs: 0, metrics: nil, featureReady: false, reason: "pose_only_capture_qc_failed"),
            output: makeOutput(totalReps: 1, status: "seated_rest", repetitionCompleted: true, trackingReady: false),
        )

        let record = recorder.currentRecord()
        XCTAssertEqual(record.summary.cannotAssessRepCount, 1)
        XCTAssertEqual(record.summary.incorrectRepCount, 0)
        XCTAssertEqual(record.repetitions.first?.outcome, .cannotAssess)
        XCTAssertTrue(record.repetitions.first?.faultTags.isEmpty ?? false)
    }

    func testSitToStandRecordRoundTripsThroughLocalEvidenceValidation() throws {
        let recorder = NativeSitToStandRuleBasedEvidenceV12Module()
        for timestamp in stride(from: 0, through: 490, by: 70) {
            recorder.ingest(
                frame: makeFrame(timestampMs: timestamp, metrics: neutralMetrics),
                output: makeOutput(totalReps: 0, status: "standing_hold"),
            )
        }
        recorder.ingest(
            frame: makeFrame(timestampMs: 560, metrics: neutralMetrics),
            output: makeOutput(totalReps: 1, status: "seated_rest", repetitionCompleted: true),
        )

        let data = try recorder.encodedFinalizedCurrentRecord()
        let decoded = try NativeEvidenceExport.validate(data)
        XCTAssertEqual(decoded.exerciseID, NativeSitToStandV72AIModule.exerciseID)
        XCTAssertEqual(decoded.summary.totalReps, 1)

        let url = try NativeEvidenceExport.writeTemporaryFile(data)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("physioai-sit-to-stand-evidence-"))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }

    @MainActor
    func testFinalizedFaultSummaryFeedsTheExistingSessionInvalidRepAggregate() throws {
        let recorder = NativeSitToStandRuleBasedEvidenceV12Module()
        for timestamp in stride(from: 0, through: 490, by: 70) {
            recorder.ingest(
                frame: makeFrame(timestampMs: timestamp, metrics: highTrunkTiltMetrics),
                output: makeOutput(totalReps: 0, status: "rising"),
            )
        }
        recorder.ingest(
            frame: makeFrame(timestampMs: 560, metrics: neutralMetrics),
            output: makeOutput(totalReps: 1, status: "seated_rest", repetitionCompleted: true),
        )
        let evidence = try recorder.encodedFinalizedCurrentRecord()

        let app = NativeAppModel()
        app.openPlanItem(
            NativePlanItem(
                exerciseId: NativeSitToStandV72AIModule.exerciseID,
                reps: 1,
                sets: 1,
            ),
        )
        app.finishPractice(
            cuesPresented: 0,
            startedAt: Date().addingTimeInterval(-1),
            completedReps: 1,
            ruleBasedEvidenceJSON: evidence,
        )

        XCTAssertEqual(app.latestSummary?.reps, 1)
        XCTAssertEqual(app.latestSummary?.sets, 1)
        XCTAssertEqual(app.latestSummary?.invalidReps, 1)
    }

    private var neutralMetrics: NativeSitToStandEvidenceMetrics {
        NativeSitToStandEvidenceMetrics(
            trunkViewPlaneTiltDeg: 0,
            trunkLateralOffsetNorm: 0,
            hipAngleDifferenceDeg: 0,
            kneeAngleDifferenceDeg: 0,
            footCenterOffsetFromPelvisNorm: 0,
        )
    }

    private var highTrunkTiltMetrics: NativeSitToStandEvidenceMetrics {
        NativeSitToStandEvidenceMetrics(
            trunkViewPlaneTiltDeg: 40,
            trunkLateralOffsetNorm: 0,
            hipAngleDifferenceDeg: 0,
            kneeAngleDifferenceDeg: 0,
            footCenterOffsetFromPelvisNorm: 0,
        )
    }

    private func makeFrame(
        timestampMs: Int,
        metrics: NativeSitToStandEvidenceMetrics?,
        featureReady: Bool = true,
        reason: String? = nil,
    ) -> NativeSitToStandFeatureFrame {
        NativeSitToStandFeatureFrame(
            timestampMs: timestampMs,
            sourceGeneration: 1,
            featureVector: featureReady ? Array(repeating: 0, count: 30) : nil,
            pelvisHeightAboveAnklesNorm: featureReady ? 0.5 : nil,
            meanKneeAngleDeg: featureReady ? 90 : nil,
            wristSpanNorm: featureReady ? 0.1 : nil,
            reason: reason,
            evidenceMetrics: metrics,
        )
    }

    private func makeOutput(
        totalReps: Int,
        status: String,
        repetitionCompleted: Bool = false,
        trackingReady: Bool = true,
    ) -> NativeSitToStandOutput {
        NativeSitToStandOutput(
            captureQC: trackingReady ? "pose_geometry_only" : "cannot_assess",
            setupReason: trackingReady ? nil : "pose_only_capture_qc_failed",
            featureFrameCount: 0,
            geometryStatus: status,
            geometryReason: nil,
            geometryTotalReps: totalReps,
            geometryRepetitionCompleted: repetitionCompleted,
            handsTogetherStatus: "hands_together_latched",
            phase: nil,
            phaseStatus: "context_only",
            phaseProbabilities: nil,
            commentStatus: "context_only",
            cue: nil,
            cueThai: nil,
            commentRepetitionCount: 0,
            isTrackingReady: trackingReady,
            evidenceMetrics: nil,
        )
    }
}
