import {
  DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION,
  DYNAMIC_WEIGHT_SHIFT_PHASES,
  dynamicWeightShiftClassParts,
  isDynamicWeightShiftExerciseId,
  isWrongDynamicWeightShiftClass,
  normalizeDynamicWeightShiftDirection,
  normalizeDynamicWeightShiftClass,
  screenDirectionForDynamicWeightShift,
} from './DynamicWeightShiftContract.js';
import { LANDMARK_SIDE_CONVENTION } from './Landmarks.js';

export const MOTION_LABELS_V1 = Object.freeze(['reached_target', 'not_reached_target']);
export const DATA_QUALITY_LABELS = Object.freeze([
  'usable',
  'no_pose',
  'out_of_frame',
  'low_visibility',
  'missing_primary_required',
  'missing_stabilizer_required',
  'missing_schema',
]);
export const LABEL_STATUSES = Object.freeze({
  DRAFT: 'draft',
  REVIEWED: 'reviewed',
  AUTO_REJECTED: 'auto_rejected',
  SKIPPED: 'skipped',
});

const MOTION_LABEL_ALIASES = Object.freeze({
  good: 'reached_target',
  good_rep: 'reached_target',
  needs_correction: 'not_reached_target',
  bad_rep: 'not_reached_target',
  incomplete: 'not_reached_target',
  incomplete_target: 'not_reached_target',
});

export function normalizeMotionLabel(value) {
  const normalized = MOTION_LABEL_ALIASES[value] || value;
  return MOTION_LABELS_V1.includes(normalized) ? normalized : null;
}

export function isReviewedTrainableRow(row = {}) {
  const dynamicWeightShift = [
    row.exerciseId,
    row.exerciseModuleId,
    row.metadata?.exerciseModuleId,
  ].some(isDynamicWeightShiftExerciseId);
  const classLabel = normalizeDynamicWeightShiftClass(row.classLabel || row.metadata?.classLabel || row.label);
  const classParts = dynamicWeightShiftClassParts(classLabel);
  const storedDirection = normalizeDynamicWeightShiftDirection(row.metadata?.shiftDirection);
  const requiredDynamicPhases = isWrongDynamicWeightShiftClass(classLabel)
    ? ['target']
    : DYNAMIC_WEIGHT_SHIFT_PHASES;
  const phaseCounts = (row.frames || []).reduce((counts, frame) => {
    if (frame?.phase) counts[frame.phase] = (counts[frame.phase] || 0) + 1;
    return counts;
  }, {});
  const dynamicContractValid = !dynamicWeightShift || (
    !!classLabel &&
    row.metadata?.directionConvention === DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION &&
    (row.landmarkSideConvention || row.metadata?.landmarkSideConvention) === LANDMARK_SIDE_CONVENTION &&
    storedDirection === classParts?.direction &&
    row.metadata?.screenDirection === screenDirectionForDynamicWeightShift(classParts?.direction) &&
    requiredDynamicPhases.every((phase) => Number(phaseCounts[phase] || 0) >= 3) &&
    (row.frames || []).every((frame) => DYNAMIC_WEIGHT_SHIFT_PHASES.includes(frame?.phase))
  );
  return row.trainable === true &&
    row.repComplete === true &&
    row.dataQuality === 'usable' &&
    row.labelStatus === LABEL_STATUSES.REVIEWED &&
    (dynamicWeightShift ? dynamicContractValid : !!normalizeMotionLabel(row.motionLabel || row.label)) &&
    !!row.landmarkSchemaId &&
    !row.missingPrimary?.length &&
    !row.missingStabilizer?.length;
}

export function reviewDatasetRow(row = {}, motionLabel) {
  const normalized = normalizeMotionLabel(motionLabel);
  if (!normalized) {
    const err = new Error(`Invalid motion label: ${motionLabel}`);
    err.code = 'invalid_motion_label';
    throw err;
  }
  const dataQuality = row.dataQuality || 'usable';
  const trainable = dataQuality === 'usable' &&
    row.repComplete === true &&
    !!row.landmarkSchemaId &&
    !row.missingPrimary?.length &&
    !row.missingStabilizer?.length;
  return {
    ...row,
    motionLabel: normalized,
    label: normalized,
    labelStatus: LABEL_STATUSES.REVIEWED,
    trainable,
    scoreable: trainable,
  };
}

export function markDatasetRowAsIntentionalIncomplete(row = {}) {
  if (row.completionSource !== 'manual_stop' || row.repComplete === true) {
    const err = new Error('Only manual-stop incomplete rows can be marked as intentional incomplete samples.');
    err.code = 'not_manual_incomplete';
    throw err;
  }
  const dataQuality = row.dataQuality || 'usable';
  const trainable = dataQuality === 'usable' &&
    !!row.landmarkSchemaId &&
    !row.missingPrimary?.length &&
    !row.missingStabilizer?.length;
  return {
    ...row,
    motionLabel: 'not_reached_target',
    label: 'not_reached_target',
    suggestedLabel: 'not_reached_target',
    labelStatus: LABEL_STATUSES.REVIEWED,
    repComplete: true,
    completionSource: 'manual_incomplete_reviewed',
    trainable,
    scoreable: trainable,
  };
}

export function autoRejectDatasetRow(row = {}, dataQuality, details = {}) {
  const quality = DATA_QUALITY_LABELS.includes(dataQuality) ? dataQuality : 'missing_schema';
  return {
    ...row,
    ...details,
    dataQuality: quality,
    labelStatus: LABEL_STATUSES.AUTO_REJECTED,
    trainable: false,
    scoreable: false,
  };
}
