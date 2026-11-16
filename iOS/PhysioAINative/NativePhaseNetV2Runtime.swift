import CryptoKit
import Foundation

struct NativePhaseNetV2Inference: Equatable {
    let phase: String
    let argmaxIndex: Int
    let probabilities: [Double]
}

enum NativePhaseNetV2RuntimeError: LocalizedError {
    case missingWeights
    case invalidWeightLength(Int)
    case invalidWeightHash(String)
    case invalidWindow

    var errorDescription: String? {
        switch self {
        case .missingWeights:
            return "PhaseNet V2 weights are missing from the native app bundle."
        case .invalidWeightLength(let count):
            return "PhaseNet V2 weight length is invalid (\(count) bytes)."
        case .invalidWeightHash(let hash):
            return "PhaseNet V2 weight hash mismatch (\(hash))."
        case .invalidWindow:
            return "PhaseNet V2 requires a finite 30 × 20 window."
        }
    }
}

/// Dependency-free Swift port of the frozen PhaseNet V2 browser graph. It uses
/// the same scalar accumulation order (Double sum, Float activation storage)
/// to make numerical parity testable against the model-owned browser bundle.
final class NativePhaseNetV2Runtime {
    static let modelID = "bottlegrab_posehand_phasenet_v2_same_lineage_video_expansion_train_only"
    static let expectedWeightByteLength = 55_480
    static let expectedWeightFloatCount = 13_870
    static let expectedWeightSHA256 = "b522a4e5f705594ccdfc400d24b11cc87677f39961698f95a63dfddcb1e1fd43"
    static let classOrder = ["start_or_rest", "reach", "preshape", "grasp", "release", "return"]

    private let tensors: [String: [Float]]

    private init(weights: [Float]) {
        func tensor(_ offset: Int, _ count: Int) -> [Float] {
            Array(weights[offset..<(offset + count)])
        }
        tensors = [
            "pose_norm_gamma": tensor(0, 10),
            "pose_norm_beta": tensor(10, 10),
            "hand_norm_gamma": tensor(20, 10),
            "hand_norm_beta": tensor(30, 10),
            "pose_encoder_d1_kernel": tensor(40, 1_200),
            "pose_encoder_d1_bias": tensor(1_240, 24),
            "hand_encoder_d1_kernel": tensor(1_264, 1_200),
            "hand_encoder_d1_bias": tensor(2_464, 24),
            "pose_projection_d1_kernel": tensor(2_488, 576),
            "pose_projection_d1_bias": tensor(3_064, 24),
            "pose_residual_d1_kernel": tensor(3_088, 240),
            "pose_residual_d1_bias": tensor(3_328, 24),
            "hand_projection_d1_kernel": tensor(3_352, 576),
            "hand_projection_d1_bias": tensor(3_928, 24),
            "hand_residual_d1_kernel": tensor(3_952, 240),
            "hand_residual_d1_bias": tensor(4_192, 24),
            "pose_encoder_d2_kernel": tensor(4_216, 2_880),
            "pose_encoder_d2_bias": tensor(7_096, 24),
            "hand_encoder_d2_kernel": tensor(7_120, 2_880),
            "hand_encoder_d2_bias": tensor(10_000, 24),
            "pose_projection_d2_kernel": tensor(10_024, 576),
            "pose_projection_d2_bias": tensor(10_600, 24),
            "hand_projection_d2_kernel": tensor(10_624, 576),
            "hand_projection_d2_bias": tensor(11_200, 24),
            "fusion_embedding_kernel": tensor(11_224, 2_304),
            "fusion_embedding_bias": tensor(13_528, 48),
            "phase_class_kernel": tensor(13_576, 288),
            "phase_class_bias": tensor(13_864, 6),
        ]
    }

    static func loadBundled(from bundle: Bundle = .main) throws -> NativePhaseNetV2Runtime {
        guard let url = bundle.url(forResource: "phasenet_v2_browser_weights", withExtension: "f32") else {
            throw NativePhaseNetV2RuntimeError.missingWeights
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count == expectedWeightByteLength else {
            throw NativePhaseNetV2RuntimeError.invalidWeightLength(data.count)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == expectedWeightSHA256 else {
            throw NativePhaseNetV2RuntimeError.invalidWeightHash(hash)
        }
        var weights: [Float] = []
        weights.reserveCapacity(expectedWeightFloatCount)
        for offset in stride(from: 0, to: data.count, by: 4) {
            let bits = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            weights.append(Float(bitPattern: bits))
        }
        guard weights.count == expectedWeightFloatCount else {
            throw NativePhaseNetV2RuntimeError.invalidWeightLength(data.count)
        }
        return NativePhaseNetV2Runtime(weights: weights)
    }

    func predict(window: [[Float]]) throws -> NativePhaseNetV2Inference {
        guard window.count == NativePhaseNetV2WindowAccumulator.sequenceLength,
              window.allSatisfy({ $0.count == NativePhaseNetV2WindowAccumulator.featureCount && $0.allSatisfy(\.isFinite) }) else {
            throw NativePhaseNetV2RuntimeError.invalidWindow
        }
        let pose = window.map { Array($0[0..<10]) }
        let hand = window.map { Array($0[10..<20]) }
        let poseContext = encode(pose, prefix: "pose")
        let handContext = encode(hand, prefix: "hand")
        let embedding = dense(
            poseContext + handContext,
            kernel: tensor("fusion_embedding_kernel"),
            bias: tensor("fusion_embedding_bias"),
            units: 48,
            relu: true,
        )
        let logits = dense(
            embedding,
            kernel: tensor("phase_class_kernel"),
            bias: tensor("phase_class_bias"),
            units: 6,
            relu: false,
        )
        let probabilities = softmax(logits)
        let argmax = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
        return NativePhaseNetV2Inference(
            phase: Self.classOrder[argmax],
            argmaxIndex: argmax,
            probabilities: probabilities,
        )
    }

    private func tensor(_ key: String) -> [Float] {
        // All entries are assembled from the frozen layout in init.
        tensors[key]!
    }

    private func encode(_ stream: [[Float]], prefix: String) -> [Float] {
        let normalized = layerNorm(stream, gamma: tensor("\(prefix)_norm_gamma"), beta: tensor("\(prefix)_norm_beta"))
        let encodedD1 = conv1d(
            normalized,
            kernel: tensor("\(prefix)_encoder_d1_kernel"),
            bias: tensor("\(prefix)_encoder_d1_bias"),
            kernelSize: 5,
            inChannels: 10,
            outChannels: 24,
            dilation: 1,
            relu: true,
        )
        let projectedD1 = conv1d(
            encodedD1,
            kernel: tensor("\(prefix)_projection_d1_kernel"),
            bias: tensor("\(prefix)_projection_d1_bias"),
            kernelSize: 1,
            inChannels: 24,
            outChannels: 24,
        )
        let residualD1 = conv1d(
            normalized,
            kernel: tensor("\(prefix)_residual_d1_kernel"),
            bias: tensor("\(prefix)_residual_d1_bias"),
            kernelSize: 1,
            inChannels: 10,
            outChannels: 24,
        )
        let outputD1 = addRelu(projectedD1, residualD1)
        let encodedD2 = conv1d(
            outputD1,
            kernel: tensor("\(prefix)_encoder_d2_kernel"),
            bias: tensor("\(prefix)_encoder_d2_bias"),
            kernelSize: 5,
            inChannels: 24,
            outChannels: 24,
            dilation: 2,
            relu: true,
        )
        let projectedD2 = conv1d(
            encodedD2,
            kernel: tensor("\(prefix)_projection_d2_kernel"),
            bias: tensor("\(prefix)_projection_d2_bias"),
            kernelSize: 1,
            inChannels: 24,
            outChannels: 24,
        )
        return addRelu(projectedD2, outputD1).last ?? Array(repeating: 0, count: 24)
    }

    private func layerNorm(_ input: [[Float]], gamma: [Float], beta: [Float]) -> [[Float]] {
        input.map { row in
            let mean = row.reduce(0.0) { $0 + Double($1) } / Double(row.count)
            let variance = row.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(row.count)
            let inverse = 1 / sqrt(variance + 0.001)
            return row.indices.map { index in
                Float((Double(row[index]) - mean) * inverse * Double(gamma[index]) + Double(beta[index]))
            }
        }
    }

    private func conv1d(
        _ input: [[Float]],
        kernel: [Float],
        bias: [Float],
        kernelSize: Int,
        inChannels: Int,
        outChannels: Int,
        dilation: Int = 1,
        relu: Bool = false,
    ) -> [[Float]] {
        var output = Array(repeating: Array(repeating: Float.zero, count: outChannels), count: input.count)
        for time in input.indices {
            for out in 0..<outChannels {
                var sum = Double(bias[out])
                for k in 0..<kernelSize {
                    let sourceTime = time - dilation * (kernelSize - 1 - k)
                    guard sourceTime >= 0 else { continue }
                    let source = input[sourceTime]
                    let kernelBase = k * inChannels * outChannels + out
                    for channel in 0..<inChannels {
                        sum += Double(source[channel]) * Double(kernel[kernelBase + channel * outChannels])
                    }
                }
                output[time][out] = Float(relu && sum < 0 ? 0 : sum)
            }
        }
        return output
    }

    private func addRelu(_ left: [[Float]], _ right: [[Float]]) -> [[Float]] {
        left.indices.map { time in
            left[time].indices.map { channel in
                Float(max(0, Double(left[time][channel]) + Double(right[time][channel])))
            }
        }
    }

    private func dense(_ input: [Float], kernel: [Float], bias: [Float], units: Int, relu: Bool) -> [Float] {
        (0..<units).map { out in
            var sum = Double(bias[out])
            for index in input.indices {
                sum += Double(input[index]) * Double(kernel[index * units + out])
            }
            return Float(relu && sum < 0 ? 0 : sum)
        }
    }

    private func softmax(_ logits: [Float]) -> [Double] {
        let maximum = logits.map(Double.init).max() ?? 0
        let exponentials = logits.map { Foundation.exp(Double($0) - maximum) }
        let total = exponentials.reduce(0, +)
        return exponentials.map { $0 / total }
    }
}
