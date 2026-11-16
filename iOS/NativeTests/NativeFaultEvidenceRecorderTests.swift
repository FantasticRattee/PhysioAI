import XCTest
@testable import PhysioAINative

final class NativeFaultEvidenceRecorderTests: XCTestCase {
    func testQualifiedRuleWrapFramesBecomeOneCommentObservation() {
        let recorder = NativeFaultEvidenceRecorder()

        for timestamp in [1_000, 1_067, 1_134] {
            let snapshot = makeSnapshot(timestampMs: timestamp, sourceGeneration: 1)
            recorder.ingestOutput(snapshot: snapshot, output: makeOutput())
            recorder.ingestHandComment(snapshot: snapshot, cue: .fingerWrap)
        }
        let cleared = makeSnapshot(timestampMs: 1_201, sourceGeneration: 1)
        recorder.ingestOutput(snapshot: cleared, output: makeOutput())
        recorder.ingestHandComment(snapshot: cleared, cue: nil)

        let record = recorder.localRecord()
        XCTAssertEqual(record.faultObservations.count, 0)
        XCTAssertEqual(record.commentObservations.count, 1)
        guard let event = record.commentObservations.first else { return }
        XCTAssertEqual(event.semanticID, "finger_wrap_incomplete")
        XCTAssertEqual(event.bodyRegion, "left_hand")
        XCTAssertEqual(event.observationCount, 3)
        XCTAssertEqual(event.firstObservedAtMs, 1_000)
        XCTAssertEqual(event.lastObservedAtMs, 1_134)
        XCTAssertEqual(event.repIndex, 2)
        XCTAssertEqual(record.coverage.observedFrames, 4)
    }

    func testCannotAssessIsCoverageNotAFault() {
        let recorder = NativeFaultEvidenceRecorder()
        let snapshot = makeSnapshot(timestampMs: 2_000, sourceGeneration: 1)
        recorder.ingestOutput(
            snapshot: snapshot,
            output: makeOutput(
                captureQC: "cannot_assess_missing_left_hand",
                setupReason: "missing_left_hand",
            ),
        )

        let record = recorder.localRecord()
        XCTAssertEqual(record.coverage.observedFrames, 1)
        XCTAssertEqual(record.coverage.assessableFrames, 0)
        XCTAssertEqual(record.coverage.skippedFrames, 1)
        XCTAssertEqual(record.coverage.skippedReasonCounts["missing_left_hand"], 1)
        XCTAssertTrue(record.faultObservations.isEmpty)
        XCTAssertTrue(record.commentObservations.isEmpty)
    }

    func testSourceGenerationChangeSplitsCommentOccurrences() {
        let recorder = NativeFaultEvidenceRecorder()
        let sourceOne = makeSnapshot(timestampMs: 3_000, sourceGeneration: 1)
        recorder.ingestOutput(snapshot: sourceOne, output: makeOutput())
        recorder.ingestHandComment(snapshot: sourceOne, cue: .fingerWrap)

        let sourceTwo = makeSnapshot(timestampMs: 3_067, sourceGeneration: 2)
        recorder.ingestOutput(snapshot: sourceTwo, output: makeOutput())
        recorder.ingestHandComment(snapshot: sourceTwo, cue: .fingerWrap)
        recorder.ingestHandComment(
            snapshot: makeSnapshot(timestampMs: 3_134, sourceGeneration: 2),
            cue: nil,
        )

        let record = recorder.localRecord()
        XCTAssertEqual(record.commentObservations.count, 2)
        XCTAssertEqual(record.commentObservations.map(\.sourceGeneration), [1, 2])
        XCTAssertEqual(record.commentObservations.map(\.observationCount), [1, 1])
    }

    func testEncodedRecordContainsOnlyDerivedEvidenceFields() throws {
        let recorder = NativeFaultEvidenceRecorder()
        let snapshot = makeSnapshot(timestampMs: 4_000, sourceGeneration: 1)
        recorder.ingestOutput(snapshot: snapshot, output: makeOutput())
        recorder.ingestHandComment(snapshot: snapshot, cue: .fingerWrap)
        recorder.ingestHandComment(
            snapshot: makeSnapshot(timestampMs: 4_067, sourceGeneration: 1),
            cue: nil,
        )

        let json = try String(decoding: recorder.encodedLocalRecord(), as: UTF8.self)
        XCTAssertTrue(json.contains("physioai.native.fault_evidence.v1"))
        XCTAssertTrue(json.contains("finger_wrap_incomplete"))
        XCTAssertFalse(json.contains("\"pose\""))
        XCTAssertFalse(json.contains("\"hand\""))
        XCTAssertFalse(json.contains("CMSampleBuffer"))
        XCTAssertFalse(json.contains("rawFrame"))
    }

    func testEncodedRecordIncludesPortableRepetitionSummaryWithoutInventingCorrectness() throws {
        let recorder = NativeFaultEvidenceRecorder()
        let first = makeSnapshot(timestampMs: 5_000, sourceGeneration: 1)
        recorder.ingestOutput(snapshot: first, output: makeOutput(totalReps: 1))
        recorder.ingestHandComment(snapshot: first, cue: .fingerWrap)
        recorder.ingestHandComment(
            snapshot: makeSnapshot(timestampMs: 5_067, sourceGeneration: 1),
            cue: nil,
        )
        recorder.ingestOutput(
            snapshot: makeSnapshot(timestampMs: 5_134, sourceGeneration: 1),
            output: makeOutput(totalReps: 3),
        )

        let data = try recorder.encodedLocalRecord()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
        )
        let summary = try XCTUnwrap(json["repetitionSummary"] as? [String: Any])

        XCTAssertEqual(summary["totalReps"] as? Int, 3)
        XCTAssertEqual(summary["commentFlaggedRepIndexes"] as? [Int], [1])
        XCTAssertEqual(summary["commentFlaggedRepCount"] as? Int, 1)
        XCTAssertTrue(summary["correctRepCount"] is NSNull)
        XCTAssertTrue(summary["incorrectRepCount"] is NSNull)
        XCTAssertEqual(
            summary["correctnessStatus"] as? String,
            "unavailable_no_fault_engine",
        )
    }

    func testRepetitionSummaryKeepsHighestCounterTotalAcrossLaterLowerValue() throws {
        let recorder = NativeFaultEvidenceRecorder()
        recorder.ingestOutput(
            snapshot: makeSnapshot(timestampMs: 6_000, sourceGeneration: 1),
            output: makeOutput(totalReps: 4),
        )
        recorder.ingestOutput(
            snapshot: makeSnapshot(timestampMs: 6_067, sourceGeneration: 2),
            output: makeOutput(totalReps: 1),
        )

        let data = try recorder.encodedLocalRecord()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
        )
        let summary = try XCTUnwrap(json["repetitionSummary"] as? [String: Any])
        XCTAssertEqual(summary["totalReps"] as? Int, 4)
    }

    func testCurrentRecordDoesNotFinalizeAContinuingRuleWrapComment() {
        let recorder = NativeFaultEvidenceRecorder()
        let first = makeSnapshot(timestampMs: 7_000, sourceGeneration: 1)
        let second = makeSnapshot(timestampMs: 7_067, sourceGeneration: 1)

        recorder.ingestOutput(snapshot: first, output: makeOutput(totalReps: 2))
        recorder.ingestHandComment(snapshot: first, cue: .fingerWrap)
        XCTAssertEqual(recorder.currentRecord().commentObservations.first?.observationCount, 1)

        recorder.ingestOutput(snapshot: second, output: makeOutput(totalReps: 2))
        recorder.ingestHandComment(snapshot: second, cue: .fingerWrap)

        let live = recorder.currentRecord()
        XCTAssertEqual(live.commentObservations.count, 1)
        XCTAssertEqual(live.commentObservations.first?.observationCount, 2)
        XCTAssertEqual(recorder.localRecord().commentObservations.first?.observationCount, 2)
    }

    func testRuleBasedSessionFinalizesAQualifiedFaultWhenCounterCompletesRep() {
        let recorder = NativeRuleBasedSessionV8Module()
        for (index, timestamp) in [9_000, 9_067, 9_134, 9_201, 9_268].enumerated() {
            let snapshot = makeSnapshot(timestampMs: timestamp, sourceGeneration: 1)
            let total = index == 4 ? 1 : 0
            recorder.ingestOutput(snapshot: snapshot, output: makeOutput(totalReps: total))
            recorder.ingestHandComment(snapshot: snapshot, cue: .fingerWrap)
        }

        let record = recorder.currentRecord()
        XCTAssertEqual(record.summary.totalReps, 1)
        XCTAssertEqual(record.summary.incorrectRepCount, 1)
        XCTAssertEqual(record.summary.correctRepCount, 0)
        XCTAssertEqual(record.repetitions.first?.outcome, .incorrect)
        XCTAssertEqual(record.repetitions.first?.bodyRegions, ["left_hand"])
        XCTAssertEqual(record.repetitions.first?.severity, "medium")
    }

    func testRuleBasedSessionAppendsCompletedRepetitionsAfterSourceGenerationResetsCounter() {
        let recorder = NativeRuleBasedSessionV8Module()

        for (index, timestamp) in [10_000, 10_067, 10_134, 10_201, 10_268].enumerated() {
            let snapshot = makeSnapshot(timestampMs: timestamp, sourceGeneration: 1)
            recorder.ingestOutput(
                snapshot: snapshot,
                output: makeOutput(totalReps: index == 4 ? 1 : 0),
            )
            recorder.ingestHandComment(snapshot: snapshot, cue: nil)
        }

        recorder.resetForNewCaptureSource()

        for (index, timestamp) in [11_000, 11_067, 11_134, 11_201, 11_268].enumerated() {
            let snapshot = makeSnapshot(timestampMs: timestamp, sourceGeneration: 2)
            recorder.ingestOutput(
                snapshot: snapshot,
                output: makeOutput(totalReps: index == 4 ? 1 : 0),
            )
            recorder.ingestHandComment(snapshot: snapshot, cue: nil)
        }

        let record = recorder.currentRecord()
        XCTAssertEqual(record.summary.totalReps, 2)
        XCTAssertEqual(record.summary.correctRepCount, 2)
        XCTAssertEqual(record.repetitions.map(\.repIndex), [1, 2])
    }

    func testFinalizedRuleBasedSessionFlushesAPendingCounterFrameWithoutInventingAFault() throws {
        let recorder = NativeRuleBasedSessionV8Module()
        let snapshot = makeSnapshot(timestampMs: 12_000, sourceGeneration: 1)

        // This models the final counter callback arriving before the paired
        // Hand callback. Auto-finish must retain the counter-owned repetition
        // total while treating the unavailable cue as no qualified fault.
        recorder.ingestOutput(snapshot: snapshot, output: makeOutput(totalReps: 1))

        let data = try recorder.encodedFinalizedCurrentRecord()
        let record = try JSONDecoder().decode(NativeRuleBasedSessionRecord.self, from: data)
        XCTAssertEqual(record.summary.totalReps, 1)
        XCTAssertEqual(record.repetitions.count, 1)
        XCTAssertNotEqual(record.repetitions.first?.outcome, .incorrect)
        XCTAssertTrue(record.repetitions.first?.faultTags.isEmpty ?? false)
    }

    private func makeSnapshot(timestampMs: Int, sourceGeneration: Int) -> NativeFrameSnapshot {
        let fixture = NativeFixtureProvider.fullBodySnapshot(frame: 1)
        return NativeFrameSnapshot(
            timestampMs: timestampMs,
            sourceGeneration: sourceGeneration,
            inputIsMirrored: false,
            pose: fixture.pose,
            hand: fixture.hand,
            handSide: "left",
            handSideSource: "fixture",
            handScore: 0.9,
            detectorLatencyMs: 4,
        )
    }

    private func makeOutput(
        captureQC: String = "can_assess",
        setupReason: String? = nil,
        totalReps: Int = 2,
    ) -> NativeBottleGrabOutput {
        NativeBottleGrabOutput(
            phase: nil,
            captureQC: captureQC,
            cue: nil,
            cueThai: nil,
            bufferedFrames: 0,
            assessableFrames: 0,
            posePoints: 33,
            handPoints: 21,
            handSide: "left",
            detectorLatencyMs: 4,
            modelStatus: "fixture",
            setupReason: setupReason,
            totalReps: totalReps,
        )
    }
}
