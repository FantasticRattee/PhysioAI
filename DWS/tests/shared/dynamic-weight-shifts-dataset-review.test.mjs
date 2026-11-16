import test from 'node:test';
import assert from 'node:assert/strict';
import { isReviewedTrainableRow } from '../../shared/ai/DatasetLabeler.js';
import { normalizeDatasetLandmarks } from '../../shared/ai/MotionDataset.js';
import {
  dynamicWeightShiftDirectionForRow,
  overrideDynamicWeightShiftDirection,
  prepareDynamicWeightShiftDatasetRow,
  reviewDynamicWeightShiftDatasetRow,
} from '../../exercise-modules/dynamic_weight_shifts/runtime/datasetReview.js';
import { makeBasePose } from '../helpers/pose-fixtures.mjs';

function shiftPose(deltaX = 0) {
  const landmarks = makeBasePose();
  landmarks[11] = { ...landmarks[11], x: landmarks[11].x + deltaX };
  landmarks[12] = { ...landmarks[12], x: landmarks[12].x + deltaX };
  return landmarks;
}

function row(overrides = {}) {
  return {
    id: 'dws_1',
    exerciseId: 'cust_dynamic_weight_shifts',
    dataQuality: 'usable',
    labelStatus: 'draft',
    trainable: false,
    repComplete: true,
    landmarkSchemaId: 'seated_balance.v1',
    missingPrimary: [],
    missingStabilizer: [],
    frames: [
      ...Array.from({ length: 3 }, (_, index) => ({
        t: index * 100,
        phase: 'rest',
        boundaryStatus: 'inside',
        angles: { trunk_shift: 0 },
        landmarks: shiftPose(0),
      })),
      ...Array.from({ length: 3 }, (_, index) => ({
        t: 300 + index * 100,
        phase: 'target',
        boundaryStatus: 'inside',
        angles: { trunk_shift: 12 },
        landmarks: shiftPose(0.06),
      })),
    ],
    metadata: {},
    ...overrides,
  };
}

test('Dynamic Weight Shifts review stores a four-class label using screen direction', () => {
  const reviewed = reviewDynamicWeightShiftDatasetRow(row(), 'correct');

  assert.equal(reviewed.formLabel, 'correct');
  assert.equal(reviewed.label, 'correct_right');
  assert.equal(reviewed.classLabel, 'correct_right');
  assert.equal(reviewed.motionLabel, null);
  assert.equal(reviewed.metadata.directionConvention, 'screen.v1');
  assert.equal(reviewed.landmarkSideConvention, 'screen.v1');
  assert.equal(reviewed.metadata.landmarkSideConvention, 'screen.v1');
  assert.equal(reviewed.metadata.shiftDirection, 'right');
  assert.equal(reviewed.metadata.screenDirection, 'screen_right');
  assert.equal(reviewed.metadata.anatomicalDirection, 'left');
  assert.equal(reviewed.metadata.directionSource, 'stored_landmarks');
  assert.deepEqual(reviewed.phaseLabels, ['rest', 'target']);
  assert.equal(reviewed.landmarkSchemaId, 'seated_balance.v2');
  assert.deepEqual(reviewed.jointNames, []);
  assert.equal(reviewed.frames.some((frame) => frame.angles.trunk_shift != null), false);
  assert.deepEqual(reviewed.metadata.trainingPhases, ['rest', 'target']);
  assert.equal(reviewed.trainable, true);
  assert.equal(isReviewedTrainableRow(reviewed), true);
});

test('Dynamic Weight Shifts preparation removes legacy trunk_shift and preserves screen-oriented coordinates', () => {
  const source = row();
  const prepared = prepareDynamicWeightShiftDatasetRow(source);

  assert.equal(prepared.metadata.featureContract, 'shoulder_hip_landmarks_only.v1');
  assert.equal(prepared.frames.every((frame, index) => frame.landmarks !== source.frames[index].landmarks), true);
  assert.deepEqual(
    prepared.frames.map((frame) => frame.landmarks),
    source.frames.map((frame) => normalizeDatasetLandmarks(frame.landmarks)),
  );
  assert.equal(prepared.metadata.landmarkSideConvention, 'screen.v1');
  assert.equal(prepared.frames.every((frame) => !Object.hasOwn(frame.angles, 'trunk_shift')), true);
});

test('Dynamic Weight Shifts rows require correct/wrong form tag before training', () => {
  const missingForm = {
    ...row(),
    classLabel: null,
    motionLabel: null,
    label: 'unlabeled',
    labelStatus: 'reviewed',
    trainable: true,
  };

  assert.equal(isReviewedTrainableRow(missingForm), false);
  assert.throws(() => reviewDynamicWeightShiftDatasetRow(row(), 'moving_to_target'), /Invalid Dynamic Weight Shifts form label/);
});

test('Dynamic Weight Shifts automatic direction can be manually corrected', () => {
  const source = row();
  assert.equal(dynamicWeightShiftDirectionForRow(source).direction, 'right');

  const corrected = overrideDynamicWeightShiftDirection(source, 'left');
  assert.equal(dynamicWeightShiftDirectionForRow(corrected).direction, 'left');
  assert.equal(corrected.metadata.directionSource, 'manual_override');

  const reviewed = reviewDynamicWeightShiftDatasetRow(source, 'wrong');
  assert.deepEqual(reviewed.metadata.trainingPhases, ['target']);
  const reviewedCorrected = overrideDynamicWeightShiftDirection(reviewed, 'left');
  assert.equal(reviewed.classLabel, 'wrong_right');
  assert.equal(reviewedCorrected.classLabel, 'wrong_left');
});

test('screen-left target is labeled left even though anatomical direction is right', () => {
  const source = row({
    frames: [
      ...Array.from({ length: 3 }, (_, index) => ({
        t: index * 100,
        phase: 'rest',
        boundaryStatus: 'inside',
        angles: {},
        landmarks: shiftPose(0),
      })),
      ...Array.from({ length: 3 }, (_, index) => ({
        t: 300 + index * 100,
        phase: 'target',
        boundaryStatus: 'inside',
        angles: {},
        landmarks: shiftPose(-0.06),
      })),
    ],
  });
  const reviewed = reviewDynamicWeightShiftDatasetRow(source, 'correct');

  assert.equal(reviewed.classLabel, 'correct_left');
  assert.equal(reviewed.metadata.shiftDirection, 'left');
  assert.equal(reviewed.metadata.screenDirection, 'screen_left');
  assert.equal(reviewed.metadata.anatomicalDirection, 'right');
});

test('screen-v1 wrong row may store Target only without losing its reviewed direction', () => {
  const source = row({
    label: 'wrong_left',
    classLabel: 'wrong_left',
    formLabel: 'wrong',
    labelStatus: 'reviewed',
    trainable: true,
    frames: Array.from({ length: 3 }, (_, index) => ({
      t: index * 100,
      phase: 'target',
      boundaryStatus: 'inside',
      angles: {},
      landmarks: shiftPose(-0.06),
    })),
    metadata: {
      directionConvention: 'screen.v1',
      directionSource: 'stored_landmarks',
      shiftDirection: 'left',
      screenDirection: 'screen_left',
      anatomicalDirection: 'right',
      formLabel: 'wrong',
      classLabel: 'wrong_left',
    },
  });
  const prepared = prepareDynamicWeightShiftDatasetRow(source);

  assert.equal(prepared.classLabel, 'wrong_left');
  assert.equal(prepared.metadata.shiftDirection, 'left');
  assert.deepEqual(prepared.metadata.trainingPhases, ['target']);
  assert.equal(isReviewedTrainableRow(prepared), true);
});
