import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import os from 'node:os';
import path from 'node:path';

import { buildDynamicWeightShiftFeatures } from '../../exercise-modules/dynamic_weight_shifts/training/build_features.mjs';
import { makeBasePose } from '../helpers/pose-fixtures.mjs';

const CLASSES = ['correct_left', 'correct_right', 'wrong_left', 'wrong_right'];

function poseForClass(classLabel, phase) {
  const pose = makeBasePose();
  if (phase === 'target') {
    const delta = classLabel.endsWith('_left') ? -0.08 : 0.08;
    pose[11] = { ...pose[11], x: pose[11].x + delta };
    pose[12] = { ...pose[12], x: pose[12].x + delta };
  }
  return pose;
}

function reviewedRow(classLabel, lineageIndex) {
  const [formLabel, direction] = classLabel.split('_');
  const repId = `${classLabel}_${lineageIndex}`;
  return {
    id: repId,
    version: 2,
    exerciseId: 'cust_dynamic_weight_shifts',
    exerciseModuleId: 'dynamic_weight_shifts',
    subjectId: 'therapist_1',
    datasetSessionId: `session_${lineageIndex}`,
    repId,
    label: classLabel,
    classLabel,
    formLabel,
    motionLabel: null,
    labelStatus: 'reviewed',
    trainable: true,
    scoreable: true,
    repComplete: true,
    dataQuality: 'usable',
    landmarkSchemaId: 'seated_balance.v2',
    cameraView: 'front',
    missingPrimary: [],
    missingStabilizer: [],
    frames: ['rest', 'target'].flatMap((phase, phaseIndex) => Array.from({ length: 3 }, (_, frameIndex) => ({
      t: (phaseIndex * 3 + frameIndex) * 100,
      phase,
      boundaryStatus: 'inside',
      angles: { trunk_shift: phase === 'target' ? 12 : 0 },
      landmarks: poseForClass(classLabel, phase),
    }))),
    metadata: {
      exerciseModuleId: 'dynamic_weight_shifts',
      classLabel,
      formLabel,
      directionConvention: 'screen.v1',
      shiftDirection: direction,
      screenDirection: `screen_${direction}`,
      anatomicalDirection: direction === 'left' ? 'right' : 'left',
    },
  };
}

test('Dynamic Weight Shifts feature flow is two-phase, four-class, and landmark-only', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'physioai-dws-contract-'));
  const datasetDir = path.join(root, 'datasets');
  const exercisePath = path.join(root, 'exercise.json');
  const outPath = path.join(root, 'features.json');
  await mkdir(datasetDir);
  await writeFile(exercisePath, JSON.stringify({
    id: 'cust_dynamic_weight_shifts',
    cameraView: 'front',
    landmarkSchemaId: 'seated_balance.v2',
  }));

  try {
    for (const classLabel of CLASSES) {
      for (let index = 1; index <= 3; index += 1) {
        const row = reviewedRow(classLabel, index);
        await writeFile(path.join(datasetDir, `${row.id}.json`), JSON.stringify(row));
      }
    }
    const { payload } = await buildDynamicWeightShiftFeatures({
      input: datasetDir,
      exercise: exercisePath,
      out: outPath,
      windowSize: 30,
      stride: 5,
      phasePurityThreshold: 0.7,
    });

    assert.deepEqual(payload.phases, ['rest', 'target']);
    assert.deepEqual(payload.qualities, CLASSES);
    assert.deepEqual(payload.inputShape, [30, 16]);
    assert.deepEqual(payload.jointNames, []);
    assert.equal(payload.featureContract, 'shoulder_hip_landmarks_only.v1');
    assert.equal(payload.classContract, 'dynamic_weight_shifts_form_screen_direction.v2');
    assert.equal(payload.qualityDecisionMode, 'four_class_form_and_screen_direction');
    assert.equal(payload.samples.every((sample) => sample.window.every((vector) => vector.length === 16)), true);
    assert.equal(payload.samples.some((sample) => 'jointAngles' in sample || 'targetJointAngle' in sample), false);
    assert.deepEqual(payload.trainingPhasePolicy, {
      correct: ['rest', 'target'],
      wrong: ['target'],
    });
    assert.equal(
      payload.samples.filter((sample) => sample.quality.startsWith('wrong_'))
        .every((sample) => sample.phase === 'target'),
      true,
    );
    assert.deepEqual(
      [...new Set(payload.samples
        .filter((sample) => sample.quality.startsWith('correct_'))
        .map((sample) => sample.phase))].sort(),
      ['rest', 'target'],
    );
    for (const split of ['train', 'validation', 'test']) {
      for (const classLabel of CLASSES) {
        assert.ok(payload.splitCoverage[split].classes[classLabel] >= 1);
      }
    }

    const dryRun = spawnSync('python3', [
      'exercise-modules/dynamic_weight_shifts/training/train.py',
      '--features', outPath,
      '--out', path.join(root, 'model.keras'),
      '--dry-run',
    ], {
      cwd: process.cwd(),
      encoding: 'utf8',
      env: { ...process.env, PYTHONPYCACHEPREFIX: path.join(root, 'pycache') },
    });
    assert.equal(dryRun.status, 0, dryRun.stderr || dryRun.stdout);
    const drySummary = JSON.parse(dryRun.stdout);
    assert.equal(drySummary.architectureId, 'dynamic_weight_shifts_tcn.v3');
    assert.deepEqual(drySummary.inputShape, [30, 16]);
    assert.deepEqual(drySummary.phases, ['rest', 'target']);
    assert.deepEqual(drySummary.qualities, CLASSES);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test('screen-left TCN features use Target-only Wrong and explicit hip-to-shoulder geometry without KNN', async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), 'physioai-dws-left-tcn-'));
  const datasetDir = path.join(root, 'datasets');
  const exercisePath = path.join(root, 'exercise.json');
  const outPath = path.join(root, 'features.json');
  await mkdir(datasetDir);
  await writeFile(exercisePath, JSON.stringify({
    id: 'cust_dynamic_weight_shifts',
    cameraView: 'front',
    landmarkSchemaId: 'seated_balance.v2',
  }));

  try {
    for (const classLabel of ['correct_left', 'wrong_left']) {
      for (let index = 1; index <= 3; index += 1) {
        const row = reviewedRow(classLabel, index);
        await writeFile(path.join(datasetDir, `${row.id}.json`), JSON.stringify(row));
      }
    }
    const { payload } = await buildDynamicWeightShiftFeatures({
      input: datasetDir,
      exercise: exercisePath,
      out: outPath,
      windowSize: 30,
      stride: 2,
      phasePurityThreshold: 0.8,
      direction: 'left',
    });

    assert.deepEqual(payload.phases, ['rest', 'target']);
    assert.deepEqual(payload.qualities, ['correct_left', 'wrong_left']);
    assert.deepEqual(payload.inputShape, [30, 23]);
    assert.equal(payload.classContract, 'dynamic_weight_shifts_form_screen_left.v1');
    assert.equal(payload.featureContract, 'shoulder_hip_torso_geometry.v2');
    assert.equal(payload.derivedFeatureContract, 'dynamic_weight_shifts_torso_geometry.v1');
    assert.deepEqual(payload.derivedFeatureNames, [
      'shoulder_line_tilt_from_horizontal',
      'left_hip_to_shoulder_lean_from_vertical',
      'right_hip_to_shoulder_lean_from_vertical',
      'hip_center_to_shoulder_center_lean_from_vertical',
      'left_hip_to_shoulder_length',
      'right_hip_to_shoulder_length',
      'hip_to_shoulder_length_delta',
    ]);
    assert.equal(payload.formGeometryContract.excludedJointAngle, 'shoulder_hip_knee');
    assert.equal(payload.formGeometryContract.excludedTranslation, 'absolute_hip_center_motion');
    assert.equal(payload.formGeometryContract.normalizationAnchor, 'hip_center_per_frame');
    assert.deepEqual(payload.qualityTrainingPhases, ['target']);
    assert.equal(payload.exposeHeadConfidences, true);
    assert.deepEqual(payload.augmentationPolicy, {
      mirrorX: false,
      syntheticRows: 'train_only_same_source_lineage',
    });
    assert.equal(payload.samples.filter((sample) => sample.quality === 'wrong_left')
      .every((sample) => sample.phase === 'target' && sample.qualityWeight === 1), true);
    assert.equal(payload.samples.every((sample) => sample.window.every((vector) => vector.length === 23)), true);
    assert.equal(JSON.stringify(payload).toLowerCase().includes('knn'), false);
    for (const split of ['train', 'validation', 'test']) {
      assert.ok(payload.splitCoverage[split].classes.correct_left >= 1);
      assert.ok(payload.splitCoverage[split].classes.wrong_left >= 1);
    }

    const dryRun = spawnSync('python3', [
      'exercise-modules/dynamic_weight_shifts/training/train_left.py',
      '--features', outPath,
      '--out', path.join(root, 'model.keras'),
      '--dry-run',
    ], {
      cwd: process.cwd(),
      encoding: 'utf8',
      env: { ...process.env, PYTHONPYCACHEPREFIX: path.join(root, 'pycache') },
    });
    assert.equal(dryRun.status, 0, dryRun.stderr || dryRun.stdout);
    const summary = JSON.parse(dryRun.stdout);
    assert.equal(summary.architectureId, 'dynamic_weight_shifts_left_tcn.v1');
    assert.deepEqual(summary.inputShape, [30, 23]);
    assert.equal(summary.derivedFeatureContract, 'dynamic_weight_shifts_torso_geometry.v1');
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
