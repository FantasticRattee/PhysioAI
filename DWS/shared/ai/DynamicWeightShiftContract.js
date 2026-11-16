export const DYNAMIC_WEIGHT_SHIFT_EXERCISE_IDS = Object.freeze([
  'cust_dynamic_weight_shifts',
  'dynamic_weight_shifts',
  'dynamic-weight-shifts',
]);

export const DYNAMIC_WEIGHT_SHIFT_LANDMARK_SCHEMA_ID = 'seated_balance.v2';
export const DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION = 'screen.v1';
export const DYNAMIC_WEIGHT_SHIFT_CLASS_CONTRACT = 'dynamic_weight_shifts_form_screen_direction.v2';
export const DYNAMIC_WEIGHT_SHIFT_LEFT_TCN_CLASS_CONTRACT = 'dynamic_weight_shifts_form_screen_left.v1';
export const DYNAMIC_WEIGHT_SHIFT_LEFT_TCN_ARCHITECTURE_ID = 'dynamic_weight_shifts_left_tcn.v1';
export const DYNAMIC_WEIGHT_SHIFT_PHASES = Object.freeze(['rest', 'target']);
export const DYNAMIC_WEIGHT_SHIFT_FORM_LABELS = Object.freeze(['correct', 'wrong']);
export const DYNAMIC_WEIGHT_SHIFT_DIRECTIONS = Object.freeze(['left', 'right']);
export const DYNAMIC_WEIGHT_SHIFT_CLASSES = Object.freeze([
  'correct_left',
  'correct_right',
  'wrong_left',
  'wrong_right',
]);

const EXERCISE_ID_SET = new Set(DYNAMIC_WEIGHT_SHIFT_EXERCISE_IDS);
const CLASS_SET = new Set(DYNAMIC_WEIGHT_SHIFT_CLASSES);

export function isDynamicWeightShiftExerciseId(value) {
  return EXERCISE_ID_SET.has(String(value || '').trim().toLowerCase());
}

export function normalizeDynamicWeightShiftClass(value) {
  const normalized = String(value || '').trim().toLowerCase();
  return CLASS_SET.has(normalized) ? normalized : null;
}

export function normalizeDynamicWeightShiftDirection(value) {
  const normalized = String(value || '').trim().toLowerCase().replace(/^screen_/, '');
  return DYNAMIC_WEIGHT_SHIFT_DIRECTIONS.includes(normalized) ? normalized : null;
}

export function screenDirectionForDynamicWeightShift(value) {
  const direction = normalizeDynamicWeightShiftDirection(value);
  return direction ? `screen_${direction}` : 'unknown';
}

export function buildDynamicWeightShiftClassLabel(formLabel, screenDirection) {
  const form = String(formLabel || '').trim().toLowerCase();
  const direction = normalizeDynamicWeightShiftDirection(screenDirection);
  if (!DYNAMIC_WEIGHT_SHIFT_FORM_LABELS.includes(form) || !DYNAMIC_WEIGHT_SHIFT_DIRECTIONS.includes(direction)) {
    return null;
  }
  return normalizeDynamicWeightShiftClass(`${form}_${direction}`);
}

export function dynamicWeightShiftClassParts(value) {
  const classLabel = normalizeDynamicWeightShiftClass(value);
  if (!classLabel) return null;
  const [formLabel, direction] = classLabel.split('_');
  return {
    classLabel,
    formLabel,
    direction,
    screenDirection: screenDirectionForDynamicWeightShift(direction),
  };
}

export function isCorrectDynamicWeightShiftClass(value) {
  return normalizeDynamicWeightShiftClass(value)?.startsWith('correct_') === true;
}

export function isWrongDynamicWeightShiftClass(value) {
  return normalizeDynamicWeightShiftClass(value)?.startsWith('wrong_') === true;
}

export function isDynamicWeightShiftLeftTcnModel(value = {}) {
  const manifest = value?.validationModelManifest || value;
  return manifest?.architectureId === DYNAMIC_WEIGHT_SHIFT_LEFT_TCN_ARCHITECTURE_ID ||
    manifest?.classContract === DYNAMIC_WEIGHT_SHIFT_LEFT_TCN_CLASS_CONTRACT ||
    value?.validationModelArchitectureId === DYNAMIC_WEIGHT_SHIFT_LEFT_TCN_ARCHITECTURE_ID ||
    value?.validationModelClassContract === DYNAMIC_WEIGHT_SHIFT_LEFT_TCN_CLASS_CONTRACT;
}
