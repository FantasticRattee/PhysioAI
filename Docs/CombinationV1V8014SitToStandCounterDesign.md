# Combination V1 App V8.0.14 Sit-to-Stand Counter Calibration Design

Status: **Implemented; automated and signed-device-install verification passed; physical-camera retest pending**

Follow-up 2026-09-05: **Physical retest failed.** The new recording showed
standing assigned as `seated_rest` and sitting assigned as `rising`. The
implementation/verification below is retained as history. The current repair
is [V8.0.15 posture/counting](CombinationV1V8015SitToStandPostureRepair.md).

Date: 2026-09-05

Scope: Native Sit-to-Stand geometry counter only

## Problem

On the V8.0.13 physical-device recording, Pose remains `33/33` and the user
visibly reaches an upright position, but the counter stays in `rising` rather
than `standing_hold`. The current counter requires a fixed absolute
`pelvisHeightAboveAnklesNorm >= 1.10`; that value is a development capture
calibration and can reject normal standing under a different camera/seat/body
geometry.

The user approved a V8.0.14 repair after preserving V8.0.13 as rollback.

## Rollback boundary

- V8.0.13 rollback commit: `2dec783af97539aff785a4d13aeaeb23c6a6f0f2`
- Local rollback tag: `combination-v1-v8.0.13-rollback`
- V8.0.14 development branch: `codex/combination-v1-v8-0-14-sts-counter`
- V8.0.13 remains the installed rollback reference; do not alter its tag.

## Selected approach

Use two independent ways to qualify a stable stand:

1. Keep the existing legacy path unchanged:
   - absolute pelvis height at least `1.10`; and
   - rise from seated baseline at least `0.25`.
2. Add an adaptive path for camera/body scaling differences:
   - rise from the current session's seated baseline at least `0.25`; and
   - mean knee extension at least `150°`.

Both paths still require the existing 200 ms stable-standing hold, lowering,
and return to the seated threshold before a repetition is incremented. A
partial squat that rises high enough but keeps both knees bent cannot use the
adaptive path.

## Why this is selected

| Approach | Result |
| --- | --- |
| Lower `1.10` globally | Not selected: it can make a partial rise count with no compensating guard. |
| Baseline-relative rise only | Not selected: it is more flexible but may count a partial sit-to-stand. |
| Baseline-relative rise plus knee extension plus existing hold | **Selected:** adapts to the user's camera geometry while keeping an independent anti-partial-rise gate. |
| Let PhaseNet/TTS count reps | Not selected: it changes counter ownership and risks coupling comments to repetition authority. |

## Runtime contract

- Add a derived `meanKneeAngleDeg` to the geometry observation; it is computed
  from the existing left/right knee angles, not raw landmarks.
- Keep the counter as the only writer of completed repetitions.
- Keep MediaPipe acquisition, hands-together admission, TTS, PhaseNet comments,
  Fault Detector, session summary, and Bottle Grab unchanged.
- Add a DEBUG-only diagnostic reason when a rising frame has not yet qualified
  as a stand. It may contain derived height, seated baseline, and knee angle;
  it must contain no raw landmark arrays or video.
- Use a centralized threshold configuration so subsequent calibration changes
  do not alter the state-machine logic.

## Acceptance criteria

- A normal baseline-relative full stand below legacy absolute height can count
  only when mean knee extension meets the V8.0.14 guard.
- A baseline-relative partial rise with bent knees does not count.
- Existing legacy absolute-height cycles, two-frame standing spikes, missing
  wrist admission, and Bottle Grab tests retain their current behavior.
- The DEBUG panel identifies a standing-qualification failure without exposing
  raw landmarks.
- App identity becomes V8.0.14/build 14 while retained engine provenance stays
  V8.0.12.
- Focused RED/GREEN tests, full native suite, evidence package tests, generic
  iPhone build, signed physical-device install, and a new physical Sit-to-Stand test
  are documented separately.

## Deferred

- Changing PhaseNet/comment behavior.
- Replacing the geometry counter with a model-owned counter.
- Supabase, Railway, TherapistWeb, detailed evidence-delivery, or model-weight
  changes.
- Clinical threshold claims or cross-user score comparability.

## Implementation and verification

- Added a centralized V8.0.14 geometry-counter configuration and passed the
  existing derived `meanKneeAngleDeg` from the Pose feature extractor into the
  counter. No raw landmarks are retained or exported by this change.
- The legacy absolute-height route remains unchanged. The adaptive route can
  enter `standing_hold` only after both the existing session-relative rise and
  the new `150°` mean-knee-extension guard are satisfied.
- DEBUG now exposes the compact `standing_qualification_pending` reason when
  a rise has not yet qualified; it does not display landmarks, video, or a
  clinical interpretation.
- TDD evidence: the new full-stand-below-legacy test first failed with zero
  repetitions on V8.0.13 logic; the new API call first failed to compile until
  the derived knee angle was wired. The V8.0.14 focused regression set then
  passed `32/32`.
- Full native regression: `198` passed, `3` skipped, `0` failed. The
  `PhysioAIFaultEvidenceKit` package passed `17/17` tests.
- A generic iPhone build and signed physical-device Debug build succeeded. The app was
  installed and launched as `com.example.physioai.dev`, display name
  `PhysioAI App V8.0.14 Combination V1 Experimental`, version `8.0.14`, build
  `14`.
- This establishes source, test, build, install, and launch readiness. It does
  **not** prove the physical-camera count until the user performs a new seated
  baseline → stand → seated cycle on the test iPhone.
