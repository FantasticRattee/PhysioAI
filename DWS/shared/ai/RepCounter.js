import {
  isCorrectDynamicWeightShiftClass,
  isWrongDynamicWeightShiftClass,
} from './DynamicWeightShiftContract.js';

export const AI_REP_PHASES = Object.freeze({
  REST: 'rest',
  MOVING_TO_TARGET: 'moving_to_target',
  TARGET: 'target',
  WAIT_RESET: 'waiting_reset',
});

const TRAINABLE_PHASES = new Set([
  AI_REP_PHASES.REST,
  AI_REP_PHASES.MOVING_TO_TARGET,
  AI_REP_PHASES.TARGET,
]);

const QUALITY_RANK = Object.freeze({
  reached_target: 2,
  not_reached_target: 1,
  // Legacy labels are correction outcomes until old artifacts are replaced.
  unstable: 1,
  incomplete: 1,
  wrong_path: 1,
});

function qualityScore(quality) {
  if (isCorrectDynamicWeightShiftClass(quality)) return 2;
  if (isWrongDynamicWeightShiftClass(quality)) return 1;
  return QUALITY_RANK[quality] || 0;
}

function isReachedQuality(quality) {
  return quality === 'reached_target' || isCorrectDynamicWeightShiftClass(quality);
}

function worseQuality(a, b) {
  if (!a) return b || null;
  if (!b) return a;
  return qualityScore(b) < qualityScore(a) ? b : a;
}

export function createAiPhaseRepCounter({
  minConfidence = 0.75,
  minTargetFrames = 1,
  minRestFrames = 3,
  requireReachedTarget = false,
  targetQualityOnly = false,
} = {}) {
  let reps = 0;
  let state = AI_REP_PHASES.REST;
  let targetFrames = 0;
  let restFrames = 0;
  let rejectedFrames = 0;
  let startedAt = null;
  let worstQuality = null;
  let confidenceSum = 0;
  let confidenceCount = 0;
  let lastCompletedRep = null;

  function resetCurrent({ keepState = false } = {}) {
    if (!keepState) state = AI_REP_PHASES.REST;
    targetFrames = 0;
    restFrames = 0;
    rejectedFrames = 0;
    startedAt = null;
    worstQuality = null;
    confidenceSum = 0;
    confidenceCount = 0;
  }

  function snapshot(completedRep = null) {
    return {
      reps,
      currentPhase: state,
      completedRep,
      rejectedFrames,
    };
  }

  function push({
    phase = null,
    quality = null,
    confidence = 0,
    safetyOk = true,
    timestamp = Date.now(),
  } = {}) {
    lastCompletedRep = null;
    const conf = Number(confidence);
    if (!safetyOk) {
      rejectedFrames += 1;
      if (state !== AI_REP_PHASES.REST) resetCurrent();
      return snapshot();
    }
    if (!Number.isFinite(conf) || conf < minConfidence || !TRAINABLE_PHASES.has(phase)) {
      return snapshot();
    }

    if (state === AI_REP_PHASES.WAIT_RESET) {
      if (phase === AI_REP_PHASES.REST) restFrames += 1;
      else restFrames = 0;
      if (restFrames >= minRestFrames) resetCurrent();
      return snapshot();
    }

    confidenceSum += conf;
    confidenceCount += 1;
    if (!targetQualityOnly || phase === AI_REP_PHASES.TARGET) {
      worstQuality = worseQuality(worstQuality, quality || 'reached_target');
    }

    if (state === AI_REP_PHASES.REST) {
      if (phase === AI_REP_PHASES.MOVING_TO_TARGET) {
        state = AI_REP_PHASES.MOVING_TO_TARGET;
        startedAt = timestamp;
        restFrames = 0;
      } else if (phase === AI_REP_PHASES.TARGET) {
        state = AI_REP_PHASES.MOVING_TO_TARGET;
        startedAt = timestamp;
        targetFrames = 1;
        restFrames = 0;
        if (targetFrames >= minTargetFrames) {
          const completedQuality = worstQuality || quality || 'reached_target';
          const accepted = !requireReachedTarget || isReachedQuality(completedQuality);
          if (accepted) reps += 1;
          lastCompletedRep = {
            index: accepted ? reps : reps + 1,
            startedAt,
            endedAt: timestamp,
            quality: completedQuality,
            confidence: confidenceCount ? confidenceSum / confidenceCount : 0,
            accepted,
          };
          resetCurrent({ keepState: true });
          state = AI_REP_PHASES.WAIT_RESET;
          return snapshot(lastCompletedRep);
        }
      } else if (phase === AI_REP_PHASES.REST) {
        restFrames += 1;
      }
      return snapshot();
    }

    if (state === AI_REP_PHASES.MOVING_TO_TARGET) {
      if (phase === AI_REP_PHASES.TARGET) targetFrames += 1;
      else if (phase === AI_REP_PHASES.REST) resetCurrent();
      if (targetFrames >= minTargetFrames) {
        const completedQuality = worstQuality || 'reached_target';
        const accepted = !requireReachedTarget || isReachedQuality(completedQuality);
        if (accepted) reps += 1;
        lastCompletedRep = {
          index: accepted ? reps : reps + 1,
          startedAt,
          endedAt: timestamp,
          quality: completedQuality,
          confidence: confidenceCount ? confidenceSum / confidenceCount : 0,
          accepted,
        };
        resetCurrent({ keepState: true });
        state = AI_REP_PHASES.WAIT_RESET;
        restFrames = 0;
        return snapshot(lastCompletedRep);
      }
      return snapshot();
    }

    if (state === AI_REP_PHASES.TARGET) {
      state = AI_REP_PHASES.WAIT_RESET;
    }

    return snapshot(lastCompletedRep);
  }

  return {
    push,
    reset: () => {
      reps = 0;
      lastCompletedRep = null;
      resetCurrent();
    },
    getSnapshot: () => snapshot(lastCompletedRep),
  };
}
