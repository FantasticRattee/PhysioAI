import XCTest
@testable import PhysioAINative

final class NativeV8FaultEvidenceTests: XCTestCase {
    func testV8BundleDeclaresTheLocalOnlyFaultEvidenceContract() throws {
        let appBundle = Bundle(for: NativeAppModel.self)
        XCTAssertEqual(appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "8.0.17")

        guard let url = appBundle.url(
            forResource: "native_v8_0_fault_evidence_local.manifest",
            withExtension: "json",
        ) else {
            XCTFail("Missing V8 local fault evidence manifest")
            return
        }

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["schema"] as? String, "physioai.native_fault_evidence_local.v1")
        XCTAssertEqual(object?["appVersion"] as? String, "8.0.15")
        XCTAssertEqual(object?["storage"] as? String, "process_memory_only")
        XCTAssertEqual(object?["moduleVersion"] as? String, "0.3.0-dev")
        XCTAssertEqual(object?["dashboardConnected"] as? Bool, false)
        XCTAssertEqual(object?["llmConnected"] as? Bool, false)
        XCTAssertEqual(object?["appIntegrationAuthorized"] as? Bool, true)
        let portablePackage = object?["portablePackage"] as? [String: Any]
        XCTAssertEqual(portablePackage?["name"] as? String, "PhysioAIFaultEvidenceKit")
        let ruleBasedSession = object?["ruleBasedSession"] as? [String: Any]
        XCTAssertEqual(
            ruleBasedSession?["schema"] as? String,
            "physioai.rule_based_bottle_grab_session.v1",
        )
        XCTAssertEqual(
            ruleBasedSession?["moduleId"] as? String,
            "bottle_grab_rule_based_session_v8_local",
        )
        XCTAssertEqual(ruleBasedSession?["storage"] as? String, "process_memory_until_user_export")
        XCTAssertEqual(ruleBasedSession?["delivery"] as? String, "user-initiated temporary JSON file plus iOS share sheet; no Dashboard, backend, Railway, LLM, or automatic persistence")
        let planDose = object?["planDoseExecution"] as? [String: Any]
        XCTAssertEqual(planDose?["source"] as? String, "NativePlanItem.reps and NativePlanItem.sets")
        XCTAssertEqual(planDose?["completion"] as? String, "one-shot local Summary transition when counter-owned total reaches reps × sets")
    }

    func testV8BundleDeclaresAdapterReadySitToStandRuleBasedEvidenceContract() throws {
        let appBundle = Bundle(for: NativeAppModel.self)
        guard let url = appBundle.url(
            forResource: "native_v8_0_fault_evidence_local.manifest",
            withExtension: "json",
        ) else {
            XCTFail("Missing V8 local fault evidence manifest")
            return
        }

        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(object?["portedEngineVersion"] as? String, "8.0.12")
        let sitToStand = object?["sitToStandRuleBasedSession"] as? [String: Any]
        XCTAssertEqual(sitToStand?["schema"] as? String, "physioai.rule_based_sit_to_stand_session.v1")
        XCTAssertEqual(sitToStand?["moduleId"] as? String, "sit_to_stand_rule_based_evidence_v1")
        XCTAssertEqual(sitToStand?["trackingProfile"] as? String, "pose_only")
        XCTAssertEqual(sitToStand?["anatomicalSide"] as? String, "bilateral")
        XCTAssertEqual(sitToStand?["delivery"] as? String, "user-initiated temporary JSON file plus iOS share sheet; adapter-ready but not uploaded")
        XCTAssertEqual(
            sitToStand?["schemaResource"] as? String,
            "PhysioAIFaultEvidenceKit/Sources/PhysioAIFaultEvidenceKit/Resources/sit-to-stand-rule-based-session.schema.json",
        )
        let calibration = object?["sitToStandCounterCalibration"] as? [String: Any]
        XCTAssertEqual(calibration?["version"] as? String, "8.0.15")
        XCTAssertEqual(calibration?["seatedMaximumMeanThighShinRatio"] as? Double, 0.55)
        XCTAssertEqual(calibration?["standingMinimumMeanThighShinRatio"] as? Double, 0.85)
        XCTAssertEqual(calibration?["baselineRiseMinimumInShins"] as? Double, 0.25)
        XCTAssertEqual(calibration?["changesPhaseNet"] as? Bool, false)
        XCTAssertEqual(calibration?["changesGuidedStartTTS"] as? Bool, true)

        let scoring = object?["postSessionScoring"] as? [String: Any]
        XCTAssertEqual(scoring?["scorer"] as? String, "NativeRuleBasedSessionScorerV13")
        XCTAssertEqual(scoring?["scorerVersion"] as? String, "1.0.0")
        XCTAssertEqual(scoring?["clinicalScore"] as? Bool, false)
        XCTAssertEqual(
            scoring?["detailedEvidenceDelivery"] as? String,
            "not connected to Dashboard, backend, Railway, or LLM",
        )
    }
}
