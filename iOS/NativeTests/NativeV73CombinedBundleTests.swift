import XCTest
@testable import PhysioAINative

final class NativeV73CombinedBundleTests: XCTestCase {
    func testV8017AppRetainsTheV73CombinedBundleAsItsParentArtifact() throws {
        let appBundle = Bundle(for: NativeAppModel.self)
        XCTAssertEqual(appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, "8.0.17")
        XCTAssertEqual(appBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String, "17")

        guard let url = appBundle.url(
            forResource: "native_v7_3_combined_ai_bundle.manifest",
            withExtension: "json",
        ) else {
            XCTFail("Missing V7.3 combined bundle manifest")
            return
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))

        XCTAssertEqual(manifest.schema, "physioai.native_v7_3_combined_ai_bundle.v1")
        XCTAssertEqual(manifest.bundleId, "native_bottle_grab_sit_to_stand_v7_3_ai_bundle")
        XCTAssertEqual(manifest.bundleVersion, "7.3.6-sit-to-stand-pose-wrist-gate-dev")
        XCTAssertEqual(manifest.exercises, ["bottle_grab", "sit_to_stand"])
        XCTAssertEqual(manifest.exerciseModules.bottleGrab.moduleId, NativeBottleGrabV7AIModule.moduleID)
        XCTAssertEqual(manifest.exerciseModules.bottleGrab.baselineId, NativeBottleGrabV7AIModule.baselineID)
        XCTAssertTrue(manifest.exerciseModules.bottleGrab.behaviorChange)
        XCTAssertEqual(manifest.exerciseModules.sitToStand.moduleId, NativeSitToStandV72AIModule.moduleID)
        XCTAssertEqual(manifest.exerciseModules.sitToStand.sourceVersion, "v7.3.6_sit_to_stand_pose_wrist_gate")
        XCTAssertTrue(manifest.exerciseModules.sitToStand.behaviorChange)
        XCTAssertEqual(manifest.presentation.ttsCoordinator, "NativeSpeechCommentCoordinator")
        XCTAssertFalse(manifest.appIntegrationAuthorized)
        XCTAssertFalse(manifest.patientFacingApproved)
        XCTAssertFalse(manifest.clinicalApproved)
    }

    func testSitToStandModuleManifestDeclaresThePoseWristAdmissionGate() throws {
        let appBundle = Bundle(for: NativeAppModel.self)
        guard let url = appBundle.url(
            forResource: "sit_to_stand_v7_ai_module.manifest",
            withExtension: "json",
        ) else {
            XCTFail("Missing Sit-to-Stand native module manifest")
            return
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let ownership = object?["parallelOwnership"] as? [String: Any]

        XCTAssertEqual(object?["moduleVersion"] as? String, NativeSitToStandV72AIModule.moduleVersion)
        XCTAssertEqual(object?["branch"] as? String, "codex/combination-v1-v8-0-15-sts-posture")
        XCTAssertEqual(ownership?["admissionGate"] as? String, "sit_to_stand_pose_wrist_admission_gate_v2")
        XCTAssertEqual(ownership?["counterConsumesAdmissionGate"] as? Bool, true)
    }

    func testV73DebugBuildDefaultsBottleGrabToTheCombinedV7Path() {
        #if DEBUG
        XCTAssertTrue(NativeBottleDetectorContract.isV7Enabled)
        #endif
    }

    private struct Manifest: Decodable {
        let schema: String
        let bundleId: String
        let bundleVersion: String
        let exercises: [String]
        let exerciseModules: ExerciseModules
        let presentation: Presentation
        let appIntegrationAuthorized: Bool
        let patientFacingApproved: Bool
        let clinicalApproved: Bool

        struct ExerciseModules: Decodable {
            let bottleGrab: BottleGrab
            let sitToStand: SitToStand

            enum CodingKeys: String, CodingKey {
                case bottleGrab = "bottle_grab"
                case sitToStand = "sit_to_stand"
            }

            struct BottleGrab: Decodable {
                let moduleId: String
                let baselineId: String
                let behaviorChange: Bool
            }

            struct SitToStand: Decodable {
                let moduleId: String
                let sourceVersion: String
                let behaviorChange: Bool
            }
        }

        struct Presentation: Decodable {
            let ttsCoordinator: String
        }
    }
}
