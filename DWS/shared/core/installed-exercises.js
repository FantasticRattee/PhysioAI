import {
  BOTTLE_GRAB_EXERCISE,
  isNativeExercise,
  nativeExerciseSnapshot,
} from './native-exercises.js';

export const RIGHT_LATERAL_ARM_RAISE_EXERCISE_ID = 'cust_mrhhkile';
export const RIGHT_LATERAL_ARM_RAISE_MODEL_ID = 'cust_mrhhkile-threshold70-candidate-v2';
export const DYNAMIC_WEIGHT_SHIFTS_EXERCISE_ID = 'cust_dynamic_weight_shifts';
export const DYNAMIC_WEIGHT_SHIFTS_MODEL_ID = 'cust_dynamic_weight_shifts-left-tcn-v3';

const RIGHT_LATERAL_ARM_RAISE_TARGET_POLICY = Object.freeze({
  version: 'multi_joint_trajectory_reach.v4',
  joint: 'right_shoulder',
  phase: 'target',
  aggregate: 'hold',
  comparator: 'gte',
  reachedTargetMinDeg: 70,
  restResetDeg: 30,
  requiredJointRules: Object.freeze([
    Object.freeze({
      joint: 'right_elbow',
      comparator: 'gte',
      reachedTargetMinDeg: 150,
      enforceDuringPhases: Object.freeze(['moving_to_target', 'target']),
      violationGraceMs: 350,
    }),
  ]),
});

export const RIGHT_LATERAL_ARM_RAISE_EXERCISE = Object.freeze({
  id: RIGHT_LATERAL_ARM_RAISE_EXERCISE_ID,
  key: RIGHT_LATERAL_ARM_RAISE_EXERCISE_ID,
  source: 'production_model',
  label: 'Right Lateral Arm Raise',
  labelTh: 'ยกแขนขวาด้านข้าง',
  title: 'ยกแขนขวาด้านข้าง',
  titleEn: 'Right Lateral Arm Raise',
  icon: 'body',
  accent: '#7BA88F',
  category: 'shoulder',
  type: 'rep',
  reps: 10,
  sets: 1,
  holdSec: 0,
  target: 70,
  rest: 30,
  tol: 12,
  bodyRegion: 'right_arm',
  primaryJoint: 'right_shoulder',
  dominantJoint: 'right_shoulder',
  requiredJoints: Object.freeze(['right_shoulder', 'right_elbow']),
  optionalJoints: Object.freeze([]),
  primaryRequiredLandmarks: Object.freeze(['right_shoulder', 'right_elbow', 'right_wrist']),
  stabilizerRequiredLandmarks: Object.freeze(['left_shoulder']),
  modelInputLandmarks: Object.freeze(['right_shoulder', 'right_elbow', 'right_wrist', 'left_shoulder']),
  jointNames: Object.freeze(['right_shoulder', 'right_elbow']),
  landmarkSchemaId: 'right_arm.v1',
  movementPattern: 'motion_cycle',
  repMode: 'motion_cycle',
  cameraView: 'front',
  cameraOrientation: 'front',
  cameraSide: 'any',
  minVisibility: 0.35,
  minUsableJointRatio: 0.8,
  activeModelId: RIGHT_LATERAL_ARM_RAISE_MODEL_ID,
  modelBaseUrl: `/shared/models/${RIGHT_LATERAL_ARM_RAISE_MODEL_ID}`,
  modelEngineType: 'motion_tcn',
  modelStatus: 'deployed',
  validationOnly: false,
  modelTrial: false,
  validationMode: 'hybrid',
  decisionMode: 'hybrid',
  targetOutcomePolicy: RIGHT_LATERAL_ARM_RAISE_TARGET_POLICY,
  requiresReference: false,
  templateOnly: false,
  availability: 'production_ai',
  assessmentScope: 'lateral_arm_raise_repetition',
  clinicalScoreAvailable: true,
  setupInstruction: 'หันหน้าเข้ากล้องและถอยให้เห็นไหล่ ศอก ข้อมือ และลำตัวครบ',
  setupInstructionTh: 'หันหน้าเข้ากล้องและถอยให้เห็นไหล่ ศอก ข้อมือ และลำตัวครบ',
  setupInstructionEn: 'Face the camera and keep the shoulders, elbow, wrist, and torso visible.',
});

const DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY = Object.freeze({
  version: 'seated_lateral_shift.v1',
  joint: 'trunk_shift',
  phase: 'target',
  aggregate: 'hold',
  comparator: 'gte',
  reachedTargetMinDeg: 2.5,
  restResetDeg: 1.8,
  requiredJointRules: Object.freeze([
    Object.freeze({
      joint: 'shoulder_tilt',
      comparator: 'lte',
      reachedTargetMaxDeg: 15,
      enforceDuringPhases: Object.freeze(['target']),
      violationGraceMs: 0,
    }),
  ]),
});

export const DYNAMIC_WEIGHT_SHIFTS_EXERCISE = Object.freeze({
  id: DYNAMIC_WEIGHT_SHIFTS_EXERCISE_ID,
  key: DYNAMIC_WEIGHT_SHIFTS_EXERCISE_ID,
  source: 'production_model',
  label: 'Dynamic Weight Shifts — Left',
  labelTh: 'ถ่ายน้ำหนักไปทางซ้าย',
  title: 'ถ่ายน้ำหนักไปทางซ้าย',
  titleEn: 'Dynamic Weight Shifts — Left',
  icon: 'body',
  accent: '#7BA88F',
  category: 'balance',
  type: 'rep',
  reps: 5,
  sets: 1,
  holdSec: 0,
  target: 2.5,
  rest: 1.8,
  tol: 3,
  bodyRegion: 'seated_balance',
  primaryJoint: 'trunk_shift',
  dominantJoint: 'trunk_shift',
  requiredJoints: Object.freeze(['trunk_shift', 'shoulder_tilt']),
  optionalJoints: Object.freeze([]),
  primaryRequiredLandmarks: Object.freeze([
    'left_shoulder',
    'right_shoulder',
    'left_hip',
    'right_hip',
  ]),
  stabilizerRequiredLandmarks: Object.freeze([
    'left_knee',
    'right_knee',
    'left_ankle',
    'right_ankle',
    'left_wrist',
    'right_wrist',
  ]),
  modelInputLandmarks: Object.freeze([
    'left_shoulder',
    'right_shoulder',
    'left_hip',
    'right_hip',
  ]),
  jointNames: Object.freeze([]),
  landmarkSchemaId: 'seated_balance.v2',
  movementPattern: 'motion_cycle',
  repMode: 'motion_cycle',
  cameraView: 'front',
  cameraOrientation: 'front',
  cameraSide: 'any',
  minVisibility: 0.65,
  minUsableJointRatio: 0.8,
  activeModelId: DYNAMIC_WEIGHT_SHIFTS_MODEL_ID,
  modelBaseUrl: `/shared/models/${DYNAMIC_WEIGHT_SHIFTS_MODEL_ID}`,
  modelEngineType: 'motion_tcn',
  modelStatus: 'deployed',
  validationOnly: false,
  modelTrial: false,
  validationMode: 'hybrid',
  decisionMode: 'hybrid',
  targetOutcomePolicy: DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY,
  targetHoldMs: 300,
  fallbackHoldMs: 300,
  disagreementHoldMs: 800,
  restHoldMs: 180,
  trackingLossGraceMs: 350,
  minAiConfidence: 0.5,
  targetStabilityToleranceDeg: null,
  requiresReference: false,
  templateOnly: false,
  availability: 'production_ai',
  assessmentScope: 'seated_dynamic_weight_shift_left',
  clinicalScoreAvailable: true,
  setupInstruction: 'นั่งหันหน้ากล้อง ให้เห็นหัวไหล่ สะโพก ข้อมือ เข่า และข้อเท้าครบ',
  setupInstructionTh: 'นั่งหันหน้ากล้อง ให้เห็นหัวไหล่ สะโพก ข้อมือ เข่า และข้อเท้าครบ',
  setupInstructionEn: 'Sit facing the camera and keep the shoulders, hips, wrists, knees, and ankles visible.',
});

export const INSTALLED_PRODUCTION_EXERCISES = Object.freeze([
  BOTTLE_GRAB_EXERCISE,
  RIGHT_LATERAL_ARM_RAISE_EXERCISE,
  DYNAMIC_WEIGHT_SHIFTS_EXERCISE,
]);

const INSTALLED_PRODUCTION_EXERCISE_BY_ID = new Map(
  INSTALLED_PRODUCTION_EXERCISES.map((exercise) => [exercise.id, exercise]),
);

export function getInstalledProductionExercise(id) {
  return INSTALLED_PRODUCTION_EXERCISE_BY_ID.get(String(id || '')) || null;
}

export function isInstalledProductionExercise(exerciseOrId) {
  const id = typeof exerciseOrId === 'string' ? exerciseOrId : exerciseOrId?.id;
  return getInstalledProductionExercise(id) != null;
}

export function installedProductionExerciseSnapshot(exerciseOrId) {
  const exercise = typeof exerciseOrId === 'string'
    ? getInstalledProductionExercise(exerciseOrId)
    : getInstalledProductionExercise(exerciseOrId?.id);
  if (!exercise) return null;
  if (isNativeExercise(exercise)) return nativeExerciseSnapshot(exercise);
  return {
    ...exercise,
    requiredJoints: [...exercise.requiredJoints],
    optionalJoints: [...exercise.optionalJoints],
    primaryRequiredLandmarks: [...exercise.primaryRequiredLandmarks],
    stabilizerRequiredLandmarks: [...exercise.stabilizerRequiredLandmarks],
    modelInputLandmarks: [...exercise.modelInputLandmarks],
    jointNames: [...exercise.jointNames],
    targetOutcomePolicy: {
      ...exercise.targetOutcomePolicy,
      requiredJointRules: exercise.targetOutcomePolicy.requiredJointRules.map((rule) => ({
        ...rule,
        enforceDuringPhases: [...rule.enforceDuringPhases],
      })),
    },
  };
}
