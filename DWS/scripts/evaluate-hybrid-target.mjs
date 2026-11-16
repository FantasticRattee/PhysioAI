#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import * as tf from '@tensorflow/tfjs';
import {
  createExerciseTargetDecisionEngine,
  resolveExerciseRuntime,
  resolveExerciseTargetConfig,
} from '../exercise-modules/runtime-registry.js';

function parseArgs(argv = process.argv.slice(2)) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith('--')) continue;
    options[key.slice(2)] = argv[index + 1];
    index += 1;
  }
  return options;
}

async function loadTfjsModel(modelDir) {
  const modelJson = JSON.parse(await readFile(path.join(modelDir, 'model.json'), 'utf8'));
  const groups = modelJson.weightsManifest || [];
  const weightSpecs = groups.flatMap((group) => group.weights || []);
  const chunks = [];
  for (const group of groups) {
    for (const relativePath of group.paths || []) {
      chunks.push(await readFile(path.join(modelDir, relativePath)));
    }
  }
  const buffer = Buffer.concat(chunks);
  const weightData = buffer.buffer.slice(buffer.byteOffset, buffer.byteOffset + buffer.byteLength);
  const handler = tf.io.fromMemory({
    modelTopology: modelJson.modelTopology,
    weightSpecs,
    weightData,
    format: modelJson.format,
    generatedBy: modelJson.generatedBy,
    convertedBy: modelJson.convertedBy,
  });
  return modelJson.format === 'graph-model'
    ? tf.loadGraphModel(handler)
    : tf.loadLayersModel(handler);
}

function maxPrediction(vector = []) {
  let index = 0;
  let confidence = -Infinity;
  vector.forEach((value, candidate) => {
    if (Number(value) > confidence) {
      confidence = Number(value);
      index = candidate;
    }
  });
  return { index, confidence: Math.max(0, Math.min(1, confidence)) };
}

function outputIndexes(model) {
  const names = model.outputNames || [];
  const phase = names.findIndex((name) => String(name).toLowerCase().includes('phase'));
  const quality = names.findIndex((name) => String(name).toLowerCase().includes('quality'));
  return {
    phase: phase >= 0 ? phase : 0,
    quality: quality >= 0 ? quality : 1,
  };
}

async function predict(model, samples, outputMap = null) {
  const input = tf.tensor3d(samples.map((sample) => sample.window));
  const graphExecute = typeof model.execute === 'function'
    ? model.execute.bind(model)
    : model.executeAsync?.bind(model);
  const raw = outputMap && graphExecute
    ? await graphExecute(input, [outputMap.phase, outputMap.quality])
    : model.predict(input);
  const tensors = Array.isArray(raw) ? raw : [raw];
  try {
    const values = await Promise.all(tensors.map((tensor) => tensor.array()));
    const indexes = outputMap ? { phase: 0, quality: 1 } : outputIndexes(model);
    return {
      phase: values[indexes.phase],
      quality: values[indexes.quality],
    };
  } finally {
    input.dispose();
    tensors.forEach((tensor) => tensor.dispose?.());
  }
}

function targetAngleIndex(features, targetJoint) {
  const jointIndex = (features.jointNames || []).indexOf(targetJoint);
  if (jointIndex < 0) throw new Error(`Target joint ${targetJoint} is not in feature jointNames`);
  return (features.modelInputLandmarks || []).length * 4 + jointIndex;
}

function metricsFromCounts({ trueReached, falseReached, trueNotReached, falseNotReached }) {
  const total = trueReached + falseReached + trueNotReached + falseNotReached;
  const reachedTotal = trueReached + falseNotReached;
  const notReachedTotal = trueNotReached + falseReached;
  return {
    repAccuracy: total ? (trueReached + trueNotReached) / total : 0,
    reachedRecall: reachedTotal ? trueReached / reachedTotal : 0,
    notReachedRecall: notReachedTotal ? trueNotReached / notReachedTotal : 0,
    falseReachedRate: notReachedTotal ? falseReached / notReachedTotal : 0,
  };
}

function classificationFromPredictions(samples, predictions, labels, { phase = null } = {}) {
  const selected = samples
    .map((sample, index) => ({ sample, index }))
    .filter(({ sample }) => !phase || sample.phase === phase);
  const confusionMatrix = Object.fromEntries(labels.map((label) => [
    label,
    Object.fromEntries(labels.map((predicted) => [predicted, 0])),
  ]));
  let correct = 0;
  for (const { sample, index } of selected) {
    const truth = phase ? sample.quality : sample.phase;
    const predicted = labels[maxPrediction(predictions[index]).index];
    if (!confusionMatrix[truth] || !predicted) continue;
    confusionMatrix[truth][predicted] += 1;
    correct += Number(truth === predicted);
  }
  const perLabelRecall = Object.fromEntries(labels.map((label) => {
    const total = Object.values(confusionMatrix[label]).reduce((sum, count) => sum + count, 0);
    return [label, total ? confusionMatrix[label][label] / total : 0];
  }));
  return {
    sampleCount: selected.length,
    accuracy: selected.length ? correct / selected.length : 0,
    perLabelRecall,
    confusionMatrix,
  };
}

function isDynamicWeightShiftFormContract(features = {}) {
  return String(features.classContract || '').startsWith('dynamic_weight_shifts_form_screen_');
}

export function evaluateHybridRepPredictions({
  features,
  samples,
  phasePredictions,
  qualityPredictions,
  exercise,
  fps = 30,
} = {}) {
  const phases = features.phases || ['rest', 'moving_to_target', 'target'];
  const qualities = features.qualities || ['reached_target', 'not_reached_target'];
  if (isDynamicWeightShiftFormContract(features)) {
    const phase = classificationFromPredictions(samples, phasePredictions, phases);
    const quality = classificationFromPredictions(samples, qualityPredictions, qualities, { phase: 'target' });
    const completeCoverage = qualities.every((label) => quality.perLabelRecall[label] > 0);
    return {
      mode: features.qualityDecisionMode || 'form_and_screen_direction',
      repCount: new Set(samples.map((sample) => sample.repId).filter(Boolean)).size,
      phase,
      quality,
      approval: {
        ok: phase.accuracy >= 0.9 && quality.accuracy >= 0.85 && completeCoverage,
        criteria: { phaseAccuracy: 0.9, qualityAccuracy: 0.85, everyClassRecallAboveZero: true },
      },
    };
  }
  const runtimeExercise = resolveExerciseRuntime(exercise);
  const targetConfig = resolveExerciseTargetConfig(runtimeExercise);
  const angleIndexes = targetConfig.targetRules.map((rule) => ({
    joint: rule.joint,
    index: targetAngleIndex(features, rule.joint),
  }));
  const groups = new Map();
  samples.forEach((sample, index) => {
    const key = sample.repId || `${sample.datasetSessionId}:${index}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push({ sample, index });
  });

  const confusion = {
    trueReached: 0,
    falseReached: 0,
    trueNotReached: 0,
    falseNotReached: 0,
  };
  const reps = [];
  for (const [repId, rows] of groups) {
    const engine = createExerciseTargetDecisionEngine({ exercise: runtimeExercise });
    let predictedReached = false;
    let completion = null;
    rows.forEach(({ sample, index }, frameIndex) => {
      const phase = maxPrediction(phasePredictions[index]);
      const quality = maxPrediction(qualityPredictions[index]);
      const lastVector = sample.window.at(-1) || [];
      const jointAngles = Object.fromEntries(angleIndexes.map(({ joint, index: angleIndex }) => [
        joint,
        Number(lastVector[angleIndex]) * 180,
      ]));
      const snapshot = engine.push({
        timestamp: frameIndex * (1000 / fps),
        jointAngles,
        boundary: { status: 'inside', ok: true, scoreable: true, dataQuality: 'usable' },
        aiSignal: {
          phase: phases[phase.index],
          quality: qualities[quality.index],
          confidence: Math.min(phase.confidence, quality.confidence),
        },
      });
      if (snapshot.completedRep) {
        predictedReached = true;
        completion = snapshot.completedRep;
      }
    });
    const expectedReached = rows.some(({ sample }) => sample.quality === 'reached_target');
    if (expectedReached && predictedReached) confusion.trueReached += 1;
    else if (!expectedReached && predictedReached) confusion.falseReached += 1;
    else if (!expectedReached) confusion.trueNotReached += 1;
    else confusion.falseNotReached += 1;
    reps.push({ repId, expectedReached, predictedReached, completion });
  }

  const metrics = metricsFromCounts(confusion);
  return {
    repCount: reps.length,
    confusion,
    metrics,
    approval: {
      ok: metrics.repAccuracy >= 0.9 &&
        metrics.reachedRecall >= 0.9 &&
        metrics.notReachedRecall >= 0.9 &&
        metrics.falseReachedRate <= 0.05,
      criteria: {
        repAccuracy: 0.9,
        reachedRecall: 0.9,
        notReachedRecall: 0.9,
        falseReachedRate: 0.05,
      },
    },
    reps,
  };
}

async function main() {
  const args = parseArgs();
  if (!args.model || !args.features || !args.out) {
    throw new Error('Usage: --model <tfjs dir> --features <features.json> --out <evaluation.json> [--exercise <exercise.json>] [--threshold <deg>]');
  }
  const features = JSON.parse(await readFile(args.features, 'utf8'));
  const manifest = JSON.parse(await readFile(path.join(args.model, 'manifest.json'), 'utf8'));
  const samples = (features.samples || []).filter((sample) => sample.split === (args.split || 'test'));
  const storedPolicy = features.targetOutcomePolicy || manifest.targetOutcomePolicy || {};
  const formDirectionContract = isDynamicWeightShiftFormContract(features);
  const threshold = Number(args.threshold ?? storedPolicy.reachedTargetMinDeg ?? storedPolicy.reachedTargetMaxDeg);
  const targetJoint = args.joint || storedPolicy.joint || null;
  if (!formDirectionContract && (!targetJoint || !Number.isFinite(threshold))) {
    throw new Error('Hybrid evaluation requires a target joint and threshold from the exercise policy or CLI.');
  }
  const comparator = storedPolicy.comparator === 'lte' ? 'lte' : 'gte';
  const exerciseRecord = args.exercise
    ? JSON.parse(await readFile(path.resolve(args.exercise), 'utf8'))
    : {
        id: features.exerciseId,
        primaryJoint: targetJoint || 'trunk_shift',
        rest: Number(args.rest || 30),
        targetOutcomePolicy: {
          ...storedPolicy,
          joint: targetJoint || 'trunk_shift',
          comparator,
          ...(comparator === 'lte'
            ? { reachedTargetMaxDeg: Number.isFinite(threshold) ? threshold : 2.5 }
            : { reachedTargetMinDeg: Number.isFinite(threshold) ? threshold : 2.5 }),
          ...(args['required-joint'] && Number.isFinite(Number(args['required-threshold'])) ? {
            requiredJointRules: [{
              joint: args['required-joint'],
              comparator: 'gte',
              reachedTargetMinDeg: Number(args['required-threshold']),
              enforceDuringPhases: ['moving_to_target', 'target'],
              violationGraceMs: Number(args['movement-violation-grace-ms'] || 120),
            }],
          } : {}),
        },
      };
  const exercise = resolveExerciseRuntime(exerciseRecord);
  const targetConfig = resolveExerciseTargetConfig(exercise);
  const model = await loadTfjsModel(args.model);
  const predictions = await predict(model, samples, manifest.outputMap || null);
  model.dispose();
  const evaluation = evaluateHybridRepPredictions({
    features,
    samples,
    phasePredictions: predictions.phase,
    qualityPredictions: predictions.quality,
    exercise,
    fps: Number(args.fps || 30),
  });
  const output = {
    schema: 'physioai.hybrid_target_evaluation.v1',
    modelVersion: manifest.version,
    validationOnly: manifest.validationOnly === true,
    evaluatedSplit: args.split || 'test',
    sampleCount: samples.length,
    targetJoint: formDirectionContract ? null : targetConfig.targetJoint,
    targetThreshold: formDirectionContract ? null : targetConfig.targetThreshold,
    targetRules: formDirectionContract ? [] : targetConfig.targetRules,
    ...evaluation,
  };
  await writeFile(args.out, `${JSON.stringify(output, null, 2)}\n`, 'utf8');
  console.log(JSON.stringify(output, null, 2));
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  main().catch((error) => {
    console.error(error?.stack || error);
    process.exitCode = 1;
  });
}
