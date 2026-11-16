import { resolveDynamicWeightShiftsExercise } from '../runtime/rules.js';
import { buildDynamicWeightShiftsTrainingPlan } from './pipeline.mjs';

export const dynamicWeightShiftsTrainingProfile = Object.freeze({
  id: 'dynamic_weight_shifts',
  protectedRunIds: Object.freeze(['left-tcn-v3']),
  exerciseId: 'cust_dynamic_weight_shifts',
  aliases: Object.freeze([
    'dynamic-weight-shifts',
    'cust_dynamic_weight_shifts',
  ]),
  resolveExercise: resolveDynamicWeightShiftsExercise,
  buildTrainingPlan: buildDynamicWeightShiftsTrainingPlan,
  architecture: Object.freeze({
    id: 'dynamic_weight_shifts_tcn.v3',
    version: 3,
    trainer: 'exercise-modules/dynamic_weight_shifts/training/train.py',
  }),
  paths: Object.freeze({
    exerciseDir: 'data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts',
    exercise: 'data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/exercise.json',
    dataset: 'data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/datasets',
    trainingRuns: 'data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/training_runs',
    publishedModels: 'shared/models',
  }),
  features: Object.freeze({
    windowSize: 30,
    stride: 5,
    phasePurityThreshold: 0.7,
  }),
  trainer: Object.freeze({
    epochs: 50,
    batchSize: 32,
    filters: 24,
    dropout: 0.05,
    patience: 8,
    phaseLossWeight: 0.05,
    qualityLossWeight: 1,
    classBalancePower: 0.7,
    outsideBoundaryMultiplier: 2,
    learningRate: 0.002,
    seed: 1337,
    deterministic: true,
  }),
  evaluation: Object.freeze({
    split: 'test',
    fps: 10,
    qualityDecisionThreshold: 0.5,
  }),
  prototypeOnly: true,
});

export default dynamicWeightShiftsTrainingProfile;
