export const RULE_BASED_SESSION_SCHEMA = 'physioai.rule_based_bottle_grab_session.v1';
export const SIT_TO_STAND_RULE_BASED_SESSION_SCHEMA = 'physioai.rule_based_sit_to_stand_session.v1';

const OUTCOMES = new Set(['correct', 'incorrect', 'cannot_assess', 'incomplete']);
const CONTRACTS_BY_SCHEMA = Object.freeze({
  [RULE_BASED_SESSION_SCHEMA]: Object.freeze({
    exerciseID: 'bottle_grab',
    trackingProfile: 'pose_plus_hand',
    anatomicalSide: 'left',
    decisionScope: 'experimental_rule_based_visible_faults',
  }),
  [SIT_TO_STAND_RULE_BASED_SESSION_SCHEMA]: Object.freeze({
    exerciseID: 'sit_to_stand',
    trackingProfile: 'pose_only',
    anatomicalSide: 'bilateral',
    decisionScope: 'experimental_rule_based_visible_form',
  }),
});
const FORBIDDEN_KEYS = new Set([
  'rawLandmarks', 'landmarks', 'pose', 'hand', 'rawFrame', 'image',
  'imageBytes', 'pixelCoordinates', 'video', 'videoBytes', 'x', 'y', 'z',
  'patientId', 'patientID', 'patientIdentifier', 'userId', 'userID',
  'participantId', 'participantID', 'email', 'fullName',
]);

const isRecord = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
const isNonNegativeInteger = (value) => Number.isInteger(value) && value >= 0;

function sortedCounts(counts) {
  return Object.entries(counts || {})
    .filter(([, count]) => isNonNegativeInteger(count) && count > 0)
    .map(([label, count]) => ({ label, count }))
    .sort((left, right) => right.count - left.count || left.label.localeCompare(right.label));
}

function findForbiddenKey(value, path = '$') {
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index += 1) {
      const found = findForbiddenKey(value[index], `${path}[${index}]`);
      if (found) return found;
    }
    return null;
  }
  if (!isRecord(value)) return null;
  for (const [key, child] of Object.entries(value)) {
    if (FORBIDDEN_KEYS.has(key)) return `${path}.${key}`;
    const found = findForbiddenKey(child, `${path}.${key}`);
    if (found) return found;
  }
  return null;
}

function validateRecord(record) {
  const errors = [];
  if (!isRecord(record)) return ['JSON root must be an object'];
  const contract = CONTRACTS_BY_SCHEMA[record.schema];
  if (!contract) errors.push('unsupported rule-based session schema');
  for (const field of ['moduleID', 'moduleVersion', 'exerciseID', 'trackingProfile', 'anatomicalSide', 'decisionScope']) {
    if (typeof record[field] !== 'string' || !record[field]) errors.push(`missing ${field}`);
  }
  for (const [field, expected] of Object.entries(contract || {})) {
    if (record[field] !== expected) errors.push(`unsupported ${field}; expected ${expected}`);
  }
  if (!isRecord(record.summary)) {
    errors.push('missing summary');
  } else {
    for (const field of [
      'totalReps', 'correctRepCount', 'incorrectRepCount', 'cannotAssessRepCount', 'incompleteRepCount',
    ]) {
      if (!isNonNegativeInteger(record.summary[field])) errors.push(`summary.${field} must be a non-negative integer`);
    }
    if (!isRecord(record.summary.wrongByBodyRegion)) errors.push('summary.wrongByBodyRegion must be an object');
    if (!isRecord(record.summary.wrongBySeverity)) errors.push('summary.wrongBySeverity must be an object');
    for (const [field, counts] of Object.entries({
      wrongByBodyRegion: record.summary.wrongByBodyRegion,
      wrongBySeverity: record.summary.wrongBySeverity,
    })) {
      if (isRecord(counts) && Object.values(counts).some((count) => !isNonNegativeInteger(count))) {
        errors.push(`summary.${field} values must be non-negative integers`);
      }
    }
  }
  if (!Array.isArray(record.repetitions)) {
    errors.push('repetitions must be an array');
  } else {
    record.repetitions.forEach((repetition, index) => {
      if (!isRecord(repetition)) {
        errors.push(`repetitions[${index}] must be an object`);
        return;
      }
      if (repetition.repIndex !== index + 1) errors.push(`repetitions[${index}].repIndex must be contiguous`);
      if (!OUTCOMES.has(repetition.outcome)) errors.push(`repetitions[${index}].outcome is invalid`);
      if (!Array.isArray(repetition.faultTags)) errors.push(`repetitions[${index}].faultTags must be an array`);
      if (!Array.isArray(repetition.bodyRegions)) errors.push(`repetitions[${index}].bodyRegions must be an array`);
      if (!Array.isArray(repetition.faultSignals)) errors.push(`repetitions[${index}].faultSignals must be an array`);
      if (repetition.severity !== null && typeof repetition.severity !== 'string') errors.push(`repetitions[${index}].severity must be a string or null`);
      for (const field of ['assessableFrameCount', 'skippedFrameCount']) {
        if (!isNonNegativeInteger(repetition[field])) errors.push(`repetitions[${index}].${field} must be a non-negative integer`);
      }
      if (!isRecord(repetition.skippedReasonCounts)) errors.push(`repetitions[${index}].skippedReasonCounts must be an object`);
    });
  }
  if (!isRecord(record.claimBoundary)) {
    errors.push('missing claimBoundary');
  } else {
    const expectedBoundary = {
      experimental: true,
      clinicalDecision: false,
      patientFacingApproved: false,
      rawMediaPersisted: false,
      rawLandmarksPersisted: false,
    };
    for (const [field, expected] of Object.entries(expectedBoundary)) {
      if (record.claimBoundary[field] !== expected) errors.push(`claimBoundary.${field} must be ${expected}`);
    }
  }
  if (isRecord(record.summary) && Array.isArray(record.repetitions)) {
    const counts = record.repetitions.reduce((total, repetition) => {
      if (OUTCOMES.has(repetition?.outcome)) total[repetition.outcome] += 1;
      return total;
    }, { correct: 0, incorrect: 0, cannot_assess: 0, incomplete: 0 });
    if (record.summary.totalReps !== record.repetitions.length) errors.push('summary.totalReps does not match repetitions');
    if (record.summary.correctRepCount !== counts.correct) errors.push('summary.correctRepCount does not match repetitions');
    if (record.summary.incorrectRepCount !== counts.incorrect) errors.push('summary.incorrectRepCount does not match repetitions');
    if (record.summary.cannotAssessRepCount !== counts.cannot_assess) errors.push('summary.cannotAssessRepCount does not match repetitions');
    if (record.summary.incompleteRepCount !== counts.incomplete) errors.push('summary.incompleteRepCount does not match repetitions');
  }
  const forbidden = findForbiddenKey(record);
  if (forbidden) errors.push(`raw/private coordinate field is not allowed: ${forbidden}`);
  return errors;
}

function makeView(record) {
  return {
    totalReps: record.summary.totalReps,
    correctRepCount: record.summary.correctRepCount,
    incorrectRepCount: record.summary.incorrectRepCount,
    cannotAssessRepCount: record.summary.cannotAssessRepCount,
    incompleteRepCount: record.summary.incompleteRepCount,
    wrongByBodyRegion: sortedCounts(record.summary.wrongByBodyRegion),
    wrongBySeverity: sortedCounts(record.summary.wrongBySeverity),
    repetitions: record.repetitions.map((repetition) => ({
      repIndex: repetition.repIndex,
      outcome: repetition.outcome,
      faultTags: repetition.faultTags.slice(),
      bodyRegions: repetition.bodyRegions.slice(),
      severity: repetition.severity ?? null,
      assessableFrameCount: repetition.assessableFrameCount,
      skippedFrameCount: repetition.skippedFrameCount,
      skippedReasonCounts: { ...(repetition.skippedReasonCounts || {}) },
    })),
  };
}

export function readRuleBasedSessionJSON(text) {
  let record;
  try {
    record = JSON.parse(text);
  } catch {
    return { valid: false, errors: ['invalid JSON'], record: null, view: null };
  }
  const errors = validateRecord(record);
  return {
    valid: errors.length === 0,
    errors,
    record: errors.length === 0 ? record : null,
    view: errors.length === 0 ? makeView(record) : null,
  };
}
