import Foundation

/// Guided-start cards may prepare a patient during the visual countdown, but
/// their voice must wait until Active so it never competes with Audio-Only
/// countdown numbers. This remains a presentation policy and cannot enable a
/// counter or change readiness.
enum NativeGuidedStartPresentationPhasePolicy {
    static func showsActionCue(in phase: NativePracticePhase) -> Bool {
        phase == .countdown || phase == .active
    }

    static func speaksActionCue(in phase: NativePracticePhase) -> Bool {
        phase == .active
    }
}

/// Decides whether a positioning failure needs an audible cue. Raw inference
/// reasons arrive at camera cadence, but voice must use a stable
/// patient-facing state rather than treat every engine transition as a new
/// instruction.
enum NativeSetupSpeechPolicy {
    static let initialSettlingInterval: TimeInterval = 4
    static let noParticipantReminderInterval: TimeInterval = 30
    static let participantPresenceRearmInterval: TimeInterval = 2
    static let noParticipantSemanticReason = "no_participant"
    static let noParticipantReminderDeliveredKey = "setup:no_participant:reminder_delivered"

    private static let noParticipantRawReasons: Set<String> = [
        "missing_required_pose",
        "missing_pose",
        "pose_missing",
        "pose_only_capture_qc_failed",
        noParticipantSemanticReason,
        noParticipantReminderDeliveredKey,
    ]

    static func shouldRecheckForSnapshot(
        timestampMs: Int?,
        lastCheckedTimestampMs: Int?,
    ) -> Bool {
        guard let timestampMs else { return false }
        return timestampMs != lastCheckedTimestampMs
    }

    static func shouldSpeak(
        reason: String?,
        speechEnabled: Bool,
        visualOnly: Bool,
        lastReason: String?,
        elapsedSinceLastSpeech: TimeInterval,
    ) -> Bool {
        guard speechEnabled,
              !visualOnly,
              let reason,
              !reason.isEmpty else {
            return false
        }
        let normalizedReason = semanticReason(for: reason)
        guard let lastReason else { return true }
        let lastSemanticReason = semanticReason(for: lastReason)
        guard normalizedReason == lastSemanticReason else { return true }

        guard normalizedReason == noParticipantSemanticReason,
              lastReason != noParticipantReminderDeliveredKey else {
            return false
        }
        return elapsedSinceLastSpeech >= noParticipantReminderInterval
    }

    static func semanticReason(for rawReason: String) -> String {
        noParticipantRawReasons.contains(rawReason)
            ? noParticipantSemanticReason
            : rawReason
    }

    static func isNoParticipant(_ reason: String?) -> Bool {
        guard let reason else { return false }
        return semanticReason(for: reason) == noParticipantSemanticReason
    }
}

/// The one patient-facing setup instruction resolved for a camera snapshot.
/// Its semantic key and copy travel together so visual presentation and TTS
/// cannot independently choose different wording for the same state.
struct NativeSetupGuidance: Equatable {
    let semanticKey: String
    let title: String
    /// Concise copy used only by speech presentation.
    let detail: String
    /// Detailed copy retained for the visible setup and cue cards.
    let visualDetail: String
    let snapshotTimestampMs: Int?
}

/// The patient sees detailed visual guidance, but real-time audio remains
/// short enough to be useful while moving. Unknown/dynamic copy deliberately
/// falls through unchanged rather than being silently paraphrased.
enum NativeTtsCopyPolicy {
    static func motionText(
        status: String,
        isSitToStand: Bool,
        isThai: Bool,
        fallback: String,
    ) -> String {
        if status.hasPrefix("counted_rep_"),
           let repetition = Int(status.dropFirst("counted_rep_".count)),
           repetition > 0 {
            return isThai ? "รอบที่ \(repetition)" : "Rep \(repetition)"
        }
        if isSitToStand {
            switch status {
            case "hands_together_collecting", "hands_together_required":
                return isThai ? "ประสานมือก่อน" : "Bring hands together."
            case "hands_not_assessable":
                return isThai ? "ให้เห็นมือทั้งสองข้าง" : "Show both hands."
            case "awaiting_seated_baseline", "standing_ready_to_sit":
                return isThai ? "นั่งลงได้เลย" : "Sit down now."
            case "seated_settling":
                return isThai ? "นั่งนิ่งสักครู่" : "Sit still briefly."
            case "seated_rest":
                return isThai ? "เตรียมลุกขึ้น" : "Get ready to stand."
            case "rising", "standing_hold":
                return isThai ? "ยืนให้มั่นคง" : "Stand steady."
            case "lowering":
                return isThai ? "นั่งลงได้เลย" : "Sit down now."
            default:
                return fallback
            }
        }

        switch status {
        case "collecting_rest":
            return isThai ? "อ้ามือค้างไว้" : "Open hand and hold."
        case "armed":
            return isThai ? "เอื้อมหยิบขวด" : "Reach for the bottle."
        case "grasped":
            return isThai ? "ปล่อยขวด" : "Release the bottle."
        default:
            return fallback
        }
    }

    static func practiceStart(isSitToStand: Bool, isThai: Bool) -> String {
        if isSitToStand {
            return isThai ? "นั่งนิ่ง แล้วลุกขึ้นครับ" : "Sit still, then stand."
        }
        return isThai ? "อ้ามือ แล้วหยิบขวดครับ" : "Open your hand, then grab the bottle."
    }

    static func modelText(semanticKey: String, visibleText: String, isThai: Bool) -> String {
        if semanticKey.hasPrefix("hand-cue:") {
            return isThai ? "โอบนิ้วรอบขวดครับ" : "Wrap your fingers around the bottle."
        }
        guard isThai else { return visibleText }
        switch visibleText {
        case "ลองขยับแขนกลับเข้าใกล้แนวอ้างอิง":
            return "ขยับแขนกลับแนวเดิมครับ"
        case "ลองรักษาลำตัวให้อยู่ใกล้แนวอ้างอิง":
            return "ลำตัวให้อยู่ตรงครับ"
        case "ให้เห็นมือทั้งสองข้างในกล้องก่อนเริ่ม":
            return "ให้เห็นมือทั้งสองข้างครับ"
        default:
            return visibleText
        }
    }
}

/// V8.0.10 established, and V8.0.12 retains, automatic model comments on the
/// visible card. During a movement they can change more quickly than a patient
/// can safely act on speech. Blocking setup/action episodes and the
/// authoritative repetition announcement are handled through separate paths.
enum NativeActiveCoachingSpeechPolicy {
    static let automaticallySpeaksModelCues = false
    static let automaticallySpeaksHandCues = false
}

/// A patient-facing action cue is deliberately coarser than raw geometry
/// status. It is visual guidance only; `speechText` is non-nil only for a
/// persistent blocking condition. Count speech remains separately owned by
/// `speakRepAnnouncementIfNeeded`.
struct NativeActionCuePresentation: Equatable {
    let semanticKey: String
    let visualText: String
    let speechText: String?
}

/// Converts high-cadence engine states into a calm visual instruction. The
/// policy is independent of MediaPipe, counters, models, and persistence so
/// it can be tested without changing any exercise decision.
struct NativeActionCuePresentationPolicy {
    static let candidateDwell: TimeInterval = 0.45
    static let blockingFaultCandidateDwell: TimeInterval = 0.75
    static let ordinaryMinimumDisplay: TimeInterval = 1.0
    static let postRepHold: TimeInterval = 1.2

    private var visible: NativeActionCuePresentation?
    private var visibleSince: TimeInterval?
    private var candidate: NativeActionCuePresentation?
    private var candidateSince: TimeInterval?
    private var postRepHoldUntil: TimeInterval?
    private var lastObservedTotalReps = 0
    private var hasPresentedInitialSeatCue = false
    private var hasPresentedFirstRiseCue = false
    private var spokenBlockingFaultKeysForCurrentRep = Set<String>()
    private var spokenDirectionKeysForCurrentRep = Set<String>()

    mutating func reset(totalReps: Int = 0) {
        visible = nil
        visibleSince = nil
        candidate = nil
        candidateSince = nil
        postRepHoldUntil = nil
        lastObservedTotalReps = max(0, totalReps)
        hasPresentedInitialSeatCue = false
        hasPresentedFirstRiseCue = false
        spokenBlockingFaultKeysForCurrentRep.removeAll(keepingCapacity: true)
        spokenDirectionKeysForCurrentRep.removeAll(keepingCapacity: true)
    }

    /// Adopts a counter total at the countdown-to-Active boundary without
    /// clearing a guided-start cue that the patient has already seen.
    mutating func rebase(totalReps: Int) {
        lastObservedTotalReps = max(0, totalReps)
        spokenBlockingFaultKeysForCurrentRep.removeAll(keepingCapacity: true)
    }

    mutating func observe(
        rawStatus: String?,
        totalReps: Int,
        isSitToStand: Bool,
        isThai: Bool,
        fallback: String,
        now: TimeInterval,
    ) -> NativeActionCuePresentation? {
        let normalizedTotal = max(0, totalReps)
        if normalizedTotal < lastObservedTotalReps {
            lastObservedTotalReps = normalizedTotal
            spokenBlockingFaultKeysForCurrentRep.removeAll(keepingCapacity: true)
            spokenDirectionKeysForCurrentRep.removeAll(keepingCapacity: true)
        }
        if normalizedTotal > lastObservedTotalReps {
            lastObservedTotalReps = normalizedTotal
            spokenBlockingFaultKeysForCurrentRep.removeAll(keepingCapacity: true)
            spokenDirectionKeysForCurrentRep.removeAll(keepingCapacity: true)
            let rep = NativeActionCuePresentation(
                semanticKey: "rep:\(normalizedTotal)",
                visualText: isThai ? "รอบ \(normalizedTotal) สำเร็จ" : "Rep \(normalizedTotal) complete",
                speechText: nil,
            )
            visible = rep
            visibleSince = now
            candidate = nil
            candidateSince = nil
            postRepHoldUntil = now + Self.postRepHold
            return rep
        }

        guard var incoming = Self.resolve(
            rawStatus: rawStatus,
            isSitToStand: isSitToStand,
            isThai: isThai,
            fallback: fallback,
        ) else {
            candidate = nil
            candidateSince = nil
            return visible
        }

        // A displayed first instruction may still be waiting for countdown
        // to finish before TTS is enabled. Preserve its key and speech while
        // the same posture remains; the speech coordinator speaks it once.
        if isSitToStand,
           (incoming.semanticKey == "sts:initial_seat" && visible?.semanticKey == "sts:initial_seat"
            || incoming.semanticKey == "sts:ready_to_stand" && visible?.semanticKey == "sts:first_rise") {
            candidate = nil
            candidateSince = nil
            return visible
        }

        if isSitToStand,
           incoming.semanticKey == "sts:initial_seat",
           hasPresentedInitialSeatCue {
            incoming = NativeActionCuePresentation(
                semanticKey: "sts:seat_for_baseline",
                visualText: isThai ? "นั่งลงได้เลย" : "Sit down now.",
                speechText: nil,
            )
        } else if isSitToStand,
                  incoming.semanticKey == "sts:ready_to_stand",
                  !hasPresentedFirstRiseCue {
            let text = isThai ? "ดีมาก ลุกขึ้นได้เลย" : "Great. Stand up now."
            incoming = NativeActionCuePresentation(
                semanticKey: "sts:first_rise",
                visualText: text,
                speechText: text,
            )
        }

        if Self.isBlockingFault(incoming.semanticKey),
           spokenBlockingFaultKeysForCurrentRep.contains(incoming.semanticKey) {
            incoming = NativeActionCuePresentation(
                semanticKey: incoming.semanticKey,
                visualText: incoming.visualText,
                speechText: nil,
            )
        }
        if spokenDirectionKeysForCurrentRep.contains(incoming.semanticKey) {
            incoming = NativeActionCuePresentation(semanticKey: incoming.semanticKey,
                visualText: incoming.visualText, speechText: nil)
        }

        if incoming.semanticKey == visible?.semanticKey {
            candidate = nil
            candidateSince = nil
            return visible
        }

        if let postRepHoldUntil, now < postRepHoldUntil {
            return visible
        }
        if postRepHoldUntil != nil, visible?.semanticKey.hasPrefix("rep:") == true {
            visible = nil
            visibleSince = nil
            self.postRepHoldUntil = nil
        }

        if incoming.semanticKey != candidate?.semanticKey {
            candidate = incoming
            candidateSince = now
        }
        guard let candidate, let candidateSince,
              now - candidateSince >= Self.requiredCandidateDwell(for: candidate) else {
            return visible
        }
        if let visibleSince, now - visibleSince < Self.ordinaryMinimumDisplay {
            return visible
        }

        visible = candidate
        visibleSince = now
        if candidate.semanticKey == "sts:initial_seat" {
            hasPresentedInitialSeatCue = true
        }
        if candidate.semanticKey == "sts:first_rise" {
            hasPresentedFirstRiseCue = true
        }
        if Self.isBlockingFault(candidate.semanticKey), candidate.speechText != nil {
            spokenBlockingFaultKeysForCurrentRep.insert(candidate.semanticKey)
        }
        if ["sts:seat_settling", "sts:return_to_seat"].contains(candidate.semanticKey), candidate.speechText != nil {
            spokenDirectionKeysForCurrentRep.insert(candidate.semanticKey)
        }
        self.candidate = nil
        self.candidateSince = nil
        return candidate
    }

    private static func requiredCandidateDwell(
        for presentation: NativeActionCuePresentation,
    ) -> TimeInterval {
        isBlockingFault(presentation.semanticKey)
            ? blockingFaultCandidateDwell
            : candidateDwell
    }

    private static func isBlockingFault(_ semanticKey: String) -> Bool {
        switch semanticKey {
        case "sts:hands_together", "sts:hands_visible":
            return true
        default:
            return false
        }
    }

    private static func resolve(
        rawStatus: String?,
        isSitToStand: Bool,
        isThai: Bool,
        fallback: String,
    ) -> NativeActionCuePresentation? {
        let status = rawStatus ?? "unknown"
        if isSitToStand {
            switch status {
            case "hands_together_collecting", "hands_together_required":
                let text = isThai ? "ประสานมือก่อน" : "Bring hands together."
                return NativeActionCuePresentation(semanticKey: "sts:hands_together", visualText: text, speechText: text)
            case "hands_not_assessable":
                let text = isThai ? "ให้เห็นมือทั้งสองข้าง" : "Show both hands."
                return NativeActionCuePresentation(semanticKey: "sts:hands_visible", visualText: text, speechText: text)
            case "awaiting_seated_baseline":
                let text = isThai ? "ดีมาก นั่งลงได้เลย" : "Great. Sit down now."
                return NativeActionCuePresentation(
                    semanticKey: "sts:initial_seat",
                    visualText: text,
                    speechText: text,
                )
            case "hands_together_latched", "posture_unknown":
                return NativeActionCuePresentation(
                    semanticKey: "sts:check_posture",
                    visualText: isThai ? "กำลังตรวจท่านั่งหรือยืน" : "Checking your position.",
                    speechText: nil,
                )
            case "seated_settling":
                let text = isThai ? "นั่งนิ่งสักครู่" : "Sit still briefly."
                return NativeActionCuePresentation(semanticKey: "sts:seat_settling", visualText: text, speechText: text)
            case "seated_rest":
                return NativeActionCuePresentation(
                    semanticKey: "sts:ready_to_stand",
                    visualText: isThai ? "ลุกขึ้นได้เลย" : "Stand up now.",
                    speechText: nil,
                )
            case "rising":
                return NativeActionCuePresentation(
                    semanticKey: "sts:continue_rising",
                    visualText: isThai ? "ลุกขึ้นได้เลย" : "Stand up now.", speechText: nil
                )
            case "standing_hold":
                return NativeActionCuePresentation(
                    semanticKey: "sts:stand_steady",
                    visualText: isThai ? "ยืนให้มั่นคง" : "Stand steady.",
                    speechText: nil,
                )
            case "standing_ready_to_sit":
                let text = isThai ? "นั่งลงได้เลย" : "Sit down now."
                return NativeActionCuePresentation(semanticKey: "sts:return_to_seat", visualText: text, speechText: text)
            case "lowering":
                return NativeActionCuePresentation(
                    semanticKey: "sts:sit_down",
                    visualText: isThai ? "นั่งลงได้เลย" : "Sit down now.",
                    speechText: nil,
                )
            default:
                break
            }
        } else {
            switch status {
            case "collecting_rest":
                return NativeActionCuePresentation(
                    semanticKey: "bottle:open_hold",
                    visualText: isThai ? "อ้ามือค้างไว้" : "Open hand and hold.",
                    speechText: nil,
                )
            case "armed":
                return NativeActionCuePresentation(
                    semanticKey: "bottle:reach",
                    visualText: isThai ? "เอื้อมหยิบขวด" : "Reach for the bottle.",
                    speechText: nil,
                )
            case "grasped":
                return NativeActionCuePresentation(
                    semanticKey: "bottle:release",
                    visualText: isThai ? "ปล่อยขวด" : "Release the bottle.",
                    speechText: nil,
                )
            default:
                break
            }
        }

        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFallback.isEmpty else { return nil }
        return NativeActionCuePresentation(
            semanticKey: "fallback:\(status):\(trimmedFallback)",
            visualText: trimmedFallback,
            speechText: nil,
        )
    }
}

enum NativeSetupGuidancePolicy {
    static func resolve(
        rawReason: String?,
        poseLandmarkCount: Int?,
        isSitToStand: Bool,
        isThai: Bool,
        snapshotTimestampMs: Int?,
    ) -> NativeSetupGuidance? {
        if poseLandmarkCount == 0 {
            return noParticipant(isSitToStand: isSitToStand, isThai: isThai, timestampMs: snapshotTimestampMs)
        }

        guard let rawReason, !rawReason.isEmpty else { return nil }
        if isSitToStand {
            if rawReason == "source_mirrored" {
                return NativeSetupGuidance(
                    semanticKey: "source_mirrored",
                    title: isThai ? "เปลี่ยนเป็นภาพไม่กลับด้าน" : "Use an unmirrored view",
                    detail: isThai ? "ใช้กล้องหลังครับ" : "Use the rear camera.",
                    visualDetail: isThai
                        ? "ใช้กล้องหลังหรือภาพที่ไม่กลับซ้าย–ขวา แล้วจัดให้เห็นตัวเต็ม เก้าอี้ เข่า และเท้าทั้งสองข้าง"
                        : "Use the rear camera or an unmirrored source, then frame your full body, chair, knees, and both feet.",
                    snapshotTimestampMs: snapshotTimestampMs,
                )
            }
            return NativeSetupGuidance(
                semanticKey: "full_body_framing",
                title: isThai ? "รอข้อมูลทั้งตัว" : "Waiting for full-body data",
                detail: isThai ? "ให้เห็นตัวและเก้าอี้ครับ" : "Show your body and chair.",
                visualDetail: isThai
                    ? "ให้เห็นศีรษะ ไหล่ สะโพก เข่า เท้า และเก้าอี้ในกรอบกล้อง"
                    : "Keep your head, shoulders, hips, knees, feet, and chair visible in the camera frame.",
                snapshotTimestampMs: snapshotTimestampMs,
            )
        }

        switch rawReason {
        case "missing_left_hand", "missing_hand_side", "wrong_anatomical_side", "unreliable_hand_side", "unassociated_left_hand":
            return NativeSetupGuidance(
                semanticKey: "left_hand_detail",
                title: isThai ? "รอข้อมูลมือซ้าย" : "Waiting for left-hand data",
                detail: isThai ? "ให้เห็นมือซ้ายเต็มมือครับ" : "Show your full left hand.",
                visualDetail: isThai
                    ? "เห็นแขนแล้วครับ ยื่นมือซ้ายให้เห็นเต็มมืออีกนิด"
                    : "Your arm is visible. Show your full left hand a little more clearly.",
                snapshotTimestampMs: snapshotTimestampMs,
            )
        default:
            return NativeSetupGuidance(
                semanticKey: "left_arm_framing",
                title: isThai ? "รอข้อมูลแขนซ้าย" : "Waiting for left-arm data",
                detail: isThai ? "ให้เห็นแขนซ้ายทั้งแขนครับ" : "Show your full left arm.",
                visualDetail: isThai
                    ? "ขยับอีกนิด ให้เห็นไหล่ ข้อศอก ข้อมือ และมือซ้ายชัดเจนครับ"
                    : "Move slightly so your left shoulder, elbow, wrist, and hand are clearly visible.",
                snapshotTimestampMs: snapshotTimestampMs,
            )
        }
    }

    private static func noParticipant(
        isSitToStand: Bool,
        isThai: Bool,
        timestampMs: Int?,
    ) -> NativeSetupGuidance {
        if isSitToStand {
            return NativeSetupGuidance(
                semanticKey: NativeSetupSpeechPolicy.noParticipantSemanticReason,
                title: isThai ? "รอให้คุณเข้ากรอบ" : "Waiting for you in frame",
                detail: isThai ? "เข้ากรอบให้เห็นตัวและเก้าอี้ครับ" : "Step into frame with your body and chair.",
                visualDetail: isThai
                    ? "ขยับเข้ามาในกรอบกล้องให้เห็นตัวและเก้าอี้ครับ"
                    : "Step into the camera frame so your body and chair are visible.",
                snapshotTimestampMs: timestampMs,
            )
        }
        return NativeSetupGuidance(
            semanticKey: NativeSetupSpeechPolicy.noParticipantSemanticReason,
            title: isThai ? "รอให้คุณเข้ากรอบ" : "Waiting for you in frame",
            detail: isThai ? "เข้ากรอบให้เห็นแขนซ้ายครับ" : "Step into frame with your left arm.",
            visualDetail: isThai
                ? "ขยับเข้ามาในกรอบกล้องให้เห็นช่วงไหล่ถึงมือซ้ายครับ"
                : "Step into the camera frame so your shoulder through left hand are visible.",
            snapshotTimestampMs: timestampMs,
        )
    }
}
