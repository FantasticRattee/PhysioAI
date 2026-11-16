import Foundation
import XCTest
@testable import PhysioAINative

/// These deterministic windows prove Python-to-Swift numerical parity for the
/// exported PhaseNet only. They are not movement-quality or device evidence.
final class NativeSitToStandPhaseNetV1ParityTests: XCTestCase {
    func testBundledRuntimeMatchesPythonGoldenProbabilitiesAndArgmax() throws {
        let golden: NativeGoldenDocument = try decodeFixture("sit_to_stand_phasenet_v1_golden")
        let runtime = try NativeSitToStandPhaseNetV1Runtime.loadBundled(
            from: Bundle(for: NativeSitToStandPhaseNetV1Runtime.self),
        )

        XCTAssertEqual(golden.windowShape, [30, 30])
        XCTAssertEqual(NativeSitToStandPhaseNetV1Runtime.classOrder.count, 4)
        for fixture in golden.cases {
            let actual = try runtime.predict(window: fixture.input)
            XCTAssertEqual(actual.argmaxIndex, fixture.python.argmax, fixture.id)
            XCTAssertEqual(actual.phase, fixture.python.className, fixture.id)
            for (index, probability) in actual.probabilities.enumerated() {
                XCTAssertEqual(
                    probability,
                    fixture.python.probabilities[index],
                    accuracy: 0.000_001,
                    "\(fixture.id) class \(index)",
                )
            }
        }
    }

    private func decodeFixture<T: Decodable>(_ resource: String) throws -> T {
        let bundle = Bundle(for: NativeSitToStandPhaseNetV1ParityTests.self)
        guard let url = bundle.url(forResource: resource, withExtension: "json") else {
            throw NativeGoldenError.missing(resource)
        }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
}

private enum NativeGoldenError: LocalizedError {
    case missing(String)
}

private struct NativeGoldenDocument: Decodable {
    let windowShape: [Int]
    let cases: [NativeGoldenCase]
}

private struct NativeGoldenCase: Decodable {
    let id: String
    let input: [[Float]]
    let python: NativeGoldenPrediction
}

private struct NativeGoldenPrediction: Decodable {
    let probabilities: [Double]
    let argmax: Int
    let className: String

    private enum CodingKeys: String, CodingKey {
        case probabilities, argmax
        case className = "class"
    }
}
