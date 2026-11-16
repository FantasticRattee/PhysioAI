import SwiftUI
import PhysioAIDynamicWeightShiftSDK

struct DWSPracticeScreen: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var runtime = DWSPoseCameraRuntime()
    @StateObject private var speech = NativeSpeechController()
    @State private var reviewTracker = DWSSessionTracker()
    @State private var spokenCues = 0
    @State private var lastSpokenAt = Date.distantPast
    @State private var lastSpokenByCue: [String: Date] = [:]
    @State private var voiceEnabled = true
    @State private var isShowingPreparation = true
    @State private var startedAt = Date()
    @State private var isFinishing = false
    @State private var mediaSetupTask: Task<Void, Never>?
    @State private var mediaRecorder: NativeSessionVideoRecorder?
    @State private var mediaSessionID: String?
    @State private var didFinalizeMedia = false

    private var exercise: NativeExercise {
        app.selectedExercise ?? .dynamicWeightShift
    }

    private var repetitionsPerSet: Int { max(1, exercise.reps) }
    private var totalSets: Int { max(1, exercise.sets) }
    private var targetRepetitions: Int { repetitionsPerSet * totalSets }

    var body: some View {
        ZStack {
            if isShowingPreparation {
                DWSPreparationScreen(
                    exercise: exercise,
                    isThai: app.isThai,
                    onBack: cancelPractice,
                    onStart: startPractice
                )
                .transition(.opacity)
            } else {
                livePractice
                    .transition(.opacity)
            }
        }
        .preferredColorScheme(isShowingPreparation ? .light : .dark)
        .animation(.easeInOut(duration: 0.20), value: isShowingPreparation)
        .onAppear {
            isShowingPreparation = true
            startedAt = Date()
            isFinishing = false
            didFinalizeMedia = false
        }
        .onChange(of: runtime.decision) { _, decision in
            guard !isShowingPreparation, !isFinishing else { return }
            let event = reviewTracker.observe(decision, now: Date().timeIntervalSinceReferenceDate)
            if let event {
                announce(event)
            }
            if decision.reps >= targetRepetitions { finishCurrentSession() }
        }
        .task(id: isShowingPreparation) {
            guard !isShowingPreparation else { return }
            // Startup guidance follows the same readiness used by the boundary.
            // Stop reminding once the boundary first turns green. Polling also
            // handles a stationary/no-pose snapshot that does not trigger onChange.
            while !Task.isCancelled, !isFinishing {
                if runtime.isRunning {
                    if runtime.safety.isScoreable { return }
                    announce("ขยับให้เห็นร่างกายครบในกรอบ")
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
            }
        }
        .onDisappear { cleanUpIfNeeded() }
    }

    private var livePractice: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            DWSCameraPreview(
                session: runtime.captureSession,
                device: runtime.captureDevice
            )
                .ignoresSafeArea()
                .accessibilityIdentifier("dws.camera")

            DWSSkeletonOverlay(
                landmarks: runtime.landmarks,
                isReady: runtime.safety.isScoreable,
                imageSize: runtime.imageSize
            )
            .ignoresSafeArea()

            DWSBoundaryOverlay(isReady: runtime.safety.isScoreable)
                .padding(.horizontal, 4)
                .padding(.vertical, 8)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.58), .clear, .clear, .black.opacity(0.50)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            practiceOverlay

            if let confirmationStep {
                DWSConfirmationCountdown(step: confirmationStep)
                    .transition(.scale(scale: 0.82).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: confirmationStep)
    }

    private var confirmationStep: Int? {
        guard runtime.isRunning,
              runtime.safety.isScoreable,
              runtime.decision.state == "target_candidate",
              runtime.decision.requiredHoldMs > 0 else {
            return nil
        }
        let totalSteps = max(1, Int(ceil(runtime.decision.requiredHoldMs / 1_000)))
        let elapsedStep = Int(max(0, runtime.decision.holdElapsedMs) / 1_000) + 1
        return min(totalSteps, elapsedStep)
    }

    private var practiceOverlay: some View {
        VStack(spacing: 0) {
            header

            DWSRepSummary(
                repetitions: runtime.decision.reps,
                repetitionsPerSet: repetitionsPerSet,
                totalSets: totalSets,
                angleText: angleText,
                statusText: statusText,
                tone: presentationTone
            )
            .padding(.top, 18)

            Spacer(minLength: 28)

            DWSCoachCard(
                cue: cueText,
                progressPercent: progressPercent,
                tone: presentationTone
            )
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .safeAreaPadding(.top, 8)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: cancelPractice) {
                Image(systemName: "xmark")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(DWSTopButtonStyle())
            .accessibilityLabel("ออกจากการฝึก")
            .accessibilityIdentifier("dws.close")

            VStack(alignment: .leading, spacing: 2) {
                Text("Dynamic Weight Shift")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("ฝึกเลื่อนน้ำหนักขณะนั่ง")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.65)

            Spacer()

            Button {
                voiceEnabled.toggle()
                if !voiceEnabled { speech.stop() }
            } label: {
                Image(systemName: voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(DWSTopButtonStyle())
            .accessibilityLabel(voiceEnabled ? "ปิดเสียงคำแนะนำ" : "เปิดเสียงคำแนะนำ")

            Button {
                runtime.resetRepetitions()
                reviewTracker = DWSSessionTracker()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(DWSTopButtonStyle())
            .accessibilityLabel("รีเซ็ตจำนวนครั้ง")
            .accessibilityIdentifier("dws.reset")

            if runtime.isRunning {
                Button(action: finishCurrentSession) {
                    Image(systemName: "stop.fill")
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(DWSTopButtonStyle())
                .accessibilityLabel("หยุดการฝึก")
                .accessibilityIdentifier("dws.stop")
            }
        }
    }

    private var angleText: String {
        String(
            format: "ตัว %.1f°/%.1f° · ไหล่ %.1f°/%.1f°",
            runtime.decision.trunkShiftDegrees,
            DWSContract.targetShiftDegrees,
            runtime.decision.shoulderTiltDegrees,
            DWSContract.maximumShoulderTiltDegrees
        )
    }

    private var statusText: String {
        let mode: String
        switch DWSContract.appDecisionMode {
        case .aiOnly: mode = "AI-only"
        case .strictAIAndRule: mode = "AI + Rule"
        case .hybrid: mode = "Native"
        }
        guard runtime.isRunning else { return "\(mode) · พร้อมเริ่ม" }
        guard runtime.safety.isScoreable else { return "\(mode) · จัดตำแหน่งกล้อง" }
        let base: String
        switch runtime.decision.state {
        case "rest": base = "\(mode) · พร้อมเริ่ม"
        case "moving_to_target": base = "\(mode) · กำลังติดตาม"
        case "target_candidate": base = "\(mode) · กำลังยืนยัน"
        case "target_reached":
            if runtime.decision.source == "wrong_rule_fallback" {
                base = "AI + Rule · Wrong fallback"
            } else if runtime.decision.source == "strict_ai_rule" {
                base = "AI + Rule · ผ่านตรงกัน"
            } else if runtime.decision.source == "ai_only" {
                base = "AI-only · ผ่าน AI"
            } else if runtime.decision.source == "ai_rule" {
                base = "Native · ผ่าน AI + กฎ"
            } else {
                base = "Native · ผ่านกฎสำรอง"
            }
        case "blocked": base = "\(mode) · จัดตำแหน่งกล้อง"
        default: base = "\(mode) · รอ Rest"
        }
        guard let confidence = runtime.decision.aiSignal?.confidence else { return base }
        return "\(base) · AI \(Int((confidence * 100).rounded()))%"
    }

    private var cueText: String {
        guard runtime.isRunning else {
            return "นั่งให้เห็นหัวไหล่ สะโพก เข่า ข้อเท้า และข้อมือ แล้วกดเริ่ม"
        }
        guard runtime.safety.isScoreable else { return runtime.safety.hint }
        if runtime.decision.shoulderTiltDegrees > DWSContract.maximumShoulderTiltDegrees {
            return "ไหล่เอียงเกิน 7° · รักษาแนวหัวไหล่ให้ตรง"
        }
        switch runtime.decision.state {
        case "rest":
            return "พร้อมแล้ว · ค่อย ๆ เอนลำตัวไปด้านข้าง"
        case "moving_to_target":
            if DWSContract.appDecisionMode == .aiOnly {
                return "AI ยังไม่ยืนยัน Target · ค่อย ๆ เอนลำตัวต่อ"
            }
            if runtime.decision.shoulderTiltDegrees > DWSContract.maximumShoulderTiltDegrees {
                return "รักษาแนวหัวไหล่ให้ตรง แล้วเอนลำตัวต่อ"
            }
            if DWSContract.appDecisionMode == .strictAIAndRule &&
                runtime.decision.trunkShiftDegrees > DWSContract.targetShiftDegrees {
                return "กฎมุมผ่านแล้ว · รอ AI ยืนยัน Target และฟอร์มที่ถูกต้อง"
            }
            return "เอนลำตัวต่อให้ถึง \(String(format: "%.1f", DWSContract.targetShiftDegrees))°"
        case "target_candidate":
            switch DWSContract.appDecisionMode {
            case .aiOnly: return "AI กำลังยืนยัน Target และฟอร์มที่ถูกต้อง"
            case .strictAIAndRule: return "AI และกฎตรงกัน · คงท่าต่อเนื่องให้ครบ 5 วินาที"
            case .hybrid: return "คงตำแหน่งสั้น ๆ ให้ AI และกฎยืนยันพร้อมกัน"
            }
        case "target_reached":
            return "นับแล้ว \(runtime.decision.reps) ครั้ง · ค่อย ๆ กลับมากึ่งกลาง"
        case "blocked":
            return runtime.safety.hint
        default:
            return "นั่งตัวตรงให้นิ่งที่กึ่งกลางก่อนเริ่ม"
        }
    }

    private var progressPercent: Int {
        if runtime.decision.state == "target_reached" { return 100 }
        let progress = runtime.decision.trunkShiftDegrees / DWSContract.targetShiftDegrees
        return Int((min(1, max(0, progress)) * 100).rounded())
    }

    private var presentationTone: Color {
        guard runtime.isRunning, runtime.safety.isScoreable else { return DWSPalette.warning }
        switch runtime.decision.state {
        case "rest", "target_reached": return DWSPalette.brand
        case "moving_to_target":
            return runtime.decision.shoulderTiltDegrees > DWSContract.maximumShoulderTiltDegrees
                ? DWSPalette.danger
                : DWSPalette.brand
        case "target_candidate": return DWSPalette.warning
        default: return DWSPalette.warning
        }
    }

    private func startPractice() {
        guard !runtime.isRunning, !isFinishing else { return }
        app.latestDWSReport = nil
        app.latestSessionID = nil
        app.persistenceMessage = nil
        startedAt = Date()
        reviewTracker = DWSSessionTracker()
        spokenCues = 0
        lastSpokenAt = .distantPast
        lastSpokenByCue = [:]
        announce("ขยับให้เห็นร่างกายครบในกรอบ")
        runtime.resetRepetitions()
        runtime.start()
        beginSessionMediaRecording()
        isShowingPreparation = false
    }

    private func cancelPractice() {
        guard !isFinishing else { return }
        runtime.stop()
        mediaSetupTask?.cancel()
        mediaSetupTask = nil
        runtime.setSampleBufferHandler(nil)
        mediaRecorder?.cancelAndDelete()
        mediaRecorder = nil
        mediaSessionID = nil
        didFinalizeMedia = true
        app.backHome()
    }

    private func finishCurrentSession() {
        guard !isFinishing else { return }
        reviewTracker.finish()
        app.latestDWSReport = reviewTracker.report(target: targetRepetitions)
        isFinishing = true
        let completedRepetitions = min(runtime.decision.reps, targetRepetitions)
        runtime.stop()
        didFinalizeMedia = true
        mediaSetupTask?.cancel()
        mediaSetupTask = nil
        runtime.setSampleBufferHandler(nil)

#if targetEnvironment(simulator)
        app.finishPractice(
            cuesPresented: spokenCues,
            startedAt: startedAt,
            completedReps: completedRepetitions
        )
#else
        guard let recorder = mediaRecorder, let pendingMediaSessionID = mediaSessionID else {
            app.finishPractice(
                cuesPresented: spokenCues,
                startedAt: startedAt,
                completedReps: completedRepetitions
            )
            return
        }
        mediaRecorder = nil
        mediaSessionID = nil
        recorder.finish { result in
            let linkedMediaSessionID: String?
            if case .success(let capture?) = result, !capture.segments.isEmpty {
                NativeSessionMediaUploader.shared.enqueue(capture)
                linkedMediaSessionID = pendingMediaSessionID
            } else {
                linkedMediaSessionID = nil
            }
            app.finishPractice(
                cuesPresented: spokenCues,
                startedAt: startedAt,
                completedReps: completedRepetitions,
                sessionID: linkedMediaSessionID,
                mediaSessionID: linkedMediaSessionID
            )
        }
#endif
    }

    private func beginSessionMediaRecording() {
#if !targetEnvironment(simulator)
        guard !app.fixtureMode else { return }
        let nextMediaSessionID = UUID().uuidString.lowercased()
        mediaSetupTask?.cancel()
        mediaSetupTask = Task { @MainActor in
            do {
                try await NativeSessionMediaAPIClient().start(
                    mediaSessionID: nextMediaSessionID,
                    exerciseID: exercise.id
                )
                guard !Task.isCancelled, !didFinalizeMedia else { return }
                let recorder = NativeSessionVideoRecorder()
                try recorder.start(mediaSessionID: nextMediaSessionID)
                mediaRecorder = recorder
                mediaSessionID = nextMediaSessionID
                runtime.setSampleBufferHandler { sampleBuffer in
                    recorder.append(sampleBuffer)
                }
            } catch is CancellationError {
                return
            } catch {
#if DEBUG
                print("[PhysioAI DWS Media] Recording unavailable: \(error.localizedDescription)")
#endif
            }
        }
#endif
    }

    private func cleanUpIfNeeded() {
        speech.stop()
        runtime.stop()
        mediaSetupTask?.cancel()
        mediaSetupTask = nil
        runtime.setSampleBufferHandler(nil)
        if !didFinalizeMedia { mediaRecorder?.cancelAndDelete() }
        mediaRecorder = nil
        mediaSessionID = nil
    }

    private func announce(_ text: String) {
        let now = Date()
        // Skip stale cues instead of queuing them or interrupting current speech.
        guard voiceEnabled,
              speech.state != "started", speech.state != "queued",
              now.timeIntervalSince(lastSpokenAt) >= 8,
              now.timeIntervalSince(lastSpokenByCue[text] ?? .distantPast) >= 20 else { return }
        if speech.speak(text, language: "th-TH") {
            spokenCues += 1
            lastSpokenAt = now
            lastSpokenByCue[text] = now
        }
    }
}

/// Host-side observations only: never changes SDK rep decisions or thresholds.
struct DWSSessionReport: Codable, Equatable {
    var schema = "physioai.dws-session.v1"
    var completedReps = 0
    var correctReps = 0
    var ruleFallbackReps = 0
    var incompleteHolds = 0
    var shoulderTiltEpisodes = 0
    var trackingInterruptions = 0
    var interruptedAtStop = 0
    var targetReps = 1
    var requiredHoldSeconds = 5.0
    var minimumIncompleteHoldSeconds = 2.0
    var maximumShoulderTiltDegrees = 7.0
    var completionScore: Int { min(100, Int((Double(completedReps) / Double(max(1, targetReps)) * 100).rounded())) }
}

struct DWSSessionTracker {
    private var result = DWSSessionReport()
    private var holding = false
    private var heldMs = 0.0
    private var requiredHoldMs = DWSContract.targetHoldMs
    private var previousReps = 0
    private var tiltStartedAt: Double?
    private var tiltCounted = false
    private var trackingLost = false

    mutating func observe(_ d: DWSDecisionSnapshot, now: Double) -> String? {
        // Completion always comes directly from the existing SDK counter.
        result.completedReps = d.reps
        guard d.isScoreable else {
            if holding && !trackingLost { result.trackingInterruptions += 1 }
            holding = false
            heldMs = 0
            trackingLost = true
            tiltStartedAt = nil
            tiltCounted = false
            return nil
        }
        trackingLost = false
        if d.reps > previousReps {
            let added = d.reps - previousReps
            if d.source == "wrong_rule_fallback" { result.ruleFallbackReps += added }
            else { result.correctReps += added }
            previousReps = d.reps
            holding = false
            heldMs = 0
            return "นับแล้ว กลับท่าพัก"
        }
        if d.shoulderTiltDegrees > DWSContract.maximumShoulderTiltDegrees {
            if tiltStartedAt == nil { tiltStartedAt = now }
            if !tiltCounted, now - (tiltStartedAt ?? now) >= 0.5 {
                tiltCounted = true
                result.shoulderTiltEpisodes += 1
                _ = endIncompleteHold()
                return "เอียงเกินไป"
            }
        } else if d.shoulderTiltDegrees <= DWSContract.maximumShoulderTiltDegrees - 1 {
            tiltStartedAt = nil
            tiltCounted = false
        }
        if d.state == "target_candidate" {
            let entering = !holding
            holding = true
            heldMs = d.holdElapsedMs
            requiredHoldMs = d.requiredHoldMs > 0 ? d.requiredHoldMs : DWSContract.targetHoldMs
            return entering ? "ค้างไว้ห้าวินาที" : nil
        }
        if holding {
            return endIncompleteHold() ? "ค้างยังไม่ครบ ลองใหม่" : nil
        }
        return nil
    }

    @discardableResult
    private mutating func endIncompleteHold() -> Bool {
        let qualifies = holding && heldMs > 2_000 && heldMs < requiredHoldMs
        holding = false
        heldMs = 0
        if qualifies { result.incompleteHolds += 1 }
        return qualifies
    }

    mutating func finish() {
        if holding { result.interruptedAtStop += 1; holding = false }
    }

    func report(target: Int) -> DWSSessionReport {
        var report = result
        report.targetReps = max(1, target)
        return report
    }
}

struct DWSSessionScoreboard: View {
    @EnvironmentObject private var app: NativeAppModel
    let report: DWSSessionReport

    private var review: NativeAIReviewContent? {
        guard let id = app.latestSessionID, app.sessionReviews[id]?.aiStatus == "ready" else { return nil }
        return app.sessionReviews[id]?.aiReview
    }

    var body: some View {
        NativePageBackground {
            VStack(alignment: .leading, spacing: 20) {
                NativeBackButton(title: "แผนฝึก") { app.backHome() }
                Text("สรุปการฝึก DWS")
                    .font(.system(size: 30, weight: .heavy))
                HStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(NativeTheme.line, lineWidth: 10)
                        Circle().trim(from: 0, to: Double(report.completionScore) / 100)
                            .stroke(NativeTheme.mint, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(report.completionScore)%").font(.system(size: 29, weight: .heavy))
                    }.frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("สำเร็จตามเป้าหมาย").font(.headline)
                        Text("\(report.completedReps) / \(report.targetReps) ครั้ง").font(.title2.bold())
                        Text("ความครบของจำนวนฝึก ไม่ใช่คะแนนคุณภาพท่า")
                            .font(.caption).foregroundStyle(NativeTheme.muted)
                    }
                }.padding(.vertical, 8)
                VStack(spacing: 0) {
                    metric(report.completedReps >= report.targetReps ? "ทำครบตามเป้าหมาย" : "จำนวนครั้งที่ทำได้", report.completedReps, "checkmark.circle.fill", NativeTheme.forest)
                    metric("ค้างไม่ครบ 5 วินาที", report.incompleteHolds, "timer", .orange)
                    metric("ไหล่เอียงเกิน 7°", report.shoulderTiltEpisodes, "figure.seated.side", .orange)
                }
                .padding(.horizontal, 16)
                .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 22))
                Text("เหตุการณ์ค้างไม่ครบและไหล่เอียงอาจเกิดในรอบเดียวกัน จึงไม่นำมาบวกเป็นจำนวนท่าผิด")
                    .font(.caption).foregroundStyle(NativeTheme.muted)
                if report.trackingInterruptions + report.interruptedAtStop > 0 {
                    Text("กล้องติดตามขาดช่วงระหว่างค้าง \(report.trackingInterruptions) ครั้ง · หยุดก่อนค้างครบ \(report.interruptedAtStop) ครั้ง")
                        .font(.caption).foregroundStyle(NativeTheme.muted)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Label("AI comment", systemImage: "sparkles").font(.title3.bold())
                    if let review {
                        Text(review.summary).font(.body.weight(.semibold))
                        ForEach(Array(review.observations.enumerated()), id: \.offset) { _, text in Text("• \(text)") }
                        Text("โฟกัสครั้งถัดไป").font(.headline)
                        ForEach(Array(review.focusNextSession.enumerated()), id: \.offset) { _, text in Text("• \(text)") }
                    } else {
                        Text(app.persistenceMessage ?? "กำลังบันทึกผลและเตรียม AI comment…")
                        Button("โหลดความคิดเห็นใหม่") {
                            Task { await app.loadSessionHistory() }
                        }
                        .disabled(app.isLoadingSessionHistory)
                    }
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(NativeTheme.brandSoft, in: RoundedRectangle(cornerRadius: 22))
                Button("ดูประวัติและความคิดเห็นนักกายภาพ") { app.openSessionHistory() }
                    .buttonStyle(NativeSecondaryButtonStyle())
                Button("กลับแผนฝึก") { app.backHome() }
                    .buttonStyle(NativePrimaryButtonStyle())
            }
            .foregroundStyle(NativeTheme.ink)
            .frame(maxWidth: 620)
        }
        .preferredColorScheme(.light)
    }

    private func metric(_ title: String, _ count: Int, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 30)
            Text(title).font(.system(size: 16, weight: .semibold))
            Spacer()
            Text("\(count)").font(.system(size: 28, weight: .heavy)).monospacedDigit()
        }.padding(.vertical, 15)
    }
}

private struct DWSPreparationScreen: View {
    @State private var showingExampleVideo = false
    let exercise: NativeExercise
    let isThai: Bool
    let onBack: () -> Void
    let onStart: () -> Void

    var body: some View {
        ZStack {
            NativeTheme.cream.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    NativeBackButton(
                        title: isThai ? "แผนฝึก" : "My plan",
                        action: onBack,
                        fillsWidth: true
                    )
                    .accessibilityIdentifier("dws.preparation.back")

                    VStack(spacing: 8) {
                        Text(isThai ? exercise.titleThai : exercise.title)
                            .font(.system(size: 35, weight: .heavy, design: .rounded))
                            .foregroundStyle(NativeTheme.forest)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.72)

                        Text(isThai
                             ? "Production AI · ผลจะถูกบันทึกในแผนการรักษา"
                             : "Production AI · Results are saved to your care plan")
                            .font(.system(size: 16, weight: .medium, design: .rounded))
                            .foregroundStyle(NativeTheme.muted)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 26)

                    preparationCard
                    doseCard
                        .padding(.top, 16)
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
            Button {
                showingExampleVideo = true
            } label: {
                Label(isThai ? "ดูวิดีโอตัวอย่าง" : "Watch example video", systemImage: "play.circle")
                    .font(.system(size: 17, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NativeTheme.forest)
            .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(NativeTheme.line, lineWidth: 1))
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .accessibilityIdentifier("dws.exampleVideo")
            Button(action: onStart) {
                Label(
                    isThai ? "เปิดกล้องและเริ่มฝึก" : "Open camera and start",
                    systemImage: "camera.fill"
                )
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 60)
            }
            .buttonStyle(.plain)
            .foregroundStyle(NativeTheme.inverse)
            .background(NativeTheme.forest, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 10)
            .background(NativeTheme.cream)
            .accessibilityIdentifier("dws.start")
            }
            .background(NativeTheme.cream)
        }
        .sheet(isPresented: $showingExampleVideo) {
            NativeBottleExampleVideo(isThai: isThai, resourceName: "dws-example", titleThai: "ตัวอย่างท่า DWS", titleEnglish: "DWS example")
        }
        .accessibilityIdentifier("dws.preparation")
    }

    private var preparationCard: some View {
        VStack(spacing: 0) {
            DWSPreparationIllustration()
                .frame(height: 230)
                .frame(maxWidth: .infinity)
                .background(NativeTheme.surface2)

            VStack(alignment: .leading, spacing: 17) {
                checklistRow(
                    isThai
                        ? "หันหน้าเข้ากล้องและถอยให้เห็นไหล่ สะโพก เข่า ข้อเท้า และข้อมือครบ"
                        : "Face the camera and step back until your shoulders, hips, knees, ankles, and wrists are visible"
                )
                checklistRow(
                    isThai
                        ? "ใช้เก้าอี้ที่มั่นคง และจัดพื้นที่รอบตัวให้โล่งและปลอดภัย"
                        : "Use a stable chair and clear the area around you"
                )
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NativeTheme.paper)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(NativeTheme.line, lineWidth: 1)
        }
    }

    private func checklistRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "checkmark")
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(NativeTheme.mint, in: Circle())

            Text(text)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(NativeTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var doseCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(NativeTheme.mint)
                .frame(width: 32)

            Text(isThai ? "จำนวน" : "Dose")
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(NativeTheme.muted)

            Spacer()

            Text(isThai
                 ? "\(exercise.reps) ครั้ง · \(exercise.sets) เซ็ต"
                 : "\(exercise.reps) reps · \(exercise.sets) sets")
                .font(.system(size: 19, weight: .heavy, design: .rounded))
                .foregroundStyle(NativeTheme.ink)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 72)
        .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(NativeTheme.line, lineWidth: 1)
        }
    }
}

private struct DWSPreparationIllustration: View {
    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / 350, proxy.size.height / 230)
            let originX = (proxy.size.width - 350 * scale) / 2
            let originY = (proxy.size.height - 230 * scale) / 2

            ZStack {
                Path { path in
                    path.move(to: point(54, 190, scale, originX, originY))
                    path.addLine(to: point(298, 190, scale, originX, originY))

                }
                .stroke(NativeTheme.muted.opacity(0.3), style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))

                // Chair stays behind the seated figure, in a lighter color.
                Path { path in
                    path.move(to: point(92, 105, scale, originX, originY))
                    path.addLine(to: point(92, 191, scale, originX, originY))
                    path.move(to: point(92, 151, scale, originX, originY))
                    path.addLine(to: point(145, 151, scale, originX, originY))
                    path.addLine(to: point(145, 191, scale, originX, originY))
                }
                .stroke(NativeTheme.mint.opacity(0.55), style: StrokeStyle(lineWidth: 4 * scale, lineCap: .round, lineJoin: .round))

                // Two bent legs: hip → knee → ankle → foot, separate from chair legs.
                Path { path in
                    path.move(to: point(130, 84, scale, originX, originY))
                    path.addLine(to: point(130, 144, scale, originX, originY))
                    path.addLine(to: point(174, 148, scale, originX, originY))
                    path.addLine(to: point(174, 188, scale, originX, originY))
                    path.addLine(to: point(186, 188, scale, originX, originY))
                    path.move(to: point(130, 144, scale, originX, originY))
                    path.addLine(to: point(156, 160, scale, originX, originY))
                    path.addLine(to: point(156, 194, scale, originX, originY))
                    path.addLine(to: point(168, 194, scale, originX, originY))
                    path.move(to: point(130, 100, scale, originX, originY))
                    path.addLine(to: point(113, 123, scale, originX, originY))
                    path.addLine(to: point(141, 136, scale, originX, originY))
                    path.move(to: point(130, 100, scale, originX, originY))
                    path.addLine(to: point(153, 119, scale, originX, originY))
                    path.addLine(to: point(170, 136, scale, originX, originY))
                }
                .stroke(NativeTheme.ink.opacity(0.78), style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round, lineJoin: .round))

                Circle()
                    .stroke(NativeTheme.ink.opacity(0.88), lineWidth: 5 * scale)
                    .frame(width: 41 * scale, height: 41 * scale)
                    .position(point(130, 65, scale, originX, originY))

                Path { path in
                    corner(&path, x: 50, y: 36, horizontal: 24, vertical: 24, scale: scale, originX: originX, originY: originY)
                    corner(&path, x: 300, y: 36, horizontal: -24, vertical: 24, scale: scale, originX: originX, originY: originY)
                    corner(&path, x: 50, y: 186, horizontal: 24, vertical: -24, scale: scale, originX: originX, originY: originY)
                    corner(&path, x: 300, y: 186, horizontal: -24, vertical: -24, scale: scale, originX: originX, originY: originY)
                }
                .stroke(NativeTheme.mint, style: StrokeStyle(lineWidth: 6 * scale, lineCap: .round, lineJoin: .round))

                VStack(spacing: 4 * scale) {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 25 * scale, weight: .bold))
                    Text("DWS")
                        .font(.system(size: 13 * scale, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(NativeTheme.forest)
                .position(point(234, 116, scale, originX, originY))
            }
        }
        .accessibilityHidden(true)
    }

    private func point(
        _ x: CGFloat,
        _ y: CGFloat,
        _ scale: CGFloat,
        _ originX: CGFloat,
        _ originY: CGFloat
    ) -> CGPoint {
        CGPoint(x: originX + x * scale, y: originY + y * scale)
    }

    private func corner(
        _ path: inout Path,
        x: CGFloat,
        y: CGFloat,
        horizontal: CGFloat,
        vertical: CGFloat,
        scale: CGFloat,
        originX: CGFloat,
        originY: CGFloat
    ) {
        path.move(to: point(x + horizontal, y, scale, originX, originY))
        path.addLine(to: point(x, y, scale, originX, originY))
        path.addLine(to: point(x, y + vertical, scale, originX, originY))
    }
}

private struct DWSConfirmationCountdown: View {
    let step: Int

    var body: some View {
        VStack(spacing: 4) {
            Text("กำลังนับ")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.82))

            Text("\(step)")
                .font(.system(size: 76, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .contentTransition(.numericText())
        }
        .frame(width: 148, height: 148)
        .background(.black.opacity(0.68), in: Circle())
        .overlay {
            Circle()
                .stroke(DWSPalette.warning.opacity(0.92), lineWidth: 5)
        }
        .shadow(color: .black.opacity(0.40), radius: 22, y: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("กำลังนับ \(step) จาก 5")
        .accessibilityIdentifier("dws.confirmationCountdown")
    }
}

private struct DWSRepSummary: View {
    let repetitions: Int
    let repetitionsPerSet: Int
    let totalSets: Int
    let angleText: String
    let statusText: String
    let tone: Color

    var body: some View {
        VStack(spacing: 13) {
            GeometryReader { proxy in
                let spacing: CGFloat = repetitionsPerSet > 12 ? 4 : 8
                let width = max(
                    3,
                    (proxy.size.width - spacing * CGFloat(repetitionsPerSet - 1)) /
                        CGFloat(repetitionsPerSet)
                )
                HStack(spacing: spacing) {
                    ForEach(0..<repetitionsPerSet, id: \.self) { index in
                        Capsule()
                            .fill(index < repetitionsInCurrentSet
                                ? DWSPalette.complete
                                : .white.opacity(0.68))
                            .frame(width: width, height: 5)
                            .shadow(
                                color: index < repetitionsInCurrentSet
                                    ? DWSPalette.complete.opacity(0.45)
                                    : .clear,
                                radius: 5
                            )
                    }
                }
            }
            .frame(height: 5)

            Text(progressLabel)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
                .shadow(color: .black.opacity(0.35), radius: 5, y: 2)
                .accessibilityIdentifier("dws.repCount")

            HStack(spacing: 10) {
                DWSMotionChip(text: angleText, foreground: DWSPalette.ink)
                DWSMotionChip(text: statusText, foreground: tone)
            }
        }
        .frame(maxWidth: 540)
    }

    private var progressLabel: String {
        let target = repetitionsPerSet * totalSets
        if repetitions >= target {
            return "ครบ \(target) ครั้ง · เซ็ต \(totalSets)/\(totalSets)"
        }
        let currentSet = min(totalSets, repetitions / repetitionsPerSet + 1)
        let repetitionsInSet = repetitions % repetitionsPerSet
        let prefix = repetitions == 0 ? "เริ่มจากกึ่งกลาง · " : ""
        return "\(prefix)เซ็ต \(currentSet)/\(totalSets) · \(repetitionsInSet)/\(repetitionsPerSet) ครั้ง"
    }

    private var repetitionsInCurrentSet: Int {
        let target = repetitionsPerSet * totalSets
        if repetitions >= target { return repetitionsPerSet }
        return repetitions % repetitionsPerSet
    }
}

private struct DWSCoachCard: View {
    let cue: String
    let progressPercent: Int
    let tone: Color

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text("คำแนะนำ")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(DWSPalette.secondaryInk)

                Text(cue)
                    .font(.system(size: 23, weight: .bold, design: .rounded))
                    .foregroundStyle(DWSPalette.ink)
                    .minimumScaleFactor(0.72)
                    .lineLimit(3)
                    .accessibilityIdentifier("dws.motionCue")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            DWSProgressRing(progressPercent: progressPercent, tone: tone)
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: 560, minHeight: 124)
        .background(DWSPalette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(DWSPalette.surfaceBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 12)
        .animation(.easeInOut(duration: 0.18), value: cue)
    }
}

private struct DWSMotionChip: View {
    let text: String
    let foreground: Color

    var body: some View {
        Text(text)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(foreground)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .padding(.horizontal, 13)
            .frame(minHeight: 42)
            .background(DWSPalette.surface, in: Capsule())
            .overlay { Capsule().stroke(DWSPalette.surfaceBorder, lineWidth: 1) }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
    }
}

private struct DWSProgressRing: View {
    let progressPercent: Int
    let tone: Color

    private var safeProgress: Int { min(100, max(0, progressPercent)) }

    var body: some View {
        ZStack {
            Circle().stroke(DWSPalette.line, lineWidth: 8)
            Circle()
                .trim(from: 0, to: Double(safeProgress) / 100)
                .stroke(tone, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(safeProgress)")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(DWSPalette.ink)
                .contentTransition(.numericText())
        }
        .frame(width: 72, height: 72)
        .accessibilityIdentifier("dws.motionProgress")
    }
}

private struct DWSTopButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .background(.black.opacity(configuration.isPressed ? 0.72 : 0.46), in: Circle())
            .overlay { Circle().stroke(.white.opacity(0.22), lineWidth: 1) }
    }
}

private enum DWSPalette {
    static let surface = Color.white
    static let surfaceBorder = Color.black.opacity(0.10)
    static let brand = Color(red: 0.18, green: 0.43, blue: 0.34)
    static let complete = Color(red: 0.34, green: 0.83, blue: 0.61)
    static let warning = Color(red: 0.61, green: 0.35, blue: 0.20)
    static let danger = Color(red: 0.55, green: 0.31, blue: 0.25)
    static let ink = Color(red: 0.12, green: 0.16, blue: 0.13)
    static let secondaryInk = ink.opacity(0.58)
    static let line = Color(red: 0.90, green: 0.88, blue: 0.83)
}
