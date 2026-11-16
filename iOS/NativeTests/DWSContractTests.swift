import XCTest
@testable import PhysioAIDynamicWeightShiftSDK

final class DWSContractTests: XCTestCase {
    func testFrozenValidateContract() {
        XCTAssertEqual(DWSContract.windowSize, 30)
        XCTAssertEqual(DWSContract.featureSize, 23)
        XCTAssertEqual(DWSContract.minimumAIConfidence, 0.5)
        XCTAssertEqual(DWSContract.appDecisionMode, .strictAIAndRule)
        XCTAssertEqual(DWSContract.targetShiftDegrees, 8)
        XCTAssertEqual(DWSContract.centerResetDegrees, 8)
        XCTAssertEqual(DWSContract.maximumShoulderTiltDegrees, 7)
        XCTAssertEqual(DWSContract.targetHoldMs, 5_000)
        XCTAssertEqual(DWSContract.fallbackHoldMs, 5_000)
        XCTAssertEqual(DWSContract.disagreementHoldMs, 5_000)
        XCTAssertEqual(DWSContract.aiOnlyTargetHoldMs, 0)
        XCTAssertEqual(DWSContract.strictAIAndRuleTargetHoldMs, 5_000)
        XCTAssertEqual(DWSContract.restHoldMs, 180)
        XCTAssertEqual(DWSContract.hysteresisDegrees, 0)
        XCTAssertEqual(DWSContract.realtimeRestMinimumConfidence, 0.5)
    }

    func testFeatureExtractorMatchesWebFixture() throws {
        struct Fixture: Decodable { let landmarks: [DWSLandmark]; let expected: [Float] }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "dws_feature_parity", withExtension: "json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let normalized = DWSFeatureExtractor.normalizeToScreenSide(fixture.landmarks)
        let actual = try DWSFeatureExtractor.vector(from: normalized)
        XCTAssertEqual(actual.count, 23)
        for index in actual.indices {
            XCTAssertEqual(actual[index], fixture.expected[index], accuracy: 0.00001, "feature \(index)")
        }
    }

    func testScreenSideNormalizationIsIdempotent() {
        var points = Array(repeating: DWSLandmark(x: 0.5, y: 0.5), count: 33)
        for (left, right) in [(7, 8), (11, 12), (23, 24), (25, 26), (27, 28)] {
            points[left].x = 0.7
            points[right].x = 0.3
        }
        let normalized = DWSFeatureExtractor.normalizeToScreenSide(points)
        XCTAssertLessThan(normalized[11].x, normalized[12].x)
        XCTAssertEqual(DWSFeatureExtractor.normalizeToScreenSide(normalized), normalized)
    }

    func testMirroredFrontCameraProjectionUsesDisplayedLeanDirection() {
        var points = Array(repeating: DWSLandmark(x: 0.5, y: 0.5), count: 33)
        // Unmirrored front-camera coordinates: this positive X shift appears
        // as a lean toward the left side of the mirrored selfie preview.
        points[7] = DWSLandmark(x: 0.7, y: 0.2)
        points[8] = DWSLandmark(x: 0.3, y: 0.2)
        points[11] = DWSLandmark(x: 0.75, y: 0.3)
        points[12] = DWSLandmark(x: 0.45, y: 0.3)
        points[23] = DWSLandmark(x: 0.65, y: 0.7)
        points[24] = DWSLandmark(x: 0.35, y: 0.7)
        points[25] = DWSLandmark(x: 0.65, y: 0.8)
        points[26] = DWSLandmark(x: 0.35, y: 0.8)
        points[27] = DWSLandmark(x: 0.65, y: 0.9)
        points[28] = DWSLandmark(x: 0.35, y: 0.9)

        let rawScreenSide = DWSFeatureExtractor.prepareForDisplayedScreen(
            points,
            mirroredHorizontally: false
        )
        let displayedScreenSide = DWSFeatureExtractor.prepareForDisplayedScreen(
            points,
            mirroredHorizontally: true
        )
        let rawMetrics = DWSFeatureExtractor.metrics(from: rawScreenSide)
        let displayedMetrics = DWSFeatureExtractor.metrics(from: displayedScreenSide)

        XCTAssertGreaterThan(rawMetrics.signedTorsoLeanDegrees, 0)
        XCTAssertLessThan(displayedMetrics.signedTorsoLeanDegrees, 0)
        XCTAssertEqual(
            displayedMetrics.trunkShiftDegrees,
            rawMetrics.trunkShiftDegrees,
            accuracy: 0.00001
        )
        XCTAssertLessThan(displayedScreenSide[11].x, displayedScreenSide[12].x)
    }
}
