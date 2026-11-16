import SwiftUI

/// Maps MediaPipe's normalized image coordinates into the same
/// `resizeAspectFill` geometry used by `AVCaptureVideoPreviewLayer`.
///
/// A direct `x * canvas.width`, `y * canvas.height` mapping stretches the
/// landmark image to fill the preview. On a portrait iPhone that puts the
/// skeleton beside the camera subject whenever the preview crops either axis.
/// This mapper preserves the camera image's aspect ratio, applies the same
/// centered crop, and lets Canvas clip points that are genuinely off-screen.
enum NativePreviewCoordinateMapper {
    static let portraitHDAspectRatio: CGFloat = 9 / 16

    static func point(
        normalizedX: CGFloat,
        normalizedY: CGFloat,
        mirrored: Bool,
        sourceAspectRatio: CGFloat,
        destinationSize: CGSize,
    ) -> CGPoint {
        guard destinationSize.width > 0, destinationSize.height > 0 else {
            return .zero
        }
        let sourceAspect = sourceAspectRatio.isFinite && sourceAspectRatio > 0
            ? sourceAspectRatio
            : portraitHDAspectRatio
        let sourceWidth = sourceAspect
        let sourceHeight: CGFloat = 1
        let scale = max(
            destinationSize.width / sourceWidth,
            destinationSize.height / sourceHeight,
        )
        let renderedWidth = sourceWidth * scale
        let renderedHeight = sourceHeight * scale
        let offsetX = (destinationSize.width - renderedWidth) / 2
        let offsetY = (destinationSize.height - renderedHeight) / 2
        let x = mirrored ? 1 - normalizedX : normalizedX
        return CGPoint(
            x: offsetX + max(0, min(1, x)) * renderedWidth,
            y: offsetY + max(0, min(1, normalizedY)) * renderedHeight,
        )
    }
}

/// Bottle Grab needs both Pose and Hand observations. A previous hand-only
/// policy hid every body skeleton, which made a valid Pose result invisible
/// during device validation. Draw the 33-point body topology only when the
/// full-body anchor set is credible; a weak partial Pose still stays hidden
/// rather than being misrepresented as a malformed body skeleton.
enum NativeSkeletonOverlayPolicy {
    private static let bottleGrabFullBodyAnchors = [0, 11, 12, 13, 15, 17, 19, 21, 23, 24, 25, 26, 27, 28]

    static func showsBodyPose(
        exerciseID: String?,
        snapshot: NativeFrameSnapshot?,
    ) -> Bool {
        guard exerciseID?.lowercased() == "bottle_grab" else { return true }
        guard let pose = snapshot?.pose, pose.count >= 33 else { return false }
        return bottleGrabFullBodyAnchors.allSatisfy { index in
            let point = pose[index]
            return point.x.isFinite && point.y.isFinite && point.visibility.isFinite
                && point.x >= 0 && point.x <= 1
                && point.y >= 0 && point.y <= 1
                && point.visibility >= 0.5
        }
    }
}

struct LandmarkOverlay: View {
    let snapshot: NativeFrameSnapshot?
    /// Accepted current Bottle ROI only. A stale/rejected detector result is
    /// intentionally absent, so the overlay never makes an old box look live.
    var bottleDetection: NativeBottleDetection? = nil
    var mirrored = false
    var sourceAspectRatio: CGFloat = NativePreviewCoordinateMapper.portraitHDAspectRatio
    var showsBodyPose = true
    var lineColor: Color = .white.opacity(0.78)
    var pointColor: Color = .mint
    var handLineColor: Color = .mint.opacity(0.95)
    var handPointColor: Color = .white

    private let poseEdges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 7), (0, 4), (4, 5), (5, 6), (6, 8),
        (9, 10), (11, 12),
        (11, 13), (13, 15), (15, 17), (15, 19), (15, 21), (17, 19),
        (12, 14), (14, 16), (16, 18), (16, 20), (16, 22), (18, 20),
        (11, 23), (12, 24), (23, 24),
        (23, 25), (25, 27), (27, 29), (27, 31), (29, 31),
        (24, 26), (26, 28), (28, 30), (28, 32), (30, 32),
    ]

    private let handEdges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (5, 9), (9, 10), (10, 11), (11, 12),
        (9, 13), (13, 14), (14, 15), (15, 16),
        (13, 17), (17, 18), (18, 19), (19, 20),
        (0, 17),
    ]

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard let snapshot else { return }
                func map(_ point: NativeLandmark) -> CGPoint {
                    NativePreviewCoordinateMapper.point(
                        normalizedX: CGFloat(point.x),
                        normalizedY: CGFloat(point.y),
                        mirrored: mirrored,
                        sourceAspectRatio: sourceAspectRatio,
                        destinationSize: size,
                    )
                }

                if showsBodyPose, snapshot.pose.count >= 33 {
                    let mapped = snapshot.pose.map(map)
                    var poseLines = Path()
                    for (from, to) in poseEdges {
                        guard snapshot.pose[from].visibility >= 0.35,
                              snapshot.pose[to].visibility >= 0.35 else { continue }
                        poseLines.move(to: mapped[from])
                        poseLines.addLine(to: mapped[to])
                    }
                    context.stroke(poseLines, with: .color(lineColor), lineWidth: 3)
                    for (index, point) in mapped.enumerated() where snapshot.pose[index].visibility >= 0.35 {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)), with: .color(pointColor))
                    }
                }

                if snapshot.hand.count >= 21 {
                    let mapped = snapshot.hand.map(map)
                    var handLines = Path()
                    for (from, to) in handEdges {
                        handLines.move(to: mapped[from])
                        handLines.addLine(to: mapped[to])
                    }
                    context.stroke(handLines, with: .color(handLineColor), lineWidth: 3)
                    for point in mapped {
                        context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)), with: .color(handPointColor))
                    }
                }

                if let bottleDetection {
                    let box = bottleDetection.boundingBox
                    let first = NativePreviewCoordinateMapper.point(
                        normalizedX: box.minX,
                        normalizedY: box.minY,
                        mirrored: mirrored,
                        sourceAspectRatio: sourceAspectRatio,
                        destinationSize: size,
                    )
                    let second = NativePreviewCoordinateMapper.point(
                        normalizedX: box.maxX,
                        normalizedY: box.maxY,
                        mirrored: mirrored,
                        sourceAspectRatio: sourceAspectRatio,
                        destinationSize: size,
                    )
                    let rectangle = CGRect(
                        x: min(first.x, second.x),
                        y: min(first.y, second.y),
                        width: abs(second.x - first.x),
                        height: abs(second.y - first.y),
                    )
                    guard rectangle.width > 1, rectangle.height > 1 else { return }
                    context.fill(
                        Path(roundedRect: rectangle, cornerRadius: 12),
                        with: .color(.green.opacity(0.12)),
                    )
                    context.stroke(
                        Path(roundedRect: rectangle, cornerRadius: 12),
                        with: .color(.green.opacity(0.95)),
                        lineWidth: 3,
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .allowsHitTesting(false)
        }
    }
}
