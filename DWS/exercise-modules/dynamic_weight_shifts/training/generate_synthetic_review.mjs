#!/usr/bin/env node

import crypto from 'node:crypto';
import { mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { dynamicWeightShiftDirectionForRow } from '../runtime/datasetReview.js';
import { validateDatasetPayload } from '../../../shared/api/handlers/payload-validation.js';
import { LocalFileStore } from '../../../shared/api/runtime/local-file.js';

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const EXERCISE_ID = 'cust_dynamic_weight_shifts';
const DEFAULT_DATA_ROOT = path.join(REPO_ROOT, 'data/local');
const DEFAULT_DATASET_DIR = path.join(
  DEFAULT_DATA_ROOT,
  'exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/datasets',
);
const DEFAULT_FEATURES = path.join(
  DEFAULT_DATA_ROOT,
  'exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/training_runs/left-tcn-v1/features.json',
);
const DEFAULT_REPORT_ROOT = path.join(
  DEFAULT_DATA_ROOT,
  'exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/training_runs/synthetic-review',
);

const LEFT_UPPER = Object.freeze([1, 2, 3, 7, 9, 11, 13, 15, 17, 19, 21]);
const RIGHT_UPPER = Object.freeze([4, 5, 6, 8, 10, 12, 14, 16, 18, 20, 22]);

function parseArgs(argv = []) {
  const args = {
    datasetDir: DEFAULT_DATASET_DIR,
    features: DEFAULT_FEATURES,
    dataRoot: DEFAULT_DATA_ROOT,
    reportRoot: DEFAULT_REPORT_ROOT,
    runId: 'torso-special-left-v1',
    maxCorrectSources: 18,
    maxWrongSources: 11,
    dryRun: false,
  };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === '--dataset-dir') args.datasetDir = path.resolve(argv[++index]);
    else if (arg === '--features') args.features = path.resolve(argv[++index]);
    else if (arg === '--data-root') args.dataRoot = path.resolve(argv[++index]);
    else if (arg === '--report-root') args.reportRoot = path.resolve(argv[++index]);
    else if (arg === '--run') args.runId = argv[++index];
    else if (arg === '--max-correct-sources') args.maxCorrectSources = Number(argv[++index]);
    else if (arg === '--max-wrong-sources') args.maxWrongSources = Number(argv[++index]);
    else if (arg === '--dry-run') args.dryRun = true;
    else if (arg === '--help' || arg === '-h') args.help = true;
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!/^[A-Za-z0-9._-]+$/.test(args.runId || '')) throw new Error('--run must be a safe identifier');
  if (!Number.isInteger(args.maxCorrectSources) || args.maxCorrectSources < 1) {
    throw new Error('--max-correct-sources must be a positive integer');
  }
  if (!Number.isInteger(args.maxWrongSources) || args.maxWrongSources < 1) {
    throw new Error('--max-wrong-sources must be a positive integer');
  }
  return args;
}

function clone(value) {
  return JSON.parse(JSON.stringify(value));
}

function median(values = []) {
  const sorted = values.map(Number).filter(Number.isFinite).sort((a, b) => a - b);
  if (!sorted.length) return 0;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function stableToken(...parts) {
  return crypto.createHash('sha256').update(parts.join('|')).digest('hex').slice(0, 20);
}

function stableSeed(...parts) {
  return Number.parseInt(stableToken(...parts).slice(0, 8), 16) >>> 0;
}

function mulberry32(seed) {
  let state = seed >>> 0;
  return () => {
    state += 0x6D2B79F5;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4294967296;
  };
}

function signed(rng, magnitude = 1) {
  return (rng() * 2 - 1) * magnitude;
}

function point(frame, index) {
  return frame?.landmarks?.[index] || [0, 0, 0, 0];
}

function torsoGeometry(frame = {}) {
  const leftShoulder = point(frame, 11);
  const rightShoulder = point(frame, 12);
  const leftHip = point(frame, 23);
  const rightHip = point(frame, 24);
  const shoulderCenter = [
    (Number(leftShoulder[0]) + Number(rightShoulder[0])) / 2,
    (Number(leftShoulder[1]) + Number(rightShoulder[1])) / 2,
  ];
  const hipCenter = [
    (Number(leftHip[0]) + Number(rightHip[0])) / 2,
    (Number(leftHip[1]) + Number(rightHip[1])) / 2,
  ];
  const shoulderTiltDeg = Math.atan2(
    Number(rightShoulder[1]) - Number(leftShoulder[1]),
    Math.abs(Number(rightShoulder[0]) - Number(leftShoulder[0])) || 1e-6,
  ) * 180 / Math.PI;
  const torsoLeanDeg = Math.atan2(
    shoulderCenter[0] - hipCenter[0],
    hipCenter[1] - shoulderCenter[1],
  ) * 180 / Math.PI;
  return { shoulderCenter, hipCenter, shoulderTiltDeg, torsoLeanDeg };
}

function rowGeometry(row = {}) {
  const rest = (row.frames || []).filter((frame) => frame?.phase === 'rest').map(torsoGeometry);
  const target = (row.frames || []).filter((frame) => frame?.phase === 'target').map(torsoGeometry);
  const neutralTorsoLeanDeg = median(rest.map((item) => item.torsoLeanDeg));
  return {
    neutralTorsoLeanDeg,
    targetShoulderTiltDeg: median(target.map((item) => item.shoulderTiltDeg)),
    targetShiftDeg: median(target.map((item) => Math.abs(item.torsoLeanDeg - neutralTorsoLeanDeg))),
  };
}

function interpolateNumber(left, right, fraction) {
  return Number(left) + (Number(right) - Number(left)) * fraction;
}

function interpolateFrame(left, right, fraction, phase) {
  const frame = clone(left);
  frame.landmarks = left.landmarks.map((leftPoint, pointIndex) => {
    const rightPoint = right.landmarks[pointIndex] || leftPoint;
    return leftPoint.map((value, axis) => interpolateNumber(value, rightPoint[axis] ?? value, fraction));
  });
  frame.phase = phase;
  frame.boundaryStatus = 'inside';
  frame.missingPrimary = [];
  frame.missingStabilizer = [];
  return frame;
}

function resamplePhase(frames, speedFactor) {
  if (frames.length < 2) return clone(frames);
  const count = Math.max(3, Math.round(frames.length / speedFactor));
  return Array.from({ length: count }, (_, index) => {
    const position = index * (frames.length - 1) / Math.max(1, count - 1);
    const leftIndex = Math.floor(position);
    const rightIndex = Math.min(frames.length - 1, leftIndex + 1);
    return interpolateFrame(frames[leftIndex], frames[rightIndex], position - leftIndex, frames[0].phase);
  });
}

function resampleRowFrames(frames, speedFactor, fps) {
  const output = ['rest', 'target'].flatMap((phase) =>
    resamplePhase(frames.filter((frame) => frame?.phase === phase), speedFactor));
  const stepMs = 1000 / Math.max(1, Number(fps) || 10);
  output.forEach((frame, index) => {
    frame.t = Math.round(index * stepMs);
    const { trunk_shift: _legacyTrunkShift, ...angles } = frame.angles || {};
    frame.angles = angles;
  });
  return output;
}

function moveUpperBody(frame, { desiredTorsoLeanDeg, desiredShoulderTiltDeg }) {
  const output = clone(frame);
  const leftShoulder = point(output, 11);
  const rightShoulder = point(output, 12);
  const { shoulderCenter, hipCenter } = torsoGeometry(output);
  const verticalHeight = Math.max(0.05, hipCenter[1] - shoulderCenter[1]);
  const desiredCenter = [
    hipCenter[0] + Math.tan(desiredTorsoLeanDeg * Math.PI / 180) * verticalHeight,
    shoulderCenter[1],
  ];
  const shoulderWidth = Math.max(0.04, Math.hypot(
    Number(rightShoulder[0]) - Number(leftShoulder[0]),
    Number(rightShoulder[1]) - Number(leftShoulder[1]),
  ));
  const tiltRadians = desiredShoulderTiltDeg * Math.PI / 180;
  const shoulderVector = [shoulderWidth * Math.cos(tiltRadians), shoulderWidth * Math.sin(tiltRadians)];
  const desiredLeft = [desiredCenter[0] - shoulderVector[0] / 2, desiredCenter[1] - shoulderVector[1] / 2];
  const desiredRight = [desiredCenter[0] + shoulderVector[0] / 2, desiredCenter[1] + shoulderVector[1] / 2];
  const leftDelta = [desiredLeft[0] - Number(leftShoulder[0]), desiredLeft[1] - Number(leftShoulder[1])];
  const rightDelta = [desiredRight[0] - Number(rightShoulder[0]), desiredRight[1] - Number(rightShoulder[1])];

  for (const index of LEFT_UPPER) {
    output.landmarks[index][0] += leftDelta[0];
    output.landmarks[index][1] += leftDelta[1];
  }
  for (const index of RIGHT_UPPER) {
    output.landmarks[index][0] += rightDelta[0];
    output.landmarks[index][1] += rightDelta[1];
  }
  const centerDelta = [(leftDelta[0] + rightDelta[0]) / 2, (leftDelta[1] + rightDelta[1]) / 2];
  output.landmarks[0][0] += centerDelta[0];
  output.landmarks[0][1] += centerDelta[1];
  return output;
}

function applyTargetGeometry(frames, source, variant, rng) {
  if (variant !== 'torso_boundary') return frames;
  const sourceGeometry = rowGeometry(source);
  const correct = source.classLabel === 'correct_left';
  const desiredShiftDeg = correct ? 3.25 + rng() * 2.75 : 6.5 + rng() * 5.5;
  const desiredShoulderTiltDeg = correct ? signed(rng, 2.0) : -(12 + rng() * 12);
  return frames.map((frame) => frame.phase !== 'target' ? frame : moveUpperBody(frame, {
    desiredTorsoLeanDeg: sourceGeometry.neutralTorsoLeanDeg - desiredShiftDeg + signed(rng, 0.22),
    desiredShoulderTiltDeg: desiredShoulderTiltDeg + signed(rng, 0.35),
  }));
}

function applyCameraAndJitter(frames, rng) {
  const scale = 0.97 + rng() * 0.025;
  const translateX = signed(rng, 0.009);
  const translateY = signed(rng, 0.007);
  let smoothX = 0;
  let smoothY = 0;
  for (const frame of frames) {
    smoothX = smoothX * 0.82 + signed(rng, 0.00028);
    smoothY = smoothY * 0.82 + signed(rng, 0.00028);
    for (const landmark of frame.landmarks) {
      landmark[0] = 0.5 + scale * (Number(landmark[0]) - 0.5) + translateX + smoothX;
      landmark[1] = 0.5 + scale * (Number(landmark[1]) - 0.5) + translateY + smoothY;
      landmark[2] = scale * Number(landmark[2]);
    }
  }
  return { frames, camera: { scale, translateX, translateY, smoothJitterMax: 0.00028 } };
}

function phaseCounts(frames) {
  return Object.fromEntries(['rest', 'target'].map((phase) => [
    phase,
    frames.filter((frame) => frame.phase === phase).length,
  ]));
}

function syntheticRow(source, { runId, variant, variantIndex, generatedAt }) {
  const sourceRepId = source.repId || source.id;
  const seed = stableSeed(runId, sourceRepId, variant, variantIndex);
  const rng = mulberry32(seed);
  const speedFactor = variant === 'camera_hold' ? 0.86 + rng() * 0.34 : 0.94 + rng() * 0.18;
  let frames = resampleRowFrames(source.frames || [], speedFactor, source.fpsEstimate || 10);
  frames = applyTargetGeometry(frames, source, variant, rng);
  const cameraResult = applyCameraAndJitter(frames, rng);
  frames = cameraResult.frames;
  const id = `ds_${EXERCISE_ID}_syn_${stableToken(runId, sourceRepId, variant, variantIndex)}`;
  const counts = phaseCounts(frames);
  const proposal = source.classLabel || source.label;
  const sourceMetadata = clone(source.metadata || {});
  const sourceClip = sourceMetadata.clip || {};
  const output = {
    ...clone(source),
    id,
    repId: id,
    captureId: id,
    capturedAt: generatedAt,
    storedAt: Date.parse(generatedAt),
    datasetSessionId: `synthetic_review_${runId}`,
    source: 'synthetic_torso_review',
    completionSource: 'synthetic_review_variant',
    label: 'unlabeled',
    motionLabel: null,
    classLabel: null,
    formLabel: null,
    suggestedLabel: proposal,
    labelStatus: 'draft',
    trainable: false,
    scoreable: false,
    repComplete: true,
    dataQuality: 'usable',
    missingPrimary: [],
    missingStabilizer: [],
    frameCount: frames.length,
    frames,
    metadata: {
      ...sourceMetadata,
      classLabel: null,
      formLabel: null,
      repId: id,
      captureId: id,
      capturedAt: generatedAt,
      datasetSessionId: `synthetic_review_${runId}`,
      completionSource: 'synthetic_review_variant',
      phaseCounts: counts,
      reviewSource: 'synthetic_torso_special_v1',
      referenceDataset: false,
      synthetic: true,
      syntheticReviewRequired: true,
      syntheticApprovedForTraining: false,
      syntheticSourceId: sourceRepId,
      syntheticSourceRepId: sourceRepId,
      syntheticSourceClassLabel: proposal,
      syntheticSuggestedClassLabel: proposal,
      syntheticSuggestedFormLabel: proposal?.startsWith('correct_') ? 'correct' : 'wrong',
      splitLineageId: sourceRepId,
      syntheticSourceSplit: 'train',
      augmentationPurpose: 'dynamic_weight_shifts_torso_form_review',
      augmentationRunId: runId,
      augmentationVariant: variant,
      augmentationSeed: seed,
      syntheticSpeedFactor: speedFactor,
      syntheticMirror: false,
      syntheticNoMirror: true,
      landmarksMirrored: false,
      mirrored: false,
      syntheticCameraScale: cameraResult.camera.scale,
      syntheticTranslateX: cameraResult.camera.translateX,
      syntheticTranslateY: cameraResult.camera.translateY,
      syntheticSmoothJitterMax: cameraResult.camera.smoothJitterMax,
      landmarkSideConvention: 'screen.v1',
      clip: {
        ...sourceClip,
        source: 'synthetic-torso-review',
        sourceRepId,
        originalFrameCount: source.frames?.length || 0,
        selectedFrameCount: frames.length,
        fpsEstimate: source.fpsEstimate || 10,
        phases: { counts, labels: ['rest', 'target'], rangesExplicit: true },
      },
      dataQualitySummary: {
        totalFrames: frames.length,
        usableFrames: frames.length,
        usableFrameRatio: 1,
        primaryVisibleRatio: 1,
        stabilizerVisibleRatio: 1,
        boundaryInsideRatio: 1,
      },
    },
  };

  const measured = dynamicWeightShiftDirectionForRow(output, { preferStored: false });
  output.metadata.shiftDirection = measured.direction;
  output.metadata.screenDirection = measured.screenDirection;
  output.metadata.anatomicalDirection = measured.anatomicalDirection;
  output.metadata.detectedShiftDirection = measured.direction;
  output.metadata.detectedScreenDirection = measured.screenDirection;
  output.metadata.detectedAnatomicalDirection = measured.anatomicalDirection;
  output.metadata.directionConfidence = measured.confidence;
  output.metadata.peakShiftDeg = measured.peakShiftDeg;
  output.metadata.directionSource = 'synthetic_stored_landmarks';

  const validation = validateDatasetPayload(output);
  if (!validation.ok) throw new Error(`${id}: ${validation.issues.join(', ')}`);
  return validation.value;
}

function selectDiverseSources(rows, limit) {
  if (rows.length <= limit) return [...rows];
  const sorted = [...rows].sort((left, right) => {
    const a = rowGeometry(left);
    const b = rowGeometry(right);
    return a.targetShoulderTiltDeg - b.targetShoulderTiltDeg ||
      a.targetShiftDeg - b.targetShiftDeg ||
      String(left.id).localeCompare(String(right.id));
  });
  if (limit === 1) return [sorted[Math.floor(sorted.length / 2)]];
  return Array.from({ length: limit }, (_, index) =>
    sorted[Math.round(index * (sorted.length - 1) / (limit - 1))]);
}

export function buildSyntheticReviewRows({
  rows = [],
  features = {},
  runId = 'torso-special-left-v1',
  maxCorrectSources = 18,
  maxWrongSources = 11,
  generatedAt = new Date().toISOString(),
} = {}) {
  const trainRepIds = new Set((features.samples || [])
    .filter((sample) => sample?.split === 'train')
    .map((sample) => sample.repId));
  const realTrainRows = rows.filter((row) =>
    row?.exerciseId === EXERCISE_ID &&
    row?.metadata?.synthetic !== true &&
    row?.labelStatus === 'reviewed' &&
    row?.trainable === true &&
    trainRepIds.has(row.repId || row.id));
  const correctSources = selectDiverseSources(
    realTrainRows.filter((row) => row.classLabel === 'correct_left'),
    maxCorrectSources,
  );
  const wrongSources = selectDiverseSources(
    realTrainRows.filter((row) => row.classLabel === 'wrong_left'),
    maxWrongSources,
  );
  if (!correctSources.length || !wrongSources.length) {
    throw new Error(`Synthetic review requires train sources for correct_left and wrong_left; found ${correctSources.length}/${wrongSources.length}`);
  }
  const variants = ['camera_hold', 'torso_boundary'];
  const generatedRows = [...correctSources, ...wrongSources].flatMap((source) =>
    variants.map((variant, variantIndex) => syntheticRow(source, {
      runId,
      variant,
      variantIndex,
      generatedAt,
    })));
  return { generatedRows, correctSources, wrongSources, trainRepIds };
}

export function auditSyntheticReviewRows({ generatedRows = [], trainRepIds = new Set() } = {}) {
  const failures = [];
  const ids = new Set();
  const byProposal = {};
  const byVariant = {};
  for (const row of generatedRows) {
    const metadata = row.metadata || {};
    const proposal = metadata.syntheticSuggestedClassLabel;
    const geometry = rowGeometry(row);
    if (ids.has(row.id)) failures.push(`${row.id}: duplicate id`);
    ids.add(row.id);
    byProposal[proposal] = (byProposal[proposal] || 0) + 1;
    byVariant[metadata.augmentationVariant] = (byVariant[metadata.augmentationVariant] || 0) + 1;
    if (row.labelStatus !== 'draft' || row.trainable !== false || row.scoreable !== false) {
      failures.push(`${row.id}: review-only safety flags invalid`);
    }
    if (row.label !== 'unlabeled' || row.classLabel != null || row.formLabel != null) {
      failures.push(`${row.id}: draft already has a final class`);
    }
    if (metadata.synthetic !== true || metadata.syntheticReviewRequired !== true || metadata.syntheticApprovedForTraining !== false) {
      failures.push(`${row.id}: synthetic review metadata invalid`);
    }
    if (metadata.syntheticMirror !== false || metadata.syntheticNoMirror !== true || metadata.landmarksMirrored !== false) {
      failures.push(`${row.id}: mirror must remain disabled`);
    }
    if (!trainRepIds.has(metadata.syntheticSourceRepId) || metadata.splitLineageId !== metadata.syntheticSourceRepId) {
      failures.push(`${row.id}: source is not a same-lineage train rep`);
    }
    if (metadata.shiftDirection !== 'left' || metadata.screenDirection !== 'screen_left') {
      failures.push(`${row.id}: measured direction is not screen-left`);
    }
    if ((row.frames || []).some((frame) =>
      frame.boundaryStatus !== 'inside' ||
      frame.missingPrimary?.length ||
      frame.missingStabilizer?.length ||
      frame.landmarks?.some((landmark) => landmark.some((value) => !Number.isFinite(Number(value)))))) {
      failures.push(`${row.id}: invalid frame data`);
    }
    if (metadata.augmentationVariant === 'torso_boundary' && proposal === 'correct_left' &&
      Math.abs(geometry.targetShoulderTiltDeg) > 3) {
      failures.push(`${row.id}: hard positive shoulders are not level`);
    }
    if (metadata.augmentationVariant === 'torso_boundary' && proposal === 'wrong_left' &&
      Math.abs(geometry.targetShoulderTiltDeg) < 10) {
      failures.push(`${row.id}: hard negative shoulder collapse is too small`);
    }
  }
  return {
    schema: 'physioai.dynamic_weight_shifts.synthetic_review_audit.v1',
    ok: failures.length === 0,
    failures,
    generatedRows: generatedRows.length,
    uniqueIds: ids.size,
    byProposal,
    byVariant,
    constraints: {
      sourceSplit: 'train-only',
      splitLineage: 'same-as-real-source',
      mirror: false,
      labelStatus: 'draft',
      trainable: false,
      finalClassRequiresTherapistReview: true,
      modelLandmarks: ['left_shoulder', 'right_shoulder', 'left_hip', 'right_hip'],
      presenceOnlyLandmarks: ['left_knee', 'right_knee', 'left_ankle', 'right_ankle', 'left_wrist', 'right_wrist'],
    },
  };
}

async function readRows(datasetDir) {
  const files = (await readdir(datasetDir))
    .filter((file) => file.startsWith('ds_') && file.endsWith('.json'))
    .sort();
  return Promise.all(files.map(async (file) => JSON.parse(await readFile(path.join(datasetDir, file), 'utf8'))));
}

export async function runSyntheticReviewGeneration(argv = process.argv.slice(2), {
  generatedAt = new Date().toISOString(),
} = {}) {
  const args = parseArgs(argv);
  if (args.help) {
    return { help: 'Usage: node generate_synthetic_review.mjs [--run ID] [--dry-run] [--max-correct-sources N] [--max-wrong-sources N]' };
  }
  const [rows, features] = await Promise.all([
    readRows(args.datasetDir),
    readFile(args.features, 'utf8').then(JSON.parse),
  ]);
  const built = buildSyntheticReviewRows({
    rows,
    features,
    runId: args.runId,
    maxCorrectSources: args.maxCorrectSources,
    maxWrongSources: args.maxWrongSources,
    generatedAt,
  });
  const audit = auditSyntheticReviewRows(built);
  if (!audit.ok) throw new Error(`Synthetic audit failed:\n${audit.failures.join('\n')}`);

  const reportDir = path.join(args.reportRoot, args.runId);
  const manifest = {
    schema: 'physioai.dynamic_weight_shifts.synthetic_review_manifest.v1',
    runId: args.runId,
    generatedAt,
    dryRun: args.dryRun,
    sourceDatasetDirectory: args.datasetDir,
    sourceFeatures: args.features,
    selectedRealSources: {
      correctLeft: built.correctSources.map((row) => row.repId || row.id),
      wrongLeft: built.wrongSources.map((row) => row.repId || row.id),
    },
    generatedDatasetIds: built.generatedRows.map((row) => row.id),
    audit,
  };
  if (!args.dryRun) {
    const store = new LocalFileStore({ root: args.dataRoot });
    for (const row of built.generatedRows) await store.writeDatasetArtifact(row);
    await mkdir(reportDir, { recursive: true });
    await writeFile(path.join(reportDir, 'manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`);
    await writeFile(path.join(reportDir, 'audit.json'), `${JSON.stringify(audit, null, 2)}\n`);
  }
  return manifest;
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] || '')) {
  runSyntheticReviewGeneration()
    .then((result) => console.log(result.help || JSON.stringify(result, null, 2)))
    .catch((error) => {
      console.error(error.stack || error.message);
      process.exitCode = 1;
    });
}
