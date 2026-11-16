import { LABEL_STATUSES } from '../../../shared/ai/DatasetLabeler.js';
import { normalizeDatasetLandmarks } from '../../../shared/ai/MotionDataset.js';
import {
  modelManifestSchemaFields,
  resolveBodyRegionLandmarkSchema,
} from '../../../shared/ai/BodyRegionLandmarkSchema.js';
import {
  buildDynamicWeightShiftClassLabel,
  DYNAMIC_WEIGHT_SHIFT_CLASS_CONTRACT,
  DYNAMIC_WEIGHT_SHIFT_CLASSES,
  DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION,
  DYNAMIC_WEIGHT_SHIFT_DIRECTIONS,
  DYNAMIC_WEIGHT_SHIFT_FORM_LABELS,
  DYNAMIC_WEIGHT_SHIFT_LANDMARK_SCHEMA_ID,
  DYNAMIC_WEIGHT_SHIFT_PHASES,
  dynamicWeightShiftClassParts,
  isDynamicWeightShiftExerciseId,
  isWrongDynamicWeightShiftClass,
  normalizeDynamicWeightShiftDirection,
  normalizeDynamicWeightShiftClass,
  screenDirectionForDynamicWeightShift,
} from '../../../shared/ai/DynamicWeightShiftContract.js';
import { dynamicWeightShiftMetrics } from './metrics.js';
import { DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY } from './rules.js';

export {
  DYNAMIC_WEIGHT_SHIFT_CLASSES,
  DYNAMIC_WEIGHT_SHIFT_DIRECTIONS,
  DYNAMIC_WEIGHT_SHIFT_FORM_LABELS,
  DYNAMIC_WEIGHT_SHIFT_PHASES,
};

function median(values = []) {
  const sorted = values
    .map(Number)
    .filter(Number.isFinite)
    .sort((a, b) => a - b);
  if (!sorted.length) return 0;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function rowTokens(row = {}) {
  return [
    row.exerciseId,
    row.exerciseModuleId,
    row.metadata?.exerciseModuleId,
    row.metadata?.trainingProfileId,
  ].map((value) => String(value || '').trim().toLowerCase());
}

export function isDynamicWeightShiftDatasetRow(row = {}) {
  return rowTokens(row).some(isDynamicWeightShiftExerciseId);
}

function anatomicalDirectionForScreen(direction, mirrored = false) {
  if (!DYNAMIC_WEIGHT_SHIFT_DIRECTIONS.includes(direction)) return 'unknown';
  if (direction === 'right') return mirrored ? 'right' : 'left';
  return mirrored ? 'left' : 'right';
}

function storedDirection(row = {}) {
  const metadata = row.metadata || {};
  const storedScreenDirection = row.screenDirection ||
    metadata.screenDirection ||
    metadata.detectedScreenDirection;
  const convention = metadata.directionConvention || row.directionConvention;
  const direction = normalizeDynamicWeightShiftDirection(storedScreenDirection) ||
    (convention === DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION
      ? normalizeDynamicWeightShiftDirection(row.shiftDirection || metadata.shiftDirection)
      : null);
  if (!direction) return null;
  const mirrored = metadata.landmarksMirrored === true || metadata.mirrored === true;
  return {
    valid: true,
    direction,
    shiftDirection: direction,
    screenDirection: screenDirectionForDynamicWeightShift(direction),
    anatomicalDirection: metadata.anatomicalDirection || anatomicalDirectionForScreen(direction, mirrored),
    confidence: Number(metadata.directionConfidence) || null,
    peakShiftDeg: Number(metadata.peakShiftDeg) || null,
    source: metadata.directionSource || 'stored',
  };
}

export function dynamicWeightShiftDirectionForRow(row = {}, { preferStored = true } = {}) {
  if (preferStored) {
    const stored = storedDirection(row);
    if (stored) return stored;
  }

  const frames = Array.isArray(row.frames) ? row.frames : [];
  const measured = frames
    .map((frame) => ({
      frame,
      metrics: dynamicWeightShiftMetrics(frame?.landmarks || []),
    }))
    .filter(({ metrics }) => metrics.valid);
  if (!measured.length) {
    return {
      valid: false,
      direction: 'unknown',
      shiftDirection: 'unknown',
      anatomicalDirection: 'unknown',
      screenDirection: 'unknown',
      confidence: 0,
      peakShiftDeg: 0,
      source: 'unavailable',
    };
  }

  const centerSamples = measured
    .filter(({ frame }) => frame?.phase === 'rest')
    .map(({ metrics }) => metrics.torsoLeanDeg);
  const fallbackCenterCount = Math.max(1, Math.ceil(measured.length * 0.15));
  const neutralTorsoLeanDeg = median(centerSamples.length
    ? centerSamples
    : measured.slice(0, fallbackCenterCount).map(({ metrics }) => metrics.torsoLeanDeg));
  const mirrored = row.metadata?.landmarksMirrored === true || row.metadata?.mirrored === true;
  const adjusted = measured.map(({ frame }) => ({
    frame,
    metrics: dynamicWeightShiftMetrics(frame?.landmarks || [], { neutralTorsoLeanDeg, mirrored }),
  }));
  const targetAdjusted = adjusted.filter(({ frame }) => frame?.phase === 'target');
  const peakCandidates = targetAdjusted.length ? targetAdjusted : adjusted;
  const peak = peakCandidates.reduce((best, item) =>
    item.metrics.trunkShiftDeg > best.metrics.trunkShiftDeg ? item : best, peakCandidates[0]);
  const minTargetDeg = Number(DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY.reachedTargetMinDeg) || 8;
  const direction = normalizeDynamicWeightShiftDirection(peak.metrics.screenDirection);

  return {
    valid: !!direction,
    direction: direction || 'unknown',
    shiftDirection: direction || 'unknown',
    anatomicalDirection: peak.metrics.anatomicalDirection,
    screenDirection: peak.metrics.screenDirection,
    confidence: Math.min(1, peak.metrics.trunkShiftDeg / minTargetDeg),
    peakShiftDeg: peak.metrics.trunkShiftDeg,
    neutralTorsoLeanDeg,
    source: 'stored_landmarks',
  };
}

export function prepareDynamicWeightShiftDatasetRow(row = {}) {
  if (!isDynamicWeightShiftDatasetRow(row)) return row;
  const sourceFrames = Array.isArray(row.frames) ? row.frames : [];
  const frames = sourceFrames.map((frame) => {
    const sourceAngles = frame?.angles || frame?.jointAngles || {};
    const { trunk_shift: _removedTrunkShift, ...angles } = sourceAngles;
    return {
      ...frame,
      landmarks: normalizeDatasetLandmarks(frame?.landmarks || []),
      angles,
    };
  });
  const schema = resolveBodyRegionLandmarkSchema(DYNAMIC_WEIGHT_SHIFT_LANDMARK_SCHEMA_ID, { fallback: false });
  const schemaFields = modelManifestSchemaFields(schema);
  const phaseCounts = Object.fromEntries(DYNAMIC_WEIGHT_SHIFT_PHASES.map((phase) => [
    phase,
    frames.filter((frame) => frame?.phase === phase).length,
  ]));
  const {
    trunkShiftSource: _removedTrunkShiftSource,
    neutralTorsoLeanDeg: _removedNeutralTorsoLean,
    ...existingMetadata
  } = row.metadata || {};
  const base = {
    ...row,
    ...schemaFields,
    phaseLabels: [...DYNAMIC_WEIGHT_SHIFT_PHASES],
    frames,
    metadata: existingMetadata,
  };
  const measuredDirection = dynamicWeightShiftDirectionForRow(base, { preferStored: false });
  const stored = storedDirection(base);
  const trustedStoredDirection = existingMetadata.directionConvention === DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION
    ? stored
    : null;
  const manualDirection = existingMetadata.directionSource === 'manual_override' ? stored : null;
  const direction = manualDirection ||
    (Number(phaseCounts.rest || 0) > 0 && measuredDirection.valid
      ? measuredDirection
      : trustedStoredDirection || measuredDirection);
  const existingClass = normalizeDynamicWeightShiftClass(row.classLabel || existingMetadata.classLabel || row.label);
  const formLabel = row.formLabel || existingMetadata.formLabel || dynamicWeightShiftClassParts(existingClass)?.formLabel || null;
  const classLabel = buildDynamicWeightShiftClassLabel(formLabel, direction.direction);
  const trainingPhases = isWrongDynamicWeightShiftClass(classLabel)
    ? ['target']
    : [...DYNAMIC_WEIGHT_SHIFT_PHASES];
  const prepared = {
    ...base,
    label: classLabel || 'unlabeled',
    formLabel,
    classLabel,
    motionLabel: null,
    suggestedLabel: classLabel,
    metadata: {
      ...existingMetadata,
      ...schemaFields,
      phaseCounts,
      motionClassContract: DYNAMIC_WEIGHT_SHIFT_CLASS_CONTRACT,
      directionConvention: DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION,
      motionClasses: [...DYNAMIC_WEIGHT_SHIFT_CLASSES],
      phases: [...DYNAMIC_WEIGHT_SHIFT_PHASES],
      featureContract: 'shoulder_hip_landmarks_only.v1',
      formLabel,
      classLabel,
      trainingPhases,
      ...(direction.valid ? {
        shiftDirection: direction.direction,
        screenDirection: direction.screenDirection,
        anatomicalDirection: direction.anatomicalDirection,
        directionSource: direction.source,
      } : {}),
      detectedShiftDirection: measuredDirection.direction,
      detectedScreenDirection: measuredDirection.screenDirection,
      detectedAnatomicalDirection: measuredDirection.anatomicalDirection,
      directionConfidence: measuredDirection.confidence,
      peakShiftDeg: measuredDirection.peakShiftDeg,
    },
  };
  return prepared;
}

export function reviewDynamicWeightShiftDatasetRow(row = {}, formLabel) {
  if (!DYNAMIC_WEIGHT_SHIFT_FORM_LABELS.includes(formLabel)) {
    const error = new Error(`Invalid Dynamic Weight Shifts form label: ${formLabel}`);
    error.code = 'invalid_form_label';
    throw error;
  }
  const prepared = prepareDynamicWeightShiftDatasetRow(row);
  const direction = dynamicWeightShiftDirectionForRow(prepared);
  const classLabel = buildDynamicWeightShiftClassLabel(formLabel, direction.direction);
  const dataQuality = prepared.dataQuality || 'usable';
  const phaseCounts = prepared.metadata?.phaseCounts || {};
  const trainingPhases = formLabel === 'wrong' ? ['target'] : [...DYNAMIC_WEIGHT_SHIFT_PHASES];
  const phasesValid = trainingPhases.every((phase) => Number(phaseCounts[phase] || 0) >= 3) &&
    prepared.frames.every((frame) => DYNAMIC_WEIGHT_SHIFT_PHASES.includes(frame?.phase));
  const trainable = dataQuality === 'usable' &&
    prepared.repComplete === true &&
    !!prepared.landmarkSchemaId &&
    !prepared.missingPrimary?.length &&
    !prepared.missingStabilizer?.length &&
    direction.valid &&
    !!classLabel &&
    phasesValid;

  return {
    ...prepared,
    label: classLabel || 'unlabeled',
    formLabel,
    classLabel,
    motionLabel: null,
    suggestedLabel: classLabel,
    labelStatus: LABEL_STATUSES.REVIEWED,
    trainable,
    scoreable: trainable,
    metadata: {
      ...(prepared.metadata || {}),
      formLabel,
      classLabel,
      directionConvention: DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION,
      shiftDirection: direction.direction,
      anatomicalDirection: direction.anatomicalDirection,
      screenDirection: direction.screenDirection,
      directionConfidence: direction.confidence,
      directionSource: direction.source,
      peakShiftDeg: direction.peakShiftDeg,
      trainingPhases,
    },
  };
}

export function overrideDynamicWeightShiftDirection(row = {}, screenDirection) {
  const direction = normalizeDynamicWeightShiftDirection(screenDirection);
  if (!direction) {
    const error = new Error(`Invalid Dynamic Weight Shifts direction: ${screenDirection}`);
    error.code = 'invalid_shift_direction';
    throw error;
  }
  const prepared = prepareDynamicWeightShiftDatasetRow(row);
  const parts = dynamicWeightShiftClassParts(prepared.classLabel || prepared.label);
  const formLabel = prepared.formLabel || prepared.metadata?.formLabel || parts?.formLabel || null;
  const classLabel = buildDynamicWeightShiftClassLabel(formLabel, direction);
  const mirrored = prepared.metadata?.landmarksMirrored === true || prepared.metadata?.mirrored === true;
  return {
    ...prepared,
    ...(classLabel ? {
      label: classLabel,
      classLabel,
      motionLabel: null,
      suggestedLabel: classLabel,
    } : {}),
    metadata: {
      ...(prepared.metadata || {}),
      ...(classLabel ? { classLabel } : {}),
      directionConvention: DYNAMIC_WEIGHT_SHIFT_DIRECTION_CONVENTION,
      shiftDirection: direction,
      anatomicalDirection: anatomicalDirectionForScreen(direction, mirrored),
      screenDirection: screenDirectionForDynamicWeightShift(direction),
      directionSource: 'manual_override',
    },
  };
}

export function dynamicWeightShiftClassForRow(row = {}) {
  return normalizeDynamicWeightShiftClass(row.classLabel || row.metadata?.classLabel || row.label);
}
