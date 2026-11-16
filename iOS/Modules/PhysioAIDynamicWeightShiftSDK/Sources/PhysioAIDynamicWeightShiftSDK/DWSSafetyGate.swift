import Foundation

public enum DWSSafetyGate {
    private static let primary: [(String, Int)] = [
        ("left_shoulder", 11), ("right_shoulder", 12), ("left_hip", 23), ("right_hip", 24),
    ]
    private static let stabilizers: [(String, Int)] = [
        ("left_knee", 25), ("right_knee", 26), ("left_ankle", 27), ("right_ankle", 28),
        ("left_wrist", 15), ("right_wrist", 16),
    ]

    public static func evaluate(
        _ rawLandmarks: [DWSLandmark],
        screenMirrorX: Bool = false
    ) -> DWSSafetyResult {
        let points = DWSFeatureExtractor.prepareForDisplayedScreen(
            rawLandmarks,
            mirroredHorizontally: screenMirrorX
        )
        guard points.count >= 33 else {
            return blocked("no_pose", "เข้ากรอบกล้องก่อน", points)
        }
        let missingPrimary = missing(primary, in: points)
        if !missingPrimary.isEmpty {
            return blocked("missing_primary_required", "ยังไม่เห็นหัวไหล่และสะโพกครบ", points)
        }
        let missingStabilizers = missing(stabilizers, in: points)
        if !missingStabilizers.isEmpty {
            return blocked("missing_stabilizer_required", "ต้องเห็นเข่า ข้อเท้า และข้อมือครบ", points)
        }
        let lowPrimary = lowVisibility(primary, in: points, minimum: DWSContract.minimumPrimaryVisibility)
        let lowStabilizers = lowVisibility(stabilizers, in: points, minimum: DWSContract.minimumStabilizerVisibility)
        if !lowPrimary.isEmpty || !lowStabilizers.isEmpty {
            return blocked("low_visibility", "ปรับแสงหรือระยะกล้องให้จุดสำคัญชัดขึ้น", points)
        }
        let outside = (primary + stabilizers).filter { _, index in
            let point = points[index]
            return point.x < DWSContract.boundaryMinimum || point.x > DWSContract.boundaryMaximum ||
                point.y < DWSContract.boundaryMinimum || point.y > DWSContract.boundaryMaximum
        }
        if !outside.isEmpty {
            return blocked("out_of_frame", "ขยับให้จุดสำคัญอยู่ในกรอบ", points)
        }
        let view = cameraView(points)
        guard view.ok else { return blocked(view.status, view.hint, points, detectedView: view.detected) }
        return DWSSafetyResult(isScoreable: true, status: "ready", hint: "พร้อมเริ่มท่า",
                               normalizedLandmarks: points, detectedView: view.detected)
    }

    private static func missing(_ specs: [(String, Int)], in points: [DWSLandmark]) -> [String] {
        specs.compactMap { name, index in
            let p = points[index]
            return p.isFinite2D ? nil : name
        }
    }

    private static func lowVisibility(_ specs: [(String, Int)], in points: [DWSLandmark], minimum: Float) -> [String] {
        specs.compactMap { name, index in
            let value = points[index].visibility
            return value.isFinite && value >= minimum ? nil : name
        }
    }

    private static func cameraView(_ p: [DWSLandmark]) -> (ok: Bool, status: String, hint: String, detected: String?) {
        let ls = p[11], rs = p[12], lh = p[23], rh = p[24]
        let shoulderSpan = distance2D(ls, rs)
        let hipSpan = distance2D(lh, rh)
        let torsoScale = (distance2D(ls, lh) + distance2D(rs, rh)) / 2
        guard torsoScale > 0 else {
            return (false, "camera_view_unavailable", "จัดให้เห็นหัวไหล่และสะโพกเพื่อเช็กมุมกล้อง", nil)
        }
        let lateralRatio = max(shoulderSpan, hipSpan) / torsoScale
        if lateralRatio >= 0.32 { return (true, "ready", "มุมกล้องด้านหน้าพร้อมแล้ว", "front") }
        if lateralRatio <= 0.20 { return (false, "wrong_camera_view", "หันหน้าเข้ากล้อง", "side") }
        return (false, "camera_view_uncertain", "ปรับตัวให้เป็นมุมด้านหน้าชัดเจนขึ้น", "uncertain")
    }

    private static func distance2D(_ a: DWSLandmark, _ b: DWSLandmark) -> Double {
        hypot(Double(a.x - b.x), Double(a.y - b.y))
    }

    private static func blocked(_ status: String, _ hint: String, _ points: [DWSLandmark],
                                detectedView: String? = nil) -> DWSSafetyResult {
        DWSSafetyResult(isScoreable: false, status: status, hint: hint,
                        normalizedLandmarks: points, detectedView: detectedView)
    }
}
