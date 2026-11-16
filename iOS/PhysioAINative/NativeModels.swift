import Combine
import Foundation

enum NativeAppRoute: Equatable {
    case welcome
    case login
    case register
    case home
    case history
    case communication
    case practice
    case summary
}

enum NativePresentationMode: String, CaseIterable, Identifiable {
    case standard
    case audioOnly
    case visualOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .audioOnly: return "Audio-Only"
        case .visualOnly: return "Visual-Only"
        }
    }
}

struct NativeExercise: Identifiable, Equatable {
    let id: String
    let title: String
    let titleThai: String
    let detail: String
    let detailThai: String
    let isExperimental: Bool
    let category: String?
    let type: String
    let reps: Int
    let sets: Int
    let holdSec: Double
    let target: Double
    let rest: Double
    let tolerance: Double
    let primaryJoint: String
    let direction: String

    init(
        id: String,
        title: String,
        titleThai: String,
        detail: String,
        detailThai: String,
        isExperimental: Bool = false,
        category: String? = nil,
        type: String = "rep",
        reps: Int = 10,
        sets: Int = 3,
        holdSec: Double = 1.5,
        target: Double = 120,
        rest: Double = 30,
        tolerance: Double = 15,
        primaryJoint: String = "right_shoulder",
        direction: String = "up",
    ) {
        self.id = id
        self.title = title
        self.titleThai = titleThai
        self.detail = detail
        self.detailThai = detailThai
        self.isExperimental = isExperimental
        self.category = category
        self.type = type
        self.reps = reps
        self.sets = sets
        self.holdSec = holdSec
        self.target = target
        self.rest = rest
        self.tolerance = tolerance
        self.primaryJoint = primaryJoint
        self.direction = direction
    }

    static let bottleGrab = NativeExercise(
        id: "bottle_grab",
        title: "Bottle Grab",
        titleThai: "หยิบขวด",
        detail: "Experimental camera test — reach, grasp, release and return",
        detailThai: "โหมดทดลองจากกล้อง — เอื้อม หยิบ ปล่อย และกลับท่าเดิม",
        isExperimental: true,
        reps: 1,
        sets: 1,
        holdSec: 0.5,
        target: 105,
        rest: 55,
        tolerance: 18,
        primaryJoint: "left_elbow",
    )

    static let sitToStand = NativeExercise(
        id: "sit_to_stand",
        title: "Sit to Stand",
        titleThai: "ลุก-นั่งจากเก้าอี้",
        detail: "Experimental camera exercise — stand up and return to the chair",
        detailThai: "ท่ากล้องทดลอง — ลุกขึ้นยืนแล้วนั่งกลับเก้าอี้",
        isExperimental: true,
        reps: 5,
        sets: 1,
        holdSec: 0.5,
        target: 170,
        rest: 90,
        tolerance: 18,
        primaryJoint: "right_knee",
        direction: "up",
    )

    /// Dynamic Weight Shift v3.0.0 owns a standalone front-camera, Pose Heavy,
    /// Core ML TCN, safety gate, counter, and practice presentation. It never
    /// enters the legacy NativePracticeView camera/runtime pipeline.
    static let dynamicWeightShift = NativeExercise(
        id: "cust_dynamic_weight_shifts",
        title: "Dynamic Weight Shift",
        titleThai: "ฝึกเลื่อนน้ำหนักขณะนั่ง",
        detail: "Shift your seated weight sideways while keeping the shoulders level",
        detailThai: "เลื่อนน้ำหนักขณะนั่งไปด้านข้าง โดยรักษาแนวหัวไหล่ให้ตรง",
        isExperimental: true,
        category: "seated_balance",
        reps: 10,
        sets: 1,
        holdSec: 5,
        target: 8,
        rest: 8,
        tolerance: 7,
        primaryJoint: "torso",
        direction: "left",
    )

    static func from(id: String) -> NativeExercise? {
        switch id {
        case "bottle_grab": return .bottleGrab
        case "sit_to_stand": return .sitToStand
        case "cust_dynamic_weight_shifts": return .dynamicWeightShift
        case "shoulder":
            return NativeExercise(id: id, title: "Shoulder flexion", titleThai: "ยกแขนขึ้น", detail: "Raise your right arm forward and up", detailThai: "ยกแขนขวาไปข้างหน้าและขึ้นสูง", reps: 12, sets: 3, target: 158, rest: 22, primaryJoint: "right_shoulder")
        case "knee":
            return NativeExercise(id: id, title: "Knee extension", titleThai: "เหยียดเข่า", detail: "Straighten your knee fully", detailThai: "เหยียดเข่าให้ตรงสุด", reps: 15, sets: 2, target: 172, rest: 92, primaryJoint: "right_knee")
        case "hip":
            return NativeExercise(id: id, title: "Hip abduction", titleThai: "กางสะโพก", detail: "Lift your leg out to the side", detailThai: "ยกขาออกไปด้านข้าง", reps: 12, sets: 2, target: 148, rest: 176, primaryJoint: "right_hip", direction: "down")
        case "squat":
            return NativeExercise(id: id, title: "Assisted squat", titleThai: "สควอทช่วยพยุง", detail: "Lower into a supported squat", detailThai: "ย่อตัวลงสควอทแบบมีที่พยุง", reps: 10, sets: 3, target: 96, rest: 170, primaryJoint: "right_knee", direction: "down")
        case "balance":
            return NativeExercise(id: id, title: "Single-leg balance", titleThai: "ยืนขาเดียว", detail: "Stand on one leg and hold", detailThai: "ยืนขาเดียวแล้วค้างไว้", type: "hold", reps: 1, sets: 2, holdSec: 20, target: 70, rest: 70, tolerance: 18, primaryJoint: "right_knee", direction: "hold")
        case "overhead_ceiling_reach":
            return NativeExercise(id: id, title: "Overhead reach", titleThai: "เอื้อมแขนขึ้นเหนือศีรษะ", detail: "Reach your arm overhead", detailThai: "เอื้อมแขนขึ้นเหนือศีรษะ", reps: 10, sets: 3, target: 177, rest: 25, primaryJoint: "right_shoulder")
        case "lateral_arm_raise":
            return NativeExercise(id: id, title: "Lateral arm raise", titleThai: "กางแขนด้านข้าง", detail: "Raise your arm to the side", detailThai: "กางแขนออกด้านข้าง", reps: 10, sets: 3, target: 100, rest: 24, primaryJoint: "left_shoulder")
        case "cross_body_shoulder_stretch":
            return NativeExercise(id: id, title: "Cross-body shoulder stretch", titleThai: "ยืดไหล่พาดลำตัว", detail: "Hold a cross-body shoulder stretch", detailThai: "ยืดไหล่พาดลำตัว", type: "hold", reps: 1, sets: 2, holdSec: 15, target: 71, rest: 20, primaryJoint: "right_shoulder", direction: "hold")
        default:
            return nil
        }
    }

    /// Produces a local execution configuration from an already-authorized
    /// Therapist plan item. Model, detector, and capture settings stay the
    /// same; only therapist-owned dose/tolerance values are substituted.
    func applying(planItem: NativePlanItem) -> NativeExercise {
        NativeExercise(
            id: id,
            title: title,
            titleThai: titleThai,
            detail: detail,
            detailThai: detailThai,
            isExperimental: isExperimental,
            category: category,
            type: type,
            reps: max(1, planItem.reps ?? reps),
            sets: max(1, planItem.sets ?? sets),
            holdSec: max(0, planItem.holdSec ?? holdSec),
            target: target,
            rest: rest,
            tolerance: max(0, Double(planItem.tol ?? Int(tolerance))),
            primaryJoint: primaryJoint,
            direction: direction,
        )
    }
}

struct NativePatient: Equatable {
    let id: String
    let name: String
    let email: String
    let role: String
}

struct NativeSessionSummary: Equatable {
    let exercise: NativeExercise
    let startedAt: Date
    let durationSeconds: Int
    let cuesPresented: Int
    let experimentalOnly: Bool
    let overallScore: Int?
    let poseScore: Int?
    let motionScore: Int?
    let reps: Int
    let sets: Int
    let invalidReps: Int
    let ruleBasedScore: NativeRuleBasedSessionScoreV13?

    init(
        exercise: NativeExercise,
        startedAt: Date,
        durationSeconds: Int,
        cuesPresented: Int,
        experimentalOnly: Bool,
        overallScore: Int? = nil,
        poseScore: Int? = nil,
        motionScore: Int? = nil,
        reps: Int = 0,
        sets: Int = 0,
        invalidReps: Int = 0,
        ruleBasedScore: NativeRuleBasedSessionScoreV13? = nil,
    ) {
        self.exercise = exercise
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.cuesPresented = cuesPresented
        self.experimentalOnly = experimentalOnly
        self.overallScore = overallScore
        self.poseScore = poseScore
        self.motionScore = motionScore
        self.reps = reps
        self.sets = sets
        self.invalidReps = invalidReps
        self.ruleBasedScore = ruleBasedScore
    }
}

struct NativeAuthResponse: Codable {
    let token: String
    let user: NativeRemoteUser
}

struct NativeRemoteUser: Codable, Equatable {
    let id: String
    let name: String
    let email: String
    let role: String
}

struct NativePlanItem: Codable, Equatable, Identifiable {
    let exerciseId: String
    let reps: Int?
    let sets: Int?
    let holdSec: Double?
    let tol: Int?
    let countMode: String?

    var id: String { exerciseId }

    private enum CodingKeys: String, CodingKey {
        case exerciseId, reps, sets, holdSec, tol, countMode
    }

    init(exerciseId: String, reps: Int? = nil, sets: Int? = nil, holdSec: Double? = nil, tol: Int? = nil, countMode: String? = nil) {
        self.exerciseId = exerciseId
        self.reps = reps
        self.sets = sets
        self.holdSec = holdSec
        self.tol = tol
        self.countMode = countMode
    }
}

enum NativePracticeCompletionDecision: Equatable {
    case continuePractice
    case finishOnce
    case alreadyFinished
}

/// One-shot host policy for a selected Therapist plan. It observes the
/// counter's total; it never creates, changes, or relabels repetitions.
struct NativePracticeCompletionPolicy: Equatable {
    private(set) var didFinish = false

    mutating func observe(
        isPrescribedPlan: Bool,
        completedReps: Int,
        targetTotalReps: Int,
    ) -> NativePracticeCompletionDecision {
        guard isPrescribedPlan else { return .continuePractice }
        guard !didFinish else { return .alreadyFinished }
        guard completedReps >= max(1, targetTotalReps) else { return .continuePractice }
        didFinish = true
        return .finishOnce
    }

    mutating func reset() {
        didFinish = false
    }
}

struct NativePlan: Codable, Equatable {
    let patientId: String?
    let items: [NativePlanItem]
    let freqPerDay: Int?
    let daysPerWeek: Int?
    let durationDays: Int?
    let durationWeeks: Int?
    let startDate: String?
    let notes: String?
}

struct NativeSessionPayload: Codable, Equatable {
    let id: String
    let exerciseId: String
    let endedAt: Int64
    let kind: String
    let durationSeconds: Int
    let cuesPresented: Int
    let experimentalOnly: Bool
}

struct NativeSessionRecord: Codable, Equatable, Identifiable {
    let id: String
    let exerciseId: String?
    let startedAt: Int64
    let endedAt: Int64
    let kind: String
    let durationSeconds: Int
    let completedReps: Int
    let completedSets: Int
    let invalidReps: Int
    let cuesPresented: Int
    let overallScore: Int?
    let poseScore: Int?
    let motionScore: Int?
    let experimentalOnly: Bool
    let mediaSessionId: String?

    private enum CodingKeys: String, CodingKey {
        case id, exerciseId, startedAt, endedAt, kind, durationSeconds, completedReps, completedSets, invalidReps, cuesPresented, overallScore, poseScore, motionScore, experimentalOnly, mediaSessionId
    }

    init(id: String, exerciseId: String?, startedAt: Int64? = nil, endedAt: Int64, kind: String = "plan", durationSeconds: Int = 0, completedReps: Int = 0, completedSets: Int = 0, invalidReps: Int = 0, cuesPresented: Int = 0, overallScore: Int? = nil, poseScore: Int? = nil, motionScore: Int? = nil, experimentalOnly: Bool = false, mediaSessionId: String? = nil) {
        self.id = id
        self.exerciseId = exerciseId
        self.startedAt = startedAt ?? max(0, endedAt - Int64(max(0, durationSeconds) * 1000))
        self.endedAt = endedAt
        self.kind = kind
        self.durationSeconds = durationSeconds
        self.completedReps = completedReps
        self.completedSets = completedSets
        self.invalidReps = invalidReps
        self.cuesPresented = cuesPresented
        self.overallScore = overallScore
        self.poseScore = poseScore
        self.motionScore = motionScore
        self.experimentalOnly = experimentalOnly
        self.mediaSessionId = mediaSessionId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        exerciseId = try c.decodeIfPresent(String.self, forKey: .exerciseId)
        if let n = try? c.decode(Int64.self, forKey: .endedAt) {
            endedAt = n
        } else if let text = try? c.decode(String.self, forKey: .endedAt), let date = ISO8601DateFormatter().date(from: text) {
            endedAt = Int64(date.timeIntervalSince1970 * 1000)
        } else {
            endedAt = 0
        }
        if let n = try? c.decode(Int64.self, forKey: .startedAt) {
            startedAt = n
        } else if let text = try? c.decode(String.self, forKey: .startedAt), let date = ISO8601DateFormatter().date(from: text) {
            startedAt = Int64(date.timeIntervalSince1970 * 1000)
        } else {
            startedAt = max(0, endedAt - Int64((try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0) * 1000))
        }
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "plan"
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds) ?? 0
        completedReps = try c.decodeIfPresent(Int.self, forKey: .completedReps) ?? 0
        completedSets = try c.decodeIfPresent(Int.self, forKey: .completedSets) ?? 0
        invalidReps = try c.decodeIfPresent(Int.self, forKey: .invalidReps) ?? 0
        cuesPresented = try c.decodeIfPresent(Int.self, forKey: .cuesPresented) ?? 0
        overallScore = try c.decodeIfPresent(Int.self, forKey: .overallScore)
        poseScore = try c.decodeIfPresent(Int.self, forKey: .poseScore)
        motionScore = try c.decodeIfPresent(Int.self, forKey: .motionScore)
        experimentalOnly = try c.decodeIfPresent(Bool.self, forKey: .experimentalOnly) ?? false
        mediaSessionId = try c.decodeIfPresent(String.self, forKey: .mediaSessionId)
    }
}

struct NativeAIReviewContent: Codable, Equatable {
    let summary: String
    let observations: [String]
    let focusNextSession: [String]
    let disclaimer: String
}

struct NativeSessionReviewSnapshot: Equatable {
    var aiStatus: String?
    var aiReview: NativeAIReviewContent?
    var therapistBody: String?
    var therapistUpdatedAt: Date?
}

struct NativeLiveAssistCue: Codable, Equatable {
    let en: String?
    let th: String?
}

struct NativeLiveAssistEvent: Codable, Equatable, Identifiable {
    let id: String
    let exerciseId: String?
    let correction: String?
    let joint: String?
    let cue: NativeLiveAssistCue
    let expiresAt: Int64?

    var symbol: String {
        switch correction {
        case "increase_angle": return "↑"
        case "decrease_angle": return "↓"
        case "straighten": return "↗"
        case "bend": return "↘"
        case "hold": return "✓"
        case "reset": return "↺"
        default: return "•"
        }
    }

    func text(language: String) -> String? {
        (language == "th" ? cue.th : cue.en) ?? cue.en ?? cue.th
    }
}

struct NativeLiveAssistBatch: Codable, Equatable {
    let items: [NativeLiveAssistEvent]
    let cursor: String?
}

@MainActor
final class NativeAppModel: ObservableObject {
    @Published var route: NativeAppRoute = .welcome
    @Published var patient: NativePatient?
    @Published var selectedExercise: NativeExercise?
    @Published var presentationMode: NativePresentationMode = .standard
    @Published var language = "th"
    @Published var fixtureMode = true
    @Published var isBusy = false
    @Published var statusMessage: String?
    @Published var latestSummary: NativeSessionSummary?
    @Published var latestDWSReport: DWSSessionReport?
    @Published var latestSessionID: String?
    /// V8 local-only JSON captured before the practice camera is dismissed.
    /// It is exported only by an explicit user action in NativeSummaryView.
    @Published var latestRuleBasedEvidenceJSON: Data?
    @Published var cloudPlan: NativePlan?
    @Published var sessions: [NativeSessionRecord] = []
    @Published var sessionReviews: [String: NativeSessionReviewSnapshot] = [:]
    @Published var isLoadingSessionHistory = false
    @Published var sessionHistoryError: String?
    @Published var persistenceMessage: String?
    @Published var homeError: String?
    @Published var selectedDose: NativePlanItem?
    @Published var selectedKind: String = "extra"

    let catalog: [NativeExercise] = NativeAppBuildProfile.catalog(for: NativeAppBuildProfile.active)
    private let api = NativeAPIClient()
    private let supabaseAuth = NativeSupabaseAuthClient()

    init() {
        language = UserDefaults.standard.string(forKey: "native.language") ?? "th"
        presentationMode = NativePresentationMode(rawValue: UserDefaults.standard.string(forKey: "native.presentationMode") ?? "standard") ?? .standard
        fixtureMode = UserDefaults.standard.object(forKey: "native.fixtureMode") as? Bool ?? NativeConfig.isSimulatorFixtureDefault
        if CommandLine.arguments.contains("--native-fixture-welcome") {
            fixtureMode = true
            patient = nil
            route = .welcome
        } else if CommandLine.arguments.contains("--native-fixture-login") {
            fixtureMode = true
            route = .login
        } else if CommandLine.arguments.contains("--native-fixture-register") {
            fixtureMode = true
            route = .register
        } else if CommandLine.arguments.contains("--native-fixture-summary") {
            fixtureMode = true
            patient = NativePatient(id: "simulator-patient-1", name: "Patient 1", email: "patient1@simulator.local", role: "patient")
            selectedExercise = .bottleGrab
            latestSummary = NativeSessionSummary(exercise: .bottleGrab, startedAt: Date().addingTimeInterval(-42), durationSeconds: 42, cuesPresented: 2, experimentalOnly: true)
            route = .summary
        } else if CommandLine.arguments.contains("--native-fixture-practice") {
            fixtureMode = true
            patient = NativePatient(id: "simulator-patient-1", name: "Patient 1", email: "patient1@simulator.local", role: "patient")
            selectedExercise = .bottleGrab
            route = .practice
        } else if CommandLine.arguments.contains("--native-fixture-home") {
            fixtureMode = true
            patient = NativePatient(id: "simulator-patient-1", name: "Patient 1", email: "patient1@simulator.local", role: "patient")
            route = .home
        } else {
            restoreSession()
        }
        if patient != nil && route == .home {
            Task { @MainActor [weak self] in await self?.loadHome() }
        }
    }

    var isSignedIn: Bool { patient != nil }

    var isThai: Bool { language == "th" }

    /// Match the React Native store contract: IDs from the retained exercise
    /// library can still be opened from an older therapist plan, while truly
    /// unknown IDs are dropped instead of silently becoming Bottle Grab.
    var planItems: [NativePlanItem] {
        (cloudPlan?.items ?? []).filter { exercise(for: $0.exerciseId) != nil }
    }

    var doneTodayIDs: Set<String> {
        let start = Calendar.current.startOfDay(for: Date())
        let startMs = Int64(start.timeIntervalSince1970 * 1000)
        return Set(sessions.filter { $0.endedAt >= startMs && $0.kind != "extra" }.compactMap(\.exerciseId))
    }

    func exercise(for id: String) -> NativeExercise? {
        NativeExercise.from(id: id)
    }

    func restoreSession() {
        guard UserDefaults.standard.bool(forKey: "native.signedIn") || UserDefaults.standard.bool(forKey: "native.fixtureSignedIn") else { return }
        let fixture = UserDefaults.standard.bool(forKey: "native.fixtureSignedIn")
        guard fixture else {
            Task { @MainActor [weak self] in
                await self?.restoreSupabaseSession()
            }
            return
        }
        patient = NativePatient(
            id: UserDefaults.standard.string(forKey: "native.patientId") ?? "simulator-patient-1",
            name: UserDefaults.standard.string(forKey: "native.patientName") ?? (fixture ? "Patient 1" : "Patient"),
            email: UserDefaults.standard.string(forKey: "native.patientEmail") ?? "patient1@simulator.local",
            role: "patient",
        )
        fixtureMode = fixture
        route = .home
    }

    private func restoreSupabaseSession() async {
        do {
            let response = try await supabaseAuth.restoredSession()
            NativeKeychainStore.setToken(response.token)
            NativeSessionMediaUploader.shared.resume()
            patient = NativePatient(
                id: response.user.id,
                name: UserDefaults.standard.string(forKey: "native.patientName") ?? response.user.name,
                email: response.user.email,
                role: response.user.role
            )
            fixtureMode = false
            persistPatient(response.user)
            route = .home
            await loadHome()
        } catch {
            clearLocalSession()
        }
    }

    func continueAsSimulatorPatient() {
        fixtureMode = true
        UserDefaults.standard.set(true, forKey: "native.fixtureMode")
        patient = NativePatient(
            id: "simulator-patient-1",
            name: "Patient 1",
            email: "patient1@simulator.local",
            role: "patient",
        )
        UserDefaults.standard.set(true, forKey: "native.fixtureSignedIn")
        UserDefaults.standard.set(true, forKey: "native.signedIn")
        UserDefaults.standard.set(patient?.id, forKey: "native.patientId")
        UserDefaults.standard.set(patient?.email, forKey: "native.patientEmail")
        UserDefaults.standard.set("Patient 1", forKey: "native.patientName")
        statusMessage = "Simulator fixture account is active."
        route = .home
    }

    func showLogin() {
        statusMessage = nil
        route = .login
    }

    func showRegister() {
        statusMessage = nil
        route = .register
    }

    func backToWelcome() {
        statusMessage = nil
        route = .welcome
    }

    func setLanguage(_ value: String) {
        language = value
        UserDefaults.standard.set(value, forKey: "native.language")
    }

    func setPresentationMode(_ value: NativePresentationMode) {
        presentationMode = value
        UserDefaults.standard.set(value.rawValue, forKey: "native.presentationMode")
    }

    func submitLogin(email: String, password: String) {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedEmail.isEmpty, !password.isEmpty else {
            statusMessage = isThai ? "กรอกอีเมลและรหัสผ่านก่อน" : "Enter your email and password first."
            return
        }

        if fixtureMode {
            patient = NativePatient(id: "simulator-patient-1", name: "Patient 1", email: normalizedEmail, role: "patient")
            UserDefaults.standard.set(true, forKey: "native.fixtureSignedIn")
            UserDefaults.standard.set("Patient 1", forKey: "native.patientName")
            statusMessage = isThai ? "เข้าสู่ระบบโหมด Simulator แล้ว" : "Signed in with the Simulator fixture."
            route = .home
            return
        }

        isBusy = true
        statusMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let response = try await self.supabaseAuth.login(email: normalizedEmail, password: password)
                NativeKeychainStore.setToken(response.token)
                NativeSessionMediaUploader.shared.resume()
                self.patient = NativePatient(id: response.user.id, name: response.user.name, email: response.user.email, role: response.user.role)
                self.persistPatient(response.user)
                UserDefaults.standard.set(false, forKey: "native.fixtureSignedIn")
                self.statusMessage = self.isThai ? "เข้าสู่ระบบสำเร็จ" : "Signed in successfully."
                self.route = .home
                await self.loadHome()
            } catch {
                self.statusMessage = self.userFacing(error)
            }
            self.isBusy = false
        }
    }

    func submitRegister(name: String, email: String, password: String, confirm: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmedName.isEmpty, !normalizedEmail.isEmpty, password.count >= 6 else {
            statusMessage = isThai ? "กรอกข้อมูลให้ครบและใช้รหัสผ่านอย่างน้อย 6 ตัวอักษร" : "Enter all fields and use at least 6 password characters."
            return
        }
        guard password == confirm else {
            statusMessage = isThai ? "รหัสผ่านไม่ตรงกัน" : "Passwords do not match."
            return
        }

        if fixtureMode {
            patient = NativePatient(id: "simulator-patient-new", name: trimmedName, email: normalizedEmail, role: "patient")
            UserDefaults.standard.set(true, forKey: "native.fixtureSignedIn")
            UserDefaults.standard.set(trimmedName, forKey: "native.patientName")
            statusMessage = isThai ? "สร้างบัญชีโหมด Simulator แล้ว" : "Created a Simulator fixture account."
            route = .home
            return
        }

        isBusy = true
        statusMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let response = try await self.supabaseAuth.register(name: trimmedName, email: normalizedEmail, password: password) else {
                    self.statusMessage = self.isThai
                        ? "สมัครสำเร็จ กรุณายืนยันอีเมล แล้วกลับมาเข้าสู่ระบบ"
                        : "Account created. Confirm your email, then log in."
                    self.route = .login
                    self.isBusy = false
                    return
                }
                NativeKeychainStore.setToken(response.token)
                NativeSessionMediaUploader.shared.resume()
                self.patient = NativePatient(id: response.user.id, name: response.user.name, email: response.user.email, role: response.user.role)
                self.persistPatient(response.user)
                UserDefaults.standard.set(false, forKey: "native.fixtureSignedIn")
                self.statusMessage = self.isThai ? "สมัครบัญชีสำเร็จ" : "Account created successfully."
                self.route = .home
                await self.loadHome()
            } catch {
                self.statusMessage = self.userFacing(error)
            }
            self.isBusy = false
        }
    }

    func logout() {
        Task { [supabaseAuth] in
            await supabaseAuth.signOut()
        }
        clearLocalSession()
    }

    private func clearLocalSession() {
        NativeKeychainStore.setToken(nil)
        patient = nil
        selectedExercise = nil
        selectedDose = nil
        selectedKind = "extra"
        latestSummary = nil
        latestRuleBasedEvidenceJSON = nil
        cloudPlan = nil
        sessions = []
        persistenceMessage = nil
        homeError = nil
        UserDefaults.standard.set(false, forKey: "native.fixtureSignedIn")
        UserDefaults.standard.set(false, forKey: "native.signedIn")
        UserDefaults.standard.removeObject(forKey: "native.patientId")
        UserDefaults.standard.removeObject(forKey: "native.patientName")
        UserDefaults.standard.removeObject(forKey: "native.patientEmail")
        route = .welcome
    }

    func openExercise(_ exercise: NativeExercise) {
        latestDWSReport = nil
        latestSessionID = nil
        selectedExercise = exercise
        selectedDose = nil
        selectedKind = "extra"
        latestRuleBasedEvidenceJSON = nil
        route = .practice
    }

    func openCommunication() {
        route = .communication
    }

    func openSessionHistory() {
        route = .history
    }

    func openPlanItem(_ item: NativePlanItem) {
        latestDWSReport = nil
        latestSessionID = nil
        guard let resolved = exercise(for: item.exerciseId) else {
            persistenceMessage = isThai ? "ท่านี้ยังไม่พร้อมใช้งานในแอป Native" : "This exercise is not available in the native app yet."
            return
        }
        selectedExercise = resolved.applying(planItem: item)
        selectedDose = item
        selectedKind = "plan"
        latestRuleBasedEvidenceJSON = nil
        route = .practice
    }

    func finishPractice(
        cuesPresented: Int,
        startedAt: Date,
        output: NativeBottleGrabOutput? = nil,
        completedReps: Int? = nil,
        ruleBasedEvidenceJSON: Data? = nil,
        sessionID: String? = nil,
        mediaSessionID: String? = nil,
    ) {
        guard let exercise = selectedExercise else {
            route = .home
            return
        }
        let experimentalReps = max(
            0,
            completedReps ?? output?.totalReps ?? output?.reps ?? 0,
        )
        let experimentalSets = exercise.isExperimental
            ? min(max(0, exercise.sets), experimentalReps / max(1, exercise.reps))
            : (output?.setsDone ?? 0)
        let validatedEvidence = ruleBasedEvidenceJSON.flatMap { data -> RuleBasedSessionRecord? in
            guard let record = try? NativeEvidenceExport.validate(data),
                  record.exerciseID == exercise.id else {
                return nil
            }
            return record
        }
        let ruleBasedScore = validatedEvidence.map {
            NativeRuleBasedSessionScorerV13.score(
                $0,
                authoritativeCompletedReps: experimentalReps,
            )
        }
        let evidenceInvalidReps = ruleBasedScore?.flaggedReps ?? 0
        let summary = NativeSessionSummary(
            exercise: exercise,
            startedAt: startedAt,
            durationSeconds: max(1, Int(Date().timeIntervalSince(startedAt))),
            cuesPresented: cuesPresented,
            experimentalOnly: exercise.isExperimental,
            overallScore: exercise.isExperimental ? ruleBasedScore?.overallScore : output?.score,
            poseScore: exercise.isExperimental ? ruleBasedScore?.formQualityScore : output?.poseScore,
            motionScore: nil,
            reps: exercise.isExperimental ? experimentalReps : (output?.reps ?? 0),
            sets: experimentalSets,
            invalidReps: evidenceInvalidReps,
            ruleBasedScore: exercise.isExperimental ? ruleBasedScore : nil,
        )
        latestSummary = summary
        latestRuleBasedEvidenceJSON = ruleBasedEvidenceJSON
        route = .summary
        guard !fixtureMode else { return }
        guard let patientId = patient?.id else { return }
        let endedAt = Date()
        let dwsReport = exercise.id == NativeExercise.dynamicWeightShift.id ? latestDWSReport : nil
        let record = NativeSessionRecord(
            id: sessionID ?? UUID().uuidString,
            exerciseId: exercise.id,
            startedAt: Int64(startedAt.timeIntervalSince1970 * 1000),
            endedAt: Int64(endedAt.timeIntervalSince1970 * 1000),
            kind: selectedKind,
            durationSeconds: summary.durationSeconds,
            completedReps: summary.reps,
            completedSets: summary.sets,
            invalidReps: summary.invalidReps,
            cuesPresented: summary.cuesPresented,
            overallScore: summary.overallScore,
            poseScore: summary.poseScore,
            motionScore: summary.motionScore,
            experimentalOnly: summary.experimentalOnly,
            mediaSessionId: mediaSessionID
        )
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                self.latestSessionID = record.id
                try await self.supabaseAuth.saveSession(patientId: patientId, record: record, dwsReport: dwsReport)
                self.persistenceMessage = self.isThai ? "บันทึก session แล้ว · กำลังสรุป AI อัตโนมัติ" : "Session saved · AI review is being created automatically."
                self.sessions = try await self.supabaseAuth.fetchSessions(patientId: patientId)
                self.sessionReviews = (try? await self.supabaseAuth.fetchSessionReviews()) ?? [:]
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do {
                        try await self.api.createAutomaticSessionReview(sessionID: record.id)
                        self.sessionReviews = (try? await self.supabaseAuth.fetchSessionReviews()) ?? self.sessionReviews
                        self.persistenceMessage = self.isThai ? "บันทึก session และ AI review แล้ว" : "Session and AI review saved."
                    } catch {
                        // A review failure never changes the already-saved session.
                        self.persistenceMessage = self.isThai ? "บันทึก session แล้ว · สรุป AI ยังไม่พร้อม" : "Session saved · AI review is not available yet."
                    }
                }
            } catch {
                self.persistenceMessage = self.isThai ? "ยังบันทึก session ไม่ได้: \(error.localizedDescription)" : "Session not saved: \(error.localizedDescription)"
            }
        }
    }

    func loadCloudPlan() async {
        await loadHome()
    }

    func loadHome() async {
        guard patient != nil else { return }
        homeError = nil
        if fixtureMode {
            cloudPlan = NativePlan(patientId: patient?.id, items: [], freqPerDay: 1, daysPerWeek: 7, durationDays: 28, durationWeeks: 4, startDate: nil, notes: nil)
            sessions = []
            sessionReviews = [:]
            return
        }
        do {
            guard let patientId = patient?.id else { return }
            cloudPlan = try await supabaseAuth.fetchPlan(patientId: patientId)
            sessions = (try? await supabaseAuth.fetchSessions(patientId: patientId)) ?? []
            sessionReviews = (try? await supabaseAuth.fetchSessionReviews()) ?? [:]
        } catch {
            homeError = error.localizedDescription
            persistenceMessage = isThai ? "โหลดข้อมูลผู้ป่วยไม่ได้: \(error.localizedDescription)" : "Patient data could not be loaded: \(error.localizedDescription)"
        }
    }

    func loadSessionHistory() async {
        guard let patientId = patient?.id else { return }
        if fixtureMode {
            sessionHistoryError = nil
            return
        }
        isLoadingSessionHistory = true
        sessionHistoryError = nil
        defer { isLoadingSessionHistory = false }
        do {
            sessions = try await supabaseAuth.fetchSessions(patientId: patientId)
            sessionReviews = (try? await supabaseAuth.fetchSessionReviews()) ?? [:]
        } catch is CancellationError {
            return
        } catch {
            sessionHistoryError = error.localizedDescription
        }
    }

    private func persistPatient(_ user: NativeRemoteUser) {
        UserDefaults.standard.set(true, forKey: "native.signedIn")
        UserDefaults.standard.set(user.id, forKey: "native.patientId")
        UserDefaults.standard.set(user.name, forKey: "native.patientName")
        UserDefaults.standard.set(user.email, forKey: "native.patientEmail")
    }

    private func userFacing(_ error: Error) -> String {
        if let authError = error as? NativeSupabaseAuthError {
            switch authError {
            case .patientRoleRequired:
                return isThai ? "บัญชี Therapist ต้องใช้งานผ่านเว็บ PhysioAI Therapist" : "Therapist accounts must use the PhysioAI Therapist website."
            case .missingAuthorizationProfile:
                return isThai ? "บัญชีนี้ยังไม่มีข้อมูลสิทธิ์การใช้งาน" : "This account does not have an authorization profile."
            case .notConfigured:
                return isThai ? "ยังไม่ได้ตั้งค่า Supabase Auth" : "Supabase Auth is not configured."
            case .emailConfirmationRequired:
                return isThai ? "กรุณายืนยันอีเมล แล้วกลับมาเข้าสู่ระบบ" : "Confirm your email, then log in."
            }
        }

        let code: String
        if let apiError = error as? NativeAPIError,
           case let .message(value) = apiError {
            code = value
        } else { code = error.localizedDescription }
        let normalized = code.lowercased()
        if normalized.contains("invalid login credentials") || normalized.contains("email not confirmed") {
            return isThai ? "อีเมลหรือรหัสผ่านไม่ถูกต้อง หรือยังไม่ได้ยืนยันอีเมล" : "Email or password is incorrect, or the email is not confirmed."
        }
        if normalized.contains("user already registered") {
            return isThai ? "อีเมลนี้มีบัญชีอยู่แล้ว" : "An account with this email already exists."
        }
        switch code {
        case "required": return isThai ? "กรอกอีเมลและรหัสผ่านก่อน" : "Enter your email and password first."
        case "invalid": return isThai ? "อีเมลหรือรหัสผ่านไม่ถูกต้อง" : "Email or password is incorrect."
        case "not_patient": return isThai ? "บัญชีนี้ใช้กับแอปผู้ป่วยไม่ได้" : "This account cannot use the Patient app."
        case "exists": return isThai ? "อีเมลนี้มีบัญชีอยู่แล้ว" : "An account with this email already exists."
        case "api_not_configured": return isThai ? "ยังไม่ได้ตั้งค่า API" : "The API is not configured."
        default: return error.localizedDescription
        }
    }

    func backHome() {
        selectedExercise = nil
        route = .home
    }
}
