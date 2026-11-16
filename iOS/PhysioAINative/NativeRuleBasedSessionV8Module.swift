import Foundation

typealias NativeRuleBasedSessionRecord = RuleBasedSessionRecord

/// Observer-only V8 adapter that turns already-qualified native counter and
/// Rule-Wrap callbacks into portable per-repetition JSON. It does not alter
/// the V7/Baseline #5 counter, Camera, Capture-QC, score, PhaseNet, or TTS.
final class NativeRuleBasedSessionV8Module {
    static let moduleID = RuleBasedSessionRecorder.moduleID
    static let moduleVersion = RuleBasedSessionRecorder.moduleVersion

    private static let maximumPendingFrames = 64

    private struct FrameKey: Hashable {
        let sourceGeneration: Int
        let timestampMs: Int
    }

    private struct PendingFrame {
        let frame: FrameInput
        let totalReps: Int
    }

    private struct PendingRepetition {
        let repIndex: Int
        var assessableFrameCount = 0
        var skippedFrameCount = 0
        var skippedReasonCounts: [String: Int] = [:]
        var faultSignals: [String: QualifiedSignal] = [:]
    }

    private let lock = NSLock()
    private let recorder: RuleBasedSessionRecorder
    private var pendingFrames: [FrameKey: PendingFrame] = [:]
    private var pendingRepetition: PendingRepetition?
    /// `NativeBottleGrabEngine` restarts its counter at zero with a new
    /// capture source. This observer keeps completed session evidence, so it
    /// translates the current source's total into a session-wide total without
    /// ever writing to, or changing, the underlying counter.
    private var counterTotalOffset = 0
    private var highestCounterTotal = 0
    private var latestSourceGeneration: Int?

    init(exerciseID: String = "bottle_grab") {
        recorder = RuleBasedSessionRecorder(exerciseID: exerciseID)
    }

    func ingestOutput(snapshot: NativeFrameSnapshot, output: NativeBottleGrabOutput) {
        lock.lock()
        defer { lock.unlock() }
        guard acceptSourceGeneration(snapshot.sourceGeneration) else { return }
        let key = FrameKey(sourceGeneration: snapshot.sourceGeneration, timestampMs: snapshot.timestampMs)
        pendingFrames[key] = PendingFrame(
            frame: FrameInput(
                timestampMs: snapshot.timestampMs,
                sourceGeneration: snapshot.sourceGeneration,
                captureQC: output.captureQC,
                setupReason: output.setupReason,
                totalReps: output.totalReps,
            ),
            totalReps: max(0, output.totalReps),
        )
        trimPendingFrames()
    }

    /// Call after the Hand callback for the same timestamp. A nil cue is a
    /// valid no-fault completion signal; it never fabricates a wrong rep.
    func ingestHandComment(snapshot: NativeFrameSnapshot, cue: NativeBottleGrabCuePreview?) {
        lock.lock()
        defer { lock.unlock() }
        let key = FrameKey(sourceGeneration: snapshot.sourceGeneration, timestampMs: snapshot.timestampMs)
        guard let pending = pendingFrames.removeValue(forKey: key) else { return }
        guard acceptSourceGeneration(snapshot.sourceGeneration) else { return }
        ingest(frame: pending.frame, totalReps: pending.totalReps, cue: cue)
    }

    func resetForNewCaptureSource() {
        lock.lock()
        pendingFrames.removeAll(keepingCapacity: true)
        pendingRepetition = nil
        counterTotalOffset = highestCounterTotal
        latestSourceGeneration = nil
        lock.unlock()
    }

    func currentRecord() -> NativeRuleBasedSessionRecord {
        lock.lock()
        defer { lock.unlock() }
        return recorder.currentRecord()
    }

    func encodedCurrentRecord() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try recorder.encodedCurrentRecord()
    }

    /// A final host read drains only existing derived frames after a brief
    /// Hand-callback grace period. It cannot change counter totals or create a
    /// new repetition boundary.
    func encodedFinalizedCurrentRecord() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        flushPendingFramesWithoutFault()
        return try recorder.encodedCurrentRecord()
    }

    private func ingest(frame: FrameInput, totalReps: Int, cue: NativeBottleGrabCuePreview?) {
        // A counter that decreases after a source change cannot establish a
        // second set of global indices. Translate a new source's local total
        // with the captured offset, preserve completed output, and discard
        // only an in-source decrease until that source catches up.
        let sessionTotal = counterTotalOffset + max(0, totalReps)
        guard sessionTotal >= highestCounterTotal else {
            pendingRepetition = nil
            return
        }

        let currentIndex = highestCounterTotal + 1
        if pendingRepetition?.repIndex != currentIndex {
            pendingRepetition = PendingRepetition(repIndex: currentIndex)
        }
        if frame.isAssessable {
            pendingRepetition?.assessableFrameCount += 1
        } else {
            pendingRepetition?.skippedFrameCount += 1
            let reason = frame.setupReason ?? frame.captureQC
            pendingRepetition?.skippedReasonCounts[reason, default: 0] += 1
        }
        if let signal = faultSignal(for: cue) {
            let key = "\(signal.semanticID)|\(signal.bodyRegion)|\(signal.sourceEngine)"
            pendingRepetition?.faultSignals[key] = signal
        }

        guard sessionTotal > highestCounterTotal else { return }
        while highestCounterTotal < sessionTotal {
            let index = highestCounterTotal + 1
            let evidence = index == currentIndex
                ? pendingRepetition
                : PendingRepetition(repIndex: index)
            let input = RuleBasedRepetitionInput(
                repIndex: index,
                assessableFrameCount: evidence?.assessableFrameCount ?? 0,
                skippedFrameCount: evidence?.skippedFrameCount ?? 0,
                skippedReasonCounts: evidence?.skippedReasonCounts ?? [:],
                faultSignals: Array(evidence?.faultSignals.values ?? [:].values),
            )
            _ = try? recorder.recordCompletedRepetition(input)
            highestCounterTotal = index
        }
        pendingRepetition = nil
    }

    private func faultSignal(for cue: NativeBottleGrabCuePreview?) -> QualifiedSignal? {
        guard cue?.cueID == NativeBottleGrabCuePreview.fingerWrap.cueID else { return nil }
        return QualifiedSignal(
            kind: .faultObservation,
            semanticID: "incomplete_visible_finger_wrap",
            bodyRegion: "left_hand",
            landmarkRefs: (5...20).map { "hand_\($0)" },
            metric: DerivedMetric(name: "rule_wrap_policy_qualified", value: 1, unit: "boolean"),
            severity: "medium",
            confidence: 0.75,
            sourceEngine: cue?.provenance ?? "experimental_rule_wrap_policy_subset_native",
        )
    }

    private func acceptSourceGeneration(_ generation: Int) -> Bool {
        if let latest = latestSourceGeneration {
            guard generation >= latest else { return false }
            if generation > latest {
                pendingRepetition = nil
                pendingFrames = pendingFrames.filter { $0.key.sourceGeneration == generation }
                counterTotalOffset = highestCounterTotal
                latestSourceGeneration = generation
            }
        } else {
            latestSourceGeneration = generation
        }
        return true
    }

    private func trimPendingFrames() {
        guard pendingFrames.count > Self.maximumPendingFrames else { return }
        let surplus = pendingFrames.count - Self.maximumPendingFrames
        let keys = pendingFrames.keys.sorted {
            $0.sourceGeneration == $1.sourceGeneration
                ? $0.timestampMs < $1.timestampMs
                : $0.sourceGeneration < $1.sourceGeneration
        }
        for key in keys.prefix(surplus) {
            pendingFrames.removeValue(forKey: key)
        }
    }

    private func flushPendingFramesWithoutFault() {
        let frames = pendingFrames.values.sorted {
            $0.frame.sourceGeneration == $1.frame.sourceGeneration
                ? $0.frame.timestampMs < $1.frame.timestampMs
                : $0.frame.sourceGeneration < $1.frame.sourceGeneration
        }
        pendingFrames.removeAll(keepingCapacity: true)
        for pending in frames {
            ingest(frame: pending.frame, totalReps: pending.totalReps, cue: nil)
        }
    }
}
