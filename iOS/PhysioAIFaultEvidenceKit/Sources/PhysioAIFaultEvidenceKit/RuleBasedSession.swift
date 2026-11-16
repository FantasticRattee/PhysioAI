import Foundation

/// Experimental, derived-only outcome for one completed repetition. These
/// values describe a host-qualified rule result, not clinical correctness.
public enum RuleBasedRepetitionOutcome: String, Codable, Equatable, Sendable {
    case correct
    case incorrect
    case cannotAssess = "cannot_assess"
    case incomplete
}

/// Host-owned, completed-repetition input. The host retains responsibility for
/// MediaPipe, Capture-QC admission, and the repetition boundary; this package
/// only evaluates and aggregates already-derived evidence.
public struct RuleBasedRepetitionInput: Codable, Equatable, Sendable {
    public let repIndex: Int
    public let assessableFrameCount: Int
    public let skippedFrameCount: Int
    public let skippedReasonCounts: [String: Int]
    public let faultSignals: [QualifiedSignal]

    public init(
        repIndex: Int,
        assessableFrameCount: Int,
        skippedFrameCount: Int,
        skippedReasonCounts: [String: Int] = [:],
        faultSignals: [QualifiedSignal],
    ) {
        self.repIndex = repIndex
        self.assessableFrameCount = max(0, assessableFrameCount)
        self.skippedFrameCount = max(0, skippedFrameCount)
        self.skippedReasonCounts = skippedReasonCounts.reduce(into: [:]) { partial, pair in
            partial[pair.key] = max(0, pair.value)
        }
        self.faultSignals = faultSignals
    }
}

public struct RuleBasedRepetitionResult: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let repIndex: Int
    public let outcome: RuleBasedRepetitionOutcome
    public let faultTags: [String]
    public let bodyRegions: [String]
    public let severity: String?
    public let assessableFrameCount: Int
    public let skippedFrameCount: Int
    public let skippedReasonCounts: [String: Int]
    public let faultSignals: [QualifiedSignal]

    private enum CodingKeys: String, CodingKey {
        case id, repIndex, outcome, faultTags, bodyRegions, severity
        case assessableFrameCount, skippedFrameCount, skippedReasonCounts, faultSignals
    }

    public init(
        id: String,
        repIndex: Int,
        outcome: RuleBasedRepetitionOutcome,
        faultTags: [String],
        bodyRegions: [String],
        severity: String?,
        assessableFrameCount: Int,
        skippedFrameCount: Int,
        skippedReasonCounts: [String: Int],
        faultSignals: [QualifiedSignal],
    ) {
        self.id = id
        self.repIndex = repIndex
        self.outcome = outcome
        self.faultTags = faultTags
        self.bodyRegions = bodyRegions
        self.severity = severity
        self.assessableFrameCount = assessableFrameCount
        self.skippedFrameCount = skippedFrameCount
        self.skippedReasonCounts = skippedReasonCounts
        self.faultSignals = faultSignals
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(repIndex, forKey: .repIndex)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(faultTags, forKey: .faultTags)
        try container.encode(bodyRegions, forKey: .bodyRegions)
        try container.encode(severity, forKey: .severity)
        try container.encode(assessableFrameCount, forKey: .assessableFrameCount)
        try container.encode(skippedFrameCount, forKey: .skippedFrameCount)
        try container.encode(skippedReasonCounts, forKey: .skippedReasonCounts)
        try container.encode(faultSignals, forKey: .faultSignals)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        repIndex = try container.decode(Int.self, forKey: .repIndex)
        outcome = try container.decode(RuleBasedRepetitionOutcome.self, forKey: .outcome)
        faultTags = try container.decode([String].self, forKey: .faultTags)
        bodyRegions = try container.decode([String].self, forKey: .bodyRegions)
        severity = try container.decodeIfPresent(String.self, forKey: .severity)
        assessableFrameCount = try container.decode(Int.self, forKey: .assessableFrameCount)
        skippedFrameCount = try container.decode(Int.self, forKey: .skippedFrameCount)
        skippedReasonCounts = try container.decode([String: Int].self, forKey: .skippedReasonCounts)
        faultSignals = try container.decode([QualifiedSignal].self, forKey: .faultSignals)
    }
}

public struct RuleBasedSessionSummary: Codable, Equatable, Sendable {
    public let totalReps: Int
    public let correctRepCount: Int
    public let incorrectRepCount: Int
    public let cannotAssessRepCount: Int
    public let incompleteRepCount: Int
    public let wrongByBodyRegion: [String: Int]
    public let wrongBySeverity: [String: Int]
}

public struct RuleBasedClaimBoundary: Codable, Equatable, Sendable {
    public let experimental: Bool
    public let clinicalDecision: Bool
    public let patientFacingApproved: Bool
    public let rawMediaPersisted: Bool
    public let rawLandmarksPersisted: Bool

    public init(
        experimental: Bool = true,
        clinicalDecision: Bool = false,
        patientFacingApproved: Bool = false,
        rawMediaPersisted: Bool = false,
        rawLandmarksPersisted: Bool = false,
    ) {
        self.experimental = experimental
        self.clinicalDecision = clinicalDecision
        self.patientFacingApproved = patientFacingApproved
        self.rawMediaPersisted = rawMediaPersisted
        self.rawLandmarksPersisted = rawLandmarksPersisted
    }
}

public struct RuleBasedSessionRecord: Codable, Equatable, Sendable {
    public let schema: String
    public let moduleID: String
    public let moduleVersion: String
    public let exerciseID: String
    public let trackingProfile: String
    public let anatomicalSide: String
    public let decisionScope: String
    public let summary: RuleBasedSessionSummary
    public let repetitions: [RuleBasedRepetitionResult]
    public let claimBoundary: RuleBasedClaimBoundary
}

public enum RuleBasedSessionRecorderError: Error, Equatable, LocalizedError {
    case invalidRepIndex(Int)
    case nonContiguousRepIndex(expected: Int, actual: Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidRepIndex(index):
            return "repIndex must be positive; received \(index)"
        case let .nonContiguousRepIndex(expected, actual):
            return "repIndex must be contiguous; expected \(expected), received \(actual)"
        }
    }
}

/// Small Foundation-only aggregation engine for local JSON export and future
/// host integration. It does not run a detector, model, or counter. A host
/// supplies completed repetition events plus already-qualified rule signals.
public final class RuleBasedSessionRecorder: @unchecked Sendable {
    public static let schema = "physioai.rule_based_bottle_grab_session.v1"
    public static let moduleID = "bottle_grab_rule_based_session_v8_local"
    public static let moduleVersion = "0.1.0-dev"
    public static let minimumAssessableFrames = 5

    private let lock = NSLock()
    private let exerciseID: String
    private let trackingProfile: String
    private let anatomicalSide: String
    private var repetitions: [RuleBasedRepetitionResult] = []

    public init(
        exerciseID: String = "bottle_grab",
        trackingProfile: String = "pose_plus_hand",
        anatomicalSide: String = "left",
    ) {
        self.exerciseID = exerciseID
        self.trackingProfile = trackingProfile
        self.anatomicalSide = anatomicalSide
    }

    @discardableResult
    public func recordCompletedRepetition(
        _ input: RuleBasedRepetitionInput,
    ) throws -> RuleBasedRepetitionResult {
        lock.lock()
        defer { lock.unlock() }

        guard input.repIndex > 0 else {
            throw RuleBasedSessionRecorderError.invalidRepIndex(input.repIndex)
        }
        let expected = repetitions.count + 1
        guard input.repIndex == expected else {
            throw RuleBasedSessionRecorderError.nonContiguousRepIndex(
                expected: expected,
                actual: input.repIndex,
            )
        }

        let result = makeResult(from: input)
        repetitions.append(result)
        return result
    }

    public func currentRecord() -> RuleBasedSessionRecord {
        lock.lock()
        defer { lock.unlock() }
        return makeRecord()
    }

    public func encodedCurrentRecord() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(currentRecord())
    }

    public func reset() {
        lock.lock()
        repetitions.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    private func makeResult(from input: RuleBasedRepetitionInput) -> RuleBasedRepetitionResult {
        let faultSignals = input.faultSignals.filter { $0.kind == .faultObservation }
        let assessable = input.assessableFrameCount >= Self.minimumAssessableFrames
        let outcome: RuleBasedRepetitionOutcome
        if !assessable {
            outcome = .cannotAssess
        } else if faultSignals.isEmpty {
            outcome = .correct
        } else {
            outcome = .incorrect
        }

        let tags = uniqueSorted(faultSignals.map(\.semanticID))
        let regions = uniqueSorted(faultSignals.map(\.bodyRegion))
        let severity = outcome == .incorrect ? highestSeverity(faultSignals.map(\.severity)) : nil
        return RuleBasedRepetitionResult(
            id: "rep_\(input.repIndex)",
            repIndex: input.repIndex,
            outcome: outcome,
            faultTags: tags,
            bodyRegions: regions,
            severity: severity,
            assessableFrameCount: input.assessableFrameCount,
            skippedFrameCount: input.skippedFrameCount,
            skippedReasonCounts: input.skippedReasonCounts,
            faultSignals: faultSignals,
        )
    }

    private func makeRecord() -> RuleBasedSessionRecord {
        let correct = repetitions.filter { $0.outcome == .correct }.count
        let incorrect = repetitions.filter { $0.outcome == .incorrect }
        let cannotAssess = repetitions.filter { $0.outcome == .cannotAssess }.count
        let incomplete = repetitions.filter { $0.outcome == .incomplete }.count
        var byRegion: [String: Int] = [:]
        var bySeverity: [String: Int] = [:]
        for repetition in incorrect {
            for region in repetition.bodyRegions {
                byRegion[region, default: 0] += 1
            }
            if let severity = repetition.severity {
                bySeverity[severity, default: 0] += 1
            }
        }
        return RuleBasedSessionRecord(
            schema: Self.schema,
            moduleID: Self.moduleID,
            moduleVersion: Self.moduleVersion,
            exerciseID: exerciseID,
            trackingProfile: trackingProfile,
            anatomicalSide: anatomicalSide,
            decisionScope: "experimental_rule_based_visible_faults",
            summary: RuleBasedSessionSummary(
                totalReps: repetitions.count,
                correctRepCount: correct,
                incorrectRepCount: incorrect.count,
                cannotAssessRepCount: cannotAssess,
                incompleteRepCount: incomplete,
                wrongByBodyRegion: byRegion,
                wrongBySeverity: bySeverity,
            ),
            repetitions: repetitions,
            claimBoundary: RuleBasedClaimBoundary(),
        )
    }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values)).sorted()
    }

    private func highestSeverity(_ values: [String]) -> String {
        let priority: [String: Int] = ["low": 1, "medium": 2, "high": 3]
        return values.max {
            (priority[$0.lowercased()] ?? 0) < (priority[$1.lowercased()] ?? 0)
        } ?? "unknown"
    }
}
