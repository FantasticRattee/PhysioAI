import Foundation

public final class DWSHybridEngine {
    private enum State: String {
        case waitingRest = "waiting_rest"
        case rest
        case moving = "moving_to_target"
        case targetCandidate = "target_candidate"
        case targetReached = "target_reached"
        case blocked
    }

    private var state: State = .waitingRest
    private var reps = 0
    private var armed = false
    private var restSince: Double?
    private var targetSince: Double?
    private var latchedSource: String?
    private var lastTimestamp: Double?
    private var pendingCenterReturn = false
    private let mode: DWSDecisionMode

    public init(mode: DWSDecisionMode = .hybrid) {
        self.mode = mode
    }

    public func reset() {
        reps = 0
        lastTimestamp = nil
        pendingCenterReturn = false
        resetCurrent()
    }

    public func interrupt() {
        lastTimestamp = nil
        pendingCenterReturn = false
        resetCurrent()
    }

    public func push(timestampMs: Double, metrics: DWSMetrics,
                     safety: DWSSafetyResult, aiSignal: DWSAISignal?) -> DWSDecisionSnapshot {
        let now = max(lastTimestamp ?? timestampMs, timestampMs)
        lastTimestamp = now
        guard safety.isScoreable, metrics.isValid else {
            resetCurrent()
            state = .blocked
            pendingCenterReturn = false
            return snapshot(reason: safety.status, metrics: metrics, aiSignal: aiSignal, isScoreable: false)
        }

        if mode == .aiOnly {
            return pushAIOnly(now: now, metrics: metrics, aiSignal: aiSignal)
        }
        if mode == .strictAIAndRule {
            return pushStrictAIAndRule(now: now, metrics: metrics, aiSignal: aiSignal)
        }

        let shift = quantize(metrics.trunkShiftDegrees)
        let shoulder = quantize(metrics.shoulderTiltDegrees)
        let atRest = shift <= DWSContract.centerResetDegrees
        let rulePassed = shift > DWSContract.targetShiftDegrees &&
            shoulder <= DWSContract.maximumShoulderTiltDegrees

        if !armed {
            targetSince = nil
            if atRest {
                if restSince == nil { restSince = now }
                if now - (restSince ?? now) >= DWSContract.restHoldMs {
                    armed = true
                    state = .rest
                    latchedSource = nil
                    let returned = pendingCenterReturn
                    pendingCenterReturn = false
                    return snapshot(
                        reason: returned ? "completed_center_target_center" : "ready_to_move",
                        metrics: metrics,
                        aiSignal: aiSignal,
                        returnedToCenter: returned
                    )
                }
                if state != .targetReached { state = .waitingRest }
            } else {
                restSince = nil
            }
            return snapshot(reason: state == .targetReached ? "return_to_rest" : "waiting_for_rest",
                            metrics: metrics, aiSignal: aiSignal)
        }

        if atRest {
            state = .rest
            targetSince = nil
            return snapshot(reason: "ready_to_move", metrics: metrics, aiSignal: aiSignal)
        }

        guard rulePassed else {
            state = .moving
            targetSince = nil
            let reason = shift < DWSContract.targetShiftDegrees
                ? "below_target_angle"
                : "required_target_angle_not_reached"
            return snapshot(reason: reason, metrics: metrics, aiSignal: aiSignal)
        }

        state = .targetCandidate
        if targetSince == nil { targetSince = now }
        let confidence = aiSignal?.confidence ?? 0
        let aiAtTarget = aiSignal?.phase == "target"
        let aiConfirms = aiAtTarget && aiSignal?.form == "correct_left" &&
            confidence >= DWSContract.minimumAIConfidence
        let aiDisagrees = aiSignal != nil && (!aiAtTarget || aiSignal?.form == "wrong_left") &&
            confidence >= DWSContract.minimumAIConfidence
        let required = aiConfirms
            ? DWSContract.targetHoldMs
            : aiDisagrees ? DWSContract.disagreementHoldMs : DWSContract.fallbackHoldMs
        let source = aiConfirms ? "ai_rule" : "rule_fallback"
        let elapsed = now - (targetSince ?? now)
        guard elapsed >= required else {
            let reason = aiConfirms
                ? "confirming_ai_and_rule"
                : aiDisagrees ? "ai_disagrees_waiting_rule" : "waiting_rule_fallback"
            return snapshot(reason: reason, source: source, metrics: metrics, aiSignal: aiSignal,
                            holdElapsedMs: elapsed, requiredHoldMs: required)
        }

        reps += 1
        armed = false
        restSince = nil
        targetSince = nil
        latchedSource = source
        state = .targetReached
        pendingCenterReturn = true
        return snapshot(
            reason: aiConfirms ? "reached_ai_and_rule" : "reached_rule_fallback",
            source: source,
            metrics: metrics,
            aiSignal: aiSignal,
            completedRep: true,
            holdElapsedMs: elapsed,
            requiredHoldMs: required
        )
    }

    private func pushAIOnly(now: Double, metrics: DWSMetrics,
                            aiSignal: DWSAISignal?) -> DWSDecisionSnapshot {
        let aiAtRest = aiSignal?.phase == "rest" &&
            (aiSignal?.phaseConfidence ?? 0) >= DWSContract.minimumAIConfidence
        let aiConfirmsTarget = aiSignal?.phase == "target" &&
            aiSignal?.form == "correct_left" &&
            (aiSignal?.confidence ?? 0) >= DWSContract.minimumAIConfidence

        if !armed {
            targetSince = nil
            if aiAtRest {
                if restSince == nil { restSince = now }
                if now - (restSince ?? now) >= DWSContract.restHoldMs {
                    armed = true
                    state = .rest
                    latchedSource = nil
                    let returned = pendingCenterReturn
                    pendingCenterReturn = false
                    return snapshot(
                        reason: returned ? "completed_center_target_center" : "ready_to_move",
                        source: "ai_only",
                        metrics: metrics,
                        aiSignal: aiSignal,
                        returnedToCenter: returned
                    )
                }
                if state != .targetReached { state = .waitingRest }
            } else {
                restSince = nil
            }
            return snapshot(
                reason: state == .targetReached ? "return_to_rest" : "waiting_for_ai_rest",
                source: "ai_only",
                metrics: metrics,
                aiSignal: aiSignal
            )
        }

        if aiAtRest {
            state = .rest
            targetSince = nil
            return snapshot(reason: "ready_to_move", source: "ai_only",
                            metrics: metrics, aiSignal: aiSignal)
        }

        guard aiConfirmsTarget else {
            state = .moving
            targetSince = nil
            return snapshot(reason: "waiting_for_ai_target", source: "ai_only",
                            metrics: metrics, aiSignal: aiSignal)
        }

        state = .targetCandidate
        if targetSince == nil { targetSince = now }
        let elapsed = now - (targetSince ?? now)
        guard elapsed >= DWSContract.aiOnlyTargetHoldMs else {
            return snapshot(
                reason: "confirming_ai_only",
                source: "ai_only",
                metrics: metrics,
                aiSignal: aiSignal,
                holdElapsedMs: elapsed,
                requiredHoldMs: DWSContract.aiOnlyTargetHoldMs
            )
        }

        reps += 1
        armed = false
        restSince = nil
        targetSince = nil
        latchedSource = "ai_only"
        state = .targetReached
        pendingCenterReturn = true
        return snapshot(
            reason: "reached_ai_only",
            source: "ai_only",
            metrics: metrics,
            aiSignal: aiSignal,
            completedRep: true,
            holdElapsedMs: elapsed,
            requiredHoldMs: DWSContract.aiOnlyTargetHoldMs
        )
    }

    private func pushStrictAIAndRule(now: Double, metrics: DWSMetrics,
                                     aiSignal: DWSAISignal?) -> DWSDecisionSnapshot {
        let shift = quantize(metrics.trunkShiftDegrees)
        let shoulder = quantize(metrics.shoulderTiltDegrees)
        let ruleAtRest = shift <= DWSContract.centerResetDegrees
        let ruleConfirmsTarget = shift > DWSContract.targetShiftDegrees &&
            shoulder <= DWSContract.maximumShoulderTiltDegrees
        let aiConfirmsTarget = aiSignal?.phase == "target" &&
            aiSignal?.form == "correct_left" &&
            (aiSignal?.confidence ?? 0) >= DWSContract.minimumAIConfidence
        let aiReportsWrongTarget = aiSignal?.phase == "target" &&
            aiSignal?.form == "wrong_left" &&
            (aiSignal?.confidence ?? 0) >= DWSContract.minimumAIConfidence
        // Correct Target requires AI + rules. An explicit high-confidence
        // wrong form may use the rule fallback; Rest may always use geometry.
        let restMatches = ruleAtRest
        let targetSource: String? = ruleConfirmsTarget
            ? aiConfirmsTarget
                ? "strict_ai_rule"
                : aiReportsWrongTarget ? "wrong_rule_fallback" : nil
            : nil

        if !armed {
            targetSince = nil
            if restMatches {
                if restSince == nil { restSince = now }
                if now - (restSince ?? now) >= DWSContract.restHoldMs {
                    armed = true
                    state = .rest
                    latchedSource = nil
                    let returned = pendingCenterReturn
                    pendingCenterReturn = false
                    return snapshot(
                        reason: returned ? "completed_center_target_center" : "ready_to_move",
                        source: "strict_ai_rule",
                        metrics: metrics,
                        aiSignal: aiSignal,
                        returnedToCenter: returned
                    )
                }
                if state != .targetReached { state = .waitingRest }
            } else {
                restSince = nil
            }
            return snapshot(
                reason: state == .targetReached ? "return_to_rest" : "waiting_for_rule_rest",
                source: "strict_ai_rule",
                metrics: metrics,
                aiSignal: aiSignal
            )
        }

        if restMatches {
            state = .rest
            targetSince = nil
            return snapshot(reason: "ready_to_move", source: "strict_ai_rule",
                            metrics: metrics, aiSignal: aiSignal)
        }

        guard let targetSource else {
            state = .moving
            targetSince = nil
            return snapshot(reason: "waiting_for_ai_rule_match", source: "strict_ai_rule",
                            metrics: metrics, aiSignal: aiSignal)
        }

        state = .targetCandidate
        if targetSince == nil { targetSince = now }
        let elapsed = now - (targetSince ?? now)
        guard elapsed >= DWSContract.strictAIAndRuleTargetHoldMs else {
            return snapshot(
                reason: "confirming_strict_ai_rule",
                source: targetSource,
                metrics: metrics,
                aiSignal: aiSignal,
                holdElapsedMs: elapsed,
                requiredHoldMs: DWSContract.strictAIAndRuleTargetHoldMs
            )
        }

        reps += 1
        armed = false
        restSince = nil
        targetSince = nil
        latchedSource = targetSource
        state = .targetReached
        pendingCenterReturn = true
        return snapshot(
            reason: targetSource == "wrong_rule_fallback"
                ? "reached_wrong_rule_fallback"
                : "reached_strict_ai_rule",
            source: targetSource,
            metrics: metrics,
            aiSignal: aiSignal,
            completedRep: true,
            holdElapsedMs: elapsed,
            requiredHoldMs: DWSContract.strictAIAndRuleTargetHoldMs
        )
    }

    public func currentSnapshot() -> DWSDecisionSnapshot {
        snapshot(reason: "waiting_for_rest",
                 metrics: DWSMetrics(isValid: false, trunkShiftDegrees: 0,
                                     shoulderTiltDegrees: 0, signedTorsoLeanDegrees: 0),
                 aiSignal: nil, isScoreable: false)
    }

    private func resetCurrent() {
        state = .waitingRest
        armed = false
        restSince = nil
        targetSince = nil
        latchedSource = nil
    }

    private func quantize(_ value: Double) -> Double {
        (value / DWSContract.anglePrecisionDegrees).rounded() * DWSContract.anglePrecisionDegrees
    }

    private func snapshot(reason: String, source: String? = nil, metrics: DWSMetrics,
                          aiSignal: DWSAISignal?, completedRep: Bool = false,
                          returnedToCenter: Bool = false, holdElapsedMs: Double = 0,
                          requiredHoldMs: Double = 0, isScoreable: Bool = true) -> DWSDecisionSnapshot {
        DWSDecisionSnapshot(
            state: state.rawValue,
            reason: reason,
            source: source ?? latchedSource,
            reps: reps,
            completedRep: completedRep,
            pendingCenterReturn: pendingCenterReturn,
            returnedToCenter: returnedToCenter,
            isScoreable: isScoreable,
            isArmed: armed,
            trunkShiftDegrees: metrics.trunkShiftDegrees,
            shoulderTiltDegrees: metrics.shoulderTiltDegrees,
            holdElapsedMs: holdElapsedMs,
            requiredHoldMs: requiredHoldMs,
            aiSignal: aiSignal
        )
    }
}
