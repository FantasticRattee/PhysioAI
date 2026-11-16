import {
  MOTION_FEATURE_SCHEMA_VERSION,
  expectedMotionFeatureSizeForSchema,
  featureVectorsFromWindow,
  extractMotionFeatureWindow,
} from './MotionFeatureExtractor.js';
import { resolveBodyRegionLandmarkSchema } from './BodyRegionLandmarkSchema.js';
import { normalizeCameraView } from './CameraViewGate.js';

export const TCN_PHASES = ['rest', 'moving_to_target', 'target'];
export const TCN_QUALITIES = ['reached_target', 'not_reached_target'];

const PHASE_ALIASES = {
  rest_start: 'rest',
  rest_end: 'rest',
  outbound: 'moving_to_target',
  moving: 'moving_to_target',
};

const QUALITY_ALIASES = {
  good: 'reached_target',
  needs_correction: 'not_reached_target',
  incomplete: 'not_reached_target',
};

function clamp01(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(1, n));
}

function normalizeEnum(value, allowed, aliases = {}, fallback = null) {
  const normalized = aliases[value] || value;
  return allowed.includes(normalized) ? normalized : fallback;
}

async function unwrapModelOutput(raw) {
  if (Array.isArray(raw)) {
    return Promise.all(raw.map((item) => unwrapModelOutput(item)));
  }
  if (raw && typeof raw.data === 'function') {
    const values = await raw.data();
    raw.dispose?.();
    return Array.from(values);
  }
  if (raw && typeof raw.array === 'function') {
    const values = await raw.array();
    raw.dispose?.();
    return values;
  }
  return raw;
}

function indexToEnum(index, allowed) {
  const n = Math.round(Number(index));
  return allowed[n] || null;
}

function vectorFromOutput(output) {
  if (!Array.isArray(output)) return [];
  let value = output;
  while (Array.isArray(value[0])) value = value[0];
  return value.map((item) => Number(item));
}

function maxIndex(vector) {
  if (!Array.isArray(vector) || !vector.length) return { index: null, confidence: 0 };
  let bestIndex = 0;
  let bestValue = -Infinity;
  vector.forEach((value, index) => {
    if (Number.isFinite(value) && value > bestValue) {
      bestValue = value;
      bestIndex = index;
    }
  });
  return { index: bestIndex, confidence: clamp01(bestValue) };
}

function bestEnum(vector, allowed) {
  const best = maxIndex(vector);
  const value = Number.isInteger(best.index) ? allowed[best.index] : null;
  return value ? { value, confidence: best.confidence } : null;
}

function qualityDecisionFromVector(vector, threshold = null, qualities = TCN_QUALITIES) {
  const resolvedThreshold = Number(threshold);
  const reachedIndex = qualities.indexOf('reached_target');
  const notReachedIndex = qualities.indexOf('not_reached_target');
  const binaryTargetContract = reachedIndex >= 0 && notReachedIndex >= 0 && qualities.length === 2;
  if (!binaryTargetContract || !Number.isFinite(resolvedThreshold) || resolvedThreshold <= 0 || resolvedThreshold > 1) {
    return bestEnum(vector, qualities);
  }
  const reachedProbability = clamp01(vector?.[reachedIndex]);
  const reached = reachedProbability >= resolvedThreshold;
  const selectedIndex = reached ? reachedIndex : notReachedIndex;
  return {
    value: TCN_QUALITIES[selectedIndex],
    confidence: clamp01(vector?.[selectedIndex]),
    reachedProbability,
    qualityDecisionThreshold: resolvedThreshold,
  };
}

export function normalizeAiSignal(raw, {
  qualityDecisionThreshold = null,
  phases = TCN_PHASES,
  qualities = TCN_QUALITIES,
  exposeHeadConfidences = false,
  formEvaluationPhases = null,
} = {}) {
  if (!raw) return null;
  if (Array.isArray(raw)) {
    if (Array.isArray(raw[0]) || Array.isArray(raw[1])) {
      const phaseMax = bestEnum(vectorFromOutput(raw[0]), phases);
      const qualityMax = qualityDecisionFromVector(
        vectorFromOutput(raw[1]),
        qualityDecisionThreshold,
        qualities,
      );
      if (!phaseMax || !qualityMax) return null;
      const signal = {
        phase: phaseMax.value,
        quality: qualityMax.value,
        confidence: Math.min(phaseMax.confidence, qualityMax.confidence),
      };
      if (exposeHeadConfidences) {
        const evaluationPhases = Array.isArray(formEvaluationPhases) && formEvaluationPhases.length
          ? formEvaluationPhases
          : ['target'];
        signal.phaseConfidence = phaseMax.confidence;
        signal.formConfidence = qualityMax.confidence;
        signal.formEvaluated = evaluationPhases.includes(signal.phase);
        signal.decisionMode = 'tcn_phase_form';
        signal.confidence = signal.formEvaluated
          ? Math.min(signal.phaseConfidence, signal.formConfidence)
          : signal.phaseConfidence;
      }
      if (Number.isFinite(qualityMax.reachedProbability)) {
        signal.reachedProbability = qualityMax.reachedProbability;
        signal.qualityDecisionThreshold = qualityMax.qualityDecisionThreshold;
      }
      return signal;
    }
    const flat = raw.flat(Infinity);
    if (!flat.length) return null;
    const phase = indexToEnum(flat[0], phases);
    const quality = indexToEnum(flat[1], qualities);
    if (!phase || !quality) return null;
    return {
      phase,
      quality,
      confidence: clamp01(flat[2] ?? 0),
    };
  }
  const phase = normalizeEnum(raw.phase, phases, PHASE_ALIASES, null);
  const quality = normalizeEnum(raw.quality, qualities, QUALITY_ALIASES, null);
  if (!phase || !quality) return null;
  const signal = {
    phase,
    quality,
    confidence: clamp01(raw.confidence ?? raw.score ?? 0),
  };
  if (exposeHeadConfidences) {
    const evaluationPhases = Array.isArray(formEvaluationPhases) && formEvaluationPhases.length
      ? formEvaluationPhases
      : ['target'];
    signal.phaseConfidence = clamp01(raw.phaseConfidence ?? signal.confidence);
    signal.formConfidence = clamp01(raw.formConfidence ?? raw.qualityConfidence ?? signal.confidence);
    signal.formEvaluated = evaluationPhases.includes(signal.phase) && raw.formEvaluated !== false;
    signal.decisionMode = 'tcn_phase_form';
    signal.confidence = signal.formEvaluated
      ? Math.min(signal.phaseConfidence, signal.formConfidence)
      : signal.phaseConfidence;
  }
  return signal;
}

export function createPhaseHysteresis({ minConsecutive = 1 } = {}) {
  const required = Math.max(1, Math.round(Number(minConsecutive) || 1));
  let stablePhase = null;
  let candidatePhase = null;
  let candidateCount = 0;

  function reset() {
    stablePhase = null;
    candidatePhase = null;
    candidateCount = 0;
  }

  function push(signal = null) {
    if (!signal?.phase || required <= 1) return signal;
    const rawPhase = signal.phase;
    if (!stablePhase) {
      stablePhase = rawPhase;
      return { ...signal, rawPhase, phaseStabilized: false };
    }
    if (rawPhase === stablePhase) {
      candidatePhase = null;
      candidateCount = 0;
      return { ...signal, rawPhase, phaseStabilized: false };
    }
    if (rawPhase === candidatePhase) candidateCount += 1;
    else {
      candidatePhase = rawPhase;
      candidateCount = 1;
    }
    if (candidateCount >= required) {
      stablePhase = rawPhase;
      candidatePhase = null;
      candidateCount = 0;
    }
    return {
      ...signal,
      rawPhase,
      phase: stablePhase,
      phaseStabilized: stablePhase !== rawPhase,
    };
  }

  return { push, reset };
}

export function createTcnMotionClassifier({
  registry = null,
  modelName = 'motion-tcn',
  extractorOptions = {},
  tf = null,
  allowUnapprovedValidation = false,
  phaseStabilityFrames = 1,
  formWindowMode = 'shared',
  latestFrameFormUsesTemporalTarget = false,
  realtimeRestMinConfidence = 0.9,
  logger = console,
} = {}) {
  let status = {
    state: 'idle',
    reason: null,
    candidate: false,
    manifest: null,
  };
  const phaseHysteresis = createPhaseHysteresis({ minConsecutive: phaseStabilityFrames });
  const resolvedRealtimeRestMinConfidence = Number.isFinite(Number(realtimeRestMinConfidence))
    ? clamp01(realtimeRestMinConfidence)
    : 0.9;

  function updateStatus(next = {}) {
    status = { ...status, ...next };
    return status;
  }

  async function load() {
    if (!registry?.load) {
      updateStatus({ state: 'unavailable', reason: 'missing_model_registry' });
      return null;
    }
    updateStatus({ state: status.state === 'ready' ? 'ready' : 'loading', reason: null });
    const model = await registry.load(modelName);
    if (!model) {
      updateStatus({ state: 'unavailable', reason: 'model_not_loaded' });
      return null;
    }
    const manifest = model.__physioAiManifest || null;
    updateStatus({
      state: manifest?.approved === true ? 'ready' : 'candidate_ready',
      reason: null,
      candidate: manifest?.approved !== true,
      manifest,
    });
    return model;
  }

  async function predict(frames = [], options = {}) {
    try {
      const model = await load();
      if (!model) return null;
      const manifest = model.__physioAiManifest || {};
      const candidateAllowed = allowUnapprovedValidation === true && manifest.validationOnly === true;
      if (model.__physioAiManifest && manifest.approved !== true && !candidateAllowed) {
        updateStatus({ state: 'blocked', reason: 'model_not_approved', candidate: true, manifest });
        logger?.warn?.('TCN motion classifier is not approved; falling back to rule-based scoring.');
        return null;
      }
      const requestedExerciseId = options.exercise?.id || null;
      if (model.__physioAiManifest && (!manifest.exerciseId || !requestedExerciseId || manifest.exerciseId !== requestedExerciseId)) {
        updateStatus({ state: 'blocked', reason: 'exercise_mismatch', manifest });
        logger?.warn?.(`TCN motion classifier exercise mismatch: exercise ${requestedExerciseId || 'missing'}, model ${manifest.exerciseId || 'missing'}.`);
        return null;
      }
      const requestedCameraView = normalizeCameraView(options.exercise || 'front');
      const manifestCameraView = normalizeCameraView(manifest);
      if (model.__physioAiManifest && requestedCameraView !== manifestCameraView) {
        updateStatus({ state: 'blocked', reason: 'camera_view_mismatch', manifest });
        logger?.warn?.(`TCN motion classifier camera view mismatch: exercise ${requestedCameraView}, model ${manifestCameraView}.`);
        return null;
      }
      const requestedSchema = options.landmarkSchemaId || options.exercise?.landmarkSchemaId || extractorOptions.landmarkSchemaId;
      const manifestSchema = manifest.landmarkSchemaId
        ? resolveBodyRegionLandmarkSchema(manifest.landmarkSchemaId, { fallback: false })
        : null;
      if (model.__physioAiManifest && !manifestSchema) {
        updateStatus({ state: 'blocked', reason: 'missing_landmark_schema', manifest });
        logger?.warn?.('TCN motion classifier manifest is missing or using an unknown landmark schema.');
        return null;
      }
      if (requestedSchema && !resolveBodyRegionLandmarkSchema(requestedSchema, { fallback: false })) {
        updateStatus({ state: 'blocked', reason: 'unknown_requested_schema', manifest });
        logger?.warn?.(`TCN motion classifier requested unknown landmark schema: ${requestedSchema}.`);
        return null;
      }
      if (requestedSchema && manifest.landmarkSchemaId && requestedSchema !== manifest.landmarkSchemaId) {
        updateStatus({ state: 'blocked', reason: 'landmark_schema_mismatch', manifest });
        logger?.warn?.(`TCN motion classifier schema mismatch: exercise ${requestedSchema}, model ${manifest.landmarkSchemaId}.`);
        return null;
      }
      const extractorConfig = {
        ...extractorOptions,
        ...(options.extractorOptions || {}),
        landmarkSchemaId: manifest.landmarkSchemaId || requestedSchema || undefined,
      };
      if (model.__physioAiManifest) {
        extractorConfig.landmarkSchemaId = manifest.landmarkSchemaId;
        extractorConfig.joints = manifest.jointNames || undefined;
        extractorConfig.derivedFeatureContract = manifest.derivedFeatureContract || undefined;
      }
      const featureWindow = extractMotionFeatureWindow(frames, extractorConfig);
      let predictionWindow = featureWindow;
      if (model.__physioAiManifest) {
        const inputShape = manifest.inputShape;
        if (!Array.isArray(inputShape) || inputShape.length !== 2) {
          updateStatus({ state: 'blocked', reason: 'missing_input_shape', manifest });
          logger?.warn?.('TCN motion classifier manifest is missing inputShape.');
          return null;
        }
        const windowSize = Number(inputShape[0]);
        const featureSize = Number(inputShape[1]);
        const expectedFeatureSize = expectedMotionFeatureSizeForSchema({
          landmarkSchema: manifestSchema,
          derivedFeatureContract: manifest.derivedFeatureContract || null,
        });
        if (!Number.isInteger(windowSize) || windowSize <= 0 || featureSize !== expectedFeatureSize) {
          updateStatus({ state: 'blocked', reason: 'input_shape_mismatch', manifest });
          logger?.warn?.(`TCN motion classifier inputShape mismatch for ${manifest.landmarkSchemaId}.`);
          return null;
        }
        const featureVersion = Number(manifest.motionFeatureSchemaVersion || 1);
        if (featureVersion !== MOTION_FEATURE_SCHEMA_VERSION || manifest.windowPadding !== 'repeat_first') {
          updateStatus({ state: 'blocked', reason: 'feature_contract_mismatch', manifest });
          logger?.warn?.('TCN motion classifier feature contract does not match the runtime extractor.');
          return null;
        }
        if (!featureWindow.length) return null;
        if (featureWindow.length < windowSize) {
          predictionWindow = [
            ...Array.from({ length: windowSize - featureWindow.length }, () => featureWindow[0]),
            ...featureWindow,
          ];
        } else {
          predictionWindow = featureWindow.slice(-windowSize);
        }
        if (predictionWindow.some((features) => features.schemaMissing || features.featureVector.length !== featureSize)) {
          updateStatus({ state: 'blocked', reason: 'feature_window_mismatch', manifest });
          logger?.warn?.('TCN motion classifier feature window does not match manifest inputShape.');
          return null;
        }
      }
      async function runPrediction({
        predictionVectors,
        predictionFrames = frames,
        predictionFeatures = featureWindow,
      }) {
        let raw = null;
        if (typeof model.predictMotion === 'function') {
          raw = await model.predictMotion({
            frames: predictionFrames,
            featureWindow: predictionFeatures,
            vectors: predictionVectors,
            options,
          });
        } else if (typeof model.predict === 'function') {
          const tensorRuntime = tf || globalThis.tf;
          const shouldUseTensor = model.__physioAiManifest && typeof tensorRuntime?.tensor3d === 'function';
          const input = shouldUseTensor ? tensorRuntime.tensor3d([predictionVectors]) : predictionVectors;
          try {
            raw = await model.predict(input, {
              frames: predictionFrames,
              featureWindow: predictionFeatures,
              options,
            });
          } finally {
            input?.dispose?.();
          }
        } else {
          updateStatus({ state: 'unavailable', reason: 'missing_predict_function', manifest });
          return null;
        }
        return unwrapModelOutput(raw);
      }

      const signalOptions = {
        qualityDecisionThreshold: manifest.qualityDecisionThreshold,
        phases: manifest.phases || TCN_PHASES,
        qualities: manifest.qualities || TCN_QUALITIES,
        exposeHeadConfidences: manifest.exposeHeadConfidences === true,
        formEvaluationPhases: manifest.formEvaluationPhases || manifest.qualityTrainingPhases,
      };
      const vectors = predictionWindow.map((features) => features.featureVector);
      let signal = normalizeAiSignal(await runPrediction({ predictionVectors: vectors }), signalOptions);
      if (formWindowMode === 'latest_frame' && signal?.formEvaluated === true) {
        const latestFrame = frames.at(-1);
        const latestFeatures = predictionWindow.at(-1);
        const realtimeFeatures = Array.from(
          { length: predictionWindow.length },
          () => latestFeatures,
        );
        const realtimeVectors = realtimeFeatures.map((features) => features.featureVector);
        const realtimeSignal = normalizeAiSignal(await runPrediction({
          predictionVectors: realtimeVectors,
          predictionFrames: latestFrame ? [latestFrame] : frames.slice(-1),
          predictionFeatures: realtimeFeatures,
        }), signalOptions);
        if (realtimeSignal) {
          const phaseConfidence = clamp01(signal.phaseConfidence ?? signal.confidence);
          const realtimePhaseConfidence = clamp01(
            realtimeSignal.phaseConfidence ?? realtimeSignal.confidence,
          );
          if (
            realtimeSignal.phase === 'rest' &&
            realtimePhaseConfidence >= resolvedRealtimeRestMinConfidence
          ) {
            signal = {
              ...signal,
              phase: 'rest',
              quality: null,
              confidence: realtimePhaseConfidence,
              phaseConfidence: realtimePhaseConfidence,
              formConfidence: null,
              formEvaluated: false,
              formWindowMode: 'latest_frame',
              formWindowFrames: 0,
              phaseWindowMode: 'latest_frame_rest',
            };
          } else if (
            realtimeSignal.formEvaluated === false &&
            latestFrameFormUsesTemporalTarget === true &&
            signal.phase === 'target' &&
            realtimeSignal.quality
          ) {
            // The temporal head owns Phase while the repeated latest frame
            // owns Form. A latest-frame Phase candidate can still be Rest
            // below the explicit Rest override threshold; that must not erase
            // the independent Form head and leave Hybrid waiting forever.
            const formConfidence = clamp01(
              realtimeSignal.formConfidence ?? realtimeSignal.confidence,
            );
            signal = {
              ...signal,
              quality: realtimeSignal.quality,
              confidence: Math.min(phaseConfidence, formConfidence),
              phaseConfidence,
              formConfidence,
              formEvaluated: true,
              formWindowMode: 'latest_frame',
              formWindowFrames: 1,
              realtimePhaseCandidate: realtimeSignal.phase,
              realtimePhaseConfidence,
            };
            if (Number.isFinite(realtimeSignal.reachedProbability)) {
              signal.reachedProbability = realtimeSignal.reachedProbability;
              signal.qualityDecisionThreshold = realtimeSignal.qualityDecisionThreshold;
            }
          } else if (realtimeSignal.formEvaluated === false) {
            signal = {
              ...signal,
              quality: null,
              confidence: phaseConfidence,
              phaseConfidence,
              formConfidence: null,
              formEvaluated: false,
              formWindowMode: 'latest_frame',
              formWindowFrames: 0,
              realtimePhaseCandidate: realtimeSignal.phase,
              realtimePhaseConfidence,
            };
          } else {
            const formConfidence = clamp01(
              realtimeSignal.formConfidence ?? realtimeSignal.confidence,
            );
            signal = {
              ...signal,
              quality: realtimeSignal.quality,
              confidence: Math.min(phaseConfidence, formConfidence),
              phaseConfidence,
              formConfidence,
              formEvaluated: true,
              formWindowMode: 'latest_frame',
              formWindowFrames: 1,
            };
            if (Number.isFinite(realtimeSignal.reachedProbability)) {
              signal.reachedProbability = realtimeSignal.reachedProbability;
              signal.qualityDecisionThreshold = realtimeSignal.qualityDecisionThreshold;
            }
          }
        } else {
          const phaseConfidence = clamp01(signal.phaseConfidence ?? signal.confidence);
          signal = {
            ...signal,
            quality: null,
            confidence: phaseConfidence,
            phaseConfidence,
            formConfidence: null,
            formEvaluated: false,
            formWindowMode: 'latest_frame',
            formWindowFrames: 0,
          };
        }
      }
      updateStatus({
        state: manifest.approved === true ? 'ready' : 'candidate_ready',
        reason: signal ? null : 'invalid_model_output',
        candidate: manifest.approved !== true,
        manifest,
      });
      return phaseHysteresis.push(signal);
    } catch (err) {
      updateStatus({ state: 'error', reason: err?.message || 'prediction_failed' });
      logger?.warn?.('TCN motion classifier failed; falling back to rule-based scoring.', err);
      return null;
    }
  }

  return {
    modelName,
    load,
    predict,
    reset: phaseHysteresis.reset,
    getStatus: () => ({ ...status }),
    featureVectorsFromWindow: (frames, options = {}) => featureVectorsFromWindow(frames, {
      ...extractorOptions,
      ...options,
    }),
  };
}
