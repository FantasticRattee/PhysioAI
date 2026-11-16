import Foundation
import XCTest
@testable import PhysioAINative

/// Developer-only replay coverage for externally stored Bottle Grab raw
/// traces. The test reads a user-supplied JSONL path only in memory, sends it
/// through the normal native engine, and records no frames/predictions/files.
/// It is deliberately not a production app route or a model-accuracy claim.
final class NativeBottleGrabJSONLReplayTests: XCTestCase {
    func testRawV14FrameMapsToTheNormalNativeSnapshotContract() throws {
        let row = try JSONDecoder().decode(
            RawFrame.self,
            from: Data("""
            {
              "schema":"physioai.bottle_grab_pose_hand_raw_frame.v1_4",
              "sourceTimestampMs":67,
              "sourceMirrored":false,
              "anatomicalSide":"left",
              "pose":{"imageLandmarks":[{"x":0.2,"y":0.3,"z":0,"visibility":0.9}]},
              "hand":{"detectedHandSide":"Left","detectedHandScore":0.98,"imageLandmarks":[{"x":0.4,"y":0.5,"z":0,"visibility":0.9}]}
            }
            """.utf8),
        )

        let snapshot = row.nativeSnapshot(sourceGeneration: 7)

        XCTAssertEqual(snapshot.timestampMs, 67)
        XCTAssertEqual(snapshot.sourceGeneration, 7)
        XCTAssertEqual(snapshot.pose.count, 1)
        XCTAssertEqual(snapshot.hand.count, 1)
        // Prefer the trace's already-normalized anatomical-side field over
        // the detector's display label, exactly as live MediaPipe does.
        XCTAssertEqual(snapshot.handSide, "left")
        XCTAssertEqual(snapshot.handScore, 0.98, accuracy: 0.0001)
    }

    func testExternalReplayUsesNativeEngineAndKeepsOnlyAggregates() throws {
        let aggregate = try runExternalReplay(countingEnabled: false)

        XCTAssertGreaterThan(aggregate.rows, 0)
        // This is deliberately wiring-only. The patient-visible PhaseNet
        // policy and the geometry diagnostic are disabled, so zero cycles
        // cannot be read as a model or rep-counter result. It proves only
        // JSONL → normal native engine mapping without retaining source
        // payloads in this workspace.
        XCTAssertEqual(aggregate.visiblePhaseCycles, 0)
        XCTAssertEqual(aggregate.hostDiagnosticCycles, 0)
        print(aggregate.logLine(mode: "wiring_only"))
    }

    func testExternalActiveHostReplayKeepsOnlyAggregates() throws {
        guard ProcessInfo.processInfo.environment["PHYSIOAI_BOTTLE_GRAB_REPLAY_ACTIVE"] == "1" else {
            throw XCTSkip("Set PHYSIOAI_BOTTLE_GRAB_REPLAY_ACTIVE=1 with an external replay path to exercise the active host counter.")
        }
        let aggregate = try runExternalReplay(countingEnabled: true)

        XCTAssertGreaterThan(aggregate.rows, 0)
        // This remains aggregate-only and has no locked-label target. It is a
        // native-engine integration/reproducibility check, not an accuracy or
        // threshold-tuning criterion for unseen data.
        XCTAssertLessThanOrEqual(aggregate.visiblePhaseCycles, aggregate.rows)
        XCTAssertLessThanOrEqual(aggregate.hostDiagnosticCycles, aggregate.rows)
        // The separately-instantiated policy mirrors the engine's lifecycle
        // phase decoder; this confirms which source owns visible reps.
        XCTAssertEqual(aggregate.visiblePhaseCycles, aggregate.phasePolicyCycles)
        XCTAssertLessThanOrEqual(aggregate.phasePolicyCycles, aggregate.newPredictionRows)
        print(aggregate.logLine(mode: "active_host_integration_only"))
    }

    func testExternalActiveHostReplayDirectoryKeepsOnlyAggregates() throws {
        guard ProcessInfo.processInfo.environment["PHYSIOAI_BOTTLE_GRAB_REPLAY_DIRECTORY_ACTIVE"] == "1" else {
            throw XCTSkip("Set PHYSIOAI_BOTTLE_GRAB_REPLAY_DIRECTORY_ACTIVE=1 with an external directory to run aggregate-only active host replay.")
        }
        guard let path = ProcessInfo.processInfo.environment["PHYSIOAI_BOTTLE_GRAB_REPLAY_DIRECTORY"], !path.isEmpty else {
            throw XCTSkip("Set PHYSIOAI_BOTTLE_GRAB_REPLAY_DIRECTORY to an external raw JSONL directory.")
        }
        let url = URL(fileURLWithPath: path)
        let files = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles],
        )
        .filter { $0.pathExtension == "jsonl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else {
            throw XCTSkip("No external JSONL traces are available in the requested replay directory.")
        }

        // Do not save, label, or use individual trace outputs as a pass/fail
        // target. This verifies the entire supplied corpus follows the normal
        // native-engine path and prints aggregate counts only.
        var totals = ReplayCorpusAggregate()
        for file in files {
            let aggregate = try runExternalReplay(at: file, countingEnabled: true)
            totals.include(aggregate)
        }
        XCTAssertEqual(totals.traces, files.count)
        XCTAssertGreaterThan(totals.rows, 0)
        XCTAssertLessThanOrEqual(totals.visiblePhaseCycles, totals.rows)
        XCTAssertLessThanOrEqual(totals.hostDiagnosticCycles, totals.rows)
        print(totals.logLine(mode: "active_host_directory_integration_only"))
    }

    private func runExternalReplay(countingEnabled: Bool) throws -> ReplayAggregate {
        guard let path = ProcessInfo.processInfo.environment["PHYSIOAI_BOTTLE_GRAB_REPLAY_JSONL"], !path.isEmpty else {
            throw XCTSkip("Set PHYSIOAI_BOTTLE_GRAB_REPLAY_JSONL to an external raw v1_4 JSONL file to run replay.")
        }
        return try runExternalReplay(at: URL(fileURLWithPath: path), countingEnabled: countingEnabled)
    }

    private func runExternalReplay(at url: URL, countingEnabled: Bool) throws -> ReplayAggregate {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("External replay path is unavailable.")
        }

        let decoder = JSONDecoder()
        let engine = NativeBottleGrabEngine()
        engine.setCountingEnabled(countingEnabled)
        // `NativeBottleGrabEngine` intentionally does not surface the legacy
        // PhaseNet shadow-cycle total to patient UI. Recreate that exact
        // diagnostic lane here with a separate tracker so this developer-only
        // harness can distinguish a phase-order failure from a host-geometry
        // counter failure. This is aggregate-only wiring evidence, not a
        // second patient-facing counter or a label-based model evaluation.
        let phasePolicyTracker = NativePhaseNetV2Tracker()
        let phasePolicy = NativeBottleGrabFullCyclePolicy()
        phasePolicy.setCountingEnabled(countingEnabled)
        var aggregate = ReplayAggregate()
        let contents = try String(contentsOf: url, encoding: .utf8)
        for line in contents.split(whereSeparator: \.isNewline) {
            guard !line.isEmpty else { continue }
            let raw = try decoder.decode(RawFrame.self, from: Data(line.utf8))
            XCTAssertEqual(raw.schema, "physioai.bottle_grab_pose_hand_raw_frame.v1_4")
            let snapshot = raw.nativeSnapshot(sourceGeneration: 0)
            let output = engine.ingest(snapshot)
            let phaseTracking = phasePolicyTracker.ingest(snapshot)
            if phaseTracking.status == "cannot_assess" || phaseTracking.status == "reset" || phaseTracking.status == "phase_error" {
                let reason = phaseTracking.reason ?? phaseTracking.status
                phasePolicy.resetPartialCycle(reason: reason)
                aggregate.phasePolicyResets[reason, default: 0] += 1
            }
            if phaseTracking.isNewPrediction, let prediction = phaseTracking.prediction {
                if phasePolicy.ingest(prediction) {
                    aggregate.phasePolicyCycleEvents += 1
                }
            }
            aggregate.rows += 1
            if output.captureQC == "can_assess" { aggregate.assessableRows += 1 }
            if output.setupState == "positioning" { aggregate.hardBlockedRows += 1 }
            aggregate.trackerStatuses[output.phaseStatus, default: 0] += 1
            if let status = output.hostCounterStatus {
                aggregate.hostStatuses[status, default: 0] += 1
            }
            if let reason = output.hostCounterReason {
                aggregate.hostReasons[reason, default: 0] += 1
            }
            if let phase = output.phase {
                aggregate.newPredictionRows += 1
                aggregate.phaseCounts[phase, default: 0] += 1
            }
            aggregate.visiblePhaseCycles = output.totalReps
            aggregate.hostDiagnosticCycles = output.hostDiagnosticCycles ?? 0
            aggregate.phasePolicyCycles = phasePolicy.totalCycles
        }
        XCTAssertLessThanOrEqual(aggregate.assessableRows, aggregate.rows)
        XCTAssertEqual(aggregate.phasePolicyCycles, aggregate.phasePolicyCycleEvents)
        return aggregate
    }
}

private struct ReplayAggregate {
    var rows = 0
    var assessableRows = 0
    var hardBlockedRows = 0
    var newPredictionRows = 0
    var visiblePhaseCycles = 0
    var hostDiagnosticCycles = 0
    /// Shadow-only PhaseNet order policy. It is never the patient-visible
    /// repetition count; compare it to `completedCycles` only to diagnose
    /// which independent native lane dropped the true input sequence.
    var phasePolicyCycles = 0
    var phasePolicyCycleEvents = 0
    var phasePolicyResets: [String: Int] = [:]
    var phaseCounts: [String: Int] = [:]
    var trackerStatuses: [String: Int] = [:]
    var hostStatuses: [String: Int] = [:]
    var hostReasons: [String: Int] = [:]

    func logLine(mode: String) -> String {
        "[PhysioAINative][ReplayAggregate] mode=\(mode) rows=\(rows) " +
        "assessable=\(assessableRows) hardBlocked=\(hardBlockedRows) " +
        "newPredictions=\(newPredictionRows) visiblePhaseCycles=\(visiblePhaseCycles) " +
        "hostDiagnosticCycles=\(hostDiagnosticCycles) " +
        "phasePolicyCycles=\(phasePolicyCycles) phasePolicyResets=\(phasePolicyResets.sorted { $0.key < $1.key }) " +
        "phases=\(phaseCounts.sorted { $0.key < $1.key }) " +
        "tracker=\(trackerStatuses.sorted { $0.key < $1.key }) " +
        "hostStatus=\(hostStatuses.sorted { $0.key < $1.key }) " +
        "hostReason=\(hostReasons.sorted { $0.key < $1.key })"
    }
}

private struct ReplayCorpusAggregate {
    var traces = 0
    var rows = 0
    var assessableRows = 0
    var hardBlockedRows = 0
    var newPredictionRows = 0
    var visiblePhaseCycles = 0
    var hostDiagnosticCycles = 0
    var phasePolicyCycles = 0
    var phasePolicyCycleEvents = 0
    var phasePolicyResets: [String: Int] = [:]
    var trackerStatuses: [String: Int] = [:]
    var hostStatuses: [String: Int] = [:]
    var hostReasons: [String: Int] = [:]

    mutating func include(_ aggregate: ReplayAggregate) {
        traces += 1
        rows += aggregate.rows
        assessableRows += aggregate.assessableRows
        hardBlockedRows += aggregate.hardBlockedRows
        newPredictionRows += aggregate.newPredictionRows
        visiblePhaseCycles += aggregate.visiblePhaseCycles
        hostDiagnosticCycles += aggregate.hostDiagnosticCycles
        phasePolicyCycles += aggregate.phasePolicyCycles
        phasePolicyCycleEvents += aggregate.phasePolicyCycleEvents
        Self.merge(&trackerStatuses, aggregate.trackerStatuses)
        Self.merge(&hostStatuses, aggregate.hostStatuses)
        Self.merge(&hostReasons, aggregate.hostReasons)
        Self.merge(&phasePolicyResets, aggregate.phasePolicyResets)
    }

    func logLine(mode: String) -> String {
        "[PhysioAINative][ReplayCorpusAggregate] mode=\(mode) traces=\(traces) rows=\(rows) " +
        "assessable=\(assessableRows) hardBlocked=\(hardBlockedRows) " +
        "newPredictions=\(newPredictionRows) visiblePhaseCycles=\(visiblePhaseCycles) " +
        "hostDiagnosticCycles=\(hostDiagnosticCycles) " +
        "phasePolicyCycles=\(phasePolicyCycles) phasePolicyResets=\(phasePolicyResets.sorted { $0.key < $1.key }) " +
        "tracker=\(trackerStatuses.sorted { $0.key < $1.key }) " +
        "hostStatus=\(hostStatuses.sorted { $0.key < $1.key }) " +
        "hostReason=\(hostReasons.sorted { $0.key < $1.key })"
    }

    private static func merge(_ destination: inout [String: Int], _ source: [String: Int]) {
        for (key, value) in source {
            destination[key, default: 0] += value
        }
    }
}

private struct RawFrame: Decodable {
    let schema: String
    let sourceTimestampMs: Double
    let sourceMirrored: Bool?
    let anatomicalSide: String?
    let pose: RawPose?
    let hand: RawHand?

    struct RawPose: Decodable {
        let imageLandmarks: [RawLandmark]?
    }

    struct RawHand: Decodable {
        let detectedHandSide: String?
        let detectedHandScore: Float?
        let imageLandmarks: [RawLandmark]?
    }

    struct RawLandmark: Decodable {
        let x: Float?
        let y: Float?
        let z: Float?
        let visibility: Float?
    }

    func nativeSnapshot(sourceGeneration: Int) -> NativeFrameSnapshot {
        let posePoints = (pose?.imageLandmarks ?? []).map(NativeLandmark.init)
        let handPoints = (hand?.imageLandmarks ?? []).map(NativeLandmark.init)
        // A mirrored trace cannot be silently relabelled by this harness. The
        // production camera supplies the actual AVCaptureConnection mirror
        // state to MediaPipe before it creates a NativeFrameSnapshot.
        let side = sourceMirrored == true
            ? nil
            : (anatomicalSide ?? hand?.detectedHandSide)
        return NativeFrameSnapshot(
            timestampMs: Int(sourceTimestampMs.rounded()),
            sourceGeneration: sourceGeneration,
            pose: posePoints,
            hand: handPoints,
            handSide: side,
            handScore: hand?.detectedHandScore ?? 0,
            detectorLatencyMs: 0,
        )
    }
}

private extension NativeLandmark {
    init(_ raw: RawFrame.RawLandmark) {
        self.init(
            x: raw.x ?? .nan,
            y: raw.y ?? .nan,
            z: raw.z ?? 0,
            visibility: raw.visibility ?? 0,
        )
    }
}
