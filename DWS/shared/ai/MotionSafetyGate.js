import {
  LANDMARK_SIDE_CONVENTION,
  idx,
  normalizePoseLandmarksToScreenSide,
} from './Landmarks.js';
import { getBodyRegionLandmarkSchema, resolveBodyRegionLandmarkSchema } from './BodyRegionLandmarkSchema.js';
import { CAMERA_VIEW_STATUSES, evaluateCameraView } from './CameraViewGate.js';
import { landmarkListLabel } from '../core/landmark-labels.js';

export const MOTION_SAFETY_STATUSES = Object.freeze({
  READY: 'ready',
  NO_POSE: 'no_pose',
  MISSING_PRIMARY_REQUIRED: 'missing_primary_required',
  MISSING_STABILIZER_REQUIRED: 'missing_stabilizer_required',
  LOW_VISIBILITY: 'low_visibility',
  OUT_OF_FRAME: 'out_of_frame',
  MISSING_SCHEMA: 'missing_schema',
  CAMERA_VIEW_UNAVAILABLE: CAMERA_VIEW_STATUSES.UNAVAILABLE,
  CAMERA_VIEW_UNCERTAIN: CAMERA_VIEW_STATUSES.UNCERTAIN,
  WRONG_CAMERA_VIEW: CAMERA_VIEW_STATUSES.WRONG_VIEW,
  WRONG_CAMERA_SIDE: CAMERA_VIEW_STATUSES.WRONG_SIDE,
});

const DEFAULT_BOX = Object.freeze({
  left: 0.025,
  top: 0.025,
  right: 0.975,
  bottom: 0.975,
  width: 0.95,
  height: 0.95,
});

function finitePoint(point) {
  return !!point && Number.isFinite(point.x) && Number.isFinite(point.y);
}

function insideBox(point, box = DEFAULT_BOX) {
  return point.x >= box.left && point.x <= box.right && point.y >= box.top && point.y <= box.bottom;
}

function pointFor(landmarks, name) {
  const index = idx(name);
  return index >= 0 ? landmarks?.[index] || null : null;
}

function evaluateGroup(landmarks, names, { minVisibility, boundaryBox, requireInside }) {
  const visible = [];
  const missing = [];
  const lowVisibility = [];
  const inside = [];
  const outside = [];

  for (const name of names || []) {
    const point = pointFor(landmarks, name);
    if (!finitePoint(point)) {
      missing.push(name);
      continue;
    }
    const visibility = Number(point.visibility ?? 1);
    if (!Number.isFinite(visibility) || visibility < minVisibility) {
      lowVisibility.push(name);
      continue;
    }
    visible.push(name);
    if (!requireInside || insideBox(point, boundaryBox)) inside.push(name);
    else outside.push(name);
  }

  const total = names?.length || 0;
  return {
    names: [...(names || [])],
    visible,
    missing,
    lowVisibility,
    inside,
    outside,
    visibilityRatio: total ? visible.length / total : 1,
    insideRatio: total ? inside.length / total : 1,
  };
}

function hintFor(status, primary, stabilizer, cameraView = null) {
  if (cameraView && status === cameraView.status) {
    return { hint: cameraView.hint, hintTh: cameraView.hintTh };
  }
  if (status === MOTION_SAFETY_STATUSES.READY) {
    return { hint: 'Ready to record AI dataset', hintTh: 'พร้อมเก็บข้อมูลฝึก AI' };
  }
  if (status === MOTION_SAFETY_STATUSES.NO_POSE) {
    return { hint: 'Step into the camera frame', hintTh: 'เข้ากรอบกล้องก่อน' };
  }
  if (status === MOTION_SAFETY_STATUSES.MISSING_PRIMARY_REQUIRED) {
    const names = primary.missing.length ? primary.missing : primary.lowVisibility;
    return {
      hint: `Missing primary landmarks: ${landmarkListLabel(names, 'en')}`,
      hintTh: `ยังไม่เห็นจุดหลักครบ: ${landmarkListLabel(names, 'th')}`,
    };
  }
  if (status === MOTION_SAFETY_STATUSES.MISSING_STABILIZER_REQUIRED) {
    const names = stabilizer.missing.length ? stabilizer.missing : stabilizer.lowVisibility;
    return {
      hint: `Primary is visible, but stabilizers are missing: ${landmarkListLabel(names, 'en')}`,
      hintTh: `เห็นส่วนหลักแล้ว แต่ต้องเห็นจุดช่วยทรงตัว: ${landmarkListLabel(names, 'th')}`,
    };
  }
  if (status === MOTION_SAFETY_STATUSES.LOW_VISIBILITY) {
    const names = [...primary.lowVisibility, ...stabilizer.lowVisibility];
    return names.length
      ? {
        hint: `Low visibility: ${landmarkListLabel(names, 'en')}`,
        hintTh: `เห็นไม่ชัด: ${landmarkListLabel(names, 'th')}`,
      }
      : { hint: 'Improve landmark visibility before recording', hintTh: 'ปรับแสงหรือถอยกล้องให้เห็นจุดสำคัญชัดขึ้น' };
  }
  if (status === MOTION_SAFETY_STATUSES.OUT_OF_FRAME) {
    const names = [...primary.outside, ...stabilizer.outside];
    return names.length
      ? {
        hint: `Outside frame: ${landmarkListLabel(names, 'en')}`,
        hintTh: `อยู่นอกกรอบ: ${landmarkListLabel(names, 'th')}`,
      }
      : { hint: 'Move the required landmarks inside the frame', hintTh: 'ขยับให้จุดสำคัญอยู่ในกรอบ' };
  }
  return { hint: 'Schema not ready', hintTh: 'schema ของท่ายังไม่พร้อม' };
}

export function evaluateMotionSafetyGate(landmarks, {
  exercise = {},
  landmarkSchemaId = null,
  landmarkSchema = null,
  boundaryBox = DEFAULT_BOX,
  minVisibility = null,
} = {}) {
  const requestedSchemaId = landmarkSchemaId || exercise?.landmarkSchemaId || null;
  const schema = landmarkSchema || (requestedSchemaId
    ? resolveBodyRegionLandmarkSchema(requestedSchemaId, { fallback: false })
    : getBodyRegionLandmarkSchema(exercise));
  if (!schema?.id) {
    const hint = hintFor(MOTION_SAFETY_STATUSES.MISSING_SCHEMA, {}, {});
    return {
      ok: false,
      trainable: false,
      scoreable: false,
      status: MOTION_SAFETY_STATUSES.MISSING_SCHEMA,
      dataQuality: MOTION_SAFETY_STATUSES.MISSING_SCHEMA,
      schemaId: requestedSchemaId,
      landmarkSideConvention: LANDMARK_SIDE_CONVENTION,
      primary: { names: [], visible: [], missing: [], lowVisibility: [], inside: [], outside: [], visibilityRatio: 0, insideRatio: 0 },
      stabilizer: { names: [], visible: [], missing: [], lowVisibility: [], inside: [], outside: [], visibilityRatio: 0, insideRatio: 0 },
      missingPrimary: [],
      missingStabilizer: [],
      ...hint,
    };
  }

  if (!Array.isArray(landmarks) || !landmarks.length) {
    const primary = {
      names: [...(schema.boundaryPrimaryLandmarks || schema.primaryRequiredLandmarks)],
      visible: [],
      missing: [...(schema.boundaryPrimaryLandmarks || schema.primaryRequiredLandmarks)],
      lowVisibility: [],
      inside: [],
      outside: [],
      visibilityRatio: 0,
      insideRatio: 0,
    };
    const stabilizer = {
      names: [...(schema.boundaryStabilizerLandmarks || schema.stabilizerRequiredLandmarks)],
      visible: [],
      missing: [...(schema.boundaryStabilizerLandmarks || schema.stabilizerRequiredLandmarks)],
      lowVisibility: [],
      inside: [],
      outside: [],
      visibilityRatio: 0,
      insideRatio: 0,
    };
    const hint = hintFor(MOTION_SAFETY_STATUSES.NO_POSE, primary, stabilizer);
    return {
      ok: false,
      trainable: false,
      scoreable: false,
      status: MOTION_SAFETY_STATUSES.NO_POSE,
      dataQuality: MOTION_SAFETY_STATUSES.NO_POSE,
      schemaId: schema.id,
      landmarkSideConvention: schema.landmarkSideConvention || LANDMARK_SIDE_CONVENTION,
      primary,
      stabilizer,
      missingPrimary: primary.missing,
      missingStabilizer: stabilizer.missing,
      ...hint,
    };
  }

  const policy = schema.boundaryPolicy || {};
  const screenLandmarks = normalizePoseLandmarksToScreenSide(landmarks);
  const visibility = Number(minVisibility ?? exercise?.minVisibility ?? schema.minVisibility ?? 0.6);
  const stabilizerVisibility = Number(
    exercise?.stabilizerMinVisibility ?? schema.stabilizerMinVisibility ?? visibility,
  );
  const primary = evaluateGroup(screenLandmarks, schema.boundaryPrimaryLandmarks || schema.primaryRequiredLandmarks, {
    minVisibility: visibility,
    boundaryBox,
    requireInside: policy.requirePrimaryInside !== false,
  });
  const stabilizer = evaluateGroup(screenLandmarks, schema.boundaryStabilizerLandmarks || schema.stabilizerRequiredLandmarks, {
    minVisibility: stabilizerVisibility,
    boundaryBox,
    requireInside: policy.requireStabilizerInside !== false,
  });
  const cameraView = evaluateCameraView(screenLandmarks, { exercise, minVisibility: Math.min(visibility, 0.35) });

  const missingPrimary = [...primary.missing, ...primary.lowVisibility];
  const missingStabilizer = [...stabilizer.missing, ...stabilizer.lowVisibility];
  let status = MOTION_SAFETY_STATUSES.READY;
  if (primary.missing.length) status = MOTION_SAFETY_STATUSES.MISSING_PRIMARY_REQUIRED;
  else if (stabilizer.missing.length) status = MOTION_SAFETY_STATUSES.MISSING_STABILIZER_REQUIRED;
  else if (primary.lowVisibility.length || stabilizer.lowVisibility.length) status = MOTION_SAFETY_STATUSES.LOW_VISIBILITY;
  else if (
    primary.visibilityRatio < (policy.minPrimaryVisibleRatio ?? 0.9) ||
    stabilizer.visibilityRatio < (policy.minStabilizerVisibleRatio ?? 0.9)
  ) status = MOTION_SAFETY_STATUSES.LOW_VISIBILITY;
  else if (
    primary.outside.length ||
    stabilizer.outside.length ||
    Math.min(primary.insideRatio, stabilizer.insideRatio) < (policy.minBoundaryInsideRatio ?? 0.9)
  ) status = MOTION_SAFETY_STATUSES.OUT_OF_FRAME;
  else if (!cameraView.ok) status = cameraView.status;

  const ok = status === MOTION_SAFETY_STATUSES.READY;
  const hint = hintFor(status, primary, stabilizer, cameraView);
  return {
    ok,
    trainable: ok,
    scoreable: ok,
    status,
    dataQuality: ok ? 'usable' : status,
    schemaId: schema.id,
    landmarkSideConvention: schema.landmarkSideConvention || LANDMARK_SIDE_CONVENTION,
    primary,
    stabilizer,
    missingPrimary,
    missingStabilizer,
    cameraView,
    ...hint,
  };
}
