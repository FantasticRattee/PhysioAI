import Foundation

public enum DWSFeatureExtractor {
    private static let bilateralPairs = [
        (1, 4), (2, 5), (3, 6), (7, 8), (9, 10), (11, 12), (13, 14),
        (15, 16), (17, 18), (19, 20), (21, 22), (23, 24), (25, 26),
        (27, 28), (29, 30), (31, 32),
    ]
    private static let sideEvidencePairs = [(11, 12), (23, 24), (25, 26), (27, 28), (7, 8)]
    private static let modelIndices = [11, 12, 23, 24]

    /// Projects raw camera landmarks into the coordinate system shown to the
    /// patient. The front-camera preview is rendered as a selfie, while the
    /// MediaPipe video output remains unmirrored, so live analysis must reflect
    /// X exactly once before applying the screen-side landmark convention.
    public static func projectToDisplayedScreen(
        _ input: [DWSLandmark],
        mirroredHorizontally: Bool
    ) -> [DWSLandmark] {
        guard mirroredHorizontally else { return input }
        return input.map { point in
            var reflected = point
            if reflected.x.isFinite { reflected.x = 1 - reflected.x }
            return reflected
        }
    }

    public static func prepareForDisplayedScreen(
        _ input: [DWSLandmark],
        mirroredHorizontally: Bool
    ) -> [DWSLandmark] {
        normalizeToScreenSide(projectToDisplayedScreen(
            input,
            mirroredHorizontally: mirroredHorizontally
        ))
    }

    public static func normalizeToScreenSide(_ input: [DWSLandmark]) -> [DWSLandmark] {
        guard input.count >= 33 else { return input }
        let evidence = sideEvidencePairs.compactMap { left, right -> Float? in
            let a = input[left]
            let b = input[right]
            guard a.isFinite2D, b.isFinite2D else { return nil }
            let value = a.x - b.x
            return abs(value) > 0.00001 ? value : nil
        }.sorted()
        guard !evidence.isEmpty else { return input }
        let median: Float
        let middle = evidence.count / 2
        if evidence.count.isMultiple(of: 2) {
            median = (evidence[middle - 1] + evidence[middle]) / 2
        } else {
            median = evidence[middle]
        }
        guard median > 0 else { return input }
        var output = input
        bilateralPairs.forEach { left, right in output.swapAt(left, right) }
        return output
    }

    public static func metrics(from normalizedLandmarks: [DWSLandmark], neutralTorsoLeanDegrees: Double = 0) -> DWSMetrics {
        guard normalizedLandmarks.count > DWSLandmarkIndex.rightAnkle else {
            return DWSMetrics(isValid: false, trunkShiftDegrees: 0,
                              shoulderTiltDegrees: 0, signedTorsoLeanDegrees: 0)
        }
        let ls = normalizedLandmarks[DWSLandmarkIndex.leftShoulder]
        let rs = normalizedLandmarks[DWSLandmarkIndex.rightShoulder]
        let lh = normalizedLandmarks[DWSLandmarkIndex.leftHip]
        let rh = normalizedLandmarks[DWSLandmarkIndex.rightHip]
        let shoulderX = Double(ls.x + rs.x) / 2
        let shoulderY = Double(ls.y + rs.y) / 2
        let hipX = Double(lh.x + rh.x) / 2
        let hipY = Double(lh.y + rh.y) / 2
        let shoulderTilt = abs(atan2(Double(rs.y - ls.y), max(abs(Double(rs.x - ls.x)), 0.000001)) * 180 / .pi)
        let torsoLean = atan2(shoulderX - hipX, hipY - shoulderY) * 180 / .pi
        let signed = torsoLean - neutralTorsoLeanDegrees
        return DWSMetrics(isValid: true, trunkShiftDegrees: abs(signed),
                          shoulderTiltDegrees: shoulderTilt, signedTorsoLeanDegrees: signed)
    }

    public static func vector(from normalizedLandmarks: [DWSLandmark]) throws -> [Float] {
        guard normalizedLandmarks.count >= 33 else { throw DWSError.invalidFeatureWindow }
        let selected = modelIndices.map { normalizedLandmarks[$0] }
        let usable = selected.filter(\.isUsable)
        let first = usable.first ?? DWSLandmark(x: 0, y: 0, z: 0, visibility: 0)
        let shoulderCenter = midpoint(selected[0], selected[1])
        let hipCenter = midpoint(selected[2], selected[3])
        let anchor = hipCenter ?? shoulderCenter ?? (first.x, first.y, first.z)
        let candidateScales = [
            distance3D(selected[0], selected[1]),
            distance3D(selected[2], selected[3]),
            distance3D(shoulderCenter, hipCenter),
            selected.filter(\.isUsable).map { point in
                hypot3(point.x - anchor.0, point.y - anchor.1, point.z - anchor.2)
            }.max() ?? 0,
        ]
        let scale = candidateScales.first(where: { $0.isFinite && $0 >= 0.03 }) ?? 1
        let normalized: [DWSLandmark] = selected.map { point in
            guard point.isUsable else { return DWSLandmark(x: 0, y: 0, z: 0, visibility: 0) }
            return DWSLandmark(
                x: (point.x - anchor.0) / scale,
                y: (point.y - anchor.1) / scale,
                z: (point.z - anchor.2) / scale,
                visibility: point.visibility
            )
        }
        var output = normalized.flatMap { [$0.x, $0.y, $0.z, $0.visibility] }
        let leftShoulder = normalized[0]
        let rightShoulder = normalized[1]
        let leftHip = normalized[2]
        let rightHip = normalized[3]
        let normalizedShoulderCenter = midpoint(leftShoulder, rightShoulder)
        let normalizedHipCenter = midpoint(leftHip, rightHip)
        let leftLength = tanh(hypot2(leftHip.x - leftShoulder.x, leftHip.y - leftShoulder.y))
        let rightLength = tanh(hypot2(rightHip.x - rightShoulder.x, rightHip.y - rightShoulder.y))
        output.append(contentsOf: [
            clamp(Float(atan2(Double(rightShoulder.y - leftShoulder.y),
                              max(abs(Double(rightShoulder.x - leftShoulder.x)), 0.000001)) * 180 / .pi / 90)),
            leanFromVertical(hip: (leftHip.x, leftHip.y), shoulder: (leftShoulder.x, leftShoulder.y)),
            leanFromVertical(hip: (rightHip.x, rightHip.y), shoulder: (rightShoulder.x, rightShoulder.y)),
            leanFromVertical(hip: normalizedHipCenter.map { ($0.0, $0.1) },
                             shoulder: normalizedShoulderCenter.map { ($0.0, $0.1) }),
            leftLength,
            rightLength,
            clamp(leftLength - rightLength),
        ])
        guard output.count == DWSContract.featureSize, output.allSatisfy(\.isFinite) else {
            throw DWSError.invalidFeatureWindow
        }
        return output
    }

    public static func paddedWindow(_ vectors: [[Float]]) throws -> [[Float]] {
        guard let first = vectors.first,
              vectors.allSatisfy({ $0.count == DWSContract.featureSize }) else {
            throw DWSError.invalidFeatureWindow
        }
        let recent = Array(vectors.suffix(DWSContract.windowSize))
        return Array(repeating: first, count: DWSContract.windowSize - recent.count) + recent
    }

    private static func midpoint(_ a: DWSLandmark, _ b: DWSLandmark) -> (Float, Float, Float)? {
        guard a.isUsable, b.isUsable else { return nil }
        return ((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
    }

    private static func distance3D(_ a: DWSLandmark, _ b: DWSLandmark) -> Float {
        guard a.isUsable, b.isUsable else { return 0 }
        return hypot3(a.x - b.x, a.y - b.y, a.z - b.z)
    }

    private static func distance3D(_ a: (Float, Float, Float)?, _ b: (Float, Float, Float)?) -> Float {
        guard let a, let b else { return 0 }
        return hypot3(a.0 - b.0, a.1 - b.1, a.2 - b.2)
    }

    private static func hypot2(_ x: Float, _ y: Float) -> Float { sqrt(x * x + y * y) }
    private static func hypot3(_ x: Float, _ y: Float, _ z: Float) -> Float { sqrt(x * x + y * y + z * z) }
    private static func clamp(_ value: Float) -> Float { min(1, max(-1, value.isFinite ? value : 0)) }

    private static func leanFromVertical(hip: (Float, Float)?, shoulder: (Float, Float)?) -> Float {
        guard let hip, let shoulder else { return 0 }
        let value = atan2(Double(shoulder.0 - hip.0), Double(hip.1 - shoulder.1)) * 180 / .pi / 90
        return clamp(Float(value))
    }
}
