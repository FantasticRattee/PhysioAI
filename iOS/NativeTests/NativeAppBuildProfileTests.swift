import XCTest
@testable import PhysioAINative

final class NativeAppBuildProfileTests: XCTestCase {
    func testRealV7ProfileIsBottleGrabOnlyAndUsesBaselineIdentity() {
        XCTAssertEqual(NativeAppBuildProfile.catalog(for: .v7).map(\.id), ["bottle_grab"])
        XCTAssertEqual(NativeAppBuildProfile.version(for: .v7), "7.0.0")
        XCTAssertEqual(NativeAppBuildProfile.displayName(for: .v7), "PhysioAI App V7 Baseline 5 Experimental")
        XCTAssertFalse(NativeAppBuildProfile.usesSpeechCoordinator(for: .v7))
    }

    func testV71ProfileKeepsBottleGrabAndSpeechCoordinatorWithoutSitToStand() {
        XCTAssertEqual(NativeAppBuildProfile.catalog(for: .v71).map(\.id), ["bottle_grab"])
        XCTAssertEqual(NativeAppBuildProfile.version(for: .v71), "7.1.0")
        XCTAssertTrue(NativeAppBuildProfile.usesSpeechCoordinator(for: .v71))
    }

    func testV72ProfileAddsSitToStandWithoutV71SpeechCoordinator() {
        XCTAssertEqual(
            NativeAppBuildProfile.catalog(for: .v72).map(\.id),
            ["bottle_grab", "sit_to_stand"],
        )
        XCTAssertEqual(NativeAppBuildProfile.version(for: .v72), "7.2.0")
        XCTAssertFalse(NativeAppBuildProfile.usesSpeechCoordinator(for: .v72))
    }

    func testV73ProfileCombinesBothExercisesAndSpeechCoordinator() {
        XCTAssertEqual(
            NativeAppBuildProfile.catalog(for: .v73).map(\.id),
            ["bottle_grab", "sit_to_stand"],
        )
        XCTAssertEqual(NativeAppBuildProfile.version(for: .v73), "7.3.6")
        XCTAssertEqual(
            NativeAppBuildProfile.displayName(for: .v73),
            "PhysioAI App V7.3.6 Sit-to-Stand Pose-Wrist Gate + Bottle Grab Baseline Experimental",
        )
        XCTAssertTrue(NativeAppBuildProfile.usesSpeechCoordinator(for: .v73))
    }

    func testV8ProfilePublishesTheCombinationV8017CleanUIReleaseIdentity() {
        XCTAssertEqual(
            NativeAppBuildProfile.catalog(for: .v8).map(\.id),
            ["bottle_grab", "sit_to_stand", "cust_dynamic_weight_shifts"],
        )
        XCTAssertEqual(NativeAppBuildProfile.version(for: .v8), "8.0.17")
        XCTAssertEqual(
            NativeAppBuildProfile.displayName(for: .v8),
            "PhysioAI App V8.0.17 Combination V1 + DWS Experimental",
        )
        XCTAssertEqual(
            NativeAppBuildProfile.activeHeaderThai,
            "โหมดผู้ป่วย · App V8.0.17 · Combination V1 + DWS ทดลอง",
        )
        XCTAssertEqual(NativeAppBuildProfile.activeHeaderEnglish, "Patient Practice · App V8.0.17 · Combination V1 + DWS Experimental")
        XCTAssertEqual(NativeAppBuildProfile.activeContentThai, "App V8.0.17 · Combination V1 + DWS")
        XCTAssertEqual(NativeAppBuildProfile.activeContentEnglish, "App V8.0.17 · Combination V1 + DWS")
        XCTAssertEqual(NativeAppBuildProfile.activeContentBadgeThai, "APP V8.0.17 · COMBINATION V1 + DWS")
        XCTAssertEqual(NativeAppBuildProfile.activeContentBadgeEnglish, "APP V8.0.17 · COMBINATION V1 + DWS")
        XCTAssertTrue(NativeAppBuildProfile.usesSpeechCoordinator(for: .v8))
    }

    func testActiveProfileIsExplicitlySelectedByBuildFlag() {
#if REAL_V8
        XCTAssertEqual(NativeAppBuildProfile.active, .v8)
#elseif REAL_V7
        XCTAssertEqual(NativeAppBuildProfile.active, .v7)
#elseif REAL_V71
        XCTAssertEqual(NativeAppBuildProfile.active, .v71)
#elseif REAL_V72
        XCTAssertEqual(NativeAppBuildProfile.active, .v72)
#elseif REAL_V73
        XCTAssertEqual(NativeAppBuildProfile.active, .v73)
#else
        XCTAssertEqual(NativeAppBuildProfile.active, .v8)
#endif
    }

    func testProductionBuildHasTherapistWebFallback() {
        XCTAssertEqual(
            NativeConfig.productionAPIBaseURL.absoluteString,
            "https://therapist-web.example.com",
        )
        XCTAssertEqual(NativeConfig.productionAPIBaseURL.scheme, "https")
    }
}
