import Foundation

/// Native counterpart of the current rule-based static exercise path.
///
/// This adapter intentionally keeps the same contract as the React Native
/// JointAngleCalculator → PoseComparator → FeedbackGenerator → rep state
/// machine. It is used only for legacy/therapist-plan exercises; the exposed
/// App-V5 catalog remains Bottle Grab and its Calibration 3 cue-only boundary.
final class NativeStaticExerciseEngine {
    private struct JointSpec {
        let id: String
        let a: Int
        let b: Int
        let c: Int
    }

    private let specs: [JointSpec] = [
        .init(id: "left_elbow", a: 11, b: 13, c: 15),
        .init(id: "right_elbow", a: 12, b: 14, c: 16),
        .init(id: "left_shoulder", a: 13, b: 11, c: 23),
        .init(id: "right_shoulder", a: 14, b: 12, c: 24),
        .init(id: "left_hip", a: 11, b: 23, c: 25),
        .init(id: "right_hip", a: 12, b: 24, c: 26),
        .init(id: "left_knee", a: 23, b: 25, c: 27),
        .init(id: "right_knee", a: 24, b: 26, c: 28),
        .init(id: "left_ankle", a: 25, b: 27, c: 31),
        .init(id: "right_ankle", a: 26, b: 28, c: 32),
    ]

    private var exercise = NativeExercise.bottleGrab
    private var elapsed: Double = 0
    private var lastTimestampMs: Int?
    private var peakHold: Double = 0
    private var phase = "rest"
    private var repsInSet = 0
    private var setsDone = 0
    private var frameCount = 0
    private var assessableCount = 0
    private var lastDetectorLatency: Double = 0
    private var lastOutput: NativeBottleGrabOutput?

    func configure(exercise: NativeExercise) {
        self.exercise = exercise
        reset()
    }

    func reset() {
        elapsed = 0
        lastTimestampMs = nil
        peakHold = 0
        phase = "rest"
        repsInSet = 0
        setsDone = 0
        frameCount = 0
        assessableCount = 0
        lastDetectorLatency = 0
        lastOutput = nil
    }

    func ingest(_ snapshot: NativeFrameSnapshot) -> NativeBottleGrabOutput {
        frameCount += 1
        let dt = lastTimestampMs.map { min(0.1, max(0, Double(snapshot.timestampMs - $0) / 1000)) } ?? 0
        elapsed += dt
        lastTimestampMs = snapshot.timestampMs
        lastDetectorLatency = snapshot.detectorLatencyMs

        let required = [11, 12, 13, 14, 15, 16, 23, 24, 25, 26, 27, 28]
        let poseReady = snapshot.pose.count >= 33 && required.allSatisfy { index in
            snapshot.pose[index].visibility >= 0.5
        }
        guard poseReady else {
            return output(
                phase: nil,
                captureQC: "cannot_assess_missing_pose",
                cue: "Step into frame so your key joints are visible.",
                cueThai: "ขยับเข้าเฟรมให้เห็นข้อต่อสำคัญชัดขึ้น",
                score: nil,
                poseScore: nil,
                primaryAngle: nil,
                formClass: nil,
                hasPose: false,
            )
        }

        let angles = Dictionary(uniqueKeysWithValues: specs.compactMap { spec -> (String, Float)? in
            guard let value = angle(snapshot.pose[spec.a], snapshot.pose[spec.b], snapshot.pose[spec.c]) else { return nil }
            return (spec.id, value)
        })
        guard let primary = angles[exercise.primaryJoint] else {
            return output(
                phase: nil,
                captureQC: "cannot_assess_missing_primary_joint",
                cue: "Keep the target joint visible.",
                cueThai: "จัดให้ข้อต่อเป้าหมายอยู่ในภาพ",
                score: nil,
                poseScore: nil,
                primaryAngle: nil,
                formClass: nil,
                hasPose: false,
            )
        }
        assessableCount += 1

        let target = Float(exercise.target)
        let tolerance = Float(exercise.tolerance)
        let delta = abs(primary - target)
        let score = Int(max(0, min(100, 100 - (delta / max(1, tolerance * 3)) * 100)).rounded())
        let status = delta <= tolerance ? "ok" : delta <= tolerance * 2 ? "warn" : "bad"
        let formClass = status == "ok" ? "correct" : "undershoot"
        let cue: (String, String)
        if status == "ok" {
            cue = (score >= 92 ? "Great form — keep it up." : "Good form — keep going.", score >= 92 ? "ท่าดีมาก ทำต่อได้เลย" : "ท่าดี ทำต่อได้เลย")
        } else {
            let increase = primary < target
            switch exercise.primaryJoint {
            case "left_elbow": cue = increase ? ("Straighten your left elbow a little more.", "เหยียดศอกซ้ายเพิ่มอีกเล็กน้อย") : ("Bend your left elbow a little more.", "งอศอกซ้ายเพิ่มอีกเล็กน้อย")
            case "right_elbow": cue = increase ? ("Straighten your right elbow a little more.", "เหยียดศอกขวาเพิ่มอีกเล็กน้อย") : ("Bend your right elbow a little more.", "งอศอกขวาเพิ่มอีกเล็กน้อย")
            case "left_shoulder": cue = increase ? ("Raise your left arm a little higher.", "ยกแขนซ้ายให้สูงขึ้นอีกเล็กน้อย") : ("Lower your left arm a little.", "ลดแขนซ้ายลงเล็กน้อย")
            case "right_shoulder": cue = increase ? ("Raise your right arm a little higher.", "ยกแขนขวาให้สูงขึ้นอีกเล็กน้อย") : ("Lower your right arm a little.", "ลดแขนขวาลงเล็กน้อย")
            case "left_knee": cue = increase ? ("Straighten your left knee a little more.", "เหยียดเข่าซ้ายเพิ่มอีกเล็กน้อย") : ("Bend your left knee a little more.", "งอเข่าซ้ายเพิ่มอีกเล็กน้อย")
            case "right_knee": cue = increase ? ("Straighten your right knee a little more.", "เหยียดเข่าขวาเพิ่มอีกเล็กน้อย") : ("Bend your right knee a little more.", "งอเข่าขวาเพิ่มอีกเล็กน้อย")
            default: cue = ("Adjust your position slightly.", "ปรับท่าอีกเล็กน้อย")
            }
        }

        let atPeak = exercise.direction == "down"
            ? primary <= target + tolerance
            : primary >= target - tolerance
        let atRest = exercise.direction == "down"
            ? primary >= Float(exercise.rest - exercise.tolerance * 0.4)
            : primary <= Float(exercise.rest + exercise.tolerance * 0.4)
        let dwell = min(max(exercise.holdSec, 0.1), 0.45)
        if exercise.type == "hold" {
            if atPeak { peakHold += dt }
            if peakHold >= exercise.holdSec {
                completeRep()
                peakHold = 0
            }
        } else if phase == "rest" {
            peakHold = atPeak ? peakHold + 0.033 : 0
            if peakHold >= dwell { phase = "peak" }
        } else if atRest {
            completeRep()
            phase = "rest"
            peakHold = 0
        }

        return output(
            phase: phase,
            captureQC: "can_assess",
            cue: cue.0,
            cueThai: cue.1,
            score: score,
            poseScore: score,
            primaryAngle: primary,
            targetAngle: target,
            formClass: formClass,
            hasPose: true,
            finished: setsDone >= exercise.sets,
            experimental: false,
        )
    }

    private func completeRep() {
        guard setsDone < exercise.sets else { return }
        repsInSet += 1
        if repsInSet >= exercise.reps {
            setsDone += 1
            repsInSet = 0
        }
    }

    private func output(
        phase: String?,
        captureQC: String,
        cue: String?,
        cueThai: String?,
        score: Int?,
        poseScore: Int?,
        primaryAngle: Float?,
        targetAngle: Float? = nil,
        formClass: String?,
        hasPose: Bool,
        finished: Bool = false,
        experimental: Bool = false,
    ) -> NativeBottleGrabOutput {
        let output = NativeBottleGrabOutput(
            phase: phase,
            captureQC: captureQC,
            cue: cue,
            cueThai: cueThai,
            bufferedFrames: frameCount,
            assessableFrames: assessableCount,
            posePoints: hasPose ? 33 : 0,
            handPoints: 0,
            handSide: nil,
            detectorLatencyMs: lastDetectorLatency,
            modelStatus: "native_static_angle_comparator",
            score: score,
            poseScore: poseScore,
            primaryAngle: primaryAngle,
            targetAngle: targetAngle,
            reps: repsInSet,
            repsTarget: exercise.reps,
            setsDone: setsDone,
            totalSets: exercise.sets,
            formClass: formClass,
            hasPose: hasPose,
            finished: finished,
            experimental: experimental,
        )
        lastOutput = output
        return output
    }

    private func angle(_ a: NativeLandmark, _ b: NativeLandmark, _ c: NativeLandmark) -> Float? {
        let v1x = a.x - b.x
        let v1y = a.y - b.y
        let v2x = c.x - b.x
        let v2y = c.y - b.y
        let denominator = sqrt((v1x * v1x + v1y * v1y) * (v2x * v2x + v2y * v2y))
        guard denominator > 0.00001 else { return nil }
        let dot = v1x * v2x + v1y * v2y
        let cross = abs(v1x * v2y - v1y * v2x)
        return atan2(cross, dot) * 180 / .pi
    }
}

/// Dispatches a camera frame to the correct native exercise adapter while
/// keeping the SwiftUI surface independent from model-specific types.
final class NativeExerciseEngine {
    private let bottle: NativeBottleGrabEngine
    private let statics = NativeStaticExerciseEngine()
    private var activeID = NativeBottleGrabEngine.exerciseID

    init(counterMode: NativeBottleGrabCounterMode = .phaseNetFullCycle) {
        bottle = NativeBottleGrabEngine(counterMode: counterMode)
    }

    func configure(exercise: NativeExercise) {
        activeID = exercise.id
        if exercise.id == NativeBottleGrabEngine.exerciseID { bottle.configure(exercise: exercise) }
        else { statics.configure(exercise: exercise) }
    }

    func reset() {
        if activeID == NativeBottleGrabEngine.exerciseID { bottle.reset() }
        else { statics.reset() }
    }

    func setCountingEnabled(_ enabled: Bool) {
        guard activeID == NativeBottleGrabEngine.exerciseID else { return }
        bottle.setCountingEnabled(enabled)
    }

    func resetForNewCaptureSource() {
        if activeID == NativeBottleGrabEngine.exerciseID {
            bottle.resetForNewCaptureSource()
        } else {
            statics.reset()
        }
    }

    func ingest(_ snapshot: NativeFrameSnapshot) -> NativeBottleGrabOutput {
        activeID == NativeBottleGrabEngine.exerciseID ? bottle.ingest(snapshot) : statics.ingest(snapshot)
    }
}
