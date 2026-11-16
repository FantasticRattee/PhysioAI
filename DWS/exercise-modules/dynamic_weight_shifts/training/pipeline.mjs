import { exerciseTrainingRunPaths } from '../../training/runner.mjs';

function numberArg(args, name, value) {
  args.push(name, String(value));
}

export function buildDynamicWeightShiftsTrainingPlan(profile, {
  runId,
  modelId = null,
  python = 'python3',
} = {}) {
  const paths = exerciseTrainingRunPaths(profile, runId, modelId);
  const features = profile.features;
  const trainer = profile.trainer;
  const evaluation = profile.evaluation;
  const featureArgs = [
    'exercise-modules/dynamic_weight_shifts/training/build_features.mjs',
    '--input', profile.paths.dataset,
    '--exercise', paths.exercise,
    '--out', paths.features,
  ];
  numberArg(featureArgs, '--window-size', features.windowSize);
  numberArg(featureArgs, '--stride', features.stride);
  numberArg(featureArgs, '--phase-purity-threshold', features.phasePurityThreshold);
  if (features.direction) featureArgs.push('--direction', features.direction);

  const trainArgs = [
    profile.architecture.trainer,
    '--features', paths.features,
    '--out', paths.kerasModel,
  ];
  for (const [name, value] of [
    ['--epochs', trainer.epochs],
    ['--batch-size', trainer.batchSize],
    ['--filters', trainer.filters],
    ['--dropout', trainer.dropout],
    ['--patience', trainer.patience],
    ['--phase-loss-weight', trainer.phaseLossWeight],
    ['--quality-loss-weight', trainer.qualityLossWeight],
    ['--class-balance-power', trainer.classBalancePower],
    ['--outside-boundary-multiplier', trainer.outsideBoundaryMultiplier],
    ['--learning-rate', trainer.learningRate],
    ['--seed', trainer.seed],
  ]) numberArg(trainArgs, name, value);
  if (trainer.deterministic) trainArgs.push('--deterministic');

  const validationModelOut = profile.validationCandidateExport === true
    ? paths.publishedModel
    : paths.tfjsModel;

  return {
    exerciseModule: profile.id,
    exerciseId: profile.exerciseId,
    paths,
    commands: {
      features: { command: process.execPath, args: featureArgs },
      train: { command: python, args: trainArgs },
      evaluate: {
        command: python,
        args: [
          'training/evaluate_motion_tcn_keras.py',
          '--model', paths.bestKerasModel,
          '--features', paths.features,
          '--out', paths.evaluation,
          '--split', evaluation.split,
          '--quality-decision-threshold', String(evaluation.qualityDecisionThreshold),
        ],
      },
      export: {
        command: python,
        args: [
          'training/export_keras_to_tfjs.py',
          '--model', paths.bestKerasModel,
          '--features', paths.features,
          '--evaluation', paths.evaluation,
          '--out', validationModelOut,
          '--version', paths.modelId,
          '--architecture-id', profile.architecture.id,
          '--architecture-version', String(profile.architecture.version),
          '--validation-only',
        ],
      },
      hybrid: {
        command: process.execPath,
        args: [
          'scripts/evaluate-hybrid-target.mjs',
          '--model', validationModelOut,
          '--features', paths.features,
          '--exercise', paths.exercise,
          '--out', paths.hybridEvaluation,
          '--split', evaluation.split,
          '--fps', String(evaluation.fps),
        ],
      },
      publish: {
        command: process.execPath,
        args: ['exercise-modules/dynamic_weight_shifts/training/block_publish.mjs'],
      },
    },
  };
}
