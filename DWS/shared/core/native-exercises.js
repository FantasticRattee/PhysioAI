export const BOTTLE_GRAB_EXERCISE_ID = 'bottle_grab';
export const BOTTLE_GRAB_NATIVE_RUNTIME = 'bottle_grab_v8_0_2';

export const BOTTLE_GRAB_EXERCISE = Object.freeze({
  id: BOTTLE_GRAB_EXERCISE_ID,
  key: BOTTLE_GRAB_EXERCISE_ID,
  source: 'native',
  label: 'Bottle Grab',
  labelTh: 'หยิบขวดน้ำ',
  title: 'หยิบขวดน้ำ',
  titleEn: 'Bottle Grab',
  category: 'functional',
  type: 'rep',
  reps: 5,
  sets: 1,
  holdSec: 0.5,
  tol: 18,
  target: 105,
  rest: 55,
  bodyRegion: 'left_arm',
  primaryJoint: 'left_elbow',
  dominantJoint: 'left_elbow',
  requiredJoints: ['left_shoulder', 'left_elbow', 'left_wrist'],
  cameraView: 'front',
  cameraOrientation: 'front',
  cameraSide: 'any',
  setupInstructionTh: 'วางขวดบนโต๊ะด้านหน้า จัดกล้องให้เห็นลำตัวและแขนซ้ายครบ',
  setupInstructionEn: 'Place the bottle on a table and keep the torso and left arm visible.',
  nativeRuntime: BOTTLE_GRAB_NATIVE_RUNTIME,
  nativeRuntimeVersion: '8.0.2',
  requiresReference: false,
  availability: 'ios_native',
  assessmentScope: 'functional_repetition',
  clinicalScoreAvailable: false,
});

export const NATIVE_EXERCISES = Object.freeze([BOTTLE_GRAB_EXERCISE]);
export const NATIVE_EXERCISE_BY_ID = new Map(NATIVE_EXERCISES.map((exercise) => [exercise.id, exercise]));

export function getNativeExercise(id) {
  return NATIVE_EXERCISE_BY_ID.get(String(id || '')) || null;
}

export function isNativeExercise(exerciseOrId) {
  const exercise = typeof exerciseOrId === 'string'
    ? getNativeExercise(exerciseOrId)
    : exerciseOrId;
  return exercise?.source === 'native'
    && exercise?.nativeRuntime === BOTTLE_GRAB_NATIVE_RUNTIME;
}

export function nativeExerciseSnapshot(exercise) {
  if (!isNativeExercise(exercise)) return null;
  return {
    id: exercise.id,
    key: exercise.key || exercise.id,
    source: 'native',
    label: exercise.label,
    labelTh: exercise.labelTh,
    title: exercise.title,
    titleEn: exercise.titleEn,
    category: exercise.category,
    type: exercise.type,
    reps: exercise.reps,
    sets: exercise.sets,
    holdSec: exercise.holdSec,
    tol: exercise.tol,
    target: exercise.target,
    rest: exercise.rest,
    bodyRegion: exercise.bodyRegion,
    primaryJoint: exercise.primaryJoint,
    dominantJoint: exercise.dominantJoint,
    requiredJoints: exercise.requiredJoints,
    cameraView: exercise.cameraView,
    cameraOrientation: exercise.cameraOrientation,
    cameraSide: exercise.cameraSide,
    setupInstructionTh: exercise.setupInstructionTh,
    setupInstructionEn: exercise.setupInstructionEn,
    nativeRuntime: exercise.nativeRuntime,
    nativeRuntimeVersion: exercise.nativeRuntimeVersion,
    requiresReference: false,
    availability: exercise.availability,
    assessmentScope: exercise.assessmentScope,
    clinicalScoreAvailable: false,
  };
}
