import Foundation

// The portable package owns the Codable contract and aggregation behavior.
// Keep these aliases so the existing V8-native façade remains source-compatible
// while its data is now reusable by another Swift/iOS host.
typealias NativeFaultEvidenceObservationKind = QualifiedSignalKind
typealias NativeFaultEvidenceMetric = DerivedMetric
typealias NativeFaultEvidenceObservation = FaultEvidenceObservation
typealias NativeFaultEvidenceCoverage = FaultEvidenceCoverage
typealias NativeFaultEvidenceRepSummary = RepetitionSummary
typealias NativeFaultEvidenceRecord = FaultEvidenceRecord

/// Native adapter around the Foundation-only package recorder. It maps the
/// V8-specific Camera/MediaPipe types to derived package inputs and never
/// forwards raw camera frames, landmark arrays, or patient data.
final class NativeFaultEvidenceRecorder {
    static let schema = FaultEvidenceRecorder.schema
    static let moduleID = FaultEvidenceRecorder.moduleID
    static let moduleVersion = FaultEvidenceRecorder.moduleVersion

    private static let maximumPendingCallbackFrames = 64

    private struct FrameKey: Hashable {
        let sourceGeneration: Int
        let timestampMs: Int
    }

    private let recorder: FaultEvidenceRecorder
    /// `MediaPipePipeline` intentionally emits the counter frame first and
    /// its Hand-comment result later. Keep only the derived frame contract
    /// until that secondary callback completes; this avoids both double
    /// coverage and a premature comment close.
    private var pendingCounterFrames: [FrameKey: FrameInput] = [:]

    init(exerciseID: String = "bottle_grab") {
        recorder = FaultEvidenceRecorder(exerciseID: exerciseID)
    }

    func ingestOutput(snapshot: NativeFrameSnapshot, output: NativeBottleGrabOutput) {
        let frame = FrameInput(
            timestampMs: snapshot.timestampMs,
            sourceGeneration: snapshot.sourceGeneration,
            captureQC: output.captureQC,
            setupReason: output.setupReason,
            totalReps: output.totalReps,
        )
        pendingCounterFrames[
            FrameKey(sourceGeneration: snapshot.sourceGeneration, timestampMs: snapshot.timestampMs)
        ] = frame
        trimPendingFrames()
        recorder.ingestFrame(frame)
    }

    func ingestHandComment(snapshot: NativeFrameSnapshot, cue: NativeBottleGrabCuePreview?) {
        let key = FrameKey(sourceGeneration: snapshot.sourceGeneration, timestampMs: snapshot.timestampMs)
        guard let frame = pendingCounterFrames.removeValue(forKey: key) else {
            // A stale Hand callback must not fabricate a coverage record or
            // attach a cue to an unknown counter value.
            return
        }
        let signals = cue.flatMap(makeQualifiedSignal).map { [$0] } ?? []
        recorder.ingestSignals(for: frame, signals: signals)
        recorder.finishSignalEvaluation(for: frame)
    }

    func resetForNewCaptureSource() {
        pendingCounterFrames.removeAll(keepingCapacity: true)
        recorder.resetForNewCaptureSource()
    }

    /// Non-mutating live snapshot. This is the validation/export surface for
    /// an active practice run; it does not split an active Rule-Wrap event.
    func currentRecord() -> NativeFaultEvidenceRecord {
        recorder.currentRecord()
    }

    func encodedCurrentRecord() throws -> Data {
        try recorder.encodedCurrentRecord()
    }

    /// Finalizes any active occurrence. Preserve this name for the original
    /// V8 local-record API and use `currentRecord()` while a camera session is
    /// still live.
    func localRecord() -> NativeFaultEvidenceRecord {
        recorder.finalizedRecord()
    }

    func encodedLocalRecord() throws -> Data {
        try recorder.encodedFinalizedRecord()
    }

    private func makeQualifiedSignal(_ cue: NativeBottleGrabCuePreview) -> QualifiedSignal? {
        guard cue.cueID == NativeBottleGrabCuePreview.fingerWrap.cueID else {
            return nil
        }
        return QualifiedSignal(
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
            sourceEngine: cue.provenance,
        )
    }

    private func trimPendingFrames() {
        guard pendingCounterFrames.count > Self.maximumPendingCallbackFrames else { return }
        let surplus = pendingCounterFrames.count - Self.maximumPendingCallbackFrames
        let oldest = pendingCounterFrames.keys.sorted {
            if $0.sourceGeneration != $1.sourceGeneration {
                return $0.sourceGeneration < $1.sourceGeneration
            }
            return $0.timestampMs < $1.timestampMs
        }
        for key in oldest.prefix(surplus) {
            pendingCounterFrames.removeValue(forKey: key)
        }
    }
}

/// Thread-safe façade used at the `NativeBottleGrabV7AIModule` callback
/// boundary. It remains an observer: it cannot alter the counter, score,
/// Capture-QC, PhaseNet, TTS, or any decision engine.
final class NativeFaultEvidenceV8Module {
    static let moduleID = NativeFaultEvidenceRecorder.moduleID
    static let moduleVersion = NativeFaultEvidenceRecorder.moduleVersion

    private let recorder: NativeFaultEvidenceRecorder
    private let lock = NSLock()

    init(exerciseID: String = "bottle_grab") {
        recorder = NativeFaultEvidenceRecorder(exerciseID: exerciseID)
    }

    func ingestOutput(snapshot: NativeFrameSnapshot, output: NativeBottleGrabOutput) {
        lock.lock()
        recorder.ingestOutput(snapshot: snapshot, output: output)
        lock.unlock()
    }

    func ingestHandComment(snapshot: NativeFrameSnapshot, cue: NativeBottleGrabCuePreview?) {
        lock.lock()
        recorder.ingestHandComment(snapshot: snapshot, cue: cue)
        lock.unlock()
    }

    func resetForNewCaptureSource() {
        lock.lock()
        recorder.resetForNewCaptureSource()
        lock.unlock()
    }

    func currentRecord() -> NativeFaultEvidenceRecord {
        lock.lock()
        defer { lock.unlock() }
        return recorder.currentRecord()
    }

    func encodedCurrentRecord() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try recorder.encodedCurrentRecord()
    }

    func localRecord() -> NativeFaultEvidenceRecord {
        lock.lock()
        defer { lock.unlock() }
        return recorder.localRecord()
    }

    func encodedLocalRecord() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        return try recorder.encodedLocalRecord()
    }
}
