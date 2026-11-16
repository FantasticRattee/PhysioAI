import {
  createDynamicWeightShiftsDecisionEngine,
  DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS,
  DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY,
  resolveDynamicWeightShiftsExercise,
  resolveDynamicWeightShiftsTargetConfig,
} from './rules.js';
import { dynamicWeightShiftMetrics } from './metrics.js';
import {
  createDynamicWeightShiftsSessionAnalyzer,
  DYNAMIC_WEIGHT_SHIFTS_SESSION_ANALYSIS_POLICY,
} from './session-analyzer.js';

const MATCH_TOKENS = new Set([
  'dynamic_weight_shifts',
  'dynamic-weight-shifts',
  'cust_dynamic_weight_shifts',
]);

export const dynamicWeightShiftsRuntimeModule = Object.freeze({
  id: 'dynamic_weight_shifts',
  exerciseIds: Object.freeze(['cust_dynamic_weight_shifts']),
  matches({ exercise = {}, tokens = new Set() } = {}) {
    if ([...tokens].some((token) => MATCH_TOKENS.has(token))) return true;
    return String(exercise.activeModelId || '').startsWith('cust_dynamic_weight_shifts-');
  },
  resolveExercise: resolveDynamicWeightShiftsExercise,
  resolveTargetConfig: resolveDynamicWeightShiftsTargetConfig,
  createDecisionEngine: createDynamicWeightShiftsDecisionEngine,
  createSessionAnalyzer: createDynamicWeightShiftsSessionAnalyzer,
  frameMetrics: dynamicWeightShiftMetrics,
  targetPolicy: DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY,
  decisionDefaults: DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS,
  sessionAnalysisPolicy: DYNAMIC_WEIGHT_SHIFTS_SESSION_ANALYSIS_POLICY,
});

export {
  createDynamicWeightShiftsDecisionEngine,
  createDynamicWeightShiftsSessionAnalyzer,
  DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS,
  DYNAMIC_WEIGHT_SHIFTS_SESSION_ANALYSIS_POLICY,
  DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY,
  dynamicWeightShiftMetrics,
  resolveDynamicWeightShiftsExercise,
  resolveDynamicWeightShiftsTargetConfig,
};
