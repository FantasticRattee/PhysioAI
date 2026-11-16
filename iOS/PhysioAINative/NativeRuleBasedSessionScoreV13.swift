import Foundation

enum NativeRuleSessionScoreAvailability: String, Equatable, Sendable {
    case available
    case insufficientEvidence = "insufficient_evidence"
    case noCompletedRepetitions = "no_completed_repetitions"
}

struct NativeRuleSessionFaultBreakdown: Equatable, Identifiable, Sendable {
    let categoryID: String
    let flaggedRepCount: Int
    let strongestSeverity: String
    let semanticIDs: [String]

    var id: String { categoryID }
}

/// Experimental, derived-only session score. Values are intended for
/// same-exercise feedback under this exact rule set, not clinical comparison.
struct NativeRuleBasedSessionScoreV13: Equatable, Sendable {
    static let scorerVersion = "1.0.0"

    let availability: NativeRuleSessionScoreAvailability
    let totalReps: Int
    let assessableReps: Int
    let correctReps: Int
    let flaggedReps: Int
    let cannotAssessReps: Int
    let incompleteReps: Int
    let overallScore: Int?
    let formQualityScore: Int?
    let consistencyScore: Int?
    let evidenceCoverageScore: Int
    let faultBreakdown: [NativeRuleSessionFaultBreakdown]

    var focusCategoryID: String? { faultBreakdown.first?.categoryID }
}

/// Pure post-session aggregator. It reads completed-repetition evidence and
/// cannot influence Camera, MediaPipe, the exercise engine, counting, or TTS.
enum NativeRuleBasedSessionScorerV13 {
    private static let minimumCoverage = 0.60
    private static let maximumDeductionPerRep = 60
    private static let minimumAssessableRepScore = 40

    private struct CategoryAggregate {
        var repIndexes: Set<Int> = []
        var semanticIDs: Set<String> = []
        var strongestSeverity = "low"
    }

    static func score(
        _ record: RuleBasedSessionRecord,
        authoritativeCompletedReps: Int? = nil,
    ) -> NativeRuleBasedSessionScoreV13 {
        let repetitions = record.repetitions
        let totalReps = max(
            repetitions.count,
            max(0, authoritativeCompletedReps ?? repetitions.count),
        )
        let missingEvidenceReps = max(0, totalReps - repetitions.count)
        let assessable = repetitions.filter {
            $0.outcome == .correct || $0.outcome == .incorrect
        }
        let correctReps = assessable.filter { $0.outcome == .correct }.count
        let incorrect = assessable.filter { $0.outcome == .incorrect }
        let cannotAssessReps = repetitions.filter { $0.outcome == .cannotAssess }.count
            + missingEvidenceReps
        let incompleteReps = repetitions.filter { $0.outcome == .incomplete }.count
        let coverageRatio = totalReps == 0
            ? 0
            : Double(assessable.count) / Double(totalReps)
        let coverageScore = percentage(coverageRatio)
        let breakdown = makeFaultBreakdown(from: incorrect)

        guard totalReps > 0 else {
            return NativeRuleBasedSessionScoreV13(
                availability: .noCompletedRepetitions,
                totalReps: 0,
                assessableReps: 0,
                correctReps: 0,
                flaggedReps: 0,
                cannotAssessReps: 0,
                incompleteReps: 0,
                overallScore: nil,
                formQualityScore: nil,
                consistencyScore: nil,
                evidenceCoverageScore: 0,
                faultBreakdown: [],
            )
        }

        let minimumAssessableReps = min(totalReps, 3)
        guard coverageRatio >= minimumCoverage,
              assessable.count >= minimumAssessableReps else {
            return NativeRuleBasedSessionScoreV13(
                availability: .insufficientEvidence,
                totalReps: totalReps,
                assessableReps: assessable.count,
                correctReps: correctReps,
                flaggedReps: incorrect.count,
                cannotAssessReps: cannotAssessReps,
                incompleteReps: incompleteReps,
                overallScore: nil,
                formQualityScore: nil,
                consistencyScore: nil,
                evidenceCoverageScore: coverageScore,
                faultBreakdown: breakdown,
            )
        }

        let repScores = assessable.map(scoreForAssessableRepetition)
        let formQuality = Int(
            (Double(repScores.reduce(0, +)) / Double(repScores.count)).rounded(),
        )
        let consistency = percentage(Double(correctReps) / Double(assessable.count))
        let overall = Int(
            (Double(formQuality) * 0.80 + Double(consistency) * 0.20).rounded(),
        )

        return NativeRuleBasedSessionScoreV13(
            availability: .available,
            totalReps: totalReps,
            assessableReps: assessable.count,
            correctReps: correctReps,
            flaggedReps: incorrect.count,
            cannotAssessReps: cannotAssessReps,
            incompleteReps: incompleteReps,
            overallScore: overall,
            formQualityScore: formQuality,
            consistencyScore: consistency,
            evidenceCoverageScore: coverageScore,
            faultBreakdown: breakdown,
        )
    }

    private static func scoreForAssessableRepetition(
        _ repetition: RuleBasedRepetitionResult,
    ) -> Int {
        guard repetition.outcome == .incorrect else { return 100 }
        let faults = semanticFaults(in: repetition)
        let totalDeduction = faults.values.map(penalty).reduce(0, +)
        let cappedDeduction = min(maximumDeductionPerRep, totalDeduction)
        return max(minimumAssessableRepScore, 100 - cappedDeduction)
    }

    private static func semanticFaults(
        in repetition: RuleBasedRepetitionResult,
    ) -> [String: String] {
        var faults: [String: String] = [:]
        for signal in repetition.faultSignals where signal.kind == .faultObservation {
            let severity = normalizedSeverity(signal.severity)
            if let current = faults[signal.semanticID] {
                faults[signal.semanticID] = strongerSeverity(current, severity)
            } else {
                faults[signal.semanticID] = severity
            }
        }

        // Retain compatibility with a valid older record that carries tags but
        // not the optional signal details. An incorrect repetition still gets
        // one deterministic medium fallback instead of an invented zero.
        if faults.isEmpty, repetition.outcome == .incorrect {
            let severity = normalizedSeverity(repetition.severity ?? "medium")
            if repetition.faultTags.isEmpty {
                faults["unclassified_fault"] = severity
            } else {
                for semanticID in repetition.faultTags {
                    faults[semanticID] = severity
                }
            }
        }
        return faults
    }

    private static func makeFaultBreakdown(
        from repetitions: [RuleBasedRepetitionResult],
    ) -> [NativeRuleSessionFaultBreakdown] {
        var categories: [String: CategoryAggregate] = [:]

        for repetition in repetitions {
            let semanticFaults = semanticFaults(in: repetition)
            var perRepCategories: [String: (severity: String, semanticIDs: Set<String>)] = [:]
            for (semanticID, severity) in semanticFaults {
                let categoryID = category(for: semanticID)
                var value = perRepCategories[categoryID] ?? ("low", [])
                value.severity = strongerSeverity(value.severity, severity)
                value.semanticIDs.insert(semanticID)
                perRepCategories[categoryID] = value
            }

            for (categoryID, value) in perRepCategories {
                var aggregate = categories[categoryID] ?? CategoryAggregate()
                aggregate.repIndexes.insert(repetition.repIndex)
                aggregate.semanticIDs.formUnion(value.semanticIDs)
                aggregate.strongestSeverity = strongerSeverity(
                    aggregate.strongestSeverity,
                    value.severity,
                )
                categories[categoryID] = aggregate
            }
        }

        return categories.map { categoryID, aggregate in
            NativeRuleSessionFaultBreakdown(
                categoryID: categoryID,
                flaggedRepCount: aggregate.repIndexes.count,
                strongestSeverity: aggregate.strongestSeverity,
                semanticIDs: aggregate.semanticIDs.sorted(),
            )
        }
        .sorted { lhs, rhs in
            let lhsRank = severityRank(lhs.strongestSeverity)
            let rhsRank = severityRank(rhs.strongestSeverity)
            if lhsRank != rhsRank { return lhsRank > rhsRank }
            if lhs.flaggedRepCount != rhs.flaggedRepCount {
                return lhs.flaggedRepCount > rhs.flaggedRepCount
            }
            return lhs.categoryID < rhs.categoryID
        }
    }

    private static func category(for semanticID: String) -> String {
        switch semanticID {
        case "incomplete_visible_finger_wrap":
            return "grip_finger_wrap"
        case "trunk_view_plane_tilt", "trunk_lateral_offset":
            return "trunk_alignment"
        case "hip_left_right_asymmetry":
            return "hip_symmetry"
        case "knee_left_right_asymmetry":
            return "knee_symmetry"
        case "foot_base_offset":
            return "foot_placement"
        default:
            return semanticID
        }
    }

    private static func normalizedSeverity(_ value: String) -> String {
        switch value.lowercased() {
        case "low": return "low"
        case "high": return "high"
        default: return "medium"
        }
    }

    private static func strongerSeverity(_ lhs: String, _ rhs: String) -> String {
        severityRank(rhs) > severityRank(lhs) ? rhs : lhs
    }

    private static func penalty(_ severity: String) -> Int {
        switch normalizedSeverity(severity) {
        case "low": return 10
        case "high": return 35
        default: return 20
        }
    }

    private static func severityRank(_ severity: String) -> Int {
        switch normalizedSeverity(severity) {
        case "low": return 1
        case "high": return 3
        default: return 2
        }
    }

    private static func percentage(_ ratio: Double) -> Int {
        Int((max(0, min(1, ratio)) * 100).rounded())
    }
}
