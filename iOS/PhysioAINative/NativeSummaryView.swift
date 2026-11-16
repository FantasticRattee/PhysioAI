import SwiftUI

/// Post-session renderer for the V8.0.13 experimental rule score. Missing or
/// insufficient evidence stays unavailable instead of becoming a false zero.
struct NativeSummaryView: View {
    @EnvironmentObject private var app: NativeAppModel
    @State private var shareItem: NativeEvidenceShareItem?
    @State private var evidenceMessage: String?

    private var summary: NativeSessionSummary? { app.latestSummary }
    private var ruleScore: NativeRuleBasedSessionScoreV13? { summary?.ruleBasedScore }
    private var overall: Int? { summary?.overallScore }

    var body: some View {
        NativePageBackground(horizontalPadding: 0, verticalPadding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                NativeBackButton(title: app.isThai ? "ย้อนกลับ" : "Back") { app.backHome() }
                    .padding(.bottom, 8)

                HStack(alignment: .center, spacing: 18) {
                    NativeScoreRing(value: overall, size: 118, color: scoreColor(overall))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(app.isThai ? "จบเซสชันแล้ว เยี่ยมมาก" : "Session complete — well done")
                            .font(.system(size: 24, weight: .heavy))
                            .kerning(-0.4)
                            .foregroundColor(NativeTheme.ink)
                        Text(app.isThai ? "คะแนนทดลองจาก Fault Detector" : "Experimental Fault Detector score")
                            .font(.system(size: 13.5))
                            .foregroundColor(NativeTheme.ink2)
                            .padding(.top, 4)
                        Text(app.isThai ? "ใช้เปรียบเทียบเฉพาะท่าและชุดกฎเดียวกัน" : "Compare only within the same exercise and rule set")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(NativeTheme.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.bottom, 20)

                HStack(spacing: 10) {
                    metricCard(
                        app.isThai ? "คุณภาพท่าทาง" : "Form Quality",
                        percent(ruleScore?.formQualityScore),
                        tone: ruleScore?.formQualityScore,
                    )
                    metricCard(
                        app.isThai ? "ความสม่ำเสมอ" : "Consistency",
                        percent(ruleScore?.consistencyScore),
                        tone: ruleScore?.consistencyScore,
                    )
                    metricCard(
                        app.isThai ? "ความครบของข้อมูล" : "Evidence Coverage",
                        percent(ruleScore?.evidenceCoverageScore),
                        tone: ruleScore?.evidenceCoverageScore,
                    )
                }

                if let ruleScore, !ruleScore.faultBreakdown.isEmpty {
                    dashboardBand(title: app.isThai ? "จุดที่ตรวจพบ" : "Detected persistent faults") {
                        VStack(spacing: 0) {
                            ForEach(Array(ruleScore.faultBreakdown.prefix(4))) { fault in
                                faultRow(fault)
                            }
                        }
                    }
                }

                dashboardBand(title: app.isThai ? "สิ่งที่ควรโฟกัสครั้งหน้า" : "Focus next time") {
                    HStack(alignment: .top, spacing: 10) {
                        Text("1")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(NativeTheme.forest)
                            .frame(width: 24, height: 24)
                            .background(NativeTheme.brandSoft, in: Circle())
                        Text(focusMessage)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(NativeTheme.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 7)
                }

                HStack(spacing: 22) {
                    stat(summary?.reps ?? 0, app.isThai ? "ครั้ง" : "reps")
                    stat(summary?.invalidReps ?? 0, app.isThai ? "รอบมี Fault" : "flagged")
                    stat(summary?.sets ?? 0, app.isThai ? "เซ็ต" : "sets")
                    stat(durationText, app.isThai ? "เวลา" : "time")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)

                Button {
                    app.openExercise(summary?.exercise ?? .bottleGrab)
                } label: {
                    Text(app.isThai ? "↻  เริ่มฝึก" : "↻  Start practice")
                }
                .buttonStyle(NativePrimaryButtonStyle())

#if DEBUG
                if isEvidenceSummary {
                    Button {
                        exportEvidence()
                    } label: {
                        Label(
                            app.isThai ? "Export Evidence JSON" : "Export Evidence JSON",
                            systemImage: "square.and.arrow.up",
                        )
                    }
                    .buttonStyle(NativeSecondaryButtonStyle())
                    .disabled(!canExportEvidence)

                    Text(evidenceHint)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(NativeTheme.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
#endif

                NativeBackButton(title: app.isThai ? "เสร็จสิ้น" : "Finish") { app.backHome() }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)

                if let message = app.persistenceMessage {
                    NativeStatusMessage(text: message)
                        .padding(.top, 8)
                }
                if let evidenceMessage {
                    NativeStatusMessage(text: evidenceMessage)
                        .padding(.top, 8)
                }
            }
            .padding(20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .sheet(item: $shareItem) { item in
            NativeActivitySheet(items: [item.url])
        }
    }

    private var isEvidenceSummary: Bool {
        switch summary?.exercise.id {
        case NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
             NativeSitToStandV72AIModule.exerciseID:
            return true
        default:
            return false
        }
    }

    private var validatedEvidence: RuleBasedSessionRecord? {
        guard let data = app.latestRuleBasedEvidenceJSON,
              let record = try? NativeEvidenceExport.validate(data),
              record.exerciseID == summary?.exercise.id else {
            return nil
        }
        return record
    }

    private var canExportEvidence: Bool {
        validatedEvidence != nil
    }

    private var evidenceHint: String {
        if canExportEvidence {
            return app.isThai
                ? "ตรวจ JSON แล้ว · เลือก Files หรือ AirDrop เพื่อเก็บไฟล์"
                : "Validated local JSON · choose Files or AirDrop to keep the file"
        }
        return app.isThai
            ? "ต้องจบรอบที่นับได้อย่างน้อย 1 ครั้งก่อน export"
            : "Complete at least one counted repetition before exporting"
    }

    private var durationText: String {
        let seconds = summary?.durationSeconds ?? 0
        if seconds < 60 { return app.isThai ? "\(seconds) วิ" : "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    private var focusMessage: String {
        guard let ruleScore else {
            return app.isThai
                ? "ยังไม่มี Evidence ที่ใช้คำนวณคะแนนได้"
                : "No usable evidence was available for scoring."
        }
        guard ruleScore.availability == .available else {
            return app.isThai
                ? "ครั้งหน้าให้ร่างกายและอวัยวะที่ใช้ฝึกเห็นชัดในกล้อง"
                : "Keep the exercise area clearly visible to the camera next time."
        }
        guard let categoryID = ruleScore.focusCategoryID else {
            return app.isThai
                ? "ไม่พบ Fault ที่เกิดซ้ำในรอบที่ประเมินได้"
                : "No persistent fault was detected in the assessed repetitions."
        }
        switch categoryID {
        case "grip_finger_wrap":
            return app.isThai ? "กำมือรอบขวดให้ชัดขึ้น" : "Wrap your fingers fully around the bottle."
        case "trunk_alignment":
            return app.isThai ? "รักษาลำตัวให้อยู่กึ่งกลาง" : "Keep your trunk centered."
        case "hip_symmetry":
            return app.isThai ? "ลงน้ำหนักสะโพกสองข้างให้สมดุล" : "Keep both hips balanced."
        case "knee_symmetry":
            return app.isThai ? "ให้เข่าสองข้างเคลื่อนไหวสมดุลกัน" : "Move both knees evenly."
        case "foot_placement":
            return app.isThai ? "วางเท้าให้อยู่ใต้ลำตัว" : "Place your feet under your body."
        default:
            return app.isThai ? "ทำท่าช้าลงและรักษาแนวร่างกาย" : "Move slowly and keep your alignment."
        }
    }

    private func exportEvidence() {
        guard let data = app.latestRuleBasedEvidenceJSON else { return }
        do {
            let url = try NativeEvidenceExport.writeTemporaryFile(data)
            evidenceMessage = app.isThai
                ? "เตรียม JSON แล้ว · เลือกตำแหน่งเก็บไฟล์"
                : "Evidence JSON is ready · choose where to save it"
            shareItem = NativeEvidenceShareItem(url: url)
        } catch {
            evidenceMessage = app.isThai
                ? "Export Evidence JSON ไม่สำเร็จ: \(error.localizedDescription)"
                : "Evidence JSON export failed: \(error.localizedDescription)"
        }
    }

    private func percent(_ value: Int?) -> String { value.map { "\($0)%" } ?? "—" }

    private func metricCard(_ label: String, _ value: String, tone: Int?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(NativeTheme.ink2)
            Text(value)
                .font(.system(size: 23, weight: .heavy, design: .rounded))
                .foregroundColor(scoreColor(tone))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, minHeight: 90, alignment: .leading)
        .padding(14)
        .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(NativeTheme.line, lineWidth: 1))
    }

    private func faultRow(_ fault: NativeRuleSessionFaultBreakdown) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(severityColor(fault.strongestSeverity))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(categoryTitle(fault.categoryID))
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(NativeTheme.ink)
                Text(severityTitle(fault.strongestSeverity))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(NativeTheme.ink2)
            }
            Spacer()
            Text(app.isThai ? "\(fault.flaggedRepCount) รอบ" : "\(fault.flaggedRepCount) reps")
                .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                .foregroundColor(NativeTheme.ink)
                .monospacedDigit()
        }
        .padding(.vertical, 8)
    }

    private func categoryTitle(_ categoryID: String) -> String {
        switch categoryID {
        case "grip_finger_wrap": return app.isThai ? "การกำมือรอบขวด" : "Grip / finger wrap"
        case "trunk_alignment": return app.isThai ? "แนวลำตัว" : "Trunk alignment"
        case "hip_symmetry": return app.isThai ? "สมดุลสะโพก" : "Hip symmetry"
        case "knee_symmetry": return app.isThai ? "สมดุลเข่า" : "Knee symmetry"
        case "foot_placement": return app.isThai ? "ตำแหน่งเท้า" : "Foot placement"
        default:
            return categoryID
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private func severityTitle(_ severity: String) -> String {
        switch severity.lowercased() {
        case "high": return app.isThai ? "ระดับสูง" : "High"
        case "low": return app.isThai ? "ระดับต่ำ" : "Low"
        default: return app.isThai ? "ระดับปานกลาง" : "Medium"
        }
    }

    private func severityColor(_ severity: String) -> Color {
        switch severity.lowercased() {
        case "high": return .red
        case "low": return NativeTheme.mint
        default: return .orange
        }
    }

    private func dashboardBand<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .heavy))
                .foregroundColor(NativeTheme.ink)
                .padding(.bottom, 10)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(NativeTheme.line, lineWidth: 1))
        .padding(.top, 14)
    }

    private func stat(_ value: Any, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(String(describing: value))
                .font(.system(size: 20, weight: .heavy, design: .rounded))
                .foregroundColor(NativeTheme.ink)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(NativeTheme.ink2)
        }
        .frame(maxWidth: .infinity)
    }

    private func scoreColor(_ value: Int?) -> Color {
        guard let value else { return NativeTheme.ink3 }
        return value >= 75 ? NativeTheme.forest : value >= 50 ? .orange : .red
    }
}

private struct NativeScoreRing: View {
    let value: Int?
    let size: CGFloat
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(NativeTheme.brandSoft, lineWidth: 10)
            if let value {
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(100, value))) / 100)
                    .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(value.map { "\($0)%" } ?? "—")
                .font(.system(size: 18, weight: .heavy, design: .monospaced))
                .foregroundColor(color)
        }
        .frame(width: size, height: size)
    }
}
