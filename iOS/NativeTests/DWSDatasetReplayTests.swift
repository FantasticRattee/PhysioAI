import XCTest
@testable import PhysioAIDynamicWeightShiftSDK

final class DWSDatasetReplayTests: XCTestCase {
    private struct Fixture: Decodable {
        let split: String
        let phaseLabels: [String]
        let formLabels: [String]
        let samples: [Sample]
    }

    private struct Sample: Decodable {
        let id: String
        let phase: String
        let form: String
        let phaseTransitionWindow: Bool
        let window: [[Float]]
        let kerasPhase: [Double]
        let kerasForm: [Double]
    }

    func testHeldOutDatasetKeepsKerasCoreMLParityAndAccuracy() throws {
        let fixtureURL = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "dws_dataset_replay", withExtension: "json"
        ))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        XCTAssertEqual(fixture.split, "test")
        XCTAssertEqual(fixture.samples.count, 33)
        let classifier = try DWSCoreMLClassifier(computeUnits: .cpuOnly)
        var phaseCorrect = 0
        var stablePhaseCorrect = 0
        var stablePhaseCount = 0
        var formCorrect = 0
        var formCount = 0
        var falseGood = 0
        var wrongCount = 0
        var worstDelta = 0.0

        for sample in fixture.samples {
            let coreML = try classifier.rawPrediction(window: sample.window)
            worstDelta = max(worstDelta, maxDelta(coreML.phase, sample.kerasPhase))
            worstDelta = max(worstDelta, maxDelta(coreML.form, sample.kerasForm))
            let phase = label(coreML.phase, labels: fixture.phaseLabels)
            let form = label(coreML.form, labels: fixture.formLabels)
            phaseCorrect += phase == sample.phase ? 1 : 0
            if !sample.phaseTransitionWindow {
                stablePhaseCount += 1
                stablePhaseCorrect += phase == sample.phase ? 1 : 0
            }
            if sample.phase == "target" {
                formCount += 1
                formCorrect += form == sample.form ? 1 : 0
                if sample.form == "wrong_left" {
                    wrongCount += 1
                    falseGood += form == "correct_left" ? 1 : 0
                }
            }
        }

        XCTAssertLessThanOrEqual(worstDelta, 0.015, "Core ML drifted from Keras")
        XCTAssertGreaterThanOrEqual(Double(phaseCorrect) / Double(fixture.samples.count), 0.90)
        XCTAssertGreaterThanOrEqual(Double(stablePhaseCorrect) / Double(stablePhaseCount), 0.99)
        XCTAssertGreaterThanOrEqual(Double(formCorrect) / Double(formCount), 0.99)
        XCTAssertEqual(falseGood, 0, "A wrong-form dataset window was accepted as correct")
        XCTAssertGreaterThan(wrongCount, 0)
    }

    private func label(_ probabilities: [Double], labels: [String]) -> String {
        let index = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) ?? 0
        return labels[index]
    }

    private func maxDelta(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).map { abs($0 - $1) }.max() ?? .infinity
    }
}
