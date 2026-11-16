import AVFoundation
import Combine
import Foundation

enum NativeCameraPosition: String {
    case back
    case front

    var avPosition: AVCaptureDevice.Position {
        self == .back ? .back : .front
    }
}

/// Capture defaults are kept separate from the lens catalog so the model lane
/// can choose an inference-friendly starting view without hiding any hardware
/// lens that the user can explicitly select later.
enum NativeCaptureDefaults {
    static let defaultZoomFactor: CGFloat = 1
}

struct NativeLensOption: Identifiable, Equatable {
    let id: String
    let title: String
    let zoomFactor: CGFloat
    /// A physical lens selection is represented by its capture-device type.
    /// `nil` means keep the current logical device and only change digital zoom.
    let deviceTypeRawValue: String?
}

/// Pure policy for normalizing a UIKit-preview tap before it reaches an
/// `AVCaptureDevice`. CameraPreview owns aspect-fill/orientation conversion;
/// this type prevents invalid values reaching camera configuration.
enum NativeCaptureFocusPolicy {
    static func clampedDevicePoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(1, max(0, point.x.isFinite ? point.x : 0.5)),
            y: min(1, max(0, point.y.isFinite ? point.y : 0.5)),
        )
    }
}

/// Bottle Grab needs enough target pixels for a clear plastic bottle. This
/// applies only to capture controls; it does not change detector thresholds or
/// any model/counter behavior.
enum NativeBottleGrabCapturePolicy {
    static let bottleGrabExerciseID = "bottle_grab"
    static let bottleGrabMinimumZoom: CGFloat = 1

    static func requestedMinimumZoom(for exerciseID: String) -> CGFloat {
        exerciseID == bottleGrabExerciseID ? bottleGrabMinimumZoom : 0.1
    }

    static func clampedZoom(
        _ requested: CGFloat,
        exerciseID: String,
        deviceMinimumZoom: CGFloat,
    ) -> CGFloat {
        let safeDeviceMinimum = max(0.1, deviceMinimumZoom.isFinite ? deviceMinimumZoom : 0.1)
        let requestedMinimum = requestedMinimumZoom(for: exerciseID)
        let safeRequested = requested.isFinite ? requested : safeDeviceMinimum
        return max(safeRequested, safeDeviceMinimum, requestedMinimum)
    }

    static func visibleLensOptions(
        _ options: [NativeLensOption],
        exerciseID: String,
    ) -> [NativeLensOption] {
        guard exerciseID == bottleGrabExerciseID else { return options }
        return options.filter { $0.zoomFactor >= bottleGrabMinimumZoom }
    }
}

/// Builds the user-facing lens catalog from the devices that AVFoundation
/// actually reports on this phone. Keeping this pure makes the hardware
/// decision testable without pretending that an iOS Simulator has lenses.
enum NativeLensCatalog {
    /// Classifies a virtual-camera zoom into the hardware segment bounded by
    /// Apple's reported switch-over factors. It is deliberately pure so the
    /// source-reset boundary can be tested without device hardware.
    static func virtualLensSegment(
        zoom: CGFloat,
        minimumZoom: CGFloat,
        switchOverFactors: [CGFloat],
    ) -> Int? {
        let factors = ([minimumZoom] + switchOverFactors)
            .filter { $0.isFinite }
            .sorted()
            .reduce(into: [CGFloat]()) { result, value in
                if result.last.map({ abs($0 - value) < 0.01 }) != true {
                    result.append(value)
                }
            }
        guard factors.count > 1 else { return nil }
        return factors.lastIndex(where: { zoom >= $0 - 0.01 }) ?? 0
    }

    static func make(
        position: NativeCameraPosition,
        availableDeviceTypes: Set<String>,
        minZoom: CGFloat,
        maxZoom: CGFloat,
        displayZoomByDeviceType: [String: CGFloat] = [:],
        /// A logical dual/triple camera exposes its real hardware switch-over
        /// factors. Prefer those factors to fabricating a constituent-camera
        /// input from device names.
        virtualDeviceZoomFactors: [CGFloat] = [],
        displayZoomMultiplier: CGFloat = 1,
    ) -> [NativeLensOption] {
        // `maxZoom` is intentionally not rendered as a "Max" menu item. On
        // iPhone, maxAvailableVideoZoomFactor is an absolute digital crop
        // limit (and can be a value such as 123.8×), not a user-facing Camera
        // lens choice. Pinch zoom uses the device's effective system range;
        // this menu is reserved for physical lenses reported by AVFoundation.
        _ = maxZoom
        var options: [NativeLensOption] = []
        let wideType = AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue
        let dualWideType = AVCaptureDevice.DeviceType.builtInDualWideCamera.rawValue
        let ultraWideType = AVCaptureDevice.DeviceType.builtInUltraWideCamera.rawValue
        let telephotoType = AVCaptureDevice.DeviceType.builtInTelephotoCamera.rawValue

        func title(for type: String, fallback: String) -> String {
            guard let multiplier = displayZoomByDeviceType[type], multiplier.isFinite, multiplier > 0 else {
                return fallback
            }
            let display = abs(multiplier.rounded() - multiplier) < 0.05
                ? String(format: "%.0f", Double(multiplier))
                : String(format: "%.1f", Double(multiplier))
            return "\(display)×"
        }

        func virtualTitle(for zoomFactor: CGFloat) -> String {
            let multiplier = displayZoomMultiplier.isFinite && displayZoomMultiplier > 0
                ? displayZoomMultiplier
                : 1
            let displayZoom = max(0.1, zoomFactor * multiplier)
            let display = abs(displayZoom.rounded() - displayZoom) < 0.05
                ? String(format: "%.0f", Double(displayZoom))
                : String(format: "%.1f", Double(displayZoom))
            return "\(display)×"
        }

        // For a logical virtual camera this is the Apple-supported physical
        // lens route: set its reported switch-over factor and leave one
        // capture input alive. The options are device-derived, never guessed.
        let virtualFactors = ([minZoom] + virtualDeviceZoomFactors)
            .filter { $0.isFinite && $0 >= minZoom && $0 <= maxZoom }
            .sorted()
            .reduce(into: [CGFloat]()) { result, value in
                if result.last.map({ abs($0 - value) < 0.01 }) != true {
                    result.append(value)
                }
            }
        if position == .back, virtualFactors.count > 1 {
            return virtualFactors.enumerated().map { index, factor in
                NativeLensOption(
                    id: "virtual-\(index)-\(String(format: "%.3f", Double(factor)))",
                    title: virtualTitle(for: factor),
                    zoomFactor: factor,
                    deviceTypeRawValue: nil,
                )
            }
        }

        if position == .back {
            if availableDeviceTypes.contains(ultraWideType) {
                options.append(NativeLensOption(
                    id: "ultra-wide",
                    title: title(for: ultraWideType, fallback: "Ultra-wide"),
                    zoomFactor: 1,
                    deviceTypeRawValue: ultraWideType,
                ))
            }
            if availableDeviceTypes.contains(wideType) {
                options.append(NativeLensOption(
                    id: "wide",
                    title: title(for: wideType, fallback: "1×"),
                    zoomFactor: 1,
                    deviceTypeRawValue: wideType,
                ))
            } else if availableDeviceTypes.contains(dualWideType) {
                options.append(NativeLensOption(
                    id: "wide",
                    title: title(for: dualWideType, fallback: "1×"),
                    zoomFactor: 1,
                    deviceTypeRawValue: dualWideType,
                ))
            }
            if availableDeviceTypes.contains(telephotoType) {
                options.append(NativeLensOption(
                    id: "tele",
                    title: title(for: telephotoType, fallback: "Telephoto"),
                    zoomFactor: 1,
                    deviceTypeRawValue: telephotoType,
                ))
            }
        } else {
            options.append(NativeLensOption(
                id: "wide",
                title: "1×",
                zoomFactor: max(0.1, minZoom),
                deviceTypeRawValue: nil,
            ))
        }

        if options.isEmpty {
            options.append(NativeLensOption(
                id: "wide",
                title: "1×",
                zoomFactor: max(0.1, minZoom),
                deviceTypeRawValue: nil,
            ))
        }
        return options
    }
}

enum NativeZoomPolicy {
    /// Keep pinch zoom inside the range Apple recommends for the active
    /// format when that recommendation exists. The raw AVFoundation maximum
    /// remains the fallback for older devices/formats, but is never shown as
    /// a fabricated lens button.
    static func effectiveMax(rawMax: CGFloat, recommendedMax: CGFloat?) -> CGFloat {
        let safeRaw = rawMax.isFinite && rawMax >= 1 ? rawMax : 1
        guard let recommendedMax,
              recommendedMax.isFinite,
              recommendedMax >= 1 else { return safeRaw }
        return min(safeRaw, recommendedMax)
    }
}

/// The frozen PhaseNet V2 sidecar consumes a causal 15 Hz trace.  The camera
/// transport must therefore request real 15 Hz source frames when the active
/// AVCapture format supports them; it must never fabricate timestamps,
/// interpolate landmarks, or pretend a faster device-default stream is a
/// model-ready 15 Hz trace.
enum NativeInferenceCaptureCadencePolicy {
    static let targetFramesPerSecond: Double = 15

    static func supportsTargetFrameRate(
        minimum: Double,
        maximum: Double,
    ) -> Bool {
        minimum.isFinite
            && maximum.isFinite
            && minimum <= targetFramesPerSecond
            && maximum >= targetFramesPerSecond
    }
}

enum NativeMediaPipeDelegateMode: Equatable {
    case automatic
    case gpu
    case cpu
}

enum NativeMediaPipeDelegatePreference {
    /// Force flags are intentionally Debug-only A/B controls. The V7 Bottle
    /// Detector route applies its own CPU-only crash-containment policy after
    /// this generic preference is resolved.
    static func resolve(arguments: [String]) -> NativeMediaPipeDelegateMode {
#if DEBUG
        if arguments.contains("--native-mediapipe-cpu") { return .cpu }
        if arguments.contains("--native-mediapipe-gpu") { return .gpu }
#endif
        return .automatic
    }
}

/// Aggregate-only evidence for comparing camera/detector configurations. It
/// deliberately contains no frames, landmarks, identifiers, or patient data.
struct NativeMediaPipeTelemetry: Equatable {
    private(set) var submittedFrames = 0
    private(set) var coalescedFrames = 0
    private(set) var poseCallbacks = 0
    private(set) var handCallbacks = 0
    private(set) var joinedSnapshots = 0
    private(set) var emptyHandSnapshots = 0
    private(set) var selectedLeftSnapshots = 0
    private(set) var fallbackOrNoLeftSnapshots = 0
    private(set) var totalLatencyMs: Double = 0

    var averageLatencyMs: Double {
        guard joinedSnapshots > 0 else { return 0 }
        return totalLatencyMs / Double(joinedSnapshots)
    }

    mutating func recordSubmitted() {
        submittedFrames += 1
    }

    mutating func recordCoalesced() {
        coalescedFrames += 1
    }

    mutating func recordPoseCallback() {
        poseCallbacks += 1
    }

    mutating func recordHandCallback(candidateCount: Int) {
        handCallbacks += 1
        _ = candidateCount
    }

    mutating func recordJoined(handCandidateCount: Int, selectedSide: String?, latencyMs: Double) {
        joinedSnapshots += 1
        if handCandidateCount == 0 { emptyHandSnapshots += 1 }
        if selectedSide?.localizedCaseInsensitiveCompare("Left") == .orderedSame {
            selectedLeftSnapshots += 1
        } else {
            fallbackOrNoLeftSnapshots += 1
        }
        if latencyMs.isFinite { totalLatencyMs += max(0, latencyMs) }
    }

    mutating func reset() {
        self = NativeMediaPipeTelemetry()
    }
}

/// A one-element, thread-safe mailbox for high-frequency pinch updates.
///
/// A camera lens tap is an explicit user choice and must win over a stale
/// pinch callback that has not reached the serial capture-session queue yet.
/// `cancelPending()` intentionally leaves a previously scheduled consumer in
/// place: it will observe `nil`, clear `isScheduled`, and cannot overwrite the
/// lens selection. A genuinely new pinch submitted afterwards schedules (or
/// joins) the next normal application.
final class NativeZoomRequestMailbox {
    private let lock = NSLock()
    private var pending: CGFloat?
    private var isScheduled = false

    /// Stores the newest request and returns whether the caller must enqueue a
    /// consumer. Intermediate pinch values are deliberately coalesced.
    @discardableResult
    func submit(_ requested: CGFloat) -> Bool {
        lock.lock()
        pending = requested
        let shouldSchedule = !isScheduled
        if shouldSchedule { isScheduled = true }
        lock.unlock()
        return shouldSchedule
    }

    /// Takes the latest request for one serial camera-session callback.
    func takeNewest() -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        let requested = pending
        pending = nil
        isScheduled = false
        return requested
    }

    /// Cancels only stale queued gesture work. The scheduled consumer remains
    /// harmless and releases its scheduling flag when it observes `nil`.
    func cancelPending() {
        lock.lock()
        pending = nil
        lock.unlock()
    }
}

/// Converts each camera input into a monotonic MediaPipe/model timeline while
/// preserving the real frame intervals inside that input. A replacement
/// camera/lens begins a fresh generation, so callbacks from an older input can
/// never reuse the same join key as the new stream.
struct NativeSourceTimestampClock {
    private(set) var generation = 0
    private(set) var lastRawTimestampMs: Int?
    private(set) var lastTimelineTimestampMs: Int?
    private var offsetMs = 0

    mutating func beginNewSource() {
        generation += 1
        lastRawTimestampMs = nil
        offsetMs = 0
    }

    mutating func normalize(rawTimestampMs: Int) -> Int? {
        guard rawTimestampMs >= 0 else { return nil }
        if let lastRawTimestampMs, rawTimestampMs <= lastRawTimestampMs {
            return nil
        }
        if lastRawTimestampMs == nil, let lastTimelineTimestampMs {
            // The engine resets at a source swap, so this gap is not used as
            // a model sample interval. It only guarantees a non-colliding
            // callback key for the next capture generation.
            offsetMs = lastTimelineTimestampMs + 1_000 - rawTimestampMs
        }
        let timelineTimestampMs = rawTimestampMs + offsetMs
        guard timelineTimestampMs > (lastTimelineTimestampMs ?? Int.min) else {
            return nil
        }
        lastRawTimestampMs = rawTimestampMs
        lastTimelineTimestampMs = timelineTimestampMs
        return timelineTimestampMs
    }
}

/// DEBUG candidate evidence must never produce one console write per detector
/// callback. Keep the decision pure so it can be unit-tested independently of
/// AVFoundation and so live diagnosis does not add avoidable logging pressure.
struct NativeCandidateTraceLogPolicy {
    static let intervalMs = 1_000

    static func shouldEmit(
        previousState: String?,
        previousTimestampMs: Int?,
        nextState: String,
        timestampMs: Int,
    ) -> Bool {
        guard previousState == nextState,
              let previousTimestampMs else {
            return true
        }
        return timestampMs - previousTimestampMs >= intervalMs
    }
}

final class CameraSession: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var authorization: AVAuthorizationStatus = .notDetermined
    @Published private(set) var cameraStatus = "Waiting for camera permission"
    @Published private(set) var detectorStatus = "Loading native MediaPipe"
    /// This is source transport telemetry for the development camera lane.
    /// It is intentionally separate from MediaPipe inference latency and is
    /// not a model score or a claim that PhaseNet has a valid temporal window.
    @Published private(set) var inferenceCadenceStatus = "15 fps requested"
    @Published private(set) var latestSnapshot: NativeFrameSnapshot?
    @Published private(set) var latestOutput: NativeBottleGrabOutput?
    /// Aggregate ObjectDetector status for the current camera generation. It
    /// is presentation/diagnostic evidence only and never alters the counter.
    @Published private(set) var latestBottleDetectorDiagnostics: NativeBottleDetectorDiagnostics?
    /// Secondary Hand-only output. This is presentation/comment evidence and
    /// must never be read by the authoritative Bottle Grab rep counter.
    @Published private(set) var latestFingerComment: NativeBottleGrabCuePreview?
    @Published private(set) var latestSitToStandOutput: NativeSitToStandOutput?
    // The native Patient flow starts with the rear camera so the user can
    // frame the exercise without first turning the phone around.
    @Published private(set) var position: NativeCameraPosition = .back
    @Published private(set) var lensOptions: [NativeLensOption] = []
    @Published private(set) var selectedLensTitle = "1×"
    @Published private(set) var currentZoomFactor: CGFloat = 1
    @Published private(set) var minZoomFactor: CGFloat = 1
    @Published private(set) var maxZoomFactor: CGFloat = 1
    @Published private(set) var activeDeviceName = ""
    /// The portrait aspect ratio of the actual camera image. LandmarkOverlay
    /// uses this with the same aspect-fill crop as CameraPreview so points do
    /// not stretch into a different coordinate space from the video.
    @Published private(set) var previewSourceAspectRatio: CGFloat = NativePreviewCoordinateMapper.portraitHDAspectRatio
    @Published private(set) var droppedFrames = 0
    /// Changes whenever a front/back or physical/virtual lens transition
    /// invalidates temporal evidence. SwiftUI uses this to return an active
    /// session to positioning instead of silently continuing a stale cycle.
    @Published private(set) var captureSourceGeneration = 0

    let captureSession = AVCaptureSession()
    let previewLayer = AVCaptureVideoPreviewLayer()

    private let sessionQueue = DispatchQueue(label: "physioai.native.camera.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "physioai.native.camera.frames", qos: .userInitiated)
    // V7.3.5 Debug defaults Bottle Grab to the frozen Baseline #5 + V7.1 TTS
    // presentation path. V6 remains a separate local rollback branch.
    private let v7BottleDetectorEnabled: Bool
    private let engine: NativeExerciseEngine
    private let engineLock = NSLock()
    private var pipeline: MediaPipePipeline?
    private var v7AIModule: NativeBottleGrabV7AIModule?
    private var sitToStandAIModule: NativeSitToStandV72AIModule?
    private var selectedExerciseID = "bottle_grab"
    private var videoOutput: AVCaptureVideoDataOutput?
    /// Passive recording sidecar. It receives the same sample buffer on its
    /// own utility queue and never feeds data back into inference or counting.
    private var sessionVideoRecorder: NativeSessionVideoRecorder?
    private var currentDevice: AVCaptureDevice?
    private var preferredDeviceType: AVCaptureDevice.DeviceType?
    /// Owned by sessionQueue. NativePracticeView sets this before starting an
    /// exercise so Bottle Grab cannot remain at the 0.5× capture scale seen in
    /// the physical V7.3.4 screenshot.
    private var minimumCaptureZoom: CGFloat = 0.1
    /// MagnificationGesture can deliver many updates per display frame. Keep
    /// the session queue bounded by applying only the newest requested zoom;
    /// physical lens taps remain explicit, one-shot transactions.
    private let zoomRequests = NativeZoomRequestMailbox()
    /// Session-queue-owned position. `position` is the published UI value and
    /// is only changed on the main queue.
    private var configuredPosition: NativeCameraPosition = .back
    private var isConfigured = false
    /// Accessed only from `frameQueue` (or through `frameQueue.sync` during a
    /// source reset), so raw camera timestamps and callback keys stay in one
    /// serial timeline.
    private var sourceTimestampClock = NativeSourceTimestampClock()
    /// MediaPipe invokes its live-stream delegates asynchronously. This lock
    /// protects the capture-source generation seen by those callbacks while
    /// `sourceTimestampClock` itself remains exclusively frame-queue-owned.
    private let sourceStateLock = NSLock()
    private var activeSourceGeneration = 0
    private var didLogFirstFrame = false
    private var didLogFirstResult = false
#if DEBUG
    /// Keep physical-device troubleshooting observable without dumping raw
    /// landmarks or camera frames into the Xcode/device console.  A line is
    /// emitted only when a meaningful QC/phase/counter state changes.
    private var lastBottleGrabDiagnosticSignature: String?
    private var lastBottleDetectorDiagnosticSignature: String?
    /// Candidate metrics can change at the detector cadence. Rate-limit the
    /// aggregate-only trace so a physical run remains inspectable without
    /// turning Xcode logging itself into a source of camera latency.
    private var lastCandidateTraceState: String?
    private var lastCandidateTraceTimestampMs = Int.min
#endif

    override init() {
        let v7BottleDetectorEnabled = NativeBottleDetectorContract.isV7Enabled
        self.v7BottleDetectorEnabled = v7BottleDetectorEnabled
        self.engine = NativeExerciseEngine(
            counterMode: v7BottleDetectorEnabled ? .bottleDetectorProximity : .parallelGeometryFirst,
        )
        super.init()
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
        previewLayer.session = captureSession
        previewLayer.videoGravity = .resizeAspectFill
        if v7BottleDetectorEnabled {
            v7AIModule = NativeBottleGrabV7AIModule(
                onOutput: { [weak self] snapshot, output in
                    self?.consume(snapshot, outputOverride: output)
                },
                onHandComment: { [weak self] snapshot, cue in
                    self?.consumeFingerComment(snapshot, cue: cue)
                },
                onBottleDiagnostics: { [weak self] diagnostics in
                    self?.consumeBottleDiagnostics(diagnostics)
                },
                onStatus: { [weak self] status in
                    DispatchQueue.main.async {
                        self?.detectorStatus = status
                    }
                },
            )
            detectorStatus = v7AIModule?.setupError ?? "Native App V7 Baseline #5 AI module ready"
        } else {
            pipeline = MediaPipePipeline(
                onSnapshot: { [weak self] snapshot in
                    self?.consume(snapshot)
                },
                onStatus: { [weak self] status in
                    DispatchQueue.main.async {
                        self?.detectorStatus = status
                    }
                },
            )
            if let error = pipeline?.setupError {
                detectorStatus = error
            }
        }
    }

    func attachSessionVideoRecorder(_ recorder: NativeSessionVideoRecorder?) {
        frameQueue.async { [weak self] in
            self?.sessionVideoRecorder = recorder
        }
    }

    func setExercise(_ exercise: NativeExercise) {
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.selectedExerciseID = exercise.id
            self.engineLock.lock()
            if exercise.id == NativeSitToStandV72AIModule.exerciseID {
                self.ensureSitToStandModule()
                self.sitToStandAIModule?.resetForNewSession()
            } else {
                self.engine.configure(exercise: exercise)
                if self.v7BottleDetectorEnabled {
                    self.v7AIModule?.configure(exercise: exercise)
                }
            }
            self.engineLock.unlock()
        }
    }

    /// Enables only the patient-facing repetition boundary after the visible
    /// countdown. MediaPipe/PhaseNet may keep warming up before this point,
    /// but no completed rep is allowed to bridge the countdown.
    func setPracticeCountingEnabled(_ enabled: Bool) {
        frameQueue.async { [weak self] in
            guard let self else { return }
            self.engineLock.lock()
            if self.selectedExerciseID == NativeSitToStandV72AIModule.exerciseID {
                self.sitToStandAIModule?.setCountingEnabled(enabled)
            } else if self.v7BottleDetectorEnabled {
                self.v7AIModule?.setCountingEnabled(enabled)
            } else {
                self.engine.setCountingEnabled(enabled)
            }
            self.engineLock.unlock()
        }
    }

    /// Read the current Bottle Grab V8 evidence snapshot for a local developer
    /// validation/export flow. The underlying observer owns a lock and this
    /// method neither writes storage nor changes the active counter/comment
    /// state. `nil` means that this build has no V7 Bottle Grab module.
    func currentBottleGrabFaultEvidenceRecord() -> NativeFaultEvidenceRecord? {
        guard v7BottleDetectorEnabled else { return nil }
        return v7AIModule?.currentFaultEvidenceRecord()
    }

    /// JSON counterpart of `currentBottleGrabFaultEvidenceRecord()`. It is
    /// intentionally process-local: the caller decides whether and how an
    /// already de-identified record is handed to another system.
    func encodedCurrentBottleGrabFaultEvidence() throws -> Data? {
        guard v7BottleDetectorEnabled else { return nil }
        return try v7AIModule?.encodedCurrentFaultEvidenceRecord()
    }

    /// Local-only per-repetition rule measurement for a host integration or
    /// the bundled JSON visualizer. This does not write storage or call an API.
    func currentBottleGrabRuleBasedSessionRecord() -> NativeRuleBasedSessionRecord? {
        guard v7BottleDetectorEnabled else { return nil }
        return v7AIModule?.currentRuleBasedSessionRecord()
    }

    func encodedCurrentBottleGrabRuleBasedSession() throws -> Data? {
        guard v7BottleDetectorEnabled else { return nil }
        return try v7AIModule?.encodedCurrentRuleBasedSessionRecord()
    }

    /// Used only while ending a local Bottle Grab plan session. Counting has
    /// already been stopped by the host; this remains local and does not send
    /// or persist any data.
    func encodedFinalizedBottleGrabRuleBasedSession() throws -> Data? {
        guard v7BottleDetectorEnabled else { return nil }
        return try v7AIModule?.encodedFinalizedCurrentRuleBasedSessionRecord()
    }

    /// Local-only Sit-to-Stand evidence uses the existing Pose-only derived
    /// geometry contract. It neither sends data nor alters the counter.
    func currentSitToStandRuleBasedSessionRecord() -> RuleBasedSessionRecord? {
        sitToStandAIModule?.currentRuleBasedSessionRecord()
    }

    func encodedCurrentSitToStandRuleBasedSession() throws -> Data? {
        try sitToStandAIModule?.encodedCurrentRuleBasedSessionRecord()
    }

    /// The practice host calls this only after it freezes counting while ending
    /// a local plan. The recorder returns completed counter-owned repetitions
    /// and does not manufacture an incomplete/fault event from a partial cycle.
    func encodedFinalizedSitToStandRuleBasedSession() throws -> Data? {
        try sitToStandAIModule?.encodedFinalizedCurrentRuleBasedSessionRecord()
    }

    func requestPermissionAndStart() {
        print("[PhysioAINative] requestPermissionAndStart called")
        let current = AVCaptureDevice.authorizationStatus(for: .video)
        print("[PhysioAINative] camera authorization raw=\(current.rawValue)")
        DispatchQueue.main.async { self.authorization = current }
        switch current {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.authorization = granted ? .authorized : .denied
                }
                if granted { self.configureAndStart() }
            }
        case .denied, .restricted:
            DispatchQueue.main.async { self.cameraStatus = "Camera permission is denied. Open Settings to continue." }
        @unknown default:
            DispatchQueue.main.async { self.cameraStatus = "Camera permission is unavailable." }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning { self.captureSession.stopRunning() }
            self.frameQueue.sync {
                self.engineLock.lock()
                if self.selectedExerciseID == NativeSitToStandV72AIModule.exerciseID {
                    self.sitToStandAIModule?.resetForNewCaptureSource()
                } else if self.v7BottleDetectorEnabled {
                    self.v7AIModule?.resetForNewCaptureSource()
                } else {
                    self.engine.reset()
                }
                self.engineLock.unlock()
                self.beginNewFrameSourceOnFrameQueue()
            }
            DispatchQueue.main.async {
                self.latestSnapshot = nil
                self.latestOutput = nil
                self.latestBottleDetectorDiagnostics = nil
                self.latestFingerComment = nil
                self.latestSitToStandOutput = nil
                if self.authorization == .authorized { self.cameraStatus = "Camera paused" }
            }
        }
    }

    func switchCamera() {
        let next: NativeCameraPosition = position == .back ? .front : .back
        reconfigure(position: next)
    }

    /// Applies a continuous pinch zoom on the active AVCaptureDevice. This is
    /// deliberately separate from the physical-lens picker: iPhone's Camera
    /// app uses the physical lenses reported by AVFoundation and a continuous
    /// zoom control between them.
    func setZoomFactor(_ requested: CGFloat) {
        let shouldSchedule = zoomRequests.submit(requested)
        guard shouldSchedule else { return }
        sessionQueue.async { [weak self] in
            self?.applyNewestZoomRequest()
        }
    }

    /// Updates the exercise-specific lower zoom bound without replacing the
    /// camera input. If a currently running device is below the new bound, the
    /// zoom is raised through the existing safe zoom/lens-boundary path.
    func setCaptureMinimumZoom(_ requested: CGFloat) {
        let minimum = max(0.1, requested.isFinite ? requested : 0.1)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.minimumCaptureZoom = minimum
            guard let device = self.currentDevice else { return }
            let priorZoom = device.videoZoomFactor
            guard priorZoom < minimum else {
                self.updateLensOptions(for: device, position: self.configuredPosition)
                return
            }
            guard self.applyZoomFactor(minimum, on: device, titleOverride: nil) else { return }
            self.resetForVirtualLensSegmentChangeIfNeeded(
                device: device,
                from: priorZoom,
                to: device.videoZoomFactor,
            )
            self.updateLensOptions(for: device, position: self.configuredPosition)
        }
    }

    /// Applies single-tap focus/exposure using the device point converted by
    /// the mounted `CameraPreview` layer. It deliberately does not alter the
    /// capture input, source generation, inference pipeline, or counter.
    func focus(at point: CGPoint) {
        let devicePoint = NativeCaptureFocusPolicy.clampedDevicePoint(point)
        sessionQueue.async { [weak self] in
            guard let self,
                  self.captureSession.isRunning,
                  let device = self.currentDevice else {
                return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = devicePoint
                    if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    } else if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = devicePoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    } else if device.isExposureModeSupported(.autoExpose) {
                        device.exposureMode = .autoExpose
                    }
                }
#if DEBUG
                let x = String(format: "%.3f", devicePoint.x)
                let y = String(format: "%.3f", devicePoint.y)
                print("[PhysioAINative] focus point x=\(x) y=\(y) device=\(device.localizedName)")
#endif
            } catch {
#if DEBUG
                print("[PhysioAINative] focus request failed device=\(device.localizedName) error=\(error.localizedDescription)")
#endif
            }
        }
    }

    private func applyNewestZoomRequest() {
        let requested = zoomRequests.takeNewest()
        guard let requested, let device = currentDevice else { return }
        let priorZoom = device.videoZoomFactor
        guard applyZoomFactor(requested, on: device, titleOverride: nil) else { return }
        resetForVirtualLensSegmentChangeIfNeeded(
            device: device,
            from: priorZoom,
            to: device.videoZoomFactor,
        )
    }

    func selectLens(_ option: NativeLensOption) {
        // A button tap is a discrete user choice. Discard any retained pinch
        // value before queuing the lens work, otherwise a late gesture update
        // can immediately overwrite the chosen physical/virtual lens.
        zoomRequests.cancelPending()
        sessionQueue.async { [weak self] in
            guard let self, let device = self.currentDevice else { return }
#if DEBUG
            let requestedType = option.deviceTypeRawValue ?? "logical"
            print("[PhysioAINative] lens requested title=\(option.title) id=\(option.id) type=\(requestedType) current=\(device.localizedName) currentType=\(device.deviceType.rawValue)")
#endif
            if let raw = option.deviceTypeRawValue {
                let type = AVCaptureDevice.DeviceType(rawValue: raw)
                if type != device.deviceType {
#if DEBUG
                    print("[PhysioAINative] lens request requires input replacement -> \(type.rawValue)")
#endif
                    self.reconfigure(
                        position: self.configuredPosition,
                        preferredType: type,
                        requestedZoom: option.zoomFactor,
                        selectedTitle: option.title,
                    )
                    return
                }
            }
            let priorZoom = device.videoZoomFactor
            guard self.applyZoomFactor(option.zoomFactor, on: device, titleOverride: option.title) else { return }
            self.resetForVirtualLensSegmentChangeIfNeeded(
                device: device,
                from: priorZoom,
                to: device.videoZoomFactor,
            )
#if DEBUG
            print("[PhysioAINative] lens applied title=\(option.title) zoom=\(device.videoZoomFactor) device=\(device.localizedName)")
#endif
        }
    }

    @discardableResult
    private func applyZoomFactor(_ requested: CGFloat, on device: AVCaptureDevice, titleOverride: String?) -> Bool {
        // Do not erase a device-reported 0.5× ultra-wide minimum. The
        // previous `max(1, …)` clamp made a visible 0.5× option impossible
        // to apply even when AVFoundation exposed it.
        let minZoom = max(0.1, device.minAvailableVideoZoomFactor, minimumCaptureZoom)
        let rawMax = max(minZoom, device.maxAvailableVideoZoomFactor)
        let effectiveMax = NativeZoomPolicy.effectiveMax(
            rawMax: rawMax,
            recommendedMax: recommendedMaxZoom(for: device),
        )
        let clamped = min(max(requested.isFinite ? requested : minZoom, minZoom), effectiveMax)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            let title = titleOverride ?? displayZoomTitle(for: device, zoomFactor: clamped)
            DispatchQueue.main.async {
                self.currentZoomFactor = clamped
                self.minZoomFactor = minZoom
                self.maxZoomFactor = effectiveMax
                self.selectedLensTitle = title
                self.activeDeviceName = device.localizedName
                self.cameraStatus = "Live · \(self.position == .back ? "back" : "front") · \(title)"
            }
            return true
        } catch {
#if DEBUG
            print("[PhysioAINative] zoom apply failed requested=\(requested) error=\(error.localizedDescription)")
#endif
            DispatchQueue.main.async { self.cameraStatus = "Zoom unavailable: \(error.localizedDescription)" }
            return false
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !self.isConfigured { self.configureSession() }
            guard !self.captureSession.isRunning else { return }
            self.captureSession.startRunning()
            DispatchQueue.main.async {
                self.cameraStatus = "Live · \(self.position == .back ? "back" : "front") · \(self.selectedLensTitle)"
            }
        }
    }

    private func configureSession() {
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        guard let device = findDevice(position: configuredPosition.avPosition, preferredType: preferredDeviceType) else {
            DispatchQueue.main.async { self.cameraStatus = "No compatible camera found." }
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device), captureSession.canAddInput(input) else {
            DispatchQueue.main.async { self.cameraStatus = "Could not add the camera input." }
            return
        }
        captureSession.addInput(input)
        // Landmark inference only needs a stable full-body + working-hand
        // image. 720p substantially reduces the two-detector workload on a
        // real device while retaining more than enough spatial detail for the
        // bundled Lite Pose and Hand models. Fall back only when the selected
        // hardware/format cannot provide it.
        captureSession.sessionPreset = captureSession.canSetSessionPreset(.hd1280x720)
            ? .hd1280x720
            : .high
        currentDevice = device
        preferredDeviceType = device.deviceType
        // Bottle Grab inference starts at the physical wide view. A 0.5×
        // ultra-wide choice remains available, but it is not a reliable
        // default for the 21-point Hand Landmarker because the hand occupies
        // fewer pixels even when Pose still sees the full body.
        _ = applyZoomFactor(NativeCaptureDefaults.defaultZoomFactor, on: device, titleOverride: nil)
        configureInferenceCaptureCadence(for: device)
        print("[PhysioAINative] camera configured device=\(device.localizedName) type=\(device.deviceType.rawValue)")

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.setSampleBufferDelegate(self, queue: frameQueue)
        guard captureSession.canAddOutput(output) else {
            DispatchQueue.main.async { self.cameraStatus = "Could not add the camera frame output." }
            return
        }
        captureSession.addOutput(output)
        videoOutput = output
        frameQueue.sync {
            beginNewFrameSourceOnFrameQueue()
        }
        applyPortraitOrientation(for: configuredPosition)
        publishPreviewSourceAspectRatio(for: device)
        updateLensOptions(for: device, position: configuredPosition)
        isConfigured = true
    }

    private func reconfigure(
        position newPosition: NativeCameraPosition,
        preferredType: AVCaptureDevice.DeviceType? = nil,
        requestedZoom: CGFloat? = nil,
        selectedTitle: String? = nil,
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
#if DEBUG
            let requestedType = preferredType?.rawValue ?? "default"
            print("[PhysioAINative] reconfigure requested position=\(newPosition.rawValue) preferred=\(requestedType)")
#endif
            if !self.isConfigured {
                self.configuredPosition = newPosition
                self.preferredDeviceType = preferredType
                DispatchQueue.main.async { self.position = newPosition }
                self.configureAndStart()
                return
            }

            // Resolve and construct the replacement before touching the live
            // session. The previous implementation removed the old input
            // first; when the new physical lens was unavailable it left the
            // session without a camera and only changed the status label.
            guard let device = self.findDevice(position: newPosition.avPosition, preferredType: preferredType) else {
#if DEBUG
                let requestedType = preferredType?.rawValue ?? "default"
                print("[PhysioAINative] reconfigure failed: no device for position=\(newPosition.rawValue) preferred=\(requestedType)")
#endif
                DispatchQueue.main.async {
                    self.cameraStatus = newPosition == .back
                        ? "Rear camera unavailable. Keeping current camera."
                        : "Front camera unavailable. Keeping current camera."
                }
                return
            }
            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
#if DEBUG
                print("[PhysioAINative] reconfigure failed: input init device=\(device.localizedName) type=\(device.deviceType.rawValue) error=\(error.localizedDescription)")
#endif
                DispatchQueue.main.async { self.cameraStatus = "Lens change unavailable: \(error.localizedDescription)" }
                return
            }

            let oldInput = self.captureSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first
            self.captureSession.beginConfiguration()
            if let oldInput { self.captureSession.removeInput(oldInput) }
            guard self.captureSession.canAddInput(input) else {
#if DEBUG
                print("[PhysioAINative] reconfigure failed: capture session rejected device=\(device.localizedName) type=\(device.deviceType.rawValue)")
#endif
                if let oldInput, self.captureSession.canAddInput(oldInput) {
                    self.captureSession.addInput(oldInput)
                }
                self.captureSession.commitConfiguration()
                DispatchQueue.main.async {
                    self.cameraStatus = "Lens/camera unavailable. Keeping current camera."
                }
                return
            }
            self.captureSession.addInput(input)
            self.currentDevice = device
            self.configuredPosition = newPosition
            self.preferredDeviceType = preferredType ?? device.deviceType
            self.configureInferenceCaptureCadence(for: device)
            let previousTimestamp = self.frameQueue.sync { () -> Int in
                let previous = self.sourceTimestampClock.lastTimelineTimestampMs ?? 0
                self.beginNewFrameSourceOnFrameQueue()
                self.engineLock.lock()
                if self.v7BottleDetectorEnabled {
                    self.v7AIModule?.resetForNewCaptureSource()
                } else {
                    self.engine.resetForNewCaptureSource()
                }
                self.engineLock.unlock()
                return previous
            }
            _ = self.applyZoomFactor(requestedZoom ?? 1, on: device, titleOverride: selectedTitle)
            self.updateLensOptions(for: device, position: newPosition, selectedTitleOverride: selectedTitle)
            self.applyPortraitOrientation(for: newPosition)
            self.publishPreviewSourceAspectRatio(for: device)
            self.captureSession.commitConfiguration()
            DispatchQueue.main.async {
                self.position = newPosition
                self.latestSnapshot = nil
                self.latestOutput = nil
                self.latestBottleDetectorDiagnostics = nil
                self.latestFingerComment = nil
                self.activeDeviceName = device.localizedName
                self.cameraStatus = "Live · \(newPosition == .back ? "back" : "front") · \(self.selectedLensTitle)"
            }
#if DEBUG
            print("[PhysioAINative] reconfigure applied device=\(device.localizedName) type=\(device.deviceType.rawValue) selected=\(self.selectedLensTitle)")
#endif
#if DEBUG
            print("[PhysioAINative] camera reconfigured from timestamp=\(previousTimestamp) device=\(device.localizedName) type=\(device.deviceType.rawValue)")
#endif
        }
    }

    /// Keep the camera source close to the frozen PhaseNet V2 training
    /// cadence.  This is a best-effort hardware request: an unsupported
    /// device format remains live, but its diagnostic status makes clear that
    /// it cannot be assumed to satisfy the exact 15 Hz model window.
    private func configureInferenceCaptureCadence(for device: AVCaptureDevice) {
        let target = NativeInferenceCaptureCadencePolicy.targetFramesPerSecond
        let supportsTarget = device.activeFormat.videoSupportedFrameRateRanges.contains {
            NativeInferenceCaptureCadencePolicy.supportsTargetFrameRate(
                minimum: $0.minFrameRate,
                maximum: $0.maxFrameRate,
            )
        }
        guard supportsTarget else {
            DispatchQueue.main.async {
                self.inferenceCadenceStatus = "15 fps unavailable on current camera format"
            }
#if DEBUG
            print("[PhysioAINative] 15 fps unavailable device=\(device.localizedName) format=\(device.activeFormat)")
#endif
            return
        }

        let duration = CMTime(value: 1, timescale: CMTimeScale(Int32(target)))
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
            device.unlockForConfiguration()
            DispatchQueue.main.async {
                self.inferenceCadenceStatus = "15 fps source active"
            }
#if DEBUG
            print("[PhysioAINative] inference cadence configured target=\(Int(target))fps device=\(device.localizedName)")
#endif
        } catch {
            DispatchQueue.main.async {
                self.inferenceCadenceStatus = "15 fps request failed: \(error.localizedDescription)"
            }
#if DEBUG
            print("[PhysioAINative] inference cadence request failed device=\(device.localizedName) error=\(error.localizedDescription)")
#endif
        }
    }

    private func findDevice(position: AVCaptureDevice.Position, preferredType: AVCaptureDevice.DeviceType? = nil) -> AVCaptureDevice? {
        let devices = discoveredDevices(position: position)
        if let preferredType,
           let preferred = devices.first(where: { $0.deviceType == preferredType }) {
            return preferred
        }
        return devices.first(where: { $0.deviceType == .builtInTripleCamera })
            ?? devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? devices.first
    }

    /// Preserve the hardware inventory for fallback discovery and diagnostics.
    /// A logical dual/triple camera's real lens choices are normally applied
    /// through `virtualDeviceSwitchOverVideoZoomFactors`, not by guessing that
    /// an arbitrary constituent camera can replace the capture input.
    private func discoveredDevices(position: AVCaptureDevice.Position) -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInTripleCamera,
                .builtInDualWideCamera,
                .builtInDualCamera,
                .builtInWideAngleCamera,
                .builtInUltraWideCamera,
                .builtInTelephotoCamera,
                .builtInTrueDepthCamera,
            ],
            mediaType: .video,
            position: position,
        )

        var seen = Set<String>()
        var flattened: [AVCaptureDevice] = []

        func append(_ device: AVCaptureDevice) {
            guard seen.insert(device.uniqueID).inserted else { return }
            flattened.append(device)
            for constituent in device.constituentDevices {
                append(constituent)
            }
        }

        for device in discovery.devices {
            append(device)
        }
        return flattened
    }

    private func updateLensOptions(
        for device: AVCaptureDevice,
        position: NativeCameraPosition,
        selectedTitleOverride: String? = nil,
    ) {
        let deviceMinimumZoom = max(0.1, device.minAvailableVideoZoomFactor)
        let minZoom = max(deviceMinimumZoom, minimumCaptureZoom)
        let rawMaxZoom = max(deviceMinimumZoom, device.maxAvailableVideoZoomFactor)
        let effectiveMaxZoom = NativeZoomPolicy.effectiveMax(
            rawMax: rawMaxZoom,
            recommendedMax: recommendedMaxZoom(for: device),
        )
        let discovered = discoveredDevices(position: position.avPosition)
        let availableTypes = Set(discovered.map { $0.deviceType.rawValue })
        let displayZoomByDeviceType = displayZoomMultipliers(for: discovered)
        let virtualFactors = virtualDeviceZoomFactors(for: device)
        let options = NativeLensCatalog.make(
            position: position,
            availableDeviceTypes: availableTypes,
            minZoom: minZoom,
            // Discover every physical/virtual switch-over that this device
            // reports. The system-recommended cap applies only to continuous
            // pinch zoom; using it here could hide a real telephoto option.
            maxZoom: rawMaxZoom,
            displayZoomByDeviceType: displayZoomByDeviceType,
            virtualDeviceZoomFactors: virtualFactors,
            displayZoomMultiplier: displayZoomMultiplier(for: device),
        )
        let selected = options.min { lhs, rhs in
            abs(lhs.zoomFactor - device.videoZoomFactor) < abs(rhs.zoomFactor - device.videoZoomFactor)
        } ?? options.first
        let selectedTitle = selectedTitleOverride ?? selected?.title ?? "1×"
        #if DEBUG
        let debugDevices = discoveredDevices(position: position.avPosition)
            .map { "\($0.deviceType.rawValue)=\($0.localizedName)" }
            .joined(separator: ", ")
        print("[PhysioAINative] lens discovery position=\(position == .back ? "back" : "front") device=\(device.deviceType.rawValue) virtualFactors=\(virtualFactors) devices=[\(debugDevices)] options=\(options.map(\.title))")
        #endif
        DispatchQueue.main.async {
            self.lensOptions = options
            self.selectedLensTitle = selectedTitle
            self.currentZoomFactor = device.videoZoomFactor
            self.minZoomFactor = minZoom
            self.maxZoomFactor = effectiveMaxZoom
            self.activeDeviceName = device.localizedName
            self.cameraStatus = self.cameraStatus.hasPrefix("Live")
                ? "Live · \(position == .back ? "back" : "front") · \(selectedTitle)"
                : self.cameraStatus
        }
    }

    private func recommendedMaxZoom(for device: AVCaptureDevice) -> CGFloat? {
        if #available(iOS 18.0, *) {
            return device.activeFormat.systemRecommendedVideoZoomRange?.upperBound
        }
        return nil
    }

    private func displayZoomMultipliers(for devices: [AVCaptureDevice]) -> [String: CGFloat] {
        guard #available(iOS 18.0, *) else { return [:] }
        return Dictionary(devices.map {
            ($0.deviceType.rawValue, $0.displayVideoZoomFactorMultiplier)
        }, uniquingKeysWith: { first, _ in first })
    }

    private func displayZoomMultiplier(for device: AVCaptureDevice) -> CGFloat {
        guard #available(iOS 18.0, *) else { return 1 }
        let value = device.displayVideoZoomFactorMultiplier
        return value.isFinite && value > 0 ? value : 1
    }

    private func virtualDeviceZoomFactors(for device: AVCaptureDevice) -> [CGFloat] {
        guard device.isVirtualDevice else { return [] }
        return device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
    }

    /// Returns the reported virtual-lens segment containing a zoom factor.
    /// Only a segment change can represent an optical-lens hand-off on a
    /// logical dual/triple device; ordinary pinch deltas in one segment keep
    /// the temporal source intact.
    private func virtualLensSegment(for zoom: CGFloat, on device: AVCaptureDevice) -> Int? {
        guard device.isVirtualDevice else { return nil }
        return NativeLensCatalog.virtualLensSegment(
            zoom: zoom,
            minimumZoom: device.minAvailableVideoZoomFactor,
            switchOverFactors: virtualDeviceZoomFactors(for: device),
        )
    }

    private func resetForVirtualLensSegmentChangeIfNeeded(
        device: AVCaptureDevice,
        from previousZoom: CGFloat,
        to currentZoom: CGFloat,
    ) {
        guard let previous = virtualLensSegment(for: previousZoom, on: device),
              let current = virtualLensSegment(for: currentZoom, on: device),
              previous != current else { return }
        let previousTimestamp = frameQueue.sync { () -> Int in
            let timestamp = sourceTimestampClock.lastTimelineTimestampMs ?? 0
            beginNewFrameSourceOnFrameQueue()
            engineLock.lock()
            if v7BottleDetectorEnabled {
                v7AIModule?.resetForNewCaptureSource()
            } else {
                engine.resetForNewCaptureSource()
            }
            engineLock.unlock()
            return timestamp
        }
        DispatchQueue.main.async {
            self.latestSnapshot = nil
            self.latestOutput = nil
            self.latestBottleDetectorDiagnostics = nil
            self.latestFingerComment = nil
        }
#if DEBUG
        print("[PhysioAINative] virtual lens segment changed \(previous)->\(current) at timestamp=\(previousTimestamp); re-baselining")
#endif
    }

    private func displayZoomTitle(for device: AVCaptureDevice, zoomFactor: CGFloat) -> String {
        let multiplier: CGFloat
        if #available(iOS 18.0, *) {
            multiplier = device.displayVideoZoomFactorMultiplier
        } else {
            multiplier = 1
        }
        let displayZoom = max(0.1, zoomFactor * multiplier)
        let display = abs(displayZoom.rounded() - displayZoom) < 0.05
            ? String(format: "%.0f", Double(displayZoom))
            : String(format: "%.1f", Double(displayZoom))
        return "\(display)×"
    }

    private func applyPortraitOrientation(for activePosition: NativeCameraPosition = .back) {
        if let connection = videoOutput?.connection(with: .video) {
            if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = activePosition == .front }
            // Stabilization is valuable for recording, but it can add a
            // capture pipeline stage and crop that do not help an on-device
            // landmark stream.  Disable it for the analysis output so the
            // source timing/geometry stays as close as possible to the real
            // camera frame consumed by MediaPipe.
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
        if let connection = previewLayer.connection, connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = activePosition == .front }
        }
    }

    private func publishPreviewSourceAspectRatio(for device: AVCaptureDevice) {
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let nativeWidth = CGFloat(dimensions.width)
        let nativeHeight = CGFloat(dimensions.height)
        guard nativeWidth > 0, nativeHeight > 0 else { return }
        // Both the video output and preview connections are explicitly
        // portrait. Invert the format's landscape-oriented dimensions so the
        // overlay receives the same portrait source geometry as the preview.
        let portraitAspectRatio = nativeHeight / nativeWidth
        guard portraitAspectRatio.isFinite, portraitAspectRatio > 0 else { return }
        DispatchQueue.main.async {
            self.previewSourceAspectRatio = portraitAspectRatio
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        sessionVideoRecorder?.append(sampleBuffer)
        let rawTimestampMs = Int(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds * 1000)
        guard let timestamp = sourceTimestampClock.normalize(rawTimestampMs: rawTimestampMs) else { return }
        let sourceGeneration = sourceTimestampClock.generation
        if !didLogFirstFrame {
            didLogFirstFrame = true
            print("[PhysioAINative] first camera frame timestampMs=\(timestamp)")
        }
        // This connection owns the image transform for this exact frame.
        // Camera position is only a UI state and can diverge after a camera
        // or lens replacement, so never use it to infer handedness.
        let inputIsMirrored = connection.isVideoMirroringSupported && connection.isVideoMirrored
        if selectedExerciseID == NativeSitToStandV72AIModule.exerciseID {
            sitToStandAIModule?.process(
                sampleBuffer: sampleBuffer,
                timestampMs: timestamp,
                inputIsMirrored: inputIsMirrored,
                sourceGeneration: sourceGeneration,
            )
        } else if v7BottleDetectorEnabled {
            v7AIModule?.process(
                sampleBuffer: sampleBuffer,
                timestampMs: timestamp,
                inputIsMirrored: inputIsMirrored,
                sourceGeneration: sourceGeneration,
            )
        } else {
            pipeline?.process(
                sampleBuffer: sampleBuffer,
                timestampMs: timestamp,
                inputIsMirrored: inputIsMirrored,
                sourceGeneration: sourceGeneration,
            )
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        DispatchQueue.main.async { self.droppedFrames += 1 }
    }

    private func consume(_ snapshot: NativeFrameSnapshot, outputOverride: NativeBottleGrabOutput? = nil) {
        // A source replacement resets the model state. Drop any delayed
        // MediaPipe result from the prior camera/lens before it can enter a
        // new 30-frame PhaseNet window.
        guard accepts(snapshot: snapshot) else { return }
        engineLock.lock()
        let result = outputOverride ?? engine.ingest(snapshot)
        engineLock.unlock()
        // The source could have changed while inference was being serialized.
        // Recheck before publishing so an old result cannot repaint the UI.
        guard accepts(snapshot: snapshot) else { return }
        if !didLogFirstResult {
            didLogFirstResult = true
            print("[PhysioAINative] first native result pose=\(snapshot.pose.count) hand=\(snapshot.hand.count) latencyMs=\(snapshot.detectorLatencyMs)")
        }
#if DEBUG
        let signature = [
            result.captureQC,
            result.setupState,
            result.setupReason ?? "-",
            result.phaseStatus,
            result.phase ?? "-",
            result.hostCounterStatus ?? "-",
            result.hostCounterReason ?? "-",
            result.repCounterProvenance ?? "-",
            result.bottleStatus ?? "-",
            "zone=\(result.bottleInZone.map { String($0) } ?? "-")",
            "reps=\(result.totalReps)",
            "side=\(snapshot.handSide ?? "-")",
            "source=\(snapshot.handSideSource ?? "-")",
        ].joined(separator: "|")
        if signature != lastBottleGrabDiagnosticSignature {
            lastBottleGrabDiagnosticSignature = signature
            print("[PhysioAINative][BottleGrab] qc=\(result.captureQC) setup=\(result.setupState)/\(result.setupReason ?? "-") phase=\(result.phaseStatus)/\(result.phase ?? "-") bottle=\(result.bottleStatus ?? "-") zone=\(result.bottleInZone.map { String($0) } ?? "-") bottleScore=\(result.bottleScore.map { String(format: "%.2f", $0) } ?? "-") host=\(result.hostCounterStatus ?? "-")/\(result.hostCounterReason ?? "-") reps=\(result.totalReps) provenance=\(result.repCounterProvenance ?? "-") side=\(snapshot.handSide ?? "-") via=\(snapshot.handSideSource ?? "-") latencyMs=\(Int(snapshot.detectorLatencyMs))")
        }
        let candidateState = [
            "generation=\(snapshot.sourceGeneration)",
            "side=\(snapshot.handSide ?? "-")",
            "source=\(snapshot.handSideSource ?? "-")",
        ].joined(separator: "|")
        if NativeCandidateTraceLogPolicy.shouldEmit(
            previousState: lastCandidateTraceState,
            previousTimestampMs: lastCandidateTraceTimestampMs == Int.min ? nil : lastCandidateTraceTimestampMs,
            nextState: candidateState,
            timestampMs: snapshot.timestampMs,
        ) {
            lastCandidateTraceState = candidateState
            lastCandidateTraceTimestampMs = snapshot.timestampMs
            print("[PhysioAINative][HandCandidates] timestampMs=\(snapshot.timestampMs) \(snapshot.handCandidateTrace ?? "mirrored=?\\nno_hand_candidates")")
        }
#endif
        DispatchQueue.main.async {
            self.latestSnapshot = snapshot
            self.latestOutput = result
            self.latestSitToStandOutput = nil
            self.detectorStatus = self.v7AIModule?.setupError
                ?? self.pipeline?.setupError
                ?? "Native MediaPipe live stream"
        }
    }

    /// Receives a Hand-only comment result after the authoritative Pose+Bottle
    /// counter path has already consumed its same camera frame. Updating this
    /// presentation state cannot call `engine.ingest`, alter `latestOutput`,
    /// or reset a repetition.
    private func consumeFingerComment(
        _ snapshot: NativeFrameSnapshot,
        cue: NativeBottleGrabCuePreview?,
    ) {
        guard accepts(snapshot: snapshot) else { return }
        DispatchQueue.main.async {
            guard self.accepts(snapshot: snapshot) else { return }
            // Hand results are intentionally asynchronous. Do not let a late
            // comment from an older same-source frame repaint newer Pose/Counter
            // presentation state; it remains comment-only either way.
            if let latest = self.latestSnapshot,
               latest.sourceGeneration == snapshot.sourceGeneration,
               latest.timestampMs > snapshot.timestampMs {
                return
            }
            self.latestSnapshot = snapshot
            self.latestFingerComment = cue
        }
    }

    /// Receives only aggregate Bottle Detector health/selection telemetry.
    /// It cannot invoke the engine or make a counting decision. Source
    /// generation fencing prevents an old camera/lens callback from painting
    /// a current preview.
    private func consumeBottleDiagnostics(_ diagnostics: NativeBottleDetectorDiagnostics) {
        guard accepts(sourceGeneration: diagnostics.sourceGeneration) else { return }
        DispatchQueue.main.async {
            guard self.accepts(sourceGeneration: diagnostics.sourceGeneration) else { return }
#if DEBUG
            let signature = [
                diagnostics.status,
                diagnostics.selectionReason,
                String(diagnostics.rawDetectionCount),
                String(diagnostics.acceptedBottleCount),
                diagnostics.topLabel ?? "-",
                diagnostics.topScore.map { String(format: "%.2f", $0) } ?? "-",
                diagnostics.anchorState.rawValue,
            ].joined(separator: "|")
            if signature != self.lastBottleDetectorDiagnosticSignature {
                self.lastBottleDetectorDiagnosticSignature = signature
                print("[PhysioAINative][BottleDetector] status=\(diagnostics.status) reason=\(diagnostics.selectionReason) raw=\(diagnostics.rawDetectionCount) accepted=\(diagnostics.acceptedBottleCount) top=\(diagnostics.topLabel ?? "-") score=\(diagnostics.topScore.map { String(format: "%.2f", $0) } ?? "-") ageMs=\(diagnostics.ageMs.map(String.init) ?? "-") anchor=\(diagnostics.anchorState.rawValue) anchorTimestampMs=\(diagnostics.anchorTimestampMs.map(String.init) ?? "-")")
            }
#endif
            self.latestBottleDetectorDiagnostics = diagnostics
        }
    }

    private func ensureSitToStandModule() {
        guard sitToStandAIModule == nil else { return }
        sitToStandAIModule = NativeSitToStandV72AIModule(
            onOutput: { [weak self] snapshot, output in
                self?.consumeSitToStand(snapshot, output: output)
            },
            onStatus: { [weak self] status in
                DispatchQueue.main.async {
                    self?.detectorStatus = status
                }
            },
        )
        detectorStatus = sitToStandAIModule?.setupError ?? "Native App V7.3.5 Sit-to-Stand AI module ready"
    }

    private func consumeSitToStand(_ snapshot: NativeFrameSnapshot, output: NativeSitToStandOutput) {
        guard accepts(snapshot: snapshot) else { return }
        DispatchQueue.main.async {
            self.latestSnapshot = snapshot
            self.latestOutput = nil
            self.latestBottleDetectorDiagnostics = nil
            self.latestFingerComment = nil
            self.latestSitToStandOutput = output
            self.detectorStatus = self.sitToStandAIModule?.setupError ?? "Native MediaPipe Pose-only live stream"
        }
    }

    /// Must be called only from `frameQueue` (or `frameQueue.sync`). It makes
    /// source replacement explicit in both the callback join table and the
    /// model-facing snapshot identity.
    private func beginNewFrameSourceOnFrameQueue() {
        sourceTimestampClock.beginNewSource()
        let generation = sourceTimestampClock.generation
        sourceStateLock.lock()
        activeSourceGeneration = generation
        sourceStateLock.unlock()
        if selectedExerciseID == NativeSitToStandV72AIModule.exerciseID {
            sitToStandAIModule?.resetPendingFrames(sourceGeneration: generation)
        } else if v7BottleDetectorEnabled {
            v7AIModule?.resetPendingFrames(sourceGeneration: generation)
        } else {
            pipeline?.resetPendingFrames(sourceGeneration: generation)
        }
        DispatchQueue.main.async {
            self.captureSourceGeneration = generation
        }
    }

    private func accepts(snapshot: NativeFrameSnapshot) -> Bool {
        accepts(sourceGeneration: snapshot.sourceGeneration)
    }

    private func accepts(sourceGeneration: Int) -> Bool {
        sourceStateLock.lock()
        let accepted = sourceGeneration == activeSourceGeneration
        sourceStateLock.unlock()
        return accepted
    }
}
