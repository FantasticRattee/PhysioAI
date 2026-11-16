#!/usr/bin/env node

import { mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { parseMotionDatasetJsonl } from '../../../shared/ai/MotionDataset.js';
import { extractMotionFeatureWindow, MOTION_FEATURE_SCHEMA_VERSION } from '../../../shared/ai/MotionFeatureExtractor.js';
import { modelManifestSchemaFields, resolveBodyRegionLandmarkSchema } from '../../../shared/ai/BodyRegionLandmarkSchema.js';
import {
  DYNAMIC_WEIGHT_SHIFT_CLASSES,
  DYNAMIC_WEIGHT_SHIFT_CLASS_CONTRACT,
  DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION,
  DYNAMIC_WEIGHT_SHIFT_LANDMARK_SCHEMA_ID,
  DYNAMIC_WEIGHT_SHIFT_PHASES,
  isWrongDynamicWeightShiftClass,
  dynamicWeightShiftClassParts,
  normalizeDynamicWeightShiftDirection,
  normalizeDynamicWeightShiftClass,
  screenDirectionForDynamicWeightShift,
} from '../../../shared/ai/DynamicWeightShiftContract.js';
import { LANDMARK_SIDE_CONVENTION } from '../../../shared/ai/Landmarks.js';
import {
  DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_CONTRACT,
  DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_FEATURE_NAMES,
} from '../../../shared/ai/DynamicWeightShiftTorsoFeatures.js';
import {
  isDynamicWeightShiftDatasetRow,
  prepareDynamicWeightShiftDatasetRow,
} from '../runtime/datasetReview.js';

function parseArgs(argv) {
  const args = { input: null, exercise: null, out: null, windowSize: 30, stride: 5, phasePurityThreshold: 0.7, direction: null };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--input') args.input = argv[++index];
    else if (arg === '--exercise') args.exercise = argv[++index];
    else if (arg === '--out') args.out = argv[++index];
    else if (arg === '--window-size') args.windowSize = Number(argv[++index]);
    else if (arg === '--stride') args.stride = Number(argv[++index]);
    else if (arg === '--phase-purity-threshold') args.phasePurityThreshold = Number(argv[++index]);
    else if (arg === '--direction') {
      const value = argv[++index];
      args.direction = normalizeDynamicWeightShiftDirection(value);
      if (!args.direction) throw new Error(`--direction must be left or right; got ${value || 'missing'}`);
    }
    else throw new Error(`Unknown argument: ${arg}`);
  }
  return args;
}

function oneHot(label, labels) {
  return labels.map((item) => Number(item === label));
}

function padWindow(vectors, windowSize, featureSize) {
  const selected = vectors.slice(-windowSize).map((vector) => vector.slice(0, featureSize));
  const first = selected[0] || Array(featureSize).fill(0);
  while (selected.length < windowSize) selected.unshift([...first]);
  return selected;
}

function phasePurity(frames, end, windowSize, phase) {
  const selected = frames.slice(Math.max(0, end - windowSize), end);
  const padding = Math.max(0, windowSize - selected.length);
  const paddingPhase = selected[0]?.phase || phase;
  const matching = selected.reduce((count, frame) => count + Number(frame.phase === phase), 0)
    + Number(paddingPhase === phase) * padding;
  return matching / windowSize;
}

function endIndexesForFrames(frames, stride) {
  const indexes = new Set([1, frames.length]);
  for (let end = 1; end <= frames.length; end += Math.max(1, stride)) indexes.add(end);
  const presentPhases = DYNAMIC_WEIGHT_SHIFT_PHASES.filter((phase) =>
    frames.some((frame) => frame?.phase === phase));
  for (const phase of presentPhases) {
    const first = frames.findIndex((frame) => frame.phase === phase);
    const last = frames.findLastIndex((frame) => frame.phase === phase);
    if (first >= 0) indexes.add(first + 1);
    if (last >= 0) indexes.add(last + 1);
  }
  return [...indexes].filter((value) => value > 0 && value <= frames.length).sort((a, b) => a - b);
}

async function readDatasetRows(inputPath) {
  const inputStat = await stat(inputPath);
  if (inputStat.isDirectory()) {
    const files = (await readdir(inputPath))
      .filter((file) => file.endsWith('.json') && file !== 'index.json')
      .sort();
    return Promise.all(files.map(async (file) => JSON.parse(await readFile(path.join(inputPath, file), 'utf8'))));
  }
  const text = await readFile(inputPath, 'utf8');
  if (inputPath.endsWith('.jsonl') || inputPath.endsWith('.ndjson')) return parseMotionDatasetJsonl(text);
  const parsed = JSON.parse(text);
  return Array.isArray(parsed) ? parsed : [parsed];
}

function stableHash(value = '') {
  let hash = 2166136261;
  for (const char of String(value)) {
    hash ^= char.charCodeAt(0);
    hash = Math.imul(hash, 16777619);
  }
  return hash >>> 0;
}

function splitLineage(row = {}) {
  const subject = row.subjectId || row.metadata?.subjectId || 'unknown_subject';
  const lineage = row.metadata?.splitLineageId || row.metadata?.syntheticSourceId || row.repId || row.id;
  return `lineage:${subject}:${lineage || 'unknown'}`;
}

function validationIssues(row = {}) {
  const issues = [];
  const classLabel = normalizeDynamicWeightShiftClass(row.classLabel || row.metadata?.classLabel || row.label);
  if (!classLabel) issues.push('invalid_or_missing_classLabel');
  const classParts = dynamicWeightShiftClassParts(classLabel);
  const storedDirection = normalizeDynamicWeightShiftDirection(row.metadata?.shiftDirection);
  if (row.metadata?.directionConvention !== DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION) {
    issues.push('directionConvention_screen_v1_required');
  }
  if ((row.landmarkSideConvention || row.metadata?.landmarkSideConvention) !== LANDMARK_SIDE_CONVENTION) {
    issues.push('landmarkSideConvention_screen_v1_required');
  }
  if (classParts && storedDirection !== classParts.direction) issues.push('class_direction_mismatch');
  if (classParts && row.metadata?.screenDirection !== screenDirectionForDynamicWeightShift(classParts.direction)) {
    issues.push('screenDirection_class_mismatch');
  }
  if (row.labelStatus !== 'reviewed') issues.push('labelStatus_not_reviewed');
  if (row.trainable !== true) issues.push('trainable_not_true');
  if (row.repComplete !== true) issues.push('repComplete_true_required');
  if (row.dataQuality !== 'usable') issues.push(`dataQuality_${row.dataQuality || 'missing'}`);
  if (row.landmarkSchemaId !== DYNAMIC_WEIGHT_SHIFT_LANDMARK_SCHEMA_ID) issues.push('landmarkSchemaId_mismatch');
  if (row.missingPrimary?.length) issues.push('missing_primary_required');
  if (row.missingStabilizer?.length) issues.push('missing_stabilizer_required');
  const frames = Array.isArray(row.frames) ? row.frames : [];
  if (!frames.length) issues.push('no_frames');
  const requiredPhases = isWrongDynamicWeightShiftClass(classLabel)
    ? ['target']
    : DYNAMIC_WEIGHT_SHIFT_PHASES;
  for (const phase of requiredPhases) {
    if (frames.filter((frame) => frame?.phase === phase).length < 3) issues.push(`insufficient_${phase}_frames`);
  }
  if (frames.some((frame) => !DYNAMIC_WEIGHT_SHIFT_PHASES.includes(frame?.phase))) issues.push('invalid_phase');
  if (frames.some((frame) => frame?.boundaryStatus !== 'inside')) issues.push('non_inside_training_frame');
  return issues;
}

function assignLineageSplits(rows = [], classLabels = DYNAMIC_WEIGHT_SHIFT_CLASSES) {
  const groups = new Map();
  for (const row of rows) {
    const key = splitLineage(row);
    const classLabel = normalizeDynamicWeightShiftClass(row.classLabel || row.metadata?.classLabel || row.label);
    const group = groups.get(key) || { key, classLabels: new Set(), rows: [] };
    group.classLabels.add(classLabel);
    group.rows.push(row);
    groups.set(key, group);
  }
  const mixed = [...groups.values()].filter((group) => group.classLabels.size !== 1);
  if (mixed.length) throw new Error(`A split lineage mixes class labels: ${mixed.map((group) => group.key).join(', ')}`);

  const assignments = new Map();
  for (const classLabel of classLabels) {
    const candidates = [...groups.values()]
      .filter((group) => group.classLabels.has(classLabel) && group.rows.some((row) => row.metadata?.synthetic !== true))
      .sort((left, right) => stableHash(left.key) - stableHash(right.key) || left.key.localeCompare(right.key));
    if (candidates.length < 3) {
      throw new Error(`Class ${classLabel} needs at least 3 independent real lineages for train, validation, and test; found ${candidates.length}.`);
    }
    candidates.forEach((group, index) => {
      const split = index === 0 ? 'test' : index === 1 ? 'validation' : 'train';
      const existing = assignments.get(group.key);
      if (existing && existing !== split) throw new Error(`Conflicting split assignment for ${group.key}`);
      assignments.set(group.key, split);
    });
  }
  return assignments;
}

function splitCoverage(rows = [], classLabels = DYNAMIC_WEIGHT_SHIFT_CLASSES) {
  return Object.fromEntries(['train', 'validation', 'test'].map((split) => [split, {
    rows: rows.filter((row) => row.metadata?.datasetSplit === split).length,
    classes: Object.fromEntries(classLabels.map((classLabel) => [
      classLabel,
      rows.filter((row) => row.metadata?.datasetSplit === split && row.classLabel === classLabel).length,
    ])),
  }]));
}

export async function buildDynamicWeightShiftFeatures(args) {
  if (!args.input || !args.exercise || !args.out) throw new Error('--input, --exercise, and --out are required');
  const exercise = JSON.parse(await readFile(args.exercise, 'utf8'));
  const sourceRows = await readDatasetRows(args.input);
  const schema = resolveBodyRegionLandmarkSchema(exercise.landmarkSchemaId, { fallback: false });
  if (!schema) throw new Error(`Unknown schema: ${exercise.landmarkSchemaId}`);

  const exerciseRows = sourceRows
    .filter((row) => row.exerciseId === exercise.id && isDynamicWeightShiftDatasetRow(row))
    .map(prepareDynamicWeightShiftDatasetRow);
  const assessed = exerciseRows.map((row) => ({ row, issues: validationIssues(row) }));
  const invalidReviewed = assessed.filter(({ row, issues }) => issues.length && (row.labelStatus === 'reviewed' || row.trainable === true));
  if (invalidReviewed.length) {
    throw new Error(`Invalid reviewed Dynamic Weight Shifts rows:\n${invalidReviewed.map(({ row, issues }) => `${row.id || row.repId}: ${issues.join(', ')}`).join('\n')}`);
  }
  const selectedDirection = normalizeDynamicWeightShiftDirection(args.direction);
  const selectedClasses = selectedDirection
    ? [`correct_${selectedDirection}`, `wrong_${selectedDirection}`]
    : [...DYNAMIC_WEIGHT_SHIFT_CLASSES];
  const derivedFeatureContract = selectedDirection
    ? DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_CONTRACT
    : null;
  const validRows = assessed.filter(({ issues }) => !issues.length).map(({ row }) => ({
    ...row,
    classLabel: normalizeDynamicWeightShiftClass(row.classLabel || row.metadata?.classLabel || row.label),
  })).filter((row) => selectedClasses.includes(row.classLabel));
  if (!validRows.length) {
    throw new Error(`No eligible reviewed Dynamic Weight Shifts rows for ${selectedDirection || 'four-class'} training`);
  }

  const assignments = assignLineageSplits(validRows, selectedClasses);
  const splitRows = validRows.flatMap((row) => {
    const datasetSplit = assignments.get(splitLineage(row));
    if (!datasetSplit || (row.metadata?.synthetic === true && datasetSplit !== 'train')) return [];
    return [{
      ...row,
      metadata: { ...(row.metadata || {}), datasetSplit, splitLineageId: splitLineage(row) },
    }];
  });
  const coverage = splitCoverage(splitRows, selectedClasses);
  for (const split of ['train', 'validation', 'test']) {
    for (const classLabel of selectedClasses) {
      if (coverage[split].classes[classLabel] < 1) throw new Error(`${split} split is missing class ${classLabel}`);
    }
  }

  const samples = [];
  let featureSize = null;
  for (const row of splitRows) {
    const frames = isWrongDynamicWeightShiftClass(row.classLabel)
      ? (row.frames || []).filter((frame) => frame?.phase === 'target')
      : row.frames || [];
    const extracted = extractMotionFeatureWindow(frames, {
      landmarkSchema: schema,
      landmarkSchemaId: schema.id,
      joints: schema.jointNames,
      derivedFeatureContract,
    });
    const vectors = extracted.map((item) => item.featureVector);
    if (!vectors.length) continue;
    featureSize ??= vectors[0].length;
    if (vectors.some((vector) => vector.length !== featureSize || vector.some((value) => !Number.isFinite(value)))) {
      throw new Error(`Feature vector mismatch in ${row.repId || row.id}`);
    }
    for (const end of endIndexesForFrames(frames, args.stride)) {
      const frame = frames[end - 1];
      const phase = frame.phase;
      const purity = phasePurity(frames, end, args.windowSize, phase);
      samples.push({
        exerciseId: row.exerciseId,
        cameraView: row.cameraView,
        subjectId: row.subjectId,
        datasetSessionId: row.datasetSessionId,
        repId: row.repId,
        splitGroup: row.metadata.splitLineageId,
        split: row.metadata.datasetSplit,
        phase,
        quality: row.classLabel,
        classLabel: row.classLabel,
        qualityWeight: phase === 'target' ? 1 : 0,
        phasePurity: purity,
        phaseWeight: purity >= args.phasePurityThreshold ? 1 : 0,
        phaseTransitionWindow: purity < 1,
        window: padWindow(vectors.slice(0, end), args.windowSize, featureSize),
        phaseOneHot: oneHot(phase, DYNAMIC_WEIGHT_SHIFT_PHASES),
        qualityOneHot: oneHot(row.classLabel, selectedClasses),
        synthetic: row.metadata?.synthetic === true,
      });
    }
  }
  const splitCounts = Object.fromEntries(['train', 'validation', 'test'].map((split) => [
    split,
    samples.filter((sample) => sample.split === split).length,
  ]));
  if (Object.values(splitCounts).some((count) => count === 0)) throw new Error(`Training split has no samples: ${JSON.stringify(splitCounts)}`);

  const payload = {
    schema: 'physioai.motion_features.v2',
    builtAt: new Date().toISOString(),
    sourceDataset: args.input,
    inputShape: [args.windowSize, featureSize],
    motionFeatureSchemaVersion: MOTION_FEATURE_SCHEMA_VERSION,
    windowPadding: 'repeat_first',
    exerciseId: exercise.id,
    cameraView: exercise.cameraView,
    phases: [...DYNAMIC_WEIGHT_SHIFT_PHASES],
    qualities: [...selectedClasses],
    featureContract: selectedDirection
      ? 'shoulder_hip_torso_geometry.v2'
      : 'shoulder_hip_landmarks_only.v1',
    derivedFeatureContract,
    derivedFeatureNames: derivedFeatureContract
      ? [...DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_FEATURE_NAMES]
      : [],
    formGeometryContract: selectedDirection ? {
      version: 'screen_torso_form.v1',
      shoulderLine: 'two_shoulders_parallel_to_screen_horizontal',
      torsoLean: 'same_screen_side_hip_to_shoulder_from_vertical',
      correctTarget: 'shoulder_line_level_while_torso_axis_leans_toward_target',
      excludedJointAngle: 'shoulder_hip_knee',
      excludedTranslation: 'absolute_hip_center_motion',
      normalizationAnchor: 'hip_center_per_frame',
    } : null,
    classContract: selectedDirection
      ? `dynamic_weight_shifts_form_screen_${selectedDirection}.v1`
      : DYNAMIC_WEIGHT_SHIFT_CLASS_CONTRACT,
    trainingDirection: selectedDirection,
    trainingPhasePolicy: {
      correct: ['rest', 'target'],
      wrong: ['target'],
    },
    qualityDecisionMode: selectedDirection
      ? `binary_form_screen_${selectedDirection}`
      : 'four_class_form_and_screen_direction',
    qualityTrainingPhases: ['target'],
    exposeHeadConfidences: true,
    formEvaluationPhases: ['target'],
    augmentationPolicy: {
      mirrorX: false,
      syntheticRows: 'train_only_same_source_lineage',
    },
    ...modelManifestSchemaFields(schema),
    rows: sourceRows.length,
    exerciseRows: exerciseRows.length,
    validRows: splitRows.length,
    invalidRows: assessed.filter(({ issues }) => issues.length).length,
    split: splitCounts,
    splitCoverage: coverage,
    splitGroupMode: 'real_lineage_with_synthetic_train_only',
    phasePurityThreshold: args.phasePurityThreshold,
    phaseTrainingSamples: {
      total: samples.length,
      active: samples.filter((sample) => sample.phaseWeight > 0).length,
      masked: samples.filter((sample) => sample.phaseWeight === 0).length,
    },
    clinicalReviewRequired: true,
    samples,
  };
  await mkdir(path.dirname(args.out), { recursive: true });
  await writeFile(args.out, `${JSON.stringify(payload)}\n`);
  const summary = {
    ok: true,
    out: args.out,
    rows: sourceRows.length,
    validRows: splitRows.length,
    samples: samples.length,
    inputShape: payload.inputShape,
    phases: payload.phases,
    classes: payload.qualities,
    direction: selectedDirection,
    split: splitCounts,
    splitCoverage: coverage,
  };
  console.log(JSON.stringify(summary, null, 2));
  return { payload, summary };
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  buildDynamicWeightShiftFeatures(parseArgs(process.argv.slice(2))).catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
