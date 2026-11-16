import { idx } from './Landmarks.js';

export const CAMERA_VIEW_OPTIONS = Object.freeze([
  Object.freeze({ id: 'front', orientation: 'front', side: 'any', label: 'Front', labelTh: 'หันหน้า' }),
  Object.freeze({ id: 'left_side', orientation: 'side', side: 'left', label: 'Left side', labelTh: 'หันข้างซ้าย' }),
  Object.freeze({ id: 'right_side', orientation: 'side', side: 'right', label: 'Right side', labelTh: 'หันข้างขวา' }),
]);

export const CAMERA_VIEW_STATUSES = Object.freeze({
  READY: 'ready',
  UNAVAILABLE: 'camera_view_unavailable',
  UNCERTAIN: 'camera_view_uncertain',
  WRONG_VIEW: 'wrong_camera_view',
  WRONG_SIDE: 'wrong_camera_side',
});

const CAMERA_VIEW_BY_ID = new Map(CAMERA_VIEW_OPTIONS.map((option) => [option.id, option]));
const VIEW_ALIASES = Object.freeze({
  front_view: 'front',
  left: 'left_side',
  side_left: 'left_side',
  right: 'right_side',
  side_right: 'right_side',
});

export function normalizeCameraView(value = 'front') {
  if (value && typeof value === 'object') {
    const explicit = normalizeCameraView(value.cameraView || '');
    if (value.cameraView && explicit) return explicit;
    const orientation = String(value.cameraOrientation || value.orientation || 'front').toLowerCase();
    const side = String(value.cameraSide || value.side || 'any').toLowerCase();
    if (orientation === 'side' && side === 'left') return 'left_side';
    if (orientation === 'side' && side === 'right') return 'right_side';
    if (orientation === 'side') return 'side';
    return 'front';
  }
  const id = VIEW_ALIASES[String(value || '').toLowerCase()] || String(value || '').toLowerCase();
  if (id === 'side' || CAMERA_VIEW_BY_ID.has(id)) return id;
  return 'front';
}

export function cameraViewContract(value = 'front') {
  const id = normalizeCameraView(value);
  if (id === 'side') return { id, orientation: 'side', side: 'any' };
  const option = CAMERA_VIEW_BY_ID.get(id) || CAMERA_VIEW_BY_ID.get('front');
  return { id: option.id, orientation: option.orientation, side: option.side };
}

export function cameraViewLabel(value = 'front', lang = 'en') {
  const id = normalizeCameraView(value);
  if (id === 'side') return lang === 'th' ? 'หันข้าง' : 'Side';
  const option = CAMERA_VIEW_BY_ID.get(id) || CAMERA_VIEW_BY_ID.get('front');
  return lang === 'th' ? option.labelTh : option.label;
}

export function cameraViewInstruction(value = 'front', lang = 'en') {
  const view = cameraViewContract(value);
  if (view.orientation === 'front') {
    return lang === 'th' ? 'หันหน้าเข้ากล้องให้เห็นจุดสำคัญครบ' : 'Face the camera with all required landmarks visible.';
  }
  if (view.side === 'left') {
    return lang === 'th' ? 'หันลำตัวด้านซ้ายเข้ากล้อง' : 'Turn your left side toward the camera.';
  }
  if (view.side === 'right') {
    return lang === 'th' ? 'หันลำตัวด้านขวาเข้ากล้อง' : 'Turn your right side toward the camera.';
  }
  return lang === 'th' ? 'หันข้างเข้ากล้อง' : 'Turn sideways to the camera.';
}

function pointFor(landmarks, name, minVisibility) {
  const point = landmarks?.[idx(name)];
  if (!point || !Number.isFinite(point.x) || !Number.isFinite(point.y)) return null;
  if (Number(point.visibility ?? 1) < minVisibility) return null;
  return point;
}

function distance2d(a, b) {
  return Math.hypot(Number(a.x) - Number(b.x), Number(a.y) - Number(b.y));
}

function average(values = []) {
  const finite = values.map(Number).filter(Number.isFinite);
  return finite.length ? finite.reduce((sum, value) => sum + value, 0) / finite.length : null;
}

function viewHint(status, expectedView, detectedView = null) {
  const expectedEn = cameraViewLabel(expectedView, 'en');
  const expectedTh = cameraViewLabel(expectedView, 'th');
  if (status === CAMERA_VIEW_STATUSES.READY) {
    return { hint: `${expectedEn} camera view ready`, hintTh: `มุมกล้อง${expectedTh}พร้อมแล้ว` };
  }
  if (status === CAMERA_VIEW_STATUSES.UNAVAILABLE) {
    return { hint: 'Keep both shoulders and hips visible to check camera view', hintTh: 'จัดให้เห็นหัวไหล่และสะโพกเพื่อเช็กมุมกล้อง' };
  }
  if (status === CAMERA_VIEW_STATUSES.UNCERTAIN) {
    return { hint: `Turn clearly to the required ${expectedEn.toLowerCase()} view`, hintTh: `ปรับตัวให้เป็นมุม${expectedTh}ชัดเจนขึ้น` };
  }
  if (status === CAMERA_VIEW_STATUSES.WRONG_SIDE) {
    return { hint: `Wrong side detected; use the ${expectedEn.toLowerCase()} view`, hintTh: `หันผิดด้าน กรุณา${expectedTh}` };
  }
  return {
    hint: `Camera view is ${detectedView || 'incorrect'}; use ${expectedEn.toLowerCase()}`,
    hintTh: `มุมกล้องไม่ตรงกับท่านี้ กรุณา${expectedTh}`,
  };
}

export function evaluateCameraView(landmarks, {
  exercise = {},
  cameraView = null,
  minVisibility = 0.2,
  frontMinRatio = 0.32,
  sideMaxRatio = 0.2,
  minDepthSeparation = 0.04,
} = {}) {
  const expectedView = normalizeCameraView(cameraView || exercise);
  const expected = cameraViewContract(expectedView);
  const names = ['left_shoulder', 'right_shoulder', 'left_hip', 'right_hip', 'nose'];
  const points = Object.fromEntries(names.map((name) => [name, pointFor(landmarks, name, minVisibility)]));
  const missing = ['left_shoulder', 'right_shoulder'].filter((name) => !points[name]);
  const hasHipPair = Boolean(points.left_hip && points.right_hip);
  if (missing.length || (!hasHipPair && !points.nose)) {
    const status = CAMERA_VIEW_STATUSES.UNAVAILABLE;
    const unavailable = [...missing, ...(!hasHipPair && !points.nose ? ['nose'] : [])];
    return { ok: false, status, expectedView, detectedView: null, missing: unavailable, ...viewHint(status, expectedView) };
  }

  const shoulderSpan = distance2d(points.left_shoulder, points.right_shoulder);
  const hipSpan = hasHipPair ? distance2d(points.left_hip, points.right_hip) : 0;
  const torsoScale = hasHipPair
    ? average([
      distance2d(points.left_shoulder, points.left_hip),
      distance2d(points.right_shoulder, points.right_hip),
    ])
    : average([
      distance2d(points.left_shoulder, points.nose) * 2,
      distance2d(points.right_shoulder, points.nose) * 2,
    ]);
  // Loose clothing and arm poses can make one bilateral pair collapse even in a
  // clear front view. Use the stronger torso span; a real side view compresses
  // both shoulders and hips.
  const lateralRatio = torsoScale > 0 ? Math.max(shoulderSpan, hipSpan) / torsoScale : null;
  const detectedOrientation = lateralRatio >= frontMinRatio
    ? 'front'
    : lateralRatio <= sideMaxRatio
      ? 'side'
      : 'uncertain';

  const leftDepth = average([points.left_shoulder.z, points.left_hip?.z]);
  const rightDepth = average([points.right_shoulder.z, points.right_hip?.z]);
  const depthDelta = Number.isFinite(leftDepth) && Number.isFinite(rightDepth) ? rightDepth - leftDepth : null;
  const detectedSide = Number.isFinite(depthDelta) && Math.abs(depthDelta) >= minDepthSeparation
    ? (depthDelta > 0 ? 'left' : 'right')
    : null;
  const detectedView = detectedOrientation === 'front'
    ? 'front'
    : detectedOrientation === 'side' && detectedSide
      ? `${detectedSide}_side`
      : detectedOrientation;

  let status = CAMERA_VIEW_STATUSES.READY;
  if (detectedOrientation === 'uncertain') status = CAMERA_VIEW_STATUSES.UNCERTAIN;
  else if (detectedOrientation !== expected.orientation) status = CAMERA_VIEW_STATUSES.WRONG_VIEW;
  else if (expected.orientation === 'side' && expected.side !== 'any' && !detectedSide) status = CAMERA_VIEW_STATUSES.UNCERTAIN;
  else if (expected.orientation === 'side' && expected.side !== 'any' && detectedSide !== expected.side) status = CAMERA_VIEW_STATUSES.WRONG_SIDE;

  return {
    ok: status === CAMERA_VIEW_STATUSES.READY,
    status,
    expectedView,
    detectedView,
    detectedOrientation,
    detectedSide,
    lateralRatio,
    depthDelta,
    missing: [],
    ...viewHint(status, expectedView, detectedView),
  };
}
