# Dynamic Weight Shift v3.0.0 Integration

## Provenance and versions

| Artifact | Exact version / tag |
| --- | --- |
| Upstream repository | the team's private `dws-ios` repository |
| Imported release | `v3.0.0` |
| Imported commit | `356195fe5d5508de3e1d2d4a2f8cdbd80638818d` |
| Host patient app | `8.0.16` build `16` |
| Local CocoaPod metadata | `PhysioAIDynamicWeightShiftSDK` `2.0.0` (unchanged from upstream tag) |
| MediaPipe Tasks Vision | `0.10.35` |
| Minimum iOS | `17.0` |
| Supabase catalog migration | `20260907030508_add_dynamic_weight_shift_exercise` |
| Therapist web | `0.15.3` |

The upstream release tag and podspec version are intentionally recorded
separately: the Git release is v3.0.0, while that release's own podspec reports
2.0.0. This integration does not rewrite upstream provenance.

## Imported scope

The integration includes all DWS SDK Swift sources, the mirrored front-camera
preview, Pose Heavy pipeline, Core ML TCN classifier, AI + Rule decision engine,
safety gate, skeleton and boundary overlays, the complete practice-screen
layout, model/manifest resources, four upstream test suites, and two replay
fixtures.

Runtime resources are pinned by SHA-256:

- `pose_landmarker_heavy.task`: `64437af838a65d18e5ba7a0d39b465540069bc8aae8308de3e318aad31fcbc7b`
- `PhysioAIDynamicWeightShiftTCN.mlmodelc/coremldata.bin`: `6ac265edacc7decc489cf8d7f73ce8b4ba1217cce9539f230d0bde25a91efcd0`

## Isolation boundary

`cust_dynamic_weight_shifts` is routed directly from `NativeRootView` to
`DWSPracticeScreen`. The screen owns `DWSPoseCameraRuntime`; it does not create
or call `CameraSession`, `MediaPipePipeline`, `NativeBottleGrabEngine`, or
`NativePracticeView`. Consequently, changes to the legacy Bottle Grab and
Sit-to-Stand runtime do not decide DWS landmarks, form, or repetitions.

The host app connects only these product-level seams:

- prescribed repetitions and sets from the authenticated Patient plan;
- completion into the existing session summary/history save path;
- passive H.264 capture of the same DWS camera buffers for the existing private
  session-video upload path; recording never participates in DWS inference;
- the shared Supabase exercise catalog, so a Therapist can assign the exercise.

## DWS contract retained from v3.0.0

- Model input: 30 frames × 23 features.
- Decision mode: strict AI + Rule.
- Minimum AI confidence: 0.5.
- Rest/target boundary: Rest at or below 8°, Target above 8°.
- Maximum shoulder tilt: 7°.
- Target hold: 5,000 ms.
- Center re-arm hold: 180 ms.
- Camera: mirrored front camera.

This remains experimental software and is not a clinical-validation claim.
