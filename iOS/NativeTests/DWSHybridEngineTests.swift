import XCTest
@testable import PhysioAIDynamicWeightShiftSDK

final class DWSHybridEngineTests: XCTestCase {
    private let ready = DWSSafetyResult(isScoreable: true, status: "ready", hint: "ready", normalizedLandmarks: [])

    func testAIAndRuleConfirmAfterFiveSeconds() {
        let engine = armedEngine()
        let signal = DWSAISignal(phase: "target", form: "correct_left", confidence: 0.8,
                                 phaseConfidence: 0.9, formConfidence: 0.8, formEvaluated: true)
        XCTAssertFalse(engine.push(timestampMs: 200, metrics: target(), safety: ready, aiSignal: signal).completedRep)
        XCTAssertFalse(engine.push(timestampMs: 5_199, metrics: target(), safety: ready, aiSignal: signal).completedRep)
        let completed = engine.push(timestampMs: 5_200, metrics: target(), safety: ready, aiSignal: signal)
        XCTAssertTrue(completed.completedRep)
        XCTAssertEqual(completed.source, "ai_rule")
        XCTAssertEqual(completed.reps, 1)
    }

    func testLowConfidenceFallbackStillRequiresFiveSeconds() {
        let engine = armedEngine()
        let signal = DWSAISignal(phase: "target", form: "correct_left", confidence: 0.49,
                                 phaseConfidence: 0.8, formConfidence: 0.49, formEvaluated: true)
        _ = engine.push(timestampMs: 200, metrics: target(), safety: ready, aiSignal: signal)
        XCTAssertFalse(engine.push(timestampMs: 5_199, metrics: target(), safety: ready, aiSignal: signal).completedRep)
        let completed = engine.push(timestampMs: 5_200, metrics: target(), safety: ready, aiSignal: signal)
        XCTAssertTrue(completed.completedRep)
        XCTAssertEqual(completed.source, "rule_fallback")
    }

    func testHighConfidenceWrongAlsoRequiresFiveSeconds() {
        let engine = armedEngine()
        let signal = DWSAISignal(phase: "target", form: "wrong_left", confidence: 0.9,
                                 phaseConfidence: 0.95, formConfidence: 0.9, formEvaluated: true)
        _ = engine.push(timestampMs: 200, metrics: target(), safety: ready, aiSignal: signal)
        XCTAssertFalse(engine.push(timestampMs: 5_199, metrics: target(), safety: ready, aiSignal: signal).completedRep)
        XCTAssertTrue(engine.push(timestampMs: 5_200, metrics: target(), safety: ready, aiSignal: signal).completedRep)
    }

    func testRepCannotDuplicateUntilCenterReturn() {
        let engine = armedEngine()
        _ = engine.push(timestampMs: 200, metrics: target(), safety: ready, aiSignal: nil)
        let completed = engine.push(timestampMs: 5_200, metrics: target(), safety: ready, aiSignal: nil)
        XCTAssertEqual(completed.reps, 1)
        XCTAssertFalse(engine.push(timestampMs: 5_400, metrics: target(), safety: ready, aiSignal: nil).completedRep)
        _ = engine.push(timestampMs: 5_500, metrics: center(), safety: ready, aiSignal: nil)
        let returned = engine.push(timestampMs: 5_680, metrics: center(), safety: ready, aiSignal: nil)
        XCTAssertTrue(returned.returnedToCenter)
        XCTAssertEqual(returned.reason, "completed_center_target_center")
        _ = engine.push(timestampMs: 5_800, metrics: target(), safety: ready, aiSignal: nil)
        XCTAssertTrue(engine.push(timestampMs: 10_800, metrics: target(), safety: ready, aiSignal: nil).completedRep)
        XCTAssertEqual(engine.currentSnapshot().reps, 2)
    }

    func testEightDegreesIsRestAndOnlyGreaterThanEightStartsTarget() {
        let engine = armedEngine()
        let boundary = engine.push(timestampMs: 200, metrics: center(), safety: ready, aiSignal: nil)
        XCTAssertEqual(boundary.state, "rest")
        XCTAssertEqual(boundary.reps, 0)

        let aboveBoundary = DWSMetrics(isValid: true, trunkShiftDegrees: 8.1,
                                       shoulderTiltDegrees: 4, signedTorsoLeanDegrees: 8.1)
        let candidate = engine.push(timestampMs: 300, metrics: aboveBoundary, safety: ready, aiSignal: nil)
        XCTAssertEqual(candidate.state, "target_candidate")
        XCTAssertEqual(candidate.requiredHoldMs, 5_000)
    }

    func testSafetyLossBlocksAndClearsPendingCenter() {
        let engine = armedEngine()
        let blocked = DWSSafetyResult(isScoreable: false, status: "out_of_frame", hint: "blocked", normalizedLandmarks: [])
        let snapshot = engine.push(timestampMs: 200, metrics: target(), safety: blocked, aiSignal: nil)
        XCTAssertEqual(snapshot.state, "blocked")
        XCTAssertFalse(snapshot.isScoreable)
        XCTAssertFalse(snapshot.pendingCenterReturn)
    }

    func testAIOnlyIgnoresGeometryAndCountsCorrectAIImmediately() {
        let engine = aiOnlyArmedEngine(metrics: invalidRuleGeometry())
        let correct = aiSignal(phase: "target", form: "correct_left", confidence: 0.8)

        let completed = engine.push(timestampMs: 200, metrics: invalidRuleGeometry(),
                                    safety: ready, aiSignal: correct)

        XCTAssertTrue(completed.completedRep)
        XCTAssertEqual(completed.source, "ai_only")
        XCTAssertEqual(completed.reps, 1)
        XCTAssertEqual(completed.requiredHoldMs, 0)
    }

    func testAIOnlyHasNoRuleFallbackForWrongOrLowConfidenceAI() {
        let engine = aiOnlyArmedEngine(metrics: target())
        let wrong = aiSignal(phase: "target", form: "wrong_left", confidence: 0.9)
        _ = engine.push(timestampMs: 200, metrics: target(), safety: ready, aiSignal: wrong)
        XCTAssertEqual(engine.push(timestampMs: 5_500, metrics: target(),
                                   safety: ready, aiSignal: wrong).reps, 0)

        let lowConfidence = aiSignal(phase: "target", form: "correct_left", confidence: 0.49)
        _ = engine.push(timestampMs: 6_000, metrics: target(), safety: ready, aiSignal: lowConfidence)
        XCTAssertEqual(engine.push(timestampMs: 12_000, metrics: target(),
                                   safety: ready, aiSignal: lowConfidence).reps, 0)
    }

    func testAIOnlyRequiresAIRestToRearm() {
        let engine = aiOnlyArmedEngine(metrics: target())
        let correct = aiSignal(phase: "target", form: "correct_left", confidence: 0.8)
        _ = engine.push(timestampMs: 200, metrics: target(), safety: ready, aiSignal: correct)

        let geometryOnlyRest = engine.push(timestampMs: 400, metrics: center(),
                                          safety: ready, aiSignal: correct)
        XCTAssertTrue(geometryOnlyRest.pendingCenterReturn)
        XCTAssertFalse(geometryOnlyRest.returnedToCenter)

        let rest = aiSignal(phase: "rest", form: nil, confidence: 0.9)
        _ = engine.push(timestampMs: 500, metrics: target(), safety: ready, aiSignal: rest)
        let returned = engine.push(timestampMs: 680, metrics: target(), safety: ready, aiSignal: rest)
        XCTAssertTrue(returned.returnedToCenter)
        XCTAssertEqual(returned.reason, "completed_center_target_center")
    }

    func testStrictAIAndRuleCountsAfterFiveSecondsWhenBothAgree() {
        let engine = strictArmedEngine()
        let correct = aiSignal(phase: "target", form: "correct_left", confidence: 0.8)
        XCTAssertFalse(engine.push(timestampMs: 200, metrics: target(),
                                   safety: ready, aiSignal: correct).completedRep)
        XCTAssertFalse(engine.push(timestampMs: 5_199, metrics: target(),
                                   safety: ready, aiSignal: correct).completedRep)
        let completed = engine.push(timestampMs: 5_200, metrics: target(),
                                    safety: ready, aiSignal: correct)

        XCTAssertTrue(completed.completedRep)
        XCTAssertEqual(completed.source, "strict_ai_rule")
        XCTAssertEqual(completed.reps, 1)
        XCTAssertEqual(completed.requiredHoldMs, 5_000)
    }

    func testStrictAIAndRuleAllowsFallbackWhenAIReportsWrongTarget() {
        let engine = strictArmedEngine()
        let wrong = aiSignal(phase: "target", form: "wrong_left", confidence: 0.9)
        XCTAssertFalse(engine.push(timestampMs: 200, metrics: target(),
                                   safety: ready, aiSignal: wrong).completedRep)
        XCTAssertFalse(engine.push(timestampMs: 5_199, metrics: target(),
                                   safety: ready, aiSignal: wrong).completedRep)
        let completed = engine.push(timestampMs: 5_200, metrics: target(),
                                    safety: ready, aiSignal: wrong)

        XCTAssertTrue(completed.completedRep)
        XCTAssertEqual(completed.reps, 1)
        XCTAssertEqual(completed.source, "wrong_rule_fallback")
        XCTAssertEqual(completed.reason, "reached_wrong_rule_fallback")
    }

    func testStrictAIAndRuleHasNoTargetFallbackForMissingOrLowConfidenceAI() {
        let missingEngine = strictArmedEngine()
        XCTAssertEqual(missingEngine.push(timestampMs: 200, metrics: target(),
                                          safety: ready, aiSignal: nil).reps, 0)

        let lowEngine = strictArmedEngine()
        let low = aiSignal(phase: "target", form: "wrong_left", confidence: 0.49)
        let rejected = lowEngine.push(timestampMs: 200, metrics: target(),
                                      safety: ready, aiSignal: low)
        XCTAssertEqual(rejected.reps, 0)
        XCTAssertEqual(rejected.reason, "waiting_for_ai_rule_match")
    }

    func testStrictFiveSecondHoldResetsWhenTargetAgreementBreaks() {
        let engine = strictArmedEngine()
        let correct = aiSignal(phase: "target", form: "correct_left", confidence: 0.9)
        let low = aiSignal(phase: "target", form: "correct_left", confidence: 0.49)
        _ = engine.push(timestampMs: 200, metrics: target(), safety: ready, aiSignal: correct)
        _ = engine.push(timestampMs: 3_000, metrics: target(), safety: ready, aiSignal: correct)
        XCTAssertEqual(engine.push(timestampMs: 3_200, metrics: target(),
                                   safety: ready, aiSignal: low).holdElapsedMs, 0)

        _ = engine.push(timestampMs: 4_000, metrics: target(), safety: ready, aiSignal: correct)
        XCTAssertFalse(engine.push(timestampMs: 8_999, metrics: target(),
                                   safety: ready, aiSignal: correct).completedRep)
        XCTAssertTrue(engine.push(timestampMs: 9_000, metrics: target(),
                                  safety: ready, aiSignal: correct).completedRep)
    }

    func testStrictAIAndRuleDoesNotLetAICorrectOverrideFailedRules() {
        let engine = strictArmedEngine()
        let correct = aiSignal(phase: "target", form: "correct_left", confidence: 0.9)
        let rejected = engine.push(timestampMs: 200, metrics: invalidRuleGeometry(),
                                   safety: ready, aiSignal: correct)

        XCTAssertEqual(rejected.reps, 0)
        XCTAssertEqual(rejected.reason, "waiting_for_ai_rule_match")
    }

    func testStrictAIAndRuleAcceptsShoulderTiltAtSevenDegrees() {
        let engine = strictArmedEngine()
        let correct = aiSignal(phase: "target", form: "correct_left", confidence: 0.9)
        let boundary = DWSMetrics(isValid: true, trunkShiftDegrees: 14,
                                  shoulderTiltDegrees: 7, signedTorsoLeanDegrees: 14)

        let candidate = engine.push(timestampMs: 200, metrics: boundary,
                                    safety: ready, aiSignal: correct)

        XCTAssertEqual(candidate.state, "target_candidate")
        XCTAssertEqual(candidate.reason, "confirming_strict_ai_rule")
    }

    func testStrictAIAndRuleRejectsShoulderTiltAboveSevenDegrees() {
        let engine = strictArmedEngine()
        let correct = aiSignal(phase: "target", form: "correct_left", confidence: 0.9)
        let overLimit = DWSMetrics(isValid: true, trunkShiftDegrees: 14,
                                   shoulderTiltDegrees: 7.1, signedTorsoLeanDegrees: 14)

        let rejected = engine.push(timestampMs: 200, metrics: overLimit,
                                   safety: ready, aiSignal: correct)

        XCTAssertEqual(rejected.reps, 0)
        XCTAssertEqual(rejected.reason, "waiting_for_ai_rule_match")
        XCTAssertEqual(rejected.holdElapsedMs, 0)
    }

    func testStrictAIAndRuleAllowsRuleFallbackForRestRearm() {
        let engine = strictArmedEngine()
        let correct = aiSignal(phase: "target", form: "correct_left", confidence: 0.9)
        _ = engine.push(timestampMs: 200, metrics: target(), safety: ready, aiSignal: correct)
        _ = engine.push(timestampMs: 5_200, metrics: target(), safety: ready, aiSignal: correct)

        _ = engine.push(timestampMs: 5_400, metrics: center(), safety: ready, aiSignal: correct)
        let returned = engine.push(timestampMs: 5_580, metrics: center(),
                                   safety: ready, aiSignal: correct)

        XCTAssertTrue(returned.returnedToCenter)
        XCTAssertFalse(returned.pendingCenterReturn)
        XCTAssertEqual(returned.reason, "completed_center_target_center")
    }

    private func armedEngine() -> DWSHybridEngine {
        let engine = DWSHybridEngine()
        _ = engine.push(timestampMs: 0, metrics: center(), safety: ready, aiSignal: nil)
        _ = engine.push(timestampMs: 180, metrics: center(), safety: ready, aiSignal: nil)
        return engine
    }

    private func aiOnlyArmedEngine(metrics: DWSMetrics) -> DWSHybridEngine {
        let engine = DWSHybridEngine(mode: .aiOnly)
        let rest = aiSignal(phase: "rest", form: nil, confidence: 0.9)
        _ = engine.push(timestampMs: 0, metrics: metrics, safety: ready, aiSignal: rest)
        _ = engine.push(timestampMs: 180, metrics: metrics, safety: ready, aiSignal: rest)
        return engine
    }

    private func strictArmedEngine() -> DWSHybridEngine {
        let engine = DWSHybridEngine(mode: .strictAIAndRule)
        _ = engine.push(timestampMs: 0, metrics: center(), safety: ready, aiSignal: nil)
        _ = engine.push(timestampMs: 180, metrics: center(), safety: ready, aiSignal: nil)
        return engine
    }

    private func aiSignal(phase: String, form: String?, confidence: Double) -> DWSAISignal {
        DWSAISignal(phase: phase, form: form, confidence: confidence,
                    phaseConfidence: confidence, formConfidence: form == nil ? nil : confidence,
                    formEvaluated: form != nil)
    }

    private func invalidRuleGeometry() -> DWSMetrics {
        DWSMetrics(isValid: true, trunkShiftDegrees: 2, shoulderTiltDegrees: 45,
                   signedTorsoLeanDegrees: 2)
    }

    private func center() -> DWSMetrics {
        DWSMetrics(isValid: true, trunkShiftDegrees: 8.0, shoulderTiltDegrees: 2,
                   signedTorsoLeanDegrees: 8)
    }

    private func target() -> DWSMetrics {
        DWSMetrics(isValid: true, trunkShiftDegrees: 14.0, shoulderTiltDegrees: 4,
                   signedTorsoLeanDegrees: 14)
    }
}
