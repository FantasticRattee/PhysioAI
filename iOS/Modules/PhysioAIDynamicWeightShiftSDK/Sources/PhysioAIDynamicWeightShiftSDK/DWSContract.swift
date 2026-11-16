import Foundation

public enum DWSDecisionMode: String, Sendable {
    case hybrid
    case aiOnly = "ai_only"
    case strictAIAndRule = "strict_ai_rule"
}

public enum DWSContract {
    public static let sdkID = "dynamic_weight_shifts.validate.v1"
    public static let modelID = "cust_dynamic_weight_shifts-left-tcn-v3"
    public static let landmarkSchemaID = "seated_balance.v2"
    public static let featureContract = "dynamic_weight_shifts_torso_geometry.v1"

    public static let windowSize = 30
    public static let featureSize = 23
    public static let inferenceIntervalMs = 1000.0 / 15.0
    public static let minimumAIConfidence = 0.5
    // Use the same gate for a latest-frame Rest override as every other DWS
    // Hybrid decision. A separate 0.9 gate made the temporal Target state
    // linger after the patient had visibly returned to center.
    public static let realtimeRestMinimumConfidence = 0.5
    public static let qualityDecisionThreshold = 0.5
    // Stable v2 uses the AI + Rule path and never runs in AI-only mode.
    public static let appDecisionMode: DWSDecisionMode = .strictAIAndRule

    // The displayed torso angle is measured from the camera's vertical axis.
    // Eight degrees still belongs to Rest; Target starts strictly above it.
    public static let targetShiftDegrees = 8.0
    public static let centerResetDegrees = 8.0
    // Keep the shoulders close to level. Exactly seven degrees is accepted;
    // anything above seven degrees cannot confirm a Target.
    public static let maximumShoulderTiltDegrees = 7.0
    // A repetition is counted only after the target remains continuously
    // valid for five seconds, regardless of which Hybrid path confirms it.
    public static let targetHoldMs = 5_000.0
    public static let fallbackHoldMs = 5_000.0
    public static let disagreementHoldMs = 5_000.0
    public static let aiOnlyTargetHoldMs = 0.0
    public static let strictAIAndRuleTargetHoldMs = 5_000.0
    public static let restHoldMs = 180.0
    public static let hysteresisDegrees = 0.0
    public static let anglePrecisionDegrees = 0.1

    public static let minimumPrimaryVisibility: Float = 0.65
    public static let minimumStabilizerVisibility: Float = 0.0
    public static let boundaryMinimum: Float = 0.025
    public static let boundaryMaximum: Float = 0.975

    public static let phaseLabels = ["rest", "target"]
    public static let formLabels = ["correct_left", "wrong_left"]
}

public struct DWSLandmark: Codable, Equatable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var visibility: Float

    public init(x: Float, y: Float, z: Float = 0, visibility: Float = 1) {
        self.x = x
        self.y = y
        self.z = z
        self.visibility = visibility
    }

    var isFinite2D: Bool { x.isFinite && y.isFinite }
    var isUsable: Bool { isFinite2D && z.isFinite && visibility.isFinite && visibility > 0 }
}

public enum DWSLandmarkIndex {
    public static let nose = 0
    public static let leftEar = 7
    public static let rightEar = 8
    public static let leftShoulder = 11
    public static let rightShoulder = 12
    public static let leftWrist = 15
    public static let rightWrist = 16
    public static let leftHip = 23
    public static let rightHip = 24
    public static let leftKnee = 25
    public static let rightKnee = 26
    public static let leftAnkle = 27
    public static let rightAnkle = 28
}

public struct DWSSafetyResult: Equatable, Sendable {
    public let isScoreable: Bool
    public let status: String
    public let hint: String
    public let normalizedLandmarks: [DWSLandmark]
    public let detectedView: String?

    public init(isScoreable: Bool, status: String, hint: String,
                normalizedLandmarks: [DWSLandmark], detectedView: String? = nil) {
        self.isScoreable = isScoreable
        self.status = status
        self.hint = hint
        self.normalizedLandmarks = normalizedLandmarks
        self.detectedView = detectedView
    }
}

public struct DWSMetrics: Equatable, Sendable {
    public let isValid: Bool
    public let trunkShiftDegrees: Double
    public let shoulderTiltDegrees: Double
    public let signedTorsoLeanDegrees: Double

    public init(isValid: Bool, trunkShiftDegrees: Double, shoulderTiltDegrees: Double,
                signedTorsoLeanDegrees: Double) {
        self.isValid = isValid
        self.trunkShiftDegrees = trunkShiftDegrees
        self.shoulderTiltDegrees = shoulderTiltDegrees
        self.signedTorsoLeanDegrees = signedTorsoLeanDegrees
    }
}

public struct DWSAISignal: Equatable, Sendable {
    public let phase: String
    public let form: String?
    public let confidence: Double
    public let phaseConfidence: Double
    public let formConfidence: Double?
    public let formEvaluated: Bool
    public let realtimePhaseCandidate: String?
    public let realtimePhaseConfidence: Double?

    public init(phase: String, form: String?, confidence: Double,
                phaseConfidence: Double, formConfidence: Double?, formEvaluated: Bool,
                realtimePhaseCandidate: String? = nil, realtimePhaseConfidence: Double? = nil) {
        self.phase = phase
        self.form = form
        self.confidence = confidence
        self.phaseConfidence = phaseConfidence
        self.formConfidence = formConfidence
        self.formEvaluated = formEvaluated
        self.realtimePhaseCandidate = realtimePhaseCandidate
        self.realtimePhaseConfidence = realtimePhaseConfidence
    }
}

public struct DWSDecisionSnapshot: Equatable, Sendable {
    public let state: String
    public let reason: String
    public let source: String?
    public let reps: Int
    public let completedRep: Bool
    public let pendingCenterReturn: Bool
    public let returnedToCenter: Bool
    public let isScoreable: Bool
    public let isArmed: Bool
    public let trunkShiftDegrees: Double
    public let shoulderTiltDegrees: Double
    public let holdElapsedMs: Double
    public let requiredHoldMs: Double
    public let aiSignal: DWSAISignal?

    public init(state: String, reason: String, source: String? = nil, reps: Int,
                completedRep: Bool = false, pendingCenterReturn: Bool = false,
                returnedToCenter: Bool = false, isScoreable: Bool = true,
                isArmed: Bool = false, trunkShiftDegrees: Double = 0,
                shoulderTiltDegrees: Double = 0, holdElapsedMs: Double = 0,
                requiredHoldMs: Double = 0, aiSignal: DWSAISignal? = nil) {
        self.state = state
        self.reason = reason
        self.source = source
        self.reps = reps
        self.completedRep = completedRep
        self.pendingCenterReturn = pendingCenterReturn
        self.returnedToCenter = returnedToCenter
        self.isScoreable = isScoreable
        self.isArmed = isArmed
        self.trunkShiftDegrees = trunkShiftDegrees
        self.shoulderTiltDegrees = shoulderTiltDegrees
        self.holdElapsedMs = holdElapsedMs
        self.requiredHoldMs = requiredHoldMs
        self.aiSignal = aiSignal
    }
}

public enum DWSError: LocalizedError {
    case missingResource(String)
    case invalidModelOutput(String)
    case invalidFeatureWindow
    case cameraUnavailable
    case cameraPermissionDenied

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): return "Missing SDK resource: \(name)"
        case .invalidModelOutput(let name): return "Invalid Core ML output: \(name)"
        case .invalidFeatureWindow: return "Expected a 30 × 23 Float32 feature window."
        case .cameraUnavailable: return "Front camera is unavailable."
        case .cameraPermissionDenied: return "Camera permission was denied."
        }
    }
}
