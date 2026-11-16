import test from 'node:test';
import assert from 'node:assert/strict';
import {
  DEFAULT_LANDMARK_COUNT,
  expectedMotionFeatureSizeForSchema,
  extractMotionFeatures,
  extractMotionFeatureWindow,
  featureVectorsFromWindow,
} from '../../shared/ai/MotionFeatureExtractor.js';

test('extractMotionFeatures builds a stable vector from landmarks angles and flags', () => {
  const features = extractMotionFeatures({
    t: 100,
    landmarks: [
      { x: 0.1, y: 0.2, z: 0.3, visibility: 0.9 },
      { x: 0.4, y: 0.5, z: 0.6, visibility: 0.8 },
    ],
    jointAngles: { right_shoulder: 45, left_shoulder: 30 },
    progressPct: 55,
    boundaryStatus: 'inside',
  }, {
    joints: ['right_shoulder', 'left_shoulder'],
  });

  assert.equal(features.landmarks.length, DEFAULT_LANDMARK_COUNT);
  assert.deepEqual(features.joints, ['right_shoulder', 'left_shoulder']);
  assert.equal(features.angles.right_shoulder, 45);
  assert.equal(features.insideFrame, true);
  assert.equal(features.progress, 55);
  assert.equal(features.version, 2);
  assert.equal(features.featureVector.length, DEFAULT_LANDMARK_COUNT * 4 + 2 + 2);
  assert.deepEqual(features.featureVector.slice(0, 4), [0, 0, 0, 0.9]);
  assert.equal(features.featureVector.at(-4), 45 / 180);
});

test('extractMotionFeatureWindow computes angle velocity from previous frame timestamps', () => {
  const window = extractMotionFeatureWindow([
    { t: 0, jointAngles: { right_knee: 20 }, landmarks: [] },
    { t: 100, jointAngles: { right_knee: 35 }, landmarks: [] },
  ], {
    joints: ['right_knee'],
    landmarkCount: 1,
  });

  assert.equal(window[0].angleVelocity.right_knee, 0);
  assert.equal(window[1].angleVelocity.right_knee, 150);
});

test('extractMotionFeatures uses body-region schema landmarks when schema id is provided', () => {
  const landmarks = Array.from({ length: DEFAULT_LANDMARK_COUNT }, (_, index) => ({
    x: index / 100,
    y: index / 200,
    z: 0,
    visibility: 0.9,
  }));
  const features = extractMotionFeatures({
    t: 0,
    landmarks,
    jointAngles: { right_shoulder: 70, right_elbow: 120, left_knee: 30 },
    boundaryStatus: 'inside',
  }, {
    landmarkSchemaId: 'right_arm.v1',
  });

  assert.equal(features.landmarks.length, 4);
  assert.deepEqual(features.modelInputLandmarks, ['right_shoulder', 'right_elbow', 'right_wrist', 'left_shoulder']);
  assert.deepEqual(features.joints, ['right_shoulder', 'right_elbow']);
  assert.equal(features.featureVector.length, 4 * 4 + 2 + 2);
  assert.equal(features.landmarkSchemaId, 'right_arm.v1');
  assert.equal(expectedMotionFeatureSizeForSchema({ landmarkSchemaId: 'right_arm.v1' }), features.featureVector.length);
});

test('extractMotionFeatures does not fall back to full landmarks for unknown schema id', () => {
  const landmarks = Array.from({ length: DEFAULT_LANDMARK_COUNT }, (_, index) => ({
    x: index / 100,
    y: index / 200,
    z: 0,
    visibility: 0.9,
  }));
  const features = extractMotionFeatures({
    t: 0,
    landmarks,
    jointAngles: { right_shoulder: 70 },
    boundaryStatus: 'inside',
  }, {
    landmarkSchemaId: 'made_up.v1',
  });

  assert.equal(features.schemaMissing, true);
  assert.equal(features.landmarkSchemaId, 'made_up.v1');
  assert.deepEqual(features.landmarks, []);
  assert.deepEqual(features.joints, []);
  assert.deepEqual(features.featureVector, []);
  assert.equal(features.featureSize, 0);
});

test('seated balance v2 produces landmark-only features even when frame angles exist', () => {
  const landmarks = Array.from({ length: DEFAULT_LANDMARK_COUNT }, (_, index) => ({
    x: index / 100,
    y: index / 200,
    z: 0,
    visibility: 0.9,
  }));
  const features = extractMotionFeatures({
    t: 0,
    landmarks,
    angles: { trunk_shift: 12, left_knee: 80 },
    boundaryStatus: 'inside',
  }, { landmarkSchemaId: 'seated_balance.v2' });

  assert.deepEqual(features.joints, []);
  assert.equal(features.featureVector.length, 16);
  assert.equal(expectedMotionFeatureSizeForSchema({ landmarkSchemaId: 'seated_balance.v2' }), 16);
  assert.equal(features.landmarkSideConvention, 'screen.v1');
});

test('seated balance feature order follows screen left/right, not MediaPipe anatomy', () => {
  const landmarks = Array.from({ length: DEFAULT_LANDMARK_COUNT }, () => ({
    x: 0.5,
    y: 0.5,
    z: 0,
    visibility: 0.99,
  }));
  landmarks[11] = { x: 0.7, y: 0.3, z: 0, visibility: 0.91 };
  landmarks[12] = { x: 0.3, y: 0.3, z: 0, visibility: 0.92 };
  landmarks[23] = { x: 0.62, y: 0.65, z: 0, visibility: 0.93 };
  landmarks[24] = { x: 0.38, y: 0.65, z: 0, visibility: 0.94 };

  const features = extractMotionFeatures({ landmarks }, { landmarkSchemaId: 'seated_balance.v2' });

  assert.ok(features.landmarks[0][0] < features.landmarks[1][0], 'left shoulder feature must be screen-left');
  assert.ok(features.landmarks[2][0] < features.landmarks[3][0], 'left hip feature must be screen-left');
  assert.deepEqual(features.landmarks.map((point) => point[3]), [0.92, 0.91, 0.94, 0.93]);
});

test('screenMirrorX makes selfie-camera input match the pose displayed on screen', () => {
  const displayed = Array.from({ length: DEFAULT_LANDMARK_COUNT }, () => ({
    x: 0.5,
    y: 0.5,
    z: 0,
    visibility: 0.99,
  }));
  displayed[11] = { x: 0.25, y: 0.3, z: 0, visibility: 0.96 };
  displayed[12] = { x: 0.45, y: 0.3, z: 0, visibility: 0.97 };
  displayed[23] = { x: 0.37, y: 0.65, z: 0, visibility: 0.98 };
  displayed[24] = { x: 0.57, y: 0.65, z: 0, visibility: 0.95 };
  const rawSelfieCamera = displayed.map((point) => ({ ...point, x: 1 - point.x }));
  const options = {
    landmarkSchemaId: 'seated_balance.v2',
    derivedFeatureContract: 'dynamic_weight_shifts_torso_geometry.v1',
  };

  const datasetFeatures = extractMotionFeatures({ landmarks: displayed }, options);
  const liveFeatures = extractMotionFeatures({ landmarks: rawSelfieCamera }, {
    ...options,
    screenMirrorX: true,
  });

  assert.equal(liveFeatures.screenMirrorX, true);
  assert.ok(liveFeatures.landmarks[0][0] < liveFeatures.landmarks[1][0]);
  assert.ok(liveFeatures.derivedFeatureValues[3] < 0, 'screen-left torso lean must stay negative');
  datasetFeatures.featureVector.forEach((value, index) => {
    assert.ok(Math.abs(value - liveFeatures.featureVector[index]) < 1e-9);
  });
});

test('featureVectorsFromWindow returns vectors only for classifier input', () => {
  const vectors = featureVectorsFromWindow([
    { t: 0, landmarks: [[0.1, 0.2, 0, 0.9]], angles: { elbow: 10 } },
    { t: 100, landmarks: [[0.2, 0.2, 0, 0.9]], angles: { elbow: 20 } },
  ], {
    joints: ['elbow'],
    landmarkCount: 1,
  });

  assert.equal(vectors.length, 2);
  assert.deepEqual(vectors[0].slice(0, 4), [0, 0, 0, 0.9]);
  assert.equal(vectors[1].length, 1 * 4 + 1 + 1);
});

test('body-relative landmark features are invariant to image translation and uniform scale', () => {
  const base = Array.from({ length: DEFAULT_LANDMARK_COUNT }, () => ({ x: 0, y: 0, z: 0, visibility: 0.95 }));
  const names = {
    11: [0.3, 0.3],
    12: [0.5, 0.3],
    14: [0.65, 0.45],
    16: [0.75, 0.6],
    24: [0.5, 0.65],
  };
  for (const [index, [x, y]] of Object.entries(names)) base[index] = { x, y, z: 0.02, visibility: 0.95 };
  const transformed = base.map((point) => ({
    ...point,
    x: point.x * 1.7 + 0.08,
    y: point.y * 1.7 - 0.11,
    z: point.z * 1.7,
  }));
  const options = { landmarkSchemaId: 'right_arm.v1' };
  const a = extractMotionFeatures({ landmarks: base, jointAngles: { right_shoulder: 80, right_elbow: 120 } }, options);
  const b = extractMotionFeatures({ landmarks: transformed, jointAngles: { right_shoulder: 80, right_elbow: 120 } }, options);

  a.featureVector.forEach((value, index) => assert.ok(Math.abs(value - b.featureVector[index]) < 1e-9));
});
