import {
  LATERAL_ARM_RAISE_DECISION_DEFAULTS,
  LATERAL_ARM_RAISE_TARGET_POLICY,
} from './rules.js';

export const LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY = Object.freeze({
  schemaVersion: 'physioai.lateral_arm_raise.session_analysis.v4',
  version: 'lateral_arm_raise.outbound_analysis.v4',
  angleSpace: 'mediapipe_normalized_xy_2d.v1',
  primaryJoint: 'right_shoulder',
  elbowJoint: 'right_elbow',
  // Match the native critical-motion SDK's rest recovery hysteresis. The
  // strict 30-degree target reset made real iPhone sessions report zero reps
  // even though the native counter had already re-armed at 40 degrees.
  restThresholdDeg: Math.min(
    LATERAL_ARM_RAISE_TARGET_POLICY.restResetDeg + 10,
    Math.max(
      LATERAL_ARM_RAISE_TARGET_POLICY.restResetDeg,
      LATERAL_ARM_RAISE_TARGET_POLICY.reachedTargetMinDeg - 20,
    ),
  ),
  leaveRestThresholdDeg: Math.min(
    LATERAL_ARM_RAISE_TARGET_POLICY.restResetDeg + 10,
    Math.max(
      LATERAL_ARM_RAISE_TARGET_POLICY.restResetDeg,
      LATERAL_ARM_RAISE_TARGET_POLICY.reachedTargetMinDeg - 20,
    ),
  )
    + LATERAL_ARM_RAISE_DECISION_DEFAULTS.hysteresisDeg,
  targetThresholdDeg: LATERAL_ARM_RAISE_TARGET_POLICY.reachedTargetMinDeg,
  restHoldMs: LATERAL_ARM_RAISE_DECISION_DEFAULTS.restHoldMs,
  targetHoldMs: LATERAL_ARM_RAISE_DECISION_DEFAULTS.targetHoldMs,
  minOutboundExcursionDeg: 10,
  peakDropDeg: 5,
  peakConfirmMs: 180,
  finishPlateauMinMs: 400,
  finishPlateauMaxVelocityDegPerSec: 5,
  finishPlateauRangeDeg: 2,
  upDownMinExcursionDeg: 5,
  frequentUpDownMinEvents: 2,
  inefficientPathThreshold: 0.8,
  pauseMinMs: 400,
  pauseVelocityDegPerSec: 5,
  elbowBendThresholdDeg: null,
  elbowBendAffectedMinMs: 250,
  elbowBaselineWindowMs: 600,
  elbowBaselineMinSamples: 5,
  elbowMaxDeviationFromRestDeg: 22,
  elbowAdaptiveThresholdMinDeg: 145,
  elbowAdaptiveThresholdMaxDeg: 150,
  minElbowUsableRatio: 0.8,
  smoothingWindowMs: 100,
  maxFrameGapMs: 250,
  trackingLossGraceMs: 500,
  allowMissingBoundary: false,
  minSessionUsableRatio: 0.8,
  anglePrecisionDeg: LATERAL_ARM_RAISE_DECISION_DEFAULTS.anglePrecisionDeg,
});

function finiteNumber(value) {
  if (value == null || typeof value === 'boolean' || (typeof value === 'string' && !value.trim())) return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function nonNegative(value, fallback) {
  const number = finiteNumber(value);
  return number != null && number >= 0 ? number : fallback;
}

function positive(value, fallback) {
  const number = finiteNumber(value);
  return number != null && number > 0 ? number : fallback;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function median(values = []) {
  const sorted = values.filter(Number.isFinite).slice().sort((a, b) => a - b);
  if (!sorted.length) return null;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

function rounded(value, precision = 0.1) {
  if (!Number.isFinite(value)) return null;
  const step = positive(precision, 0.1);
  return Number((Math.round(value / step) * step).toFixed(6));
}

function roundedRatio(value) {
  return Number.isFinite(value) ? Math.round(value * 1_000) / 1_000 : null;
}

function clone(value) {
  return value == null ? value : JSON.parse(JSON.stringify(value));
}

function boundaryAllowsAnalysis(boundary, policy) {
  if (!boundary) return policy.allowMissingBoundary === true;
  return boundary.status === 'inside'
    && boundary.scoreable === true
    && boundary.trainable !== false
    && boundary.ok !== false;
}

function resolvePolicy(exercise = {}, policy = {}, overrides = {}) {
  const targetPolicy = exercise.targetOutcomePolicy || {};
  const elbowPolicy = (targetPolicy.requiredJointRules || [])
    .find((rule) => rule?.joint === 'right_elbow') || {};
  const targetThresholdDeg = targetPolicy.reachedTargetMinDeg
    ?? LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY.targetThresholdDeg;
  const strictRestThresholdDeg = targetPolicy.restResetDeg
    ?? LATERAL_ARM_RAISE_TARGET_POLICY.restResetDeg;
  const recoveryRestThresholdDeg = Math.min(
    strictRestThresholdDeg + 10,
    Math.max(strictRestThresholdDeg, targetThresholdDeg - 20),
  );
  const explicitLeaveRestThresholdDeg = overrides.leaveRestThresholdDeg
    ?? policy.leaveRestThresholdDeg;
  const merged = {
    ...LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY,
    targetThresholdDeg,
    restThresholdDeg: exercise.sessionAnalysisRestThresholdDeg
      ?? targetPolicy.sessionAnalysisRestThresholdDeg
      ?? recoveryRestThresholdDeg,
    leaveRestThresholdDeg: recoveryRestThresholdDeg
      + LATERAL_ARM_RAISE_DECISION_DEFAULTS.hysteresisDeg,
    targetHoldMs: exercise.targetHoldMs
      ?? LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY.targetHoldMs,
    restHoldMs: exercise.restHoldMs
      ?? LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY.restHoldMs,
    smoothingWindowMs: elbowPolicy.smoothingWindowMs
      ?? LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY.smoothingWindowMs,
    elbowBaselineWindowMs: elbowPolicy.restBaselineWindowMs
      ?? LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY.elbowBaselineWindowMs,
    elbowBaselineMinSamples: elbowPolicy.restBaselineMinSamples
      ?? LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY.elbowBaselineMinSamples,
    elbowMaxDeviationFromRestDeg: elbowPolicy.maxDeviationFromRestDeg
      ?? LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY.elbowMaxDeviationFromRestDeg,
    elbowAdaptiveThresholdMinDeg: elbowPolicy.adaptiveThresholdMinDeg
      ?? LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY.elbowAdaptiveThresholdMinDeg,
    elbowAdaptiveThresholdMaxDeg: elbowPolicy.adaptiveThresholdMaxDeg
      ?? LATERAL_ARM_RAISE_SESSION_ANALYSIS_POLICY.elbowAdaptiveThresholdMaxDeg,
    ...policy,
    ...overrides,
  };
  merged.leaveRestThresholdDeg = finiteNumber(explicitLeaveRestThresholdDeg)
    ?? (Number(merged.restThresholdDeg) + LATERAL_ARM_RAISE_DECISION_DEFAULTS.hysteresisDeg);
  merged.targetThresholdDeg = positive(merged.targetThresholdDeg, 70);
  merged.restThresholdDeg = nonNegative(merged.restThresholdDeg, 30);
  merged.restHoldMs = nonNegative(merged.restHoldMs, 180);
  merged.targetHoldMs = nonNegative(merged.targetHoldMs, 300);
  merged.minOutboundExcursionDeg = positive(merged.minOutboundExcursionDeg, 10);
  merged.peakDropDeg = positive(merged.peakDropDeg, 5);
  merged.peakConfirmMs = nonNegative(merged.peakConfirmMs, 180);
  merged.finishPlateauMinMs = nonNegative(merged.finishPlateauMinMs, 400);
  merged.finishPlateauMaxVelocityDegPerSec = nonNegative(
    merged.finishPlateauMaxVelocityDegPerSec,
    5,
  );
  merged.finishPlateauRangeDeg = positive(merged.finishPlateauRangeDeg, 2);
  merged.upDownMinExcursionDeg = positive(merged.upDownMinExcursionDeg, 5);
  merged.frequentUpDownMinEvents = Math.max(1, Math.round(positive(merged.frequentUpDownMinEvents, 2)));
  merged.inefficientPathThreshold = clamp(
    positive(merged.inefficientPathThreshold, 0.8),
    0.01,
    1,
  );
  merged.pauseMinMs = nonNegative(merged.pauseMinMs, 400);
  merged.pauseVelocityDegPerSec = nonNegative(merged.pauseVelocityDegPerSec, 5);
  merged.elbowBendAffectedMinMs = nonNegative(merged.elbowBendAffectedMinMs, 250);
  merged.elbowBaselineWindowMs = nonNegative(merged.elbowBaselineWindowMs, 600);
  merged.elbowBaselineMinSamples = Math.max(1, Math.round(positive(merged.elbowBaselineMinSamples, 5)));
  merged.smoothingWindowMs = nonNegative(merged.smoothingWindowMs, 100);
  merged.maxFrameGapMs = positive(merged.maxFrameGapMs, 250);
  merged.trackingLossGraceMs = positive(merged.trackingLossGraceMs, 500);
  merged.minElbowUsableRatio = clamp(nonNegative(merged.minElbowUsableRatio, 0.8), 0, 1);
  merged.minSessionUsableRatio = clamp(nonNegative(merged.minSessionUsableRatio, 0.8), 0, 1);
  return Object.freeze(merged);
}

function smoothedElbows(samples, windowMs) {
  if (windowMs <= 0) return samples.map((sample) => sample.elbow);
  return samples.map((sample, index) => {
    if (!Number.isFinite(sample.elbow)) return null;
    const values = [];
    for (let cursor = index; cursor >= 0; cursor -= 1) {
      const candidate = samples[cursor];
      if (candidate.segment !== sample.segment || sample.timestamp - candidate.timestamp > windowMs) break;
      if (Number.isFinite(candidate.elbow)) values.push(candidate.elbow);
    }
    return median(values);
  });
}

function countUpDownEvents(samples, minimumExcursionDeg, maxFrameGapMs) {
  if (samples.length < 3) return 0;
  let high = samples[0].shoulder;
  let inDrop = false;
  let trough = high;
  let events = 0;

  for (let index = 1; index < samples.length; index += 1) {
    const sample = samples[index];
    const previous = samples[index - 1];
    const continuous = sample.segment === previous.segment
      && sample.timestamp - previous.timestamp <= maxFrameGapMs;
    if (!continuous) {
      high = sample.shoulder;
      trough = sample.shoulder;
      inDrop = false;
      continue;
    }
    if (!inDrop) {
      if (sample.shoulder >= high) high = sample.shoulder;
      else if (high - sample.shoulder >= minimumExcursionDeg) {
        inDrop = true;
        trough = sample.shoulder;
      }
      continue;
    }
    trough = Math.min(trough, sample.shoulder);
    if (sample.shoulder - trough >= minimumExcursionDeg) {
      events += 1;
      high = sample.shoulder;
      trough = sample.shoulder;
      inDrop = false;
    }
  }
  return events;
}

function pauseMetrics(samples, policy) {
  let count = 0;
  let durationMs = 0;
  let pauseStartedAt = null;
  let pauseEndedAt = null;

  const finishPause = () => {
    if (pauseStartedAt == null || pauseEndedAt == null) return;
    const duration = Math.max(0, pauseEndedAt - pauseStartedAt);
    if (duration >= policy.pauseMinMs) {
      count += 1;
      durationMs += duration;
    }
    pauseStartedAt = null;
    pauseEndedAt = null;
  };

  for (let index = 1; index < samples.length; index += 1) {
    const previous = samples[index - 1];
    const sample = samples[index];
    const deltaMs = sample.timestamp - previous.timestamp;
    const continuous = sample.segment === previous.segment
      && deltaMs > 0
      && deltaMs <= policy.maxFrameGapMs;
    const velocity = continuous
      ? Math.abs(sample.shoulder - previous.shoulder) / (deltaMs / 1_000)
      : Infinity;
    if (velocity <= policy.pauseVelocityDegPerSec) {
      if (pauseStartedAt == null) pauseStartedAt = previous.timestamp;
      pauseEndedAt = sample.timestamp;
    } else {
      finishPause();
    }
  }
  finishPause();
  return { count, durationMs };
}

function elbowMetrics(samples, active, policy) {
  const elbows = smoothedElbows(samples, policy.smoothingWindowMs);
  const usableCount = elbows.filter(Number.isFinite).length;
  const usableRatio = samples.length ? usableCount / samples.length : 0;
  const fixedThreshold = finiteNumber(policy.elbowBendThresholdDeg);
  const baseline = Number.isFinite(active.elbowBaselineDeg) ? active.elbowBaselineDeg : null;
  const adaptiveThreshold = baseline == null
    ? policy.elbowAdaptiveThresholdMaxDeg
    : clamp(
      baseline - policy.elbowMaxDeviationFromRestDeg,
      policy.elbowAdaptiveThresholdMinDeg,
      policy.elbowAdaptiveThresholdMaxDeg,
    );
  const threshold = fixedThreshold ?? adaptiveThreshold;
  const assessed = usableRatio >= policy.minElbowUsableRatio;
  let detected = false;
  let totalDurationMs = 0;
  let longestDurationMs = 0;
  let intervalStartedAt = null;
  let intervalEndedAt = null;

  const finishInterval = () => {
    if (intervalStartedAt == null || intervalEndedAt == null) return;
    const duration = Math.max(0, intervalEndedAt - intervalStartedAt);
    totalDurationMs += duration;
    longestDurationMs = Math.max(longestDurationMs, duration);
    intervalStartedAt = null;
    intervalEndedAt = null;
  };

  for (let index = 0; index < samples.length; index += 1) {
    const elbow = elbows[index];
    const sample = samples[index];
    const bent = Number.isFinite(elbow) && elbow < threshold;
    if (!bent) {
      finishInterval();
      continue;
    }
    detected = true;
    const previous = index > 0 ? samples[index - 1] : null;
    const previousBent = index > 0 && Number.isFinite(elbows[index - 1]) && elbows[index - 1] < threshold;
    const continuous = previous
      && previousBent
      && sample.segment === previous.segment
      && sample.timestamp - previous.timestamp <= policy.maxFrameGapMs;
    if (!continuous) {
      finishInterval();
      intervalStartedAt = sample.timestamp;
      intervalEndedAt = sample.timestamp;
    } else {
      intervalEndedAt = sample.timestamp;
    }
  }
  finishInterval();

  return {
    assessed,
    detected: assessed ? detected : null,
    durationMs: assessed ? Math.round(totalDurationMs) : null,
    longestDurationMs: assessed ? Math.round(longestDurationMs) : null,
    affected: assessed ? totalDurationMs >= policy.elbowBendAffectedMinMs : null,
    thresholdDeg: rounded(threshold, policy.anglePrecisionDeg),
    baselineDeg: rounded(baseline, policy.anglePrecisionDeg),
    usableRatio: roundedRatio(usableRatio),
  };
}

function pathEfficiency(samples) {
  if (samples.length < 2) return null;
  const direct = Math.max(...samples.map((sample) => sample.shoulder)) - samples[0].shoulder;
  let travelled = 0;
  for (let index = 1; index < samples.length; index += 1) {
    const previous = samples[index - 1];
    const sample = samples[index];
    if (sample.segment !== previous.segment) continue;
    travelled += Math.abs(sample.shoulder - previous.shoulder);
  }
  if (travelled <= 1e-6) return direct <= 1e-6 ? 1 : null;
  return clamp(direct / travelled, 0, 1);
}

function terminalPlateauDuration(samples, policy) {
  if (samples.length < 2) return 0;
  const last = samples.at(-1);
  let startedAt = last.timestamp;
  let startAngle = last.shoulder;
  let minimumAngle = last.shoulder;
  let maximumAngle = last.shoulder;
  for (let index = samples.length - 1; index > 0; index -= 1) {
    const sample = samples[index];
    const previous = samples[index - 1];
    const deltaMs = sample.timestamp - previous.timestamp;
    const continuous = sample.segment === previous.segment
      && deltaMs > 0
      && deltaMs <= policy.maxFrameGapMs;
    if (!continuous) break;
    const nextMinimum = Math.min(minimumAngle, previous.shoulder);
    const nextMaximum = Math.max(maximumAngle, previous.shoulder);
    if (nextMaximum - nextMinimum > policy.finishPlateauRangeDeg) break;
    minimumAngle = nextMinimum;
    maximumAngle = nextMaximum;
    startedAt = previous.timestamp;
    startAngle = previous.shoulder;
  }
  const duration = Math.max(0, last.timestamp - startedAt);
  if (!duration) return 0;
  const averageVelocity = Math.abs(last.shoulder - startAngle) / (duration / 1_000);
  return averageVelocity <= policy.finishPlateauMaxVelocityDegPerSec ? duration : 0;
}

export function createLateralArmRaiseSessionAnalyzer({
  exercise = {},
  policy = {},
  timestampNow = () => (globalThis.performance?.now ? globalThis.performance.now() : Date.now()),
  ...overrides
} = {}) {
  const resolvedPolicy = resolvePolicy(exercise, policy, overrides);
  let mode;
  let reps;
  let active;
  let lastTimestamp;
  let lastUsableTimestamp;
  let segment;
  let restSince;
  let postRestSince;
  let restSamples;
  let lastRestSample;
  let lastCompletedRepIndex;
  let totalFrames;
  let usableFrames;
  let rejectedFrames;
  let trackingLossStartedAt;
  let trackingLossExpired;
  let trackingLossEvents;
  let interruptedAttempts;
  let discardedAttempts;
  let finishedSummary;

  function reset() {
    mode = 'waiting_for_rest';
    reps = [];
    active = null;
    lastTimestamp = null;
    lastUsableTimestamp = null;
    segment = 0;
    restSince = null;
    postRestSince = null;
    restSamples = [];
    lastRestSample = null;
    lastCompletedRepIndex = null;
    totalFrames = 0;
    usableFrames = 0;
    rejectedFrames = 0;
    trackingLossStartedAt = null;
    trackingLossExpired = false;
    trackingLossEvents = 0;
    interruptedAttempts = 0;
    discardedAttempts = 0;
    finishedSummary = null;
  }

  function trimRestSamples(timestamp) {
    const cutoff = timestamp - resolvedPolicy.elbowBaselineWindowMs;
    restSamples = restSamples.filter((sample) => sample.timestamp >= cutoff);
  }

  function recordRestSample(sample) {
    lastRestSample = sample;
    restSamples.push(sample);
    trimRestSamples(sample.timestamp);
  }

  function restElbowBaseline() {
    const elbows = restSamples.map((sample) => sample.elbow).filter(Number.isFinite);
    return elbows.length >= resolvedPolicy.elbowBaselineMinSamples ? median(elbows) : null;
  }

  function beginAttempt(sample) {
    const baseline = lastRestSample || {
      ...sample,
      shoulder: resolvedPolicy.restThresholdDeg,
    };
    const baselineSample = {
      ...baseline,
      attemptTotalFrames: 1,
      attemptRejectedFrames: 0,
    };
    const movementSample = {
      ...sample,
      attemptTotalFrames: 2,
      attemptRejectedFrames: 0,
    };
    active = {
      samples: [baselineSample, movementSample],
      totalFrames: 2,
      rejectedFrames: 0,
      raisingStartedAt: sample.timestamp,
      peakAngle: Math.max(baselineSample.shoulder, movementSample.shoulder),
      peakIndex: movementSample.shoulder >= baselineSample.shoulder ? 1 : 0,
      targetSince: null,
      targetIndex: null,
      descent: null,
      returnRestSince: null,
      elbowBaselineDeg: restElbowBaseline(),
    };
    mode = 'raising';
    restSince = null;
  }

  function completedRep(activeAttempt, {
    targetReached,
    completion,
    completedAt,
    endIndex,
    returnedToRest = false,
    returnedAt = null,
  }) {
    const outboundSamples = activeAttempt.samples.slice(0, Math.max(0, endIndex) + 1);
    if (!outboundSamples.length) return null;
    const start = outboundSamples[0];
    const peakAngle = Math.max(...outboundSamples.map((sample) => sample.shoulder));
    const peakSample = outboundSamples.find((sample) => sample.shoulder === peakAngle) || outboundSamples.at(-1);
    if (peakAngle - start.shoulder < resolvedPolicy.minOutboundExcursionDeg) return null;
    const pauses = pauseMetrics(outboundSamples, resolvedPolicy);
    const elbow = elbowMetrics(outboundSamples, activeAttempt, resolvedPolicy);
    const upDownEventCount = countUpDownEvents(
      outboundSamples,
      resolvedPolicy.upDownMinExcursionDeg,
      resolvedPolicy.maxFrameGapMs,
    );
    const efficiency = pathEfficiency(outboundSamples);
    const endSample = outboundSamples.at(-1);
    const outboundTotalFrames = Number(endSample?.attemptTotalFrames) || outboundSamples.length;
    const outboundRejectedFrames = Number(endSample?.attemptRejectedFrames) || 0;
    const shoulderUsableRatio = outboundTotalFrames
      ? (outboundTotalFrames - outboundRejectedFrames) / outboundTotalFrames
      : 0;
    const inefficientPath = Number.isFinite(efficiency)
      ? efficiency < resolvedPolicy.inefficientPathThreshold
      : null;
    const issueCodes = [
      !targetReached ? 'target_not_reached' : null,
      upDownEventCount >= resolvedPolicy.frequentUpDownMinEvents ? 'frequent_up_down' : null,
      pauses.count > 0 ? 'mid_raise_pause' : null,
      elbow.affected === true ? 'excessive_elbow_bend' : null,
      inefficientPath === true ? 'inefficient_path' : null,
    ].filter(Boolean);
    return {
      index: reps.length + 1,
      valid: true,
      completion,
      targetReached: !!targetReached,
      startedAt: start.timestamp,
      raisingStartedAt: activeAttempt.raisingStartedAt,
      peakAt: peakSample.timestamp,
      completedAt,
      startAngleDeg: rounded(start.shoulder, resolvedPolicy.anglePrecisionDeg),
      peakAngleDeg: rounded(peakAngle, resolvedPolicy.anglePrecisionDeg),
      raisingDurationMs: Math.max(0, Math.round(peakSample.timestamp - activeAttempt.raisingStartedAt)),
      upDownEventCount,
      frequentUpDown: upDownEventCount >= resolvedPolicy.frequentUpDownMinEvents,
      pauseCount: pauses.count,
      pauseDurationMs: Math.round(pauses.durationMs),
      elbowAssessed: elbow.assessed,
      elbowBendDetected: elbow.detected,
      elbowBendAffected: elbow.affected,
      elbowBendDurationMs: elbow.durationMs,
      longestElbowBendMs: elbow.longestDurationMs,
      elbowThresholdDeg: elbow.thresholdDeg,
      elbowBaselineDeg: elbow.baselineDeg,
      pathEfficiency: roundedRatio(efficiency),
      inefficientPath,
      meetsPatientTargetRules: !!targetReached && elbow.affected !== true,
      hasTechniqueIssue: issueCodes.length > 0,
      issueCodes,
      returnedToRest,
      returnedAt,
      shoulderUsableRatio: roundedRatio(shoulderUsableRatio),
      elbowUsableRatio: elbow.usableRatio,
    };
  }

  function finalizeAttempt(options) {
    if (!active) return null;
    const rep = completedRep(active, options);
    if (rep) {
      reps.push(rep);
      lastCompletedRepIndex = reps.length - 1;
    } else {
      discardedAttempts += 1;
    }
    active = null;
    return rep;
  }

  function returnCompletedRepToRest(timestamp) {
    if (lastCompletedRepIndex == null || !reps[lastCompletedRepIndex]) return;
    reps[lastCompletedRepIndex] = {
      ...reps[lastCompletedRepIndex],
      returnedToRest: true,
      returnedAt: timestamp,
    };
  }

  function handleWaitingForRest(sample) {
    if (sample.shoulder > resolvedPolicy.restThresholdDeg) {
      restSince = null;
      return;
    }
    recordRestSample(sample);
    if (restSince == null) restSince = sample.timestamp;
    if (sample.timestamp - restSince >= resolvedPolicy.restHoldMs) mode = 'armed';
  }

  function handleArmed(sample) {
    if (sample.shoulder <= resolvedPolicy.restThresholdDeg) {
      recordRestSample(sample);
      return;
    }
    if (sample.shoulder >= resolvedPolicy.leaveRestThresholdDeg) beginAttempt(sample);
  }

  function handleWaitingForReset(sample) {
    if (sample.shoulder > resolvedPolicy.restThresholdDeg) {
      postRestSince = null;
      return;
    }
    recordRestSample(sample);
    if (postRestSince == null) postRestSince = sample.timestamp;
    if (sample.timestamp - postRestSince < resolvedPolicy.restHoldMs) return;
    returnCompletedRepToRest(sample.timestamp);
    postRestSince = null;
    restSince = sample.timestamp;
    mode = 'armed';
  }

  function handleRaising(sample) {
    active.totalFrames += 1;
    active.samples.push({
      ...sample,
      attemptTotalFrames: active.totalFrames,
      attemptRejectedFrames: active.rejectedFrames,
    });
    const index = active.samples.length - 1;
    if (sample.shoulder > active.peakAngle) {
      active.peakAngle = sample.shoulder;
      active.peakIndex = index;
      active.descent = null;
    }

    if (sample.shoulder <= resolvedPolicy.restThresholdDeg) {
      if (active.returnRestSince == null) active.returnRestSince = sample.timestamp;
      if (sample.timestamp - active.returnRestSince >= resolvedPolicy.restHoldMs) {
        finalizeAttempt({
          targetReached: false,
          completion: 'returned_to_rest',
          completedAt: sample.timestamp,
          endIndex: active.peakIndex,
          returnedToRest: true,
          returnedAt: sample.timestamp,
        });
        recordRestSample(sample);
        restSince = sample.timestamp;
        postRestSince = null;
        mode = 'armed';
      }
      return;
    }
    active.returnRestSince = null;

    if (sample.shoulder >= resolvedPolicy.targetThresholdDeg) {
      if (active.targetSince == null) {
        active.targetSince = sample.timestamp;
        active.targetIndex = index;
      }
      if (sample.timestamp - active.targetSince >= resolvedPolicy.targetHoldMs) {
        finalizeAttempt({
          targetReached: true,
          completion: 'target_hold',
          completedAt: sample.timestamp,
          endIndex: active.targetIndex,
        });
        postRestSince = null;
        mode = 'waiting_for_reset';
      }
      return;
    }
    active.targetSince = null;
    active.targetIndex = null;

    const drop = active.peakAngle - sample.shoulder;
    if (drop < resolvedPolicy.peakDropDeg) {
      active.descent = null;
      return;
    }
    if (!active.descent) {
      active.descent = {
        startedAt: sample.timestamp,
        troughAngle: sample.shoulder,
      };
      return;
    }
    active.descent.troughAngle = Math.min(active.descent.troughAngle, sample.shoulder);
    if (sample.shoulder - active.descent.troughAngle >= resolvedPolicy.upDownMinExcursionDeg) {
      active.descent = null;
      return;
    }
    if (sample.timestamp - active.descent.startedAt >= resolvedPolicy.peakConfirmMs) {
      finalizeAttempt({
        targetReached: false,
        completion: 'confirmed_peak',
        completedAt: sample.timestamp,
        endIndex: active.peakIndex,
      });
      postRestSince = sample.shoulder <= resolvedPolicy.restThresholdDeg ? sample.timestamp : null;
      mode = 'waiting_for_reset';
    }
  }

  function interruptActiveAttempt({ forceWaitingForRest = false } = {}) {
    if (active) interruptedAttempts += 1;
    active = null;
    restSince = null;
    postRestSince = null;
    if (forceWaitingForRest || mode !== 'waiting_for_reset') mode = 'waiting_for_rest';
  }

  function shiftHoldTimers(durationMs) {
    if (!(durationMs > 0)) return;
    if (restSince != null) restSince += durationMs;
    if (postRestSince != null) postRestSince += durationMs;
    if (!active) return;
    active.raisingStartedAt += durationMs;
    if (active.targetSince != null) active.targetSince += durationMs;
    if (active.returnRestSince != null) active.returnRestSince += durationMs;
    if (active.descent?.startedAt != null) active.descent.startedAt += durationMs;
  }

  function expireTrackingLoss() {
    if (trackingLossExpired) return;
    trackingLossExpired = true;
    segment += 1;
    interruptActiveAttempt({ forceWaitingForRest: true });
  }

  function handleRejectedFrame(timestamp, { hardReset = false } = {}) {
    if (active) {
      active.totalFrames += 1;
      active.rejectedFrames += 1;
    }
    if (hardReset) {
      trackingLossEvents += 1;
      trackingLossStartedAt = null;
      trackingLossExpired = false;
      segment += 1;
      interruptActiveAttempt({ forceWaitingForRest: true });
      return;
    }
    if (trackingLossStartedAt == null) {
      trackingLossStartedAt = timestamp;
      trackingLossExpired = false;
      trackingLossEvents += 1;
    }
    if (timestamp - trackingLossStartedAt > resolvedPolicy.trackingLossGraceMs) {
      expireTrackingLoss();
    }
  }

  function buildSummary({ patientCountedReps: patientCountedOverride = null } = {}) {
    const usableFrameRatio = totalFrames ? usableFrames / totalFrames : 0;
    const validReps = reps.length;
    const hasPatientCountOverride = finiteNumber(patientCountedOverride) != null;
    const runtimePatientCountedReps = hasPatientCountOverride
      ? Math.max(0, Math.round(Number(patientCountedOverride)))
      : null;
    // An accepted Patient rep is itself proof of an attempt. This protects the
    // displayed count if a WebKit frame was unavailable to the additive
    // analyzer while the native counter kept running.
    const totalAttempts = Math.max(reps.length, runtimePatientCountedReps ?? 0);
    const targetReachedReps = reps.filter((rep) => rep.targetReached).length;
    const frequentUpDownReps = reps.filter((rep) => rep.frequentUpDown).length;
    const repsWithUpDown = reps.filter((rep) => rep.upDownEventCount > 0).length;
    const upDownEvents = reps.reduce((sum, rep) => sum + rep.upDownEventCount, 0);
    const pausedReps = reps.filter((rep) => rep.pauseCount > 0).length;
    const pauseDurationMs = reps.reduce((sum, rep) => sum + rep.pauseDurationMs, 0);
    const elbowBendAffectedReps = reps.filter((rep) => rep.elbowBendAffected === true).length;
    const elbowAssessedReps = reps.filter((rep) => rep.elbowAssessed === true).length;
    const elbowBendDetectedReps = reps.filter((rep) => rep.elbowBendDetected === true).length;
    const elbowBendTotalMs = reps.reduce(
      (sum, rep) => sum + (Number.isFinite(rep.elbowBendDurationMs) ? rep.elbowBendDurationMs : 0),
      0,
    );
    const returnedToRestReps = reps.filter((rep) => rep.returnedToRest).length;
    const pathEfficiencyAssessedReps = reps.filter((rep) => Number.isFinite(rep.pathEfficiency)).length;
    const inefficientPathReps = reps.filter((rep) => rep.inefficientPath === true).length;
    const reconstructedPatientCountedReps = reps
      .filter((rep) => rep.meetsPatientTargetRules === true).length;
    const patientCountedReps = hasPatientCountOverride
      ? runtimePatientCountedReps
      : reconstructedPatientCountedReps;
    const notCountedAttempts = Math.max(0, totalAttempts - patientCountedReps);
    const techniqueIssueReps = reps.filter((rep) => rep.hasTechniqueIssue).length;
    const cleanTechniqueReps = Math.max(0, reps.length - techniqueIssueReps);
    const outboundUsableFrameRatio = median(reps.map((rep) => rep.shoulderUsableRatio));
    const scorable = reps.length
      ? reps.every((rep) => rep.shoulderUsableRatio >= resolvedPolicy.minSessionUsableRatio)
      : totalFrames > 0 && usableFrameRatio >= resolvedPolicy.minSessionUsableRatio;
    return {
      schemaVersion: resolvedPolicy.schemaVersion,
      policyVersion: resolvedPolicy.version,
      angleSpace: resolvedPolicy.angleSpace,
      clock: 'monotonic_ms',
      status: scorable ? 'scorable' : 'insufficient_data',
      totalAttempts,
      analyzedAttempts: reps.length,
      patientCountedReps,
      notCountedAttempts,
      patientCountSource: hasPatientCountOverride ? 'patient_runtime' : 'rule_reconstruction',
      techniqueIssueReps,
      cleanTechniqueReps,
      // Deprecated in v4: historically this meant analyzable attempts, not
      // correct repetitions. Keep it only in the detailed runtime snapshot so
      // older in-memory consumers do not break; compact persisted JSON uses
      // analyzedAttempts instead.
      validReps,
      targetReachedReps,
      frequentUpDownReps,
      repsWithUpDown,
      upDownEvents,
      pausedReps,
      pauseDurationMs,
      elbowBendAffectedReps,
      elbowAssessedReps,
      elbowBendDetectedReps,
      elbowBendTotalMs,
      returnedToRestReps,
      pathEfficiencyAssessedReps,
      inefficientPathReps,
      medianPathEfficiency: roundedRatio(median(reps.map((rep) => rep.pathEfficiency))),
      rules: {
        targetThresholdDeg: resolvedPolicy.targetThresholdDeg,
        targetHoldMs: resolvedPolicy.targetHoldMs,
        restThresholdDeg: resolvedPolicy.restThresholdDeg,
        restHoldMs: resolvedPolicy.restHoldMs,
        upDownMinExcursionDeg: resolvedPolicy.upDownMinExcursionDeg,
        inefficientPathThreshold: resolvedPolicy.inefficientPathThreshold,
        pauseMinMs: resolvedPolicy.pauseMinMs,
        elbowBendAffectedMinMs: resolvedPolicy.elbowBendAffectedMinMs,
      },
      dataQuality: {
        totalFrames,
        usableFrames,
        rejectedFrames,
        usableFrameRatio: roundedRatio(usableFrameRatio),
        outboundUsableFrameRatio: roundedRatio(outboundUsableFrameRatio),
        trackingLossEvents,
        interruptedAttempts,
        discardedAttempts,
      },
      reps: reps.map((rep) => ({ ...rep })),
    };
  }

  function getSnapshot() {
    const summary = buildSummary();
    return clone({
      ...summary,
      state: mode,
      activeAttempt: active ? {
        raisingStartedAt: active.raisingStartedAt,
        peakAngleDeg: rounded(active.peakAngle, resolvedPolicy.anglePrecisionDeg),
      } : null,
    });
  }

  function push({
    timestamp = timestampNow(),
    jointAngles = {},
    boundary = null,
    hasPose = true,
  } = {}) {
    if (finishedSummary) return clone(finishedSummary);
    const resolvedTimestamp = finiteNumber(timestamp) ?? finiteNumber(timestampNow()) ?? Date.now();
    totalFrames += 1;
    if (lastTimestamp != null && resolvedTimestamp <= lastTimestamp) {
      rejectedFrames += 1;
      handleRejectedFrame(resolvedTimestamp, { hardReset: true });
      return getSnapshot();
    }
    lastTimestamp = resolvedTimestamp;
    const shoulder = finiteNumber(jointAngles?.[resolvedPolicy.primaryJoint]);
    const elbow = finiteNumber(jointAngles?.[resolvedPolicy.elbowJoint]);
    if (hasPose === false || shoulder == null || !boundaryAllowsAnalysis(boundary, resolvedPolicy)) {
      rejectedFrames += 1;
      handleRejectedFrame(resolvedTimestamp);
      return getSnapshot();
    }

    const gapSinceUsable = lastUsableTimestamp == null
      ? 0
      : resolvedTimestamp - lastUsableTimestamp;
    if (trackingLossStartedAt != null) {
      if (trackingLossExpired || gapSinceUsable > resolvedPolicy.trackingLossGraceMs) {
        expireTrackingLoss();
      } else {
        // Keep the rep state through short visibility jitter, but exclude the
        // unseen time from rest/target holds and from continuous path metrics.
        segment += 1;
        shiftHoldTimers(gapSinceUsable);
      }
      trackingLossStartedAt = null;
      trackingLossExpired = false;
    } else if (gapSinceUsable > resolvedPolicy.maxFrameGapMs) {
      segment += 1;
      if (gapSinceUsable > resolvedPolicy.trackingLossGraceMs) {
        interruptActiveAttempt({ forceWaitingForRest: true });
      } else {
        shiftHoldTimers(gapSinceUsable);
      }
    }
    lastUsableTimestamp = resolvedTimestamp;
    usableFrames += 1;
    const sample = {
      timestamp: resolvedTimestamp,
      shoulder,
      elbow,
      segment,
    };

    if (mode === 'waiting_for_rest') handleWaitingForRest(sample);
    else if (mode === 'armed') handleArmed(sample);
    else if (mode === 'raising') handleRaising(sample);
    else if (mode === 'waiting_for_reset') handleWaitingForReset(sample);
    return getSnapshot();
  }

  function finish({ patientCountedReps = null } = {}) {
    if (finishedSummary) return clone(finishedSummary);
    if (active) {
      const lastIndex = active.samples.length - 1;
      const last = active.samples[lastIndex];
      const descendedFromPeak = active.peakAngle - last.shoulder >= resolvedPolicy.peakDropDeg;
      const plateauConfirmed = terminalPlateauDuration(active.samples, resolvedPolicy)
        >= resolvedPolicy.finishPlateauMinMs;
      if (descendedFromPeak || plateauConfirmed) {
        finalizeAttempt({
          targetReached: false,
          completion: descendedFromPeak ? 'session_end_peak' : 'session_end_plateau',
          completedAt: last.timestamp,
          endIndex: descendedFromPeak ? active.peakIndex : lastIndex,
        });
      } else {
        discardedAttempts += 1;
        active = null;
      }
    }
    finishedSummary = buildSummary({ patientCountedReps });
    return clone(finishedSummary);
  }

  reset();
  return {
    push,
    finish,
    getSnapshot,
    interrupt: interruptActiveAttempt,
    reset,
    policy: resolvedPolicy,
  };
}
