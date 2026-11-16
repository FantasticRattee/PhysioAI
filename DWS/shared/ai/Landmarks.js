// BlazePose 33 landmark schema shared by detector, scoring, boundary, and overlays.

export const LANDMARK_NAMES = [
  'nose', 'left_eye_inner', 'left_eye', 'left_eye_outer',
  'right_eye_inner', 'right_eye', 'right_eye_outer',
  'left_ear', 'right_ear', 'mouth_left', 'mouth_right',
  'left_shoulder', 'right_shoulder', 'left_elbow', 'right_elbow',
  'left_wrist', 'right_wrist', 'left_pinky', 'right_pinky',
  'left_index', 'right_index', 'left_thumb', 'right_thumb',
  'left_hip', 'right_hip', 'left_knee', 'right_knee',
  'left_ankle', 'right_ankle', 'left_heel', 'right_heel',
  'left_foot_index', 'right_foot_index',
];

export const idx = (name) => LANDMARK_NAMES.indexOf(name);

// PhysioAI's user-facing side contract is based on the rendered screen, not
// MediaPipe's anatomical left/right labels. MediaPipe normally reports the
// subject's left side on the right half of an unmirrored front-view image.
export const LANDMARK_SIDE_CONVENTION = 'screen.v1';

export const BILATERAL_LANDMARK_PAIRS = Object.freeze([
  Object.freeze(['left_eye_inner', 'right_eye_inner']),
  Object.freeze(['left_eye', 'right_eye']),
  Object.freeze(['left_eye_outer', 'right_eye_outer']),
  Object.freeze(['left_ear', 'right_ear']),
  Object.freeze(['mouth_left', 'mouth_right']),
  Object.freeze(['left_shoulder', 'right_shoulder']),
  Object.freeze(['left_elbow', 'right_elbow']),
  Object.freeze(['left_wrist', 'right_wrist']),
  Object.freeze(['left_pinky', 'right_pinky']),
  Object.freeze(['left_index', 'right_index']),
  Object.freeze(['left_thumb', 'right_thumb']),
  Object.freeze(['left_hip', 'right_hip']),
  Object.freeze(['left_knee', 'right_knee']),
  Object.freeze(['left_ankle', 'right_ankle']),
  Object.freeze(['left_heel', 'right_heel']),
  Object.freeze(['left_foot_index', 'right_foot_index']),
]);

function pointX(point) {
  const value = Array.isArray(point) ? point[0] : point?.x;
  return Number.isFinite(Number(value)) ? Number(value) : null;
}

function screenOrientationEvidence(landmarks = []) {
  const evidencePairs = [
    ['left_shoulder', 'right_shoulder'],
    ['left_hip', 'right_hip'],
    ['left_knee', 'right_knee'],
    ['left_ankle', 'right_ankle'],
    ['left_ear', 'right_ear'],
  ];
  return evidencePairs
    .map(([leftName, rightName]) => {
      const leftX = pointX(landmarks?.[idx(leftName)]);
      const rightX = pointX(landmarks?.[idx(rightName)]);
      return leftX == null || rightX == null ? null : leftX - rightX;
    })
    .filter((delta) => Number.isFinite(delta) && Math.abs(delta) > 1e-5);
}

export function poseLandmarksNeedScreenSideSwap(landmarks = []) {
  if (!Array.isArray(landmarks) || !landmarks.length) return false;
  const evidence = screenOrientationEvidence(landmarks);
  if (!evidence.length) return false;
  const sorted = [...evidence].sort((a, b) => a - b);
  const middle = Math.floor(sorted.length / 2);
  const median = sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
  return median > 0;
}

/**
 * Return a shallow copy whose `left_*` slots always contain the body side on
 * the left of the screen. The operation is idempotent, so already-normalized
 * frames remain unchanged when they pass through ingestion and training again.
 */
export function normalizePoseLandmarksToScreenSide(landmarks = []) {
  if (!Array.isArray(landmarks)) return [];
  const normalized = [...landmarks];
  if (!poseLandmarksNeedScreenSideSwap(normalized)) return normalized;
  for (const [leftName, rightName] of BILATERAL_LANDMARK_PAIRS) {
    const leftIndex = idx(leftName);
    const rightIndex = idx(rightName);
    if (leftIndex < 0 || rightIndex < 0) continue;
    normalized[leftIndex] = landmarks[rightIndex];
    normalized[rightIndex] = landmarks[leftIndex];
  }
  return normalized;
}
