import {
  createHybridTargetDecisionEngine,
  resolveHybridTargetConfig,
} from '../../../shared/ai/HybridTargetDecisionEngine.js';

export const LATERAL_ARM_RAISE_LEFT_TARGET_POLICY = Object.freeze({
  version: 'multi_joint_trajectory_reach.v4',
  joint: 'left_shoulder',
  phase: 'target',
  aggregate: 'hold',
  comparator: 'gte',
  reachedTargetMinDeg: 70,
  restResetDeg: 30,
  requiredJointRules: Object.freeze([
    Object.freeze({
      joint: 'left_elbow',
      comparator: 'gte',
      reachedTargetMinDeg: 150,
      enforceDuringPhases: Object.freeze(['moving_to_target', 'target']),
      smoothingWindowMs: 100,
      restBaselineWindowMs: 600,
      restBaselineMinSamples: 5,
      maxDeviationFromRestDeg: 22,
      adaptiveThresholdMinDeg: 145,
      adaptiveThresholdMaxDeg: 150,
      violationWindowMs: 450,
      maxViolationRatio: 0.55,
      violationGraceMs: 350,
      hardMinDeg: 145,
      hardViolationGraceMs: 250,
    }),
  ]),
});

export const LATERAL_ARM_RAISE_LEFT_DECISION_DEFAULTS = Object.freeze({
  minAiConfidence: 0.5,
  targetHoldMs: 300,
  fallbackHoldMs: 300,
  disagreementHoldMs: 800,
  restHoldMs: 180,
  hysteresisDeg: 5,
  anglePrecisionDeg: 0.1,
});

function cloneTargetPolicy() {
  return {
    ...LATERAL_ARM_RAISE_LEFT_TARGET_POLICY,
    requiredJointRules: LATERAL_ARM_RAISE_LEFT_TARGET_POLICY.requiredJointRules.map((rule) => ({
      ...rule,
      enforceDuringPhases: [...rule.enforceDuringPhases],
    })),
  };
}

export function resolveLateralArmRaiseLeftExercise(exercise = {}) {
  return {
    ...exercise,
    exerciseModuleId: 'lateral_arm_raise_left',
    trainingProfileId: 'lateral_arm_raise_left',
    modelArchitectureId: 'lateral_arm_raise_left_tcn.v1',
    modelArchitectureVersion: 1,
    primaryJoint: 'left_shoulder',
    cameraView: 'front',
    cameraOrientation: 'front',
    cameraSide: 'any',
    bodyRegion: 'left_arm',
    landmarkSchemaId: 'left_arm.v1',
    targetOutcomePolicy: cloneTargetPolicy(),
  };
}

export function resolveLateralArmRaiseLeftTargetConfig(exercise = {}, overrides = {}) {
  return resolveHybridTargetConfig(resolveLateralArmRaiseLeftExercise(exercise), {
    ...LATERAL_ARM_RAISE_LEFT_DECISION_DEFAULTS,
    ...overrides,
  });
}

export function createLateralArmRaiseLeftDecisionEngine({ exercise = {}, ...overrides } = {}) {
  return createHybridTargetDecisionEngine({
    exercise: resolveLateralArmRaiseLeftExercise(exercise),
    ...LATERAL_ARM_RAISE_LEFT_DECISION_DEFAULTS,
    ...overrides,
  });
}
