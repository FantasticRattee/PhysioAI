import Foundation
import XCTest
@testable import PhysioAIFaultEvidenceKit

final class FaultEvidenceRecorderTests: XCTestCase {
    func testRecordIdentifiesPortableV8ContractRevision() {
        let record = FaultEvidenceRecorder().currentRecord()
        XCTAssertEqual(record.schema, "physioai.native.fault_evidence.v1")
        XCTAssertEqual(record.moduleID, "native_fault_evidence_v8_local")
        XCTAssertEqual(record.moduleVersion, "0.2.0-dev")
    }

    func testContiguousQualifiedSignalsAggregateIntoOneCommentEvent() throws {
        let recorder = FaultEvidenceRecorder()
        let signal = QualifiedSignal(
            semanticID: "finger_wrap_incomplete",
            bodyRegion: "left_hand",
            landmarkRefs: ["hand_5", "hand_20"],
            metric: DerivedMetric(name: "rule_wrap_policy_qualified", value: 1, unit: "boolean"),
            severity: "cue",
            confidence: 0.75,
            sourceEngine: "experimental_rule_wrap_policy_subset_native",
        )

        recorder.ingest(frame: frame(1_000, reps: 1), signal: signal)
        recorder.ingest(frame: frame(1_067, reps: 1), signal: signal)
        recorder.ingest(frame: frame(1_134, reps: 1), signal: signal)
        recorder.ingest(frame: frame(1_201, reps: 1))

        let record = recorder.currentRecord()
        XCTAssertEqual(record.commentObservations.count, 1)
        XCTAssertEqual(record.commentObservations[0].observationCount, 3)
        XCTAssertEqual(record.commentObservations[0].firstObservedAtMs, 1_000)
        XCTAssertEqual(record.commentObservations[0].lastObservedAtMs, 1_134)
        XCTAssertEqual(record.commentObservations[0].repIndex, 1)
    }

    func testCurrentSnapshotDoesNotCloseAnActiveEvent() {
        let recorder = FaultEvidenceRecorder()
        recorder.ingest(
            frame: frame(2_000, reps: 2),
            signal: makeSignal(),
        )

        let live = recorder.currentRecord()
        XCTAssertEqual(live.commentObservations.count, 1)
        XCTAssertEqual(live.commentObservations[0].observationCount, 1)

        recorder.ingest(frame: frame(2_067, reps: 2), signal: makeSignal())
        let updated = recorder.currentRecord()
        XCTAssertEqual(updated.commentObservations.count, 1)
        XCTAssertEqual(updated.commentObservations[0].observationCount, 2)

        let final = recorder.finalizedRecord()
        XCTAssertEqual(final.commentObservations.count, 1)
        XCTAssertEqual(final.commentObservations[0].observationCount, 2)
    }

    func testDelayedSignalEvaluationDoesNotDoubleCountFrameOrPrematurelyCloseEvent() {
        let recorder = FaultEvidenceRecorder()
        let first = frame(2_500, reps: 1)
        let second = frame(2_567, reps: 1)
        let third = frame(2_634, reps: 1)

        recorder.ingestFrame(first)
        XCTAssertEqual(recorder.currentRecord().coverage.observedFrames, 1)

        // Simulates a frame callback followed by a later engine callback.
        recorder.ingestSignals(for: first, signals: [makeSignal()])
        let duringDelayedCallback = recorder.currentRecord()
        XCTAssertEqual(duringDelayedCallback.coverage.observedFrames, 1)
        XCTAssertEqual(duringDelayedCallback.commentObservations.count, 1)

        recorder.ingestFrame(second)
        recorder.ingestSignals(for: second, signals: [makeSignal()])
        recorder.finishSignalEvaluation(for: second)
        recorder.ingestFrame(third)
        recorder.finishSignalEvaluation(for: third)

        let record = recorder.currentRecord()
        XCTAssertEqual(record.coverage.observedFrames, 3)
        XCTAssertEqual(record.commentObservations.count, 1)
        XCTAssertEqual(record.commentObservations[0].observationCount, 2)
        XCTAssertEqual(record.commentObservations[0].lastObservedAtMs, second.timestampMs)
    }

    func testSkippedFramesAreCoverageAndDoNotBecomeFaults() {
        let recorder = FaultEvidenceRecorder()
        recorder.ingest(
            frame: FrameInput(
                timestampMs: 3_000,
                sourceGeneration: 1,
                captureQC: "cannot_assess_missing_left_hand",
                setupReason: "missing_left_hand",
                totalReps: 0,
            ),
            signal: makeSignal(),
        )

        let record = recorder.currentRecord()
        XCTAssertEqual(record.coverage.observedFrames, 1)
        XCTAssertEqual(record.coverage.assessableFrames, 0)
        XCTAssertEqual(record.coverage.skippedFrames, 1)
        XCTAssertEqual(record.coverage.skippedReasonCounts["missing_left_hand"], 1)
        XCTAssertTrue(record.faultObservations.isEmpty)
        XCTAssertTrue(record.commentObservations.isEmpty)
    }

    func testRepetitionSummaryTracksDistinctCommentFlaggedRepsAndLeavesCorrectnessNull() throws {
        let recorder = FaultEvidenceRecorder()
        recorder.ingest(frame: frame(4_000, reps: 1), signal: makeSignal())
        recorder.ingest(frame: frame(4_067, reps: 1))
        recorder.ingest(frame: frame(4_134, reps: 2), signal: makeSignal())
        recorder.ingest(frame: frame(4_201, reps: 3))

        let data = try recorder.encodedCurrentRecord()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let summary = try XCTUnwrap(json["repetitionSummary"] as? [String: Any])
        XCTAssertEqual(summary["totalReps"] as? Int, 3)
        XCTAssertEqual(summary["commentFlaggedRepIndexes"] as? [Int], [1, 2])
        XCTAssertEqual(summary["commentFlaggedRepCount"] as? Int, 2)
        XCTAssertTrue(summary["correctRepCount"] is NSNull)
        XCTAssertTrue(summary["incorrectRepCount"] is NSNull)
        XCTAssertEqual(summary["correctnessStatus"] as? String, "unavailable_no_fault_engine")
    }

    func testCompletedAssessableRepetitionWithoutFaultIsSummarizedAsCorrect() {
        let recorder = RuleBasedSessionRecorder()
        let result = try! recorder.recordCompletedRepetition(
            RuleBasedRepetitionInput(
                repIndex: 1,
                assessableFrameCount: 5,
                skippedFrameCount: 0,
                faultSignals: [],
            ),
        )

        XCTAssertEqual(result.outcome, .correct)
        let summary = recorder.currentRecord().summary
        XCTAssertEqual(summary.totalReps, 1)
        XCTAssertEqual(summary.correctRepCount, 1)
        XCTAssertEqual(summary.incorrectRepCount, 0)
        XCTAssertEqual(summary.cannotAssessRepCount, 0)
    }

    func testQualifiedFaultBeforeCounterCompletionIsSummarizedAsIncorrect() {
        let recorder = RuleBasedSessionRecorder()
        let fault = QualifiedSignal(
            kind: .faultObservation,
            semanticID: "incomplete_visible_finger_wrap",
            bodyRegion: "left_hand",
            landmarkRefs: ["hand_5", "hand_20"],
            metric: DerivedMetric(name: "rule_wrap_policy_qualified", value: 1, unit: "boolean"),
            severity: "medium",
            confidence: 0.75,
            sourceEngine: "experimental_rule_wrap_policy_subset_native",
        )
        let result = try! recorder.recordCompletedRepetition(
            RuleBasedRepetitionInput(
                repIndex: 1,
                assessableFrameCount: 5,
                skippedFrameCount: 0,
                faultSignals: [fault],
            ),
        )

        let record = recorder.currentRecord()
        XCTAssertEqual(result.outcome, .incorrect)
        XCTAssertEqual(record.summary.incorrectRepCount, 1)
        XCTAssertEqual(record.summary.correctRepCount, 0)
        XCTAssertEqual(result.faultSignals.first?.bodyRegion, "left_hand")
        XCTAssertEqual(result.faultSignals.first?.severity, "medium")
    }

    func testEncodedRuleSessionKeepsNullSeverityForACorrectRep() throws {
        let recorder = RuleBasedSessionRecorder()
        _ = try recorder.recordCompletedRepetition(
            RuleBasedRepetitionInput(
                repIndex: 1,
                assessableFrameCount: 5,
                skippedFrameCount: 0,
                faultSignals: [],
            ),
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: recorder.encodedCurrentRecord()) as? [String: Any],
        )
        let repetitions = try XCTUnwrap(object["repetitions"] as? [[String: Any]])
        XCTAssertTrue(repetitions[0]["severity"] is NSNull)
    }

    func testInsufficientCoverageIsCannotAssessNotIncorrect() throws {
        let recorder = RuleBasedSessionRecorder()
        let fault = QualifiedSignal(
            kind: .faultObservation,
            semanticID: "incomplete_visible_finger_wrap",
            bodyRegion: "left_hand",
            landmarkRefs: ["hand_5"],
            metric: DerivedMetric(name: "rule_wrap_policy_qualified", value: 1, unit: "boolean"),
            severity: "medium",
            confidence: 0.75,
            sourceEngine: "experimental_rule_wrap_policy_subset_native",
        )
        let result = try recorder.recordCompletedRepetition(
            RuleBasedRepetitionInput(
                repIndex: 1,
                assessableFrameCount: 4,
                skippedFrameCount: 2,
                skippedReasonCounts: ["missing_hand": 2],
                faultSignals: [fault],
            ),
        )

        XCTAssertEqual(result.outcome, .cannotAssess)
        XCTAssertEqual(recorder.currentRecord().summary.incorrectRepCount, 0)
        XCTAssertEqual(recorder.currentRecord().summary.cannotAssessRepCount, 1)
    }

    func testNonContiguousRepIndexIsRejected() throws {
        let recorder = RuleBasedSessionRecorder()
        XCTAssertThrowsError(
            try recorder.recordCompletedRepetition(
                RuleBasedRepetitionInput(
                    repIndex: 2,
                    assessableFrameCount: 5,
                    skippedFrameCount: 0,
                    faultSignals: [],
                ),
            ),
        ) { error in
            XCTAssertEqual(
                error as? RuleBasedSessionRecorderError,
                .nonContiguousRepIndex(expected: 1, actual: 2),
            )
        }
    }

    func testSourceGenerationSplitsEventsAndHighestRepTotalWins() {
        let recorder = FaultEvidenceRecorder()
        recorder.ingest(frame: frame(5_000, generation: 1, reps: 4), signal: makeSignal())
        recorder.ingest(frame: frame(5_067, generation: 2, reps: 1), signal: makeSignal())
        let record = recorder.currentRecord()

        XCTAssertEqual(record.commentObservations.count, 2)
        XCTAssertEqual(record.commentObservations.map(\.sourceGeneration), [1, 2])
        XCTAssertEqual(record.repetitionSummary.totalReps, 4)
    }

    func testFinalizingMultipleActiveSignalsKeepsEveryObservation() {
        let recorder = FaultEvidenceRecorder()
        let first = makeSignal()
        let second = QualifiedSignal(
            semanticID: "hand_reach_quality",
            bodyRegion: "left_hand",
            landmarkRefs: ["hand_0"],
            metric: DerivedMetric(name: "host_quality_signal", value: 1, unit: "boolean"),
            severity: "cue",
            confidence: 0.5,
            sourceEngine: "host_quality_preview",
        )
        recorder.ingest(frame: frame(5_500, reps: 1), signals: [first, second])

        let final = recorder.finalizedRecord()
        XCTAssertEqual(final.commentObservations.count, 2)
        XCTAssertEqual(final.commentObservations.map(\.semanticID).sorted(), [
            "finger_wrap_incomplete",
            "hand_reach_quality",
        ])
    }

    func testEncodedRecordHasNoRawMediaOrLandmarkCoordinates() throws {
        let recorder = FaultEvidenceRecorder()
        recorder.ingest(frame: frame(6_000, reps: 1), signal: makeSignal())
        let json = String(decoding: try recorder.encodedCurrentRecord(), as: UTF8.self)

        XCTAssertTrue(json.contains("physioai.native.fault_evidence.v1"))
        XCTAssertTrue(json.contains("finger_wrap_incomplete"))
        XCTAssertFalse(json.contains("CMSampleBuffer"))
        XCTAssertFalse(json.contains("rawFrame"))
        XCTAssertFalse(json.contains("\"x\""))
        XCTAssertFalse(json.contains("\"y\""))
        XCTAssertFalse(json.contains("\"z\""))
    }

    func testMachineReadableSchemaIsBundledWithThePackage() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "fault-evidence.schema", withExtension: "json"),
        )
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
        )
        XCTAssertEqual(schema["$id"] as? String, "https://physioai.local/schemas/native-fault-evidence-v1.json")
        XCTAssertEqual(schema["title"] as? String, "PhysioAI Native Fault Evidence Record")
    }

    func testRuleBasedSessionSchemaIsBundledWithThePackage() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "rule-based-session.schema", withExtension: "json"),
        )
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
        )
        XCTAssertEqual(
            schema["$id"] as? String,
            "https://physioai.local/schemas/rule-based-bottle-grab-session-v1.json",
        )
        XCTAssertEqual(schema["title"] as? String, "PhysioAI Rule-Based Bottle Grab Session")
    }

    func testSitToStandRuleBasedSessionSchemaIsBundledForAdapterReaders() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "sit-to-stand-rule-based-session.schema", withExtension: "json"),
        )
        let schema = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
        )
        XCTAssertEqual(
            schema["$id"] as? String,
            "https://physioai.local/schemas/rule-based-sit-to-stand-session-v1.json",
        )
        XCTAssertEqual(schema["title"] as? String, "PhysioAI Rule-Based Sit-to-Stand Session")
    }

    private func makeSignal() -> QualifiedSignal {
        QualifiedSignal(
            semanticID: "finger_wrap_incomplete",
            bodyRegion: "left_hand",
            landmarkRefs: ["hand_5", "hand_20"],
            metric: DerivedMetric(name: "rule_wrap_policy_qualified", value: 1, unit: "boolean"),
            severity: "cue",
            confidence: 0.75,
            sourceEngine: "experimental_rule_wrap_policy_subset_native",
        )
    }

    private func frame(
        _ timestampMs: Int,
        generation: Int = 1,
        reps: Int,
    ) -> FrameInput {
        FrameInput(
            timestampMs: timestampMs,
            sourceGeneration: generation,
            captureQC: "can_assess",
            totalReps: reps,
        )
    }
}
