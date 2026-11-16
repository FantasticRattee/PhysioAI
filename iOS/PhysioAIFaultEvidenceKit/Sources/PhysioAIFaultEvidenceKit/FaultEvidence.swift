import Foundation

/// A derived, privacy-safe frame envelope. Raw camera buffers and landmark
/// arrays are intentionally not representable by this package's public API.
public struct FrameInput: Codable, Equatable, Sendable {
    public let timestampMs: Int
    public let sourceGeneration: Int
    public let captureQC: String
    public let setupReason: String?
    public let totalReps: Int

    public init(
        timestampMs: Int,
        sourceGeneration: Int = 0,
        captureQC: String = "can_assess",
        setupReason: String? = nil,
        totalReps: Int = 0,
    ) {
        self.timestampMs = timestampMs
        self.sourceGeneration = sourceGeneration
        self.captureQC = captureQC
        self.setupReason = setupReason
        self.totalReps = max(0, totalReps)
    }

    public var isAssessable: Bool { captureQC == "can_assess" }
}

public enum QualifiedSignalKind: String, Codable, Equatable, Sendable {
    case faultObservation = "fault_observation"
    case commentObservation = "comment_observation"
}

public struct DerivedMetric: Codable, Equatable, Sendable {
    public let name: String
    public let value: Double
    public let unit: String

    public init(name: String, value: Double, unit: String) {
        self.name = name
        self.value = value
        self.unit = unit
    }
}

/// A signal must already be qualified by an upstream engine. The recorder
/// aggregates it; it does not run a classifier or infer clinical truth.
public struct QualifiedSignal: Codable, Equatable, Sendable {
    public let kind: QualifiedSignalKind
    public let semanticID: String
    public let bodyRegion: String
    public let landmarkRefs: [String]
    public let metric: DerivedMetric
    public let severity: String
    public let confidence: Double
    public let sourceEngine: String

    public init(
        kind: QualifiedSignalKind = .commentObservation,
        semanticID: String,
        bodyRegion: String,
        landmarkRefs: [String],
        metric: DerivedMetric,
        severity: String,
        confidence: Double,
        sourceEngine: String,
    ) {
        self.kind = kind
        self.semanticID = semanticID
        self.bodyRegion = bodyRegion
        self.landmarkRefs = landmarkRefs
        self.metric = metric
        self.severity = severity
        self.confidence = confidence
        self.sourceEngine = sourceEngine
    }
}

public struct FaultEvidenceObservation: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: QualifiedSignalKind
    public let semanticID: String
    public let bodyRegion: String
    public let landmarkRefs: [String]
    public let metric: DerivedMetric
    public let severity: String
    public let confidence: Double
    public let sourceEngine: String
    public let sourceGeneration: Int
    public let repIndex: Int
    public let firstObservedAtMs: Int
    public let lastObservedAtMs: Int
    public let observationCount: Int

    fileprivate init(
        id: String,
        signal: QualifiedSignal,
        sourceGeneration: Int,
        repIndex: Int,
        firstObservedAtMs: Int,
        lastObservedAtMs: Int,
        observationCount: Int,
    ) {
        self.id = id
        self.kind = signal.kind
        self.semanticID = signal.semanticID
        self.bodyRegion = signal.bodyRegion
        self.landmarkRefs = signal.landmarkRefs
        self.metric = signal.metric
        self.severity = signal.severity
        self.confidence = signal.confidence
        self.sourceEngine = signal.sourceEngine
        self.sourceGeneration = sourceGeneration
        self.repIndex = repIndex
        self.firstObservedAtMs = firstObservedAtMs
        self.lastObservedAtMs = lastObservedAtMs
        self.observationCount = observationCount
    }
}

public struct FaultEvidenceCoverage: Codable, Equatable, Sendable {
    public let observedFrames: Int
    public let assessableFrames: Int
    public let skippedFrames: Int
    public let skippedReasonCounts: [String: Int]
}

public struct RepetitionSummary: Codable, Equatable, Sendable {
    public let totalReps: Int
    public let commentFlaggedRepIndexes: [Int]
    public let commentFlaggedRepCount: Int
    public let correctRepCount: Int?
    public let incorrectRepCount: Int?
    public let correctnessStatus: String

    public init(
        totalReps: Int,
        commentFlaggedRepIndexes: [Int],
        commentFlaggedRepCount: Int,
        correctRepCount: Int? = nil,
        incorrectRepCount: Int? = nil,
        correctnessStatus: String = "unavailable_no_fault_engine",
    ) {
        self.totalReps = totalReps
        self.commentFlaggedRepIndexes = commentFlaggedRepIndexes
        self.commentFlaggedRepCount = commentFlaggedRepCount
        self.correctRepCount = correctRepCount
        self.incorrectRepCount = incorrectRepCount
        self.correctnessStatus = correctnessStatus
    }

    private enum CodingKeys: String, CodingKey {
        case totalReps, commentFlaggedRepIndexes, commentFlaggedRepCount
        case correctRepCount, incorrectRepCount, correctnessStatus
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(totalReps, forKey: .totalReps)
        try container.encode(commentFlaggedRepIndexes, forKey: .commentFlaggedRepIndexes)
        try container.encode(commentFlaggedRepCount, forKey: .commentFlaggedRepCount)
        try container.encode(correctRepCount, forKey: .correctRepCount)
        try container.encode(incorrectRepCount, forKey: .incorrectRepCount)
        try container.encode(correctnessStatus, forKey: .correctnessStatus)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalReps = try container.decode(Int.self, forKey: .totalReps)
        commentFlaggedRepIndexes = try container.decode([Int].self, forKey: .commentFlaggedRepIndexes)
        commentFlaggedRepCount = try container.decode(Int.self, forKey: .commentFlaggedRepCount)
        correctRepCount = try container.decodeIfPresent(Int.self, forKey: .correctRepCount)
        incorrectRepCount = try container.decodeIfPresent(Int.self, forKey: .incorrectRepCount)
        correctnessStatus = try container.decode(String.self, forKey: .correctnessStatus)
    }
}

public struct FaultEvidenceRecord: Codable, Equatable, Sendable {
    public let schema: String
    public let moduleID: String
    public let moduleVersion: String
    public let exerciseID: String
    public let sourceGenerations: [Int]
    public let coverage: FaultEvidenceCoverage
    public let repetitionSummary: RepetitionSummary
    public let faultObservations: [FaultEvidenceObservation]
    public let commentObservations: [FaultEvidenceObservation]
}

/// Thread-safe, process-local aggregate recorder. `currentRecord()` and
/// `encodedCurrentRecord()` are non-mutating snapshots; use
/// `finalizedRecord()` when the host is ending a session or source.
public final class FaultEvidenceRecorder: @unchecked Sendable {
    public static let schema = "physioai.native.fault_evidence.v1"
    public static let moduleID = "native_fault_evidence_v8_local"
    public static let moduleVersion = "0.2.0-dev"

    private let exerciseID: String
    private let lock = NSLock()
    private var sourceGenerations = Set<Int>()
    private var observedFrames = 0
    private var assessableFrames = 0
    private var skippedFrames = 0
    private var skippedReasonCounts: [String: Int] = [:]
    private var highestTotalReps = 0
    private var active: [String: ActiveSignal] = [:]
    private var completed: [FaultEvidenceObservation] = []
    private var latestSourceGeneration: Int?
    private var ingestedFrameIdentities: Set<FrameIdentity> = []
    private var evaluatedSignalKeys: [FrameIdentity: Set<String>] = [:]

    private struct FrameIdentity: Hashable {
        let sourceGeneration: Int
        let timestampMs: Int
    }

    private struct ActiveSignal {
        let key: String
        let signal: QualifiedSignal
        let sourceGeneration: Int
        let repIndex: Int
        let firstObservedAtMs: Int
        var lastObservedAtMs: Int
        var observationCount: Int
    }

    public init(exerciseID: String = "bottle_grab") {
        self.exerciseID = exerciseID
    }

    public func ingest(frame: FrameInput, signal: QualifiedSignal? = nil) {
        ingest(frame: frame, signals: signal.map { [$0] } ?? [])
    }

    public func ingest(frame: FrameInput, signals: [QualifiedSignal]) {
        ingestFrame(frame)
        ingestSignals(for: frame, signals: signals)
        finishSignalEvaluation(for: frame)
    }

    /// Ingests one camera frame's derived coverage/counter metadata. This is
    /// the only method that increments coverage. A later signal callback for
    /// the same frame must use `ingestSignals(for:signals:)`, not this method.
    public func ingestFrame(_ frame: FrameInput) {
        lock.lock()
        defer { lock.unlock() }

        guard acceptSourceGeneration(frame.sourceGeneration) else { return }
        sourceGenerations.insert(frame.sourceGeneration)

        let identity = FrameIdentity(
            sourceGeneration: frame.sourceGeneration,
            timestampMs: frame.timestampMs,
        )
        guard ingestedFrameIdentities.insert(identity).inserted else { return }

        observedFrames += 1
        highestTotalReps = max(highestTotalReps, frame.totalReps)

        if frame.isAssessable {
            assessableFrames += 1
        } else {
            skippedFrames += 1
            let reason = frame.setupReason ?? frame.captureQC
            skippedReasonCounts[reason, default: 0] += 1
        }
    }

    /// Evaluates qualified signals for a frame that was already admitted with
    /// `ingestFrame`. It never increments coverage and never closes an active
    /// signal by itself, so delayed or split engine callbacks are safe.
    public func ingestSignals(for frame: FrameInput, signals: [QualifiedSignal]) {
        lock.lock()
        defer { lock.unlock() }

        guard acceptSourceGeneration(frame.sourceGeneration) else { return }
        sourceGenerations.insert(frame.sourceGeneration)
        guard frame.isAssessable else { return }

        let identity = FrameIdentity(
            sourceGeneration: frame.sourceGeneration,
            timestampMs: frame.timestampMs,
        )
        var keys = evaluatedSignalKeys[identity, default: []]
        for signal in signals {
            let key = eventKey(for: signal)
            keys.insert(key)
            upsert(signal: signal, frame: frame)
        }
        evaluatedSignalKeys[identity] = keys
    }

    /// Marks all signal callbacks for one frame as complete. Missing signals
    /// close active events only here, after the host has had an opportunity to
    /// deliver delayed Pose/Hand/Bottle-derived evidence.
    public func finishSignalEvaluation(for frame: FrameInput) {
        lock.lock()
        defer { lock.unlock() }

        guard acceptSourceGeneration(frame.sourceGeneration) else { return }
        guard frame.isAssessable else { return }
        let identity = FrameIdentity(
            sourceGeneration: frame.sourceGeneration,
            timestampMs: frame.timestampMs,
        )
        let keys = evaluatedSignalKeys.removeValue(forKey: identity) ?? []
        for key in active.keys where !keys.contains(key) {
            closeActive(key: key)
        }
    }

    public func resetForNewCaptureSource() {
        lock.lock()
        defer { lock.unlock() }
        closeAllActive()
        evaluatedSignalKeys.removeAll()
    }

    public func currentRecord() -> FaultEvidenceRecord {
        lock.lock()
        defer { lock.unlock() }
        return buildRecord(includeActive: true)
    }

    public func encodedCurrentRecord() throws -> Data {
        try JSONEncoder().encode(currentRecord())
    }

    public func finalizedRecord() -> FaultEvidenceRecord {
        lock.lock()
        defer { lock.unlock() }
        closeAllActive()
        return buildRecord(includeActive: false)
    }

    public func encodedFinalizedRecord() throws -> Data {
        try JSONEncoder().encode(finalizedRecord())
    }

    /// Compatibility alias for callers that used the app recorder name. This
    /// method intentionally has finalizing semantics; live callers should use
    /// `currentRecord()` instead.
    public func localRecord() -> FaultEvidenceRecord { finalizedRecord() }

    public func encodedLocalRecord() throws -> Data { try encodedFinalizedRecord() }

    private func buildRecord(includeActive: Bool) -> FaultEvidenceRecord {
        let activeObservations = includeActive ? active.values.map(observation(from:)) : []
        let all = (completed + activeObservations).sorted(by: observationSort)
        let flagged = Set(
            all
                .filter { $0.kind == .commentObservation }
                .map(\.repIndex)
                .filter { $0 > 0 },
        ).sorted()

        return FaultEvidenceRecord(
            schema: Self.schema,
            moduleID: Self.moduleID,
            moduleVersion: Self.moduleVersion,
            exerciseID: exerciseID,
            sourceGenerations: sourceGenerations.sorted(),
            coverage: FaultEvidenceCoverage(
                observedFrames: observedFrames,
                assessableFrames: assessableFrames,
                skippedFrames: skippedFrames,
                skippedReasonCounts: skippedReasonCounts,
            ),
            repetitionSummary: RepetitionSummary(
                totalReps: highestTotalReps,
                commentFlaggedRepIndexes: flagged,
                commentFlaggedRepCount: flagged.count,
            ),
            faultObservations: all.filter { $0.kind == .faultObservation },
            commentObservations: all.filter { $0.kind == .commentObservation },
        )
    }

    private func upsert(signal: QualifiedSignal, frame: FrameInput) {
        let key = eventKey(for: signal)
        if var current = active[key], current.sourceGeneration == frame.sourceGeneration {
            current.lastObservedAtMs = max(current.lastObservedAtMs, frame.timestampMs)
            current.observationCount += 1
            active[key] = current
            return
        }

        closeActive(key: key)
        active[key] = ActiveSignal(
            key: key,
            signal: signal,
            sourceGeneration: frame.sourceGeneration,
            repIndex: frame.totalReps,
            firstObservedAtMs: frame.timestampMs,
            lastObservedAtMs: frame.timestampMs,
            observationCount: 1,
        )
    }

    private func eventKey(for signal: QualifiedSignal) -> String {
        "\(signal.kind.rawValue)|\(signal.semanticID)|\(signal.bodyRegion)|\(signal.sourceEngine)"
    }

    private func closeActive(key: String) {
        guard let current = active.removeValue(forKey: key) else { return }
        completed.append(observation(from: current))
    }

    private func closeAllActive() {
        for key in active.keys { closeActive(key: key) }
    }

    private func acceptSourceGeneration(_ generation: Int) -> Bool {
        if let latestSourceGeneration = self.latestSourceGeneration {
            // A late callback from an older camera/lens source must not switch
            // the recorder back to that source and close the current events.
            guard generation >= latestSourceGeneration else { return false }
            if generation > latestSourceGeneration {
                closeAllActive()
                evaluatedSignalKeys = evaluatedSignalKeys.filter {
                    $0.key.sourceGeneration == generation
                }
                self.latestSourceGeneration = generation
            }
        } else {
            self.latestSourceGeneration = generation
        }
        return true
    }

    private func observation(from current: ActiveSignal) -> FaultEvidenceObservation {
        FaultEvidenceObservation(
            id: "\(current.signal.kind.rawValue)_\(current.signal.semanticID)_s\(current.sourceGeneration)_\(current.firstObservedAtMs)",
            signal: current.signal,
            sourceGeneration: current.sourceGeneration,
            repIndex: current.repIndex,
            firstObservedAtMs: current.firstObservedAtMs,
            lastObservedAtMs: current.lastObservedAtMs,
            observationCount: current.observationCount,
        )
    }

    private func observationSort(_ lhs: FaultEvidenceObservation, _ rhs: FaultEvidenceObservation) -> Bool {
        if lhs.sourceGeneration != rhs.sourceGeneration { return lhs.sourceGeneration < rhs.sourceGeneration }
        return lhs.firstObservedAtMs < rhs.firstObservedAtMs
    }
}
