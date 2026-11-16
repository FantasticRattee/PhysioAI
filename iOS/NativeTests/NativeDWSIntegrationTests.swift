import XCTest
import PhysioAIDynamicWeightShiftSDK
@testable import PhysioAINative

final class NativeDWSIntegrationTests: XCTestCase {
    func testScoreCountsCompletedRepOnceAndSeparatesFallback() {
        var tracker = DWSSessionTracker()
        let reached = DWSDecisionSnapshot(state: "target_reached", reason: "reached", source: "strict_ai_rule", reps: 1)
        for index in 0..<100 { _ = tracker.observe(reached, now: Double(index)) }
        _ = tracker.observe(.init(state: "target_reached", reason: "reached", source: "wrong_rule_fallback", reps: 2), now: 101)
        let report = tracker.report(target: 4)
        XCTAssertEqual(report.correctReps, 1)
        XCTAssertEqual(report.ruleFallbackReps, 1)
        XCTAssertEqual(report.completedReps, 2)
        XCTAssertEqual(report.completionScore, 50)
    }

    func testShortHoldIsOneEpisodeAndTrackingLossIsNotFault() {
        var tracker = DWSSessionTracker()
        let hold = DWSDecisionSnapshot(state: "target_candidate", reason: "hold", reps: 0, holdElapsedMs: 2500, requiredHoldMs: 5000)
        _ = tracker.observe(hold, now: 0)
        for index in 1..<100 { _ = tracker.observe(.init(state: "rest", reason: "rest", reps: 0), now: Double(index)) }
        _ = tracker.observe(hold, now: 101)
        _ = tracker.observe(.init(state: "blocked", reason: "visibility", reps: 0, isScoreable: false), now: 102)
        _ = tracker.observe(hold, now: 103)
        tracker.finish()
        let report = tracker.report(target: 10)
        XCTAssertEqual(report.incompleteHolds, 1)
        XCTAssertEqual(report.trackingInterruptions, 1)
        XCTAssertEqual(report.interruptedAtStop, 1)
    }

    func testShoulderTiltRequiresPersistenceAndRearmsWithHysteresis() {
        var tracker = DWSSessionTracker()
        func frame(_ tilt: Double) -> DWSDecisionSnapshot {
            .init(state: "moving_to_target", reason: "moving", reps: 0, shoulderTiltDegrees: tilt)
        }
        _ = tracker.observe(frame(8), now: 0)
        _ = tracker.observe(frame(6), now: 0.2)
        XCTAssertEqual(tracker.report(target: 10).shoulderTiltEpisodes, 0)
        for index in 0..<100 { _ = tracker.observe(frame(8), now: 1 + Double(index) * 0.1) }
        XCTAssertEqual(tracker.report(target: 10).shoulderTiltEpisodes, 1)
        _ = tracker.observe(frame(7), now: 12)
        _ = tracker.observe(frame(8), now: 13)
        XCTAssertEqual(tracker.report(target: 10).shoulderTiltEpisodes, 1)
        _ = tracker.observe(frame(6), now: 14)
        _ = tracker.observe(frame(8), now: 15)
        _ = tracker.observe(frame(8), now: 15.6)
        XCTAssertEqual(tracker.report(target: 10).shoulderTiltEpisodes, 2)
    }

    func testIncompleteHoldRequiresMoreThanTwoSecondsOfSDKTime() {
        for (elapsed, expected) in [(0.0, 0), (1500.0, 0), (2000.0, 0), (2001.0, 1), (4999.0, 1), (5000.0, 0)] {
            var tracker = DWSSessionTracker()
            _ = tracker.observe(.init(state: "target_candidate", reason: "hold", reps: 0, holdElapsedMs: elapsed, requiredHoldMs: 5000), now: 0)
            let cue = tracker.observe(.init(state: "rest", reason: "rest", reps: 0), now: 30)
            XCTAssertEqual(tracker.report(target: 5).incompleteHolds, expected, "SDK hold: \(elapsed)")
            XCTAssertEqual(cue != nil, expected == 1)
        }
    }

    func testTiltInterruptedHoldUsesSameMinimumAndCountsOnlyOnce() {
        for elapsed in [1500.0, 2000.0, 2500.0] {
            var tracker = DWSSessionTracker()
            // A tilt episode is already underway when a hold observation arrives.
            _ = tracker.observe(.init(state: "moving_to_target", reason: "tilt", reps: 0, shoulderTiltDegrees: 8), now: 0)
            _ = tracker.observe(.init(state: "target_candidate", reason: "hold", reps: 0, shoulderTiltDegrees: 8, holdElapsedMs: elapsed, requiredHoldMs: 5000), now: 0.1)
            for index in 1...10 {
                _ = tracker.observe(.init(state: "moving_to_target", reason: "tilt", reps: 0, shoulderTiltDegrees: 8), now: Double(index))
            }
            XCTAssertEqual(tracker.report(target: 5).incompleteHolds, elapsed > 2000 ? 1 : 0)
            XCTAssertEqual(tracker.report(target: 5).shoulderTiltEpisodes, 1)
        }
    }

    func testDWSUsesTheUpstreamV300RuntimeContract() {
        XCTAssertEqual(DWSContract.sdkID, "dynamic_weight_shifts.validate.v1")
        XCTAssertEqual(DWSContract.modelID, "cust_dynamic_weight_shifts-left-tcn-v3")
        XCTAssertEqual(DWSContract.windowSize, 30)
        XCTAssertEqual(DWSContract.featureSize, 23)
        XCTAssertEqual(DWSContract.minimumAIConfidence, 0.5)
        XCTAssertEqual(DWSContract.targetShiftDegrees, 8)
        XCTAssertEqual(DWSContract.maximumShoulderTiltDegrees, 7)
        XCTAssertEqual(DWSContract.targetHoldMs, 5_000)
        XCTAssertEqual(DWSContract.appDecisionMode, .strictAIAndRule)
    }

    func testDWSExerciseIdentityAndDefaultPlanDoseMatchTheDatabaseContract() {
        let exercise = NativeExercise.dynamicWeightShift
        XCTAssertEqual(exercise.id, "cust_dynamic_weight_shifts")
        XCTAssertEqual(exercise.reps, 10)
        XCTAssertEqual(exercise.sets, 1)
        XCTAssertEqual(exercise.holdSec, 5)
        XCTAssertEqual(NativeExercise.from(id: exercise.id), exercise)
    }

    func testDWSIsAddedOnlyToTheV8Catalog() {
        XCTAssertFalse(NativeAppBuildProfile.catalog(for: .v73).contains(.dynamicWeightShift))
        XCTAssertTrue(NativeAppBuildProfile.catalog(for: .v8).contains(.dynamicWeightShift))
    }
}
