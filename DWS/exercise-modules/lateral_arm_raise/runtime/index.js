import {
  createLateralArmRaiseDecisionEngine,
  LATERAL_ARM_RAISE_DECISION_DEFAULTS,
  LATERAL_ARM_RAISE_TARGET_POLICY,
  resolveLateralArmRaiseExercise,
  resolveLateralArmRaiseTargetConfig,
} from './rules.js';
import {
  createLateralArmRaiseSessionAnalyzer,
  LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY,
} from './session-analyzer.js';

const MATCH_TOKENS = new Set([
  'lateral_arm_raise',
  'lateral_arm_raise_right',
  'lateral-arm-raise',
  'cust_mrhhkile',
]);

export const lateralArmRaiseRuntimeModule = Object.freeze({
  id: 'lateral_arm_raise',
  exerciseIds: Object.freeze(['cust_mrhhkile']),
  matches({ exercise = {}, tokens = new Set() } = {}) {
    if ([...tokens].some((token) => MATCH_TOKENS.has(token))) return true;
    return String(exercise.activeModelId || '').startsWith('cust_mrhhkile-');
  },
  resolveExercise: resolveLateralArmRaiseExercise,
  resolveTargetConfig: resolveLateralArmRaiseTargetConfig,
  createDecisionEngine: createLateralArmRaiseDecisionEngine,
  createSessionAnalyzer: createLateralArmRaiseSessionAnalyzer,
  targetPolicy: LATERAL_ARM_RAISE_TARGET_POLICY,
  decisionDefaults: LATERAL_ARM_RAISE_DECISION_DEFAULTS,
  sessionAnalysisPolicy: LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY,
});

export {
  createLateralArmRaiseDecisionEngine,
  createLateralArmRaiseSessionAnalyzer,
  LATERAL_ARM_RAISE_DECISION_DEFAULTS,
  LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY,
  LATERAL_ARM_RAISE_TARGET_POLICY,
  resolveLateralArmRaiseExercise,
  resolveLateralArmRaiseTargetConfig,
};
