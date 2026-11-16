import {
  createHybridTargetDecisionEngine,
  resolveHybridTargetConfig,
} from '../../../shared/ai/HybridTargetDecisionEngine.js';

export const DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY = Object.freeze({
  version: 'seated_lateral_shift.v1',
  joint: 'trunk_shift',
  phase: 'target',
  aggregate: 'hold',
  comparator: 'gt',
  reachedTargetMinDeg: 8,
  // The runtime displays torso lean from the camera's vertical axis. Treat
  // exactly eight degrees as Rest and start Target only above eight degrees.
  restResetDeg: 8,
  // Device testing showed that 11.5 degrees resets otherwise usable holds when
  // natural shoulder motion and landmark jitter briefly overlap. Fifteen
  // degrees keeps the rule as a safety veto without making it the dominant
  // reason a patient cannot complete the exercise.
  requiredJointRules: Object.freeze([
    Object.freeze({
      joint: 'shoulder_tilt',
      comparator: 'lte',
      reachedTargetMaxDeg: 15,
    }),
  ]),
});

export const DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS = Object.freeze({
  minAiConfidence: 0.5,
  // DWS must remain continuously at Target for five seconds before counting,
  // including AI, fallback, and disagreement paths.
  targetHoldMs: 5000,
  fallbackHoldMs: 5000,
  disagreementHoldMs: 5000,
  restHoldMs: 180,
  hysteresisDeg: 0,
  anglePrecisionDeg: 0.1,
  targetStabilityToleranceDeg: null,
  requireAiConfirmation: false,
});

function cloneTargetPolicy() {
  return {
    ...DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY,
    requiredJointRules: DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY.requiredJointRules.map((rule) => ({ ...rule })),
  };
}

export function resolveDynamicWeightShiftsExercise(exercise = {}) {
  return {
    ...exercise,
    exerciseModuleId: 'dynamic_weight_shifts',
    trainingProfileId: 'dynamic_weight_shifts',
    modelArchitectureId: 'dynamic_weight_shifts_tcn.v3',
    modelArchitectureVersion: 3,
    primaryJoint: 'trunk_shift',
    cameraView: 'front',
    cameraOrientation: 'front',
    cameraSide: 'any',
    bodyRegion: 'seated_balance',
    landmarkSchemaId: 'seated_balance.v2',
    targetOutcomePolicy: cloneTargetPolicy(),
    targetHoldMs: exercise.targetHoldMs ?? DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS.targetHoldMs,
    fallbackHoldMs: exercise.fallbackHoldMs ?? DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS.fallbackHoldMs,
    disagreementHoldMs: exercise.disagreementHoldMs ?? DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS.disagreementHoldMs,
    restHoldMs: exercise.restHoldMs ?? DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS.restHoldMs,
    minAiConfidence: exercise.minAiConfidence ?? DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS.minAiConfidence,
    targetStabilityToleranceDeg: exercise.targetStabilityToleranceDeg
      ?? DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS.targetStabilityToleranceDeg,
  };
}

export function resolveDynamicWeightShiftsTargetConfig(exercise = {}, overrides = {}) {
  return resolveHybridTargetConfig(resolveDynamicWeightShiftsExercise(exercise), {
    ...DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS,
    ...overrides,
  });
}

export function createDynamicWeightShiftsDecisionEngine({ exercise = {}, ...overrides } = {}) {
  const base = createHybridTargetDecisionEngine({
    exercise: resolveDynamicWeightShiftsExercise(exercise),
    ...DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS,
    ...overrides,
  });
  let completedReps = 0;
  let pendingTarget = null;

  function withCenterReturn(snapshot) {
    let completedRep = null;
    if (snapshot?.completedRep) {
      completedReps = Math.max(completedReps + 1, Number(snapshot.reps) || 0);
      pendingTarget = {
        ...snapshot.completedRep,
        index: completedReps,
        returnedToCenter: false,
      };
      // Target confirmation is the rep completion. Returning to center only
      // re-arms the next rep and must not delay the visible rep count.
      completedRep = pendingTarget;
    }
    const returnedToCenter = pendingTarget &&
      snapshot?.state === 'rest' &&
      Number.isFinite(snapshot?.targetAngle) &&
      snapshot.targetAngle <= base.config.resetThreshold;
    if (returnedToCenter) {
      pendingTarget = null;
    }
    if (snapshot?.state === 'blocked') pendingTarget = null;
    return {
      ...snapshot,
      reps: completedReps,
      completedRep,
      pendingCenterReturn: Boolean(pendingTarget),
      returnedToCenter: Boolean(returnedToCenter),
      reason: returnedToCenter ? 'completed_center_target_center' : snapshot.reason,
    };
  }

  return {
    config: base.config,
    push(input = {}) {
      const snapshot = base.push(input);
      return withCenterReturn({ ...snapshot, timestamp: Number(input.timestamp ?? Date.now()) });
    },
    reset() {
      base.reset();
      completedReps = 0;
      pendingTarget = null;
    },
    interrupt() {
      base.interrupt();
      pendingTarget = null;
    },
    getSnapshot() {
      return withCenterReturn(base.getSnapshot());
    },
  };
}
