import AVFoundation
import SwiftUI
import UIKit

final class PreviewView: UIView {
    private let focusReticle = CAShapeLayer()

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        videoPreviewLayer.frame = bounds
    }

    func showFocusReticle(at point: CGPoint) {
        let side: CGFloat = 72
        let frame = CGRect(
            x: point.x - side / 2,
            y: point.y - side / 2,
            width: side,
            height: side,
        )
        if focusReticle.superlayer == nil {
            focusReticle.fillColor = UIColor.clear.cgColor
            focusReticle.strokeColor = UIColor.systemYellow.cgColor
            focusReticle.lineWidth = 2.5
            videoPreviewLayer.addSublayer(focusReticle)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        focusReticle.path = UIBezierPath(roundedRect: frame, cornerRadius: 10).cgPath
        focusReticle.opacity = 1
        CATransaction.commit()
        focusReticle.removeAllAnimations()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.9
        fade.beginTime = CACurrentMediaTime() + 0.55
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        focusReticle.add(fade, forKey: "focus-reticle-fade")
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    var onFocusPoint: ((CGPoint) -> Void)? = nil

    final class Coordinator: NSObject {
        var onFocusPoint: ((CGPoint) -> Void)?

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended,
                  let preview = recognizer.view as? PreviewView else {
                return
            }
            let layerPoint = recognizer.location(in: preview)
            preview.showFocusReticle(at: layerPoint)
            let devicePoint = preview.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: layerPoint)
            onFocusPoint?(NativeCaptureFocusPolicy.clampedDevicePoint(devicePoint))
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        context.coordinator.onFocusPoint = onFocusPoint
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        if uiView.videoPreviewLayer.session !== session {
            uiView.videoPreviewLayer.session = session
        }
        context.coordinator.onFocusPoint = onFocusPoint
    }
}
