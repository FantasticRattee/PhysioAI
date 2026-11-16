import {
  isCorrectDynamicWeightShiftClass,
  isWrongDynamicWeightShiftClass,
} from './DynamicWeightShiftContract.js';

export const HYBRID_TARGET_STATES = Object.freeze({
  WAITING_REST: 'waiting_rest',
  REST: 'rest',
  MOVING: 'moving_to_target',
  TARGET_CANDIDATE: 'target_candidate',
  TARGET_REACHED: 'target_reached',
  BLOCKED: 'blocked',
});

export const DEFAULT_HYBRID_TARGET_THRESHOLDS = Object.freeze({
  minAiConfidence: 0.75,
  targetHoldMs: 350,
  fallbackHoldMs: 600,
  disagreementHoldMs: 800,
  restHoldMs: 180,
  hysteresisDeg: 5,
  anglePrecisionDeg: 0.1,
  targetStabilityToleranceDeg: null,
  requireAiConfirmation: false,
});

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function finiteNumber(value, fallback = null) {
  const number = Number(value);
  return Number.isFinite(number) ? number : fallback;
}

function median(values = []) {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!sorted.length) return null;
  const middle = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
}

function trimTimedSamples(samples, now, windowMs) {
  if (!Array.isArray(samples)) return;
  if (!Number.isFinite(windowMs) || windowMs <= 0) {
    if (samples.length > 1) samples.splice(0, samples.length - 1);
    return;
  }
  const cutoff = now - windowMs;
  while (samples.length > 1 && samples[0].at < cutoff) samples.shift();
}

function quantizeAngle(value, precision = DEFAULT_HYBRID_TARGET_THRESHOLDS.anglePrecisionDeg) {
  const angle = finiteNumber(value);
  const step = finiteNumber(precision);
  if (angle == null || step == null || step <= 0) return angle;
  return Math.round(angle / step) * step;
}

function safetyReason(boundary = null) {
  if (!boundary) return 'missing_boundary_status';
  if (boundary.scoreable === false || boundary.ok === false || boundary.status === 'outside') {
    return boundary.dataQuality || boundary.readinessStatus || boundary.status || 'not_scoreable';
  }
  if (boundary.status && boundary.status !== 'inside') {
    return boundary.dataQuality || boundary.readinessStatus || boundary.status;
  }
  return null;
}

function policyThreshold(policy = {}, exercise = {}) {
  if (policy.comparator === 'lte') {
    return finiteNumber(
      policy.reachedTargetMaxDeg ?? policy.maxDeg ?? policy.threshold,
      finiteNumber(exercise.target),
    );
  }
  return finiteNumber(
    policy.reachedTargetMinDeg ?? policy.minDeg ?? policy.threshold,
    finiteNumber(exercise.target),
  );
}

function requiredRuleThreshold(rule = {}) {
  if (rule.comparator === 'lte') {
    return finiteNumber(rule.reachedTargetMaxDeg ?? rule.maxDeg ?? rule.threshold);
  }
  return finiteNumber(rule.reachedTargetMinDeg ?? rule.minDeg ?? rule.threshold);
}

function enforcementPhases(rule = {}) {
  const configured = Array.isArray(rule.enforceDuringPhases)
    ? rule.enforceDuringPhases
    : Array.isArray(rule.enforceDuring)
      ? rule.enforceDuring
      : [];
  return [...new Set(configured.map((phase) => String(phase || '').trim()).filter(Boolean))];
}

function resolvedRule(rule = {}, { joint, comparator, targetThreshold, primary = false } = {}) {
  const hardThreshold = comparator === 'lte'
    ? finiteNumber(rule.hardMaxDeg ?? rule.hardThreshold)
    : finiteNumber(rule.hardMinDeg ?? rule.hardThreshold);
  return {
    joint,
    comparator,
    targetThreshold,
    primary,
    enforceDuringPhases: enforcementPhases(rule),
    violationGraceMs: Math.max(0, finiteNumber(rule.violationGraceMs, 0)),
    smoothingWindowMs: Math.max(0, finiteNumber(rule.smoothingWindowMs, 0)),
    restBaselineWindowMs: Math.max(0, finiteNumber(rule.restBaselineWindowMs, 0)),
    restBaselineMinSamples: Math.max(1, Math.round(finiteNumber(rule.restBaselineMinSamples, 1))),
    maxDeviationFromRestDeg: Math.max(0, finiteNumber(rule.maxDeviationFromRestDeg, 0)) || null,
    adaptiveThresholdMinDeg: finiteNumber(rule.adaptiveThresholdMinDeg),
    adaptiveThresholdMaxDeg: finiteNumber(rule.adaptiveThresholdMaxDeg),
    violationWindowMs: Math.max(0, finiteNumber(rule.violationWindowMs, 0)),
    maxViolationRatio: clamp(finiteNumber(rule.maxViolationRatio, 1), 0, 1),
    hardThreshold,
    hardViolationGraceMs: Math.max(0, finiteNumber(rule.hardViolationGraceMs, 0)),
  };
}

function resolveTargetRules(exercise = {}, overrides = {}) {
  const policy = exercise.targetOutcomePolicy || {};
  const primaryComparator = policy.comparator === 'lte'
    ? 'lte'
    : policy.comparator === 'gt' ? 'gt' : 'gte';
  const primary = resolvedRule(policy, {
    joint: overrides.targetJoint || policy.joint || exercise.primaryJoint || exercise.dominantJoint || null,
    comparator: primaryComparator,
    targetThreshold: finiteNumber(overrides.targetThreshold, policyThreshold(policy, exercise)),
    primary: true,
  });
  const configuredRequiredRules = Array.isArray(overrides.requiredJointRules)
    ? overrides.requiredJointRules
    : Array.isArray(policy.requiredJointRules)
      ? policy.requiredJointRules
      : [];
  const seen = new Set(primary.joint ? [primary.joint] : []);
  const requiredRules = configuredRequiredRules.flatMap((rule = {}) => {
    const joint = rule.joint || null;
    if (!joint || seen.has(joint)) return [];
    seen.add(joint);
    return [resolvedRule(rule, {
      joint,
      comparator: rule.comparator === 'lte' ? 'lte' : 'gte',
      targetThreshold: requiredRuleThreshold(rule),
      primary: false,
    })];
  });
  return [primary, ...requiredRules];
}

function passesComparator(angle, threshold, comparator) {
  if (!Number.isFinite(angle) || !Number.isFinite(threshold)) return false;
  if (comparator === 'lte') return angle <= threshold;
  return comparator === 'gt' ? angle > threshold : angle >= threshold;
}

function adaptiveThresholdFor(rule, baselineAngle, precision) {
  if (!Number.isFinite(baselineAngle) || !Number.isFinite(rule.maxDeviationFromRestDeg)) {
    return rule.targetThreshold;
  }
  const candidate = rule.comparator === 'lte'
    ? baselineAngle + rule.maxDeviationFromRestDeg
    : baselineAngle - rule.maxDeviationFromRestDeg;
  const minimum = finiteNumber(rule.adaptiveThresholdMinDeg, -Infinity);
  const maximum = finiteNumber(rule.adaptiveThresholdMaxDeg, Infinity);
  return quantizeAngle(clamp(candidate, minimum, maximum), precision);
}

function restThresholdFor({ exercise, policy, threshold, comparator, hysteresisDeg }) {
  const explicit = finiteNumber(policy.restResetDeg ?? policy.restResetMaxDeg ?? policy.restResetMinDeg);
  if (explicit != null) return explicit;
  const rest = finiteNumber(exercise.rest);
  if (rest == null) return comparator === 'lte' ? threshold + hysteresisDeg * 2 : threshold - hysteresisDeg * 2;
  const distance = Math.abs(threshold - rest);
  const offset = Math.max(8, distance * 0.35);
  if (comparator === 'lte') return Math.max(threshold + hysteresisDeg, rest - offset);
  return Math.min(threshold - hysteresisDeg, rest + offset);
}

function isAtRest(angle, resetThreshold, comparator) {
  if (!Number.isFinite(angle)) return false;
  return comparator === 'lte' ? angle >= resetThreshold : angle <= resetThreshold;
}

function motionProgress(angle, resetThreshold, targetThreshold, comparator) {
  if (![angle, resetThreshold, targetThreshold].every(Number.isFinite)) return 0;
  const span = Math.max(1, Math.abs(targetThreshold - resetThreshold));
  const travelled = comparator === 'lte'
    ? resetThreshold - angle
    : angle - resetThreshold;
  return clamp(travelled / span, 0, 1);
}

export function resolveHybridTargetConfig(exercise = {}, overrides = {}) {
  const policy = exercise.targetOutcomePolicy || {};
  const targetRules = resolveTargetRules(exercise, overrides);
  const primaryRule = targetRules[0];
  const comparator = primaryRule.comparator;
  const hysteresisDeg = finiteNumber(overrides.hysteresisDeg, DEFAULT_HYBRID_TARGET_THRESHOLDS.hysteresisDeg);
  const targetThreshold = primaryRule.targetThreshold;
  const targetJoint = primaryRule.joint;
  const resetThreshold = finiteNumber(
    overrides.resetThreshold,
    restThresholdFor({ exercise, policy, threshold: targetThreshold, comparator, hysteresisDeg }),
  );

  return {
    decisionMode: overrides.decisionMode === 'rule' ? 'rule' : 'hybrid',
    targetJoint,
    comparator,
    targetThreshold,
    targetRules,
    requiredJointRules: targetRules.slice(1),
    movementJointRules: targetRules.filter((rule) => rule.enforceDuringPhases.includes('moving_to_target')),
    resetThreshold,
    minAiConfidence: finiteNumber(overrides.minAiConfidence, DEFAULT_HYBRID_TARGET_THRESHOLDS.minAiConfidence),
    targetHoldMs: finiteNumber(overrides.targetHoldMs, DEFAULT_HYBRID_TARGET_THRESHOLDS.targetHoldMs),
    fallbackHoldMs: finiteNumber(overrides.fallbackHoldMs, DEFAULT_HYBRID_TARGET_THRESHOLDS.fallbackHoldMs),
    disagreementHoldMs: finiteNumber(overrides.disagreementHoldMs, DEFAULT_HYBRID_TARGET_THRESHOLDS.disagreementHoldMs),
    restHoldMs: finiteNumber(overrides.restHoldMs, DEFAULT_HYBRID_TARGET_THRESHOLDS.restHoldMs),
    hysteresisDeg,
    anglePrecisionDeg: finiteNumber(overrides.anglePrecisionDeg, DEFAULT_HYBRID_TARGET_THRESHOLDS.anglePrecisionDeg),
    targetStabilityToleranceDeg: Math.max(0, finiteNumber(overrides.targetStabilityToleranceDeg, 0)) || null,
    requireAiConfirmation: overrides.requireAiConfirmation === true,
  };
}

export function createHybridTargetDecisionEngine({
  exercise = {},
  ...overrides
} = {}) {
  const config = resolveHybridTargetConfig(exercise, overrides);
  let state = HYBRID_TARGET_STATES.WAITING_REST;
  let reps = 0;
  let armed = false;
  let restSince = null;
  let targetSince = null;
  let targetAnchorAngle = null;
  let latchedSource = null;
  let lastTimestamp = null;
  let ruleSignalState = new Map();
  let movementRuleState = new Map();

  function resetRuleSignals() {
    ruleSignalState = new Map(config.targetRules.map((rule) => [rule.joint, {
      joint: rule.joint,
      phase: null,
      smoothingSamples: [],
      restSamples: [],
      rawAngle: null,
      filteredAngle: null,
      baselineAngle: null,
      threshold: rule.targetThreshold,
    }]));
  }

  function updateRuleSignals(now, rawAngles, atRest) {
    const signalPhase = atRest ? 'rest' : 'active';
    return config.targetRules.map((rule) => {
      const tracked = ruleSignalState.get(rule.joint);
      const rawAngle = rawAngles.get(rule.joint);
      if (!tracked || !Number.isFinite(rawAngle)) {
        return {
          joint: rule.joint,
          rawAngle,
          angle: rawAngle,
          comparator: rule.comparator,
          threshold: rule.targetThreshold,
          staticThreshold: rule.targetThreshold,
          baselineAngle: null,
          deviationFromBaselineDeg: null,
          passed: false,
          hardThreshold: rule.hardThreshold,
          hardPassed: false,
          primary: rule.primary === true,
        };
      }

      if (tracked.phase !== signalPhase) {
        tracked.phase = signalPhase;
        tracked.smoothingSamples = [];
      }
      tracked.rawAngle = rawAngle;
      tracked.smoothingSamples.push({ at: now, value: rawAngle });
      trimTimedSamples(tracked.smoothingSamples, now, rule.smoothingWindowMs);
      tracked.filteredAngle = quantizeAngle(
        median(tracked.smoothingSamples.map((sample) => sample.value)),
        config.anglePrecisionDeg,
      );

      if (atRest && Number.isFinite(rule.maxDeviationFromRestDeg)) {
        tracked.restSamples.push({ at: now, value: rawAngle });
        trimTimedSamples(tracked.restSamples, now, rule.restBaselineWindowMs);
        if (tracked.restSamples.length >= rule.restBaselineMinSamples) {
          tracked.baselineAngle = quantizeAngle(
            median(tracked.restSamples.map((sample) => sample.value)),
            config.anglePrecisionDeg,
          );
        }
      }

      tracked.threshold = adaptiveThresholdFor(rule, tracked.baselineAngle, config.anglePrecisionDeg);
      const deviationFromBaselineDeg = Number.isFinite(tracked.baselineAngle)
        ? quantizeAngle(
            rule.comparator === 'lte'
              ? tracked.filteredAngle - tracked.baselineAngle
              : tracked.baselineAngle - tracked.filteredAngle,
            config.anglePrecisionDeg,
          )
        : null;
      const hardPassed = !Number.isFinite(rule.hardThreshold)
        || passesComparator(tracked.filteredAngle, rule.hardThreshold, rule.comparator);
      return {
        joint: rule.joint,
        rawAngle,
        angle: tracked.filteredAngle,
        comparator: rule.comparator,
        threshold: tracked.threshold,
        staticThreshold: rule.targetThreshold,
        baselineAngle: tracked.baselineAngle,
        deviationFromBaselineDeg,
        passed: passesComparator(tracked.filteredAngle, tracked.threshold, rule.comparator),
        hardThreshold: rule.hardThreshold,
        hardPassed,
        primary: rule.primary === true,
      };
    });
  }

  function rawRuleResults(rawAngles) {
    return config.targetRules.map((rule) => {
      const rawAngle = rawAngles.get(rule.joint);
      return {
        joint: rule.joint,
        rawAngle,
        angle: rawAngle,
        comparator: rule.comparator,
        threshold: rule.targetThreshold,
        staticThreshold: rule.targetThreshold,
        baselineAngle: null,
        deviationFromBaselineDeg: null,
        passed: passesComparator(rawAngle, rule.targetThreshold, rule.comparator),
        hardThreshold: rule.hardThreshold,
        hardPassed: !Number.isFinite(rule.hardThreshold)
          || passesComparator(rawAngle, rule.hardThreshold, rule.comparator),
        primary: rule.primary === true,
      };
    });
  }

  function resetMovementRules() {
    movementRuleState = new Map(config.movementJointRules.map((rule) => [rule.joint, {
      joint: rule.joint,
      comparator: rule.comparator,
      threshold: rule.targetThreshold,
      violationGraceMs: rule.violationGraceMs,
      violationWindowMs: rule.violationWindowMs,
      maxViolationRatio: rule.maxViolationRatio,
      hardThreshold: rule.hardThreshold,
      hardViolationGraceMs: rule.hardViolationGraceMs,
      observedFrames: 0,
      passedFrames: 0,
      violationFrames: 0,
      lastAngle: null,
      lastRawAngle: null,
      baselineAngle: null,
      currentPassed: true,
      worstAngle: null,
      violationSince: null,
      longestViolationMs: 0,
      violationSamples: [],
      violationRatio: 0,
      movementStartedAt: null,
      hardViolationSince: null,
      longestHardViolationMs: 0,
      failed: false,
      failedAt: null,
      failureKind: null,
    }]));
  }

  function updateMovementRules(now, ruleResults) {
    for (const rule of config.movementJointRules) {
      const result = ruleResults.find((candidate) => candidate.joint === rule.joint);
      const tracked = movementRuleState.get(rule.joint);
      if (!tracked || !result) continue;
      tracked.movementStartedAt ??= now;
      tracked.observedFrames += 1;
      tracked.lastAngle = result.angle;
      tracked.lastRawAngle = result.rawAngle;
      tracked.baselineAngle = result.baselineAngle;
      tracked.threshold = result.threshold;
      tracked.currentPassed = result.passed === true;
      tracked.worstAngle = tracked.worstAngle == null
        ? result.angle
        : rule.comparator === 'lte'
          ? Math.max(tracked.worstAngle, result.angle)
          : Math.min(tracked.worstAngle, result.angle);
      if (result.passed) {
        tracked.passedFrames += 1;
        tracked.violationSince = null;
      } else {
        tracked.violationFrames += 1;
        tracked.violationSince ??= now;
        const violationElapsedMs = Math.max(0, now - tracked.violationSince);
        tracked.longestViolationMs = Math.max(tracked.longestViolationMs, violationElapsedMs);
      }

      if (rule.violationWindowMs > 0) {
        tracked.violationSamples.push({ at: now, failed: result.passed !== true });
        trimTimedSamples(tracked.violationSamples, now, rule.violationWindowMs);
        const failedSamples = tracked.violationSamples.filter((sample) => sample.failed).length;
        tracked.violationRatio = tracked.violationSamples.length
          ? failedSamples / tracked.violationSamples.length
          : 0;
        const observedMs = Math.max(0, now - tracked.movementStartedAt);
        if (observedMs >= tracked.violationGraceMs && tracked.violationRatio > rule.maxViolationRatio) {
          tracked.failed = true;
          tracked.failedAt ??= now;
          tracked.failureKind ??= 'rolling_violation_ratio';
        }
      } else if (!result.passed) {
        const violationElapsedMs = Math.max(0, now - tracked.violationSince);
        if (violationElapsedMs >= tracked.violationGraceMs) {
          tracked.failed = true;
          tracked.failedAt ??= now;
          tracked.failureKind ??= 'continuous_violation';
        }
      }

      if (result.hardPassed === false && Number.isFinite(rule.hardThreshold)) {
        tracked.hardViolationSince ??= now;
        const hardViolationElapsedMs = Math.max(0, now - tracked.hardViolationSince);
        tracked.longestHardViolationMs = Math.max(tracked.longestHardViolationMs, hardViolationElapsedMs);
        if (hardViolationElapsedMs >= rule.hardViolationGraceMs) {
          tracked.failed = true;
          tracked.failedAt ??= now;
          tracked.failureKind ??= 'hard_threshold';
        }
      } else {
        tracked.hardViolationSince = null;
      }
    }
  }

  function movementRuleResults(now = lastTimestamp) {
    return config.movementJointRules.map((rule) => {
      const tracked = movementRuleState.get(rule.joint);
      const violationElapsedMs = tracked?.violationSince == null
        ? 0
        : Math.max(0, finiteNumber(now, tracked.violationSince) - tracked.violationSince);
      const hardViolationElapsedMs = tracked?.hardViolationSince == null
        ? 0
        : Math.max(0, finiteNumber(now, tracked.hardViolationSince) - tracked.hardViolationSince);
      return {
        joint: rule.joint,
        angle: tracked?.lastAngle ?? null,
        rawAngle: tracked?.lastRawAngle ?? null,
        baselineAngle: tracked?.baselineAngle ?? null,
        comparator: rule.comparator,
        threshold: tracked?.threshold ?? rule.targetThreshold,
        staticThreshold: rule.targetThreshold,
        currentPassed: tracked?.currentPassed !== false,
        passed: tracked?.failed !== true,
        failed: tracked?.failed === true,
        failureKind: tracked?.failureKind ?? null,
        violationGraceMs: rule.violationGraceMs,
        violationWindowMs: rule.violationWindowMs,
        maxViolationRatio: rule.maxViolationRatio,
        violationRatio: tracked?.violationRatio || 0,
        violationElapsedMs,
        longestViolationMs: Math.max(tracked?.longestViolationMs || 0, violationElapsedMs),
        hardThreshold: rule.hardThreshold,
        hardViolationGraceMs: rule.hardViolationGraceMs,
        hardViolationElapsedMs,
        longestHardViolationMs: Math.max(tracked?.longestHardViolationMs || 0, hardViolationElapsedMs),
        observedFrames: tracked?.observedFrames || 0,
        passedFrames: tracked?.passedFrames || 0,
        violationFrames: tracked?.violationFrames || 0,
        worstAngle: tracked?.worstAngle ?? null,
      };
    });
  }

  resetRuleSignals();
  resetMovementRules();

  function resetCurrent() {
    state = HYBRID_TARGET_STATES.WAITING_REST;
    armed = false;
    restSince = null;
    targetSince = null;
    targetAnchorAngle = null;
    latchedSource = null;
    resetRuleSignals();
    resetMovementRules();
  }

  function snapshot({
    angle = null,
    ruleResults = null,
    aiSignal = null,
    aiStatus = null,
    reason = 'waiting_for_rest',
    source = null,
    completedRep = null,
    rulePassed = false,
    holdElapsedMs = 0,
    requiredHoldMs = 0,
    targetPositionDeltaDeg = null,
    scoreable = true,
  } = {}) {
    const resolvedRuleResults = Array.isArray(ruleResults)
      ? ruleResults
      : config.targetRules.map((rule) => ({
          joint: rule.joint,
          angle: rule.joint === config.targetJoint ? angle : null,
          comparator: rule.comparator,
          threshold: rule.targetThreshold,
          passed: false,
          primary: rule.primary === true,
        }));
    const primaryResult = resolvedRuleResults[0] || null;
    const failedTargetJoints = resolvedRuleResults
      .filter((rule) => rule.passed !== true)
      .map((rule) => rule.joint)
      .filter(Boolean);
    const targetAngles = Object.fromEntries(resolvedRuleResults
      .filter((rule) => rule.joint)
      .map((rule) => [rule.joint, rule.angle]));
    const targetRawAngles = Object.fromEntries(resolvedRuleResults
      .filter((rule) => rule.joint)
      .map((rule) => [rule.joint, rule.rawAngle ?? rule.angle]));
    const primaryAngle = primaryResult?.angle ?? angle;
    const resolvedMovementRuleResults = movementRuleResults();
    const failedMovementJoints = resolvedMovementRuleResults
      .filter((rule) => rule.failed)
      .map((rule) => rule.joint);
    const currentMovementFailedJoints = resolvedMovementRuleResults
      .filter((rule) => rule.currentPassed === false)
      .map((rule) => rule.joint);
    const progress = motionProgress(primaryAngle, config.resetThreshold, config.targetThreshold, config.comparator);
    const reached = state === HYBRID_TARGET_STATES.TARGET_REACHED;
    return {
      state,
      phase: state === HYBRID_TARGET_STATES.REST || state === HYBRID_TARGET_STATES.WAITING_REST
        ? 'rest'
        : state === HYBRID_TARGET_STATES.MOVING
          ? 'moving_to_target'
          : 'target',
      outcome: reached ? 'reached_target' : 'not_reached_target',
      reason,
      source: source || latchedSource,
      scoreable,
      reps,
      completedRep,
      armed,
      targetJoint: config.targetJoint,
      targetAngle: primaryAngle,
      targetThreshold: config.targetThreshold,
      targetAngles,
      targetRawAngles,
      targetRules: resolvedRuleResults,
      failedTargetJoints,
      movementRulePassed: failedMovementJoints.length === 0,
      movementRuleResults: resolvedMovementRuleResults,
      failedMovementJoints,
      currentMovementFailedJoints,
      resetThreshold: config.resetThreshold,
      comparator: config.comparator,
      decisionMode: config.decisionMode,
      rulePassed,
      progressPct: Math.round(progress * 100),
      holdElapsedMs: Math.max(0, Math.round(holdElapsedMs)),
      requiredHoldMs: Math.max(0, Math.round(requiredHoldMs)),
      holdProgress: requiredHoldMs > 0 ? clamp(holdElapsedMs / requiredHoldMs, 0, 1) : 0,
      targetAnchorAngle,
      targetPositionDeltaDeg,
      targetStabilityToleranceDeg: config.targetStabilityToleranceDeg,
      targetPositionStable: !Number.isFinite(config.targetStabilityToleranceDeg)
        || !Number.isFinite(targetPositionDeltaDeg)
        || targetPositionDeltaDeg <= config.targetStabilityToleranceDeg,
      aiSignal,
      aiStatus,
    };
  }

  function push({
    timestamp = Date.now(),
    jointAngles = {},
    boundary = null,
    aiSignal = null,
    aiStatus = null,
  } = {}) {
    const requestedTimestamp = finiteNumber(timestamp, Date.now());
    lastTimestamp = lastTimestamp == null
      ? requestedTimestamp
      : Math.max(lastTimestamp, requestedTimestamp);
    const now = lastTimestamp;
    const invalidRule = config.targetRules.find((rule) => !rule.joint || !Number.isFinite(rule.targetThreshold));
    const rawAngles = new Map(config.targetRules.map((rule) => [
      rule.joint,
      quantizeAngle(jointAngles?.[rule.joint], config.anglePrecisionDeg),
    ]));
    const immediateRuleResults = rawRuleResults(rawAngles);
    const rawPrimaryAngle = immediateRuleResults[0]?.rawAngle ?? null;
    const missingRule = immediateRuleResults.find((rule) => !Number.isFinite(rule.rawAngle));
    const blockedReason = safetyReason(boundary) || (missingRule
      ? missingRule.primary ? 'missing_target_angle' : 'missing_required_target_angle'
      : null);
    if (invalidRule) {
      resetCurrent();
      state = HYBRID_TARGET_STATES.BLOCKED;
      return snapshot({
        angle: rawPrimaryAngle,
        ruleResults: immediateRuleResults,
        aiSignal,
        aiStatus,
        reason: 'missing_target_rule',
        scoreable: false,
      });
    }
    if (blockedReason) {
      resetCurrent();
      state = HYBRID_TARGET_STATES.BLOCKED;
      return snapshot({
        angle: rawPrimaryAngle,
        ruleResults: immediateRuleResults,
        aiSignal,
        aiStatus,
        reason: blockedReason,
        scoreable: false,
      });
    }

    const atRest = isAtRest(rawPrimaryAngle, config.resetThreshold, config.comparator);
    const ruleResults = updateRuleSignals(now, rawAngles, atRest);
    const primaryResult = ruleResults[0] || null;
    const angle = primaryResult?.angle ?? rawPrimaryAngle;
    const rulePassed = ruleResults.every((rule) => rule.passed);

    if (!armed) {
      targetSince = null;
      targetAnchorAngle = null;
      if (atRest) {
        restSince ??= now;
        if (now - restSince >= config.restHoldMs) {
          resetMovementRules();
          armed = true;
          state = HYBRID_TARGET_STATES.REST;
          latchedSource = null;
          return snapshot({ angle, ruleResults, aiSignal, aiStatus, reason: 'ready_to_move', rulePassed });
        }
        state = state === HYBRID_TARGET_STATES.TARGET_REACHED
          ? HYBRID_TARGET_STATES.TARGET_REACHED
          : HYBRID_TARGET_STATES.WAITING_REST;
      } else {
        restSince = null;
      }
      return snapshot({
        angle,
        ruleResults,
        aiSignal,
        aiStatus,
        reason: state === HYBRID_TARGET_STATES.TARGET_REACHED ? 'return_to_rest' : 'waiting_for_rest',
        source: latchedSource,
        rulePassed,
      });
    }

    if (atRest) {
      state = HYBRID_TARGET_STATES.REST;
      targetSince = null;
      targetAnchorAngle = null;
      resetMovementRules();
      return snapshot({ angle, ruleResults, aiSignal, aiStatus, reason: 'ready_to_move', rulePassed });
    }

    updateMovementRules(now, ruleResults);
    const activeMovementRules = movementRuleResults(now);
    const failedMovementRules = activeMovementRules.filter((rule) => rule.failed);
    const pendingMovementRules = activeMovementRules.filter((rule) => rule.currentPassed === false && !rule.failed);
    const movementRulePassed = failedMovementRules.length === 0;

    if (!movementRulePassed) {
      state = HYBRID_TARGET_STATES.MOVING;
      targetSince = null;
      targetAnchorAngle = null;
      return snapshot({
        angle,
        ruleResults,
        aiSignal,
        aiStatus,
        reason: 'movement_joint_rule_failed',
        rulePassed: false,
      });
    }

    if (!rulePassed) {
      state = HYBRID_TARGET_STATES.MOVING;
      targetSince = null;
      targetAnchorAngle = null;
      const primaryPassed = primaryResult?.passed === true;
      return snapshot({
        angle,
        ruleResults,
        aiSignal,
        aiStatus,
        reason: pendingMovementRules.length
          ? 'movement_joint_rule_pending'
          : primaryPassed ? 'required_target_angle_not_reached' : 'below_target_angle',
        rulePassed,
      });
    }

    state = HYBRID_TARGET_STATES.TARGET_CANDIDATE;
    let targetPositionDeltaDeg = Number.isFinite(targetAnchorAngle)
      ? Math.abs(angle - targetAnchorAngle)
      : 0;
    const targetPositionChanged = Number.isFinite(config.targetStabilityToleranceDeg)
      && Number.isFinite(targetAnchorAngle)
      && targetPositionDeltaDeg > config.targetStabilityToleranceDeg;
    if (targetSince == null || !Number.isFinite(targetAnchorAngle) || targetPositionChanged) {
      targetSince = now;
      targetAnchorAngle = angle;
    }
    const ruleOnly = config.decisionMode === 'rule';
    const aiConfidence = finiteNumber(aiSignal?.confidence, 0);
    const aiAtTarget = !ruleOnly && aiSignal?.phase === 'target';
    const aiConfirms = aiAtTarget && (
      aiSignal?.quality === 'reached_target' || isCorrectDynamicWeightShiftClass(aiSignal?.quality)
    ) && aiConfidence >= config.minAiConfidence;
    const aiDisagrees = !ruleOnly && !!aiSignal && (
      !aiAtTarget || aiSignal.quality === 'not_reached_target' || isWrongDynamicWeightShiftClass(aiSignal?.quality)
    ) && aiConfidence >= config.minAiConfidence;
    const requiredHoldMs = ruleOnly
      ? config.fallbackHoldMs
      : aiConfirms
      ? config.targetHoldMs
      : aiDisagrees
        ? config.disagreementHoldMs
        : config.fallbackHoldMs;
    const holdElapsedMs = now - targetSince;
    const source = ruleOnly ? 'rule_only' : aiConfirms ? 'ai_rule' : 'rule_fallback';
    const waitingReason = targetPositionChanged
      ? 'target_position_changed'
      : ruleOnly
      ? 'confirming_rule_only'
      : aiConfirms
      ? 'confirming_ai_and_rule'
      : config.requireAiConfirmation
        ? aiDisagrees
          ? 'ai_disagrees_waiting_confirmation'
          : 'waiting_for_ai_confirmation'
        : aiDisagrees
          ? 'ai_disagrees_waiting_rule'
          : 'waiting_rule_fallback';

    if (!ruleOnly && config.requireAiConfirmation && !aiConfirms) {
      // Require a fresh continuous correct confirmation. Time spent in a
      // wrong/unknown AI state must not count toward the correct hold.
      targetSince = null;
      targetAnchorAngle = null;
      return snapshot({
        angle,
        ruleResults,
        aiSignal,
        aiStatus,
        reason: waitingReason,
        source: 'ai_rule',
        rulePassed,
        holdElapsedMs: 0,
        requiredHoldMs: config.targetHoldMs,
        targetPositionDeltaDeg,
      });
    }

    if (holdElapsedMs < requiredHoldMs) {
      return snapshot({
        angle,
        ruleResults,
        aiSignal,
        aiStatus,
        reason: waitingReason,
        source,
        rulePassed,
        holdElapsedMs,
        requiredHoldMs,
        targetPositionDeltaDeg,
      });
    }

    const completedAnchorAngle = targetAnchorAngle;
    reps += 1;
    armed = false;
    restSince = null;
    targetSince = null;
    targetAnchorAngle = null;
    latchedSource = source;
    state = HYBRID_TARGET_STATES.TARGET_REACHED;
    const completedRep = {
      index: reps,
      endedAt: now,
      quality: 'reached_target',
      source,
      targetAngle: angle,
      targetAnchorAngle: completedAnchorAngle,
      targetAngles: Object.fromEntries(ruleResults.map((rule) => [rule.joint, rule.angle])),
      targetRawAngles: Object.fromEntries(ruleResults.map((rule) => [rule.joint, rule.rawAngle ?? rule.angle])),
      targetRules: ruleResults,
      movementRules: movementRuleResults(now),
      aiConfidence,
    };
    const completedReason = source === 'ai_rule'
      ? 'reached_ai_and_rule'
      : source === 'rule_only'
        ? 'reached_rule_only'
        : 'reached_rule_fallback';
    return snapshot({
      angle,
      ruleResults,
      aiSignal,
      aiStatus,
      reason: completedReason,
      source,
      completedRep,
      rulePassed,
      holdElapsedMs,
      requiredHoldMs,
      targetPositionDeltaDeg,
    });
  }

  return {
    config,
    push,
    reset: () => {
      reps = 0;
      lastTimestamp = null;
      resetCurrent();
    },
    interrupt: () => {
      lastTimestamp = null;
      resetCurrent();
    },
    getSnapshot: () => snapshot({ reason: 'waiting_for_rest', scoreable: false }),
  };
}
