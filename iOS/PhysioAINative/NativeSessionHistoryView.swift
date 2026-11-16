import SwiftUI

struct NativeSessionHistoryView: View {
    @EnvironmentObject private var app: NativeAppModel
    @State private var expandedSessionID: String?

    var body: some View {
        NativePageBackground(horizontalPadding: 20, verticalPadding: 20) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    NativeBackButton(title: app.isThai ? "หน้าหลัก" : "Home") { app.backHome() }
                    Spacer()
                    Button {
                        Task { await app.loadSessionHistory() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(NativeTheme.forest)
                            .frame(width: 44, height: 44)
                            .background(NativeTheme.paper, in: Circle())
                            .overlay(Circle().stroke(NativeTheme.line, lineWidth: 1))
                    }
                    .disabled(app.isLoadingSessionHistory)
                    .accessibilityLabel(app.isThai ? "โหลดประวัติใหม่" : "Refresh session history")
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(app.isThai ? "ประวัติการฝึก" : "Session history")
                        .font(.system(size: 28, weight: .heavy))
                        .foregroundColor(NativeTheme.ink)
                    Text(app.isThai ? "ผลการฝึกที่บันทึกไว้ในบัญชีของคุณ" : "Completed exercise sessions saved to your account")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(NativeTheme.muted)
                }

                if app.isLoadingSessionHistory && app.sessions.isEmpty {
                    ProgressView()
                        .tint(NativeTheme.forest)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 70)
                } else if let error = app.sessionHistoryError, app.sessions.isEmpty {
                    NativeStatusMessage(text: error, tone: .bad)
                } else if app.sessions.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(app.sessions) { session in
                            sessionRow(session)
                        }
                    }
                }
            }
            .frame(maxWidth: 620)
        }
        .task { await app.loadSessionHistory() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 34, weight: .medium))
                .foregroundColor(NativeTheme.forest)
            Text(app.isThai ? "ยังไม่มีประวัติการฝึก" : "No session history yet")
                .font(.system(size: 17, weight: .heavy))
                .foregroundColor(NativeTheme.ink)
            Text(app.isThai ? "เมื่อฝึกจบ รายการจะปรากฏที่นี่และนักกายภาพที่เชื่อมกับคุณจะดูได้" : "Completed sessions will appear here and be visible to your assigned therapist.")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(NativeTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 60)
        .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(NativeTheme.line, lineWidth: 1))
    }

    private func sessionRow(_ session: NativeSessionRecord) -> some View {
        let exercise = session.exerciseId.flatMap(app.exercise(for:))
        let isExpanded = expandedSessionID == session.id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedSessionID = isExpanded ? nil : session.id
                }
            } label: {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(NativeTheme.forest)
                        .frame(width: 46, height: 46)
                        .background(NativeTheme.mint.opacity(0.22), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 7) {
                        Text(app.isThai ? (exercise?.titleThai ?? session.exerciseId ?? "ท่าฝึก") : (exercise?.title ?? session.exerciseId ?? "Exercise"))
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundColor(NativeTheme.ink)
                        Text(dateText(session.endedAt))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(NativeTheme.muted)
                        HStack(spacing: 12) {
                            stat("\(session.completedReps)", app.isThai ? "ครั้ง" : "reps")
                            stat("\(session.completedSets)", app.isThai ? "เซ็ต" : "sets")
                            stat(durationText(session.durationSeconds), app.isThai ? "เวลา" : "time")
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 10) {
                        if let score = session.overallScore {
                            Text("\(score)%")
                                .font(.system(size: 14, weight: .heavy))
                                .foregroundColor(NativeTheme.forest)
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(NativeTheme.muted)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(app.isThai ? "เปิด Session review" : "Open session review")

            if isExpanded {
                Divider()
                    .overlay(NativeTheme.line)
                    .padding(.vertical, 14)
                sessionReview(session)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(16)
        .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(NativeTheme.line, lineWidth: 1))
    }

    @ViewBuilder
    private func sessionReview(_ session: NativeSessionRecord) -> some View {
        let review = app.sessionReviews[session.id]
        VStack(alignment: .leading, spacing: 16) {
            reviewSection(number: "1", title: "Therapist review") {
                Text(review?.therapistBody ?? (app.isThai ? "นักกายภาพยังไม่ได้เขียน Review สำหรับ Session นี้" : "Your therapist has not reviewed this session yet."))
                    .foregroundColor(review?.therapistBody == nil ? NativeTheme.muted : NativeTheme.ink)
            }

            reviewSection(number: "2", title: "AI review") {
                if let ai = review?.aiReview, review?.aiStatus == "ready" {
                    VStack(alignment: .leading, spacing: 12) {
                        reviewTextGroup(app.isThai ? "สรุป" : "Summary", text: ai.summary)
                        reviewListGroup(app.isThai ? "ข้อสังเกตจากข้อมูล" : "Data observations", items: ai.observations)
                        reviewListGroup(app.isThai ? "โฟกัสครั้งถัดไป" : "Next-session focus", items: ai.focusNextSession)
                        Text(ai.disclaimer)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(NativeTheme.muted)
                    }
                } else {
                    Text(aiReviewStatusText(review?.aiStatus))
                        .foregroundColor(NativeTheme.muted)
                }
            }
        }
    }

    private func reviewSection<Content: View>(number: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(number)
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(width: 24, height: 24)
                    .background(NativeTheme.forest, in: Circle())
                Text(title)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(NativeTheme.ink)
            }
            content()
                .font(.system(size: 12, weight: .medium))
                .lineSpacing(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(NativeTheme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
    }

    private func reviewTextGroup(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).fontWeight(.heavy).foregroundColor(NativeTheme.forest)
            Text(text).foregroundColor(NativeTheme.ink)
        }
    }

    private func reviewListGroup(_ title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).fontWeight(.heavy).foregroundColor(NativeTheme.forest)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .top, spacing: 6) {
                    Text("•").foregroundColor(NativeTheme.forest)
                    Text(item).foregroundColor(NativeTheme.ink)
                }
            }
        }
    }

    private func aiReviewStatusText(_ status: String?) -> String {
        switch status {
        case "processing": return app.isThai ? "AI กำลังสรุป Session นี้" : "AI is reviewing this session."
        case "failed": return app.isThai ? "AI review ยังไม่พร้อม แต่ข้อมูล Session ถูกบันทึกแล้ว" : "AI review is not available, but the session was saved."
        default: return app.isThai ? "ยังไม่มี AI review สำหรับ Session นี้" : "No AI review is available for this session yet."
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(value).fontWeight(.heavy)
            Text(label)
        }
        .font(.system(size: 11))
        .foregroundColor(NativeTheme.ink2)
    }

    private func dateText(_ milliseconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func durationText(_ seconds: Int) -> String {
        let minutes = seconds / 60
        let remainder = seconds % 60
        return minutes > 0 ? "\(minutes):\(String(format: "%02d", remainder))" : "\(remainder)s"
    }
}
