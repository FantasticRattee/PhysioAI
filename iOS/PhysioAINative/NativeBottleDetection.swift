import Foundation
import Darwin

/// A single on-device bottle bounding-box observation. The box is normalized
/// to the same oriented image buffer used by Pose, so the proximity counter
/// can compare it with normalized Pose landmarks without a second UI crop.
struct NativeBottleDetection: Equatable {
    let sourceGeneration: Int
    let timestampMs: Int
    let label: String
    let score: Float
    let boundingBox: CGRect
}

struct NativeBottleDetectionSelection: Equatable {
    let detection: NativeBottleDetection?
    let reason: String
    let candidateCount: Int
}

/// The source of a Bottle Grab checkpoint. It deliberately describes the
/// checkpoint lifecycle separately from the fresh ObjectDetector callback so a
/// held anchor is never presented as a newly detected ROI.
enum NativeBottleAnchorState: String, Equatable {
    case waiting = "anchor_waiting"
    case provisional = "anchor_provisional"
    case confirmed = "anchor_confirmed"
    case held = "anchor_held"
    case reconfirmed = "anchor_reconfirmed"
    case relocationProvisional = "anchor_relocation_provisional"
    case relocated = "anchor_relocated"

    var isConfirmed: Bool {
        switch self {
        case .confirmed, .held, .reconfirmed, .relocationProvisional, .relocated:
            return true
        case .waiting, .provisional:
            return false
        }
    }
}

/// A confirmed static Bottle Grab location. `detection.timestampMs` stays the
/// timestamp of the detector callback that supplied the geometry; it is never
/// rewritten to masquerade as a fresh detector observation.
struct NativeBottleAnchor: Equatable {
    let sourceGeneration: Int
    let detection: NativeBottleDetection
    let acquiredAtMs: Int
    let lastConfirmedAtMs: Int
    let state: NativeBottleAnchorState
}

struct NativeBottleAnchorSnapshot: Equatable {
    let anchor: NativeBottleAnchor?
    let state: NativeBottleAnchorState
}

/// Pure temporal policy for a Bottle Grab checkpoint. `MediaPipePipeline`
/// owns one instance under its pending-data lock and feeds it only accepted
/// detector candidates. It retains a confirmed physical location through
/// detector dropouts but never fabricates a fresh detector timestamp.
final class NativeBottleAnchorTracker {
    private let nearbyIoU: CGFloat
    private let relocationMaximumIoU: CGFloat
    private let relocationMinimumCenterDistance: CGFloat
    private let confirmationsRequired: Int
    private var sourceGeneration: Int?
    private var acquisitionCandidate: NativeBottleDetection?
    private var acquisitionCount = 0
    private var relocationCandidate: NativeBottleDetection?
    private var relocationCount = 0
    private var lastDetectorTimestampMs: Int?
    private(set) var current = NativeBottleAnchorSnapshot(anchor: nil, state: .waiting)

    init(
        nearbyIoU: CGFloat = 0.50,
        relocationMaximumIoU: CGFloat = 0.20,
        relocationMinimumCenterDistance: CGFloat = 0.15,
        confirmationsRequired: Int = 2,
    ) {
        self.nearbyIoU = min(1, max(0, nearbyIoU))
        self.relocationMaximumIoU = min(1, max(0, relocationMaximumIoU))
        self.relocationMinimumCenterDistance = max(0, relocationMinimumCenterDistance)
        self.confirmationsRequired = max(2, confirmationsRequired)
    }

    func observe(
        detection: NativeBottleDetection?,
        sourceGeneration: Int,
        timestampMs: Int,
    ) -> NativeBottleAnchorSnapshot {
        if let currentSource = self.sourceGeneration, currentSource != sourceGeneration {
            reset()
        }
        self.sourceGeneration = sourceGeneration

        // Every callback, including a miss/error represented as `nil`, advances
        // the detector ordering fence. A delayed older positive result must not
        // relocate an anchor after a newer callback has already been observed.
        guard lastDetectorTimestampMs.map({ timestampMs > $0 }) ?? true else {
            return current
        }
        lastDetectorTimestampMs = timestampMs

        guard let detection,
              detection.sourceGeneration == sourceGeneration else {
            return holdOrWait()
        }

        guard let anchor = current.anchor else {
            return acquire(detection: detection, timestampMs: timestampMs)
        }

        if isNearby(detection.boundingBox, anchor.detection.boundingBox) {
            clearRelocationCandidate()
            current = NativeBottleAnchorSnapshot(
                anchor: anchored(
                    anchor,
                    state: .reconfirmed,
                    lastConfirmedAtMs: timestampMs,
                ),
                state: .reconfirmed,
            )
            return current
        }

        guard isClearlyRelocated(detection.boundingBox, from: anchor.detection.boundingBox) else {
            clearRelocationCandidate()
            current = NativeBottleAnchorSnapshot(
                anchor: anchored(anchor, state: .held),
                state: .held,
            )
            return current
        }

        if let relocationCandidate,
           isNearby(detection.boundingBox, relocationCandidate.boundingBox) {
            relocationCount += 1
        } else {
            relocationCandidate = detection
            relocationCount = 1
        }

        guard relocationCount >= confirmationsRequired,
              let relocationCandidate else {
            current = NativeBottleAnchorSnapshot(
                anchor: anchored(anchor, state: .relocationProvisional),
                state: .relocationProvisional,
            )
            return current
        }

        let relocated = NativeBottleAnchor(
            sourceGeneration: sourceGeneration,
            detection: relocationCandidate,
            acquiredAtMs: relocationCandidate.timestampMs,
            lastConfirmedAtMs: timestampMs,
            state: .relocated,
        )
        clearAcquisitionCandidate()
        clearRelocationCandidate()
        current = NativeBottleAnchorSnapshot(anchor: relocated, state: .relocated)
        return current
    }

    func reset() {
        sourceGeneration = nil
        lastDetectorTimestampMs = nil
        clearAcquisitionCandidate()
        clearRelocationCandidate()
        current = NativeBottleAnchorSnapshot(anchor: nil, state: .waiting)
    }

    private func acquire(
        detection: NativeBottleDetection,
        timestampMs: Int,
    ) -> NativeBottleAnchorSnapshot {
        if let acquisitionCandidate,
           isNearby(detection.boundingBox, acquisitionCandidate.boundingBox) {
            acquisitionCount += 1
        } else {
            acquisitionCandidate = detection
            acquisitionCount = 1
        }

        guard acquisitionCount >= confirmationsRequired,
              let acquisitionCandidate else {
            current = NativeBottleAnchorSnapshot(anchor: nil, state: .provisional)
            return current
        }

        let anchor = NativeBottleAnchor(
            sourceGeneration: sourceGeneration ?? detection.sourceGeneration,
            detection: acquisitionCandidate,
            acquiredAtMs: acquisitionCandidate.timestampMs,
            lastConfirmedAtMs: timestampMs,
            state: .confirmed,
        )
        clearAcquisitionCandidate()
        current = NativeBottleAnchorSnapshot(anchor: anchor, state: .confirmed)
        return current
    }

    private func holdOrWait() -> NativeBottleAnchorSnapshot {
        guard let anchor = current.anchor else {
            return current
        }
        current = NativeBottleAnchorSnapshot(
            anchor: anchored(anchor, state: .held),
            state: .held,
        )
        return current
    }

    private func anchored(
        _ anchor: NativeBottleAnchor,
        state: NativeBottleAnchorState,
        lastConfirmedAtMs: Int? = nil,
    ) -> NativeBottleAnchor {
        NativeBottleAnchor(
            sourceGeneration: anchor.sourceGeneration,
            detection: anchor.detection,
            acquiredAtMs: anchor.acquiredAtMs,
            lastConfirmedAtMs: lastConfirmedAtMs ?? anchor.lastConfirmedAtMs,
            state: state,
        )
    }

    private func clearAcquisitionCandidate() {
        acquisitionCandidate = nil
        acquisitionCount = 0
    }

    private func clearRelocationCandidate() {
        relocationCandidate = nil
        relocationCount = 0
    }

    private func isNearby(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        intersectionOverUnion(lhs, rhs) >= nearbyIoU
    }

    private func isClearlyRelocated(_ candidate: CGRect, from anchor: CGRect) -> Bool {
        intersectionOverUnion(candidate, anchor) < relocationMaximumIoU
            && centerDistance(candidate, anchor) >= relocationMinimumCenterDistance
    }

    private func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }

    private func centerDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = lhs.midX - rhs.midX
        let dy = lhs.midY - rhs.midY
        return sqrt(dx * dx + dy * dy)
    }
}

/// Aggregate-only health/status evidence for the native Bottle Detector.
/// It is intentionally separate from `NativeBottleProximityCounter`: the
/// status may explain why a frame cannot count, but it cannot alter the
/// frozen Baseline #5 detector, threshold, ROI, or counter state machine.
struct NativeBottleDetectorDiagnostics: Equatable {
    let sourceGeneration: Int
    /// Timestamp of the most recent detector callback, if one has completed.
    let callbackTimestampMs: Int?
    /// Timestamp of the Pose/counter frame currently presenting this status.
    let observedTimestampMs: Int
    let status: String
    let selectionReason: String
    /// Number of detections returned by the configured ObjectDetector task.
    /// It is not raw media and does not claim that any result is a bottle.
    let rawDetectionCount: Int
    /// Number of valid Bottle candidates remaining after the frozen label,
    /// score, source, freshness, and rectangle checks.
    let acceptedBottleCount: Int
    let topLabel: String?
    let topScore: Float?
    /// Present only for a currently fresh, accepted Bottle ROI. This exists so
    /// the preview can draw a local diagnostic outline; it is never persisted.
    let acceptedDetection: NativeBottleDetection?
    let errorMessage: String?
    /// The checkpoint state is separate from `status`: a held anchor is not a
    /// claim that the detector saw the bottle in this frame.
    let anchorState: NativeBottleAnchorState
    let anchorTimestampMs: Int?

    var ageMs: Int? {
        guard let callbackTimestampMs else { return nil }
        return max(0, observedTimestampMs - callbackTimestampMs)
    }

    static func waiting(
        sourceGeneration: Int,
        observedTimestampMs: Int,
    ) -> NativeBottleDetectorDiagnostics {
        NativeBottleDetectorDiagnostics(
            sourceGeneration: sourceGeneration,
            callbackTimestampMs: nil,
            observedTimestampMs: observedTimestampMs,
            status: "detector_waiting",
            selectionReason: "awaiting_callback",
            rawDetectionCount: 0,
            acceptedBottleCount: 0,
            topLabel: nil,
            topScore: nil,
            acceptedDetection: nil,
            errorMessage: nil,
            anchorState: .waiting,
            anchorTimestampMs: nil,
        )
    }

    static func result(
        sourceGeneration: Int,
        callbackTimestampMs: Int,
        selection: NativeBottleDetectionSelection,
        rawDetectionCount: Int,
        topLabel: String?,
        topScore: Float?,
    ) -> NativeBottleDetectorDiagnostics {
        NativeBottleDetectorDiagnostics(
            sourceGeneration: sourceGeneration,
            callbackTimestampMs: callbackTimestampMs,
            observedTimestampMs: callbackTimestampMs,
            status: selection.detection == nil ? selection.reason : "bottle_detected",
            selectionReason: selection.reason,
            rawDetectionCount: max(0, rawDetectionCount),
            acceptedBottleCount: max(0, selection.candidateCount),
            topLabel: topLabel,
            topScore: topScore,
            acceptedDetection: selection.detection,
            errorMessage: nil,
            anchorState: .waiting,
            anchorTimestampMs: nil,
        )
    }

    static func failure(
        sourceGeneration: Int,
        callbackTimestampMs: Int,
        message: String,
    ) -> NativeBottleDetectorDiagnostics {
        NativeBottleDetectorDiagnostics(
            sourceGeneration: sourceGeneration,
            callbackTimestampMs: callbackTimestampMs,
            observedTimestampMs: callbackTimestampMs,
            status: "detector_error",
            selectionReason: "detector_error",
            rawDetectionCount: 0,
            acceptedBottleCount: 0,
            topLabel: nil,
            topScore: nil,
            acceptedDetection: nil,
            errorMessage: message,
            anchorState: .waiting,
            anchorTimestampMs: nil,
        )
    }

    /// Converts one callback result into the status that belongs beside a
    /// later Pose/counter frame. A stale/result from another camera generation
    /// is shown explicitly and its ROI is withheld from the diagnostic overlay.
    func observing(
        sourceGeneration: Int,
        timestampMs: Int,
    ) -> NativeBottleDetectorDiagnostics {
        let sameSource = self.sourceGeneration == sourceGeneration
        let age = callbackTimestampMs.map { max(0, timestampMs - $0) }
        let nextStatus: String
        if !sameSource {
            nextStatus = "source_changed"
        } else if let age, age > NativeBottleDetectorContract.maximumDetectionAgeMs {
            nextStatus = status == "bottle_detected" ? "bottle_stale" : "detector_stale"
        } else {
            nextStatus = status
        }
        return NativeBottleDetectorDiagnostics(
            sourceGeneration: sourceGeneration,
            callbackTimestampMs: callbackTimestampMs,
            observedTimestampMs: timestampMs,
            status: nextStatus,
            selectionReason: selectionReason,
            rawDetectionCount: rawDetectionCount,
            acceptedBottleCount: acceptedBottleCount,
            topLabel: topLabel,
            topScore: topScore,
            acceptedDetection: nextStatus == "bottle_detected" ? acceptedDetection : nil,
            errorMessage: errorMessage,
            anchorState: anchorState,
            anchorTimestampMs: anchorTimestampMs,
        )
    }

    func attaching(anchorSnapshot: NativeBottleAnchorSnapshot) -> NativeBottleDetectorDiagnostics {
        NativeBottleDetectorDiagnostics(
            sourceGeneration: sourceGeneration,
            callbackTimestampMs: callbackTimestampMs,
            observedTimestampMs: observedTimestampMs,
            status: status,
            selectionReason: selectionReason,
            rawDetectionCount: rawDetectionCount,
            acceptedBottleCount: acceptedBottleCount,
            topLabel: topLabel,
            topScore: topScore,
            acceptedDetection: acceptedDetection,
            errorMessage: errorMessage,
            anchorState: anchorSnapshot.state,
            anchorTimestampMs: anchorSnapshot.anchor?.detection.timestampMs,
        )
    }
}

enum NativeBottleDetectorContract {
    static let assetName = "efficientdet_lite0"
    static let assetExtension = "tflite"
    static let label = "bottle"
    static let modelVersion = "mediapipe-efficientdet-lite0-coco-v1-dev"
    static let modelSHA256 = "40338edf5ec70d43e318b0a716a84d4564cd1802759a7a07170c7e43796dbf58"
    static let minimumScore: Float = 0.35
    static let ambiguityMargin: Float = 0.05
    static let roiMargin: CGFloat = 0.02
    static let maximumDetectionAgeMs = 350

    static var isV7Enabled: Bool {
#if DEBUG
        // V7.3 is the local combined native build: Bottle Grab takes the
        // frozen Baseline #5 + V7.1 TTS presentation path by default, while
        // Sit-to-Stand dispatches through its own V7.2 module. Release stays
        // fail-closed; the historical V6 branches remain rollback routes.
        return true
#else
        return false
#endif
    }
}

/// Pure selection/geometry policy for the V7 object-detector result. It is
/// deliberately independent of MediaPipe so the model-asset and camera
/// integration can be tested with deterministic boxes first.
/// Crash containment for the V7.3.1 Bottle Grab MediaPipe ObjectDetector.
///
/// Physical reports from multiple iPhone classes show
/// that `TensorsToDetectionsCalculator::GpuInit` may abort the process before
/// Swift can run a GPU-to-CPU fallback. The Bottle Detector must therefore
/// stay on CPU for every hardware identifier. This policy applies only to the
/// ObjectDetector; Pose/Hand can still use their independently selected
/// delegate after the V7.3.1 transport split. Pose-only Sit-to-Stand never
/// consults this policy.
enum NativeV7BottleDelegatePolicy {
    static func resolve(
        requested: NativeMediaPipeDelegateMode,
        hardwareIdentifier: String = currentHardwareIdentifier(),
    ) -> NativeMediaPipeDelegateMode {
        _ = requested
        _ = hardwareIdentifier
        return .cpu
    }

    private static func currentHardwareIdentifier() -> String {
#if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? "simulator"
#else
        var system = utsname()
        uname(&system)
        var machine = system.machine
        let capacity = MemoryLayout.size(ofValue: machine)
        return withUnsafePointer(to: &machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
#endif
    }
}

enum NativeBottleDetectionSelector {
    static func select(
        detections: [NativeBottleDetection],
        sourceGeneration: Int,
        timestampMs: Int,
        previous: NativeBottleDetection? = nil,
    ) -> NativeBottleDetectionSelection {
        let candidates = detections.filter { detection in
            detection.sourceGeneration == sourceGeneration
                && detection.timestampMs <= timestampMs
                && timestampMs - detection.timestampMs <= NativeBottleDetectorContract.maximumDetectionAgeMs
                && detection.label.localizedCaseInsensitiveCompare(NativeBottleDetectorContract.label) == .orderedSame
                && detection.score.isFinite
                && detection.score >= NativeBottleDetectorContract.minimumScore
                && validRect(detection.boundingBox)
        }.sorted { $0.score > $1.score }

        guard let first = candidates.first else {
            return NativeBottleDetectionSelection(
                detection: nil,
                reason: "bottle_missing",
                candidateCount: 0,
            )
        }

        if let previous,
           previous.sourceGeneration == sourceGeneration,
           let matching = candidates.max(by: { intersectionOverUnion($0.boundingBox, previous.boundingBox) < intersectionOverUnion($1.boundingBox, previous.boundingBox) }),
           intersectionOverUnion(matching.boundingBox, previous.boundingBox) >= 0.05 {
            return NativeBottleDetectionSelection(
                detection: matching,
                reason: "bottle_selected_tracked",
                candidateCount: candidates.count,
            )
        }

        if candidates.count > 1,
           first.score - candidates[1].score < NativeBottleDetectorContract.ambiguityMargin {
            return NativeBottleDetectionSelection(
                detection: nil,
                reason: "bottle_ambiguous",
                candidateCount: candidates.count,
            )
        }

        return NativeBottleDetectionSelection(
            detection: first,
            reason: "bottle_selected",
            candidateCount: candidates.count,
        )
    }

    static func contains(
        point: CGPoint,
        in detection: NativeBottleDetection,
        margin: CGFloat = NativeBottleDetectorContract.roiMargin,
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite, validRect(detection.boundingBox) else { return false }
        let expanded = detection.boundingBox.insetBy(dx: -max(0, margin), dy: -max(0, margin))
        return expanded.contains(point)
    }

    private static func validRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
            && rect.width > 0
            && rect.height > 0
            && rect.minX >= 0
            && rect.minY >= 0
            && rect.maxX <= 1
            && rect.maxY <= 1
    }

    private static func intersectionOverUnion(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
        let intersectionArea = intersection.width * intersection.height
        let unionArea = lhs.width * lhs.height + rhs.width * rhs.height - intersectionArea
        guard unionArea > 0 else { return 0 }
        return intersectionArea / unionArea
    }
}

struct NativeBottleProximityResult: Equatable {
    let totalCycles: Int
    let didCompleteCycle: Bool
    let status: String
    let reason: String?
    let isArmed: Bool
    let bottleInZone: Bool?
    let bottleScore: Float?
}

/// V7's Pose + Bottle repetition boundary. This counts entry into and exit
/// from a stable bottle ROI; it does not claim physical contact, grasp force,
/// or clinical success. Hand landmarks are intentionally not required.
final class NativeBottleProximityCounter {
    static let provenance = "experimental_app_v7_bottle_detector_pose_proximity_counter_v1"

    private enum Stage {
        case waitingForBottle
        case armedOutsideZone
        case insideBottleZone
    }

    private let maximumDetectionAgeMs: Int
    private let stableEntryObservations: Int
    private let stableExitObservations: Int
    private let maximumObservationGapMs: Int
    private let minimumSampleIntervalMs: Int
    private var stage: Stage = .waitingForBottle
    private var sourceGeneration: Int?
    private var lastTimestampMs: Int?
    private var lastBottleDetection: NativeBottleDetection?
    private var entryCount = 0
    private var exitCount = 0
    private var countingEnabled = false
    private(set) var totalCycles = 0
    private(set) var lastResetReason: String?

    init(
        maximumDetectionAgeMs: Int = NativeBottleDetectorContract.maximumDetectionAgeMs,
        stableEntryObservations: Int = 3,
        stableExitObservations: Int = 3,
        maximumObservationGapMs: Int = 450,
        minimumSampleIntervalMs: Int = 66,
    ) {
        self.maximumDetectionAgeMs = max(1, maximumDetectionAgeMs)
        self.stableEntryObservations = max(1, stableEntryObservations)
        self.stableExitObservations = max(1, stableExitObservations)
        self.maximumObservationGapMs = max(1, maximumObservationGapMs)
        self.minimumSampleIntervalMs = max(1, minimumSampleIntervalMs)
    }

    func setCountingEnabled(_ enabled: Bool) {
        guard countingEnabled != enabled else { return }
        countingEnabled = enabled
        resetPartial(reason: enabled ? "practice_started_rebaseline" : "practice_not_active")
    }

    func resetAll(reason: String) {
        totalCycles = 0
        countingEnabled = false
        sourceGeneration = nil
        lastTimestampMs = nil
        lastBottleDetection = nil
        resetPartial(reason: reason)
    }

    func resetPartial(reason: String) {
        stage = .waitingForBottle
        entryCount = 0
        exitCount = 0
        lastBottleDetection = nil
        lastResetReason = reason
    }

    func currentResult(reason: String? = nil) -> NativeBottleProximityResult {
        result(didCompleteCycle: false, reason: reason)
    }

    @discardableResult
    func ingest(_ snapshot: NativeFrameSnapshot) -> NativeBottleProximityResult {
        if let sourceGeneration, sourceGeneration != snapshot.sourceGeneration {
            self.sourceGeneration = snapshot.sourceGeneration
            lastTimestampMs = nil
            resetPartial(reason: "source_generation_changed")
        } else if sourceGeneration == nil {
            sourceGeneration = snapshot.sourceGeneration
        }

        if let lastTimestampMs, snapshot.timestampMs <= lastTimestampMs {
            resetPartial(reason: "timestamp_regression")
            self.lastTimestampMs = snapshot.timestampMs
            return result(didCompleteCycle: false, reason: "timestamp_regression")
        }
        if let lastTimestampMs {
            let gap = snapshot.timestampMs - lastTimestampMs
            if gap > maximumObservationGapMs {
                resetPartial(reason: "observation_gap")
            } else if gap < minimumSampleIntervalMs {
                return result(didCompleteCycle: false, reason: nil)
            }
        }
        lastTimestampMs = snapshot.timestampMs

        let anchoredDetection: NativeBottleDetection?
        if let anchor = snapshot.bottleAnchor,
           anchor.state.isConfirmed,
           anchor.sourceGeneration == snapshot.sourceGeneration,
           anchor.detection.sourceGeneration == snapshot.sourceGeneration {
            anchoredDetection = anchor.detection
        } else {
            anchoredDetection = nil
        }
        if anchoredDetection == nil,
           let detection = snapshot.bottleDetection,
           detection.sourceGeneration == snapshot.sourceGeneration,
           detection.timestampMs <= snapshot.timestampMs,
           snapshot.timestampMs - detection.timestampMs <= maximumDetectionAgeMs {
            lastBottleDetection = detection
        }

        let detection: NativeBottleDetection?
        if let anchoredDetection {
            detection = anchoredDetection
        } else if let lastBottleDetection,
                  lastBottleDetection.sourceGeneration == snapshot.sourceGeneration,
                  snapshot.timestampMs - lastBottleDetection.timestampMs <= maximumDetectionAgeMs {
            detection = lastBottleDetection
        } else {
            detection = nil
        }

        guard let detection else {
            if stage != .waitingForBottle { resetPartial(reason: "bottle_detection_stale") }
            return result(didCompleteCycle: false, reason: "bottle_detection_stale")
        }

        guard let proxyPoints = poseProxyPoints(from: snapshot), !proxyPoints.isEmpty else {
            return result(didCompleteCycle: false, reason: "pose_hand_proxy_missing")
        }
        let inZone = proxyPoints.contains {
            NativeBottleDetectionSelector.contains(point: $0, in: detection)
        }

        guard countingEnabled else {
            // The practice UI needs a real outside-bottle observation to know
            // that it can start its countdown. Keep that readiness-only state
            // separate from count authority: no entry, exit, or total can
            // advance until `setCountingEnabled(true)` resets this partial
            // state at Active practice.
            if stage == .waitingForBottle, !inZone {
                stage = .armedOutsideZone
                lastResetReason = nil
            }
            return result(didCompleteCycle: false, reason: "practice_not_active", bottleInZone: inZone, bottleScore: detection.score)
        }

        var didCompleteCycle = false
        switch stage {
        case .waitingForBottle:
            if !inZone {
                stage = .armedOutsideZone
                lastResetReason = nil
            }
        case .armedOutsideZone:
            if inZone {
                entryCount += 1
                if entryCount >= stableEntryObservations {
                    stage = .insideBottleZone
                    entryCount = 0
                    exitCount = 0
                }
            } else {
                entryCount = 0
            }
        case .insideBottleZone:
            if !inZone {
                exitCount += 1
                if exitCount >= stableExitObservations {
                    totalCycles += 1
                    didCompleteCycle = true
                    stage = .armedOutsideZone
                    exitCount = 0
                    entryCount = 0
                }
            } else {
                exitCount = 0
            }
        }
        return result(didCompleteCycle: didCompleteCycle, reason: nil, bottleInZone: inZone, bottleScore: detection.score)
    }

    private func poseProxyPoints(from snapshot: NativeFrameSnapshot) -> [CGPoint]? {
        let indices = [15, 19, 17, 21]
        guard snapshot.pose.count > (indices.max() ?? 0) else { return nil }
        let points = indices.compactMap { index -> CGPoint? in
            let landmark = snapshot.pose[index]
            guard landmark.x.isFinite, landmark.y.isFinite,
                  landmark.x >= 0, landmark.x <= 1,
                  landmark.y >= 0, landmark.y <= 1,
                  landmark.visibility.isFinite, landmark.visibility >= 0.4 else { return nil }
            return CGPoint(x: CGFloat(landmark.x), y: CGFloat(landmark.y))
        }
        return points.isEmpty ? nil : points
    }

    private func result(
        didCompleteCycle: Bool,
        reason: String?,
        bottleInZone: Bool? = nil,
        bottleScore: Float? = nil,
    ) -> NativeBottleProximityResult {
        let status: String
        switch stage {
        case .waitingForBottle: status = "waiting_for_bottle"
        case .armedOutsideZone: status = "armed_outside_zone"
        case .insideBottleZone: status = "inside_bottle_zone"
        }
        return NativeBottleProximityResult(
            totalCycles: totalCycles,
            didCompleteCycle: didCompleteCycle,
            status: status,
            reason: reason ?? lastResetReason,
            isArmed: stage == .armedOutsideZone || stage == .insideBottleZone,
            bottleInZone: bottleInZone,
            bottleScore: bottleScore,
        )
    }
}
