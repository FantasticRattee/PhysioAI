import { createHybridTargetDecisionEngine, resolveHybridTargetConfig } from '../shared/ai/HybridTargetDecisionEngine.js';
import { lateralArmRaiseLeftRuntimeModule } from './lateral_arm_raise_left/runtime/index.js';
import { lateralArmRaiseRuntimeModule } from './lateral_arm_raise/runtime/index.js';
import { dynamicWeightShiftsRuntimeModule } from './dynamic_weight_shifts/runtime/index.js';

const RUNTIME_MODULES = Object.freeze([
  lateralArmRaiseRuntimeModule,
  lateralArmRaiseLeftRuntimeModule,
  dynamicWeightShiftsRuntimeModule,
]);

function normalizedToken(value) {
  return String(value || '').trim().toLowerCase();
}

export function listExerciseRuntimeModules() {
  return [...RUNTIME_MODULES];
}

export function resolveExerciseRuntimeModule(exerciseOrId = {}) {
  const exercise = typeof exerciseOrId === 'string'
    ? { id: exerciseOrId }
    : exerciseOrId || {};
  const tokens = new Set([
    exercise.id,
    exercise.key,
    exercise.slug,
    exercise.label,
    exercise.labelTh,
    exercise.moduleId,
    exercise.exerciseModuleId,
  ].map(normalizedToken).filter(Boolean));
  return RUNTIME_MODULES.find((module) => module.matches({ exercise, tokens })) || null;
}

export function resolveExerciseRuntime(exercise = {}) {
  const module = resolveExerciseRuntimeModule(exercise);
  return module?.resolveExercise
    ? module.resolveExercise(exercise)
    : exercise;
}

export function resolveExerciseTargetConfig(exercise = {}, overrides = {}) {
  const module = resolveExerciseRuntimeModule(exercise);
  if (module?.resolveTargetConfig) return module.resolveTargetConfig(exercise, overrides);
  return resolveHybridTargetConfig(exercise, overrides);
}

export function createExerciseTargetDecisionEngine({ exercise = {}, ...overrides } = {}) {
  const module = resolveExerciseRuntimeModule(exercise);
  if (module?.createDecisionEngine) {
    return module.createDecisionEngine({ exercise, ...overrides });
  }
  return createHybridTargetDecisionEngine({ exercise, ...overrides });
}

export function createExerciseSessionAnalyzer({ exercise = {}, ...overrides } = {}) {
  const module = resolveExerciseRuntimeModule(exercise);
  if (typeof module?.createSessionAnalyzer !== 'function') return null;
  return module.createSessionAnalyzer({
    exercise: resolveExerciseRuntime(exercise),
    ...overrides,
  });
}

export function calculateExerciseFrameMetrics(exercise = {}, landmarks = [], options = {}) {
  const module = resolveExerciseRuntimeModule(exercise);
  if (typeof module?.frameMetrics !== 'function') return null;
  return module.frameMetrics(landmarks, {
    exercise: resolveExerciseRuntime(exercise),
    ...options,
  });
}
