import XCTest
@testable import PhysioAINative

final class NativeSessionMediaAuthTests: XCTestCase {
    func testUnauthorizedRefreshesAndRetriesSameBodyOnce() async throws {
        var requests: [URLRequest] = []
        var rejected: [String?] = []
        let api = NativeSessionMediaAPIClient(
            baseURL: URL(string: "https://example.test"),
            tokenProvider: { token in
                rejected.append(token)
                return token == nil ? "old" : "renewed"
            },
            send: { request in
                requests.append(request)
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: requests.count == 1 ? 401 : 200, httpVersion: nil, headerFields: nil)!)
            }
        )
        _ = try await api.request(path: "/api/session-media/uploads", body: ["index": 0])
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(rejected.count, 2)
        XCTAssertNil(rejected[0])
        XCTAssertEqual(rejected[1], "old")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer renewed")
        XCTAssertEqual(requests[0].httpBody, requests[1].httpBody)
    }

    func testPersistentUnauthorizedStopsAfterOneRetry() async throws {
        var count = 0
        let api = NativeSessionMediaAPIClient(baseURL: URL(string: "https://example.test"), tokenProvider: { _ in "test" }, send: { request in
            count += 1
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await api.request(path: "/api/session-media/uploads", body: [:])
            XCTFail("Expected unauthorized")
        } catch NativeMediaUploadError.http(_, let status) {
            XCTAssertEqual(status, 401)
        }
        XCTAssertEqual(count, 2)
    }

    func testForbiddenDoesNotRefreshOrRetry() async throws {
        var tokens = 0
        let api = NativeSessionMediaAPIClient(baseURL: URL(string: "https://example.test"), tokenProvider: { _ in tokens += 1; return "test" }, send: { request in
            (Data(), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await api.request(path: "/api/session-media/uploads", body: [:])
            XCTFail("Expected forbidden")
        } catch NativeMediaUploadError.http(_, let status) {
            XCTAssertEqual(status, 403)
        }
        XCTAssertEqual(tokens, 1)
    }
}

@MainActor
final class NativePlanDoseCompletionTests: XCTestCase {
    func testOpeningBottlePlanAppliesPrescribedRepAndSetDose() throws {
        let app = NativeAppModel()

        app.openPlanItem(
            NativePlanItem(
                exerciseId: NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
                reps: 2,
                sets: 2,
            ),
        )

        let exercise = try XCTUnwrap(app.selectedExercise)
        XCTAssertEqual(exercise.reps, 2)
        XCTAssertEqual(exercise.sets, 2)
    }

    func testOpeningSitToStandPlanAppliesPrescribedRepAndSetDose() throws {
        let app = NativeAppModel()

        app.openPlanItem(
            NativePlanItem(
                exerciseId: NativeSitToStandV72AIModule.exerciseID,
                reps: 5,
                sets: 1,
            ),
        )

        let exercise = try XCTUnwrap(app.selectedExercise)
        XCTAssertEqual(exercise.id, NativeSitToStandV72AIModule.exerciseID)
        XCTAssertEqual(exercise.reps, 5)
        XCTAssertEqual(exercise.sets, 1)
        XCTAssertEqual(app.selectedKind, "plan")
    }

    func testFinishingSitToStandPlanPreservesCountAndLocalEvidenceForSummary() throws {
        let app = NativeAppModel()
        app.openPlanItem(
            NativePlanItem(
                exerciseId: NativeSitToStandV72AIModule.exerciseID,
                reps: 5,
                sets: 1,
            ),
        )
        let evidence = Data("derived-local-evidence".utf8)

        app.finishPractice(
            cuesPresented: 0,
            startedAt: Date().addingTimeInterval(-1),
            completedReps: 5,
            ruleBasedEvidenceJSON: evidence,
        )

        XCTAssertEqual(app.route, .summary)
        XCTAssertEqual(app.latestSummary?.reps, 5)
        XCTAssertEqual(app.latestSummary?.sets, 1)
        XCTAssertEqual(app.latestRuleBasedEvidenceJSON, evidence)
    }

    func testPrescribedCompletionFiresOnceAtTheFourRepTarget() {
        var policy = NativePracticeCompletionPolicy()

        XCTAssertEqual(
            policy.observe(
                isPrescribedPlan: true,
                completedReps: 3,
                targetTotalReps: 4,
            ),
            .continuePractice,
        )
        XCTAssertEqual(
            policy.observe(
                isPrescribedPlan: true,
                completedReps: 4,
                targetTotalReps: 4,
            ),
            .finishOnce,
        )
        XCTAssertEqual(
            policy.observe(
                isPrescribedPlan: true,
                completedReps: 5,
                targetTotalReps: 4,
            ),
            .alreadyFinished,
        )
    }

    func testExtraPracticeNeverAutoFinishesFromTheDoseGate() {
        var policy = NativePracticeCompletionPolicy()

        XCTAssertEqual(
            policy.observe(
                isPrescribedPlan: false,
                completedReps: 6,
                targetTotalReps: 4,
            ),
            .continuePractice,
        )
    }

    func testPracticeViewUsesRepCountPlanEligibilityInsteadOfBottleOnlyGate() throws {
        let testDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceURL = testDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("PhysioAINative/NativePracticeView.swift")
        let source = try String(contentsOf: sourceURL, encoding: .utf8)

        XCTAssertTrue(source.contains("isPrescribedRepCountPlan"))
        XCTAssertFalse(source.contains("isPrescribedBottlePlan"))
    }

    func testV7BottleModuleUsesTheEffectivePlanDose() {
        let module = NativeBottleGrabV7AIModule()
        let effectivePlanExercise = NativeExercise.bottleGrab.applying(
            planItem: NativePlanItem(
                exerciseId: NativeBottleGrabCapturePolicy.bottleGrabExerciseID,
                reps: 2,
                sets: 2,
            ),
        )

        module.configure(exercise: effectivePlanExercise)
        let output = module.ingest(NativeFixtureProvider.fullBodySnapshot(frame: 1))

        XCTAssertEqual(output.repsTarget, 2)
        XCTAssertEqual(output.totalSets, 2)
    }
}
