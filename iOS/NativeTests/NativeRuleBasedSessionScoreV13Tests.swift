import XCTest
@testable import PhysioAINative

final class NativeRuleBasedSessionScoreV13Tests: XCTestCase {
    func testBottleGrabCorrectRepetitionsProducePerfectAvailableScore() {
        let record = makeRecord(
            exerciseID: NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
            repetitions: [correctRep(1), correctRep(2), correctRep(3)],
        )

        let score = NativeRuleBasedSessionScorerV13.score(record)

        XCTAssertEqual(score.availability, .available)
        XCTAssertEqual(score.totalReps, 3)
        XCTAssertEqual(score.assessableReps, 3)
        XCTAssertEqual(score.flaggedReps, 0)
        XCTAssertEqual(score.formQualityScore, 100)
        XCTAssertEqual(score.consistencyScore, 100)
        XCTAssertEqual(score.evidenceCoverageScore, 100)
        XCTAssertEqual(score.overallScore, 100)
        XCTAssertTrue(score.faultBreakdown.isEmpty)
    }

    func testSitToStandDeduplicatesOneSemanticFaultAcrossBothBodyRegions() throws {
        let left = signal(
            semanticID: "hip_left_right_asymmetry",
            bodyRegion: "left_hip",
            severity: "high",
        )
        let right = signal(
            semanticID: "hip_left_right_asymmetry",
            bodyRegion: "right_hip",
            severity: "high",
        )
        let record = makeRecord(
            exerciseID: NativeSitToStandV72AIModule.exerciseID,
            repetitions: [incorrectRep(1, signals: [left, right]), correctRep(2), correctRep(3)],
        )

        let score = NativeRuleBasedSessionScorerV13.score(record)

        XCTAssertEqual(score.formQualityScore, 88)
        XCTAssertEqual(score.consistencyScore, 67)
        XCTAssertEqual(score.overallScore, 84)
        XCTAssertEqual(score.flaggedReps, 1)
        let breakdown = try XCTUnwrap(score.faultBreakdown.first)
        XCTAssertEqual(breakdown.categoryID, "hip_symmetry")
        XCTAssertEqual(breakdown.flaggedRepCount, 1)
        XCTAssertEqual(breakdown.strongestSeverity, "high")
        XCTAssertEqual(breakdown.semanticIDs, ["hip_left_right_asymmetry"])
    }

    func testSeverityDeductionsUseUnknownFallbackAndFortyPointRepFloor() {
        let record = makeRecord(
            exerciseID: NativeSitToStandV72AIModule.exerciseID,
            repetitions: [
                incorrectRep(
                    1,
                    signals: [
                        signal(semanticID: "fault_low", bodyRegion: "trunk", severity: "low"),
                        signal(semanticID: "fault_medium", bodyRegion: "trunk", severity: "medium"),
                        signal(semanticID: "fault_high", bodyRegion: "trunk", severity: "high"),
                        signal(semanticID: "fault_unknown", bodyRegion: "trunk", severity: "unexpected"),
                    ],
                ),
            ],
        )

        let score = NativeRuleBasedSessionScorerV13.score(record)

        XCTAssertEqual(score.formQualityScore, 40)
        XCTAssertEqual(score.consistencyScore, 0)
        XCTAssertEqual(score.overallScore, 32)
        XCTAssertEqual(score.evidenceCoverageScore, 100)
    }

    func testCannotAssessAndIncompleteRepetitionsAreExcludedInsteadOfPenalized() {
        let record = makeRecord(
            exerciseID: NativeSitToStandV72AIModule.exerciseID,
            repetitions: [
                correctRep(1),
                correctRep(2),
                correctRep(3),
                incorrectRep(
                    4,
                    signals: [signal(semanticID: "knee_left_right_asymmetry", bodyRegion: "left_knee", severity: "medium")],
                ),
                unavailableRep(5, outcome: .cannotAssess),
                unavailableRep(6, outcome: .incomplete),
            ],
        )

        let score = NativeRuleBasedSessionScorerV13.score(record)

        XCTAssertEqual(score.availability, .available)
        XCTAssertEqual(score.assessableReps, 4)
        XCTAssertEqual(score.cannotAssessReps, 1)
        XCTAssertEqual(score.incompleteReps, 1)
        XCTAssertEqual(score.evidenceCoverageScore, 67)
        XCTAssertEqual(score.formQualityScore, 95)
        XCTAssertEqual(score.consistencyScore, 75)
        XCTAssertEqual(score.overallScore, 91)
    }

    func testEvidenceGateHidesQualityScoresWhenTooFewRepetitionsAreAssessable() {
        let record = makeRecord(
            exerciseID: NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
            repetitions: [
                correctRep(1),
                correctRep(2),
                unavailableRep(3, outcome: .cannotAssess),
                unavailableRep(4, outcome: .cannotAssess),
                unavailableRep(5, outcome: .cannotAssess),
            ],
        )

        let score = NativeRuleBasedSessionScorerV13.score(record)

        XCTAssertEqual(score.availability, .insufficientEvidence)
        XCTAssertEqual(score.evidenceCoverageScore, 40)
        XCTAssertNil(score.formQualityScore)
        XCTAssertNil(score.consistencyScore)
        XCTAssertNil(score.overallScore)
    }

    func testAuthoritativeCompletedRepCountPreventsPartialEvidenceFromInflatingCoverage() {
        let record = makeRecord(
            exerciseID: NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
            repetitions: [correctRep(1), correctRep(2)],
        )

        let score = NativeRuleBasedSessionScorerV13.score(
            record,
            authoritativeCompletedReps: 5,
        )

        XCTAssertEqual(score.totalReps, 5)
        XCTAssertEqual(score.assessableReps, 2)
        XCTAssertEqual(score.cannotAssessReps, 3)
        XCTAssertEqual(score.evidenceCoverageScore, 40)
        XCTAssertEqual(score.availability, .insufficientEvidence)
        XCTAssertNil(score.overallScore)
    }

    func testEmptyEvidenceDoesNotInventAZeroScore() {
        let score = NativeRuleBasedSessionScorerV13.score(
            makeRecord(
                exerciseID: NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
                repetitions: [],
            ),
        )

        XCTAssertEqual(score.availability, .noCompletedRepetitions)
        XCTAssertEqual(score.evidenceCoverageScore, 0)
        XCTAssertNil(score.formQualityScore)
        XCTAssertNil(score.consistencyScore)
        XCTAssertNil(score.overallScore)
    }

    func testSitToStandBreakdownGroupsAndOrdersApprovedCategories() {
        let record = makeRecord(
            exerciseID: NativeSitToStandV72AIModule.exerciseID,
            repetitions: [
                incorrectRep(
                    1,
                    signals: [
                        signal(semanticID: "trunk_view_plane_tilt", bodyRegion: "trunk", severity: "medium"),
                        signal(semanticID: "trunk_lateral_offset", bodyRegion: "trunk", severity: "high"),
                        signal(semanticID: "foot_base_offset", bodyRegion: "left_foot", severity: "low"),
                    ],
                ),
                incorrectRep(
                    2,
                    signals: [
                        signal(semanticID: "trunk_view_plane_tilt", bodyRegion: "trunk", severity: "medium"),
                        signal(semanticID: "knee_left_right_asymmetry", bodyRegion: "left_knee", severity: "medium"),
                    ],
                ),
                correctRep(3),
            ],
        )

        let score = NativeRuleBasedSessionScorerV13.score(record)

        XCTAssertEqual(score.faultBreakdown.map(\.categoryID), [
            "trunk_alignment",
            "knee_symmetry",
            "foot_placement",
        ])
        XCTAssertEqual(score.focusCategoryID, "trunk_alignment")
        XCTAssertEqual(score.faultBreakdown.first?.flaggedRepCount, 2)
        XCTAssertEqual(score.faultBreakdown.first?.strongestSeverity, "high")
        XCTAssertEqual(
            score.faultBreakdown.first?.semanticIDs,
            ["trunk_lateral_offset", "trunk_view_plane_tilt"],
        )
    }

    @MainActor
    func testFinishPracticeMapsApprovedAggregatesIntoExistingSessionSummary() throws {
        let record = makeRecord(
            exerciseID: NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
            repetitions: [
                incorrectRep(
                    1,
                    signals: [signal(semanticID: "incomplete_visible_finger_wrap", bodyRegion: "left_hand", severity: "medium")],
                ),
                correctRep(2),
                correctRep(3),
            ],
        )
        let evidence = try JSONEncoder().encode(record)
        let app = NativeAppModel()
        app.openPlanItem(NativePlanItem(exerciseId: record.exerciseID, reps: 3, sets: 1))

        app.finishPractice(
            cuesPresented: 0,
            startedAt: Date().addingTimeInterval(-1),
            completedReps: 3,
            ruleBasedEvidenceJSON: evidence,
        )

        let summary = try XCTUnwrap(app.latestSummary)
        XCTAssertEqual(summary.overallScore, 88)
        XCTAssertEqual(summary.poseScore, 93)
        XCTAssertNil(summary.motionScore)
        XCTAssertEqual(summary.invalidReps, 1)
        XCTAssertEqual(summary.ruleBasedScore?.consistencyScore, 67)
        XCTAssertEqual(summary.ruleBasedScore?.evidenceCoverageScore, 100)
    }

    func testV8013SummaryUsesOnlyImplementedRuleScoreMetrics() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("PhysioAINative/NativeSummaryView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("Form Quality"))
        XCTAssertTrue(source.contains("Consistency"))
        XCTAssertTrue(source.contains("Evidence Coverage"))
        XCTAssertTrue(source.contains("faultBreakdown"))
        XCTAssertTrue(source.contains("focusMessage"))
        XCTAssertFalse(source.contains("Motion quality"))
        XCTAssertFalse(source.contains("Smoothness"))
    }

    private func makeRecord(
        exerciseID: String,
        repetitions: [RuleBasedRepetitionResult],
    ) -> RuleBasedSessionRecord {
        let incorrect = repetitions.filter { $0.outcome == .incorrect }
        return RuleBasedSessionRecord(
            schema: exerciseID == NativeSitToStandV72AIModule.exerciseID
                ? NativeSitToStandRuleBasedEvidenceV12Module.schema
                : RuleBasedSessionRecorder.schema,
            moduleID: "score_test",
            moduleVersion: "test",
            exerciseID: exerciseID,
            trackingProfile: exerciseID == NativeSitToStandV72AIModule.exerciseID ? "pose_only" : "pose_plus_hand",
            anatomicalSide: exerciseID == NativeSitToStandV72AIModule.exerciseID ? "bilateral" : "left",
            decisionScope: "experimental_rule_test",
            summary: RuleBasedSessionSummary(
                totalReps: repetitions.count,
                correctRepCount: repetitions.filter { $0.outcome == .correct }.count,
                incorrectRepCount: incorrect.count,
                cannotAssessRepCount: repetitions.filter { $0.outcome == .cannotAssess }.count,
                incompleteRepCount: repetitions.filter { $0.outcome == .incomplete }.count,
                wrongByBodyRegion: [:],
                wrongBySeverity: [:],
            ),
            repetitions: repetitions,
            claimBoundary: RuleBasedClaimBoundary(),
        )
    }

    private func correctRep(_ index: Int) -> RuleBasedRepetitionResult {
        repetition(index, outcome: .correct, signals: [])
    }

    private func incorrectRep(
        _ index: Int,
        signals: [QualifiedSignal],
    ) -> RuleBasedRepetitionResult {
        repetition(index, outcome: .incorrect, signals: signals)
    }

    private func unavailableRep(
        _ index: Int,
        outcome: RuleBasedRepetitionOutcome,
    ) -> RuleBasedRepetitionResult {
        repetition(index, outcome: outcome, signals: [])
    }

    private func repetition(
        _ index: Int,
        outcome: RuleBasedRepetitionOutcome,
        signals: [QualifiedSignal],
    ) -> RuleBasedRepetitionResult {
        RuleBasedRepetitionResult(
            id: "rep_\(index)",
            repIndex: index,
            outcome: outcome,
            faultTags: Array(Set(signals.map(\.semanticID))).sorted(),
            bodyRegions: Array(Set(signals.map(\.bodyRegion))).sorted(),
            severity: signals.max { severityRank($0.severity) < severityRank($1.severity) }?.severity,
            assessableFrameCount: outcome == .correct || outcome == .incorrect ? 10 : 0,
            skippedFrameCount: outcome == .correct || outcome == .incorrect ? 0 : 10,
            skippedReasonCounts: outcome == .correct || outcome == .incorrect ? [:] : ["cannot_assess": 10],
            faultSignals: signals,
        )
    }

    private func signal(
        semanticID: String,
        bodyRegion: String,
        severity: String,
    ) -> QualifiedSignal {
        QualifiedSignal(
            kind: .faultObservation,
            semanticID: semanticID,
            bodyRegion: bodyRegion,
            landmarkRefs: [],
            metric: DerivedMetric(name: "test", value: 1, unit: "test"),
            severity: severity,
            confidence: 1,
            sourceEngine: "score_test",
        )
    }

    private func severityRank(_ value: String) -> Int {
        switch value.lowercased() {
        case "high": return 3
        case "medium": return 2
        case "low": return 1
        default: return 0
        }
    }
}
