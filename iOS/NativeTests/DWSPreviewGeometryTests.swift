import XCTest
@testable import PhysioAIDynamicWeightShiftSDK

final class DWSPreviewGeometryTests: XCTestCase {
    func testAspectFillUsesVerticalCoordinatesWithoutCropForPortraitFrame() {
        let point = DWSPreviewGeometry.aspectFillPoint(
            x: 0.25,
            y: 0.75,
            imageSize: CGSize(width: 1080, height: 1920),
            viewSize: CGSize(width: 390, height: 844),
            mirroredHorizontally: true
        )

        XCTAssertEqual(point.x, 313.6875, accuracy: 0.0001)
        XCTAssertEqual(point.y, 633, accuracy: 0.0001)
    }

    func testAspectFillAccountsForHorizontalCropAndSelfieMirror() {
        let leftEdge = DWSPreviewGeometry.aspectFillPoint(
            x: 0,
            y: 0.5,
            imageSize: CGSize(width: 1080, height: 1920),
            viewSize: CGSize(width: 390, height: 844),
            mirroredHorizontally: true
        )
        let rightEdge = DWSPreviewGeometry.aspectFillPoint(
            x: 1,
            y: 0.5,
            imageSize: CGSize(width: 1080, height: 1920),
            viewSize: CGSize(width: 390, height: 844),
            mirroredHorizontally: true
        )

        XCTAssertEqual(leftEdge.x, 432.375, accuracy: 0.0001)
        XCTAssertEqual(rightEdge.x, -42.375, accuracy: 0.0001)
        XCTAssertEqual(leftEdge.y, 422, accuracy: 0.0001)
        XCTAssertEqual(rightEdge.y, 422, accuracy: 0.0001)
    }
}
