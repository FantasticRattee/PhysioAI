import SwiftUI

@MainActor
final class NativeCommunicationStore: ObservableObject {
    @Published var peer: NativeCommunicationPeer?
    @Published var messages: [NativeCommunicationMessage] = []
    @Published var activeCall: NativeActiveCall?
    @Published var callHistory: [NativeActiveCall] = []
    @Published var errorMessage: String?
    @Published var isSending = false
    @Published var isStartingCall = false

    private let database = NativeSupabaseAuthClient()
    private let calls = NativeCommunicationAPIClient()

    func monitor(patientId: String, fixtureMode: Bool) async {
        if fixtureMode {
            peer = NativeCommunicationPeer(therapistId: "simulator-therapist", name: "นักกายภาพของคุณ")
            messages = []
            return
        }
        while !Task.isCancelled {
            await refresh(patientId: patientId)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
    }

    func refresh(patientId: String) async {
        do {
            let resolvedPeer: NativeCommunicationPeer?
            if let peer {
                resolvedPeer = peer
            } else {
                resolvedPeer = try await database.fetchCommunicationPeer(patientId: patientId)
            }
            peer = resolvedPeer
            if let resolvedPeer {
                messages = try await database.fetchMessages(patientId: patientId, therapistId: resolvedPeer.therapistId)
                activeCall = try? await calls.fetchActiveCall()
                if let history = try? await calls.fetchCallHistory(patientId: patientId) { mergeHistory(history) }
            }
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send(patientId: String, body: String) async -> Bool {
        guard let peer else { return false }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        isSending = true
        defer { isSending = false }
        do {
            let sent = try await database.sendMessage(patientId: patientId, therapistId: peer.therapistId, body: text)
            if !messages.contains(where: { $0.id == sent.id }) { messages.append(sent) }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func mergeHistory(_ incoming: [NativeActiveCall]) {
        let callsById = Dictionary((callHistory + incoming).map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        callHistory = Array(callsById.values.sorted { $0.createdDate > $1.createdDate }.prefix(100))
    }

    func startCall(patientId: String, callId: String? = nil, mediaType: NativeCallMediaType? = nil) async {
        guard !isStartingCall else { return }
        isStartingCall = true
        defer { isStartingCall = false }
        do {
            let session = try await calls.callSession(patientId: patientId, callId: callId, mediaType: mediaType)
            errorMessage = nil
            NativeWebRTCCallPresenter.present(session: session, userId: patientId) {
                self.activeCall = nil
                do {
                    if let call = try await self.calls.updateCall(callId: session.callId, status: "ended") {
                        self.mergeHistory([call])
                    }
                } catch {
                    self.errorMessage = "ปิดไมค์และกล้องแล้ว แต่ส่งการวางสายไม่สำเร็จ กรุณาตรวจสอบอินเทอร์เน็ต"
                }
            }
        } catch let error as NativeAPIError {
            if case .notConfigured = error {
                errorMessage = "ยังไม่ได้ตั้งค่า URL ของ PhysioAI Therapist server สำหรับการโทร"
            } else {
                errorMessage = error.localizedDescription
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct NativeCommunicationView: View {
    @EnvironmentObject private var app: NativeAppModel
    @StateObject private var store = NativeCommunicationStore()
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    // Match the canonical UUID strings returned by the communication API.
    private var patientId: String { app.patient?.id.lowercased() ?? "" }

    private struct TimelineEntry: Identifiable {
        let id: String
        let date: Date
        let message: NativeCommunicationMessage?
        let call: NativeActiveCall?
    }
    private var timeline: [TimelineEntry] {
        (store.messages.map { TimelineEntry(id: "message-\($0.id)", date: $0.createdAt, message: $0, call: nil) }
         + store.callHistory.map { TimelineEntry(id: "call-\($0.id)", date: $0.createdDate, message: nil, call: $0) })
            .sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            therapistHeader
            Divider().overlay(NativeTheme.line)
            messageTimeline
        }
        .background(NativeTheme.paper)
        .safeAreaInset(edge: .bottom) { composer }
        .task(id: patientId) { await store.monitor(patientId: patientId, fixtureMode: app.fixtureMode) }
    }

    private var navigationBar: some View {
        ZStack {
            HStack {
                Button { app.backHome() } label: {
                    Label("กลับหน้าหลัก", systemImage: "chevron.left")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(NativeTheme.forest)
                }
                Spacer()
            }
            Text("นักกายภาพของฉัน")
                .font(.system(size: 20, weight: .heavy))
                .foregroundColor(NativeTheme.ink)
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
        .background(NativeTheme.cream)
    }

    private var therapistHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(NativeTheme.mint.opacity(0.22)).frame(width: 44, height: 44)
                Image(systemName: "person.fill").font(.system(size: 24)).foregroundColor(NativeTheme.forest)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(store.peer?.name ?? "นักกายภาพของคุณ")
                    .font(.system(size: 17, weight: .heavy))
                    .foregroundColor(NativeTheme.ink)
                HStack(spacing: 6) {
                    Circle().fill(NativeTheme.mint).frame(width: 8, height: 8)
                    Text(store.peer == nil ? "รอการเชื่อมต่อ" : "เชื่อมต่อกับคุณแล้ว")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(NativeTheme.muted)
            }
            Spacer()
            callButton(.audio, icon: "phone.fill", label: "โทรด้วยเสียง")
            callButton(.video, icon: "video.fill", label: "วิดีโอคอล")
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 86)
    }

    private func callButton(_ mediaType: NativeCallMediaType, icon: String, label: String) -> some View {
        Button {
            Task { await store.startCall(patientId: patientId, mediaType: mediaType) }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold)).foregroundColor(NativeTheme.forest)
                .frame(width: 44, height: 44)
                .overlay(Circle().stroke(NativeTheme.forest, lineWidth: 1.5))
        }
        .disabled(store.peer == nil || store.isStartingCall || app.fixtureMode)
        .accessibilityLabel(label)
    }

    private var messageTimeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 13) {
                    HStack { line; Text("วันนี้").font(.system(size: 12)).foregroundColor(NativeTheme.muted); line }
                        .padding(.vertical, 7)
                    if let call = store.activeCall, call.initiatedBy != patientId {
                        Button { Task { await store.startCall(patientId: patientId, callId: call.id, mediaType: call.mediaType) } } label: {
                            Label(call.mediaType == .audio ? "สายเสียงจากนักกายภาพ · รับสาย" : "วิดีโอคอลจากนักกายภาพ · รับสาย", systemImage: call.mediaType == .audio ? "phone.fill" : "video.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 16).frame(minHeight: 46)
                                .background(NativeTheme.forest, in: Capsule())
                        }
                        .disabled(store.isStartingCall)
                    }
                    if timeline.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "message").font(.system(size: 28)).foregroundColor(NativeTheme.forest)
                            Text(store.peer == nil ? "ยังไม่มีนักกายภาพที่เชื่อมต่อ" : "เริ่มส่งข้อความถึงนักกายภาพ")
                                .font(.system(size: 15, weight: .bold)).foregroundColor(NativeTheme.ink)
                            Text("ข้อความจะเห็นได้เฉพาะบัญชีที่เชื่อมต่อกัน")
                                .font(.system(size: 12)).foregroundColor(NativeTheme.muted)
                        }.padding(.top, 70)
                    } else {
                        ForEach(timeline) { entry in
                            if let call = entry.call { callHistoryRow(call).id(entry.id) }
                            else if let message = entry.message { messageRow(message).id(entry.id) }
                        }
                    }
                    if let error = store.errorMessage {
                        Text(error).font(.system(size: 12, weight: .medium)).foregroundColor(.red).multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: timeline.last?.id) { id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .bottom) } }
            }
        }
    }

    private var line: some View { Rectangle().fill(NativeTheme.line).frame(height: 1) }

    private func callHistoryRow(_ call: NativeActiveCall) -> some View {
        let own = call.initiatedBy.lowercased() == patientId
        return VStack(alignment: own ? .trailing : .leading, spacing: 4) {
            HStack(spacing: 12) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: call.mediaType == .audio ? "phone.fill" : "video.fill")
                        .font(.system(size: 22)).frame(width: 46, height: 46)
                        .background(own ? .white.opacity(0.18) : NativeTheme.mint.opacity(0.25), in: Circle())
                    Image(systemName: own ? "arrow.up.right" : "arrow.down.left")
                        .font(.system(size: 12, weight: .bold))
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(call.mediaType == .audio ? "โทรเสียง" : "วิดีโอคอล").font(.system(size: 18, weight: .bold))
                    Text(call.historyDetail(own: own)).font(.system(size: 14)).opacity(0.8)
                }
            }
            .foregroundColor(own ? .white : NativeTheme.ink)
            .padding(15).background(own ? NativeTheme.forest : NativeTheme.cream, in: RoundedRectangle(cornerRadius: 18))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(own ? "โทรออก" : "สายเข้า") \(call.mediaType == .audio ? "โทรเสียง" : "วิดีโอคอล") \(call.historyDetail(own: own))")
            Text(call.createdDate.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 10)).foregroundColor(NativeTheme.muted)
        }.frame(maxWidth: .infinity, alignment: own ? .trailing : .leading)
    }

    private func messageRow(_ message: NativeCommunicationMessage) -> some View {
        let own = message.senderId == patientId
        return VStack(alignment: own ? .trailing : .leading, spacing: 4) {
            Text(message.body)
                .font(.system(size: 15))
                .foregroundColor(own ? .white : NativeTheme.ink)
                .padding(.horizontal, 15).padding(.vertical, 11)
                .background(own ? NativeTheme.forest : NativeTheme.cream, in: RoundedRectangle(cornerRadius: 16))
            Text(message.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10)).foregroundColor(NativeTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: own ? .trailing : .leading)
    }

    private var composer: some View {
        VStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 9) {
                TextField("พิมพ์ข้อความ…", text: $draft, axis: .vertical)
                    .focused($composerFocused)
                    .lineLimit(1...4)
                    .font(.system(size: 15))
                    .foregroundColor(NativeTheme.ink)
                    .tint(NativeTheme.forest)
                    .padding(.horizontal, 15).frame(minHeight: 46)
                    .background(NativeTheme.paper, in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(NativeTheme.line, lineWidth: 1))
                    .disabled(store.peer == nil)
                Button {
                    let text = draft
                    Task { if await store.send(patientId: patientId, body: text) { draft = "" } }
                } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 19, weight: .bold)).foregroundColor(.white)
                        .frame(width: 48, height: 48).background(NativeTheme.forest, in: Circle())
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isSending || store.peer == nil)
                .accessibilityLabel("ส่งข้อความ")
            }
            Text("🔒 เฉพาะคุณและนักกายภาพที่เชื่อมต่อกัน")
                .font(.system(size: 10)).foregroundColor(NativeTheme.muted)
        }
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
        .background(NativeTheme.cream)
    }
}
