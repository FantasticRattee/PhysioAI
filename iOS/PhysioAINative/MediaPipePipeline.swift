import Foundation
import MediaPipeTasksVision
import UIKit

/// Bottle Grab's PhaseNet V2 source traces were extracted with MediaPipe Pose
/// Landmarker Full. The native camera must request that same upstream asset so
/// pose visibility and the derived elbow/wrist features are not silently
/// sourced from Lite. This selection only controls the upstream pose detector;
/// it never changes the frozen PhaseNet weights, feature order, thresholds, or
/// hand detector. The 15 Hz capture request and latest-frame coalescing bound
/// work rather than treating a detector mismatch as a speed optimisation.
enum NativeBottleGrabPoseDetectorContract {
    static let assetName = "pose_landmarker_full"
}

/// MediaPipe hand labels are defined for mirrored/selfie input. Keep the
/// model-facing side anatomical by swapping the reported label for an
/// unmirrored rear-camera buffer. When a same-frame pose has two credible
/// wrists, use the hand-wrist/pose-wrist association as the final authority:
/// it is in the exact same image coordinate system as the hand landmarks and
/// remains valid for both front and rear camera transforms.
enum NativeHandedness {
    struct Resolution: Equatable {
        let side: String?
        /// A compact, developer-visible explanation of the decision. This is
        /// diagnostic metadata only; it never becomes a model feature.
        let source: String
        /// The detector label after correcting for the actual capture-buffer
        /// mirroring. It is evidence for debugging, never a PhaseNet feature.
        let detectorAnatomicalSide: String?
        /// Same-frame aggregate association evidence. These are distances,
        /// not raw landmarks, and exist only in the DEBUG candidate trace.
        let leftWristDistance: Float?
        let rightWristDistance: Float?
        let leftAssociationLimit: Float?
        let rightAssociationLimit: Float?
    }

    static func anatomicalSide(detectorSide: String?, inputIsMirrored: Bool) -> String? {
        guard let detectorSide = detectorSide?.lowercased() else { return nil }
        let normalized: String
        if detectorSide.contains("left") {
            normalized = "Left"
        } else if detectorSide.contains("right") {
            normalized = "Right"
        } else {
            return nil
        }
        guard !inputIsMirrored else { return normalized }
        return normalized == "Left" ? "Right" : "Left"
    }

    /// Resolve a hand's anatomical side without making the preview's visual
    /// mirroring a proxy for model input. The detector label remains the
    /// fallback when either Pose wrist is unavailable or association is
    /// ambiguous. A clear Pose-wrist match wins because it prevents a camera
    /// transform mismatch from falsely rejecting a visibly tracked left hand.
    static func resolve(
        detectorSide: String?,
        inputIsMirrored: Bool,
        pose: [NativeLandmark],
        hand: [NativeLandmark],
    ) -> Resolution {
        let detectorResolved = anatomicalSide(
            detectorSide: detectorSide,
            inputIsMirrored: inputIsMirrored,
        )
        let detectorSource = inputIsMirrored
            ? "detector_mirrored"
            : "detector_unmirrored_swapped"

        guard hand.count == 21,
              pose.count > 16,
              valid(hand[0]) else {
            return Resolution(
                side: detectorResolved,
                source: detectorSource,
                detectorAnatomicalSide: detectorResolved,
                leftWristDistance: nil,
                rightWristDistance: nil,
                leftAssociationLimit: nil,
                rightAssociationLimit: nil,
            )
        }

        let handWrist = hand[0]
        let leftWrist = pose[15]
        let rightWrist = pose[16]
        let leftWristIsValid = validPoseWrist(leftWrist)
        let rightWristIsValid = validPoseWrist(rightWrist)
        guard leftWristIsValid || rightWristIsValid else {
            return Resolution(
                side: detectorResolved,
                source: detectorSource,
                detectorAnatomicalSide: detectorResolved,
                leftWristDistance: nil,
                rightWristDistance: nil,
                leftAssociationLimit: nil,
                rightAssociationLimit: nil,
            )
        }

        let leftDistance = leftWristIsValid ? distance(handWrist, leftWrist) : nil
        let rightDistance = rightWristIsValid ? distance(handWrist, rightWrist) : nil
        let leftAssociationLimit = leftWristIsValid
            ? associationLimit(
                shoulder: pose.count > 11 ? pose[11] : nil,
                elbow: pose.count > 13 ? pose[13] : nil,
                wrist: leftWrist,
            )
            : nil
        let rightAssociationLimit = rightWristIsValid
            ? associationLimit(
                shoulder: pose.count > 12 ? pose[12] : nil,
                elbow: pose.count > 14 ? pose[14] : nil,
                wrist: rightWrist,
            )
            : nil

        // Require a meaningful gap between the two wrist candidates. A hand
        // crossing the torso can be genuinely ambiguous; preserve the
        // detector fallback rather than inventing an anatomical side. If one
        // contralateral wrist is occluded, the visible working wrist is still
        // sufficient to make the association; this is the V6.1 side-view fix.
        let separation: Float = 0.025
        if let leftDistance,
           let leftAssociationLimit,
           leftDistance <= leftAssociationLimit,
           rightDistance == nil || leftDistance + separation < rightDistance! {
            let source: String
            if detectorResolved == "Left" {
                source = "pose_left_wrist_confirmed"
            } else if rightDistance == nil {
                source = "pose_left_wrist_corrected_unilateral"
            } else {
                source = "pose_left_wrist_corrected"
            }
            return Resolution(
                side: "Left",
                source: source,
                detectorAnatomicalSide: detectorResolved,
                leftWristDistance: leftDistance,
                rightWristDistance: rightDistance,
                leftAssociationLimit: leftAssociationLimit,
                rightAssociationLimit: rightAssociationLimit,
            )
        }
        if let rightDistance,
           let rightAssociationLimit,
           rightDistance <= rightAssociationLimit,
           leftDistance == nil || rightDistance + separation < leftDistance! {
            let source: String
            if detectorResolved == "Right" {
                source = "pose_right_wrist_confirmed"
            } else if leftDistance == nil {
                source = "pose_right_wrist_corrected_unilateral"
            } else {
                source = "pose_right_wrist_corrected"
            }
            return Resolution(
                side: "Right",
                source: source,
                detectorAnatomicalSide: detectorResolved,
                leftWristDistance: leftDistance,
                rightWristDistance: rightDistance,
                leftAssociationLimit: leftAssociationLimit,
                rightAssociationLimit: rightAssociationLimit,
            )
        }
        return Resolution(
            side: detectorResolved,
            source: detectorSource,
            detectorAnatomicalSide: detectorResolved,
            leftWristDistance: leftDistance,
            rightWristDistance: rightDistance,
            leftAssociationLimit: leftAssociationLimit,
            rightAssociationLimit: rightAssociationLimit,
        )
    }

    private static func valid(_ point: NativeLandmark) -> Bool {
        point.x.isFinite && point.y.isFinite
            && point.x >= 0 && point.x <= 1
            && point.y >= 0 && point.y <= 1
    }

    private static func validPoseWrist(_ point: NativeLandmark) -> Bool {
        valid(point) && point.visibility.isFinite && point.visibility >= 0.5
    }

    private static func associationLimit(
        shoulder: NativeLandmark?,
        elbow: NativeLandmark?,
        wrist: NativeLandmark,
    ) -> Float {
        guard let shoulder,
              let elbow,
              validPoseWrist(shoulder),
              validPoseWrist(elbow) else {
            return 0.18
        }
        let armScale = distance(shoulder, elbow) + distance(elbow, wrist)
        return max(0.18, armScale * 0.85)
    }

    private static func distance(_ first: NativeLandmark, _ second: NativeLandmark) -> Float {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return sqrt(dx * dx + dy * dy)
    }
}

/// One hand returned from the same MediaPipe timestamp. The outer result index
/// is preserved so a candidate never becomes detached from its handedness
/// category. This is developer-side detector metadata, never a PhaseNet
/// feature or a persisted patient record.
struct NativeHandCandidate: Equatable {
    let index: Int
    let landmarks: [NativeLandmark]
    let detectorSide: String?
    let score: Float
}

/// Aggregate-only evidence for one Hand Landmarker candidate. It exists to
/// diagnose live left/right selection without retaining image bytes or raw
/// landmark arrays in a log, session, or backend payload.
struct NativeHandCandidateTrace: Equatable {
    let index: Int
    let detectorSide: String?
    let detectorAnatomicalSide: String?
    let score: Float
    let resolvedSide: String?
    let resolutionSource: String
    let leftWristDistance: Float?
    let rightWristDistance: Float?
    let leftAssociationLimit: Float?
    let rightAssociationLimit: Float?

    var compactDescription: String {
        let raw = detectorSide ?? "?"
        let anatomical = detectorAnatomicalSide ?? "?"
        let resolved = resolvedSide ?? "?"
        return "c\(index + 1) raw=\(raw) anat=\(anatomical) s=\(format(score)) → \(resolved) \(resolutionSource) dL=\(format(leftWristDistance))/\(format(leftAssociationLimit)) dR=\(format(rightWristDistance))/\(format(rightAssociationLimit))"
    }

    private func format(_ value: Float?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.2f", value)
    }
}

struct NativeHandCandidateSelection: Equatable {
    /// The only candidate allowed to become the model-facing 21-point hand.
    /// It is non-nil solely for a selected anatomical-left candidate.
    let candidate: NativeHandCandidate?
    let resolution: NativeHandedness.Resolution?
    let candidateCount: Int
    let source: String
    let candidateTrace: [NativeHandCandidateTrace]
    /// The transform of the actual capture buffer sent to both MediaPipe
    /// tasks. Keeping it beside the candidate trace makes a LEFT/RIGHT issue
    /// auditable without inferring front/back from UI state.
    let inputIsMirrored: Bool

    var side: String? { resolution?.side }
    var compactCandidateTrace: String {
        (["mirrored=\(inputIsMirrored)"] + candidateTrace.map(\.compactDescription))
            .joined(separator: "\n")
    }
}

/// Select the anatomical-left evidence needed by the frozen Bottle Grab
/// contract after Pose and Hand results for the same timestamp are both ready.
/// The previous implementation always chose MediaPipe array index 0, which can
/// be the contralateral hand when two hands are visible. This selector first
/// resolves each candidate against the current Pose wrists, prefers accepted
/// left candidates, then uses confidence/index only as deterministic
/// tie-breakers. If no left candidate exists, it retains the best real
/// fallback only as side/diagnostic provenance. Its landmarks are deliberately
/// withheld from the model-facing snapshot, so a contralateral hand cannot
/// accidentally become a left-trained PhaseNet input in a future caller.
enum NativeHandCandidateSelector {
    /// This must match the Hand Landmarker request below. Two candidates let
    /// the native side choose the left wrist-associated hand instead of
    /// depending on MediaPipe result order when both hands are visible.
    static let maximumHandCandidates = 2

    private struct ResolvedCandidate {
        let candidate: NativeHandCandidate
        let resolution: NativeHandedness.Resolution

        var trace: NativeHandCandidateTrace {
            NativeHandCandidateTrace(
                index: candidate.index,
                detectorSide: candidate.detectorSide,
                detectorAnatomicalSide: resolution.detectorAnatomicalSide,
                score: candidate.score,
                resolvedSide: resolution.side,
                resolutionSource: resolution.source,
                leftWristDistance: resolution.leftWristDistance,
                rightWristDistance: resolution.rightWristDistance,
                leftAssociationLimit: resolution.leftAssociationLimit,
                rightAssociationLimit: resolution.rightAssociationLimit,
            )
        }
    }

    static func select(
        candidates: [NativeHandCandidate],
        pose: [NativeLandmark],
        inputIsMirrored: Bool,
    ) -> NativeHandCandidateSelection {
        let resolved = candidates.map { candidate in
            ResolvedCandidate(
                candidate: candidate,
                resolution: NativeHandedness.resolve(
                    detectorSide: candidate.detectorSide,
                    inputIsMirrored: inputIsMirrored,
                    pose: pose,
                    hand: candidate.landmarks,
                ),
            )
        }
        let candidateTrace = resolved.map(\.trace)
        guard !resolved.isEmpty else {
            return NativeHandCandidateSelection(
                candidate: nil,
                resolution: nil,
                candidateCount: 0,
                source: "no_hand_candidates",
                candidateTrace: [],
                inputIsMirrored: inputIsMirrored,
            )
        }

        let leftCandidates = resolved.filter {
            $0.resolution.side?.localizedCaseInsensitiveCompare("Left") == .orderedSame
        }
        let usesFallback = leftCandidates.isEmpty
        let selected = bestCandidate(from: usesFallback ? resolved : leftCandidates)
        let prefix = usesFallback ? "fallback_no_left" : "selected_left"
        return NativeHandCandidateSelection(
            candidate: usesFallback ? nil : selected.candidate,
            resolution: selected.resolution,
            candidateCount: resolved.count,
            source: "\(prefix):\(selected.resolution.source):candidate_\(selected.candidate.index + 1)_of_\(resolved.count)",
            candidateTrace: candidateTrace,
            inputIsMirrored: inputIsMirrored,
        )
    }

    private static func bestCandidate(from candidates: [ResolvedCandidate]) -> ResolvedCandidate {
        candidates.sorted { first, second in
            let firstAssociation = isPoseLeftAssociation(first.resolution.source)
            let secondAssociation = isPoseLeftAssociation(second.resolution.source)
            if firstAssociation != secondAssociation { return firstAssociation }
            if first.candidate.score != second.candidate.score {
                return first.candidate.score > second.candidate.score
            }
            return first.candidate.index < second.candidate.index
        }.first!
    }

    private static func isPoseLeftAssociation(_ source: String) -> Bool {
        source == "pose_left_wrist_confirmed" || source == "pose_left_wrist_corrected"
    }
}

/// Bounds the native live-stream work to the newest processable camera frame.
/// `AVCaptureVideoDataOutput.alwaysDiscardsLateVideoFrames` only protects the
/// capture-output queue; MediaPipe's asynchronous Pose + Hand submissions can
/// otherwise keep their own internal work queue alive after the preview has
/// moved on. One joined Pose/Hand request at a time makes latency bounded by
/// a single inference instead of an unbounded backlog of stale frames.
///
/// This is deliberately a transport policy, not a model resampler. A skipped
/// image contributes no synthetic feature frame to PhaseNet or the host
/// counter. The next real completed frame retains its original timestamp.
struct NativeInferenceAdmissionGate {
    static let maximumInFlightAge: TimeInterval = 0.35

    enum Decision: Equatable {
        case admitted(expiredTimestampMs: Int?)
        case throttled
    }

    private(set) var inFlightTimestampMs: Int?
    private var startedAt: TimeInterval?

    mutating func admit(timestampMs: Int, now: TimeInterval) -> Decision {
        var expiredTimestampMs: Int?
        if let inFlightTimestampMs, let startedAt {
            guard now - startedAt > Self.maximumInFlightAge else { return .throttled }
            // A detector callback older than this bounded live budget is not
            // allowed to keep the camera in a stale state. Its later callback
            // is ignored because `complete` only clears a matching timestamp.
            expiredTimestampMs = inFlightTimestampMs
            self.inFlightTimestampMs = nil
            self.startedAt = nil
        }
        self.inFlightTimestampMs = timestampMs
        self.startedAt = now
        return .admitted(expiredTimestampMs: expiredTimestampMs)
    }

    mutating func complete(timestampMs: Int) {
        guard inFlightTimestampMs == timestampMs else { return }
        inFlightTimestampMs = nil
        startedAt = nil
    }

    mutating func reset() {
        inFlightTimestampMs = nil
        startedAt = nil
    }
}

/// The Bottle Detector must run through MediaPipe's CPU delegate because its
/// GPU initialization can abort the process. It is intentionally scheduled
/// independently from the Pose/Hand join: Pose remains the live-frame owner,
/// while Bottle observations are a bounded, fresh cache used by V7 proximity.
/// This is transport only; it does not alter the frozen counter's age, ROI,
/// source-generation, or outside → inside → outside contract.
struct NativeBottleDetectorAdmissionGate {
    static let minimumSubmissionIntervalMs = 150
    static let maximumInFlightAge: TimeInterval = 0.35

    enum Decision: Equatable {
        case admitted(expiredTimestampMs: Int?)
        case throttled
    }

    private(set) var inFlightTimestampMs: Int?
    private var startedAt: TimeInterval?
    private var lastSubmissionTimestampMs: Int?

    mutating func admit(timestampMs: Int, now: TimeInterval) -> Decision {
        var expiredTimestampMs: Int?
        if let inFlightTimestampMs, let startedAt {
            guard now - startedAt > Self.maximumInFlightAge else { return .throttled }
            expiredTimestampMs = inFlightTimestampMs
            self.inFlightTimestampMs = nil
            self.startedAt = nil
        }
        if let lastSubmissionTimestampMs,
           timestampMs - lastSubmissionTimestampMs < Self.minimumSubmissionIntervalMs {
            return .throttled
        }
        self.inFlightTimestampMs = timestampMs
        self.startedAt = now
        self.lastSubmissionTimestampMs = timestampMs
        return .admitted(expiredTimestampMs: expiredTimestampMs)
    }

    mutating func complete(timestampMs: Int) {
        guard inFlightTimestampMs == timestampMs else { return }
        inFlightTimestampMs = nil
        startedAt = nil
    }

    mutating func reset() {
        self = NativeBottleDetectorAdmissionGate()
    }
}

/// Keeps all pending inference work scoped to the currently active camera
/// source. The camera/lens reset and a detector callback can race on different
/// queues; an old coalesced frame must never re-enter the live queue after the
/// reset has invalidated its source generation.
struct NativeSourceGenerationGate {
    private(set) var activeGeneration = 0

    mutating func reset(to generation: Int) {
        activeGeneration = generation
    }

    func accepts(_ generation: Int) -> Bool {
        generation == activeGeneration
    }
}

/// Native MediaPipe live-stream processor. It consumes CMSampleBuffers on the
/// camera queue and returns only numeric landmarks/diagnostics to the SwiftUI
/// shell. No React Native view, JSI frame processor, or JavaScript callback is
/// involved in this lane.
final class MediaPipePipeline: NSObject,
                               PoseLandmarkerLiveStreamDelegate,
                               HandLandmarkerLiveStreamDelegate,
                               ObjectDetectorLiveStreamDelegate {
    typealias SnapshotHandler = (NativeFrameSnapshot) -> Void
    typealias BottleDiagnosticsHandler = (NativeBottleDetectorDiagnostics) -> Void
    typealias StatusHandler = (String) -> Void

    /// Authoritative V7 lane: Pose Body + latest fresh Bottle box only. It
    /// drives the proximity counter and must never await the Hand result.
    private let onCounterSnapshot: SnapshotHandler
    /// Secondary V7 lane: same-frame Pose + Hand result for finger-quality
    /// comments. It cannot feed the counter or reset counter state.
    private let onHandCommentSnapshot: SnapshotHandler
    /// Independent diagnostic lane. It exists only to make Bottle Detector
    /// health/selection visible to the host; it cannot delay or alter count.
    private let onBottleDiagnostics: BottleDiagnosticsHandler
    private let onStatus: StatusHandler
    private let enableBottleDetector: Bool
    /// Sit-to-Stand is an explicit Pose-only profile. Keeping this separate
    /// from `enableBottleDetector` prevents a missing Hand callback from
    /// blocking a body-only module.
    private let enableHand: Bool
    private var poseLandmarker: PoseLandmarker?
    private var handLandmarker: HandLandmarker?
    private var bottleDetector: ObjectDetector?
    private var pending: [Int: PendingDetection] = [:]
    /// Bottle detector work is independent from the live Pose/Hand fan-out.
    /// A CPU detector result can arrive later without withholding a current
    /// Pose snapshot; the result is admitted only if it remains fresh.
    private var pendingBottleDetections: [Int: PendingBottleDetection] = [:]
    private let pendingLock = NSLock()
    private var admissionGate = NativeInferenceAdmissionGate()
    private var bottleAdmissionGate = NativeBottleDetectorAdmissionGate()
    /// Camera output arrives faster than a joined Pose + Hand inference on
    /// some devices. Retain only the newest real frame while an inference is
    /// running; processing older buffered frames would make the preview and
    /// skeleton lag behind the camera.
    private var latestQueuedInput: QueuedInput?
    /// Access only while holding `pendingLock`.
    private var sourceGenerationGate = NativeSourceGenerationGate()
    private var telemetry = NativeMediaPipeTelemetry()
    private var lastBottleDetection: NativeBottleDetection?
    /// V7.3.4 separates the last confirmed physical checkpoint from a fresh
    /// detector callback. Access only while holding `pendingLock`.
    private var bottleAnchorTracker = NativeBottleAnchorTracker()
    /// Last ObjectDetector callback in aggregate form. Access only while
    /// holding `pendingLock`; no frames or raw landmarks are retained.
    private var lastBottleDiagnostics: NativeBottleDetectorDiagnostics?
#if DEBUG
    private let telemetryReportLock = NSLock()
    private var lastTelemetryReportAt: CFTimeInterval = 0
#endif

    private(set) var setupError: String?
    private(set) var inferenceDelegateName = "unavailable"

    private final class PendingDetection {
        var pose: [NativeLandmark]?
        /// `nil` means the Hand callback has not arrived yet; an empty array
        /// means it arrived but MediaPipe found no hands for this timestamp.
        var handCandidates: [NativeHandCandidate]?
        /// The authoritative Pose+Bottle result may publish before Hand. Keep
        /// this short-lived context only so a later Hand callback can reach the
        /// secondary comment lane; it must never cause a second count ingest.
        var counterPublished = false
        let inputIsMirrored: Bool
        let sourceGeneration: Int
        let imageWidth: CGFloat
        let imageHeight: CGFloat
        let startedAt: CFTimeInterval

        init(
            inputIsMirrored: Bool,
            sourceGeneration: Int,
            imageWidth: CGFloat,
            imageHeight: CGFloat,
            startedAt: CFTimeInterval = CACurrentMediaTime(),
        ) {
            self.inputIsMirrored = inputIsMirrored
            self.sourceGeneration = sourceGeneration
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
            self.startedAt = startedAt
        }
    }

    private final class PendingBottleDetection {
        let sourceGeneration: Int
        let imageWidth: CGFloat
        let imageHeight: CGFloat

        init(
            sourceGeneration: Int,
            imageWidth: CGFloat,
            imageHeight: CGFloat,
        ) {
            self.sourceGeneration = sourceGeneration
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
        }
    }

    private final class QueuedInput {
        let sampleBuffer: CMSampleBuffer
        let timestampMs: Int
        let inputIsMirrored: Bool
        let sourceGeneration: Int

        init(
            sampleBuffer: CMSampleBuffer,
            timestampMs: Int,
            inputIsMirrored: Bool,
            sourceGeneration: Int,
        ) {
            self.sampleBuffer = sampleBuffer
            self.timestampMs = timestampMs
            self.inputIsMirrored = inputIsMirrored
            self.sourceGeneration = sourceGeneration
        }
    }

    init(
        onSnapshot: @escaping SnapshotHandler,
        onHandCommentSnapshot: @escaping SnapshotHandler = { _ in },
        onBottleDiagnostics: @escaping BottleDiagnosticsHandler = { _ in },
        onStatus: @escaping StatusHandler = { _ in },
        enableBottleDetector: Bool = NativeBottleDetectorContract.isV7Enabled,
        enableHand: Bool = true,
    ) {
        self.onCounterSnapshot = onSnapshot
        self.onHandCommentSnapshot = onHandCommentSnapshot
        self.onBottleDiagnostics = onBottleDiagnostics
        self.onStatus = onStatus
        self.enableBottleDetector = enableBottleDetector
        self.enableHand = enableHand
        super.init()
        configure()
    }

    /// Drop Pose/Hand joins that belong to the previous camera input. A lens
    /// replacement is an atomic AVCaptureSession change, but the two
    /// MediaPipe live-stream delegates can still return an older frame after
    /// that transaction. Clearing the join table prevents that stale frame
    /// from being published against the new camera.
    func resetPendingFrames(sourceGeneration: Int) {
        pendingLock.lock()
        pending.removeAll()
        pendingBottleDetections.removeAll()
        latestQueuedInput = nil
        admissionGate.reset()
        bottleAdmissionGate.reset()
        sourceGenerationGate.reset(to: sourceGeneration)
        telemetry.reset()
        lastBottleDetection = nil
        bottleAnchorTracker.reset()
        lastBottleDiagnostics = nil
        pendingLock.unlock()
#if DEBUG
        telemetryReportLock.lock()
        lastTelemetryReportAt = 0
        telemetryReportLock.unlock()
#endif
    }

    private func modelPath(_ name: String) -> String? {
        Bundle.main.path(forResource: name, ofType: "task")
    }

    private func modelPath(_ name: String, ofType type: String) -> String? {
        Bundle.main.path(forResource: name, ofType: type)
    }

    private func makePoseLandmarker(path: String, delegate: Delegate) throws -> PoseLandmarker {
        let options = PoseLandmarkerOptions()
        options.baseOptions = BaseOptions()
        options.baseOptions.modelAssetPath = path
        options.baseOptions.delegate = delegate
        options.runningMode = .liveStream
        options.numPoses = 1
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.poseLandmarkerLiveStreamDelegate = self
        return try PoseLandmarker(options: options)
    }

    private func makeHandLandmarker(path: String, delegate: Delegate) throws -> HandLandmarker {
        let options = HandLandmarkerOptions()
        options.baseOptions = BaseOptions()
        options.baseOptions.modelAssetPath = path
        options.baseOptions.delegate = delegate
        options.runningMode = .liveStream
        // The V2 source extractor admitted up to two hands before selecting
        // anatomical-left evidence. Preserve that selection opportunity on
        // device; the candidate selector keeps only the chosen real hand.
        options.numHands = NativeHandCandidateSelector.maximumHandCandidates
        options.minHandDetectionConfidence = 0.5
        options.minHandPresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.handLandmarkerLiveStreamDelegate = self
        return try HandLandmarker(options: options)
    }

    private func makeBottleDetector(path: String, delegate: Delegate) throws -> ObjectDetector {
        let options = ObjectDetectorOptions()
        options.baseOptions = BaseOptions()
        options.baseOptions.modelAssetPath = path
        options.baseOptions.delegate = delegate
        options.runningMode = .liveStream
        options.maxResults = 5
        options.scoreThreshold = NativeBottleDetectorContract.minimumScore
        options.categoryAllowlist = [NativeBottleDetectorContract.label]
        options.objectDetectorLiveStreamDelegate = self
        return try ObjectDetector(options: options)
    }

    private func configure() {
        guard let posePath = modelPath(NativeBottleGrabPoseDetectorContract.assetName) else {
            setupError = "Native MediaPipe requires bundled Pose Full task asset."
            onStatus(setupError ?? "Native MediaPipe Pose task asset is missing from the app bundle.")
            return
        }
        let handPath = enableHand ? modelPath("hand_landmarker") : nil
        if enableHand, !enableBottleDetector, handPath == nil {
            setupError = "Native MediaPipe requires bundled Hand task asset."
            onStatus(setupError ?? "Native MediaPipe Hand task asset is missing from the app bundle.")
            return
        }
        let bottlePath = enableBottleDetector
            ? modelPath(NativeBottleDetectorContract.assetName, ofType: NativeBottleDetectorContract.assetExtension)
            : nil
        if enableBottleDetector, bottlePath == nil {
            setupError = "App V7 requires bundled Bottle Detector model asset."
            onStatus(setupError ?? "Bottle Detector model asset is missing from the app bundle.")
            return
        }

        // Pose/Hand may use the normal device policy. The Bottle Detector has
        // a separate, CPU-only policy because MediaPipe GPU initialization can
        // SIGABRT before Swift can fall back. Keeping the factory paths split
        // is essential: one ObjectDetector crash must not change the
        // Pose/Hand source used by the full-body V7 contract.
        let requestedPreference = NativeMediaPipeDelegatePreference.resolve(arguments: ProcessInfo.processInfo.arguments)
        let bottlePreference = NativeV7BottleDelegatePolicy.resolve(requested: requestedPreference)
#if targetEnvironment(simulator)
        let poseHandDelegates: [Delegate] = [.CPU]
#else
        let poseHandDelegates: [Delegate]
        switch requestedPreference {
        case .gpu:
            poseHandDelegates = [.GPU]
        case .cpu:
            poseHandDelegates = [.CPU]
        case .automatic:
            poseHandDelegates = [.GPU, .CPU]
        }
#endif
        let bottleDelegate: Delegate = bottlePreference == .gpu ? .GPU : .CPU
        var failures: [String] = []
        for delegate in poseHandDelegates {
            do {
                let pose = try makePoseLandmarker(path: posePath, delegate: delegate)
                var hand: HandLandmarker?
                if enableHand, let handPath {
                    do {
                        hand = try makeHandLandmarker(path: handPath, delegate: delegate)
                    } catch {
                        if !enableBottleDetector { throw error }
                        failures.append("\(delegate == .GPU ? "GPU" : "CPU") Hand optional: \(error.localizedDescription)")
                    }
                }
                let bottle = try bottlePath.map { try makeBottleDetector(path: $0, delegate: bottleDelegate) }
                poseLandmarker = pose
                handLandmarker = hand
                bottleDetector = bottle
                inferenceDelegateName = enableBottleDetector && delegate == .GPU
                    ? "Pose/Hand GPU · Bottle CPU"
                    : "CPU"
                setupError = nil
                onStatus(enableBottleDetector
                    ? "Native MediaPipe Pose Full + Bottle Detector · \(inferenceDelegateName) live stream"
                    : "Native MediaPipe Pose Full · \(inferenceDelegateName) live stream")
                return
            } catch {
                poseLandmarker = nil
                handLandmarker = nil
                bottleDetector = nil
                let name = delegate == .GPU ? "Pose/Hand GPU" : "CPU"
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        setupError = "MediaPipe setup failed: \(failures.joined(separator: " | "))"
        onStatus(setupError ?? "MediaPipe setup failed.")
    }

    func process(
        sampleBuffer: CMSampleBuffer,
        timestampMs: Int,
        inputIsMirrored: Bool,
        sourceGeneration: Int,
    ) {
        guard poseLandmarker != nil,
              (!enableBottleDetector ? (!enableHand || handLandmarker != nil) : bottleDetector != nil) else { return }
        let input = QueuedInput(
            sampleBuffer: sampleBuffer,
            timestampMs: timestampMs,
            inputIsMirrored: inputIsMirrored,
            sourceGeneration: sourceGeneration,
        )
        if let admitted = admitOrCoalesce(input) {
            submit(admitted)
        }
    }

    /// Admit one newest frame for the three-engine camera fan-out. If a request is
    /// already active, replace the mailbox item rather than queueing work. A
    /// callback that outlives the bounded live budget is removed before the
    /// replacement is submitted, so it cannot later paint stale landmarks.
    private func admitOrCoalesce(_ input: QueuedInput) -> QueuedInput? {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(input.sampleBuffer) else {
            return nil
        }
        // A coalesced callback may resume after a camera/lens reset. The
        // reset holds this same lock and advances the source generation, so
        // stale work is discarded before it can reserve another inference.
        guard sourceGenerationGate.accepts(input.sourceGeneration) else {
            return nil
        }
        prunePublishedHandContexts(through: input.timestampMs)
        telemetry.recordSubmitted()
        let admission = admissionGate.admit(
            timestampMs: input.timestampMs,
            now: CACurrentMediaTime(),
        )
        guard case let .admitted(expiredTimestampMs) = admission else {
            telemetry.recordCoalesced()
            latestQueuedInput = input
            return nil
        }
        if let expiredTimestampMs {
            pending.removeValue(forKey: expiredTimestampMs)
        }
        // This input is newer than any previously coalesced frame.
        latestQueuedInput = nil
        pending[input.timestampMs] = PendingDetection(
            inputIsMirrored: input.inputIsMirrored,
            sourceGeneration: input.sourceGeneration,
            imageWidth: CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
            imageHeight: CGFloat(CVPixelBufferGetHeight(pixelBuffer)),
        )
        return input
    }

    /// Submit after the admission gate has created a matching frame context. No
    /// image conversion happens for a frame that was merely coalesced.
    private func submit(_ input: QueuedInput) {
        pendingLock.lock()
        let isCurrentInput = sourceGenerationGate.accepts(input.sourceGeneration)
            && pending[input.timestampMs] != nil
        pendingLock.unlock()
        // A reset that arrived after a frame left the mailbox clears its context
        // and generation. Do not start a detector request that cannot ever
        // publish, because it would consume the bounded live-inference slot.
        guard isCurrentInput else { return }
        guard let poseLandmarker else {
            abandon(timestampMs: input.timestampMs)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(input.sampleBuffer) else {
            abandon(timestampMs: input.timestampMs)
            return
        }
        let image: MPImage
        do {
            // CameraSession applies portrait orientation to the exact video
            // output connection. Passing `.up` preserves that transformed
            // buffer and avoids a second per-frame rotation/copy before the
            // two detectors run. Preview and inference therefore share the
            // same coordinate orientation.
            image = try MPImage(sampleBuffer: input.sampleBuffer, orientation: .up)
        } catch {
            setupError = "Could not create an MPImage: \(error.localizedDescription)"
            abandon(timestampMs: input.timestampMs)
            return
        }

        do {
            _ = try poseLandmarker.detectAsync(image: image, timestampInMilliseconds: input.timestampMs)
        } catch {
            setupError = "Pose live-stream submission failed: \(error.localizedDescription)"
            abandon(timestampMs: input.timestampMs)
            return
        }
        if let handLandmarker {
            do {
                _ = try handLandmarker.detectAsync(image: image, timestampInMilliseconds: input.timestampMs)
            } catch {
                setupError = "Hand live-stream submission failed: \(error.localizedDescription)"
                if enableHand && !enableBottleDetector {
                    abandon(timestampMs: input.timestampMs)
                    return
                }
                pendingLock.lock()
                pending[input.timestampMs]?.handCandidates = []
                pendingLock.unlock()
                publishCounterSnapshotIfReady(timestampMs: input.timestampMs)
                publishHandCommentSnapshotIfReady(timestampMs: input.timestampMs)
            }
        }
        submitBottleDetectorIfScheduled(image: image, input: input, pixelBuffer: pixelBuffer)
    }

    /// Submit ObjectDetector at a bounded CPU cadence. Unlike the old gated
    /// V7.3 route, this never keeps the latest Pose/Hand snapshot waiting for
    /// a detector callback. The counter still rejects a cache entry older than
    /// its frozen 350 ms maximum age.
    private func submitBottleDetectorIfScheduled(
        image: MPImage,
        input: QueuedInput,
        pixelBuffer: CVPixelBuffer,
    ) {
        guard let bottleDetector else { return }
        pendingLock.lock()
        guard sourceGenerationGate.accepts(input.sourceGeneration) else {
            pendingLock.unlock()
            return
        }
        let decision = bottleAdmissionGate.admit(
            timestampMs: input.timestampMs,
            now: CACurrentMediaTime(),
        )
        guard case let .admitted(expiredTimestampMs) = decision else {
            pendingLock.unlock()
            return
        }
        if let expiredTimestampMs {
            pendingBottleDetections.removeValue(forKey: expiredTimestampMs)
        }
        pendingBottleDetections[input.timestampMs] = PendingBottleDetection(
            sourceGeneration: input.sourceGeneration,
            imageWidth: CGFloat(CVPixelBufferGetWidth(pixelBuffer)),
            imageHeight: CGFloat(CVPixelBufferGetHeight(pixelBuffer)),
        )
        pendingLock.unlock()

        do {
            _ = try bottleDetector.detectAsync(image: image, timestampInMilliseconds: input.timestampMs)
        } catch {
            let bottleDiagnostics: NativeBottleDetectorDiagnostics
            pendingLock.lock()
            pendingBottleDetections.removeValue(forKey: input.timestampMs)
            bottleAdmissionGate.complete(timestampMs: input.timestampMs)
            bottleDiagnostics = NativeBottleDetectorDiagnostics.failure(
                sourceGeneration: input.sourceGeneration,
                callbackTimestampMs: input.timestampMs,
                message: error.localizedDescription,
            )
            lastBottleDiagnostics = bottleDiagnostics
            pendingLock.unlock()
            emitBottleDiagnostics(bottleDiagnostics: bottleDiagnostics)
            reportLiveError("Bottle Detector live-stream submission failed: \(error.localizedDescription)")
        }
    }

    /// Submission can fail after a companion engine accepted its request.
    /// Remove the frame context atomically; any late successful callback is then
    /// discarded instead of publishing a half-frame or holding the gate.
    private func abandon(timestampMs: Int) {
        pendingLock.lock()
        pending.removeValue(forKey: timestampMs)
        admissionGate.complete(timestampMs: timestampMs)
        pendingLock.unlock()
        submitNewestQueuedInputIfPossible()
    }

    private func submitNewestQueuedInputIfPossible() {
        let next: QueuedInput?
        pendingLock.lock()
        next = latestQueuedInput
        latestQueuedInput = nil
        pendingLock.unlock()
        guard let next else { return }
        if let admitted = admitOrCoalesce(next) {
            submit(admitted)
        }
    }

    /// Once a counter snapshot has been delivered, retain its context only
    /// long enough for its asynchronous Hand callback to produce a secondary
    /// comment. The counter has already progressed and must not be held by
    /// this cleanup window.
    private func prunePublishedHandContexts(through timestampMs: Int) {
        let maximumAgeMs = Int(NativeInferenceAdmissionGate.maximumInFlightAge * 1_000)
        pending = pending.filter { timestamp, item in
            !item.counterPublished || timestampMs - timestamp <= maximumAgeMs
        }
    }

    /// Publishes the authoritative V7 counter input as soon as Pose is ready.
    /// Hand and Bottle execute on the same camera frame, but neither callback
    /// is allowed to delay or reset the Pose+Bottle proximity counter. V7.3.4
    /// supplies a confirmed Bottle checkpoint separately from a fresh callback;
    /// a detector dropout cannot by itself erase that checkpoint.
    private func publishCounterSnapshotIfReady(timestampMs: Int) {
        let snapshot: NativeFrameSnapshot
        let telemetrySnapshot: NativeMediaPipeTelemetry
        let bottleDiagnostics: NativeBottleDetectorDiagnostics?

        pendingLock.lock()
        guard let item = pending[timestampMs],
              !item.counterPublished,
              let pose = item.pose else {
            pendingLock.unlock()
            return
        }

        item.counterPublished = true
        admissionGate.complete(timestampMs: timestampMs)
        let latencyMs = max(0, (CACurrentMediaTime() - item.startedAt) * 1000)
        // Counter provenance must remain independent of the Hand Landmarker.
        telemetry.recordJoined(
            handCandidateCount: 0,
            selectedSide: nil,
            latencyMs: latencyMs,
        )
        let bottleSelection: NativeBottleDetectionSelection?
        let bottleAnchorSnapshot: NativeBottleAnchorSnapshot
        if enableBottleDetector {
            let cachedBottleDetections: [NativeBottleDetection] = lastBottleDetection.map { [$0] } ?? []
            bottleSelection = NativeBottleDetectionSelector.select(
                detections: cachedBottleDetections,
                sourceGeneration: item.sourceGeneration,
                timestampMs: timestampMs,
                previous: nil,
            )
            lastBottleDetection = bottleSelection?.detection
            bottleAnchorSnapshot = bottleAnchorTracker.current
            bottleDiagnostics = (lastBottleDiagnostics
                ?? NativeBottleDetectorDiagnostics.waiting(
                    sourceGeneration: item.sourceGeneration,
                    observedTimestampMs: timestampMs,
                ))
                .observing(
                    sourceGeneration: item.sourceGeneration,
                    timestampMs: timestampMs,
                )
                .attaching(anchorSnapshot: bottleAnchorSnapshot)
        } else {
            bottleSelection = nil
            bottleDiagnostics = nil
            bottleAnchorSnapshot = NativeBottleAnchorSnapshot(anchor: nil, state: .waiting)
        }
        snapshot = NativeFrameSnapshot(
            timestampMs: timestampMs,
            sourceGeneration: item.sourceGeneration,
            inputIsMirrored: item.inputIsMirrored,
            pose: pose,
            hand: [],
            handSide: nil,
            handSideSource: enableHand ? "hand_secondary_pending" : nil,
            handCandidateTrace: enableHand ? "hand_secondary_pending" : nil,
            handScore: 0,
            detectorLatencyMs: latencyMs,
            bottleDetection: bottleSelection?.detection,
            bottleAnchor: bottleAnchorSnapshot.anchor,
        )
        pending[timestampMs] = item
        telemetrySnapshot = telemetry
        pendingLock.unlock()

        setupError = nil
        onStatus(enableBottleDetector
            ? "Native MediaPipe Pose Full + Bottle Detector \(inferenceDelegateName) live stream"
            : "Native MediaPipe \(inferenceDelegateName) live stream")
        reportTelemetryIfDue(telemetrySnapshot)
        // Let the next camera frame proceed before the counter/UI consumes the
        // current observation. Hand may finish later on its secondary lane.
        submitNewestQueuedInputIfPossible()
        onCounterSnapshot(snapshot)
        if let bottleDiagnostics {
            emitBottleDiagnostics(bottleDiagnostics: bottleDiagnostics)
        }
        publishHandCommentSnapshotIfReady(timestampMs: timestampMs)
    }

    /// Publishes Hand only to the secondary finger-comment lane. It never
    /// calls the authoritative counter handler, so a slow, absent, right-side,
    /// or low-quality Hand result cannot increment, suppress, or reset reps.
    private func publishHandCommentSnapshotIfReady(timestampMs: Int) {
        let snapshot: NativeFrameSnapshot

        pendingLock.lock()
        guard let item = pending[timestampMs],
              item.counterPublished,
              let pose = item.pose,
              let handCandidates = item.handCandidates else {
            pendingLock.unlock()
            return
        }

        pending.removeValue(forKey: timestampMs)
        let selection = NativeHandCandidateSelector.select(
            candidates: handCandidates,
            pose: pose,
            inputIsMirrored: item.inputIsMirrored,
        )
        snapshot = NativeFrameSnapshot(
            timestampMs: timestampMs,
            sourceGeneration: item.sourceGeneration,
            inputIsMirrored: item.inputIsMirrored,
            pose: pose,
            hand: selection.candidate?.landmarks ?? [],
            handSide: selection.side,
            handSideSource: selection.source,
            handCandidateTrace: selection.compactCandidateTrace,
            handScore: selection.candidate?.score ?? 0,
            detectorLatencyMs: max(0, (CACurrentMediaTime() - item.startedAt) * 1000),
            bottleDetection: nil,
        )
        pendingLock.unlock()

        onHandCommentSnapshot(snapshot)
    }

    private func normalized(_ points: [NormalizedLandmark]) -> [NativeLandmark] {
        points.map {
            NativeLandmark(
                x: $0.x,
                y: $0.y,
                z: $0.z,
                visibility: $0.visibility?.floatValue ?? 1,
            )
        }
    }

    func poseLandmarker(_ poseLandmarker: PoseLandmarker,
                        didFinishDetection result: PoseLandmarkerResult?,
                        timestampInMilliseconds: Int,
                        error: Error?) {
        if let error {
            reportLiveError("Pose detection failed: \(error.localizedDescription)")
            abandon(timestampMs: timestampInMilliseconds)
            return
        }
        pendingLock.lock()
        // Do not recreate a join after a camera/lens source reset. A late
        // callback must be discarded rather than mixed with a newer stream.
        guard let item = pending[timestampInMilliseconds] else {
            pendingLock.unlock()
            return
        }
        telemetry.recordPoseCallback()
        item.pose = normalized(result?.landmarks.first ?? [])
        pending[timestampInMilliseconds] = item
        pendingLock.unlock()
        publishCounterSnapshotIfReady(timestampMs: timestampInMilliseconds)
        publishHandCommentSnapshotIfReady(timestampMs: timestampInMilliseconds)
    }

    func handLandmarker(_ handLandmarker: HandLandmarker,
                        didFinishDetection result: HandLandmarkerResult?,
                        timestampInMilliseconds: Int,
                        error: Error?) {
        if let error {
            reportLiveError("Hand detection failed: \(error.localizedDescription)")
            if enableBottleDetector {
                pendingLock.lock()
                if let item = pending[timestampInMilliseconds] {
                    item.handCandidates = []
                    pending[timestampInMilliseconds] = item
                }
                pendingLock.unlock()
                publishCounterSnapshotIfReady(timestampMs: timestampInMilliseconds)
                publishHandCommentSnapshotIfReady(timestampMs: timestampInMilliseconds)
                return
            }
            abandon(timestampMs: timestampInMilliseconds)
            return
        }
        pendingLock.lock()
        // See the Pose callback: callbacks without an active frame context belong to
        // a cleared/previous source generation and must fail closed.
        guard let item = pending[timestampInMilliseconds] else {
            pendingLock.unlock()
            return
        }
        let rawLandmarks = result?.landmarks ?? []
        telemetry.recordHandCallback(candidateCount: rawLandmarks.count)
        let handedness = result?.handedness ?? []
        item.handCandidates = rawLandmarks.enumerated().map { index, points in
            let category = handedness.indices.contains(index) ? handedness[index].first : nil
            return NativeHandCandidate(
                index: index,
                landmarks: normalized(points),
                detectorSide: category?.categoryName ?? category?.displayName,
                score: category?.score ?? 0,
            )
        }
        pending[timestampInMilliseconds] = item
        pendingLock.unlock()
        publishCounterSnapshotIfReady(timestampMs: timestampInMilliseconds)
        publishHandCommentSnapshotIfReady(timestampMs: timestampInMilliseconds)
    }

    func objectDetector(
        _ objectDetector: ObjectDetector,
        didFinishDetection result: ObjectDetectorResult?,
        timestampInMilliseconds: Int,
        error: Error?,
    ) {
        guard enableBottleDetector else { return }
        if let error {
            let bottleDiagnostics: NativeBottleDetectorDiagnostics?
            pendingLock.lock()
            let item = pendingBottleDetections.removeValue(forKey: timestampInMilliseconds)
            bottleAdmissionGate.complete(timestampMs: timestampInMilliseconds)
            if let item, sourceGenerationGate.accepts(item.sourceGeneration) {
                let bottleAnchorSnapshot = bottleAnchorTracker.observe(
                    detection: nil,
                    sourceGeneration: item.sourceGeneration,
                    timestampMs: timestampInMilliseconds,
                )
                let diagnostic = NativeBottleDetectorDiagnostics.failure(
                    sourceGeneration: item.sourceGeneration,
                    callbackTimestampMs: timestampInMilliseconds,
                    message: error.localizedDescription,
                ).attaching(anchorSnapshot: bottleAnchorSnapshot)
                lastBottleDiagnostics = diagnostic
                bottleDiagnostics = diagnostic
            } else {
                bottleDiagnostics = nil
            }
            pendingLock.unlock()
            if let bottleDiagnostics {
                emitBottleDiagnostics(bottleDiagnostics: bottleDiagnostics)
            }
            reportLiveError("Bottle Detector failed: \(error.localizedDescription)")
            return
        }
        pendingLock.lock()
        guard let item = pendingBottleDetections.removeValue(forKey: timestampInMilliseconds) else {
            pendingLock.unlock()
            return
        }
        bottleAdmissionGate.complete(timestampMs: timestampInMilliseconds)
        guard sourceGenerationGate.accepts(item.sourceGeneration) else {
            pendingLock.unlock()
            return
        }
        let width = item.imageWidth
        let height = item.imageHeight
        let rawDetections = result?.detections ?? []
        var topLabel: String?
        var topScore: Float?
        var detections: [NativeBottleDetection] = []
        for rawDetection in rawDetections {
            guard let category = rawDetection.categories.first else { continue }
            if topScore.map({ category.score > $0 }) ?? true {
                topLabel = category.categoryName ?? category.displayName
                topScore = category.score
            }
            guard width > 0, height > 0,
                  let label = category.categoryName else { continue }
            let box = rawDetection.boundingBox
            let normalized = CGRect(
                x: box.origin.x / width,
                y: box.origin.y / height,
                width: box.width / width,
                height: box.height / height,
            )
            detections.append(NativeBottleDetection(
                sourceGeneration: item.sourceGeneration,
                timestampMs: timestampInMilliseconds,
                label: label,
                score: category.score,
                boundingBox: normalized,
            ))
        }
        let selection = NativeBottleDetectionSelector.select(
            detections: detections,
            sourceGeneration: item.sourceGeneration,
            timestampMs: timestampInMilliseconds,
            previous: lastBottleDetection ?? bottleAnchorTracker.current.anchor?.detection,
        )
        lastBottleDetection = selection.detection
        let bottleAnchorSnapshot = bottleAnchorTracker.observe(
            detection: selection.detection,
            sourceGeneration: item.sourceGeneration,
            timestampMs: timestampInMilliseconds,
        )
        let bottleDiagnostics = NativeBottleDetectorDiagnostics.result(
            sourceGeneration: item.sourceGeneration,
            callbackTimestampMs: timestampInMilliseconds,
            selection: selection,
            rawDetectionCount: rawDetections.count,
            topLabel: topLabel,
            topScore: topScore,
        ).attaching(anchorSnapshot: bottleAnchorSnapshot)
        lastBottleDiagnostics = bottleDiagnostics
        pendingLock.unlock()
        emitBottleDiagnostics(bottleDiagnostics: bottleDiagnostics)
    }

    private func completeBottleDetection(timestampMs: Int) {
        pendingLock.lock()
        pendingBottleDetections.removeValue(forKey: timestampMs)
        bottleAdmissionGate.complete(timestampMs: timestampMs)
        pendingLock.unlock()
    }

    private func reportLiveError(_ message: String) {
        setupError = message
        onStatus(message)
    }

    /// Keep Detector health out of the counter callback. The handler is called
    /// only after the lock is released, and callers must treat it as display /
    /// diagnostics evidence rather than a count-control signal.
    private func emitBottleDiagnostics(bottleDiagnostics: NativeBottleDetectorDiagnostics) {
        onBottleDiagnostics(bottleDiagnostics)
    }

#if DEBUG
    private func reportTelemetryIfDue(_ snapshot: NativeMediaPipeTelemetry) {
        let now = CACurrentMediaTime()
        telemetryReportLock.lock()
        defer { telemetryReportLock.unlock() }
        guard now - lastTelemetryReportAt >= 2 else { return }
        lastTelemetryReportAt = now
        print(
            "[PhysioAINative][MediaPipeTelemetry] "
                + "delegate=\(inferenceDelegateName) "
                + "submitted=\(snapshot.submittedFrames) "
                + "coalesced=\(snapshot.coalescedFrames) "
                + "poseCallbacks=\(snapshot.poseCallbacks) "
                + "handCallbacks=\(snapshot.handCallbacks) "
                + "joined=\(snapshot.joinedSnapshots) "
                + "emptyHand=\(snapshot.emptyHandSnapshots) "
                + "selectedLeft=\(snapshot.selectedLeftSnapshots) "
                + "fallbackOrNoLeft=\(snapshot.fallbackOrNoLeftSnapshots) "
                + String(format: "avgLatencyMs=%.1f", snapshot.averageLatencyMs),
        )
    }
#else
    private func reportTelemetryIfDue(_ snapshot: NativeMediaPipeTelemetry) {}
#endif
}
