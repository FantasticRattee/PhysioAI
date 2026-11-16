import {
  createLateralArmRaiseLeftDecisionEngine,
  LATERAL_ARM_RAISE_LEFT_DECISION_DEFAULTS,
  LATERAL_ARM_RAISE_LEFT_TARGET_POLICY,
  resolveLateralArmRaiseLeftExercise,
  resolveLateralArmRaiseLeftTargetConfig,
} from './rules.js';

const MATCH_TOKENS = new Set([
  'lateral_arm_raise_left',
  'lateral-arm-raise-left',
  'left_lateral_arm_raise',
  'cust_lateral_arm_raise_left',
]);

export const lateralArmRaiseLeftRuntimeModule = Object.freeze({
  id: 'lateral_arm_raise_left',
  exerciseIds: Object.freeze(['cust_lateral_arm_raise_left']),
  matches({ exercise = {}, tokens = new Set() } = {}) {
    if ([...tokens].some((token) => MATCH_TOKENS.has(token))) return true;
    return String(exercise.activeModelId || '').startsWith('cust_lateral_arm_raise_left-');
  },
  resolveExercise: resolveLateralArmRaiseLeftExercise,
  resolveTargetConfig: resolveLateralArmRaiseLeftTargetConfig,
  createDecisionEngine: createLateralArmRaiseLeftDecisionEngine,
  targetPolicy: LATERAL_ARM_RAISE_LEFT_TARGET_POLICY,
  decisionDefaults: LATERAL_ARM_RAISE_LEFT_DECISION_DEFAULTS,
});

export {
  createLateralArmRaiseLeftDecisionEngine,
  LATERAL_ARM_RAISE_LEFT_DECISION_DEFAULTS,
  LATERAL_ARM_RAISE_LEFT_TARGET_POLICY,
  resolveLateralArmRaiseLeftExercise,
  resolveLateralArmRaiseLeftTargetConfig,
};
