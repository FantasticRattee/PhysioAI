MediaPipe task assets are copied here for the native iOS target.

App V7 experimental object detector baseline:
- efficientdet_lite0.tflite
- source: https://storage.googleapis.com/mediapipe-models/object_detector/efficientdet_lite0/float32/1/efficientdet_lite0.tflite
- SHA-256: 40338edf5ec70d43e318b0a716a84d4564cd1802759a7a07170c7e43796dbf58
- COCO labels; V7 filters the `bottle` category on-device.
- This is a generic detector baseline, not the Roboflow Bottle Detector
  dataset-trained model. Roboflow model training/export remains a later
  detector-recall experiment.

App V7.3.6 experimental Pose-only Sit-to-Stand module:
- sit_to_stand_phasenet_v1_native.contract.json
- sit_to_stand_v7_ai_module.manifest.json
- sit_to_stand_front_normal_reference_profile_v1_expanded_development.json
- causal_tcn_dilation_{1,2,4}__{0,1}.f32, residual_projection__{0,1}.f32,
  and phase_probabilities__{0,1}.f32
- source model: sit_to_stand_phasenet_v1_train_only
- source candidate SHA-256:
  b0172335605ecd30d5c6c00644b3305793f5b49cde43a6dad5a27c2baaf3c172
- native export manifest SHA-256:
  feb92e6c769e1651acdff0a4fa42e12c97155107d1f2d519eb4a14e1aeb9ea8b
- input: 30 x 30 pose-only Float32 window at 15 Hz; missing features reject
  as cannot_assess (no imputation)
- status: experimental local integration only; export parity is not App or
  patient-facing authorization

App V7.3.3 historical combined experimental bundle:
- native_v7_3_combined_ai_bundle.manifest.json
- combines Bottle Grab Baseline #5 with its V7.1 TTS presentation policy and
  the V7.2 Sit-to-Stand module without changing either engine or model asset.
- V7.3.1 changes Bottle Grab camera transport: ObjectDetector CPU on all
  hardware plus a bounded independent detector lane. V7.3.2 uses same-frame
  camera fan-out: Pose + fresh Bottle ROI own the counter while Hand publishes
  optional finger-quality comments only. V7.3.3 adds only aggregate Bottle
  Detector diagnostics (callback/result state, accepted ROI age, and rejection
  reason) plus a setup-message correction. It does not alter the model asset,
  counter contract, PhaseNet weights, or exercise model outputs.
- status: local experimental grouping only; not deployment, patient-facing, or
  clinical authorization.

App V7.3.4 Stable Bottle Anchor corrective bundle:
- keeps the same `efficientdet_lite0.tflite`, `bottle` category threshold,
  CPU-only ObjectDetector policy, and frozen Baseline #5 assets.
- adds the native-only `bottle_grab_v7_stable_bottle_anchor_v1` runtime layer
  between fresh detector callbacks and the Pose-proximity counter.
- two nearby accepted detector callbacks confirm a checkpoint; later detector
  misses/stale/ambiguous/error results retain that checkpoint without being
  restamped as a fresh ROI. Two coherent, clearly relocated candidates replace
  it; an old out-of-order callback is ignored. Source changes and session
  resets clear it.
- raw detector freshness and checkpoint state remain separate diagnostics.
  This is not a new detector asset, recall claim, patient-facing approval, or
  clinical authorization.

V8 Plan Completion + Evidence Export Local contract (introduced by App V8.0.2;
used by the current Combination V1 App V8.0.15 release):
- native_v8_0_fault_evidence_local.manifest.json
- source snapshot: App V7.3.6 commit
  7c1f199271f52035c51a894220a7348081691ef3
- contains no model weights, thresholds, raw video, or raw landmark arrays.
- describes derived evidence held in memory until an explicit Debug user export.
  It does not enable a Dashboard, backend write, LLM request, clinical
  assessment, or patient-facing approval.
- selected native Bottle Grab plan items now pass therapist `reps`/`sets` into
  the existing local engine as an execution dose. The host stops that selected
  session once the existing counter reaches `reps × sets`, then prepares the
  same local V8 evidence path for the Debug Summary export action.
- this does not change model weights, detector/Capture-QC thresholds, PhaseNet,
  or the counter's movement boundary. Extras remain manual development practice.
- V8.0.13 adds a post-session scorer that reads only the finalized rule-based
  session record. Overall, Form Quality, and flagged-repetition aggregates reuse
  the existing session-save fields; Consistency, Evidence Coverage, fault
  breakdown, and per-repetition details stay local. Detailed evidence is not
  uploaded to Dashboard, Railway, or an LLM.
- V8.0.14 retains that scorer and adds a derived-only Sit-to-Stand geometry
  counter calibration: the legacy absolute standing threshold remains, while a
  session-relative standing path requires mean knee extension. It does not
  change model weights, PhaseNet, TTS, or the Fault Detector rules.
- V8.0.14's physical count retest failed. V8.0.15 replaces the active counter
  observation with image-plane hip/knee/ankle ratios and makes guided-start TTS
  depend on actual seated/standing posture. Its wrapper is
  1.3.0-dev-image-plane-posture. The older scalar counter entry remains for
  characterization tests only; live STS uses explicit posture. NN features,
  weights, Fault Detector rules and post-session score definitions are retained.
