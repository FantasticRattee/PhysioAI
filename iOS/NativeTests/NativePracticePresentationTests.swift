import XCTest

/// Presentation-source contracts for the deliberately minimal opacity patch.
/// Simulator screenshots provide the separate rendered-view check.
final class NativePracticePresentationTests: XCTestCase {
    private func source() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("PhysioAINative/NativePracticeView.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testDiagnosticsStayMountedButAreTransparentAndCannotReceiveHiddenTaps() throws {
        let view = try source()
        XCTAssertTrue(view.contains("private let developerDiagnosticsOpacity: Double = 0"))
        XCTAssertTrue(view.contains("private var nativeDeveloperDiagnostics: some View"))
        XCTAssertTrue(view.contains("nativeDeveloperDiagnostics\n                    .opacity(developerDiagnosticsOpacity)"))
        XCTAssertTrue(view.contains(".allowsHitTesting(developerDiagnosticsOpacity > 0)"))
        XCTAssertTrue(view.contains(".accessibilityHidden(developerDiagnosticsOpacity == 0)"))
    }

    func testCenterPositioningCopyIsTransparentButCountdownRemainsVisible() throws {
        let view = try source()
        XCTAssertTrue(view.contains("private let positioningCommentOpacity: Double = 0"))
        XCTAssertTrue(view.contains("private var phaseOverlay: some View"))
        XCTAssertTrue(view.contains(".opacity(phase == .countdown ? 1 : positioningCommentOpacity)"))
        XCTAssertTrue(view.contains(".accessibilityHidden(phase != .countdown && positioningCommentOpacity == 0)"))
    }

    func testCoachingAndControlsAreNotRemovedByThePresentationChange() throws {
        let view = try source()
        for retained in [
            "@State private var speechEnabled = true",
            "@StateObject private var speech = NativeSpeechController()",
            "private var cueCard: some View",
            "private var audioOnlyHud: some View",
            "private var visualOnlyHud: some View",
            "private var bottomControls: some View",
            "beginSetupSpeechSession()",
            "updatePositioningState()",
        ] {
            XCTAssertTrue(view.contains(retained), "Must retain: \(retained)")
        }
    }
}
