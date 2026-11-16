import Foundation

/// Presentation-only priority for spoken guidance. It does not alter model,
/// counter, Capture-QC, or visible-comment decisions.
enum NativeSpeechRequestPriority: Int, Comparable, Equatable {
    case form = 0
    case lifecycle = 1
    case setup = 2
    case system = 3

    static func < (lhs: NativeSpeechRequestPriority, rhs: NativeSpeechRequestPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Controls whether a semantic cue may speak again while it remains visibly
/// active. Form feedback is one calm instruction per fault episode; blocking
/// setup may offer an occasional reminder when the patient is still unable to
/// proceed.
enum NativeSpeechRepeatPolicy: Equatable {
    case oncePerEpisode
    case reminder(after: TimeInterval)
}

/// A semantic speech request from one native presentation producer. The key is
/// deliberately stable across camera frames so identical observations do not
/// become a new utterance just because their timestamp changed.
struct NativeSpeechRequest: Equatable {
    let semanticKey: String
    let text: String
    let language: String
    let priority: NativeSpeechRequestPriority
    let observedAt: TimeInterval
    let repeatPolicy: NativeSpeechRepeatPolicy

    init(
        semanticKey: String,
        text: String,
        language: String,
        priority: NativeSpeechRequestPriority,
        observedAt: TimeInterval,
        repeatPolicy: NativeSpeechRepeatPolicy = .oncePerEpisode,
    ) {
        self.semanticKey = semanticKey
        self.text = text
        self.language = language
        self.priority = priority
        self.observedAt = observedAt
        self.repeatPolicy = repeatPolicy
    }
}

/// Pure decision output. `NativeSpeechController` is the only AVFoundation
/// adapter allowed to enact `.speakNow`; callers never touch its queue directly.
enum NativeSpeechCommentCoordinatorDecision: Equatable {
    case speakNow(NativeSpeechRequest)
    case queueLatest(NativeSpeechRequest)
    case suppress
    case none
}

/// One-active/one-pending speech arbiter for the native practice UI.
///
/// Visual UI may react to every frame, but voice is intentionally slower.
/// Ordinary requests never interrupt an active phrase. A newer request replaces
/// only the pending request, preventing unbounded queued/repeated speech.
struct NativeSpeechCommentCoordinator {
    static let maximumPendingAge: TimeInterval = 3
    static let episodeClearInterval: TimeInterval = 2

    private struct Episode: Equatable {
        var lastVisibleAt: TimeInterval
        var lastSpokenAt: TimeInterval?
    }

    private var active: NativeSpeechRequest?
    private var pending: NativeSpeechRequest?
    private var episodes: [String: Episode] = [:]

    /// Called from the frame-driven presentation layer. A cue must stay absent
    /// for a short interval before its episode is re-armed, so a one-frame
    /// detector flicker cannot make the same sentence speak again.
    mutating func observeVisibleKeys(_ keys: Set<String>, now: TimeInterval) {
        // Setup copy is live presentation guidance. Unlike an active utterance,
        // a queued setup phrase has not reached the patient yet and must not
        // outlive the card it was created for.
        if let pending,
           pending.priority == .setup,
           pending.semanticKey.hasPrefix("setup:"),
           !keys.contains(pending.semanticKey) {
            self.pending = nil
        }

        for key in keys {
            if var episode = episodes[key] {
                episode.lastVisibleAt = now
                episodes[key] = episode
            } else {
                episodes[key] = Episode(lastVisibleAt: now, lastSpokenAt: nil)
            }
        }

        let cleared = episodes.compactMap { key, episode in
            keys.contains(key) || now - episode.lastVisibleAt < Self.episodeClearInterval
                ? nil
                : key
        }
        for key in cleared {
            episodes.removeValue(forKey: key)
            if pending?.semanticKey == key {
                pending = nil
            }
        }
    }

    mutating func submit(
        _ request: NativeSpeechRequest,
        now: TimeInterval,
        isSpeaking: Bool,
    ) -> NativeSpeechCommentCoordinatorDecision {
        guard isUsable(request) else { return .suppress }
        guard !isSuppressedByEpisode(request, now: now) else { return .suppress }

        if !isSpeaking, active == nil {
            return begin(request, at: now)
        }

        if active?.semanticKey == request.semanticKey || pending?.semanticKey == request.semanticKey {
            return .suppress
        }

        // Form instructions are useful only for the live fault that produced
        // them. Do not make a patient hear an out-of-date correction after a
        // lifecycle/setup phrase finishes; the visual cue remains available.
        if request.priority == .form {
            return .suppress
        }

        if let pending, pending.priority > request.priority {
            return .suppress
        }

        self.pending = request
        return .queueLatest(request)
    }

    mutating func didFinish(now: TimeInterval) -> NativeSpeechCommentCoordinatorDecision {
        active = nil
        guard let pending else { return .none }
        self.pending = nil
        guard now - pending.observedAt <= Self.maximumPendingAge,
              !isSuppressedByEpisode(pending, now: now) else {
            return .none
        }
        return begin(pending, at: now)
    }

    /// Audio-session/voice startup can fail after a request has won
    /// arbitration. Release it so a later valid request is not trapped behind
    /// a phrase that was never actually started.
    mutating func didNotStart() {
        active = nil
    }

    mutating func reset() {
        active = nil
        pending = nil
        episodes.removeAll(keepingCapacity: true)
    }

    private mutating func begin(
        _ request: NativeSpeechRequest,
        at now: TimeInterval,
    ) -> NativeSpeechCommentCoordinatorDecision {
        active = request
        var episode = episodes[request.semanticKey]
            ?? Episode(lastVisibleAt: request.observedAt, lastSpokenAt: nil)
        episode.lastSpokenAt = now
        episodes[request.semanticKey] = episode
        return .speakNow(request)
    }

    private func isUsable(_ request: NativeSpeechRequest) -> Bool {
        !request.semanticKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !request.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func isSuppressedByEpisode(
        _ request: NativeSpeechRequest,
        now: TimeInterval,
    ) -> Bool {
        guard let lastSpokenAt = episodes[request.semanticKey]?.lastSpokenAt else {
            return false
        }
        switch request.repeatPolicy {
        case .oncePerEpisode:
            return true
        case let .reminder(after: interval):
            return now - lastSpokenAt < max(0, interval)
        }
    }
}
