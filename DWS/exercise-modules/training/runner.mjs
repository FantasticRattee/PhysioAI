import { access, mkdir, readFile, writeFile } from 'node:fs/promises';
import { constants } from 'node:fs';
import { spawn } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const REPO_ROOT = fileURLToPath(new URL('../../', import.meta.url));
const PIPELINE_STAGES = Object.freeze(['features', 'train', 'evaluate', 'export', 'hybrid']);
const VALID_STAGES = new Set(['plan', 'all', 'publish', ...PIPELINE_STAGES]);

function safeRunId(value) {
  const runId = String(value || '').trim();
  if (!runId || !/^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(runId)) {
    throw new Error('--run must use only letters, numbers, dot, underscore, or hyphen');
  }
  return runId;
}

function numberArg(args, name, value) {
  args.push(name, String(value));
}

export function exerciseTrainingRunPaths(profile, runId, modelId = null) {
  const safeId = safeRunId(runId);
  const runDir = path.join(profile.paths.trainingRuns, safeId);
  const resolvedModelId = modelId || `${profile.exerciseId}-${safeId}`;
  return {
    runId: safeId,
    runDir,
    exercise: path.join(runDir, 'exercise.resolved.json'),
    features: path.join(runDir, 'features.json'),
    kerasModel: path.join(runDir, `motion-tcn-${safeId}.keras`),
    bestKerasModel: path.join(runDir, `motion-tcn-${safeId}.best.keras`),
    evaluation: path.join(runDir, 'evaluation.json'),
    tfjsModel: path.join(runDir, 'tfjs'),
    hybridEvaluation: path.join(runDir, 'hybrid-evaluation.json'),
    modelId: resolvedModelId,
    publishedModel: path.join(profile.paths.publishedModels, resolvedModelId),
  };
}

export function buildDefaultExerciseTrainingPlan(profile, {
  runId,
  modelId = null,
  python = 'python3',
} = {}) {
  const paths = exerciseTrainingRunPaths(profile, runId, modelId);
  const features = profile.features || {};
  const trainer = profile.trainer || {};
  const evaluation = profile.evaluation || {};

  const featureArgs = [
    'scripts/build-motion-features.mjs',
    '--input', profile.paths.dataset,
    '--exercise', paths.exercise,
    '--out', paths.features,
  ];
  numberArg(featureArgs, '--window-size', features.windowSize);
  numberArg(featureArgs, '--stride', features.stride);
  numberArg(featureArgs, '--validation-ratio', features.validationRatio);
  numberArg(featureArgs, '--test-ratio', features.testRatio);
  numberArg(featureArgs, '--boundary-band-below', features.boundaryBandBelowDeg);
  numberArg(featureArgs, '--boundary-band-above', features.boundaryBandAboveDeg);
  numberArg(featureArgs, '--boundary-weight', features.boundaryWeight);
  numberArg(featureArgs, '--phase-purity-threshold', features.phasePurityThreshold ?? 0.8);
  if (features.skipUnlabeled) featureArgs.push('--skip-unlabeled');

  const trainArgs = [
    'training/train_motion_tcn_keras.py',
    '--features', paths.features,
    '--out', paths.kerasModel,
  ];
  numberArg(trainArgs, '--epochs', trainer.epochs);
  numberArg(trainArgs, '--batch-size', trainer.batchSize);
  numberArg(trainArgs, '--filters', trainer.filters);
  numberArg(trainArgs, '--dropout', trainer.dropout);
  numberArg(trainArgs, '--patience', trainer.patience);
  numberArg(trainArgs, '--phase-loss-weight', trainer.phaseLossWeight);
  numberArg(trainArgs, '--quality-loss-weight', trainer.qualityLossWeight);
  numberArg(trainArgs, '--class-balance-power', trainer.classBalancePower);
  numberArg(trainArgs, '--outside-boundary-multiplier', trainer.outsideBoundaryMultiplier);
  numberArg(trainArgs, '--seed', trainer.seed);
  if (trainer.deterministic) trainArgs.push('--deterministic');

  const evaluateArgs = [
    'training/evaluate_motion_tcn_keras.py',
    '--model', paths.bestKerasModel,
    '--features', paths.features,
    '--out', paths.evaluation,
    '--split', evaluation.split || 'test',
  ];

  const exportArgs = [
    'training/export_keras_to_tfjs.py',
    '--model', paths.bestKerasModel,
    '--features', paths.features,
    '--evaluation', paths.evaluation,
    '--out', paths.tfjsModel,
    '--version', paths.modelId,
    '--validation-only',
  ];

  const hybridArgs = [
    'scripts/evaluate-hybrid-target.mjs',
    '--model', paths.tfjsModel,
    '--features', paths.features,
    '--exercise', paths.exercise,
    '--out', paths.hybridEvaluation,
    '--split', evaluation.split || 'test',
    '--fps', String(evaluation.fps || 30),
  ];

  const publishArgs = [
    'scripts/publish-motion-model.mjs',
    '--model', paths.tfjsModel,
    '--evaluation', paths.evaluation,
    '--hybrid-evaluation', paths.hybridEvaluation,
    '--out', paths.publishedModel,
    '--version', paths.modelId,
  ];

  return {
    exerciseModule: profile.id,
    exerciseId: profile.exerciseId,
    paths,
    commands: {
      features: { command: process.execPath, args: featureArgs },
      train: { command: python, args: trainArgs },
      evaluate: { command: python, args: evaluateArgs },
      export: { command: python, args: exportArgs },
      hybrid: { command: process.execPath, args: hybridArgs },
      publish: { command: process.execPath, args: publishArgs },
    },
  };
}

export function buildExerciseTrainingPlan(profile, options = {}) {
  const buildPlan = typeof profile.buildTrainingPlan === 'function'
    ? profile.buildTrainingPlan
    : buildDefaultExerciseTrainingPlan;
  const plan = buildPlan(profile, options);
  const missingStage = [...PIPELINE_STAGES, 'publish'].find((stage) => !plan?.commands?.[stage]);
  if (missingStage) {
    throw new Error(`Training profile ${profile.id || 'unknown'} did not define the ${missingStage} command`);
  }
  return plan;
}

async function fileExists(filePath) {
  try {
    await access(path.resolve(REPO_ROOT, filePath), constants.R_OK);
    return true;
  } catch {
    return false;
  }
}

async function prepareResolvedExercise(profile, paths, { write = true } = {}) {
  const sourcePath = path.resolve(REPO_ROOT, profile.paths.exercise);
  const source = JSON.parse(await readFile(sourcePath, 'utf8'));
  if (source.id !== profile.exerciseId) {
    throw new Error(`Training profile ${profile.id} expected exercise ${profile.exerciseId}, got ${source.id || 'missing'}`);
  }
  const resolved = profile.resolveExercise ? profile.resolveExercise(source) : source;
  if (write) {
    const target = path.resolve(REPO_ROOT, paths.exercise);
    await mkdir(path.dirname(target), { recursive: true });
    await writeFile(target, `${JSON.stringify(resolved, null, 2)}\n`);
  }
  return resolved;
}

function runCommand({ command, args }, { cwd = REPO_ROOT } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, stdio: 'inherit', env: process.env });
    child.on('error', reject);
    child.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`${command} exited with code ${code}`));
    });
  });
}

export async function runExerciseTraining(profile, {
  runId,
  stage = 'plan',
  modelId = null,
  python = process.env.PHYSIOAI_TRAINING_PYTHON || 'python3',
  dryRun = false,
} = {}) {
  if (!VALID_STAGES.has(stage)) throw new Error(`Unknown training stage: ${stage}`);
  const plan = buildExerciseTrainingPlan(profile, { runId, modelId, python });
  if (!dryRun && stage !== 'plan' && profile.protectedRunIds?.includes(plan.paths.runId)) {
    throw new Error(`Run ${plan.paths.runId} is the frozen shipped-model record; use a new --run name`);
  }
  const resolvedExercise = await prepareResolvedExercise(profile, plan.paths, { write: !dryRun && stage !== 'plan' });
  if (!await fileExists(profile.paths.dataset)) {
    throw new Error(`Exercise dataset does not exist: ${profile.paths.dataset}`);
  }
  const stages = stage === 'all' || stage === 'plan' ? PIPELINE_STAGES : [stage];
  const summary = {
    ok: true,
    dryRun: dryRun || stage === 'plan',
    stage,
    ...plan,
    exerciseContract: {
      id: resolvedExercise.id,
      moduleId: resolvedExercise.exerciseModuleId || profile.id,
      landmarkSchemaId: resolvedExercise.landmarkSchemaId,
      cameraView: resolvedExercise.cameraView,
      modelArchitectureId: resolvedExercise.modelArchitectureId || profile.architecture?.id || null,
      modelArchitectureVersion: resolvedExercise.modelArchitectureVersion || profile.architecture?.version || null,
      targetOutcomePolicy: resolvedExercise.targetOutcomePolicy || null,
    },
    selectedCommands: stages.map((name) => ({ name, ...plan.commands[name] })),
  };
  if (summary.dryRun) return summary;
  for (const name of stages) await runCommand(plan.commands[name]);
  return summary;
}

export function parseExerciseTrainingArgs(argv = []) {
  const args = {
    exercise: null,
    runId: null,
    stage: 'plan',
    modelId: null,
    python: process.env.PHYSIOAI_TRAINING_PYTHON || 'python3',
    dryRun: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--exercise') args.exercise = argv[++index];
    else if (arg === '--run') args.runId = argv[++index];
    else if (arg === '--stage') args.stage = argv[++index];
    else if (arg === '--model-id') args.modelId = argv[++index];
    else if (arg === '--python') args.python = argv[++index];
    else if (arg === '--dry-run') args.dryRun = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
}

export function exerciseTrainingUsage() {
  return [
    'Usage: node scripts/run-exercise-model.mjs --exercise lateral_arm_raise --run <run-id> [--stage plan|all|features|train|evaluate|export|hybrid|publish]',
    '',
    'The plan stage is read-only and prints every resolved command.',
    'The all stage builds features, trains, evaluates, exports TFJS, and evaluates Hybrid. Publishing is always explicit.',
  ].join('\n');
}
