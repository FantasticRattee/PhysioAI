import { MOTION_LABELS_V1, normalizeMotionLabel } from './DatasetLabeler.js';
import { modelManifestSchemaFields, resolveBodyRegionLandmarkSchema } from './BodyRegionLandmarkSchema.js';
import { normalizeCameraView } from './CameraViewGate.js';
import {
  DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION,
  DYNAMIC_WEIGHT_SHIFT_CLASSES,
  DYNAMIC_WEIGHT_SHIFT_PHASES,
  dynamicWeightShiftClassParts,
  isDynamicWeightShiftExerciseId,
  isWrongDynamicWeightShiftClass,
  normalizeDynamicWeightShiftDirection,
  normalizeDynamicWeightShiftClass,
  screenDirectionForDynamicWeightShift,
} from './DynamicWeightShiftContract.js';
import { LANDMARK_SIDE_CONVENTION } from './Landmarks.js';

export const DEVELOPMENT_DATASET_MINIMUMS = Object.freeze({
  reached_target: 10,
  not_reached_target: 15,
  subjects: 1,
  sessions: 1,
});

export const PRODUCTION_DATASET_MINIMUMS = Object.freeze({
  reached_target: 70,
  not_reached_target: 70,
  subjects: 5,
  sessions: 10,
});

export const RECOMMENDED_DATASET_MINIMUMS = DEVELOPMENT_DATASET_MINIMUMS;

export const DYNAMIC_WEIGHT_SHIFT_DEVELOPMENT_MINIMUMS = Object.freeze({
  correct_left: 3,
  correct_right: 3,
  wrong_left: 3,
  wrong_right: 3,
  subjects: 1,
  sessions: 3,
});

export const RECOMMENDED_MODEL_APPROVAL_CRITERIA = Object.freeze({
  phaseAccuracy: 0.90,
  qualityAccuracy: 0.85,
  qualityMacroF1: 0.75,
  perLabelRecall: 0.75,
  falseGoodRate: 0.05,
});

const BAD_MOTION_LABELS_FOR_FALSE_GOOD = Object.freeze(['not_reached_target']);

function countBy(rows, keyFn) {
  const out = {};
  for (const row of rows || []) {
    const key = keyFn(row);
    if (!key) continue;
    out[key] = (out[key] || 0) + 1;
  }
  return out;
}

function sameStringArray(a, b) {
  return Array.isArray(a) &&
    Array.isArray(b) &&
    a.length === b.length &&
    a.every((value, index) => value === b[index]);
}

export function falseGoodRateFromConfusionMatrix(matrix = {}) {
  const dynamicContract = DYNAMIC_WEIGHT_SHIFT_CLASSES.every((label) => matrix?.[label]);
  if (dynamicContract) {
    const wrongLabels = ['wrong_left', 'wrong_right'];
    const correctLabels = ['correct_left', 'correct_right'];
    const wrongTotal = wrongLabels.reduce((total, label) =>
      total + Object.values(matrix?.[label] || {}).reduce((sum, value) => sum + (Number(value) || 0), 0), 0);
    const falseCorrect = wrongLabels.reduce((total, label) =>
      total + correctLabels.reduce((sum, predicted) => sum + (Number(matrix?.[label]?.[predicted]) || 0), 0), 0);
    return wrongTotal ? falseCorrect / wrongTotal : 0;
  }
  let badTotal = 0;
  let badPredictedGood = 0;
  for (const label of BAD_MOTION_LABELS_FOR_FALSE_GOOD) {
    const row = matrix?.[label] || {};
    const rowTotal = Object.values(row).reduce((sum, value) => sum + (Number(value) || 0), 0);
    badTotal += rowTotal;
    badPredictedGood += Number(row.reached_target) || 0;
  }
  return badTotal ? badPredictedGood / badTotal : 0;
}

function rowSchemaIssues(row = {}) {
  const issues = [];
  const schemaId = row.landmarkSchemaId || row.metadata?.landmarkSchemaId || null;
  if (!schemaId) return ['missing_landmarkSchemaId'];
  const schema = resolveBodyRegionLandmarkSchema(schemaId, { fallback: false });
  if (!schema) return ['unknown_landmarkSchemaId'];
  const schemaFields = modelManifestSchemaFields(schema);
  for (const key of ['modelInputLandmarks', 'primaryRequiredLandmarks', 'stabilizerRequiredLandmarks', 'jointNames']) {
    const value = row[key] || row.metadata?.[key] || [];
    const requiresItems = schemaFields[key].length > 0;
    if (!Array.isArray(value) || (requiresItems && !value.length)) issues.push(`missing_${key}`);
    else if (!sameStringArray(value, schemaFields[key])) issues.push(`${key}_schema_mismatch`);
  }
  return issues;
}

export function datasetRowReadinessIssues(row = {}) {
  const issues = [];
  const rawCameraView = row.cameraView || row.metadata?.cameraView || 'front';
  if (normalizeCameraView(rawCameraView) !== rawCameraView) issues.push('invalid_cameraView');
  const dynamicWeightShift = isDynamicWeightShiftExerciseId(row.exerciseId || row.exerciseModuleId || row.metadata?.exerciseModuleId);
  const label = dynamicWeightShift
    ? normalizeDynamicWeightShiftClass(row.classLabel || row.metadata?.classLabel || row.label)
    : normalizeMotionLabel(row.motionLabel || row.label);
  if (!label) issues.push('invalid_or_unlabeled_motion_label');
  if (dynamicWeightShift && label) {
    const parts = dynamicWeightShiftClassParts(label);
    const direction = normalizeDynamicWeightShiftDirection(row.metadata?.shiftDirection);
    if (row.metadata?.directionConvention !== DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION) {
      issues.push('directionConvention_screen_v1_required');
    }
    if ((row.landmarkSideConvention || row.metadata?.landmarkSideConvention) !== LANDMARK_SIDE_CONVENTION) {
      issues.push('landmarkSideConvention_screen_v1_required');
    }
    if (direction !== parts?.direction) issues.push('class_direction_mismatch');
    if (row.metadata?.screenDirection !== screenDirectionForDynamicWeightShift(parts?.direction)) {
      issues.push('screenDirection_class_mismatch');
    }
  }
  if (row.labelStatus !== 'reviewed') issues.push('labelStatus_not_reviewed');
  if (row.trainable !== true) issues.push('trainable_not_true');
  if (row.repComplete !== true) issues.push('repComplete_true_required');
  if (row.dataQuality !== 'usable') issues.push(`dataQuality_${row.dataQuality || 'missing'}`);
  if (row.missingPrimary?.length) issues.push('missing_primary_required');
  if (row.missingStabilizer?.length) issues.push('missing_stabilizer_required');
  if (Number(row.version || 1) >= 2) {
    if (!row.subjectId) issues.push('missing_subjectId');
    if (!row.datasetSessionId) issues.push('missing_datasetSessionId');
    if (!row.repId) issues.push('missing_repId');
    const phaseCounts = (row.frames || []).reduce((out, frame) => {
      if (frame?.phase) out[frame.phase] = (out[frame.phase] || 0) + 1;
      return out;
    }, {});
    const expectedPhases = dynamicWeightShift
      ? isWrongDynamicWeightShiftClass(label) ? ['target'] : DYNAMIC_WEIGHT_SHIFT_PHASES
      : ['rest', 'moving_to_target', 'target'];
    for (const phase of expectedPhases) {
      if (Number(phaseCounts[phase] || 0) < 3) issues.push(`insufficient_${phase}_frames`);
    }
    if (dynamicWeightShift && (row.frames || []).some((frame) =>
      !DYNAMIC_WEIGHT_SHIFT_PHASES.includes(frame?.phase))) issues.push('invalid_phase');
    if ((row.frames || []).some((frame) => frame?.boundaryStatus !== 'inside')) {
      issues.push('non_inside_training_frame');
    }
  }
  issues.push(...rowSchemaIssues(row));
  return issues;
}

export function evaluateDatasetReadiness(rows = [], {
  minimums = RECOMMENDED_DATASET_MINIMUMS,
} = {}) {
  const containsDynamicWeightShifts = (rows || []).some((row) => isDynamicWeightShiftExerciseId(
    row?.exerciseId || row?.exerciseModuleId || row?.metadata?.exerciseModuleId,
  ));
  const resolvedMinimums = containsDynamicWeightShifts && minimums === RECOMMENDED_DATASET_MINIMUMS
    ? DYNAMIC_WEIGHT_SHIFT_DEVELOPMENT_MINIMUMS
    : minimums;
  const assessedRows = (rows || []).map((row, index) => ({
    row,
    index,
    issues: datasetRowReadinessIssues(row),
    motionLabel: isDynamicWeightShiftExerciseId(row?.exerciseId || row?.exerciseModuleId || row?.metadata?.exerciseModuleId)
      ? normalizeDynamicWeightShiftClass(row?.classLabel || row?.metadata?.classLabel || row?.label)
      : normalizeMotionLabel(row?.motionLabel || row?.label),
  }));
  const trainable = assessedRows.filter((item) => !item.issues.length).map((item) => item.row);
  const invalidRows = assessedRows
    .filter((item) => item.issues.length && (item.row?.trainable === true || item.row?.labelStatus === 'reviewed'))
    .map((item) => ({
      index: item.index,
      exerciseId: item.row?.exerciseId || 'unknown',
      issues: item.issues,
    }));
  const byLabel = countBy(assessedRows.filter((item) => !item.issues.length), (item) => item.motionLabel);
  const subjects = new Set(trainable.map((row) => row.subjectId || row.metadata?.subjectId).filter(Boolean));
  const sessions = new Set(trainable.map((row) => row.datasetSessionId || row.metadata?.datasetSessionId).filter(Boolean));
  const expectedLabels = containsDynamicWeightShifts ? DYNAMIC_WEIGHT_SHIFT_CLASSES : MOTION_LABELS_V1;
  const missingLabels = expectedLabels
    .map((label) => ({
      label,
      actual: byLabel[label] || 0,
      required: resolvedMinimums[label] || 0,
    }))
    .filter((item) => item.actual < item.required);
  const missingSubjects = Math.max(0, (resolvedMinimums.subjects || 0) - subjects.size);
  const missingSessions = Math.max(0, (resolvedMinimums.sessions || 0) - sessions.size);
  return {
    ok: !missingLabels.length && missingSubjects === 0 && missingSessions === 0,
    trainableRows: trainable.length,
    invalidRows,
    byLabel,
    subjects: subjects.size,
    sessions: sessions.size,
    missingLabels,
    missingSubjects,
    missingSessions,
    minimums: { ...resolvedMinimums },
  };
}

export function evaluateModelApproval({
  evaluation = {},
  criteria = RECOMMENDED_MODEL_APPROVAL_CRITERIA,
} = {}) {
  const phaseAccuracy = Number(
    evaluation.stablePhaseAccuracy
      ?? evaluation.stable_phase_accuracy
      ?? evaluation.phaseAccuracy
      ?? evaluation.phase_accuracy
      ?? evaluation.metrics?.stablePhaseAccuracy
      ?? evaluation.metrics?.phase_accuracy,
  );
  const qualityAccuracy = Number(evaluation.qualityAccuracy ?? evaluation.quality_accuracy ?? evaluation.metrics?.quality_accuracy);
  const qualityMacroF1 = Number(evaluation.qualityMacroF1 ?? evaluation.quality_macro_f1 ?? evaluation.metrics?.qualityMacroF1);
  const perLabelRecall = evaluation.perLabelRecall || evaluation.per_label_recall || evaluation.metrics?.perLabelRecall || {};
  const qualityConfusionMatrix = evaluation.qualityConfusionMatrix || evaluation.quality_confusion_matrix || evaluation.confusionMatrix || evaluation.metrics?.qualityConfusionMatrix || null;
  const falseGoodRate = Number(evaluation.falseGoodRate ?? evaluation.false_good_rate ?? evaluation.metrics?.falseGoodRate ??
    (qualityConfusionMatrix ? falseGoodRateFromConfusionMatrix(qualityConfusionMatrix) : NaN));
  const issues = [];
  if (!Number.isFinite(phaseAccuracy) || phaseAccuracy < criteria.phaseAccuracy) issues.push('phase_accuracy_below_threshold');
  if (!Number.isFinite(qualityAccuracy) || qualityAccuracy < criteria.qualityAccuracy) issues.push('quality_accuracy_below_threshold');
  if (!Number.isFinite(qualityMacroF1) || qualityMacroF1 < criteria.qualityMacroF1) issues.push('quality_macro_f1_below_threshold');
  const reportedQualityLabels = Array.isArray(evaluation.qualityLabels)
    ? evaluation.qualityLabels.filter(Boolean)
    : [];
  const recallLabels = Object.keys(perLabelRecall);
  const expectedLabels = reportedQualityLabels.length
    ? reportedQualityLabels
    : recallLabels.some((label) => DYNAMIC_WEIGHT_SHIFT_CLASSES.includes(label))
      ? DYNAMIC_WEIGHT_SHIFT_CLASSES
      : MOTION_LABELS_V1;
  for (const label of expectedLabels) {
    const recall = Number(perLabelRecall[label]);
    if (!Number.isFinite(recall) || recall < criteria.perLabelRecall) issues.push(`recall_${label}_below_threshold`);
  }
  if (!Number.isFinite(falseGoodRate) || falseGoodRate > criteria.falseGoodRate) issues.push('false_good_rate_above_threshold');
  return {
    ok: issues.length === 0,
    issues,
    criteria: { ...criteria },
    metrics: {
      phaseAccuracy: Number.isFinite(phaseAccuracy) ? phaseAccuracy : null,
      qualityAccuracy: Number.isFinite(qualityAccuracy) ? qualityAccuracy : null,
      qualityMacroF1: Number.isFinite(qualityMacroF1) ? qualityMacroF1 : null,
      perLabelRecall: { ...perLabelRecall },
      falseGoodRate: Number.isFinite(falseGoodRate) ? falseGoodRate : null,
    },
  };
}
