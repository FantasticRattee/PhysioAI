import Foundation
import Supabase

enum NativeSupabaseAuthError: LocalizedError {
    case notConfigured
    case emailConfirmationRequired
    case missingAuthorizationProfile
    case patientRoleRequired

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase Auth is not configured."
        case .emailConfirmationRequired:
            return "Check your email to confirm the account, then log in."
        case .missingAuthorizationProfile:
            return "This account does not have an authorization profile."
        case .patientRoleRequired:
            return "Therapist accounts must use the PhysioAI Therapist website."
        }
    }
}

private struct NativeSupabaseProfile: Decodable {
    let role: String
    let fullName: String?

    enum CodingKeys: String, CodingKey {
        case role
        case fullName = "full_name"
    }
}

private struct NativeSupabasePlanExercise: Decodable {
    let exerciseId: String
    let reps: Int
    let sets: Int
    let holdSec: Double
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case exerciseId = "exercise_id"
        case reps
        case sets
        case holdSec = "hold_sec"
        case sortOrder = "sort_order"
    }
}

private struct NativeSupabasePlan: Decodable {
    let patientId: String
    let freqPerDay: Int
    let startDate: String
    let durationDays: Int
    let notes: String
    let items: [NativeSupabasePlanExercise]

    enum CodingKeys: String, CodingKey {
        case patientId = "patient_id"
        case freqPerDay = "freq_per_day"
        case startDate = "start_date"
        case durationDays = "duration_days"
        case notes
        case items
    }
}

struct NativeCommunicationPeer: Equatable {
    let therapistId: String
    let name: String
}

struct NativeCommunicationMessage: Decodable, Equatable, Identifiable {
    let id: String
    let patientId: String
    let therapistId: String
    let senderId: String
    let body: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case patientId = "patient_id"
        case therapistId = "therapist_id"
        case senderId = "sender_id"
        case body
        case createdAt = "created_at"
    }
}

private struct NativeCommunicationAssignment: Decodable {
    struct Therapist: Decodable {
        let fullName: String?
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
    let therapistId: String
    let therapist: Therapist?
    enum CodingKeys: String, CodingKey { case therapistId = "therapist_id"; case therapist }
}

private struct NativeCommunicationMessageInsert: Encodable {
    let patientId: String
    let therapistId: String
    let senderId: String
    let body: String
    enum CodingKeys: String, CodingKey {
        case patientId = "patient_id"
        case therapistId = "therapist_id"
        case senderId = "sender_id"
        case body
    }
}

private struct NativeExerciseSessionRow: Decodable {
    let id: String
    let exerciseId: String
    let kind: String
    let startedAt: Date
    let endedAt: Date
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

    enum CodingKeys: String, CodingKey {
        case id, kind
        case exerciseId = "exercise_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case completedReps = "completed_reps"
        case completedSets = "completed_sets"
        case invalidReps = "invalid_reps"
        case cuesPresented = "cues_presented"
        case overallScore = "overall_score"
        case poseScore = "pose_score"
        case motionScore = "motion_score"
        case experimentalOnly = "experimental_only"
        case mediaSessionId = "media_session_id"
    }
}

private struct NativeExerciseSessionInsert: Encodable {
    let dwsMetrics: DWSSessionReport?
    let id: String
    let patientId: String
    let exerciseId: String
    let kind: String
    let startedAt: Date
    let endedAt: Date
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

    enum CodingKeys: String, CodingKey {
        case dwsMetrics = "dws_metrics"
        case id, kind
        case patientId = "patient_id"
        case exerciseId = "exercise_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case completedReps = "completed_reps"
        case completedSets = "completed_sets"
        case invalidReps = "invalid_reps"
        case cuesPresented = "cues_presented"
        case overallScore = "overall_score"
        case poseScore = "pose_score"
        case motionScore = "motion_score"
        case experimentalOnly = "experimental_only"
        case mediaSessionId = "media_session_id"
    }
}

private struct NativeSessionAIReviewRow: Decodable {
    let sessionId: String
    let status: String
    let review: NativeAIReviewContent?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case status, review
    }
}

private struct NativeSessionTherapistReviewRow: Decodable {
    let sessionId: String
    let body: String
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case body
        case updatedAt = "updated_at"
    }
}

struct NativeSupabaseAuthClient {
    private let client: SupabaseClient?

    // Share SDK session storage and refresh coordination with custom HTTP clients.
    private static let sharedClient: SupabaseClient? = {
        guard let url = NativeConfig.supabaseURL,
              let key = NativeConfig.supabasePublishableKey else {
            return nil
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()

    init() {
        client = Self.sharedClient
    }

    static func accessToken(refreshing rejectedToken: String? = nil) async throws -> String {
        guard let client = sharedClient else { throw NativeSupabaseAuthError.notConfigured }
        // `session` refreshes expired credentials; never fall back to a stale copy.
        var session = try await client.auth.session
        if let rejectedToken, session.accessToken == rejectedToken {
            session = try await client.auth.refreshSession()
        }
        return session.accessToken
    }

    func login(email: String, password: String) async throws -> NativeAuthResponse {
        guard let client else { throw NativeSupabaseAuthError.notConfigured }
        let session = try await client.auth.signIn(email: email, password: password)
        return try await makePatientAuthResponse(
            client: client,
            id: session.user.id,
            email: session.user.email ?? email,
            name: displayName(email: session.user.email ?? email),
            accessToken: session.accessToken
        )
    }

    func register(name: String, email: String, password: String) async throws -> NativeAuthResponse? {
        guard let client else { throw NativeSupabaseAuthError.notConfigured }
        let response = try await client.auth.signUp(
            email: email,
            password: password,
            data: ["full_name": .string(name)]
        )
        guard let session = response.session else { return nil }
        return try await makePatientAuthResponse(
            client: client,
            id: response.user.id,
            email: response.user.email ?? email,
            name: name,
            accessToken: session.accessToken
        )
    }

    func restoredSession() async throws -> NativeAuthResponse {
        guard let client else { throw NativeSupabaseAuthError.notConfigured }
        let session = try await client.auth.session
        let email = session.user.email ?? ""
        return try await makePatientAuthResponse(
            client: client,
            id: session.user.id,
            email: email,
            name: displayName(email: email),
            accessToken: session.accessToken
        )
    }

    func fetchPlan(patientId: String) async throws -> NativePlan? {
        guard let client else { throw NativeSupabaseAuthError.notConfigured }
        let rows: [NativeSupabasePlan] = try await client
            .from("patient_plans")
            .select(
                """
                patient_id,
                freq_per_day,
                start_date,
                duration_days,
                notes,
                items:patient_plan_exercises (
                  exercise_id,
                  reps,
                  sets,
                  hold_sec,
                  sort_order
                )
                """
            )
            .eq("patient_id", value: patientId)
            .limit(1)
            .execute()
            .value

        guard let row = rows.first else { return nil }
        let items = row.items
            .sorted { $0.sortOrder < $1.sortOrder }
            .map {
                NativePlanItem(
                    exerciseId: $0.exerciseId,
                    reps: $0.reps,
                    sets: $0.sets,
                    holdSec: $0.holdSec
                )
            }
        return NativePlan(
            patientId: row.patientId,
            items: items,
            freqPerDay: row.freqPerDay,
            daysPerWeek: nil,
            durationDays: row.durationDays,
            durationWeeks: nil,
            startDate: row.startDate,
            notes: row.notes
        )
    }

    func fetchCommunicationPeer(patientId: String) async throws -> NativeCommunicationPeer? {
        guard let client else { throw NativeSupabaseAuthError.notConfigured }
        let rows: [NativeCommunicationAssignment] = try await client
            .from("therapist_patient_assignments")
            .select("therapist_id, therapist:profiles!therapist_patient_assignments_therapist_id_fkey(full_name)")
            .eq("patient_id", value: patientId)
            .limit(1)
            .execute()
            .value
        guard let row = rows.first else { return nil }
        let fallback = "Therapist \(row.therapistId.prefix(8).uppercased())"
        let name = row.therapist?.fullName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return NativeCommunicationPeer(therapistId: row.therapistId, name: name.flatMap { $0.isEmpty ? nil : $0 } ?? fallback)
    }

    func fetchMessages(patientId: String, therapistId: String) async throws -> [NativeCommunicationMessage] {
        guard let client else { throw NativeSupabaseAuthError.notConfigured }
        let rows: [NativeCommunicationMessage] = try await client
            .from("communication_messages")
            .select("id, patient_id, therapist_id, sender_id, body, created_at")
            .eq("patient_id", value: patientId)
            .eq("therapist_id", value: therapistId)
            .order("created_at", ascending: true)
            .limit(500)
            .execute()
            .value
        return rows
    }

    func sendMessage(patientId: String, therapistId: String, body: String) async throws -> NativeCommunicationMessage {
        guard let client else { throw NativeSupabaseAuthError.notConfigured }
        let payload = NativeCommunicationMessageInsert(patientId: patientId, therapistId: therapistId, senderId: patientId, body: body)
        let message: NativeCommunicationMessage = try await client
            .from("communication_messages")
            .insert(payload)
            .select("id, patient_id, therapist_id, sender_id, body, created_at")
            .single()
            .execute()
            .value
        return message
    }

    func fetchSessions(patientId: String) async throws -> [NativeSessionRecord] {
        guard let client else { throw NativeSupabaseAuthError.notConfigured }
        let rows: [NativeExerciseSessionRow] = try await client
            .from("exercise_sessions")
            .select("id, exercise_id, kind, started_at, ended_at, duration_seconds, completed_reps, completed_sets, invalid_reps, cues_presented, overall_score, pose_score, motion_score, experimental_only, media_session_id")
            .eq("patient_id", value: patientId)
            .order("ended_at", ascending: false)
            .limit(500)
            .execute()
            .value
        return rows.map { row in
            NativeSessionRecord(
                id: row.id,
                exerciseId: row.exerciseId,
                startedAt: Int64(row.startedAt.timeIntervalSince1970 * 1000),
                endedAt: Int64(row.endedAt.timeIntervalSince1970 * 1000),
                kind: row.kind,
                durationSeconds: row.durationSeconds,
                completedReps: row.completedReps,
                completedSets: row.completedSets,
                invalidReps: row.invalidReps,
                cuesPresented: row.cuesPresented,
                overallScore: row.overallScore,
                poseScore: row.poseScore,
                motionScore: row.motionScore,
                experimentalOnly: row.experimentalOnly,
                mediaSessionId: row.mediaSessionId
            )
        }
    }

    func saveSession(patientId: String, record: NativeSessionRecord, dwsReport: DWSSessionReport? = nil) async throws {
        guard let client, let exerciseId = record.exerciseId else { throw NativeSupabaseAuthError.notConfigured }
        let payload = NativeExerciseSessionInsert(
            dwsMetrics: dwsReport,
            id: record.id,
            patientId: patientId,
            exerciseId: exerciseId,
            kind: record.kind,
            startedAt: Date(timeIntervalSince1970: Double(record.startedAt) / 1000),
            endedAt: Date(timeIntervalSince1970: Double(record.endedAt) / 1000),
            durationSeconds: record.durationSeconds,
            completedReps: record.completedReps,
            completedSets: record.completedSets,
            invalidReps: record.invalidReps,
            cuesPresented: record.cuesPresented,
            overallScore: record.overallScore,
            poseScore: record.poseScore,
            motionScore: record.motionScore,
            experimentalOnly: record.experimentalOnly,
            mediaSessionId: record.mediaSessionId
        )
        try await client.from("exercise_sessions").insert(payload).execute()
    }

    func fetchSessionReviews() async throws -> [String: NativeSessionReviewSnapshot] {
        guard let client else { throw NativeSupabaseAuthError.notConfigured }
        let aiRows: [NativeSessionAIReviewRow] = try await client
            .from("session_ai_reviews")
            .select("session_id, status, review")
            .execute()
            .value
        let therapistRows: [NativeSessionTherapistReviewRow] = try await client
            .from("session_therapist_reviews")
            .select("session_id, body, updated_at")
            .execute()
            .value

        var reviews: [String: NativeSessionReviewSnapshot] = [:]
        for row in aiRows {
            reviews[row.sessionId] = NativeSessionReviewSnapshot(
                aiStatus: row.status,
                aiReview: row.review,
                therapistBody: nil,
                therapistUpdatedAt: nil
            )
        }
        for row in therapistRows {
            var review = reviews[row.sessionId] ?? NativeSessionReviewSnapshot(
                aiStatus: nil,
                aiReview: nil,
                therapistBody: nil,
                therapistUpdatedAt: nil
            )
            review.therapistBody = row.body
            review.therapistUpdatedAt = row.updatedAt
            reviews[row.sessionId] = review
        }
        return reviews
    }

    func signOut() async {
        try? await client?.auth.signOut()
    }

    private func makePatientAuthResponse(
        client: SupabaseClient,
        id: UUID,
        email: String,
        name: String,
        accessToken: String
    ) async throws -> NativeAuthResponse {
        let profile: NativeSupabaseProfile
        do {
            profile = try await client
                .from("profiles")
                .select("role, full_name")
                .eq("id", value: id.uuidString)
                .single()
                .execute()
                .value
        } catch {
            try? await client.auth.signOut()
            throw NativeSupabaseAuthError.missingAuthorizationProfile
        }

        guard profile.role == "patient" else {
            try? await client.auth.signOut()
            throw NativeSupabaseAuthError.patientRoleRequired
        }

        let profileName = profile.fullName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = profileName.flatMap { $0.isEmpty ? nil : $0 } ?? name
        return NativeAuthResponse(
            token: accessToken,
            user: NativeRemoteUser(
                id: id.uuidString,
                name: resolvedName,
                email: email,
                role: profile.role
            )
        )
    }

    private func displayName(email: String) -> String {
        let localPart = email.split(separator: "@", maxSplits: 1).first.map(String.init) ?? "Patient"
        return localPart.isEmpty ? "Patient" : localPart
    }
}
