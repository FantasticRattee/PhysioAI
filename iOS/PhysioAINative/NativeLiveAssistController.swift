import Combine
import Foundation

@MainActor
final class NativeLiveAssistController: ObservableObject {
    @Published private(set) var activeEvent: NativeLiveAssistEvent?
    @Published private(set) var errorMessage: String?

    private let api = NativeAPIClient()
    private var pollTask: Task<Void, Never>?
    private var cursor: String?
    private var exerciseId = ""
    private var language = "th"

    func start(exerciseID: String, language: String, enabled: Bool) {
        stop()
        guard enabled else { return }
        self.exerciseId = exerciseID
        self.language = language
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        activeEvent = nil
        cursor = nil
    }

    func setLanguage(_ value: String) {
        language = value
    }

    private func pollOnce() async {
        do {
            let batch = try await api.fetchLiveAssist(after: cursor, exerciseId: exerciseId)
            cursor = batch.cursor ?? cursor
            for event in batch.items {
                guard event.exerciseId == nil || event.exerciseId == exerciseId else { continue }
                guard !isExpired(event) else { continue }
                activeEvent = event
                try? await api.acknowledgeLiveAssist(id: event.id)
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func isExpired(_ event: NativeLiveAssistEvent) -> Bool {
        guard let expiresAt = event.expiresAt, expiresAt > 0 else { return false }
        return expiresAt <= Int64(Date().timeIntervalSince1970 * 1000)
    }
}
