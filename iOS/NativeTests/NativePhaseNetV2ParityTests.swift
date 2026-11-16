import Foundation
import XCTest
@testable import PhysioAINative

/// These fixtures are copied verbatim from the frozen PhaseNet V2 integration
/// bundle. They prove native numeric/feature parity only; they are not
/// performance, clinical, contact, or repetition evidence.
final class NativePhaseNetV2ParityTests: XCTestCase {
    func testFrozenPhaseNetV2RuntimeMatchesBrowserGoldenProbabilities() throws {
        let inputs: RuntimeInputDocument = try decodeFixture("phasenet_v2_golden_inputs")
        let parity: RuntimeParityDocument = try decodeFixture("phasenet_v2_golden_parity")
        let expectedByID = Dictionary(uniqueKeysWithValues: parity.fixtures.map { ($0.id, $0) })
        let runtime = try NativePhaseNetV2Runtime.loadBundled(from: Bundle(for: NativePhaseNetV2Runtime.self))

        XCTAssertEqual(parity.browserWeightSha256, NativePhaseNetV2Runtime.expectedWeightSHA256)
        XCTAssertEqual(parity.classOrder, NativePhaseNetV2Runtime.classOrder)

        for fixture in inputs.fixtures {
            guard let expected = expectedByID[fixture.id] else {
                return XCTFail("Missing browser parity expectation for \(fixture.id)")
            }
            let actual = try runtime.predict(window: fixture.window)

            XCTAssertEqual(actual.argmaxIndex, expected.browserArgmaxIndex, fixture.id)
            XCTAssertEqual(actual.phase, NativePhaseNetV2Runtime.classOrder[expected.browserArgmaxIndex], fixture.id)
            XCTAssertEqual(actual.probabilities.count, expected.browserProbabilities.count, fixture.id)
            for (index, probability) in actual.probabilities.enumerated() {
                XCTAssertEqual(
                    probability,
                    expected.browserProbabilities[index],
                    accuracy: 0.000_001,
                    "\(fixture.id) class \(index)",
                )
            }
        }
    }

    func testNativeFeatureAdapterMatchesFrozenSyntheticFormulaFixtures() throws {
        let document: FeatureAdapterDocument = try decodeFixture("phasenet_v2_feature_adapter_golden")
        var previous: NativePhaseFeatureFrame?

        for fixture in document.frames {
            let snapshot = NativeFrameSnapshot(
                timestampMs: Int(fixture.input.sourceTimestampMs.rounded()),
                pose: fixture.input.poseLandmarks.map(NativeLandmark.init),
                hand: fixture.input.handLandmarks.map(NativeLandmark.init),
                handSide: fixture.input.detectedHandSide,
                handScore: Float(fixture.input.detectedHandScore),
                detectorLatencyMs: 0,
            )
            let actual = NativePhaseNetV2FeatureAdapter.makeFeatureFrame(snapshot: snapshot, previous: previous)
            XCTAssertEqual(actual.captureQC, fixture.expected.captureQc, fixture.id)
            guard let frame = actual.frame else {
                return XCTFail("Expected finite feature frame for \(fixture.id)")
            }
            XCTAssertEqual(frame.features.count, fixture.expected.features.count, fixture.id)
            for (index, value) in frame.features.enumerated() {
                // The canonical fixture is JavaScript Double precision; the
                // native camera/landmark boundary is Float32. Keep tolerance
                // bounded to that explicit conversion rather than relabeling
                // or changing a model feature.
                XCTAssertEqual(
                    value,
                    Float(fixture.expected.features[index]),
                    accuracy: 0.000_005,
                    "\(fixture.id) feature \(index)",
                )
            }
            previous = frame
        }
    }

    private func decodeFixture<T: Decodable>(_ resource: String) throws -> T {
        let bundle = Bundle(for: NativePhaseNetV2ParityTests.self)
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw FixtureError.missingResource(resource)
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

private enum FixtureError: LocalizedError {
    case missingResource(String)

    var errorDescription: String? {
        switch self {
        case .missingResource(let resource):
            return "Missing native XCTest fixture resource: \(resource).json"
        }
    }
}

private struct RuntimeInputDocument: Decodable {
    let fixtures: [RuntimeInputFixture]
}

private struct RuntimeInputFixture: Decodable {
    let id: String
    let window: [[Float]]
}

private struct RuntimeParityDocument: Decodable {
    let browserWeightSha256: String
    let classOrder: [String]
    let fixtures: [RuntimeParityFixture]
}

private struct RuntimeParityFixture: Decodable {
    let id: String
    let browserProbabilities: [Double]
    let browserArgmaxIndex: Int
}

private struct FeatureAdapterDocument: Decodable {
    let frames: [FeatureAdapterFixture]
}

private struct FeatureAdapterFixture: Decodable {
    let id: String
    let input: FeatureAdapterInput
    let expected: FeatureAdapterExpected
}

private struct FeatureAdapterInput: Decodable {
    let sourceTimestampMs: Double
    let poseLandmarks: [FixtureLandmark]
    let handLandmarks: [FixtureLandmark]
    let detectedHandSide: String
    let detectedHandScore: Double
}

private struct FeatureAdapterExpected: Decodable {
    let captureQc: String
    let features: [Double]
}

private struct FixtureLandmark: Decodable {
    let x: Float
    let y: Float
    let z: Float
    let visibility: Float?

    init(x: Float, y: Float, z: Float, visibility: Float? = nil) {
        self.x = x
        self.y = y
        self.z = z
        self.visibility = visibility
    }
}

private extension NativeLandmark {
    init(_ fixture: FixtureLandmark) {
        self.init(
            x: fixture.x,
            y: fixture.y,
            z: fixture.z,
            visibility: fixture.visibility ?? 1,
        )
    }
}
