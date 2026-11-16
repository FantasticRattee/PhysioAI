import { landmarkToTuple } from './MotionDataset.js';
import { getBodyRegionLandmarkSchema, resolveBodyRegionLandmarkSchema } from './BodyRegionLandmarkSchema.js';
import {
  LANDMARK_SIDE_CONVENTION,
  idx,
  normalizePoseLandmarksToScreenSide,
} from './Landmarks.js';
import {
  derivedMotionFeatureNames,
  extractDerivedMotionFeatures,
} from './DynamicWeightShiftTorsoFeatures.js';

export const MOTION_FEATURE_SCHEMA_VERSION = 2;
export const DEFAULT_LANDMARK_COUNT = 33;

function finiteNumber(value, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function reflectLandmarkX(point) {
  if (Array.isArray(point)) {
    const reflected = [...point];
    const x = Number(reflected[0]);
    if (Number.isFinite(x)) reflected[0] = 1 - x;
    return reflected;
  }
  if (!point || typeof point !== 'object') return point;
  const x = Number(point.x);
  return Number.isFinite(x) ? { ...point, x: 1 - x } : { ...point };
}

function projectLandmarksToDisplayedScreen(landmarks = [], { screenMirrorX = false } = {}) {
  if (!Array.isArray(landmarks)) return [];
  return screenMirrorX ? landmarks.map(reflectLandmarkX) : landmarks;
}

function cleanAngles(angles = {}) {
  const out = {};
  for (const [joint, value] of Object.entries(angles || {})) {
    if (value == null || value === '') continue;
    const n = Number(value);
    if (Number.isFinite(n)) out[joint] = n;
  }
  return out;
}

function featureJoints(joints = null, angles = {}) {
  const list = Array.isArray(joints) ? joints : Object.keys(angles || {}).sort();
  return [...new Set(list.filter(Boolean))];
}

function padLandmarks(landmarks = [], count = DEFAULT_LANDMARK_COUNT) {
  const tuples = Array.isArray(landmarks) ? landmarks.map(landmarkToTuple) : [];
  const out = tuples.slice(0, count);
  while (out.length < count) out.push([0, 0, 0, 0]);
  return out;
}

function landmarkTupleByName(landmarks = [], name) {
  const index = idx(name);
  if (index < 0) return [0, 0, 0, 0];
  return landmarkToTuple(landmarks?.[index]);
}

function landmarksForSchema(landmarks = [], schema = null, landmarkCount = DEFAULT_LANDMARK_COUNT) {
  if (!schema?.modelInputLandmarks?.length) return padLandmarks(landmarks, landmarkCount);
  return schema.modelInputLandmarks.map((name) => landmarkTupleByName(landmarks, name));
}

function usablePoint(tuple = []) {
  return Number.isFinite(tuple[0]) && Number.isFinite(tuple[1]) && Number(tuple[3] ?? 0) > 0;
}

function midpoint(a, b) {
  if (!usablePoint(a) || !usablePoint(b)) return null;
  return [
    (a[0] + b[0]) / 2,
    (a[1] + b[1]) / 2,
    (a[2] + b[2]) / 2,
  ];
}

function distance3d(a, b) {
  if (!usablePoint(a) || !usablePoint(b)) return 0;
  return Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);
}

function normalizationFrame(landmarks = [], selected = []) {
  const leftShoulder = landmarkTupleByName(landmarks, 'left_shoulder');
  const rightShoulder = landmarkTupleByName(landmarks, 'right_shoulder');
  const leftHip = landmarkTupleByName(landmarks, 'left_hip');
  const rightHip = landmarkTupleByName(landmarks, 'right_hip');
  const shoulderCenter = midpoint(leftShoulder, rightShoulder);
  const hipCenter = midpoint(leftHip, rightHip);
  const first = selected.find(usablePoint) || [0, 0, 0, 0];
  const anchor = hipCenter || shoulderCenter || [first[0], first[1], first[2]];
  const shoulderWidth = distance3d(leftShoulder, rightShoulder);
  const hipWidth = distance3d(leftHip, rightHip);
  const torsoLength = shoulderCenter && hipCenter
    ? Math.hypot(
        shoulderCenter[0] - hipCenter[0],
        shoulderCenter[1] - hipCenter[1],
        shoulderCenter[2] - hipCenter[2],
      )
    : 0;
  const selectedSpread = selected.reduce((max, point) => {
    if (!usablePoint(point)) return max;
    return Math.max(max, Math.hypot(point[0] - anchor[0], point[1] - anchor[1], point[2] - anchor[2]));
  }, 0);
  const scale = [shoulderWidth, hipWidth, torsoLength, selectedSpread]
    .find((value) => Number.isFinite(value) && value >= 0.03) || 1;
  return { anchor, scale };
}

function normalizeLandmarkTuples(landmarks = [], selected = [], { mirrorX = false } = {}) {
  const normalization = normalizationFrame(landmarks, selected);
  return {
    normalization,
    landmarks: selected.map((point) => usablePoint(point)
      ? [
          ((point[0] - normalization.anchor[0]) / normalization.scale) * (mirrorX ? -1 : 1),
          (point[1] - normalization.anchor[1]) / normalization.scale,
          (point[2] - normalization.anchor[2]) / normalization.scale,
          finiteNumber(point[3]),
        ]
      : [0, 0, 0, 0]),
  };
}

function meanVisibility(landmarks = []) {
  const values = landmarks.map((p) => finiteNumber(p?.[3], 0));
  if (!values.length) return 0;
  return values.reduce((sum, value) => sum + value, 0) / values.length;
}

function angleVelocity(currentAngles, previousAngles, dtMs, joints) {
  const seconds = Math.max(0.001, finiteNumber(dtMs, 0) / 1000);
  const out = {};
  for (const joint of joints) {
    const current = Number(currentAngles?.[joint]);
    const previous = Number(previousAngles?.[joint]);
    out[joint] = Number.isFinite(current) && Number.isFinite(previous)
      ? (current - previous) / seconds
      : 0;
  }
  return out;
}

function timestampOf(frame, index = 0) {
  return finiteNumber(frame?.tMs ?? frame?.t ?? frame?.timestamp, index);
}

function normalizedAngle(value) {
  return finiteNumber(value) / 180;
}

function normalizedAngularVelocity(value) {
  return Math.tanh(finiteNumber(value) / 360);
}

export function extractMotionFeatures(frame = {}, {
  previousFrame = null,
  joints = [],
  landmarkCount = DEFAULT_LANDMARK_COUNT,
  landmarkSchemaId = frame.landmarkSchemaId || frame.metadata?.landmarkSchemaId || null,
  landmarkSchema = null,
  exercise = null,
  progress = null,
  derivedFeatureContract = null,
  screenMirrorX = false,
} = {}) {
  const requestedSchemaId = landmarkSchemaId || exercise?.landmarkSchemaId || null;
  const schema = landmarkSchema || (requestedSchemaId
    ? resolveBodyRegionLandmarkSchema(requestedSchemaId, { fallback: false })
    : (exercise?.bodyRegion ? getBodyRegionLandmarkSchema(exercise) : null));
  const schemaMissing = !!requestedSchemaId && !schema;
  // MediaPipe reads the unmirrored camera pixels even when the live preview is
  // rendered as a selfie. Project into the displayed coordinate system before
  // assigning left/right slots so screen.v1 means the same thing for imported
  // datasets, live validation, and patient practice.
  const projectedLandmarks = projectLandmarksToDisplayedScreen(frame.landmarks, { screenMirrorX });
  const screenLandmarks = normalizePoseLandmarksToScreenSide(projectedLandmarks);
  const selectedLandmarks = schemaMissing ? [] : landmarksForSchema(screenLandmarks, schema, landmarkCount);
  const normalized = schemaMissing
    ? { landmarks: [], normalization: null }
    : normalizeLandmarkTuples(screenLandmarks, selectedLandmarks, {
        mirrorX: schema?.canonicalMirrorX === true,
      });
  const landmarks = normalized.landmarks;
  const angles = cleanAngles(frame.angles || frame.jointAngles || {});
  const requestedJoints = joints.length ? joints : schema?.jointNames;
  const orderedJoints = schemaMissing ? [] : featureJoints(requestedJoints, angles);
  const previousAngles = previousFrame ? cleanAngles(previousFrame.angles || previousFrame.jointAngles || {}) : {};
  const dtMs = previousFrame ? timestampOf(frame) - timestampOf(previousFrame) : 0;
  const velocities = angleVelocity(angles, previousAngles, dtMs, orderedJoints);
  const boundaryStatus = frame.boundaryStatus || frame.boundary?.status || 'unknown';
  const visibilityScore = finiteNumber(
    frame.visibilityScore,
    meanVisibility(landmarks) * 100,
  );
  const progressEstimate = finiteNumber(progress ?? frame.progress ?? frame.progressPct, 0);
  const derivedFeatures = extractDerivedMotionFeatures(derivedFeatureContract, {
    landmarks,
    modelInputLandmarks: schema?.modelInputLandmarks || [],
  });

  const featureVector = schemaMissing ? [] : [
    ...landmarks.flat(),
    ...orderedJoints.map((joint) => normalizedAngle(angles[joint])),
    ...orderedJoints.map((joint) => normalizedAngularVelocity(velocities[joint])),
    ...derivedFeatures.values,
  ];

  return {
    version: MOTION_FEATURE_SCHEMA_VERSION,
    t: timestampOf(frame),
    landmarks,
    angles,
    angleVelocity: velocities,
    joints: orderedJoints,
    progress: progressEstimate,
    boundaryStatus,
    insideFrame: boundaryStatus === 'inside',
    visibilityScore,
    featureVector,
    landmarkSchemaId: schema?.id || requestedSchemaId || null,
    modelInputLandmarks: schema?.modelInputLandmarks ? [...schema.modelInputLandmarks] : null,
    landmarkSideConvention: schema?.landmarkSideConvention || LANDMARK_SIDE_CONVENTION,
    normalization: normalized.normalization,
    canonicalMirrorX: schema?.canonicalMirrorX === true,
    screenMirrorX: screenMirrorX === true,
    derivedFeatureContract: derivedFeatures.contract,
    derivedFeatureNames: derivedFeatures.names,
    derivedFeatureValues: derivedFeatures.values,
    featureSize: featureVector.length,
    schemaMissing,
  };
}

export function expectedMotionFeatureSizeForSchema({
  landmarkSchemaId = null,
  landmarkSchema = null,
  exercise = null,
  joints = [],
  landmarkCount = DEFAULT_LANDMARK_COUNT,
  derivedFeatureContract = null,
} = {}) {
  const requestedSchemaId = landmarkSchemaId || exercise?.landmarkSchemaId || null;
  const schema = landmarkSchema || (requestedSchemaId
    ? resolveBodyRegionLandmarkSchema(requestedSchemaId, { fallback: false })
    : (exercise?.bodyRegion ? getBodyRegionLandmarkSchema(exercise) : null));
  if (requestedSchemaId && !schema) return 0;
  const landmarkSize = (schema?.modelInputLandmarks?.length || landmarkCount) * 4;
  const orderedJoints = featureJoints(joints.length ? joints : schema?.jointNames, {});
  return landmarkSize + orderedJoints.length * 2 + derivedMotionFeatureNames(derivedFeatureContract).length;
}

export function extractMotionFeatureWindow(frames = [], options = {}) {
  const list = Array.isArray(frames) ? frames : [];
  return list.map((frame, index) => extractMotionFeatures(frame, {
    ...options,
    previousFrame: index > 0 ? list[index - 1] : null,
  }));
}

export function featureVectorsFromWindow(frames = [], options = {}) {
  return extractMotionFeatureWindow(frames, options).map((features) => features.featureVector);
}
