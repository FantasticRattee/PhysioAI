import AVFoundation
import SwiftUI
import UIKit

public struct DWSCameraPreview: UIViewRepresentable {
    public let session: AVCaptureSession
    public let device: AVCaptureDevice?

    public init(session: AVCaptureSession, device: AVCaptureDevice?) {
        self.session = session
        self.device = device
    }

    public func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.configure(session: session, device: device)
        return view
    }

    public func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.configure(session: session, device: device)
    }

    public final class PreviewView: UIView {
        public override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        public var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        private weak var device: AVCaptureDevice?
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?

        fileprivate func configure(session: AVCaptureSession, device: AVCaptureDevice?) {
            if previewLayer.session !== session {
                previewLayer.session = session
            }
            if self.device !== device {
                rotationObservation = nil
                rotationCoordinator = nil
                self.device = device
            }
            previewLayer.videoGravity = .resizeAspectFill
            backgroundColor = .black
            configureRotationCoordinatorIfPossible()
        }

        public override func didMoveToWindow() {
            super.didMoveToWindow()
            configureRotationCoordinatorIfPossible()
        }

        public override func layoutSubviews() {
            super.layoutSubviews()
            applyPreviewRotation()
        }

        private func configureRotationCoordinatorIfPossible() {
            guard window != nil, rotationCoordinator == nil, let device else { return }
            let coordinator = AVCaptureDevice.RotationCoordinator(
                device: device,
                previewLayer: previewLayer
            )
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview,
                options: [.initial, .new]
            ) { [weak self] _, _ in
                DispatchQueue.main.async { self?.applyPreviewRotation() }
            }
        }

        private func applyPreviewRotation() {
            guard let connection = previewLayer.connection, let rotationCoordinator else { return }
            let angle = rotationCoordinator.videoRotationAngleForHorizonLevelPreview
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
    }
}

public enum DWSPreviewGeometry {
    /// Converts a MediaPipe normalized image point into the same geometry used
    /// by AVCaptureVideoPreviewLayer with `.resizeAspectFill`.
    public static func aspectFillPoint(
        x: CGFloat,
        y: CGFloat,
        imageSize: CGSize,
        viewSize: CGSize,
        mirroredHorizontally: Bool
    ) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else {
            return .zero
        }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale
        let offsetX = (viewSize.width - scaledWidth) / 2
        let offsetY = (viewSize.height - scaledHeight) / 2
        let normalizedX = mirroredHorizontally ? 1 - x : x
        return CGPoint(
            x: offsetX + normalizedX * scaledWidth,
            y: offsetY + y * scaledHeight
        )
    }
}

public struct DWSSkeletonOverlay: View {
    private let landmarks: [DWSLandmark]
    private let isReady: Bool
    private let imageSize: CGSize
    private let connections = [
        (11, 12), (11, 23), (12, 24), (23, 24),
        (11, 13), (13, 15), (12, 14), (14, 16),
        (23, 25), (25, 27), (24, 26), (26, 28),
    ]

    public init(landmarks: [DWSLandmark], isReady: Bool, imageSize: CGSize) {
        self.landmarks = landmarks
        self.isReady = isReady
        self.imageSize = imageSize
    }

    public var body: some View {
        Canvas { context, size in
            let color = isReady ? Color.green : Color.orange
            for (a, b) in connections where landmarks.indices.contains(a) && landmarks.indices.contains(b) {
                var path = Path()
                path.move(to: displayPoint(landmarks[a], size: size))
                path.addLine(to: displayPoint(landmarks[b], size: size))
                context.stroke(path, with: .color(color.opacity(0.85)), lineWidth: 3)
            }
            for index in [11, 12, 15, 16, 23, 24, 25, 26, 27, 28] where landmarks.indices.contains(index) {
                let point = displayPoint(landmarks[index], size: size)
                context.fill(Path(ellipseIn: CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)),
                             with: .color(.white))
            }
        }
        .allowsHitTesting(false)
    }

    private func displayPoint(_ point: DWSLandmark, size: CGSize) -> CGPoint {
        DWSPreviewGeometry.aspectFillPoint(
            x: CGFloat(point.x),
            y: CGFloat(point.y),
            imageSize: imageSize,
            viewSize: size,
            mirroredHorizontally: true
        )
    }
}

public struct DWSBoundaryOverlay: View {
    public let isReady: Bool

    public init(isReady: Bool) { self.isReady = isReady }

    public var body: some View {
        GeometryReader { proxy in
            RoundedRectangle(cornerRadius: 18)
                .stroke(isReady ? Color.green : Color.orange, lineWidth: 4)
                .frame(width: proxy.size.width * 0.95, height: proxy.size.height * 0.95)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .allowsHitTesting(false)
    }
}
