import {
  DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS,
  DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY,
} from './rules.js';

export const DYNAMIC_WEIGHT_SHIFTS_SESSION_ANALYSIS_POLICY = Object.freeze({
  schemaVersion: 'physioai.dynamic_weight_shifts.session_analysis.v1',
  version: 'dynamic_weight_shifts.session_review.v1',
  primaryJoint: 'trunk_shift',
  shoulderTiltJoint: 'shoulder_tilt',
  restThresholdDeg: DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY.restResetDeg,
  // The arm-raise hysteresis is wider than the complete DWS Rest-to-Target
  // range. Start an analysis attempt at the first of the hysteresis boundary
  // or the exercise-specific Target boundary so reviewed DWS reps remain
  // geometrically faithful while sharing the same Hybrid timing.
  leaveRestThresholdDeg: Math.min(
    DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY.reachedTargetMinDeg,
    DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY.restResetDeg
      + DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS.hysteresisDeg,
  ),
  targetThresholdDeg: DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY.reachedTargetMinDeg,
  shoulderTiltMaxDeg: DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY.requiredJointRules
    .find((rule) => rule.joint === 'shoulder_tilt')?.reachedTargetMaxDeg ?? 15,
  shoulderTiltAffectedFrameRatio: 0.3,
  // Count strictly above eight degrees; ten degrees remains a modest coaching
  // goal while the observed fourteen-degree posture is comfortably Target.
  adequateLeanDeg: 10,
  allowMissingBoundary: true,
  anglePrecisionDeg: 0.1,
});

function finite(value) {
  if (value == null || typeof value === 'boolean' || (typeof value === 'string' && !value.trim())) {
    return null;
  }
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function rounded(value, precision = 0.1) {
  if (!Number.isFinite(value)) return null;
  return Number((Math.round(value / precision) * precision).toFixed(6));
}

function roundedRatio(value) {
  return Number.isFinite(value) ? Math.round(value * 1_000) / 1_000 : null;
}

function median(values = []) {
  const sorted = values.filter(Number.isFinite).slice().sort((left, right) => left - right);
  if (!sorted.length) return null;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function clone(value) {
  return value == null ? value : JSON.parse(JSON.stringify(value));
}

function boundaryAllowsAnalysis(boundary, policy) {
  if (!boundary) return policy.allowMissingBoundary === true;
  return boundary.status === 'inside'
    && boundary.scoreable !== false
    && boundary.trainable !== false
    && boundary.ok !== false;
}

function resolvePolicy(exercise = {}, policy = {}, overrides = {}) {
  const targetPolicy = exercise.targetOutcomePolicy || {};
  const shoulderRule = (targetPolicy.requiredJointRules || [])
    .find((rule) => rule?.joint === 'shoulder_tilt') || {};
  const merged = {
    ...DYNAMIC_WEIGHT_SHIFTS_SESSION_ANALYSIS_POLICY,
    targetThresholdDeg: targetPolicy.reachedTargetMinDeg
      ?? DYNAMIC_WEIGHT_SHIFTS_SESSION_ANALYSIS_POLICY.targetThresholdDeg,
    restThresholdDeg: targetPolicy.restResetDeg
      ?? DYNAMIC_WEIGHT_SHIFTS_SESSION_ANALYSIS_POLICY.restThresholdDeg,
    shoulderTiltMaxDeg: shoulderRule.reachedTargetMaxDeg
      ?? DYNAMIC_WEIGHT_SHIFTS_SESSION_ANALYSIS_POLICY.shoulderTiltMaxDeg,
    ...policy,
    ...overrides,
  };
  merged.targetThresholdDeg = Math.max(0, finite(merged.targetThresholdDeg) ?? 8);
  merged.restThresholdDeg = Math.max(0, finite(merged.restThresholdDeg) ?? 8);
  merged.leaveRestThresholdDeg = finite(merged.leaveRestThresholdDeg)
    ?? Math.min(
      merged.targetThresholdDeg,
      merged.restThresholdDeg + DYNAMIC_WEIGHT_SHIFTS_DECISION_DEFAULTS.hysteresisDeg,
    );
  merged.shoulderTiltMaxDeg = Math.max(0, finite(merged.shoulderTiltMaxDeg) ?? 15);
  merged.shoulderTiltAffectedFrameRatio = clamp(
    finite(merged.shoulderTiltAffectedFrameRatio) ?? 0.3,
    0,
    1,
  );
  merged.adequateLeanDeg = Math.max(
    merged.targetThresholdDeg,
    finite(merged.adequateLeanDeg) ?? 10,
  );
  return Object.freeze(merged);
}

export function createDynamicWeightShiftsSessionAnalyzer({
  exercise = {},
  policy = {},
  timestampNow = () => (globalThis.performance?.now ? globalThis.performance.now() : Date.now()),
  ...overrides
} = {}) {
  const resolvedPolicy = resolvePolicy(exercise, policy, overrides);
  let reps;
  let active;
  let totalFrames;
  let usableFrames;
  let rejectedFrames;
  let trackingLossEvents;
  let trackingLost;
  let lastTimestamp;
  let finishedSummary;

  function reset() {
    reps = [];
    active = null;
    totalFrames = 0;
    usableFrames = 0;
    rejectedFrames = 0;
    trackingLossEvents = 0;
    trackingLost = false;
    lastTimestamp = null;
    finishedSummary = null;
  }

  function beginAttempt(sample) {
    active = { samples: [sample], startedAt: sample.timestamp };
  }

  function finalizeAttempt({ returnedToRest = false } = {}) {
    if (!active?.samples?.length) {
      active = null;
      return null;
    }
    const samples = active.samples;
    const peakLeanDeg = Math.max(...samples.map((sample) => sample.trunkShiftDeg));
    if (peakLeanDeg <= resolvedPolicy.leaveRestThresholdDeg) {
      active = null;
      return null;
    }
    const targetSamples = samples.filter(
      (sample) => sample.trunkShiftDeg > resolvedPolicy.targetThresholdDeg,
    );
    const tiltedTargetFrames = targetSamples.filter(
      (sample) => sample.shoulderTiltDeg > resolvedPolicy.shoulderTiltMaxDeg,
    ).length;
    const tiltedTargetFrameRatio = targetSamples.length
      ? tiltedTargetFrames / targetSamples.length
      : null;
    const targetReached = targetSamples.length > 0;
    const medianTargetLeanDeg = median(targetSamples.map((sample) => sample.trunkShiftDeg));
    const shoulderTiltAffected = targetSamples.length > 0
      && tiltedTargetFrameRatio >= resolvedPolicy.shoulderTiltAffectedFrameRatio;
    const lowLean = targetReached
      && Number.isFinite(medianTargetLeanDeg)
      && medianTargetLeanDeg < resolvedPolicy.adequateLeanDeg;
    const issueCodes = [
      !targetReached ? 'target_not_reached' : null,
      shoulderTiltAffected ? 'frequent_shoulder_tilt' : null,
    ].filter(Boolean);
    const rep = {
      index: reps.length + 1,
      targetReached,
      returnedToRest,
      startedAt: active.startedAt,
      completedAt: samples.at(-1)?.timestamp ?? active.startedAt,
      peakLeanDeg: rounded(peakLeanDeg, resolvedPolicy.anglePrecisionDeg),
      medianTargetLeanDeg: rounded(medianTargetLeanDeg, resolvedPolicy.anglePrecisionDeg),
      lowLean,
      shoulderTiltAssessed: targetSamples.length > 0,
      shoulderTiltAffected,
      tiltedTargetFrameRatio: roundedRatio(tiltedTargetFrameRatio),
      maxShoulderTiltDeg: rounded(
        targetSamples.length
          ? Math.max(...targetSamples.map((sample) => sample.shoulderTiltDeg))
          : null,
        resolvedPolicy.anglePrecisionDeg,
      ),
      meetsPatientTargetRules: targetReached && !shoulderTiltAffected,
      hasTechniqueIssue: issueCodes.length > 0,
      issueCodes,
    };
    reps.push(rep);
    active = null;
    return rep;
  }

  function buildSummary({ patientCountedReps: patientCountedOverride = null } = {}) {
    const runtimeCount = finite(patientCountedOverride);
    const patientCountedReps = runtimeCount == null
      ? reps.filter((rep) => rep.meetsPatientTargetRules).length
      : Math.max(0, Math.round(runtimeCount));
    const totalAttempts = Math.max(reps.length, patientCountedReps);
    const targetReachedReps = reps.filter((rep) => rep.targetReached).length;
    const shoulderTiltAssessedReps = reps.filter((rep) => rep.shoulderTiltAssessed).length;
    const shoulderTiltAffectedReps = reps.filter((rep) => rep.shoulderTiltAffected).length;
    const lowLeanReps = reps.filter((rep) => rep.lowLean).length;
    const techniqueIssueReps = reps.filter((rep) => rep.hasTechniqueIssue).length;
    const usableFrameRatio = totalFrames ? usableFrames / totalFrames : 0;
    return {
      schemaVersion: resolvedPolicy.schemaVersion,
      policyVersion: resolvedPolicy.version,
      status: reps.length > 0 && usableFrameRatio >= 0.7 ? 'scorable' : 'insufficient_data',
      totalAttempts,
      analyzedAttempts: reps.length,
      patientCountedReps,
      notCountedAttempts: Math.max(0, totalAttempts - patientCountedReps),
      patientCountSource: runtimeCount == null ? 'rule_reconstruction' : 'patient_runtime',
      techniqueIssueReps,
      cleanTechniqueReps: Math.max(0, reps.length - techniqueIssueReps),
      targetReachedReps,
      returnedToRestReps: reps.filter((rep) => rep.returnedToRest).length,
      shoulderTiltAssessedReps,
      shoulderTiltAffectedReps,
      lowLeanReps,
      adequateLeanReps: Math.max(0, targetReachedReps - lowLeanReps),
      medianTargetLeanDeg: rounded(
        median(reps.map((rep) => rep.medianTargetLeanDeg)),
        resolvedPolicy.anglePrecisionDeg,
      ),
      medianPeakLeanDeg: rounded(
        median(reps.map((rep) => rep.peakLeanDeg)),
        resolvedPolicy.anglePrecisionDeg,
      ),
      shoulderTiltMaxDeg: resolvedPolicy.shoulderTiltMaxDeg,
      adequateLeanDeg: resolvedPolicy.adequateLeanDeg,
      dataQuality: {
        totalFrames,
        usableFrames,
        rejectedFrames,
        usableFrameRatio: roundedRatio(usableFrameRatio),
        outboundUsableFrameRatio: roundedRatio(usableFrameRatio),
        trackingLossEvents,
        interruptedAttempts: 0,
        discardedAttempts: 0,
      },
      reps: reps.map((rep) => ({ ...rep })),
    };
  }

  function push({
    timestamp = timestampNow(),
    jointAngles = {},
    boundary = null,
    hasPose = true,
  } = {}) {
    if (finishedSummary) return clone(finishedSummary);
    const resolvedTimestamp = finite(timestamp) ?? finite(timestampNow()) ?? Date.now();
    totalFrames += 1;
    const trunkShiftDeg = finite(jointAngles?.[resolvedPolicy.primaryJoint]);
    const shoulderTiltDeg = finite(jointAngles?.[resolvedPolicy.shoulderTiltJoint]);
    const timestampInvalid = lastTimestamp != null && resolvedTimestamp <= lastTimestamp;
    lastTimestamp = resolvedTimestamp;
    if (timestampInvalid
      || hasPose === false
      || trunkShiftDeg == null
      || shoulderTiltDeg == null
      || !boundaryAllowsAnalysis(boundary, resolvedPolicy)) {
      rejectedFrames += 1;
      if (!trackingLost) trackingLossEvents += 1;
      trackingLost = true;
      return clone(buildSummary());
    }
    trackingLost = false;
    usableFrames += 1;
    const sample = {
      timestamp: resolvedTimestamp,
      trunkShiftDeg: Math.abs(trunkShiftDeg),
      shoulderTiltDeg: Math.abs(shoulderTiltDeg),
    };

    if (!active && sample.trunkShiftDeg > resolvedPolicy.leaveRestThresholdDeg) {
      beginAttempt(sample);
    } else if (active) {
      active.samples.push(sample);
      if (sample.trunkShiftDeg <= resolvedPolicy.restThresholdDeg) {
        finalizeAttempt({ returnedToRest: true });
      }
    }
    return clone(buildSummary());
  }

  function finish({ patientCountedReps = null } = {}) {
    if (finishedSummary) return clone(finishedSummary);
    if (active) finalizeAttempt({ returnedToRest: false });
    finishedSummary = buildSummary({ patientCountedReps });
    return clone(finishedSummary);
  }

  reset();
  return {
    policy: resolvedPolicy,
    push,
    finish,
    reset,
    getSnapshot: () => clone(buildSummary()),
  };
}

export default createDynamicWeightShiftsSessionAnalyzer;
