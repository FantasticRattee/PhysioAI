import SwiftUI

struct NativeHomeView: View {
    @EnvironmentObject private var app: NativeAppModel

    private var planItems: [NativePlanItem] { app.planItems }
    private var planIDs: Set<String> { Set(planItems.map(\.exerciseId)) }
    private var extras: [NativeExercise] { app.catalog.filter { !planIDs.contains($0.id) } }
    private var doneCount: Int { planItems.filter { app.doneTodayIDs.contains($0.exerciseId) }.count }

    var body: some View {
        NativePageBackground(horizontalPadding: 20, verticalPadding: 20) {
            VStack(alignment: .leading, spacing: 0) {
                header
                Text(app.isThai ? "สวัสดี, \(app.patient?.name ?? "Patient")" : "Hi, \(app.patient?.name ?? "Patient")")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(NativeTheme.muted)
                    .padding(.top, 4)

                if let error = app.homeError {
                    NativeStatusMessage(text: app.isThai ? "เชื่อมต่อเซิร์ฟเวอร์ไม่สำเร็จ: \(error)" : "Could not reach the server: \(error)", tone: .bad)
                        .padding(.top, 16)
                }

                if !planItems.isEmpty {
                    progressCard
                        .padding(.top, 18)
                }

                sectionTitle(app.isThai ? "แผนของฉัน" : "MY PLAN")
                if planItems.isEmpty {
                    Text(app.isThai ? "ยังไม่มีแผนจากนักกายภาพ" : "No plan from your therapist yet")
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(NativeTheme.muted)
                        .padding(.vertical, 4)
                } else {
                    ForEach(planItems) { item in
                        planRow(item)
                    }
                }

                if !extras.isEmpty {
                    sectionTitle(app.isThai ? "ท่าเสริม" : "EXTRA EXERCISES")
                    Text(app.isThai ? "ทำเสริมได้ · ไม่นับในการรักษา" : "Optional · not part of treatment")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(NativeTheme.muted)
                        .padding(.top, -10)
                    ForEach(extras) { exercise in
                        extraRow(exercise)
                    }
                }

                if let message = app.persistenceMessage {
                    NativeStatusMessage(text: message)
                }
            }
            .frame(maxWidth: 620)
            .task { await app.loadHome() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack {
                Spacer(minLength: 0)
                messageButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    private var header: some View {
        ZStack {
            HStack {
                Spacer(minLength: 0)
                Menu {
                    Button {
                        app.openSessionHistory()
                    } label: {
                        Label(app.isThai ? "ประวัติการฝึก" : "Session history", systemImage: "clock.arrow.circlepath")
                    }
                    Divider()
                    Button(role: .destructive) {
                        app.logout()
                    } label: {
                        Label(app.isThai ? "ออกจากระบบ" : "Log out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    ZStack {
                        Circle().fill(NativeTheme.mint.opacity(0.22))
                        Circle().stroke(NativeTheme.line, lineWidth: 1)
                        Image(systemName: "person.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(NativeTheme.forest)
                    }
                    .frame(width: 44, height: 44)
                }
                .accessibilityLabel(app.isThai ? "เมนูโปรไฟล์" : "Profile menu")
                .accessibilityIdentifier("home-profile-menu")
            }
            HStack(spacing: 0) {
                Text("Physio")
                    .font(.system(size: 22, weight: .heavy))
                    .kerning(-0.7)
                    .foregroundColor(NativeTheme.ink)
                Text("AI")
                    .font(.system(size: 22, weight: .heavy))
                    .kerning(-0.7)
                    .foregroundColor(NativeTheme.forest)
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
        .padding(.bottom, 8)
    }

    private var messageButton: some View {
        Button {
            app.openCommunication()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "message.fill")
                    .font(.system(size: 17, weight: .bold))
                Text(app.isThai ? "ข้อความ" : "Messages")
                    .font(.system(size: 15, weight: .heavy))
            }
            .foregroundColor(NativeTheme.inverse)
            .padding(.horizontal, 19)
            .frame(minHeight: 54)
            .background(NativeTheme.forest, in: Capsule())
            .shadow(color: NativeTheme.forest.opacity(0.24), radius: 12, x: 0, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.isThai ? "เปิดข้อความจากนักกายภาพ" : "Open messages from therapist")
        .accessibilityIdentifier("home-message-button")
    }

    private var progressCard: some View {
        let total = planItems.count
        let progress = total == 0 ? 0 : Double(doneCount) / Double(total)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(app.isThai ? "ความคืบหน้าวันนี้" : "TODAY'S PROGRESS")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(NativeTheme.mint)
                Spacer()
                Text(doneCount >= total
                     ? (app.isThai ? "ครบแล้ววันนี้ 🎉" : "All done for today 🎉")
                     : (app.isThai ? "ทำแล้ว \(doneCount)/\(total) วันนี้" : "\(doneCount)/\(total) done today"))
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundColor(.white.opacity(0.8))
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(NativeTheme.mint).frame(width: proxy.size.width * min(1, max(0, progress)))
                }
            }
            .frame(height: 8)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeTheme.forest, in: RoundedRectangle(cornerRadius: 18))
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.2)
                .foregroundColor(NativeTheme.muted)
            Spacer()
        }
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func planRow(_ item: NativePlanItem) -> some View {
        let exercise = app.exercise(for: item.exerciseId) ?? .bottleGrab
        let done = app.doneTodayIDs.contains(item.exerciseId)
        return Button { app.openPlanItem(item) } label: {
            exerciseRow(exercise: exercise, detail: doseLine(exercise, item: item), icon: done ? "✓" : "◷", iconFill: done ? NativeTheme.mint : NativeTheme.mint.opacity(0.22), iconColor: done ? .white : NativeTheme.forest, trailing: "›")
        }
        .buttonStyle(.plain)
    }

    private func extraRow(_ exercise: NativeExercise) -> some View {
        Button { app.openExercise(exercise) } label: {
            exerciseRow(exercise: exercise, detail: doseLine(exercise, item: nil), icon: "＋", iconFill: NativeTheme.mint.opacity(0.22), iconColor: NativeTheme.forest, trailing: "›")
        }
        .buttonStyle(.plain)
    }

    private func exerciseRow(exercise: NativeExercise, detail: String, icon: String, iconFill: Color, iconColor: Color, trailing: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(iconFill).frame(width: 44, height: 44)
                Text(icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(iconColor)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(app.isThai ? exercise.titleThai : exercise.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(NativeTheme.ink)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundColor(NativeTheme.muted)
            }
            Spacer()
            Text(trailing)
                .font(.system(size: 28, weight: .regular))
                .foregroundColor(NativeTheme.forest)
        }
        .frame(minHeight: 76)
        .padding(16)
        .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(NativeTheme.forest.opacity(0.10), lineWidth: 1))
        .padding(.bottom, 12)
    }

    private func doseLine(_ exercise: NativeExercise, item: NativePlanItem?) -> String {
        let reps = item?.reps ?? exercise.reps
        let sets = item?.sets ?? exercise.sets
        let hold = item?.holdSec ?? exercise.holdSec
        if exercise.type == "hold" {
            return app.isThai ? "\(String(format: "%.0f", hold)) วิ · ค้างไว้ · \(sets) เซ็ต" : "\(String(format: "%.0f", hold))s hold · \(sets) sets"
        }
        return app.isThai ? "\(reps) ครั้ง · \(sets) เซ็ต" : "\(reps) reps · \(sets) sets"
    }

}
