import Foundation
import simd

/// A deliberately narrow, on-device preview of the frozen Baseline #4
/// Rule-Wrap evidence policy. It emits only the fixed finger-wrap cue after
/// enough same-source hand frames corroborate it. It is *not* a port of the
/// Calibration 3 parent decision, does not observe bottle contact, and never
/// changes PhaseNet phases, cycle counts, score, or correctness.
///
/// Keeping this separate makes the provenance explicit: native users receive
/// a development cue-policy subset while the frozen browser Baseline #4
/// remains the source of truth for a complete parent+wrapper decision.
struct NativeBottleGrabCuePreview: Equatable {
    let cueID: String
    let english: String
    let thai: String
    let provenance: String

    static let fingerWrap = NativeBottleGrabCuePreview(
        cueID: "BG_REF_WRAP_FINGERS_MORE",
        english: "While grasping the bottle, try wrapping your fingers around it more completely.",
        thai: "ขณะกำขวด ลองโอบนิ้วรอบขวดให้ครบขึ้น",
        provenance: "experimental_rule_wrap_policy_subset_native",
    )
}

/// Stateful same-source evidence adapter for the two independent frozen
/// Rule-Wrap signal families: pinky/index imbalance and visible-finger
/// closure spread. The frozen thresholds are preserved; no labels, images,
/// raw landmarks, or evidence history leave device memory.
final class NativeBottleGrabRuleWrapCuePreviewAdapter {
    private static let minimumAssessableFrames = 5
    private static let minimumVisibleFingers = 3
    private static let minimumPersistence: Float = 0.65
    private static let pinkyIndexGapDegrees: Float = 12
    private static let fingerSpreadDegrees: Float = 10
    private static let maxContiguousGapMs = 100

    private struct EvidenceFrame {
        let timestampMs: Int
        let hasGapSignal: Bool
        let hasSpreadSignal: Bool
        let visibleFingerCount: Int
    }

    private var evidence: [EvidenceFrame] = []
    private var sourceGeneration: Int?

    func reset() {
        evidence.removeAll(keepingCapacity: true)
        sourceGeneration = nil
    }

    /// Returns a tentative fixed cue only when the current native frame has
    /// valid left-hand geometry and both evidence families meet the frozen
    /// corroboration/persistence policy. A transient bad frame resets the
    /// small evidence window rather than bridging stale evidence.
    func ingest(_ snapshot: NativeFrameSnapshot) -> NativeBottleGrabCuePreview? {
        if let sourceGeneration, sourceGeneration != snapshot.sourceGeneration {
            reset()
        }
        sourceGeneration = snapshot.sourceGeneration

        guard let frame = makeEvidenceFrame(snapshot) else {
            reset()
            return nil
        }
        if let previous = evidence.last,
           frame.timestampMs <= previous.timestampMs || frame.timestampMs - previous.timestampMs > Self.maxContiguousGapMs {
            evidence.removeAll(keepingCapacity: true)
        }
        evidence.append(frame)
        if evidence.count > 30 { evidence.removeFirst(evidence.count - 30) }

        guard evidence.count >= Self.minimumAssessableFrames else { return nil }
        guard frame.visibleFingerCount >= Self.minimumVisibleFingers,
              frame.hasGapSignal,
              frame.hasSpreadSignal else { return nil }

        let count = Float(evidence.count)
        let gapPersistence = Float(evidence.filter(\.hasGapSignal).count) / count
        let spreadPersistence = Float(evidence.filter(\.hasSpreadSignal).count) / count
        guard min(gapPersistence, spreadPersistence) >= Self.minimumPersistence else { return nil }

        // Both present-frame signals have a policy score of at least 0.75,
        // which is the frozen rule wrapper's qualification threshold. The
        // adapter never substitutes a label or claims physical bottle contact.
        return .fingerWrap
    }

    private func makeEvidenceFrame(_ snapshot: NativeFrameSnapshot) -> EvidenceFrame? {
        guard snapshot.hand.count == 21,
              snapshot.handScore.isFinite,
              snapshot.handScore >= 0.5,
              snapshot.handSide?.lowercased().contains("left") == true,
              snapshot.hand.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return nil
        }

        let chains = [
            [5, 6, 7, 8],
            [9, 10, 11, 12],
            [13, 14, 15, 16],
            [17, 18, 19, 20],
        ]
        let flexions = chains.compactMap { meanFlexion(chain: $0, hand: snapshot.hand) }
        guard flexions.count == chains.count,
              let index = flexions.first,
              let pinky = flexions.last,
              let minimum = flexions.min(),
              let maximum = flexions.max() else {
            return nil
        }

        return EvidenceFrame(
            timestampMs: snapshot.timestampMs,
            hasGapSignal: abs(pinky - index) >= Self.pinkyIndexGapDegrees,
            hasSpreadSignal: maximum - minimum >= Self.fingerSpreadDegrees,
            visibleFingerCount: flexions.count,
        )
    }

    private func meanFlexion(chain: [Int], hand: [NativeLandmark]) -> Float? {
        guard chain.count == 4 else { return nil }
        let first = flexionDegrees(hand[chain[0]], hand[chain[1]], hand[chain[2]])
        let second = flexionDegrees(hand[chain[1]], hand[chain[2]], hand[chain[3]])
        guard let first, let second else { return nil }
        return (first + second) / 2
    }

    private func flexionDegrees(_ a: NativeLandmark, _ vertex: NativeLandmark, _ c: NativeLandmark) -> Float? {
        let left = SIMD2<Float>(a.x - vertex.x, a.y - vertex.y)
        let right = SIMD2<Float>(c.x - vertex.x, c.y - vertex.y)
        let leftLength = simd_length(left)
        let rightLength = simd_length(right)
        guard leftLength > 0.00001, rightLength > 0.00001 else { return nil }
        let cosine = max(-1, min(1, simd_dot(left, right) / (leftLength * rightLength)))
        return (1 - acos(cosine) / .pi) * 180
    }
}
