import AVFoundation
import Combine
import CoreMedia
import Foundation
import MediaPipeTasksVision

public final class DWSPoseCameraRuntime: NSObject, ObservableObject {
    @Published public private(set) var isRunning = false
    @Published public private(set) var statusText = "พร้อมเตรียมระบบ"
    @Published public private(set) var poseBackend = "not_loaded"
    @Published public private(set) var modelState = "not_loaded"
    @Published public private(set) var featureWindowCount = 0
    @Published public private(set) var landmarks: [DWSLandmark] = []
    @Published public private(set) var imageSize: CGSize = .zero
    @Published public private(set) var captureDevice: AVCaptureDevice?
    @Published public private(set) var safety = DWSSafetyResult(
        isScoreable: false, status: "no_pose", hint: "กดเริ่มแล้วเข้ากรอบกล้อง", normalizedLandmarks: []
    )
    @Published public private(set) var decision = DWSDecisionSnapshot(
        state: "waiting_rest", reason: "waiting_for_rest", reps: 0, isScoreable: false
    )

    public let captureSession = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.physioai.dws.camera")
    private let processingQueue = DispatchQueue(label: "com.physioai.dws.processing", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let hybridEngine = DWSHybridEngine(mode: DWSContract.appDecisionMode)
    private var poseLandmarker: PoseLandmarker?
    private var classifier: DWSCoreMLClassifier?
    private var featureVectors: [[Float]] = []
    private var latestSignal: DWSAISignal?
    private var lastInferenceAtMs: Double?
    private var lastSubmittedTimestamp = -1
    private var isPrepared = false
    private var currentImageSize: CGSize = .zero
    private var captureRotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var captureRotationObservation: NSKeyValueObservation?
    private var sampleBufferHandler: ((CMSampleBuffer) -> Void)?

    public override init() {
        super.init()
    }

    public func start() {
        publish { self.statusText = "กำลัง prewarm Pose และ Core ML…" }
        processingQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.prepareIfNeeded()
                self.requestCameraAndStart()
            } catch {
                self.publish {
                    self.modelState = "error"
                    self.statusText = error.localizedDescription
                }
            }
        }
    }

    public func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.captureSession.isRunning { self.captureSession.stopRunning() }
            self.processingQueue.async { self.resetProcessing() }
            self.publish {
                self.isRunning = false
                self.statusText = "หยุดแล้ว"
            }
        }
    }

    public func resetRepetitions() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.hybridEngine.reset()
            self.featureVectors.removeAll(keepingCapacity: true)
            self.latestSignal = nil
            self.lastInferenceAtMs = nil
            let snapshot = self.hybridEngine.currentSnapshot()
            self.publish {
                self.featureWindowCount = 0
                self.decision = snapshot
                self.statusText = self.isRunning ? "รีเซ็ตแล้ว—กลับมาที่กึ่งกลาง" : "พร้อมเริ่มใหม่"
            }
        }
    }

    /// Optional passive host hook used by PhysioAI's existing segmented video
    /// recorder. DWS inference remains the owner of capture and never reads
    /// recorder state or waits for encoding/upload work.
    public func setSampleBufferHandler(_ handler: ((CMSampleBuffer) -> Void)?) {
        processingQueue.async { [weak self] in
            self?.sampleBufferHandler = handler
        }
    }

    private func prepareIfNeeded() throws {
        if isPrepared { return }
        let classifier = try DWSCoreMLClassifier(computeUnits: .cpuAndNeuralEngine)
        try classifier.prewarm()
        self.classifier = classifier
        publish { self.modelState = "ready_cpu_ane" }

        let taskURL = try DWSCoreMLClassifier.resourceURL(named: "pose_landmarker_heavy", extension: "task")
        do {
            poseLandmarker = try makePoseLandmarker(modelPath: taskURL.path, delegate: .GPU)
            publish { self.poseBackend = "pose_heavy_gpu" }
        } catch {
            poseLandmarker = try makePoseLandmarker(modelPath: taskURL.path, delegate: .CPU)
            publish { self.poseBackend = "pose_heavy_cpu_fallback" }
        }
        isPrepared = true
    }

    private func makePoseLandmarker(modelPath: String, delegate: Delegate) throws -> PoseLandmarker {
        let options = PoseLandmarkerOptions()
        options.baseOptions = BaseOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.baseOptions.delegate = delegate
        options.runningMode = .liveStream
        options.numPoses = 1
        options.minPoseDetectionConfidence = 0.5
        options.minPosePresenceConfidence = 0.5
        options.minTrackingConfidence = 0.5
        options.poseLandmarkerLiveStreamDelegate = self
        return try PoseLandmarker(options: options)
    }

    private func requestCameraAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.configureAndStartCamera() }
                else { self.publish { self.statusText = DWSError.cameraPermissionDenied.localizedDescription } }
            }
        default:
            publish { self.statusText = DWSError.cameraPermissionDenied.localizedDescription }
        }
    }

    private func configureAndStartCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                if self.captureSession.inputs.isEmpty {
                    try self.configureCamera()
                }
                if !self.captureSession.isRunning { self.captureSession.startRunning() }
                self.publish {
                    self.isRunning = true
                    self.statusText = "กลับมาที่กึ่งกลางเพื่อเริ่ม"
                }
            } catch {
                self.publish { self.statusText = error.localizedDescription }
            }
        }
    }

    private func configureCamera() throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            throw DWSError.cameraUnavailable
        }
        publish { self.captureDevice = camera }
        let input = try AVCaptureDeviceInput(device: camera)
        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .high
        guard captureSession.canAddInput(input) else { throw DWSError.cameraUnavailable }
        captureSession.addInput(input)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        // MediaPipeTasksVision's MPImage(sampleBuffer:) initializer accepts
        // camera CVPixelBuffers in 32BGRA. AVCapture otherwise selects an NV12
        // format on device, which makes every live frame fail before Pose runs.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        guard captureSession.canAddOutput(videoOutput) else { throw DWSError.cameraUnavailable }
        captureSession.addOutput(videoOutput)
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            let coordinator = AVCaptureDevice.RotationCoordinator(
                device: camera,
                previewLayer: nil
            )
            captureRotationCoordinator = coordinator
            captureRotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelCapture,
                options: [.initial, .new]
            ) { [weak self, weak connection] coordinator, _ in
                guard let self, let connection else { return }
                let angle = coordinator.videoRotationAngleForHorizonLevelCapture
                self.sessionQueue.async { [weak self, weak connection] in
                    guard let self, let connection else { return }
                    self.applyCaptureRotation(angle, to: connection)
                }
            }
        }
    }

    private func applyCaptureRotation(_ angle: CGFloat, to connection: AVCaptureConnection) {
        guard connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func resetProcessing() {
        hybridEngine.interrupt()
        featureVectors.removeAll(keepingCapacity: true)
        latestSignal = nil
        lastInferenceAtMs = nil
        lastSubmittedTimestamp = -1
    }

    private func processPose(_ result: PoseLandmarkerResult?, timestampMs: Int, error: Error?) {
        if let error {
            blockTracking(timestampMs: timestampMs, status: "pose_error", hint: error.localizedDescription)
            return
        }
        let points = (result?.landmarks.first ?? []).map {
            DWSLandmark(x: $0.x, y: $0.y, z: $0.z, visibility: $0.visibility?.floatValue ?? 1)
        }
        guard !points.isEmpty else {
            blockTracking(timestampMs: timestampMs, status: "no_pose", hint: "เข้ากรอบกล้องก่อน")
            return
        }
        // The preview is a mirrored selfie but MediaPipe receives the
        // unmirrored capture output. Project analysis landmarks into the
        // displayed coordinate system so `correct_left` means screen-left.
        let safety = DWSSafetyGate.evaluate(points, screenMirrorX: true)
        guard safety.isScoreable else {
            featureVectors.removeAll(keepingCapacity: true)
            latestSignal = nil
            lastInferenceAtMs = nil
            let metrics = DWSMetrics(isValid: false, trunkShiftDegrees: 0,
                                     shoulderTiltDegrees: 0, signedTorsoLeanDegrees: 0)
            let decision = hybridEngine.push(timestampMs: Double(timestampMs), metrics: metrics,
                                             safety: safety, aiSignal: nil)
            publishFrame(safety: safety, displayLandmarks: points,
                         decision: decision, status: safety.hint)
            return
        }

        do {
            let vector = try DWSFeatureExtractor.vector(from: safety.normalizedLandmarks)
            featureVectors.append(vector)
            if featureVectors.count > DWSContract.windowSize {
                featureVectors.removeFirst(featureVectors.count - DWSContract.windowSize)
            }
            let now = Double(timestampMs)
            if lastInferenceAtMs == nil || now - (lastInferenceAtMs ?? now) >= DWSContract.inferenceIntervalMs {
                lastInferenceAtMs = now
                let window = try DWSFeatureExtractor.paddedWindow(featureVectors)
                latestSignal = try classifier?.predict(window: window)
            }
            let metrics = DWSFeatureExtractor.metrics(from: safety.normalizedLandmarks)
            let decision = hybridEngine.push(timestampMs: now, metrics: metrics,
                                             safety: safety, aiSignal: latestSignal)
            publishFrame(safety: safety, displayLandmarks: points,
                         decision: decision, status: status(for: decision))
        } catch {
            latestSignal = nil
            let metrics = DWSFeatureExtractor.metrics(from: safety.normalizedLandmarks)
            let decision = hybridEngine.push(timestampMs: Double(timestampMs), metrics: metrics,
                                             safety: safety, aiSignal: nil)
            publishFrame(safety: safety, displayLandmarks: points,
                         decision: decision, status: "Core ML: \(error.localizedDescription)")
        }
    }

    private func blockTracking(timestampMs: Int, status: String, hint: String) {
        featureVectors.removeAll(keepingCapacity: true)
        latestSignal = nil
        lastInferenceAtMs = nil
        let safety = DWSSafetyResult(isScoreable: false, status: status, hint: hint, normalizedLandmarks: [])
        let metrics = DWSMetrics(isValid: false, trunkShiftDegrees: 0,
                                 shoulderTiltDegrees: 0, signedTorsoLeanDegrees: 0)
        let decision = hybridEngine.push(timestampMs: Double(timestampMs), metrics: metrics,
                                         safety: safety, aiSignal: nil)
        publishFrame(safety: safety, displayLandmarks: [], decision: decision, status: hint)
    }

    private func publishFrame(safety: DWSSafetyResult, displayLandmarks: [DWSLandmark],
                              decision: DWSDecisionSnapshot, status: String) {
        let count = featureVectors.count
        let frameImageSize = currentImageSize
        publish {
            self.safety = safety
            // Rendering uses raw camera coordinates. Safety-side normalization
            // is intentionally kept private to feature extraction and rules.
            self.landmarks = displayLandmarks
            self.imageSize = frameImageSize
            self.decision = decision
            self.featureWindowCount = count
            self.statusText = status
        }
    }

    private func status(for snapshot: DWSDecisionSnapshot) -> String {
        switch snapshot.reason {
        case "ready_to_move": return "พร้อม—เลื่อนน้ำหนักไปด้านข้าง"
        case "below_target_angle": return "เลื่อนลำตัวต่ออีกเล็กน้อย"
        case "required_target_angle_not_reached":
            return String(
                format: "รักษาแนวไหล่ไม่ให้เอียงเกิน %.1f°",
                DWSContract.maximumShoulderTiltDegrees
            )
        case "confirming_ai_and_rule": return "AI ยืนยันแล้ว—คงท่าสั้น ๆ"
        case "ai_disagrees_waiting_rule": return "AI ยังไม่เห็นฟอร์มถูกต้อง"
        case "waiting_rule_fallback": return "กำลังยืนยันตำแหน่งเป้าหมาย"
        case "waiting_for_ai_rest": return "รอ AI ยืนยัน Rest"
        case "waiting_for_ai_target": return "รอ AI ยืนยัน Target และฟอร์มที่ถูกต้อง"
        case "confirming_ai_only": return "AI กำลังยืนยัน Target"
        case "reached_ai_only": return "AI นับครั้งแล้ว—กลับมา Rest"
        case "waiting_for_rule_rest": return "กลับเข้ามุม Rest เพื่อพร้อมครั้งถัดไป"
        case "waiting_for_ai_rule_match": return "รอ AI และกฎยืนยัน Target ตรงกัน"
        case "confirming_strict_ai_rule": return "AI และกฎตรงกัน—คงท่าให้ครบ 5 วินาที"
        case "reached_strict_ai_rule": return "AI และกฎตรงกัน—นับครั้งแล้ว"
        case "reached_wrong_rule_fallback": return "AI ระบุ Wrong—ผ่านกฎสำรองและนับแล้ว"
        case "reached_ai_and_rule", "reached_rule_fallback": return "นับครั้งแล้ว—กลับมากึ่งกลาง"
        case "completed_center_target_center": return "กลับกึ่งกลางแล้ว—พร้อมครั้งถัดไป"
        case "return_to_rest": return "กลับมากึ่งกลาง"
        default: return snapshot.reason
        }
    }

    private func publish(_ changes: @escaping () -> Void) {
        DispatchQueue.main.async(execute: changes)
    }
}

extension DWSPoseCameraRuntime: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        sampleBufferHandler?(sampleBuffer)
        guard let poseLandmarker else { return }
        if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            currentImageSize = CGSize(
                width: CGFloat(dimensions.width),
                height: CGFloat(dimensions.height)
            )
        }
        let seconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard seconds.isFinite else { return }
        let requested = Int((seconds * 1000).rounded())
        let timestamp = max(requested, lastSubmittedTimestamp + 1)
        lastSubmittedTimestamp = timestamp
        do {
            let image = try MPImage(sampleBuffer: sampleBuffer, orientation: .up)
            _ = try poseLandmarker.detectAsync(image: image, timestampInMilliseconds: timestamp)
        } catch {
            blockTracking(timestampMs: timestamp, status: "pose_submit_error", hint: error.localizedDescription)
        }
    }
}

extension DWSPoseCameraRuntime: PoseLandmarkerLiveStreamDelegate {
    public func poseLandmarker(_ poseLandmarker: PoseLandmarker,
                               didFinishDetection result: PoseLandmarkerResult?,
                               timestampInMilliseconds: Int, error: Error?) {
        processingQueue.async { [weak self] in
            self?.processPose(result, timestampMs: timestampInMilliseconds, error: error)
        }
    }
}
