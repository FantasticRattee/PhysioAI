import { jointAngleCalculatorDetailed } from '../ai/JointAngleCalculator.js';
import { evaluateBoundaryBox } from '../ai/BoundaryBoxGate.js';
import { createAiPhaseRepCounter } from '../ai/RepCounter.js';
import { overlayJointsForExercise } from '../core/patient-exercises.js';
import { calculateExerciseFrameMetrics } from '../../exercise-modules/runtime-registry.js';

const NATIVE_AI_PREDICTION_TIMEOUT_MS = 2_500;

function promiseWithTimeout(promise, timeoutMs, timeoutValue = null) {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) return promise;
  let timeoutId;
  const timeout = new Promise((resolve) => {
    timeoutId = setTimeout(() => resolve(timeoutValue), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timeoutId));
}

export function ghostLandmarksForSnapshot(reference, snapshot) {
  if (!reference) return null;
  if (snapshot?.activeSide && reference.targetLandmarksBySide?.[snapshot.activeSide]) {
    return reference.targetLandmarksBySide[snapshot.activeSide];
  }
  return reference.holdTargetLandmarks || reference.targetLandmarks || reference.landmarks || null;
}

export function createPracticeFrameProcessor({
  exercise = {},
  reference = null,
  motionEngine = null,
  motionClassifier = null,
  hybridDecisionEngine = null,
  classifierWindowSize = 30,
  classifierInferenceIntervalMs = 0,
  classifierOptions = {},
  predictionTimeoutMs = 0,
  aiRepCounter = createAiPhaseRepCounter({
    minConfidence: classifierOptions.minConfidence ?? 0.75,
  }),
  overlayJoints = null,
  timestampNow = () => (globalThis.performance?.now ? globalThis.performance.now() : Date.now()),
} = {}) {
  let classifierWindow = [];
  let lastClassifierInferenceAt = null;
  let lastAiSignal = null;
  let lastInferenceMs = null;
  const inferenceIntervalMs = Math.max(0, Number(classifierInferenceIntervalMs) || 0);
  const resolvedWindowSize = Math.max(1, Number(classifierWindowSize) || 1);

  function resetClassifierWindow() {
    classifierWindow = [];
    lastClassifierInferenceAt = null;
    lastAiSignal = null;
    lastInferenceMs = null;
  }

  function aiPerformance({ inferenceFresh = false } = {}) {
    return {
      inferenceMs: lastInferenceMs,
      inferenceFresh,
      inferenceIntervalMs,
      targetHz: inferenceIntervalMs > 0 ? 1000 / inferenceIntervalMs : null,
      windowFrames: classifierWindow.length,
      windowSize: resolvedWindowSize,
    };
  }

  function noPoseResult(nextBoundary, selectedOverlayJoints) {
    return {
      hasPose: false,
      boundary: nextBoundary,
      nextBoundaryFrame: nextBoundary?.nextFrame || null,
      liveAngles: null,
      snapshot: null,
      overlayJoints: selectedOverlayJoints,
      ghostLandmarks: null,
      aiSignal: null,
    };
  }

  function preparePracticeFrame({
    landmarks = null,
    previousBoundaryFrame = null,
    boundary = null,
    liveAngles: inputLiveAngles = null,
    angleMeta: inputAngleMeta = null,
    timestamp = timestampNow(),
  } = {}) {
    const nextBoundary = boundary || evaluateBoundaryBox(landmarks, previousBoundaryFrame, exercise, timestamp);
    const selectedOverlayJoints = overlayJoints || overlayJointsForExercise({ ...exercise, reference });

    if (!landmarks) {
      resetClassifierWindow();
      return {
        ...noPoseResult(nextBoundary, selectedOverlayJoints),
        aiPerformance: aiPerformance(),
      };
    }

    const angleResult = inputLiveAngles
      ? { angles: inputLiveAngles, meta: inputAngleMeta }
      : jointAngleCalculatorDetailed(landmarks, {
        minVisibility: exercise.minVisibility,
        use3D: exercise.allow3D,
      });
    const exerciseMetrics = inputLiveAngles ? null : calculateExerciseFrameMetrics(exercise, landmarks, {
      minVisibility: exercise.minVisibility,
    });
    const liveAngles = {
      ...angleResult.angles,
      ...(exerciseMetrics?.jointAngles || {}),
    };
    const angleMeta = exerciseMetrics
      ? { ...angleResult.meta, exerciseMetrics }
      : angleResult.meta;
    return {
      hasPose: true,
      timestamp,
      landmarks,
      boundary: nextBoundary,
      nextBoundaryFrame: nextBoundary?.nextFrame || null,
      liveAngles,
      angleMeta,
      overlayJoints: selectedOverlayJoints,
    };
  }

  function commitPracticeFrame(
    prepared,
    aiSignal = null,
    aiRepSnapshot = null,
    hybridDecision = null,
    performance = null,
  ) {
    if (!prepared?.hasPose) return prepared;
    const aiStatus = motionClassifier?.getStatus?.() || null;
    const snapshot = motionEngine
      ? motionEngine.pushFrame({
        timestamp: prepared.timestamp,
        landmarks: prepared.landmarks,
        jointAngles: prepared.liveAngles,
        angleMeta: prepared.angleMeta,
        boundary: prepared.boundary,
        aiSignal,
        aiRepSnapshot,
      })
      : null;
    // When there is no reference-based motion engine (for example the
    // validation-only Patient trial), promote the active decision engine to
    // the primary snapshot. Previously we only attached hybridDecision as
    // metadata, leaving top-level phase/reps undefined for the UI.
    const primarySnapshot = snapshot || hybridDecision || aiRepSnapshot || aiSignal;
    const nextSnapshot = primarySnapshot
      ? {
        ...primarySnapshot,
        liveAngles: prepared.liveAngles,
        ...(aiSignal ? { aiSignal } : {}),
        ...(aiStatus ? { aiStatus } : {}),
        ...(aiRepSnapshot ? {
          aiRepCounter: aiRepSnapshot,
          aiRepCount: aiRepSnapshot.reps,
          aiCompletedRep: aiRepSnapshot.completedRep || null,
        } : {}),
        ...(hybridDecision ? {
          hybridDecision,
          hybridRepCount: hybridDecision.reps,
          hybridCompletedRep: hybridDecision.completedRep || null,
        } : {}),
        ...(performance ? { aiPerformance: performance } : {}),
      }
      : null;

    return {
      hasPose: true,
      boundary: prepared.boundary,
      nextBoundaryFrame: prepared.nextBoundaryFrame,
      liveAngles: prepared.liveAngles,
      angleMeta: prepared.angleMeta,
      snapshot: nextSnapshot,
      overlayJoints: prepared.overlayJoints,
      ghostLandmarks: ghostLandmarksForSnapshot(reference, nextSnapshot),
      aiSignal,
      aiStatus,
      hybridDecision,
      aiPerformance: performance,
    };
  }

  function processPracticeFrame(args = {}) {
    const prepared = preparePracticeFrame(args);
    const aiSignal = args.aiSignal || null;
    const hybridDecision = prepared.hasPose ? hybridDecisionEngine?.push?.({
      timestamp: prepared.timestamp,
      jointAngles: prepared.liveAngles,
      boundary: prepared.boundary,
      aiSignal,
      aiStatus: motionClassifier?.getStatus?.() || null,
    }) || null : null;
    return commitPracticeFrame(prepared, aiSignal, null, hybridDecision, aiPerformance());
  }

  async function processPracticeFrameWithAi(args = {}) {
    const prepared = preparePracticeFrame(args);
    if (!prepared.hasPose) {
      aiRepCounter?.reset?.();
      const aiStatus = motionClassifier?.getStatus?.() || null;
      const hybridDecision = hybridDecisionEngine?.push?.({
        timestamp: args.timestamp ?? timestampNow(),
        jointAngles: {},
        boundary: prepared.boundary,
        aiSignal: null,
        aiStatus,
      }) || null;
      return {
        ...prepared,
        snapshot: hybridDecision ? {
          hybridDecision,
          hybridRepCount: hybridDecision.reps,
          hybridCompletedRep: null,
        } : null,
        aiStatus,
        hybridDecision,
      };
    }
    let aiSignal = args.aiSignal || null;
    const suppliedAiSignal = !!aiSignal;
    const safetyOk = prepared.boundary?.scoreable !== false && prepared.boundary?.trainable !== false;
    let aiRepSnapshot = null;
    let inferenceFresh = suppliedAiSignal;
    if (!safetyOk) {
      aiSignal = null;
      resetClassifierWindow();
      aiRepSnapshot = aiRepCounter?.push?.({
        safetyOk: false,
        timestamp: prepared.timestamp,
      }) || null;
    } else if (!aiSignal && typeof motionClassifier?.predict === 'function') {
      classifierWindow.push({
        t: prepared.timestamp,
        timestamp: prepared.timestamp,
        landmarks: prepared.landmarks,
        jointAngles: prepared.liveAngles,
        angles: prepared.liveAngles,
        boundaryStatus: prepared.boundary?.status || 'unknown',
        landmarkSchemaId: prepared.boundary?.landmarkSchemaId || exercise.landmarkSchemaId,
        dataQuality: prepared.boundary?.dataQuality || null,
      });
      classifierWindow = classifierWindow.slice(-resolvedWindowSize);
      const inferenceDue = lastClassifierInferenceAt == null
        || inferenceIntervalMs <= 0
        || prepared.timestamp - lastClassifierInferenceAt >= Math.max(0, inferenceIntervalMs - 1);
      if (inferenceDue) {
        const inferenceStartedAt = timestampNow();
        const prediction = motionClassifier.predict(classifierWindow.slice(), {
          exercise,
          landmarkSchemaId: prepared.boundary?.landmarkSchemaId || exercise.landmarkSchemaId,
          ...classifierOptions,
        }).catch(() => null);
        // A failed model fetch or WebKit backend must never hold the first
        // native frame forever. Release the scoring pipeline so the UI and
        // deterministic safety rules keep updating while the model recovers.
        aiSignal = await promiseWithTimeout(
          prediction,
          predictionTimeoutMs,
          null,
        );
        lastInferenceMs = Math.max(0, timestampNow() - inferenceStartedAt);
        lastClassifierInferenceAt = prepared.timestamp;
        lastAiSignal = aiSignal;
        inferenceFresh = true;
      } else {
        aiSignal = lastAiSignal;
      }
    }
    if (!aiRepSnapshot && aiSignal && inferenceFresh) {
      aiRepSnapshot = aiRepCounter?.push?.({
        phase: aiSignal.phase,
        quality: aiSignal.quality,
        confidence: aiSignal.confidence,
        safetyOk,
        timestamp: prepared.timestamp,
      }) || null;
    } else if (!aiRepSnapshot) {
      aiRepSnapshot = aiRepCounter?.getSnapshot?.() || null;
    }
    const hybridDecision = hybridDecisionEngine?.push?.({
      timestamp: prepared.timestamp,
      jointAngles: prepared.liveAngles,
      boundary: prepared.boundary,
      aiSignal,
      aiStatus: motionClassifier?.getStatus?.() || null,
    }) || null;
    return commitPracticeFrame(
      prepared,
      aiSignal,
      aiRepSnapshot,
      hybridDecision,
      aiPerformance({ inferenceFresh }),
    );
  }

  function resetAiWindow() {
    resetClassifierWindow();
    motionClassifier?.reset?.();
    aiRepCounter?.reset?.();
    hybridDecisionEngine?.reset?.();
  }

  function interruptAiWindow() {
    resetClassifierWindow();
    motionClassifier?.reset?.();
    hybridDecisionEngine?.interrupt?.();
  }

  return {
    exercise,
    reference,
    motionEngine,
    hybridDecisionEngine,
    processPracticeFrame,
    processPracticeFrameWithAi,
    resetAiWindow,
    interruptAiWindow,
  };
}
