import { createMotionTcnModelRegistry } from '../../../shared/ai/MotionTcnRuntime.js';
import { createTcnMotionClassifier } from '../../../shared/ai/TcnMotionClassifier.js';
import { createPracticeFrameProcessor } from '../../../shared/practice/frame.js';
import {
  createDynamicWeightShiftsDecisionEngine,
  resolveDynamicWeightShiftsExercise,
} from '../runtime/rules.js';

export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_SDK_ID = 'dynamic_weight_shifts.validate.v1';
export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_TARGET_HZ = 15;
export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_INFERENCE_INTERVAL_MS =
  1000 / DYNAMIC_WEIGHT_SHIFT_VALIDATION_TARGET_HZ;
export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_WINDOW_SIZE = 30;
export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_TARGET_CONFIRMATION_MS = 5000;
export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_FALLBACK_CONFIRMATION_MS = 5000;
export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_DISAGREEMENT_CONFIRMATION_MS = 5000;
export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_REST_CONFIRMATION_MS = 180;
export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_MIN_AI_CONFIDENCE = 0.5;
export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_REALTIME_REST_MIN_CONFIDENCE = 0.5;
export const DYNAMIC_WEIGHT_SHIFT_VALIDATION_SCREEN_MIRROR_X = false;

/**
 * One isolated runtime shared by Therapist Validate and Patient practice.
 *
 * Native iOS owns only camera capture, MediaPipe Pose Heavy, and the skeleton.
 * Every Dynamic Weight Shift decision runs through this exact SDK pipeline:
 * raw MediaPipe coordinates, seated_balance.v2 features, 30-frame TCN,
 * latest-frame form head, and one continuous five-second Target confirmation
 * across every Hybrid decision path.
 * Callers can project raw landmarks into a mirrored preview's coordinates
 * for model feature extraction. The default preserves existing Patient input.
 * The extractor mirrors once before normalizing screen-side landmark slots;
 * the source frame, overlay, rule geometry, and dataset remain unchanged.
 */
export function createDynamicWeightShiftValidationSdk({
  exercise = {},
  reference = null,
  modelBaseUrl,
  tf = null,
  allowUnapprovedValidation = false,
  decisionMode = 'hybrid',
  usesAi = true,
  usesRules = true,
  motionEngine = null,
  aiRepCounter = null,
  predictionTimeoutMs = 0,
  screenMirrorX = DYNAMIC_WEIGHT_SHIFT_VALIDATION_SCREEN_MIRROR_X,
  modelRegistryFactory = createMotionTcnModelRegistry,
  motionClassifierFactory = createTcnMotionClassifier,
  decisionEngineFactory = createDynamicWeightShiftsDecisionEngine,
  frameProcessorFactory = createPracticeFrameProcessor,
} = {}) {
  const runtimeExercise = resolveDynamicWeightShiftsExercise({
    ...exercise,
    targetHoldMs: DYNAMIC_WEIGHT_SHIFT_VALIDATION_TARGET_CONFIRMATION_MS,
    fallbackHoldMs: DYNAMIC_WEIGHT_SHIFT_VALIDATION_FALLBACK_CONFIRMATION_MS,
    disagreementHoldMs: DYNAMIC_WEIGHT_SHIFT_VALIDATION_DISAGREEMENT_CONFIRMATION_MS,
    restHoldMs: DYNAMIC_WEIGHT_SHIFT_VALIDATION_REST_CONFIRMATION_MS,
    minAiConfidence: DYNAMIC_WEIGHT_SHIFT_VALIDATION_MIN_AI_CONFIDENCE,
    targetStabilityToleranceDeg: null,
    requireAiConfirmation: false,
  });
  const modelRegistry = usesAi
    ? modelRegistryFactory({ baseUrl: modelBaseUrl, tf })
    : null;
  const motionClassifier = usesAi
    ? motionClassifierFactory({
        registry: modelRegistry,
        modelName: 'motion-tcn',
        extractorOptions: {
          landmarkSchemaId: runtimeExercise.landmarkSchemaId,
        },
        allowUnapprovedValidation,
        // This is the behavior used on Therapist Validate: phase sees the
        // temporal window, while form is evaluated from the current posture.
        formWindowMode: 'latest_frame',
        // DWS has independent Phase and Form heads. Temporal Phase owns the
        // motion state; the current-frame head must still report Form unless
        // a high-confidence current-frame Rest explicitly overrides it.
        latestFrameFormUsesTemporalTarget: true,
        // A current frame that has returned to Rest should use the same 0.5
        // confidence gate as DWS Hybrid. The generic classifier default is
        // intentionally stricter and otherwise leaves DWS stuck in Target.
        realtimeRestMinConfidence: DYNAMIC_WEIGHT_SHIFT_VALIDATION_REALTIME_REST_MIN_CONFIDENCE,
      })
    : null;
  const hybridDecisionEngine = usesRules
    ? decisionEngineFactory({ exercise: runtimeExercise, decisionMode })
    : null;
  const frameProcessor = frameProcessorFactory({
    exercise: runtimeExercise,
    reference,
    motionEngine,
    motionClassifier,
    hybridDecisionEngine,
    aiRepCounter,
    classifierWindowSize: DYNAMIC_WEIGHT_SHIFT_VALIDATION_WINDOW_SIZE,
    classifierInferenceIntervalMs: usesAi
      ? DYNAMIC_WEIGHT_SHIFT_VALIDATION_INFERENCE_INTERVAL_MS
      : 0,
    classifierOptions: {
      landmarkSchemaId: runtimeExercise.landmarkSchemaId,
      extractorOptions: {
        screenMirrorX: screenMirrorX === true,
      },
    },
    predictionTimeoutMs,
  });

  return Object.freeze({
    id: DYNAMIC_WEIGHT_SHIFT_VALIDATION_SDK_ID,
    exercise: runtimeExercise,
    modelRegistry,
    motionClassifier,
    hybridDecisionEngine,
    frameProcessor,
  });
}
