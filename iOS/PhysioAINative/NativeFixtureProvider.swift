import Combine
import Foundation

@MainActor
final class NativeFixtureController: ObservableObject {
    @Published private(set) var latestSnapshot: NativeFrameSnapshot?
    @Published private(set) var latestOutput: NativeBottleGrabOutput?
    @Published private(set) var frameNumber = 0
    @Published private(set) var captureSourceGeneration = 0

    // The Simulator fixture intentionally uses a scripted phase provider plus
    // a geometry-complete movement. It exercises the native shell and the
    // host completion boundary without presenting synthetic UI frames as
    // PhaseNet model-performance evidence.
    private let engine = NativeBottleGrabEngine(
        phaseTracker: NativeFixturePhaseTracker(),
        counterMode: .parallelGeometryFirst,
    )
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        engine.reset()
        frameNumber = 0
        captureSourceGeneration = 0
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                // Keep the fixture at the frozen PhaseNet source cadence
                // (approximately 15 Hz) so window/QC state is representative.
                try? await Task.sleep(nanoseconds: 67_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func reset() {
        stop()
        engine.reset()
        latestSnapshot = nil
        latestOutput = nil
        frameNumber = 0
        captureSourceGeneration = 0
    }

    func setPracticeCountingEnabled(_ enabled: Bool) {
        engine.setCountingEnabled(enabled)
        if enabled {
            // Re-run the deterministic rest → movement fixture after the
            // countdown so its single completion cannot occur before active
            // practice begins.
            frameNumber = 0
        }
    }

    func replaceCaptureSource() {
        engine.resetForNewCaptureSource()
        frameNumber = 0
        latestSnapshot = nil
        latestOutput = nil
        captureSourceGeneration += 1
    }

    private func tick() {
        frameNumber += 1
        let snapshot = NativeFixtureProvider.snapshot(
            frame: frameNumber,
            sourceGeneration: captureSourceGeneration,
        )
        latestSnapshot = snapshot
        latestOutput = engine.ingest(snapshot)
    }

    deinit {
        task?.cancel()
    }
}

/// Separate Pose-only simulator fixture for V7.2. It never uses Bottle Grab
/// state and exists only to exercise the selectable native shell; it is not
/// real-camera or model-performance evidence.
@MainActor
final class NativeSitToStandFixtureController: ObservableObject {
    @Published private(set) var latestSnapshot: NativeFrameSnapshot?
    @Published private(set) var latestOutput: NativeSitToStandOutput?
    @Published private(set) var captureSourceGeneration = 0

    private let module = NativeSitToStandV72AIModule()
    private var task: Task<Void, Never>?
    private var frameNumber = 0

    func start() {
        guard task == nil else { return }
        module.resetForNewCaptureSource()
        frameNumber = 0
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 67_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func setPracticeCountingEnabled(_ enabled: Bool) {
        module.setCountingEnabled(enabled)
        if enabled { frameNumber = 0 }
    }

    func replaceCaptureSource() {
        module.resetForNewCaptureSource()
        frameNumber = 0
        latestSnapshot = nil
        latestOutput = nil
        captureSourceGeneration += 1
    }

    private func tick() {
        frameNumber += 1
        let snapshot = NativeFixtureProvider.sitToStandSnapshot(
            frame: frameNumber,
            sourceGeneration: captureSourceGeneration,
        )
        latestSnapshot = snapshot
        latestOutput = module.ingest(snapshot)
    }

    deinit { task?.cancel() }
}

enum NativeFixtureProvider {
    /// UI-only inventory used by the simulator fixture. It mirrors the
    /// physical choices the native camera discovers; it is not a claim that a
    /// simulator owns iPhone lenses.
    static let simulatedLensOptions: [NativeLensOption] = [
        NativeLensOption(id: "ultra-wide", title: "0.5×", zoomFactor: 0.5, deviceTypeRawValue: nil),
        NativeLensOption(id: "wide", title: "1×", zoomFactor: 1, deviceTypeRawValue: nil),
        NativeLensOption(id: "tele", title: "4×", zoomFactor: 4, deviceTypeRawValue: nil),
    ]

    static func snapshot(frame: Int, sourceGeneration: Int = 0) -> NativeFrameSnapshot {
        // PhaseNet owns a 30-frame causal window. The fixture waits for that
        // window, then performs one *geometry-complete* open → reach → grasp
        // → release → return movement. It intentionally does not repeat: a
        // Simulator screenshot must not conceal a duplicate-counter bug.
        let movementFrame = max(0, frame - 31)
        let hasDeparted = (1...9).contains(movementFrame)
        let isClosed = (4...6).contains(movementFrame)
        let wristX: Float = hasDeparted ? 0.45 : 0.30
        let wristY: Float = 0.62
        var pose = Array(repeating: NativeLandmark(x: 0.5, y: 0.5, z: 0, visibility: 0), count: 33)
        // The required left arm + hand features are stable; full-body points
        // remain in frame as a soft framing-quality check.
        pose[0] = NativeLandmark(x: 0.50, y: 0.16, z: 0, visibility: 0.98)
        pose[7] = NativeLandmark(x: 0.39, y: 0.32, z: 0, visibility: 0.97)
        pose[11] = NativeLandmark(x: 0.50, y: 0.38, z: 0, visibility: 0.97)
        pose[12] = NativeLandmark(x: 0.60, y: 0.39, z: 0, visibility: 0.97)
        pose[13] = NativeLandmark(x: 0.40, y: 0.50, z: 0, visibility: 0.96)
        pose[15] = NativeLandmark(x: wristX, y: wristY, z: 0, visibility: 0.96)
        pose[17] = NativeLandmark(x: wristX + 0.01, y: wristY - 0.02, z: 0, visibility: 0.96)
        pose[19] = NativeLandmark(x: wristX + 0.02, y: wristY - 0.03, z: 0, visibility: 0.96)
        pose[21] = NativeLandmark(x: wristX + 0.03, y: wristY - 0.04, z: 0, visibility: 0.96)
        pose[23] = NativeLandmark(x: 0.43, y: 0.68, z: 0, visibility: 0.98)
        pose[24] = NativeLandmark(x: 0.57, y: 0.68, z: 0, visibility: 0.98)
        pose[25] = NativeLandmark(x: 0.44, y: 0.82, z: 0, visibility: 0.98)
        pose[26] = NativeLandmark(x: 0.56, y: 0.82, z: 0, visibility: 0.98)
        pose[27] = NativeLandmark(x: 0.44, y: 0.96, z: 0, visibility: 0.98)
        pose[28] = NativeLandmark(x: 0.56, y: 0.96, z: 0, visibility: 0.98)

        let wrist = pose[15]
        let hand = motionHand(anchoredAt: wrist, closed: isClosed)

        return NativeFrameSnapshot(
            timestampMs: frame * 67,
            sourceGeneration: sourceGeneration,
            pose: pose,
            hand: hand,
            handSide: "Left",
            handScore: 0.98,
            detectorLatencyMs: 4.2,
        )
    }

    static func sitToStandSnapshot(frame: Int, sourceGeneration: Int = 0) -> NativeFrameSnapshot {
        let movement = max(0, frame - 36)
        let hipY: Float
        switch movement {
        case 0...8:
            hipY = 0.64
        case 9...14:
            hipY = 0.64 - Float(movement - 8) * 0.030
        case 15...22:
            hipY = 0.46
        case 23...29:
            hipY = 0.46 + Float(movement - 22) * 0.026
        default:
            hipY = 0.64
        }
        var pose = Array(repeating: NativeLandmark(x: 0.5, y: 0.5, z: 0, visibility: 0.99), count: 33)
        let points: [Int: (Float, Float)] = [
            0: (0.50, 0.12),
            11: (0.40, 0.28), 12: (0.60, 0.28),
            13: (0.35, 0.42), 14: (0.65, 0.42),
            // The Sit-to-Stand reference fixture keeps both hands together.
            // This is Pose-wrist geometry only; it does not claim finger-level
            // interlacing or exercise correctness.
            15: (0.49, 0.56), 16: (0.51, 0.56),
            23: (0.42, hipY), 24: (0.58, hipY),
            25: (0.43, 0.70), 26: (0.57, 0.70),
            27: (0.44, 0.88), 28: (0.56, 0.88),
            31: (0.40, 0.94), 32: (0.60, 0.94),
        ]
        for (index, point) in points {
            pose[index] = NativeLandmark(x: point.0, y: point.1, z: 0, visibility: 0.99)
        }
        return NativeFrameSnapshot(
            timestampMs: frame * 67,
            sourceGeneration: sourceGeneration,
            pose: pose,
            hand: [],
            handSide: nil,
            handScore: 0,
            detectorLatencyMs: 0,
        )
    }

    static func fullBodySnapshot(frame: Int, sourceGeneration: Int = 0) -> NativeFrameSnapshot {
        snapshot(frame: frame, sourceGeneration: sourceGeneration)
    }

    private static func motionHand(anchoredAt wrist: NativeLandmark, closed: Bool) -> [NativeLandmark] {
        func point(_ x: Float, _ y: Float) -> NativeLandmark {
            NativeLandmark(x: x, y: y, z: 0, visibility: 0.98)
        }

        var hand = Array(repeating: wrist, count: 21)
        hand[0] = wrist
        // Keep palm scale constant so aperture/flexion changes are real
        // normalized movement evidence rather than a scale artefact.
        hand[9] = point(wrist.x, wrist.y - 0.10)
        hand[1] = point(wrist.x + 0.04, wrist.y)

        if closed {
            hand[2] = point(wrist.x + 0.07, wrist.y - 0.02)
            hand[3] = point(wrist.x + 0.04, wrist.y - 0.05)
            hand[4] = point(wrist.x + 0.01, wrist.y - 0.09)
            for base in [5, 9, 13, 17] {
                hand[base] = point(wrist.x, wrist.y - (base == 9 ? 0.10 : 0.04))
                hand[base + 1] = point(wrist.x + 0.04, wrist.y - 0.05)
                hand[base + 2] = point(wrist.x + 0.02, wrist.y - 0.09)
                hand[base + 3] = point(wrist.x + 0.01, wrist.y - 0.09)
            }
            hand[8] = point(wrist.x + 0.01, wrist.y - 0.09)
        } else {
            hand[2] = point(wrist.x + 0.08, wrist.y)
            hand[3] = point(wrist.x + 0.12, wrist.y)
            hand[4] = point(wrist.x + 0.16, wrist.y)
            for base in [5, 9, 13, 17] {
                hand[base] = point(wrist.x, wrist.y - (base == 9 ? 0.10 : 0.04))
                hand[base + 1] = point(wrist.x, wrist.y - 0.09)
                hand[base + 2] = point(wrist.x, wrist.y - 0.14)
                hand[base + 3] = point(wrist.x, wrist.y - 0.19)
            }
        }
        return hand
    }
}
