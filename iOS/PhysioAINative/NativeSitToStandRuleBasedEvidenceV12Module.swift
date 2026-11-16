import Foundation

/// Privacy-safe measurements already derived from a usable Pose frame. Raw
/// landmarks, video buffers, and person identity are deliberately absent from
/// this value so the evidence observer cannot retain or export them.
struct NativeSitToStandEvidenceMetrics: Equatable {
    let trunkViewPlaneTiltDeg: Float
    let trunkLateralOffsetNorm: Float
    let hipAngleDifferenceDeg: Float
    let kneeAngleDifferenceDeg: Float
    let footCenterOffsetFromPelvisNorm: Float
}
/// Development thresholds for visibly large, persistent Pose-geometry
/// deviations. These are rule thresholds rather than clinical cut-offs, and
/// live in one configuration value so later calibration does not rewrite the
/// recorder or counter.
struct NativeSitToStandEvidenceThresholds: Equatable {
    let trunkTiltLowDeg: Float
    let trunkTiltMediumDeg: Float
    let trunkTiltHighDeg: Float
    let trunkOffsetLowNorm: Float
    let trunkOffsetMediumNorm: Float
    let trunkOffsetHighNorm: Float
    let hipAsymmetryLowDeg: Float
    let hipAsymmetryMediumDeg: Float
    let hipAsymmetryHighDeg: Float
    let kneeAsymmetryLowDeg: Float
    let kneeAsymmetryMediumDeg: Float
    let kneeAsymmetryHighDeg: Float
    let footOffsetLowNorm: Float
    let footOffsetMediumNorm: Float
    let footOffsetHighNorm: Float
    let minimumPersistentDurationMs: Int
    let minimumAssessableFrames: Int
    let maximumSignalFrameGapMs: Int

    static let developmentDefault = NativeSitToStandEvidenceThresholds(
        trunkTiltLowDeg: 18,
        trunkTiltMediumDeg: 28,
        trunkTiltHighDeg: 38,
        trunkOffsetLowNorm: 0.16,
        trunkOffsetMediumNorm: 0.25,
        trunkOffsetHighNorm: 0.35,
        hipAsymmetryLowDeg: 20,
        hipAsymmetryMediumDeg: 30,
        hipAsymmetryHighDeg: 40,
        kneeAsymmetryLowDeg: 20,
        kneeAsymmetryMediumDeg: 30,
        kneeAsymmetryHighDeg: 40,
        footOffsetLowNorm: 0.25,
        footOffsetMediumNorm: 0.40,
        footOffsetHighNorm: 0.55,
        minimumPersistentDurationMs: 450,
        minimumAssessableFrames: 5,
        maximumSignalFrameGapMs: 180,
    )

    func qualifiedSignals(for metrics: NativeSitToStandEvidenceMetrics) -> [QualifiedSignal] {
        var signals: [QualifiedSignal] = []

        func add(
            semanticID: String,
            bodyRegions: [String],
            metricName: String,
            value: Float,
            unit: String,
            low: Float,
            medium: Float,
            high: Float,
        ) {
            guard let severity = severity(for: value, low: low, medium: medium, high: high) else {
                return
            }
            for bodyRegion in bodyRegions {
                signals.append(
                    QualifiedSignal(
                        kind: .faultObservation,
                        semanticID: semanticID,
                        bodyRegion: bodyRegion,
                        landmarkRefs: [],
                        metric: DerivedMetric(name: metricName, value: Double(value), unit: unit),
                        severity: severity,
                        // This is deterministic rule qualification, not a
                        // calibrated clinical/model probability.
                        confidence: 1.0,
                        sourceEngine: NativeSitToStandRuleBasedEvidenceV12Module.moduleID,
                    ),
                )
            }
        }

        add(
            semanticID: "trunk_view_plane_tilt",
            bodyRegions: ["trunk"],
            metricName: "trunk_view_plane_tilt_deg",
            value: abs(metrics.trunkViewPlaneTiltDeg),
            unit: "degrees",
            low: trunkTiltLowDeg,
            medium: trunkTiltMediumDeg,
            high: trunkTiltHighDeg,
        )
        add(
            semanticID: "trunk_lateral_offset",
            bodyRegions: ["trunk"],
            metricName: "trunk_lateral_offset_norm",
            value: abs(metrics.trunkLateralOffsetNorm),
            unit: "torso_scale",
            low: trunkOffsetLowNorm,
            medium: trunkOffsetMediumNorm,
            high: trunkOffsetHighNorm,
        )
        add(
            semanticID: "hip_left_right_asymmetry",
            bodyRegions: ["left_hip", "right_hip"],
            metricName: "left_right_hip_angle_gap_deg",
            value: abs(metrics.hipAngleDifferenceDeg),
            unit: "degrees",
            low: hipAsymmetryLowDeg,
            medium: hipAsymmetryMediumDeg,
            high: hipAsymmetryHighDeg,
        )
        add(
            semanticID: "knee_left_right_asymmetry",
            bodyRegions: ["left_knee", "right_knee"],
            metricName: "left_right_knee_angle_gap_deg",
            value: abs(metrics.kneeAngleDifferenceDeg),
            unit: "degrees",
            low: kneeAsymmetryLowDeg,
            medium: kneeAsymmetryMediumDeg,
            high: kneeAsymmetryHighDeg,
        )
        add(
            semanticID: "foot_base_offset",
            bodyRegions: ["left_foot", "right_foot"],
            metricName: "foot_center_offset_from_pelvis_norm",
            value: abs(metrics.footCenterOffsetFromPelvisNorm),
            unit: "torso_scale",
            low: footOffsetLowNorm,
            medium: footOffsetMediumNorm,
            high: footOffsetHighNorm,
        )
        return signals
    }

    private func severity(for value: Float, low: Float, medium: Float, high: Float) -> String? {
        guard value >= low else { return nil }
        if value >= high { return "high" }
        if value >= medium { return "medium" }
        return "low"
    }
}

/// Observer-only, per-counter-cycle rule recorder for Sit-to-Stand. It receives
/// only an already-derived feature frame and the existing counter result, so it
/// cannot change a count, unlock the hand gate, alter PhaseNet, or retain raw
/// camera data.
final class NativeSitToStandRuleBasedEvidenceV12Module {
    static let schema = "physioai.rule_based_sit_to_stand_session.v1"
    static let moduleID = "sit_to_stand_rule_based_evidence_v1"
    static let moduleVersion = "1.0.0-dev"
    static let trackingProfile = "pose_only"
    static let anatomicalSide = "bilateral"
    static let decisionScope = "experimental_rule_based_visible_form"

    private struct SignalOccurrence {
        var signal: QualifiedSignal
        let firstObservedAtMs: Int
        var lastObservedAtMs: Int
        var observationCount: Int
    }

    private struct PendingRepetition {
        let repIndex: Int
        var assessableFrameCount = 0
        var skippedFrameCount = 0
        var skippedReasonCounts: [String: Int] = [:]
        var activeSignals: [String: SignalOccurrence] = [:]
        var qualifiedSignals: [String: QualifiedSignal] = [:]
    }

    private let lock = NSLock()
    private let thresholds: NativeSitToStandEvidenceThresholds
    private var repetitions: [RuleBasedRepetitionResult] = []
    private var pendingRepetition: PendingRepetition?
    private var activeSourceGeneration: Int?

    init(thresholds: NativeSitToStandEvidenceThresholds = .developmentDefault) {
        self.thresholds = thresholds
    }

    func ingest(
        frame: NativeSitToStandFeatureFrame,
        output: NativeSitToStandOutput,
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptSourceGeneration(frame.sourceGeneration) else { return }

        let currentRepIndex = repetitions.count + 1
        if isMovementState(output.geometryStatus),
           frame.featureReady,
           let metrics = frame.evidenceMetrics {
            if pendingRepetition?.repIndex != currentRepIndex {
                pendingRepetition = PendingRepetition(repIndex: currentRepIndex)
            }
            pendingRepetition?.assessableFrameCount += 1
            ingestSignals(
                thresholds.qualifiedSignals(for: metrics),
                timestampMs: frame.timestampMs,
            )
        } else if pendingRepetition?.repIndex == currentRepIndex,
                  !frame.featureReady {
            pendingRepetition?.skippedFrameCount += 1
            let reason = frame.reason ?? output.setupReason ?? output.geometryReason ?? "cannot_assess"
            pendingRepetition?.skippedReasonCounts[reason, default: 0] += 1
            // A fresh counter cycle must not bridge evidence across a rejected
            // Pose frame. It will become cannot_assess only if an existing
            // counter-owned repetition later closes it.
            pendingRepetition?.activeSignals.removeAll(keepingCapacity: true)
        }

        let completedTotal = max(0, output.geometryTotalReps)
        while repetitions.count < completedTotal {
            let repIndex = repetitions.count + 1
            let pending = pendingRepetition?.repIndex == repIndex
                ? pendingRepetition
                : nil
            repetitions.append(makeResult(repIndex: repIndex, pending: pending))
            pendingRepetition = nil
        }
    }

    func resetForNewSession() {
        lock.lock()
        repetitions.removeAll(keepingCapacity: true)
        pendingRepetition = nil
        activeSourceGeneration = nil
        lock.unlock()
    }

    /// A camera/lens replacement may restart frame timing. Completed
    /// repetitions remain session evidence, while a partial rule occurrence is
    /// discarded rather than joined across the source boundary.
    func resetForNewCaptureSource() {
        lock.lock()
        pendingRepetition = nil
        activeSourceGeneration = nil
        lock.unlock()
    }

    func currentRecord() -> RuleBasedSessionRecord {
        lock.lock()
        defer { lock.unlock() }
        return makeRecord()
    }

    func encodedCurrentRecord() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(currentRecord())
    }

    /// The observer has no delayed Hand callback. This final read intentionally
    /// preserves only completed counter-owned repetitions and never invents an
    /// incomplete or incorrect record from an uncounted attempt.
    func encodedFinalizedCurrentRecord() throws -> Data {
        try encodedCurrentRecord()
    }

    private func isMovementState(_ value: String) -> Bool {
        ["rising", "standing_hold", "lowering"].contains(value)
    }

    private func ingestSignals(_ signals: [QualifiedSignal], timestampMs: Int) {
        guard var pending = pendingRepetition else { return }
        let incoming = Dictionary(uniqueKeysWithValues: signals.map { (signalKey(for: $0), $0) })
        pending.activeSignals = pending.activeSignals.filter { incoming[$0.key] != nil }

        for (key, signal) in incoming {
            var occurrence: SignalOccurrence
            if var existing = pending.activeSignals[key],
               timestampMs - existing.lastObservedAtMs <= thresholds.maximumSignalFrameGapMs {
                existing.lastObservedAtMs = timestampMs
                existing.observationCount += 1
                existing.signal = strongerSignal(existing.signal, signal)
                occurrence = existing
            } else {
                occurrence = SignalOccurrence(
                    signal: signal,
                    firstObservedAtMs: timestampMs,
                    lastObservedAtMs: timestampMs,
                    observationCount: 1,
                )
            }
            pending.activeSignals[key] = occurrence
            if occurrence.observationCount >= thresholds.minimumAssessableFrames,
               occurrence.lastObservedAtMs - occurrence.firstObservedAtMs >= thresholds.minimumPersistentDurationMs {
                pending.qualifiedSignals[key] = strongerSignal(
                    pending.qualifiedSignals[key],
                    occurrence.signal,
                )
            }
        }
        pendingRepetition = pending
    }

    private func makeResult(repIndex: Int, pending: PendingRepetition?) -> RuleBasedRepetitionResult {
        let assessableFrameCount = pending?.assessableFrameCount ?? 0
        let signals = Array(pending?.qualifiedSignals.values ?? [:].values)
            .sorted { signalKey(for: $0) < signalKey(for: $1) }
        let outcome: RuleBasedRepetitionOutcome
        if assessableFrameCount < thresholds.minimumAssessableFrames {
            outcome = .cannotAssess
        } else if signals.isEmpty {
            outcome = .correct
        } else {
            outcome = .incorrect
        }
        let tags = Array(Set(signals.map(\.semanticID))).sorted()
        let bodyRegions = Array(Set(signals.map(\.bodyRegion))).sorted()
        return RuleBasedRepetitionResult(
            id: "rep_\(repIndex)",
            repIndex: repIndex,
            outcome: outcome,
            faultTags: tags,
            bodyRegions: bodyRegions,
            severity: outcome == .incorrect ? highestSeverity(signals.map(\.severity)) : nil,
            assessableFrameCount: assessableFrameCount,
            skippedFrameCount: pending?.skippedFrameCount ?? 0,
            skippedReasonCounts: pending?.skippedReasonCounts ?? [:],
            faultSignals: signals,
        )
    }

    private func makeRecord() -> RuleBasedSessionRecord {
        let correct = repetitions.filter { $0.outcome == .correct }.count
        let incorrect = repetitions.filter { $0.outcome == .incorrect }
        let cannotAssess = repetitions.filter { $0.outcome == .cannotAssess }.count
        let incomplete = repetitions.filter { $0.outcome == .incomplete }.count
        var wrongByBodyRegion: [String: Int] = [:]
        var wrongBySeverity: [String: Int] = [:]
        for repetition in incorrect {
            for bodyRegion in repetition.bodyRegions {
                wrongByBodyRegion[bodyRegion, default: 0] += 1
            }
            if let severity = repetition.severity {
                wrongBySeverity[severity, default: 0] += 1
            }
        }
        return RuleBasedSessionRecord(
            schema: Self.schema,
            moduleID: Self.moduleID,
            moduleVersion: Self.moduleVersion,
            exerciseID: NativeSitToStandV72AIModule.exerciseID,
            trackingProfile: Self.trackingProfile,
            anatomicalSide: Self.anatomicalSide,
            decisionScope: Self.decisionScope,
            summary: RuleBasedSessionSummary(
                totalReps: repetitions.count,
                correctRepCount: correct,
                incorrectRepCount: incorrect.count,
                cannotAssessRepCount: cannotAssess,
                incompleteRepCount: incomplete,
                wrongByBodyRegion: wrongByBodyRegion,
                wrongBySeverity: wrongBySeverity,
            ),
            repetitions: repetitions,
            claimBoundary: RuleBasedClaimBoundary(),
        )
    }

    private func acceptSourceGeneration(_ sourceGeneration: Int) -> Bool {
        if let activeSourceGeneration {
            guard sourceGeneration >= activeSourceGeneration else { return false }
            if sourceGeneration > activeSourceGeneration {
                pendingRepetition = nil
                self.activeSourceGeneration = sourceGeneration
            }
        } else {
            activeSourceGeneration = sourceGeneration
        }
        return true
    }

    private func signalKey(for signal: QualifiedSignal) -> String {
        "\(signal.semanticID)|\(signal.bodyRegion)|\(signal.sourceEngine)"
    }

    private func strongerSignal(_ current: QualifiedSignal?, _ next: QualifiedSignal) -> QualifiedSignal {
        guard let current else { return next }
        let currentRank = severityRank(current.severity)
        let nextRank = severityRank(next.severity)
        if nextRank > currentRank { return next }
        if nextRank == currentRank, next.metric.value > current.metric.value { return next }
        return current
    }

    private func highestSeverity(_ values: [String]) -> String? {
        values.max { severityRank($0) < severityRank($1) }
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
