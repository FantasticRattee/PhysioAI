import AVFoundation
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var camera = CameraSession()
    @State private var speechEnabled = true
    @StateObject private var speech = NativeSpeechController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.authorization == .authorized {
                CameraPreview(session: camera.captureSession, onFocusPoint: camera.focus(at:))
                    .ignoresSafeArea()
                LandmarkOverlay(snapshot: camera.latestSnapshot)
                    .ignoresSafeArea()
            } else {
                permissionView
            }

            VStack(spacing: 0) {
                header
                Spacer()
                diagnosticsCard
                controls
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .task {
            camera.requestPermissionAndStart()
            speech.configure()
        }
        .onDisappear {
            camera.stop()
            speech.stop()
        }
        .onReceive(camera.$latestOutput.compactMap { $0?.cue }.removeDuplicates()) { cue in
            guard speechEnabled else { return }
            _ = speech.submit(
                NativeSpeechRequest(
                    semanticKey: "model-cue:\(cue)",
                    text: cue,
                    language: "en-US",
                    priority: .form,
                    observedAt: Date().timeIntervalSinceReferenceDate,
                ),
            )
        }
    }

    private var permissionView: some View {
        VStack(spacing: 18) {
            Text("PhysioAI")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text(camera.authorization == .denied ? "Camera permission is off" : "Camera permission is required")
                .font(.headline)
            Text("This native preview keeps camera capture and MediaPipe inference on the iPhone.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if camera.authorization == .denied {
                Button("Open Settings") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button("Allow Camera") { camera.requestPermissionAndStart() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
    }

    private var header: some View {
        let isV7 = NativeBottleDetectorContract.isV7Enabled
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Bottle Grab")
                    .font(.system(size: 27, weight: .bold, design: .rounded))
                Text(isV7 ? NativeAppBuildProfile.activeContentEnglish : "App V6.1 · Experimental · Hand Robustness + Geometry First")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.72))
            }
            Spacer()
            Text(isV7 ? NativeAppBuildProfile.activeContentBadgeEnglish : "APP V6.1 · EXPERIMENTAL")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.white.opacity(0.16), in: Capsule())
        }
        .padding(14)
        .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
    }

    private var diagnosticsCard: some View {
        let output = camera.latestOutput
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(output?.captureQC == "can_assess" ? .green : .orange)
                    .frame(width: 9, height: 9)
                Text(output?.captureQC == "can_assess" ? "Pose + hand detected" : "Waiting for full-body + hand")
                    .font(.headline)
                Spacer()
                Text(output?.phase?.uppercased() ?? "—")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
            }
            Text(output?.cue ?? "Position your left hand and upper body in frame. This is a tentative development cue only.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))
            HStack(spacing: 14) {
                stat("Pose", "\(output?.posePoints ?? 0)/33")
                stat("Hand", "\(output?.handPoints ?? 0)/21")
                stat("Frames", "\(output?.bufferedFrames ?? 0)")
                stat("Latency", output.map { String(format: "%.0f ms", $0.detectorLatencyMs) } ?? "—")
            }
            Text("\(camera.cameraStatus) · drops \(camera.droppedFrames)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.58))
        }
        .padding(16)
        .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 18))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    camera.switchCamera()
                } label: {
                    Label(camera.position == .back ? "Front" : "Back", systemImage: "camera.rotate")
                }
                .buttonStyle(NativeControlStyle())

                Menu {
                    ForEach(camera.lensOptions) { option in
                        Button(option.title) { camera.selectLens(option) }
                    }
                } label: {
                    Label(camera.selectedLensTitle, systemImage: "camera.aperture")
                }
                .buttonStyle(NativeControlStyle())

                Button {
                    speechEnabled.toggle()
                    if !speechEnabled { speech.stop() }
                } label: {
                    Label(speechEnabled ? "TTS on" : "TTS off", systemImage: speechEnabled ? "speaker.wave.2" : "speaker.slash")
                }
                .buttonStyle(NativeControlStyle())
            }
            Text("Only capabilities reported by this iPhone are shown. No frames leave the device.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.62))
                .multilineTextAlignment(.center)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
        }
    }

}

private struct NativeControlStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .background(.black.opacity(configuration.isPressed ? 0.82 : 0.62), in: Capsule())
    }
}
