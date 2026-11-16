import CoreML
import Foundation

private final class DWSBundleMarker {}

public final class DWSCoreMLClassifier {
    public struct RawPrediction: Equatable, Sendable {
        public let phase: [Double]
        public let form: [Double]
    }

    private let model: MLModel

    public init(modelURL: URL? = nil, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        let url = try modelURL ?? Self.resourceURL(
            named: "PhysioAIDynamicWeightShiftTCN",
            extension: "mlmodelc"
        )
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        model = try MLModel(contentsOf: url, configuration: configuration)
    }

    public func prewarm() throws {
        let zero = Array(repeating: Array(repeating: Float(0), count: DWSContract.featureSize),
                         count: DWSContract.windowSize)
        _ = try rawPrediction(window: zero)
    }

    public func predict(window: [[Float]]) throws -> DWSAISignal {
        let temporal = try rawPrediction(window: window)
        let temporalPhase = best(temporal.phase, labels: DWSContract.phaseLabels)
        guard temporalPhase.label == "target", let latest = window.last else {
            return DWSAISignal(
                phase: temporalPhase.label,
                form: nil,
                confidence: temporalPhase.confidence,
                phaseConfidence: temporalPhase.confidence,
                formConfidence: nil,
                formEvaluated: false
            )
        }

        // Matches the web Validate contract: temporal 30-frame Phase and a
        // separate repeated-latest-frame pass for Form.
        let latestWindow = Array(repeating: latest, count: DWSContract.windowSize)
        let realtime = try rawPrediction(window: latestWindow)
        let realtimePhase = best(realtime.phase, labels: DWSContract.phaseLabels)
        if realtimePhase.label == "rest" &&
            realtimePhase.confidence >= DWSContract.realtimeRestMinimumConfidence {
            return DWSAISignal(
                phase: "rest",
                form: nil,
                confidence: realtimePhase.confidence,
                phaseConfidence: realtimePhase.confidence,
                formConfidence: nil,
                formEvaluated: false,
                realtimePhaseCandidate: realtimePhase.label,
                realtimePhaseConfidence: realtimePhase.confidence
            )
        }

        let form = formDecision(realtime.form)
        return DWSAISignal(
            phase: "target",
            form: form.label,
            confidence: min(temporalPhase.confidence, form.confidence),
            phaseConfidence: temporalPhase.confidence,
            formConfidence: form.confidence,
            formEvaluated: true,
            realtimePhaseCandidate: realtimePhase.label,
            realtimePhaseConfidence: realtimePhase.confidence
        )
    }

    public func rawPrediction(window: [[Float]]) throws -> RawPrediction {
        guard window.count == DWSContract.windowSize,
              window.allSatisfy({ $0.count == DWSContract.featureSize }) else {
            throw DWSError.invalidFeatureWindow
        }
        let input = try MLMultiArray(
            shape: [1, NSNumber(value: DWSContract.windowSize), NSNumber(value: DWSContract.featureSize)],
            dataType: .float32
        )
        for frame in 0..<DWSContract.windowSize {
            for feature in 0..<DWSContract.featureSize {
                input[[0, NSNumber(value: frame), NSNumber(value: feature)]] = NSNumber(value: window[frame][feature])
            }
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["motion_window": input])
        let result = try model.prediction(from: provider)
        guard let phase = result.featureValue(for: "Identity")?.multiArrayValue else {
            throw DWSError.invalidModelOutput("Identity")
        }
        guard let form = result.featureValue(for: "Identity_1")?.multiArrayValue else {
            throw DWSError.invalidModelOutput("Identity_1")
        }
        return RawPrediction(phase: array(phase), form: array(form))
    }

    public static func resourceURL(named name: String, extension fileExtension: String) throws -> URL {
        let containingBundle = Bundle(for: DWSBundleMarker.self)
        let bundles = [
            containingBundle.url(forResource: "PhysioAIDynamicWeightShiftSDK", withExtension: "bundle")
                .flatMap(Bundle.init(url:)),
            Bundle.main.url(forResource: "PhysioAIDynamicWeightShiftSDK", withExtension: "bundle")
                .flatMap(Bundle.init(url:)),
            containingBundle,
            Bundle.main,
        ].compactMap { $0 }
        for bundle in bundles {
            if let url = bundle.url(forResource: name, withExtension: fileExtension) { return url }
        }
        throw DWSError.missingResource("\(name).\(fileExtension)")
    }

    private func array(_ value: MLMultiArray) -> [Double] {
        (0..<value.count).map { value[$0].doubleValue }
    }

    private func best(_ probabilities: [Double], labels: [String]) -> (label: String, confidence: Double) {
        guard !probabilities.isEmpty else { return (labels[0], 0) }
        let index = probabilities.indices.max(by: { probabilities[$0] < probabilities[$1] }) ?? 0
        return (labels[min(index, labels.count - 1)], clamp(probabilities[index]))
    }

    private func formDecision(_ probabilities: [Double]) -> (label: String, confidence: Double) {
        let correctProbability = clamp(probabilities.first ?? 0)
        let correct = correctProbability >= DWSContract.qualityDecisionThreshold
        let index = correct ? 0 : 1
        let confidence = probabilities.indices.contains(index) ? clamp(probabilities[index]) : 0
        return (DWSContract.formLabels[index], confidence)
    }

    private func clamp(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}
