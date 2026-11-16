import XCTest
@testable import PhysioAINative

final class NativeSpeechCommentCoordinatorTests: XCTestCase {
    func testRepeatedSemanticCommentSpeaksOnlyOnceDuringCooldown() {
        var coordinator = NativeSpeechCommentCoordinator()
        let comment = request(key: "form:finger-wrap", text: "Wrap your fingers around the bottle.", observedAt: 0)

        XCTAssertEqual(
            coordinator.submit(comment, now: 0, isSpeaking: false),
            .speakNow(comment),
        )
        XCTAssertEqual(coordinator.didFinish(now: 1), .none)
        coordinator.observeVisibleKeys([comment.semanticKey], now: 9)
        XCTAssertEqual(
            coordinator.submit(comment, now: 9, isSpeaking: false),
            .suppress,
        )
    }

    func testFormCueIsDroppedInsteadOfQueuedBehindActiveSpeech() {
        var coordinator = NativeSpeechCommentCoordinator()
        let active = request(
            key: "motion:reach",
            text: "Reach toward the bottle.",
            observedAt: 0,
            priority: .lifecycle,
        )
        let form = request(
            key: "form:shoulder-low",
            text: "Lift your shoulder slightly.",
            observedAt: 0.2,
        )

        XCTAssertEqual(coordinator.submit(active, now: 0, isSpeaking: false), .speakNow(active))
        XCTAssertEqual(coordinator.submit(form, now: 0.2, isSpeaking: true), .suppress)
    }

    func testSetupPolicyDoesNotAutomaticallyRepeatSpecificGuidanceAtFifteenSeconds() {
        XCTAssertFalse(
            NativeSetupSpeechPolicy.shouldSpeak(
                reason: "missing_left_hand",
                speechEnabled: true,
                visualOnly: false,
                lastReason: "missing_left_hand",
                elapsedSinceLastSpeech: 10,
            ),
        )
        XCTAssertFalse(
            NativeSetupSpeechPolicy.shouldSpeak(
                reason: "missing_left_hand",
                speechEnabled: true,
                visualOnly: false,
                lastReason: "missing_left_hand",
                elapsedSinceLastSpeech: 15,
            ),
        )
    }

    func testNoParticipantRawReasonChurnDoesNotCreateANewVoiceEpisode() {
        XCTAssertFalse(
            NativeSetupSpeechPolicy.shouldSpeak(
                reason: "missing_required_pose",
                speechEnabled: true,
                visualOnly: false,
                lastReason: "pose_only_capture_qc_failed",
                elapsedSinceLastSpeech: 5,
            ),
        )
    }

    func testNoParticipantStaysSilentAfterItsSingleReminderWasDelivered() {
        XCTAssertFalse(
            NativeSetupSpeechPolicy.shouldSpeak(
                reason: "missing_required_pose",
                speechEnabled: true,
                visualOnly: false,
                lastReason: "setup:no_participant:reminder_delivered",
                elapsedSinceLastSpeech: 60,
            ),
        )
    }

    func testFormCueRearmsOnlyAfterItHasBeenVisiblyClearForTwoSeconds() {
        var coordinator = NativeSpeechCommentCoordinator()
        let comment = request(key: "form:shoulder-low", text: "Lift your shoulder slightly.", observedAt: 0)

        coordinator.observeVisibleKeys([comment.semanticKey], now: 0)
        XCTAssertEqual(coordinator.submit(comment, now: 0, isSpeaking: false), .speakNow(comment))
        XCTAssertEqual(coordinator.didFinish(now: 1), .none)

        coordinator.observeVisibleKeys([], now: 1.1)
        coordinator.observeVisibleKeys([comment.semanticKey], now: 2.9)
        XCTAssertEqual(coordinator.submit(comment, now: 2.9, isSpeaking: false), .suppress)

        coordinator.observeVisibleKeys([], now: 3)
        coordinator.observeVisibleKeys([], now: 5.1)
        coordinator.observeVisibleKeys([comment.semanticKey], now: 5.2)
        XCTAssertEqual(coordinator.submit(comment, now: 5.2, isSpeaking: false), .speakNow(comment))
    }

    func testSetupCommentDoesNotInterruptActiveSpeechAndKeepsOnePendingRequest() {
        var coordinator = NativeSpeechCommentCoordinator()
        let first = request(key: "motion:open", text: "Open your hand.", observedAt: 0, priority: .lifecycle)
        let second = request(key: "setup:hand", text: "Keep your hand visible.", observedAt: 0.2, priority: .setup)

        XCTAssertEqual(
            coordinator.submit(first, now: 0, isSpeaking: false),
            .speakNow(first),
        )
        XCTAssertEqual(
            coordinator.submit(second, now: 0.2, isSpeaking: true),
            .queueLatest(second),
        )
        XCTAssertEqual(
            coordinator.didFinish(now: 1),
            .speakNow(second),
        )
    }

    func testVisibleGuidanceChangeImmediatelyDropsAStalePendingSetupPhrase() {
        var coordinator = NativeSpeechCommentCoordinator()
        let active = request(
            key: "motion:open",
            text: "Open your hand.",
            observedAt: 0,
            priority: .lifecycle,
        )
        let staleSetup = request(
            key: "setup:left-arm",
            text: "Keep your left shoulder, elbow, wrist, and hand visible.",
            observedAt: 0.2,
            priority: .setup,
        )

        XCTAssertEqual(coordinator.submit(active, now: 0, isSpeaking: false), .speakNow(active))
        XCTAssertEqual(coordinator.submit(staleSetup, now: 0.2, isSpeaking: true), .queueLatest(staleSetup))

        coordinator.observeVisibleKeys(["setup:no_participant"], now: 0.3)

        XCTAssertEqual(coordinator.didFinish(now: 0.4), .none)
    }

    func testRapidOrdinaryUpdatesKeepOnlyTheNewestPendingComment() {
        var coordinator = NativeSpeechCommentCoordinator()
        let active = request(key: "motion:open", text: "Open your hand.", observedAt: 0, priority: .lifecycle)
        let second = request(key: "motion:hold", text: "Hold your position.", observedAt: 0.2, priority: .lifecycle)
        let third = request(key: "motion:release", text: "Release the bottle slowly.", observedAt: 0.4, priority: .lifecycle)

        XCTAssertEqual(coordinator.submit(active, now: 0, isSpeaking: false), .speakNow(active))
        XCTAssertEqual(coordinator.submit(second, now: 0.2, isSpeaking: true), .queueLatest(second))
        XCTAssertEqual(coordinator.submit(third, now: 0.4, isSpeaking: true), .queueLatest(third))
        XCTAssertEqual(coordinator.didFinish(now: 1), .speakNow(third))
    }

    func testHigherPriorityPendingRequestIsNotReplacedByLaterFormComment() {
        var coordinator = NativeSpeechCommentCoordinator()
        let active = request(key: "motion:open", text: "Open your hand.", observedAt: 0, priority: .lifecycle)
        let setup = request(key: "setup:hand", text: "Keep your hand visible.", observedAt: 0.2, priority: .setup)
        let form = request(key: "form:finger-wrap", text: "Wrap your fingers around the bottle.", observedAt: 0.4)

        XCTAssertEqual(coordinator.submit(active, now: 0, isSpeaking: false), .speakNow(active))
        XCTAssertEqual(coordinator.submit(setup, now: 0.2, isSpeaking: true), .queueLatest(setup))
        XCTAssertEqual(coordinator.submit(form, now: 0.4, isSpeaking: true), .suppress)
        XCTAssertEqual(coordinator.didFinish(now: 1), .speakNow(setup))
    }

    func testStalePendingCommentIsDroppedWhenCurrentSpeechFinishes() {
        var coordinator = NativeSpeechCommentCoordinator()
        let active = request(key: "motion:open", text: "Open your hand.", observedAt: 0, priority: .lifecycle)
        let pending = request(key: "setup:hand", text: "Keep your hand visible.", observedAt: 0.2, priority: .setup)

        XCTAssertEqual(coordinator.submit(active, now: 0, isSpeaking: false), .speakNow(active))
        XCTAssertEqual(coordinator.submit(pending, now: 0.2, isSpeaking: true), .queueLatest(pending))
        XCTAssertEqual(coordinator.didFinish(now: 3.3), .none)
    }

    func testResetClearsPendingRequestAndCooldownHistory() {
        var coordinator = NativeSpeechCommentCoordinator()
        let comment = request(key: "form:finger-wrap", text: "Wrap your fingers around the bottle.", observedAt: 0)
        let pending = request(key: "motion:release", text: "Release the bottle slowly.", observedAt: 0.1, priority: .lifecycle)

        XCTAssertEqual(coordinator.submit(comment, now: 0, isSpeaking: false), .speakNow(comment))
        XCTAssertEqual(coordinator.submit(pending, now: 0.1, isSpeaking: true), .queueLatest(pending))
        coordinator.reset()

        XCTAssertEqual(coordinator.didFinish(now: 0.2), .none)
        XCTAssertEqual(coordinator.submit(comment, now: 0.3, isSpeaking: false), .speakNow(comment))
    }

    func testFailedSpeechStartReleasesTheActiveRequest() {
        var coordinator = NativeSpeechCommentCoordinator()
        let first = request(key: "setup:hand", text: "Keep your hand visible.", observedAt: 0, priority: .setup)
        let second = request(key: "motion:open", text: "Open your hand.", observedAt: 0.1, priority: .lifecycle)

        XCTAssertEqual(coordinator.submit(first, now: 0, isSpeaking: false), .speakNow(first))
        coordinator.didNotStart()
        XCTAssertEqual(coordinator.submit(second, now: 0.1, isSpeaking: false), .speakNow(second))
    }

    private func request(
        key: String,
        text: String,
        observedAt: TimeInterval,
        priority: NativeSpeechRequestPriority = .form,
    ) -> NativeSpeechRequest {
        NativeSpeechRequest(
            semanticKey: key,
            text: text,
            language: "en-US",
            priority: priority,
            observedAt: observedAt,
        )
    }
}
