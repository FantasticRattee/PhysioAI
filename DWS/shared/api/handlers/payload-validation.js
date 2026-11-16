import { modelManifestSchemaFields, resolveBodyRegionLandmarkSchema } from '../../ai/BodyRegionLandmarkSchema.js';
import { evaluateModelApproval } from '../../ai/ModelApprovalCriteria.js';
import { MOTION_FEATURE_SCHEMA_VERSION, expectedMotionFeatureSizeForSchema } from '../../ai/MotionFeatureExtractor.js';
import { TCN_PHASES, TCN_QUALITIES } from '../../ai/TcnMotionClassifier.js';
import {
  DYNAMIC_WEIGHT_SHIFT_CLASSES,
  DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION,
  DYNAMIC_WEIGHT_SHIFT_PHASES,
  dynamicWeightShiftClassParts,
  isDynamicWeightShiftExerciseId,
  isWrongDynamicWeightShiftClass,
  normalizeDynamicWeightShiftDirection,
  normalizeDynamicWeightShiftClass,
  screenDirectionForDynamicWeightShift,
} from '../../ai/DynamicWeightShiftContract.js';
import { LANDMARK_SIDE_CONVENTION } from '../../ai/Landmarks.js';

const REFERENCE_PHASES = ['rest', 'target'];
import { cameraViewContract, normalizeCameraView } from '../../ai/CameraViewGate.js';
import {
  BODY_REGIONS,
  isRemovedLegacyExerciseId,
  normalizeBodyRegionId,
} from '../../core/exercises.js';

const MAX_TEXT = 5000;
const MAX_ITEMS = 100;
const MAX_JSON_BYTES = 250_000;
const MAX_DATASET_JSON_BYTES = 5_000_000;
const MAX_EXERCISE_JSON_BYTES = 1_500_000;
const MOTION_LABELS = ['reached_target', 'not_reached_target'];
const SESSION_SCORE_SOURCES = [
  'rule',
  'ai_primary',
  'hybrid_ai_rule',
  'candidate_model_trial',
  'tentative_rule_wrap_cue',
];
const BODY_REGION_IDS = new Set(BODY_REGIONS.map((region) => region.id));
const BODY_REGION_INPUTS = new Set([...BODY_REGION_IDS, 'whole', 'whole_body', 'full_body']);

function issue(path, code) {
  return `${path}:${code}`;
}

export function validationOk(value = null) {
  return { ok: true, value, issues: [] };
}

export function validationFail(issues = []) {
  return { ok: false, value: null, issues };
}

export function isPlainObject(value) {
  return !!value && typeof value === 'object' && !Array.isArray(value);
}

export function safeString(value, { trim = true, max = MAX_TEXT } = {}) {
  if (typeof value !== 'string') return null;
  const next = trim ? value.trim() : value;
  if (!next || next.length > max) return null;
  return next;
}

export function safeEmail(value) {
  const email = safeString(value, { max: 320 })?.toLowerCase();
  if (!email || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) return null;
  return email;
}

export function safeIdentifier(value, { max = 120 } = {}) {
  const id = safeString(value, { max });
  if (!id || !/^[A-Za-z0-9._:-]+$/.test(id)) return null;
  return id;
}

export function jsonByteLength(value) {
  try {
    return Buffer.byteLength(JSON.stringify(value), 'utf8');
  } catch {
    return Infinity;
  }
}

export function validateJsonSize(value, path = 'body', maxBytes = MAX_JSON_BYTES) {
  return jsonByteLength(value) <= maxBytes ? [] : [issue(path, 'too_large')];
}

export function validatePatientLookupPayload(body = {}) {
  if (!isPlainObject(body)) return validationFail([issue('body', 'object_required')]);
  const hasPatientId = body.patientId != null && String(body.patientId).trim() !== '';
  const hasEmail = body.email != null && String(body.email).trim() !== '';
  const patientId = body.patientId == null ? '' : safeIdentifier(body.patientId);
  const email = body.email == null ? '' : safeEmail(body.email);
  if (!hasPatientId && !hasEmail) return validationFail([issue('patientId_or_email', 'required')]);
  const issues = validateJsonSize(body);
  if (hasPatientId && !patientId) issues.push(issue('patientId', 'invalid'));
  if (hasEmail && !email) issues.push(issue('email', 'invalid'));
  if (issues.length) return validationFail(issues);
  return validationOk({ patientId, email });
}

export function validateCreatePatientPayload(body = {}) {
  if (!isPlainObject(body)) return validationFail([issue('body', 'object_required')]);
  const hasName = body.name != null && String(body.name).trim() !== '';
  const hasEmail = body.email != null && String(body.email).trim() !== '';
  const hasPassword = body.password != null && String(body.password) !== '';
  const name = safeString(body.name, { max: 160 });
  const email = safeEmail(body.email);
  const password = safeString(body.password, { trim: false, max: 256 });
  if (!hasName || !hasEmail || !hasPassword) return validationFail([issue('name_email_password', 'required')]);
  const issues = validateJsonSize(body);
  if (!name) issues.push(issue('name', 'invalid'));
  if (!email) issues.push(issue('email', 'invalid'));
  if (!password) issues.push(issue('password', 'invalid'));
  if (issues.length) return validationFail(issues);
  return validationOk({ name, email, password });
}

export function validatePlanPayload(body = {}, patientId = '') {
  if (!isPlainObject(body)) return validationFail([issue('body', 'object_required')]);
  const issues = validateJsonSize(body);
  const items = Array.isArray(body.items) ? body.items : [];
  if (items.length > MAX_ITEMS) issues.push(issue('items', 'too_many'));
  for (const [index, item] of items.entries()) {
    if (!isPlainObject(item)) {
      issues.push(issue(`items.${index}`, 'object_required'));
      continue;
    }
    const rawExerciseId = item.exerciseId || item.exercise?.id;
    const exerciseId = safeIdentifier(rawExerciseId);
    if (!exerciseId) issues.push(issue(`items.${index}.exerciseId`, rawExerciseId == null ? 'required' : 'invalid'));
    else if (isRemovedLegacyExerciseId(exerciseId)) issues.push(issue(`items.${index}.exerciseId`, 'removed_legacy_exercise'));
    for (const key of ['reps', 'sets', 'holdSec', 'frequency']) {
      if (item[key] != null && !Number.isFinite(Number(item[key]))) issues.push(issue(`items.${index}.${key}`, 'number_required'));
    }
  }
  for (const key of ['freqPerDay', 'daysPerWeek', 'durationDays', 'durationWeeks']) {
    if (body[key] != null && !Number.isFinite(Number(body[key]))) issues.push(issue(key, 'number_required'));
  }
  if (issues.length) return validationFail(issues);
  return validationOk({ ...body, patientId });
}

export function validateReferencePayload(body = {}) {
  if (!isPlainObject(body)) return validationFail([issue('body', 'object_required')]);
  const exerciseId = safeIdentifier(body.exerciseId);
  if (!exerciseId) return validationFail([issue('exerciseId', body.exerciseId == null ? 'required' : 'invalid')]);
  if (isRemovedLegacyExerciseId(exerciseId)) return validationFail([issue('exerciseId', 'removed_legacy_exercise')]);
  const issues = validateJsonSize(body);
  if (body.kind != null && !safeIdentifier(body.kind)) issues.push(issue('kind', 'invalid'));
  if (body.referenceVersion != null && !Number.isFinite(Number(body.referenceVersion))) issues.push(issue('referenceVersion', 'number_required'));
  if (body.scoringVersion != null && !Number.isFinite(Number(body.scoringVersion))) issues.push(issue('scoringVersion', 'number_required'));
  if (body.referenceSequence != null && !isPlainObject(body.referenceSequence)) issues.push(issue('referenceSequence', 'object_required'));
  if (issues.length) return validationFail(issues);
  return validationOk({ exerciseId });
}

export function validateDeleteReferencePayload({ query = {}, body = {} } = {}) {
  const rawExerciseId = query.exerciseId || body?.exerciseId;
  const exerciseId = safeIdentifier(rawExerciseId);
  if (!exerciseId) return validationFail([issue('exerciseId', rawExerciseId == null ? 'required' : 'invalid')]);
  if (isRemovedLegacyExerciseId(exerciseId)) return validationFail([issue('exerciseId', 'removed_legacy_exercise')]);
  return validationOk({ exerciseId });
}

export function validateExercisePayload(body = {}) {
  if (!isPlainObject(body)) return validationFail([issue('body', 'object_required')]);
  const id = safeIdentifier(body.id);
  const label = safeString(body.label || body.labelTh || body.title, { max: 160 });
  const rawBodyRegion = String(body.bodyRegion || '').trim();
  const bodyRegion = rawBodyRegion ? normalizeBodyRegionId(rawBodyRegion) : '';
  const cameraView = normalizeCameraView(body.cameraView || body);
  const cameraContract = cameraViewContract(cameraView);
  const issues = jsonByteLength(body) <= MAX_EXERCISE_JSON_BYTES ? [] : [issue('body', 'too_large')];
  if (!id) issues.push(issue('id', body.id == null ? 'required' : 'invalid'));
  else if (isRemovedLegacyExerciseId(id)) issues.push(issue('id', 'removed_legacy_exercise'));
  if (!label) issues.push(issue('label', 'required'));
  if (!rawBodyRegion) issues.push(issue('bodyRegion', 'required'));
  else if (!BODY_REGION_INPUTS.has(rawBodyRegion)) issues.push(issue('bodyRegion', 'invalid'));
  if (body.source != null && body.source !== 'custom') issues.push(issue('source', 'custom_required'));
  if (body.landmarkSchemaId != null && !safeIdentifier(body.landmarkSchemaId)) issues.push(issue('landmarkSchemaId', 'invalid'));
  if (body.cameraView != null && cameraView !== body.cameraView) issues.push(issue('cameraView', 'invalid'));
  if (issues.length) return validationFail(issues);
  return validationOk({
    ...body,
    id,
    key: body.key || id,
    source: 'custom',
    label,
    labelTh: body.labelTh || label,
    bodyRegion,
    cameraView: cameraContract.id,
    cameraOrientation: cameraContract.orientation,
    cameraSide: cameraContract.side,
  });
}

export function validateDeleteExercisePayload({ query = {}, body = {} } = {}) {
  const rawExerciseId = query.exerciseId || query.id || body?.exerciseId || body?.id;
  const exerciseId = safeIdentifier(rawExerciseId);
  if (!exerciseId) return validationFail([issue('exerciseId', rawExerciseId == null ? 'required' : 'invalid')]);
  if (isRemovedLegacyExerciseId(exerciseId)) return validationFail([issue('exerciseId', 'removed_legacy_exercise')]);
  return validationOk({ exerciseId });
}

export function validateSessionPayload(body = {}) {
  if (!isPlainObject(body)) return validationFail([issue('body', 'object_required')]);
  const exerciseId = safeIdentifier(body.exerciseId || body.exerciseKey);
  if (!exerciseId) return validationFail([issue('exerciseId', (body.exerciseId == null && body.exerciseKey == null) ? 'required' : 'invalid')]);
  if (isRemovedLegacyExerciseId(exerciseId)) return validationFail([issue('exerciseId', 'removed_legacy_exercise')]);
  const issues = validateJsonSize(body);
  if (body.id != null && !safeIdentifier(body.id, { max: 180 })) issues.push(issue('id', 'invalid'));
  if (body.endedAt != null && !Number.isFinite(Number(new Date(body.endedAt)))) issues.push(issue('endedAt', 'invalid'));
  for (const key of ['score', 'avgScore', 'reps', 'validReps', 'invalidRepCount', 'sessionVersion']) {
    if (body[key] != null && !Number.isFinite(Number(body[key]))) issues.push(issue(key, 'number_required'));
  }
  if (body.scoreSource != null && !SESSION_SCORE_SOURCES.includes(body.scoreSource)) issues.push(issue('scoreSource', 'invalid'));
  if (body.summary != null && !isPlainObject(body.summary)) issues.push(issue('summary', 'object_required'));
  if (body.scoreBreakdown != null && !isPlainObject(body.scoreBreakdown)) issues.push(issue('scoreBreakdown', 'object_required'));
  if (issues.length) return validationFail(issues);
  return validationOk({ exerciseId });
}

function isStringArray(value, { nonEmpty = false } = {}) {
  if (!Array.isArray(value)) return false;
  if (nonEmpty && !value.length) return false;
  return value.every((item) => typeof item === 'string' && item.trim());
}

function validateInputShape(value) {
  return Array.isArray(value) &&
    value.length === 2 &&
    value.every((item) => Number.isInteger(Number(item)) && Number(item) > 0);
}

function sameStringArray(a, b) {
  return Array.isArray(a) &&
    Array.isArray(b) &&
    a.length === b.length &&
    a.every((value, index) => value === b[index]);
}

function validateSchemaMetadata(body, landmarkSchemaId, issues) {
  if (!landmarkSchemaId) return null;
  const schema = resolveBodyRegionLandmarkSchema(landmarkSchemaId, { fallback: false });
  if (!schema) {
    issues.push(issue('landmarkSchemaId', 'unknown'));
    return null;
  }
  const schemaFields = modelManifestSchemaFields(schema);
  for (const key of ['modelInputLandmarks', 'primaryRequiredLandmarks', 'stabilizerRequiredLandmarks', 'jointNames']) {
    if (Array.isArray(body[key]) && body[key].length && !sameStringArray(body[key], schemaFields[key])) {
      issues.push(issue(key, 'schema_mismatch'));
    }
  }
  if (body.bodyRegion != null && body.bodyRegion !== schemaFields.bodyRegion) {
    issues.push(issue('bodyRegion', 'schema_mismatch'));
  }
  if (validateInputShape(body.inputShape)) {
    const expectedFeatureSize = expectedMotionFeatureSizeForSchema({ landmarkSchema: schema });
    if (Number(body.inputShape[1]) !== expectedFeatureSize) issues.push(issue('inputShape', 'schema_mismatch'));
  }
  return schemaFields;
}

export function validateDatasetPayload(body = {}) {
  if (!isPlainObject(body)) return validationFail([issue('body', 'object_required')]);
  const exerciseId = safeIdentifier(body.exerciseId);
  const landmarkSchemaId = safeIdentifier(body.landmarkSchemaId);
  const labelStatus = safeIdentifier(body.labelStatus);
  const dynamicWeightShift = isDynamicWeightShiftExerciseId(exerciseId || body.exerciseModuleId || body.metadata?.exerciseModuleId);
  const classLabel = dynamicWeightShift
    ? normalizeDynamicWeightShiftClass(body.classLabel || body.metadata?.classLabel || body.label)
    : null;
  const labelCandidate = dynamicWeightShift
    ? null
    : body.motionLabel || (MOTION_LABELS.includes(body.label) ? body.label : null);
  const motionLabel = labelCandidate ? safeIdentifier(labelCandidate) : null;
  const version = Number(body.version || 1);
  const rawCameraView = body.cameraView || body.metadata?.cameraView || 'front';
  const cameraView = normalizeCameraView(rawCameraView);
  const subjectId = body.subjectId == null ? null : safeIdentifier(body.subjectId, { max: 180 });
  const datasetSessionId = body.datasetSessionId == null ? null : safeIdentifier(body.datasetSessionId, { max: 180 });
  const repId = body.repId == null ? null : safeIdentifier(body.repId, { max: 180 });
  const reviewed = labelStatus === 'reviewed';
  const nonTrainableStatus = ['draft', 'skipped', 'auto_rejected'].includes(labelStatus);
  const issues = validateJsonSize(body, 'body', MAX_DATASET_JSON_BYTES);
  if (!exerciseId) issues.push(issue('exerciseId', body.exerciseId == null ? 'required' : 'invalid'));
  else if (isRemovedLegacyExerciseId(exerciseId)) issues.push(issue('exerciseId', 'removed_legacy_exercise'));
  if (!landmarkSchemaId) issues.push(issue('landmarkSchemaId', body.landmarkSchemaId == null ? 'required' : 'invalid'));
  if (rawCameraView !== cameraView) issues.push(issue('cameraView', 'invalid'));
  if (!reviewed && !nonTrainableStatus) issues.push(issue('labelStatus', 'invalid'));
  if (dynamicWeightShift) {
    if (body.motionLabel != null) issues.push(issue('motionLabel', 'must_be_null_for_four_class_contract'));
    if (reviewed && !classLabel) issues.push(issue('classLabel', 'required'));
    const parts = dynamicWeightShiftClassParts(classLabel);
    const formLabel = body.formLabel || body.metadata?.formLabel;
    const directionConvention = body.metadata?.directionConvention;
    const landmarkSideConvention = body.landmarkSideConvention || body.metadata?.landmarkSideConvention;
    const shiftDirection = normalizeDynamicWeightShiftDirection(body.metadata?.shiftDirection);
    const screenDirection = body.metadata?.screenDirection;
    if (reviewed && parts && formLabel !== parts.formLabel) issues.push(issue('formLabel', 'class_mismatch'));
    if (reviewed && directionConvention !== DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION) {
      issues.push(issue('metadata.directionConvention', 'screen_v1_required'));
    }
    if (reviewed && landmarkSideConvention !== LANDMARK_SIDE_CONVENTION) {
      issues.push(issue('landmarkSideConvention', 'screen_v1_required'));
    }
    if (reviewed && parts && shiftDirection !== parts.direction) {
      issues.push(issue('metadata.shiftDirection', 'class_mismatch'));
    }
    if (reviewed && parts && screenDirection !== screenDirectionForDynamicWeightShift(parts.direction)) {
      issues.push(issue('metadata.screenDirection', 'class_mismatch'));
    }
  } else {
    if (labelCandidate && !MOTION_LABELS.includes(motionLabel)) issues.push(issue('motionLabel', 'invalid'));
    if (reviewed && !MOTION_LABELS.includes(motionLabel)) issues.push(issue('motionLabel', motionLabel ? 'invalid' : 'required'));
  }
  if (reviewed && body.trainable !== true) issues.push(issue('trainable', 'true_required'));
  if (reviewed && body.repComplete !== true) issues.push(issue('repComplete', 'true_required'));
  if (reviewed && body.dataQuality !== 'usable') issues.push(issue('dataQuality', 'usable_required'));
  if (reviewed && body.missingPrimary?.length) issues.push(issue('missingPrimary', 'must_be_empty'));
  if (reviewed && body.missingStabilizer?.length) issues.push(issue('missingStabilizer', 'must_be_empty'));
  if (nonTrainableStatus && body.trainable === true) issues.push(issue('trainable', 'false_required'));
  if (nonTrainableStatus && body.scoreable === true) issues.push(issue('scoreable', 'false_required'));
  if (!Array.isArray(body.frames) || !body.frames.length) issues.push(issue('frames', 'required'));
  if (!isStringArray(body.primaryRequiredLandmarks, { nonEmpty: true })) issues.push(issue('primaryRequiredLandmarks', 'required'));
  if (!isStringArray(body.stabilizerRequiredLandmarks, { nonEmpty: true })) issues.push(issue('stabilizerRequiredLandmarks', 'required'));
  if (!isStringArray(body.modelInputLandmarks, { nonEmpty: true })) issues.push(issue('modelInputLandmarks', 'required'));
  if (!isStringArray(body.jointNames, { nonEmpty: !dynamicWeightShift })) issues.push(issue('jointNames', 'required'));
  const schemaFields = validateSchemaMetadata(body, landmarkSchemaId, issues);
  if (body.id != null && !safeIdentifier(body.id, { max: 180 })) issues.push(issue('id', 'invalid'));
  if (body.subjectId != null && !subjectId) issues.push(issue('subjectId', 'invalid'));
  if (version >= 2) {
    if (!subjectId) issues.push(issue('subjectId', 'required'));
    if (!datasetSessionId) issues.push(issue('datasetSessionId', body.datasetSessionId == null ? 'required' : 'invalid'));
    if (!repId) issues.push(issue('repId', body.repId == null ? 'required' : 'invalid'));
    const allowImportedDraftOutsideFrames = body.source === 'therapist_video_import' && labelStatus === 'draft';
    const declaredPhases = Array.isArray(body.phaseLabels) ? body.phaseLabels : TCN_PHASES;
    const acceptedPhases = sameStringArray(declaredPhases, REFERENCE_PHASES)
      ? REFERENCE_PHASES
      : TCN_PHASES;
    if (!sameStringArray(declaredPhases, REFERENCE_PHASES) && !sameStringArray(declaredPhases, TCN_PHASES)) {
      issues.push(issue('phaseLabels', 'schema_mismatch'));
    }
    const phaseCounts = (body.frames || []).reduce((out, frame) => {
      if (acceptedPhases.includes(frame?.phase)) out[frame.phase] = (out[frame.phase] || 0) + 1;
      else issues.push(issue('frames.phase', 'invalid'));
      if (frame?.boundaryStatus !== 'inside' && !allowImportedDraftOutsideFrames) {
        issues.push(issue('frames.boundaryStatus', 'inside_required'));
      }
      return out;
    }, {});
    if (reviewed) {
      const requiredPhases = dynamicWeightShift && isWrongDynamicWeightShiftClass(classLabel)
        ? ['target']
        : acceptedPhases;
      for (const phase of requiredPhases) {
        if (Number(phaseCounts[phase] || 0) < 3) issues.push(issue(`frames.${phase}`, 'minimum_3_required'));
      }
    }
  }
  if (issues.length) return validationFail(issues);
  return validationOk({
    ...body,
    exerciseId,
    landmarkSchemaId,
    motionLabel,
    subjectId,
    datasetSessionId,
    repId,
    cameraView,
    label: dynamicWeightShift ? classLabel || 'unlabeled' : motionLabel || 'unlabeled',
    ...(dynamicWeightShift ? {
      classLabel,
      motionLabel: null,
      phaseLabels: [...DYNAMIC_WEIGHT_SHIFT_PHASES],
    } : {}),
    ...(schemaFields || {}),
    missingPrimary: [],
    missingStabilizer: [],
  });
}

export function validateAiModelPayload(body = {}) {
  if (!isPlainObject(body)) return validationFail([issue('body', 'object_required')]);
  const modelId = safeIdentifier(body.id || body.modelId, { max: 180 });
  const exerciseId = safeIdentifier(body.exerciseId);
  const landmarkSchemaId = safeIdentifier(body.landmarkSchemaId);
  const version = safeIdentifier(body.version, { max: 180 });
  const cameraView = normalizeCameraView(body.cameraView || 'front');
  const dynamicWeightShift = isDynamicWeightShiftExerciseId(exerciseId);
  const expectedPhases = dynamicWeightShift ? DYNAMIC_WEIGHT_SHIFT_PHASES : TCN_PHASES;
  const expectedQualities = dynamicWeightShift ? DYNAMIC_WEIGHT_SHIFT_CLASSES : TCN_QUALITIES;
  const issues = validateJsonSize(body);
  if (!modelId) issues.push(issue('id', (body.id == null && body.modelId == null) ? 'required' : 'invalid'));
  if (!exerciseId) issues.push(issue('exerciseId', body.exerciseId == null ? 'required' : 'invalid'));
  if (exerciseId && isRemovedLegacyExerciseId(exerciseId)) issues.push(issue('exerciseId', 'removed_legacy_exercise'));
  if (!landmarkSchemaId) issues.push(issue('landmarkSchemaId', body.landmarkSchemaId == null ? 'required' : 'invalid'));
  if (!version) issues.push(issue('version', body.version == null ? 'required' : 'invalid'));
  if (!validateInputShape(body.inputShape)) issues.push(issue('inputShape', 'invalid'));
  if (!isStringArray(body.modelInputLandmarks, { nonEmpty: true })) issues.push(issue('modelInputLandmarks', 'required'));
  if (!isStringArray(body.primaryRequiredLandmarks, { nonEmpty: true })) issues.push(issue('primaryRequiredLandmarks', 'required'));
  if (!isStringArray(body.stabilizerRequiredLandmarks, { nonEmpty: true })) issues.push(issue('stabilizerRequiredLandmarks', 'required'));
  if (!isStringArray(body.jointNames, { nonEmpty: !dynamicWeightShift })) issues.push(issue('jointNames', 'required'));
  if (!isStringArray(body.phases, { nonEmpty: true })) issues.push(issue('phases', 'required'));
  if (!isStringArray(body.qualities, { nonEmpty: true })) issues.push(issue('qualities', 'required'));
  if (Array.isArray(body.phases) && !sameStringArray(body.phases, expectedPhases)) issues.push(issue('phases', 'schema_mismatch'));
  if (Array.isArray(body.qualities) && !sameStringArray(body.qualities, expectedQualities)) issues.push(issue('qualities', 'schema_mismatch'));
  if (Number(body.motionFeatureSchemaVersion) !== MOTION_FEATURE_SCHEMA_VERSION) {
    issues.push(issue('motionFeatureSchemaVersion', `v${MOTION_FEATURE_SCHEMA_VERSION}_required`));
  }
  if (body.windowPadding !== 'repeat_first') issues.push(issue('windowPadding', 'repeat_first_required'));
  if (body.cameraView != null && cameraView !== body.cameraView) issues.push(issue('cameraView', 'invalid'));
  const schemaFields = validateSchemaMetadata(body, landmarkSchemaId, issues);
  if (body.approved === true) {
    const evaluation = body.evaluation || body.metrics || body.accuracy || null;
    const approval = isPlainObject(evaluation)
      ? evaluateModelApproval({ evaluation })
      : (body.approval || {});
    if (!isPlainObject(approval)) issues.push(issue('approval', 'object_required'));
    if (approval.ok !== true) issues.push(issue('approval', 'failed'));
    if (Array.isArray(approval.issues) && approval.issues.length) issues.push(issue('approval', 'failed'));
  }
  if (issues.length) return validationFail(issues);
  return validationOk({
    ...body,
    id: modelId,
    modelId,
    exerciseId,
    landmarkSchemaId,
    version,
    cameraView,
    ...(schemaFields || {}),
    approved: body.approved === true,
  });
}
