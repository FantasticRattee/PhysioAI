import { resolveDynamicWeightShiftsExercise } from '../runtime/rules.js';
import { buildDynamicWeightShiftsTrainingPlan } from './pipeline.mjs';

function resolveDynamicWeightShiftsLeftExercise(exercise = {}) {
  return {
    ...resolveDynamicWeightShiftsExercise(exercise),
    trainingProfileId: 'dynamic_weight_shifts_left',
    modelArchitectureId: 'dynamic_weight_shifts_left_tcn.v1',
    modelArchitectureVersion: 1,
  };
}

export const dynamicWeightShiftsLeftTrainingProfile = Object.freeze({
  id: 'dynamic_weight_shifts_left',
  protectedRunIds: Object.freeze(['left-tcn-v3']),
  exerciseId: 'cust_dynamic_weight_shifts',
  aliases: Object.freeze([
    'dynamic-weight-shifts-left',
    'cust_dynamic_weight_shifts_left',
  ]),
  resolveExercise: resolveDynamicWeightShiftsLeftExercise,
  buildTrainingPlan: buildDynamicWeightShiftsTrainingPlan,
  architecture: Object.freeze({
    id: 'dynamic_weight_shifts_left_tcn.v1',
    version: 1,
    trainer: 'exercise-modules/dynamic_weight_shifts/training/train_left.py',
  }),
  paths: Object.freeze({
    exerciseDir: 'data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts',
    exercise: 'data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/exercise.json',
    dataset: 'data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/datasets',
    trainingRuns: 'data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/training_runs',
    publishedModels: 'shared/models',
  }),
  features: Object.freeze({
    direction: 'left',
    windowSize: 30,
    stride: 2,
    phasePurityThreshold: 0.8,
  }),
  trainer: Object.freeze({
    epochs: 80,
    batchSize: 32,
    filters: 24,
    dropout: 0.1,
    patience: 12,
    phaseLossWeight: 1,
    qualityLossWeight: 1,
    classBalancePower: 0.7,
    outsideBoundaryMultiplier: 1,
    learningRate: 0.001,
    seed: 1337,
    deterministic: true,
  }),
  evaluation: Object.freeze({
    split: 'test',
    fps: 10,
    qualityDecisionThreshold: 0.5,
  }),
  validationCandidateExport: true,
  prototypeOnly: true,
});

export default dynamicWeightShiftsLeftTrainingProfile;
