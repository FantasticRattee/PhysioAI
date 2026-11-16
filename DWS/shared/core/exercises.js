// PhysioAI exercise library.
// Capture owns therapist-created exercises; installed native exercises are
// resolved separately and can be prescribed without becoming Capture templates.

import {
  defaultLandmarkSchemaIdForBodyRegion,
  landmarkSchemaMetadataForExercise,
} from '../ai/BodyRegionLandmarkSchema.js';
import {
  CAMERA_VIEW_OPTIONS,
  cameraViewContract,
  cameraViewInstruction,
  normalizeCameraView,
} from '../ai/CameraViewGate.js';
import {
  getInstalledProductionExercise,
  installedProductionExerciseSnapshot,
  isInstalledProductionExercise,
} from './installed-exercises.js';

export { CAMERA_VIEW_OPTIONS };

const DEFAULT_EXERCISE_METADATA = Object.freeze({
  templateOnly: true,
  landmarkSchemaId: null,
  activeModelId: null,
  modelStatus: 'not_trained',
  cameraOrientation: 'front',
  cameraSide: 'any',
  cameraView: 'front',
  recommendedCameraDistanceM: [1.5, 3.0],
  recommendedCameraHeight: 'chest',
  minVisibility: 0.6,
  minUsableJointRatio: 0.8,
  minROMDeg: 15,
  minRepMs: 600,
  maxRepMs: 12000,
  feedbackProfile: 'simple_patient',
  allow3D: false,
  allowMirror: true,
  allowSeated: true,
  contraindicationNote: '',
});

const EXERCISE_METADATA = {};

export const EXERCISES = Object.freeze([]);
export const isBuiltin = (id) => isInstalledProductionExercise(id);
export const REMOVED_LEGACY_EXERCISE_IDS = Object.freeze(['shoulder', 'knee', 'hip', 'squat', 'balance']);
const REMOVED_LEGACY_EXERCISE_ID_SET = new Set(REMOVED_LEGACY_EXERCISE_IDS);
export function isRemovedLegacyExerciseId(id) {
  return REMOVED_LEGACY_EXERCISE_ID_SET.has(String(id || ''));
}

export const BODY_REGIONS = [
  { id: 'full', label: 'Whole Body', labelTh: 'ทั้งตัว' },
  { id: 'upper', label: 'Upper Body', labelTh: 'ส่วนบน' },
  { id: 'lower', label: 'Lower Body', labelTh: 'ส่วนล่าง' },
  { id: 'shoulder', label: 'Shoulder', labelTh: 'ไหล่' },
  { id: 'left_arm', label: 'Left Arm', labelTh: 'แขนซ้าย' },
  { id: 'right_arm', label: 'Right Arm', labelTh: 'แขนขวา' },
  { id: 'left_leg', label: 'Left Leg', labelTh: 'ขาซ้าย' },
  { id: 'right_leg', label: 'Right Leg', labelTh: 'ขาขวา' },
  { id: 'seated_balance', label: 'Seated Balance', labelTh: 'การทรงตัวในท่านั่ง' },
];
export const MOVEMENT_PATTERNS = [
  { id: 'bilateralSync', label: 'Both sides together / auto', labelTh: 'สองข้างพร้อมกัน / อัตโนมัติ' },
  { id: 'unilateral', label: 'One side', labelTh: 'ข้างเดียว' },
  { id: 'alternating', label: 'Alternating left/right', labelTh: 'สลับซ้าย/ขวา' },
];
export const COUNT_MODES = [
  { id: 'per_side', label: 'Count each side', labelTh: 'นับทีละข้าง' },
  { id: 'cycle', label: 'Left + right = 1 rep', labelTh: 'ซ้าย+ขวา = 1 ครั้ง' },
];
const BODY_REGION_ALIASES = {
  whole: 'full',
  whole_body: 'full',
  full_body: 'full',
};
export function normalizeBodyRegionId(bodyRegion = 'full') {
  const id = BODY_REGION_ALIASES[bodyRegion] || bodyRegion;
  return BODY_REGIONS.some((r) => r.id === id) ? id : 'full';
}
export function defaultPrimaryJoint(bodyRegion = 'full') {
  const region = normalizeBodyRegionId(bodyRegion);
  if (region === 'upper' || region === 'shoulder' || region === 'right_arm') return 'right_shoulder';
  if (region === 'left_arm') return 'left_shoulder';
  if (region === 'lower' || region === 'right_leg') return 'right_knee';
  if (region === 'left_leg') return 'left_knee';
  return 'right_knee';
}
export function inferBodyRegion(primaryJoint) {
  if (!primaryJoint) return 'full';
  if (primaryJoint === 'neck') return 'shoulder';
  if (primaryJoint === 'left_shoulder' || primaryJoint === 'left_elbow') return 'left_arm';
  if (primaryJoint === 'right_shoulder' || primaryJoint === 'right_elbow') return 'right_arm';
  if (primaryJoint.includes('shoulder')) return 'shoulder';
  if (primaryJoint === 'left_hip' || primaryJoint === 'left_knee' || primaryJoint === 'left_ankle') return 'left_leg';
  if (primaryJoint === 'right_hip' || primaryJoint === 'right_knee' || primaryJoint === 'right_ankle') return 'right_leg';
  return 'full';
}
export function getBodyRegion(ex) {
  return ex?.bodyRegion ? normalizeBodyRegionId(ex.bodyRegion) : inferBodyRegion(ex?.primaryJoint);
}

export function exerciseMetadata(ex = {}) {
  return { ...DEFAULT_EXERCISE_METADATA, ...(EXERCISE_METADATA[ex.id] || {}), ...ex };
}

export function requiredJointsForExercise(ex = {}) {
  const metadata = exerciseMetadata(ex);
  if (Array.isArray(metadata.requiredJoints) && metadata.requiredJoints.length) {
    return [...new Set(metadata.requiredJoints.filter(Boolean))];
  }
  return [metadata.primaryJoint || defaultPrimaryJoint(metadata.bodyRegion)].filter(Boolean);
}

export function scoringProfileForExercise(ex = {}) {
  return exerciseMetadata(ex).scoringProfile || (ex.type === 'hold' ? 'static_hold' : 'default_rep');
}

// ── Custom exercises (therapist-created via Capture) — persisted locally ──
// When assigned in Plan Builder, a snapshot is embedded in the patient plan.
const CUSTOM_KEY = 'physioai.v1.exercises.custom';
function normalizeCustomExercise(exercise) {
  if (!exercise || typeof exercise !== 'object' || Array.isArray(exercise)) return null;
  const id = String(exercise.id || '').trim();
  if (!id || isRemovedLegacyExerciseId(id)) return null;
  const bodyRegion = normalizeBodyRegionId(exercise.bodyRegion);
  const cameraView = normalizeCameraView(exercise);
  const camera = cameraViewContract(cameraView);
  const base = {
    ...exercise,
    id,
    key: exercise.key || id,
    source: 'custom',
    bodyRegion,
    cameraView,
    cameraOrientation: camera.orientation,
    cameraSide: camera.side,
    label: exercise.label || exercise.labelTh || exercise.title || id,
    labelTh: exercise.labelTh || exercise.label || exercise.title || id,
  };
  return { ...base, ...landmarkSchemaMetadataForExercise(base) };
}

function normalizeCustomList(list) {
  const byId = new Map();
  for (const item of Array.isArray(list) ? list : []) {
    const normalized = normalizeCustomExercise(item);
    if (normalized) byId.set(normalized.id, normalized);
  }
  return [...byId.values()];
}

function readCustom() {
  try {
    const r = localStorage.getItem(CUSTOM_KEY);
    return normalizeCustomList(r ? JSON.parse(r) : []);
  }
  catch { return []; }
}
function writeCustom(list) {
  const normalized = normalizeCustomList(list);
  try { localStorage.setItem(CUSTOM_KEY, JSON.stringify(normalized)); } catch {}
  return normalized;
}

async function exerciseApi() {
  return import('./api.js');
}

export async function syncCustomExercisesFromApi({ get = null, put = null } = {}) {
  const apiGet = get || (await exerciseApi()).apiGet;
  const rows = await apiGet('/exercises');
  const remote = normalizeCustomList(rows);
  const local = readCustom();
  if (!remote.length && local.length) {
    await Promise.all(local.map((exercise) =>
      pushCustomExerciseToApi(exercise, { put }).catch(() => null),
    ));
    return writeCustom(local);
  }
  return writeCustom(remote);
}

export async function pushCustomExerciseToApi(exercise, { method = 'PUT', post = null, put = null } = {}) {
  const normalized = normalizeCustomExercise(exercise);
  if (!normalized) return null;
  const api = (!post || !put) ? await exerciseApi() : null;
  const save = method === 'POST'
    ? (post || api.apiPost)
    : (put || api.apiPut);
  return save('/exercises', normalized);
}

export async function deleteCustomExerciseFromApi(id, { del = null } = {}) {
  const exerciseId = String(id || '').trim();
  if (!exerciseId) return null;
  const apiDelete = del || (await exerciseApi()).apiDelete;
  return apiDelete(`/exercises?exerciseId=${encodeURIComponent(exerciseId)}`);
}

export function getCustomExercises() { return readCustom(); }
export function getExercises() { return readCustom(); }
export const exerciseExists = (id) => getExercise(id) != null;
export function getExercise(id) {
  return getExercises().find((e) => e.id === id) || getInstalledProductionExercise(id);
}

export function updateCustomExercise(id, patch) {
  const list = readCustom();
  const idx = list.findIndex((e) => e.id === id);
  if (idx < 0) { const err = new Error('not-found'); err.code = 'not-found'; throw err; }
  const merged = { ...list[idx], ...patch, id: list[idx].id, source: 'custom' };
  if (patch?.bodyRegion && normalizeBodyRegionId(patch.bodyRegion) !== normalizeBodyRegionId(list[idx].bodyRegion)) {
    merged.landmarkSchemaId = defaultLandmarkSchemaIdForBodyRegion(merged.bodyRegion);
  }
  if (!merged.landmarkSchemaId && merged.bodyRegion) {
    merged.landmarkSchemaId = defaultLandmarkSchemaIdForBodyRegion(merged.bodyRegion);
  }
  const next = { ...merged, ...landmarkSchemaMetadataForExercise(merged) };
  const out = list.slice();
  out[idx] = next;
  writeCustom(out);
  void pushCustomExerciseToApi(next).catch(() => {});
  return next;
}

export function exerciseSnapshot(ex) {
  if (isInstalledProductionExercise(ex)) return installedProductionExerciseSnapshot(ex);
  if (!ex || ex.source !== 'custom') return null;
  return {
    id: ex.id, key: ex.key, source: 'custom',
    label: ex.label, labelTh: ex.labelTh,
    icon: ex.icon, accent: ex.accent, category: ex.category,
    primaryJoint: ex.primaryJoint,
    bodyRegion: ex.bodyRegion,
    type: ex.type, dir: ex.dir,
    target: ex.target, rest: ex.rest, tol: ex.tol,
    reps: ex.reps, sets: ex.sets, holdSec: ex.holdSec,
    repMode: ex.repMode,
    movementPattern: ex.movementPattern,
    alternatingSides: ex.alternatingSides,
    countMode: ex.countMode,
    repJoints: ex.repJoints,
    primaryJoints: ex.primaryJoints,
    requestedRepJoints: ex.requestedRepJoints,
    dominantJoint: ex.dominantJoint,
    jointMotion: ex.jointMotion,
    sideMotions: ex.sideMotions,
    jointAngles: ex.jointAngles,
    restJointAngles: ex.restJointAngles,
    targetJointAngles: ex.targetJointAngles,
    targetJointAnglesBySide: ex.targetJointAnglesBySide,
    landmarks: ex.landmarks,
    restLandmarks: ex.restLandmarks,
    targetLandmarks: ex.targetLandmarks,
    targetLandmarksBySide: ex.targetLandmarksBySide,
    returnRestJointAngles: ex.returnRestJointAngles,
    returnRestLandmarks: ex.returnRestLandmarks,
    referenceSequence: ex.referenceSequence,
    cameraOrientation: ex.cameraOrientation,
    cameraSide: ex.cameraSide,
    cameraView: normalizeCameraView(ex),
    recommendedCameraDistanceM: ex.recommendedCameraDistanceM,
    recommendedCameraHeight: ex.recommendedCameraHeight,
    requiredJoints: ex.requiredJoints,
    optionalJoints: ex.optionalJoints,
    landmarkSchemaId: ex.landmarkSchemaId,
    templateOnly: ex.templateOnly,
    activeModelId: ex.activeModelId,
    modelStatus: ex.modelStatus,
    primaryRequiredLandmarks: ex.primaryRequiredLandmarks,
    stabilizerRequiredLandmarks: ex.stabilizerRequiredLandmarks,
    modelInputLandmarks: ex.modelInputLandmarks,
    jointNames: ex.jointNames,
    featureSchemaVersion: ex.featureSchemaVersion,
    minVisibility: ex.minVisibility,
    minUsableJointRatio: ex.minUsableJointRatio,
    minROMDeg: ex.minROMDeg,
    minRepMs: ex.minRepMs,
    maxRepMs: ex.maxRepMs,
    movementPlane: ex.movementPlane,
    scoringProfile: ex.scoringProfile,
    targetOutcomePolicy: ex.targetOutcomePolicy,
    feedbackProfile: ex.feedbackProfile,
    allow3D: ex.allow3D,
    allowMirror: ex.allowMirror,
    allowSeated: ex.allowSeated,
    setupInstructionTh: ex.setupInstructionTh,
    setupInstructionEn: ex.setupInstructionEn,
    contraindicationNote: ex.contraindicationNote,
  };
}

// Display label for therapist-created exercises.
export function exLabel(ex, t) {
  if (!ex) return '';
  return ex.label || ex.labelTh || ex.title || ex.id || '';
}

// Create + persist a custom exercise from Capture's "New exercise" form.
// Input { label, bodyRegion, type:'rep'|'hold' } → full exercise object (also returned).
// For rep exercises, Capture records rest + target and then auto-selects the
// multi-joint rep model from the chosen body region.
export function saveCustomExercise({ label, bodyRegion, type = 'rep', movementPattern = 'bilateralSync', countMode = 'per_side', cameraView = 'front' }) {
  const name = (label || '').trim();
  const region = normalizeBodyRegionId(bodyRegion);
  if (!name || !bodyRegion || !BODY_REGIONS.some((r) => r.id === region)) { const err = new Error('required'); err.code = 'required'; throw err; }
  const pattern = MOVEMENT_PATTERNS.some((p) => p.id === movementPattern) ? movementPattern : 'bilateralSync';
  const mode = COUNT_MODES.some((m) => m.id === countMode) ? countMode : 'per_side';
  const primaryJoint = defaultPrimaryJoint(region);
  const view = normalizeCameraView(cameraView);
  const camera = cameraViewContract(view);
  const id = 'cust_' + Date.now().toString(36);
  const hold = type === 'hold';
  const ex = {
    ...DEFAULT_EXERCISE_METADATA,
    id, key: id, source: 'custom', icon: 'body', accent: '#7BA88F',
    label: name, labelTh: name,
    primaryJoint, bodyRegion: region, type: hold ? 'hold' : 'rep', dir: hold ? 'hold' : 'up',
    cameraView: view, cameraOrientation: camera.orientation, cameraSide: camera.side,
    templateOnly: false,
    landmarkSchemaId: defaultLandmarkSchemaIdForBodyRegion(region),
    activeModelId: null,
    modelStatus: 'collecting_data',
    target: hold ? 90 : 120, rest: hold ? 90 : 30,
    tol: primaryJoint.includes('elbow') || primaryJoint === 'back' || primaryJoint === 'neck' ? 12 : 15,
    reps: 10, sets: 3, holdSec: hold ? 10 : 1.5,
    autoPrimaryJoint: true,
    pendingAutoPrimary: !hold,
    repMode: hold ? 'single' : (pattern === 'alternating' ? 'alternating' : 'multi'),
    movementPattern: hold ? 'unilateral' : pattern,
    alternatingSides: pattern === 'alternating' ? ['left', 'right'] : undefined,
    countMode: pattern === 'alternating' ? mode : undefined,
    requiredJoints: [primaryJoint, ...(region.includes('arm') ? [primaryJoint.replace('shoulder', 'elbow')] : [])].filter(Boolean),
    optionalJoints: [],
    movementPlane: camera.orientation === 'side' ? 'sagittal' : (region.includes('arm') || region === 'shoulder' ? 'frontal' : 'sagittal'),
    scoringProfile: hold ? 'static_hold' : 'default_rep',
    setupInstructionTh: cameraViewInstruction(view, 'th'),
    setupInstructionEn: cameraViewInstruction(view, 'en'),
  };
  const withSchema = { ...ex, ...landmarkSchemaMetadataForExercise(ex) };
  writeCustom([...readCustom().filter((e) => e.id !== id), withSchema]);
  void pushCustomExerciseToApi(withSchema, { method: 'POST' }).catch(() => {});
  return withSchema;
}
export function deleteCustomExercise(id) {
  writeCustom(readCustom().filter((e) => e.id !== id));
  void deleteCustomExerciseFromApi(id).catch(() => {});
}
