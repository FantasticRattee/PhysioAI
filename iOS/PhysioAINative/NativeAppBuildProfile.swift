import Foundation

/// Explicit build/runtime identity for the local native exercise variants.
/// The profile is selected at compile time so one version never depends on
/// removing another version's source or launch flags by hand.
enum NativeAppBuildVariant: String, Equatable {
    case v7
    case v71
    case v72
    case v73
    case v8
}

enum NativeAppBuildProfile {
#if REAL_V8
    static let active: NativeAppBuildVariant = .v8
#elseif REAL_V7
    static let active: NativeAppBuildVariant = .v7
#elseif REAL_V71
    static let active: NativeAppBuildVariant = .v71
#elseif REAL_V72
    static let active: NativeAppBuildVariant = .v72
#elseif REAL_V73
    static let active: NativeAppBuildVariant = .v73
#else
    static let active: NativeAppBuildVariant = .v8
#endif

    static func catalog(for variant: NativeAppBuildVariant) -> [NativeExercise] {
        switch variant {
        case .v7, .v71:
            return [.bottleGrab]
        case .v72, .v73:
            return [.bottleGrab, .sitToStand]
        case .v8:
            return [.bottleGrab, .sitToStand, .dynamicWeightShift]
        }
    }

    static func version(for variant: NativeAppBuildVariant) -> String {
        switch variant {
        case .v7: return "7.0.0"
        case .v71: return "7.1.0"
        case .v72: return "7.2.0"
        case .v73: return "7.3.6"
        case .v8: return "8.0.17"
        }
    }

    static func displayName(for variant: NativeAppBuildVariant) -> String {
        switch variant {
        case .v7: return "PhysioAI App V7 Baseline 5 Experimental"
        case .v71: return "PhysioAI App V7.1 TTS Fix Experimental"
        case .v72: return "PhysioAI App V7.2 Sit-to-Stand Experimental"
        case .v73: return "PhysioAI App V7.3.6 Sit-to-Stand Pose-Wrist Gate + Bottle Grab Baseline Experimental"
        case .v8: return "PhysioAI App V8.0.17 Combination V1 + DWS Experimental"
        }
    }

    static func usesSpeechCoordinator(for variant: NativeAppBuildVariant) -> Bool {
        switch variant {
        case .v7, .v72:
            return false
        case .v71, .v73, .v8:
            return true
        }
    }

    static var activeDisplayName: String { displayName(for: active) }

    static var activeHeaderThai: String {
        switch active {
        case .v7: return "โหมดผู้ป่วย · App V7 · Bottle Grab Baseline #5 ทดลอง"
        case .v71: return "โหมดผู้ป่วย · App V7.1 · Bottle Grab TTS Fix ทดลอง"
        case .v72: return "โหมดผู้ป่วย · App V7.2 · Sit-to-Stand ทดลอง"
        case .v73: return "โหมดผู้ป่วย · App V7.3.6 · Sit-to-Stand Pose-Wrist Gate + Bottle Grab Baseline ทดลอง"
        case .v8: return "โหมดผู้ป่วย · App V8.0.17 · Combination V1 + DWS ทดลอง"
        }
    }

    static var activeHeaderEnglish: String {
        switch active {
        case .v7: return "Patient Practice · App V7 · Bottle Grab Baseline #5 Experimental"
        case .v71: return "Patient Practice · App V7.1 · Bottle Grab TTS Fix Experimental"
        case .v72: return "Patient Practice · App V7.2 · Sit-to-Stand Experimental"
        case .v73: return "Patient Practice · App V7.3.6 · Sit-to-Stand Pose-Wrist Gate + Bottle Grab Baseline Experimental"
        case .v8: return "Patient Practice · App V8.0.17 · Combination V1 + DWS Experimental"
        }
    }

    static var activeContentThai: String {
        switch active {
        case .v7: return "App V7 · Bottle Grab Baseline #5"
        case .v71: return "App V7.1 · Bottle Grab TTS Fix"
        case .v72: return "App V7.2 · Bottle Grab + Sit-to-Stand"
        case .v73: return "App V7.3.6 · Sit-to-Stand Pose-Wrist Gate + Bottle Grab Baseline"
        case .v8: return "App V8.0.17 · Combination V1 + DWS"
        }
    }

    static var activeContentEnglish: String {
        switch active {
        case .v7: return "App V7 · Bottle Grab Baseline #5"
        case .v71: return "App V7.1 · Bottle Grab TTS Fix"
        case .v72: return "App V7.2 · Bottle Grab + Sit-to-Stand"
        case .v73: return "App V7.3.6 · Sit-to-Stand Pose-Wrist Gate + Bottle Grab Baseline"
        case .v8: return "App V8.0.17 · Combination V1 + DWS"
        }
    }

    static var activeContentBadgeThai: String {
        switch active {
        case .v7: return "APP V7 · BASELINE #5"
        case .v71: return "APP V7.1 · TTS FIX"
        case .v72: return "APP V7.2 · SIT-TO-STAND"
        case .v73: return "APP V7.3.6 · SIT-TO-STAND POSE-WRIST"
        case .v8: return "APP V8.0.17 · COMBINATION V1 + DWS"
        }
    }

    static var activeContentBadgeEnglish: String {
        activeContentBadgeThai
    }
}
