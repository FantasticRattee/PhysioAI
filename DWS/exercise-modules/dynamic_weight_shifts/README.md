# Dynamic Weight Shifts

This file preserves development-workspace notes. For the model shipped by
PhysioAI Final, installation and runnable commands, use the
[DWS handoff guide](../../README.md). The native app integration lives in the
repository's `iOS/Modules/PhysioAIDynamicWeightShiftSDK/` directory.

Current training contract for seated lateral Dynamic Weight Shifts:

- Phases: `rest`, `target`. Transition frames are excluded.
- Classes: `correct_left`, `correct_right`, `wrong_left`, `wrong_right`.
- Schema: `seated_balance.v2`.
- Model input: both shoulders and both hips × `x,y,z,visibility` = 16 features.
- Knees, ankles, and wrists must be visible inside the camera frame, but are
  not model features.
- Correct rows train Rest and Target; Wrong rows train Target only.
- No `trunk_shift` value is persisted or fed to the model.
- Therapist selects only Correct/Wrong; `_left` and `_right` always mean the
  direction visible on screen. Anatomical direction is retained only as audit
  metadata and can never change the training class.
- Validation and test require independent real lineages. Synthetic variants are
  train-only and must retain their source lineage.
- Publishing stays blocked until the model passes the approval criteria.

## Validation SDK and coordinate contract

Therapist Validate and Patient practice both use
`sdk/validationRuntime.js`. The iPhone owns front-camera capture, MediaPipe
Pose Heavy, and the live skeleton only; it does not contain a separate Dynamic
Weight Shift classifier or decision engine.

The camera preview may be mirrored like a selfie, but the 33 landmarks passed
to the SDK stay in raw MediaPipe camera coordinates. The feature extractor then
normalizes landmark names to the `screen.v1` convention. Do not reflect x or
swap left/right at the bridge: the training manifest has `mirrorX: false`, so a
second reflection would make Patient practice disagree with the reviewed JSON
and Therapist Validate. The SDK owns the 30-frame, 15 Hz TCN/Hybrid pipeline
and uses the lateral-arm Hybrid confirmation cadence: 300 ms at Target and
180 ms at Rest, with the same 800 ms AI-disagreement rule fallback.

Build the feature payload from reviewed rows:

```bash
node exercise-modules/dynamic_weight_shifts/training/run.mjs \
  --run four-class-v1 --stage features
```

Train with the exercise-owned landmark-only TCN:

```bash
node exercise-modules/dynamic_weight_shifts/training/run.mjs \
  --run four-class-v1 --stage train \
  --python training/.venv/bin/python
```

`training/segment_reps.py`, `training/augment_rep_dataset.py`, and
`training/evaluate_rules.mjs` belong to the retired weak-rule prototype and are
not part of the current training plan. `TRAINING_RESULTS_TH.md` is retained only
as a historical record of that prototype.

## Screen-left two-head TCN candidate

The current data-collection candidate intentionally uses no KNN. It is a
two-head temporal model:

- Phase head: `rest`, `target`.
- Form head: `correct_left`, `wrong_left`, evaluated only at Target.
- Correct rows contribute Rest and Target. Wrong rows contribute Target only.
- Each frame is anchored at the hip center, so absolute hip translation is not
  a model feature.
- Form geometry adds shoulder-line tilt, same-screen-side hip-to-shoulder lean,
  center hip-to-shoulder lean, and the two hip-to-shoulder lengths.
- The form contract does not use the shoulder-hip-knee joint angle. A correct
  Target means the shoulder line remains close to screen-horizontal while the
  torso axis leans toward the Target side.

Inspect the complete plan without training:

```bash
node exercise-modules/dynamic_weight_shifts/training/run_left.mjs \
  --run left-tcn-v1 --stage plan \
  --python training/.venv/bin/python
```

After the Wrong dataset is complete, run the pipeline with:

```bash
node exercise-modules/dynamic_weight_shifts/training/run_left.mjs \
  --run left-tcn-v1 --stage all \
  --python training/.venv/bin/python
```

The feature builder refuses to continue unless both classes have at least three
independent real lineages, so train/validation/test cannot share a source rep.
The current stored `wrong_left` set has only two reps from one session and is
therefore intentionally blocked until more real Wrong data is collected. The
export target is a Validate-only artifact at
`shared/models/cust_dynamic_weight_shifts-left-tcn-v1`; publishing remains
blocked.

Run the geometry audit at rep grain (Target median per rep):

```bash
node analysis/dynamic_weight_shift_geometry_audit.mjs
```
