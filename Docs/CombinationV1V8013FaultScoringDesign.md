# Combination V1 App V8.0.13 Fault Detector Scoring Design

Status: **Implemented and locally build-verified**

Date: 2026-09-04

Scope: Native patient app only; Bottle Grab and Sit-to-Stand

## Outcome

V8.0.13 adds an experimental, rule-based post-session score for both supported
exercises. The scorer runs after a completed repetition has already been owned
by the existing exercise counter. It consumes the existing derived-only Fault
Detector record and cannot change counting, TTS, camera admission, AI inference,
or exercise completion.

The App/release version is V8.0.13, while the retained AI engine provenance
remains V8.0.12. V8.0.13 is a parallel scoring addition, not an engine rename.

The patient Summary will show useful session feedback instead of empty Pose and
Motion placeholders. Aggregate scores use the existing session-save contract;
detailed per-repetition evidence remains local/export-only.

## Guardrails

- The Fault Detector observes the same derived MediaPipe inputs in parallel with
  the exercise engine; it is not a second repetition counter.
- Only persistent, already-qualified rule signals may reduce a score.
- Rejected or missing input is `cannot_assess`, never automatically a fault.
- No raw camera frame, raw video, or full landmark array enters the score record.
- The values are experimental exercise-quality feedback, not a diagnosis or a
  clinical outcome measure.
- Results may be compared only within the same exercise and rule-set version.
- V8.0.13 does not activate detailed Fault Evidence Delivery to the Therapist
  Dashboard.

## Inputs by exercise

### Bottle Grab

Use the current qualified rule only:

- `incomplete_visible_finger_wrap` -> UI category **Grip / finger wrap**

This intentionally does not invent uncalibrated Bottle Grab rules. New rules can
be added later through the same score contract after evidence and thresholds are
approved.

### Sit-to-Stand

Use the current five persistent rules and group them for the Summary:

| Rule semantic ID | Summary category |
| --- | --- |
| `trunk_view_plane_tilt` | Trunk alignment |
| `trunk_lateral_offset` | Trunk alignment |
| `hip_left_right_asymmetry` | Hip symmetry |
| `knee_left_right_asymmetry` | Knee symmetry |
| `foot_base_offset` | Foot placement |

## Deterministic score contract

For each assessable repetition:

1. Start from 100.
2. Deduplicate signals by semantic ID inside that repetition. Duplicate left and
   right body-region signals for one semantic rule count only once.
3. Deduct by the strongest severity for each semantic ID:
   - low: 10
   - medium: 20
   - high: 35
   - unknown: 20 (safe fallback)
4. Cap total deduction at 60, so an assessable repetition cannot score below 40.
5. A correct assessable repetition scores 100.
6. `cannot_assess` and `incomplete` repetitions are excluded from Form Quality
   and Consistency. They receive no penalty and no hidden zero.

Session metrics:

- **Form Quality** = mean score of assessable repetitions.
- **Consistency** = correct assessable repetitions / assessable repetitions.
- **Evidence Coverage** = assessable repetitions / total completed repetitions.
- **Overall** = 80% Form Quality + 20% Consistency.

The total-completed denominator comes from the authoritative exercise counter.
If the local evidence record is missing a completed repetition, that gap lowers
coverage and cannot inflate the score.

Publish Overall, Form Quality, and Consistency only when both conditions pass:

- Evidence Coverage is at least 60%.
- Assessable repetitions are at least `min(total completed repetitions, 3)`.

If the gate fails, these scores remain unavailable (`—`). Evidence Coverage and
a concise explanation remain visible so missing evidence cannot look like a bad
exercise score.

## Patient Summary design

The V8.0.13 Summary uses:

- a large **Overall experimental rule score**;
- cards for **Form Quality**, **Consistency**, and **Evidence Coverage**;
- up to four detected-fault categories, ordered by severity then frequency;
- one short **Focus next time** message from the strongest/frequent category;
- completed repetitions, flagged repetitions, completed sets, and duration;
- DEBUG-only validated JSON export, unchanged from V8.0.12.

When no persistent fault is detected and coverage passes, the focus message says
that no persistent fault was detected in the assessed repetitions. When coverage
fails, the message asks the user to improve camera visibility for a usable score.

## Persistence and Therapist flow

V8.0.13 reuses existing `exercise_sessions` columns:

- Overall -> `overall_score`
- Form Quality -> `pose_score`
- Motion -> `motion_score = null`
- Flagged repetitions -> `invalid_reps`

The existing Therapist history and automatic AI-review flow can therefore see
the aggregate score without a new Supabase migration. Consistency, coverage,
category breakdowns, and per-repetition signals stay local in V8.0.13.

Detailed evidence upload remains a separate future feature requiring an explicit
API/schema, authorization, retention, and privacy review.

## Acceptance criteria

- Both Bottle Grab and Sit-to-Stand evidence records produce deterministic scores.
- The scorer deduplicates the same semantic rule within a repetition.
- Low/medium/high/unknown severity deductions and the 40-point floor are tested.
- `cannot_assess` and `incomplete` are excluded, not scored as incorrect.
- The coverage/minimum-repetition gate prevents misleading scores.
- Session persistence receives only the approved aggregate mapping.
- Existing counter, TTS, camera, evidence JSON, and automatic completion behavior
  remain unchanged.
- App identity is V8.0.13/build 13.
- Focused tests, full native tests, and a local unsigned iPhone build pass before
  the FigJam proposal is relabeled as current.

## Deferred

- Detailed Fault Evidence Delivery to Therapist Dashboard.
- Cross-exercise score comparisons or clinical cut-offs.
- New Bottle Grab rules beyond the existing qualified finger-wrap rule.
- Production deployment, Git push/merge, and physical-device installation.

## Validation result

- Focused scorer tests: **10 passed, 0 failed**; release metadata is included in
  the complete regression gate.
- Complete native XCTest suite: **199 passed, 3 expected external-replay
  skips, 0 failed**.
- `PhysioAIFaultEvidenceKit`: **17 passed, 0 failed**.
- Generic arm64 iPhone build with code signing disabled: **succeeded**.
- Simulator Summary visual check: rendered without clipped cards or hidden
  actions after normal launch settling time.
- FigJam node `47:168`: V8.0.13 aggregate score is marked current with a solid
  route; detailed Future Evidence Delivery remains dashed and not connected.
- Not run in this change: signed physical-device installation, live-camera
  behavior validation, Git push/merge, Supabase migration, or Railway deploy.

## Physical delivery update — 2026-09-04

- A signed V8.0.13/build 13 build was created for the existing Combination V1
  bundle and installed successfully on the test iPhone.
- Device inventory confirms the installed display name, version 8.0.13, and
  build 13.
- Automatic launch was blocked because the test iPhone was locked. Live-camera and
  post-session score behavior are therefore still pending user/device testing.
