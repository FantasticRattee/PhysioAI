import CryptoKit
import Foundation

struct NativeSitToStandPhaseInference: Equatable {
    let phase: String
    let argmaxIndex: Int
    let probabilities: [Double]
}

enum NativeSitToStandPhaseNetV1RuntimeError: LocalizedError {
    case missingWeight(String)
    case invalidWeightLength(String, Int)
    case invalidWeightHash(String)
    case invalidWindow

    var errorDescription: String? {
        switch self {
        case .missingWeight(let name): return "Sit-to-Stand PhaseNet weight is missing: \(name)."
        case .invalidWeightLength(let name, let count): return "Sit-to-Stand PhaseNet weight length is invalid: \(name) (\(count) bytes)."
        case .invalidWeightHash(let name): return "Sit-to-Stand PhaseNet weight hash mismatch: \(name)."
        case .invalidWindow: return "Sit-to-Stand PhaseNet requires a finite 30 × 30 window."
        }
    }
}

/// Dependency-free Swift port of the model-owned causal TCN export. The
/// tensors are explicitly checksum-pinned and use the source Keras row-major
/// Float32 layout. This runtime is phase-only; it neither counts repetitions
/// nor creates comments.
final class NativeSitToStandPhaseNetV1Runtime {
    static let modelID = "sit_to_stand_phasenet_v1_train_only"
    static let sequenceLength = 30
    static let featureCount = 30
    static let filters = 24
    static let classOrder = ["seated_rest", "rise", "standing_hold", "lower"]

    private struct WeightSpec {
        let resource: String
        let count: Int
        let sha256: String
    }

    private static let weightSpecs: [String: WeightSpec] = [
        "d1Kernel": WeightSpec(resource: "causal_tcn_dilation_1__0", count: 2_160, sha256: "0c15f7dd638f1da1d5edf4b5ec827d708dc95088ec97440548d7c5fed71e6e28"),
        "d1Bias": WeightSpec(resource: "causal_tcn_dilation_1__1", count: 24, sha256: "59fbd8f23e6b3a814e6e349ec1bff85da6aec1b2ee2643d2b0afd1095a3ea605"),
        "projectionKernel": WeightSpec(resource: "residual_projection__0", count: 720, sha256: "abf4109bb6d628f8dd8069f24c9f025995ce9d98e03dae677b6dfba54e922280"),
        "projectionBias": WeightSpec(resource: "residual_projection__1", count: 24, sha256: "4ad8890326d89fe6fb345107a643200e294399fd780e372e51d7460771fd53f1"),
        "d2Kernel": WeightSpec(resource: "causal_tcn_dilation_2__0", count: 1_728, sha256: "1c153e6d5f3bac1f66a7da6e0ed5b89244c26955cff5ed7b0489c1593f8e6c5d"),
        "d2Bias": WeightSpec(resource: "causal_tcn_dilation_2__1", count: 24, sha256: "59c4f8a2868c60f243c616e9ba44b748766b238f585f27b2e1ecf6d641a82c27"),
        "d4Kernel": WeightSpec(resource: "causal_tcn_dilation_4__0", count: 1_728, sha256: "fb1573cd7cd94f2b2af7fe7f0531f0deee6420121b210442d69d6161607715e5"),
        "d4Bias": WeightSpec(resource: "causal_tcn_dilation_4__1", count: 24, sha256: "2026a50a681196825980617386b8f0d4e2d159b7813c65e68a5f6536f26879ee"),
        "classifierKernel": WeightSpec(resource: "phase_probabilities__0", count: 96, sha256: "36525a66c660295468b9ef8acc61b1e14848df46cf1199e80560c70245bd9d26"),
        "classifierBias": WeightSpec(resource: "phase_probabilities__1", count: 4, sha256: "2228d400ec6771a3c29b9000bf74234b6a0b6dd4404d33186e9ad0e8027303e6"),
    ]

    private let weights: [String: [Float]]

    private init(weights: [String: [Float]]) {
        self.weights = weights
    }

    static func loadBundled(from bundle: Bundle = .main) throws -> NativeSitToStandPhaseNetV1Runtime {
        var loaded: [String: [Float]] = [:]
        for (key, spec) in weightSpecs {
            guard let url = bundle.url(forResource: spec.resource, withExtension: "f32") else {
                throw NativeSitToStandPhaseNetV1RuntimeError.missingWeight(spec.resource)
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count == spec.count * MemoryLayout<UInt32>.size else {
                throw NativeSitToStandPhaseNetV1RuntimeError.invalidWeightLength(spec.resource, data.count)
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == spec.sha256 else {
                throw NativeSitToStandPhaseNetV1RuntimeError.invalidWeightHash(spec.resource)
            }
            loaded[key] = decodeFloat32LE(data)
        }
        return NativeSitToStandPhaseNetV1Runtime(weights: loaded)
    }

    func predict(window: [[Float]]) throws -> NativeSitToStandPhaseInference {
        guard window.count == Self.sequenceLength,
              window.allSatisfy({ $0.count == Self.featureCount && $0.allSatisfy(\.isFinite) }) else {
            throw NativeSitToStandPhaseNetV1RuntimeError.invalidWindow
        }
        let encodedD1 = conv1d(
            input: window,
            kernel: tensor("d1Kernel"),
            bias: tensor("d1Bias"),
            kernelSize: 3,
            inputChannels: Self.featureCount,
            outputChannels: Self.filters,
            dilation: 1,
            relu: true,
        )
        let residual = conv1d(
            input: window,
            kernel: tensor("projectionKernel"),
            bias: tensor("projectionBias"),
            kernelSize: 1,
            inputChannels: Self.featureCount,
            outputChannels: Self.filters,
            dilation: 1,
            relu: false,
        )
        let block1 = addRelu(encodedD1, residual)
        let encodedD2 = conv1d(
            input: block1,
            kernel: tensor("d2Kernel"),
            bias: tensor("d2Bias"),
            kernelSize: 3,
            inputChannels: Self.filters,
            outputChannels: Self.filters,
            dilation: 2,
            relu: true,
        )
        let block2 = addRelu(encodedD2, block1)
        let encodedD4 = conv1d(
            input: block2,
            kernel: tensor("d4Kernel"),
            bias: tensor("d4Bias"),
            kernelSize: 3,
            inputChannels: Self.filters,
            outputChannels: Self.filters,
            dilation: 4,
            relu: true,
        )
        let block3 = addRelu(encodedD4, block2)
        let pooled = globalAveragePool(block3)
        let logits = dense(
            input: pooled,
            kernel: tensor("classifierKernel"),
            bias: tensor("classifierBias"),
            outputChannels: Self.classOrder.count,
        )
        let probabilities = softmax(logits)
        let argmax = probabilities.indices.max { probabilities[$0] < probabilities[$1] } ?? 0
        return NativeSitToStandPhaseInference(
            phase: Self.classOrder[argmax],
            argmaxIndex: argmax,
            probabilities: probabilities,
        )
    }

    private func tensor(_ key: String) -> [Float] { weights[key] ?? [] }

    private static func decodeFloat32LE(_ data: Data) -> [Float] {
        stride(from: 0, to: data.count, by: 4).map { offset in
            let bits = UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
            return Float(bitPattern: bits)
        }
    }

    private func conv1d(
        input: [[Float]],
        kernel: [Float],
        bias: [Float],
        kernelSize: Int,
        inputChannels: Int,
        outputChannels: Int,
        dilation: Int,
        relu: Bool,
    ) -> [[Float]] {
        input.indices.map { time in
            (0..<outputChannels).map { output in
                var sum = Double(bias[output])
                for kernelIndex in 0..<kernelSize {
                    let sourceTime = time - dilation * (kernelSize - 1 - kernelIndex)
                    guard sourceTime >= 0 else { continue }
                    let base = kernelIndex * inputChannels * outputChannels + output
                    for channel in 0..<inputChannels {
                        sum += Double(input[sourceTime][channel]) * Double(kernel[base + channel * outputChannels])
                    }
                }
                return Float(relu && sum < 0 ? 0 : sum)
            }
        }
    }

    private func addRelu(_ left: [[Float]], _ right: [[Float]]) -> [[Float]] {
        left.indices.map { time in
            left[time].indices.map { channel in
                Float(max(0, Double(left[time][channel]) + Double(right[time][channel])))
            }
        }
    }

    private func globalAveragePool(_ input: [[Float]]) -> [Float] {
        guard let first = input.first else { return [] }
        return first.indices.map { channel in
            Float(input.reduce(0.0) { $0 + Double($1[channel]) } / Double(input.count))
        }
    }

    private func dense(input: [Float], kernel: [Float], bias: [Float], outputChannels: Int) -> [Float] {
        (0..<outputChannels).map { output in
            var sum = Double(bias[output])
            for index in input.indices {
                sum += Double(input[index]) * Double(kernel[index * outputChannels + output])
            }
            return Float(sum)
        }
    }

    private func softmax(_ logits: [Float]) -> [Double] {
        let maximum = logits.map(Double.init).max() ?? 0
        let values = logits.map { Foundation.exp(Double($0) - maximum) }
        let total = values.reduce(0, +)
        return values.map { $0 / total }
    }
}

struct NativeSitToStandPhaseCommentResult {
    let status: String
    let bufferedFrames: Int
    let phase: String?
    let probabilities: [Double]?
    let commentStatus: String
    let cue: String?
    let cueThai: String?
    let completedCommentCycles: Int
}

/// Independent NN phase/comment path. It intentionally owns a distinct phase
/// sequence and never observes `NativeSitToStandGeometryCounter` results.
final class NativeSitToStandPhaseCommentEngine {
    private static let stableWindows = 2
    private let runtime: NativeSitToStandPhaseNetV1Runtime?
    private let profile: NativeSitToStandReferenceProfile?
    private var window: [[Float]] = []
    private var lastPhase: String?
    private var phaseStreak = 0
    private var stablePhase: String?
    private var phaseSequence: [String] = []
    private var activeRows: [(phase: String, vector: [Float])] = []
    private(set) var completedCommentCycles = 0

    init(bundle: Bundle = .main) {
        runtime = try? NativeSitToStandPhaseNetV1Runtime.loadBundled(from: bundle)
        profile = NativeSitToStandReferenceProfile.loadBundled(from: bundle)
    }

    func reset() {
        window.removeAll(keepingCapacity: true)
        lastPhase = nil
        phaseStreak = 0
        stablePhase = nil
        phaseSequence.removeAll(keepingCapacity: true)
        activeRows.removeAll(keepingCapacity: true)
    }

    func ingest(_ frame: NativeSitToStandFeatureFrame) -> NativeSitToStandPhaseCommentResult {
        guard let vector = frame.featureVector, frame.featureReady else {
            reset()
            return result(status: "cannot_assess", bufferedFrames: 0, phase: nil, probabilities: nil, commentStatus: "cannot_assess", cue: nil, cueThai: nil)
        }
        window.append(vector)
        if window.count > NativeSitToStandPhaseNetV1Runtime.sequenceLength {
            window.removeFirst(window.count - NativeSitToStandPhaseNetV1Runtime.sequenceLength)
        }
        guard window.count == NativeSitToStandPhaseNetV1Runtime.sequenceLength else {
            return result(status: "buffering", bufferedFrames: window.count, phase: nil, probabilities: nil, commentStatus: "pending", cue: nil, cueThai: nil)
        }
        guard let runtime else {
            return result(status: "model_unavailable", bufferedFrames: window.count, phase: nil, probabilities: nil, commentStatus: "model_unavailable", cue: nil, cueThai: nil)
        }
        guard let inference = try? runtime.predict(window: window) else {
            reset()
            return result(status: "cannot_assess", bufferedFrames: 0, phase: nil, probabilities: nil, commentStatus: "cannot_assess", cue: nil, cueThai: nil)
        }
        activeRows.append((phase: inference.phase, vector: vector))
        observeStablePhase(inference.phase)
        if phaseSequence == ["seated_rest", "rise", "standing_hold", "lower", "seated_rest"] {
            completedCommentCycles += 1
            let decision = profile?.evaluate(activeRows) ?? .unavailable
            let sequence = phaseSequence
            reset()
            phaseSequence = sequence == ["seated_rest"] ? sequence : []
            return result(
                status: "phase_cycle_completed",
                bufferedFrames: NativeSitToStandPhaseNetV1Runtime.sequenceLength,
                phase: inference.phase,
                probabilities: inference.probabilities,
                commentStatus: decision.status,
                cue: decision.cue,
                cueThai: decision.cueThai,
            )
        }
        return result(status: "phase_ready", bufferedFrames: window.count, phase: inference.phase, probabilities: inference.probabilities, commentStatus: "pending", cue: nil, cueThai: nil)
    }

    private func result(
        status: String,
        bufferedFrames: Int,
        phase: String?,
        probabilities: [Double]?,
        commentStatus: String,
        cue: String?,
        cueThai: String?,
    ) -> NativeSitToStandPhaseCommentResult {
        NativeSitToStandPhaseCommentResult(
            status: status,
            bufferedFrames: bufferedFrames,
            phase: phase,
            probabilities: probabilities,
            commentStatus: commentStatus,
            cue: cue,
            cueThai: cueThai,
            completedCommentCycles: completedCommentCycles,
        )
    }

    private func observeStablePhase(_ phase: String) {
        if phase == lastPhase {
            phaseStreak += 1
        } else {
            lastPhase = phase
            phaseStreak = 1
        }
        guard phaseStreak >= Self.stableWindows, phase != stablePhase else { return }
        stablePhase = phase
        guard let expected = expectedNextPhase() else {
            phaseSequence = phase == "seated_rest" ? [phase] : []
            return
        }
        if phase == expected {
            phaseSequence.append(phase)
        } else if phase == "seated_rest" {
            phaseSequence = [phase]
        } else {
            phaseSequence = []
        }
    }

    private func expectedNextPhase() -> String? {
        guard !phaseSequence.isEmpty else { return "seated_rest" }
        let order = ["seated_rest", "rise", "standing_hold", "lower", "seated_rest"]
        guard phaseSequence.count < order.count else { return nil }
        return order[phaseSequence.count]
    }
}

private struct NativeSitToStandReferenceDecision {
    let status: String
    let cue: String?
    let cueThai: String?

    static let unavailable = NativeSitToStandReferenceDecision(status: "reference_profile_unavailable", cue: nil, cueThai: nil)
}

private final class NativeSitToStandReferenceProfile {
    private struct Envelope: Decodable {
        let lower: Double
        let median: Double
        let upper: Double
    }

    private struct Payload: Decodable {
        let phaseFeatureEnvelopes: [String: [String: Envelope]]
    }

    private let envelopes: [String: [String: Envelope]]

    private init(envelopes: [String: [String: Envelope]]) {
        self.envelopes = envelopes
    }

    static func loadBundled(from bundle: Bundle) -> NativeSitToStandReferenceProfile? {
        guard let url = bundle.url(forResource: "sit_to_stand_front_normal_reference_profile_v1_expanded_development", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        return NativeSitToStandReferenceProfile(envelopes: payload.phaseFeatureEnvelopes)
    }

    func evaluate(_ rows: [(phase: String, vector: [Float])]) -> NativeSitToStandReferenceDecision {
        guard !rows.isEmpty else { return .unavailable }
        let armIndexes = [19, 21]
        let trunkIndex = 6
        let armPersistent = armIndexes.contains { persistent(rows, featureIndex: $0) }
        let trunkPersistent = persistent(rows, featureIndex: trunkIndex)
        if armPersistent {
            return NativeSitToStandReferenceDecision(
                status: "named_deviation",
                cue: "Move the arm back toward the reference path.",
                cueThai: "ลองขยับแขนกลับเข้าใกล้แนวอ้างอิง",
            )
        }
        if trunkPersistent {
            return NativeSitToStandReferenceDecision(
                status: "named_deviation",
                cue: "Keep the trunk closer to the reference midline.",
                cueThai: "ลองรักษาลำตัวให้อยู่ใกล้แนวอ้างอิง",
            )
        }
        return NativeSitToStandReferenceDecision(status: "no_named_deviation", cue: nil, cueThai: nil)
    }

    private func persistent(_ rows: [(phase: String, vector: [Float])], featureIndex: Int) -> Bool {
        let names = NativeSitToStandFeatureNames.names
        guard names.indices.contains(featureIndex) else { return false }
        var sampleCount = 0
        var breachCount = 0
        var run = 0
        var longestRun = 0
        for row in rows {
            guard row.vector.indices.contains(featureIndex),
                  let envelope = envelopes[row.phase]?[names[featureIndex]] else { continue }
            sampleCount += 1
            let value = Double(row.vector[featureIndex])
            if value < envelope.lower || value > envelope.upper {
                breachCount += 1
                run += 1
                longestRun = max(longestRun, run)
            } else {
                run = 0
            }
        }
        guard sampleCount > 0 else { return false }
        return breachCount >= 3 && longestRun >= 3 && Double(breachCount) / Double(sampleCount) >= 0.60
    }
}

enum NativeSitToStandFeatureNames {
    static let names = [
        "pelvis_height_above_ankles_norm", "pelvis_height_velocity_norm_per_s",
        "pelvis_view_plane_offset_from_ankles_norm", "pelvis_view_plane_velocity_norm_per_s",
        "trunk_view_plane_tilt_deg_div_90", "trunk_view_plane_tilt_velocity_tanh",
        "trunk_lateral_offset_norm", "trunk_lateral_velocity_norm_per_s",
        "left_hip_angle_deg_div_180", "right_hip_angle_deg_div_180", "hip_angle_asymmetry_deg_div_180",
        "left_knee_angle_deg_div_180", "right_knee_angle_deg_div_180", "knee_angle_asymmetry_deg_div_180",
        "left_ankle_proxy_angle_deg_div_180", "right_ankle_proxy_angle_deg_div_180", "ankle_proxy_asymmetry_deg_div_180",
        "stance_width_norm", "foot_center_offset_from_pelvis_norm",
        "left_wrist_to_shoulder_x_norm", "left_wrist_to_shoulder_y_norm",
        "right_wrist_to_shoulder_x_norm", "right_wrist_to_shoulder_y_norm",
        "left_wrist_speed_norm_per_s", "right_wrist_speed_norm_per_s",
        "left_elbow_angle_deg_div_180", "right_elbow_angle_deg_div_180",
        "left_arm_elevation_deg_div_180", "right_arm_elevation_deg_div_180", "wrist_span_norm",
    ]
}
