import Foundation
import PhysioAIFaultEvidenceKit

/// Copy this adapter shape into a host app after it has produced its own
/// derived camera/counter/comment values. This package intentionally does not
/// receive an image, a MediaPipe result, or a patient identifier.
final class BottleGrabEvidenceHostAdapter {
    private let recorder = FaultEvidenceRecorder(exerciseID: "bottle_grab")
    private let ruleSession = RuleBasedSessionRecorder(exerciseID: "bottle_grab")

    func ingestCounterFrame(
        timestampMs: Int,
        sourceGeneration: Int,
        captureQC: String,
        setupReason: String?,
        totalReps: Int,
    ) {
        recorder.ingestFrame(
            FrameInput(
                timestampMs: timestampMs,
                sourceGeneration: sourceGeneration,
                captureQC: captureQC,
                setupReason: setupReason,
                totalReps: totalReps,
            ),
        )
    }

    /// Call only after every signal producer for this timestamp has returned.
    /// Passing no signal intentionally closes a previously active occurrence.
    func finishHandCommentEvaluation(
        timestampMs: Int,
        sourceGeneration: Int,
        captureQC: String,
        setupReason: String?,
        totalReps: Int,
        fingerWrapQualified: Bool,
    ) {
        let frame = FrameInput(
            timestampMs: timestampMs,
            sourceGeneration: sourceGeneration,
            captureQC: captureQC,
            setupReason: setupReason,
            totalReps: totalReps,
        )
        let signals: [QualifiedSignal] = fingerWrapQualified
            ? [
                QualifiedSignal(
                    kind: .commentObservation,
                    semanticID: "finger_wrap_incomplete",
                    bodyRegion: "left_hand",
                    landmarkRefs: (5...20).map { "hand_\($0)" },
                    metric: DerivedMetric(
                        name: "rule_wrap_policy_qualified",
                        value: 1,
                        unit: "boolean",
                    ),
                    severity: "cue",
                    confidence: 0.75,
                    sourceEngine: "host_rule_wrap_policy",
                ),
            ]
            : []

        recorder.ingestSignals(for: frame, signals: signals)
        recorder.finishSignalEvaluation(for: frame)
    }

    /// Safe to inspect repeatedly while the exercise is active.
    func currentJSON() throws -> Data {
        try recorder.encodedCurrentRecord()
    }

    /// Call once when the host deliberately ends the exercise/session.
    func finalizedJSON() throws -> Data {
        try recorder.encodedFinalizedRecord()
    }

    /// Call once only after this host's own counter has completed the
    /// repetition. The host must not pass raw landmarks or labels here.
    func recordCompletedRuleBasedRep(
        repIndex: Int,
        assessableFrameCount: Int,
        skippedFrameCount: Int,
        fingerWrapQualified: Bool,
    ) throws {
        let signals: [QualifiedSignal] = fingerWrapQualified
            ? [
                QualifiedSignal(
                    kind: .faultObservation,
                    semanticID: "incomplete_visible_finger_wrap",
                    bodyRegion: "left_hand",
                    landmarkRefs: (5...20).map { "hand_\($0)" },
                    metric: DerivedMetric(
                        name: "rule_wrap_policy_qualified",
                        value: 1,
                        unit: "boolean",
                    ),
                    severity: "medium",
                    confidence: 0.75,
                    sourceEngine: "host_rule_wrap_policy",
                ),
            ]
            : []
        try ruleSession.recordCompletedRepetition(
            RuleBasedRepetitionInput(
                repIndex: repIndex,
                assessableFrameCount: assessableFrameCount,
                skippedFrameCount: skippedFrameCount,
                faultSignals: signals,
            ),
        )
    }

    func currentRuleBasedJSON() throws -> Data {
        try ruleSession.encodedCurrentRecord()
    }
}
