export const DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_CONTRACT =
  'dynamic_weight_shifts_torso_geometry.v1';

export const DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_FEATURE_NAMES = Object.freeze([
  'shoulder_line_tilt_from_horizontal',
  'left_hip_to_shoulder_lean_from_vertical',
  'right_hip_to_shoulder_lean_from_vertical',
  'hip_center_to_shoulder_center_lean_from_vertical',
  'left_hip_to_shoulder_length',
  'right_hip_to_shoulder_length',
  'hip_to_shoulder_length_delta',
]);

function clamp(value, min = -1, max = 1) {
  const number = Number(value);
  if (!Number.isFinite(number)) return 0;
  return Math.max(min, Math.min(max, number));
}

function pointByName(landmarks = [], modelInputLandmarks = [], name) {
  const index = modelInputLandmarks.indexOf(name);
  const point = index >= 0 ? landmarks[index] : null;
  return Array.isArray(point) && Number.isFinite(point[0]) && Number.isFinite(point[1])
    ? point
    : null;
}

function midpoint(left, right) {
  if (!left || !right) return null;
  return [(left[0] + right[0]) / 2, (left[1] + right[1]) / 2];
}

function leanFromVertical(hip, shoulder) {
  if (!hip || !shoulder) return 0;
  const degrees = Math.atan2(shoulder[0] - hip[0], hip[1] - shoulder[1]) * 180 / Math.PI;
  return clamp(degrees / 90);
}

function shoulderTiltFromHorizontal(leftShoulder, rightShoulder) {
  if (!leftShoulder || !rightShoulder) return 0;
  const degrees = Math.atan2(
    rightShoulder[1] - leftShoulder[1],
    Math.abs(rightShoulder[0] - leftShoulder[0]) || 1e-6,
  ) * 180 / Math.PI;
  return clamp(degrees / 90);
}

function normalizedLength(a, b) {
  if (!a || !b) return 0;
  return Math.tanh(Math.hypot(a[0] - b[0], a[1] - b[1]));
}

export function dynamicWeightShiftTorsoGeometryFeatures({
  landmarks = [],
  modelInputLandmarks = [],
} = {}) {
  const leftShoulder = pointByName(landmarks, modelInputLandmarks, 'left_shoulder');
  const rightShoulder = pointByName(landmarks, modelInputLandmarks, 'right_shoulder');
  const leftHip = pointByName(landmarks, modelInputLandmarks, 'left_hip');
  const rightHip = pointByName(landmarks, modelInputLandmarks, 'right_hip');
  const shoulderCenter = midpoint(leftShoulder, rightShoulder);
  const hipCenter = midpoint(leftHip, rightHip);
  const leftLength = normalizedLength(leftHip, leftShoulder);
  const rightLength = normalizedLength(rightHip, rightShoulder);
  const values = [
    shoulderTiltFromHorizontal(leftShoulder, rightShoulder),
    leanFromVertical(leftHip, leftShoulder),
    leanFromVertical(rightHip, rightShoulder),
    leanFromVertical(hipCenter, shoulderCenter),
    leftLength,
    rightLength,
    clamp(leftLength - rightLength),
  ];
  return {
    contract: DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_CONTRACT,
    names: [...DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_FEATURE_NAMES],
    values,
  };
}

export function derivedMotionFeatureNames(contract = null) {
  return contract === DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_CONTRACT
    ? [...DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_FEATURE_NAMES]
    : [];
}

export function extractDerivedMotionFeatures(contract = null, options = {}) {
  if (contract !== DYNAMIC_WEIGHT_SHIFT_TORSO_GEOMETRY_CONTRACT) {
    return { contract: null, names: [], values: [] };
  }
  return dynamicWeightShiftTorsoGeometryFeatures(options);
}
