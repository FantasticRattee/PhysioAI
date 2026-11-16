# PhysioAI Combination V1 iOS Release

Current local release label: `combination-v1-v8.0.17` (not a published Git tag).

## Current local version — V8.0.17 clean UI

App `8.0.17` / build `17`, minimum iOS `17.0`. The user confirmed the
installed clean-UI variant works on 2026-09-10 while it still carried the
V8.0.16 label. This promotion retains that exact `NativePracticeView.swift`
and changes version/display labels only. The DEBUG panel and center comment
remain implemented but fully transparent; normal coaching and counting remain.

Review branch: `codex/combination-v1-v8-0-17-clean-ui`.
V8.0.16 rollback branch: `codex/combination-v1-v8-0-16-rollback`, commit
`b9b0d528373e8d4ef20548da8e54ea708567b755`. Do not develop on or force-update
that backup reference. The separate local rollback clone remains read-only;
make a new writable checkout when rollback execution is requested.
All older tags remain unchanged; publishing a branch does not merge main.
See [release scope and verification](../Docs/CombinationV1V8017CleanUIRelease.md).

## Preserved upstream stable release — Combination V1 - V8.0.16

Released as the current stable engineering build on 2026-09-07. Annotated Git
tag: `combination-v1-v8.0.16`. The same monorepo commit is tagged
`therapist-web-v0.15.3` for the matching web/API contract.

This earlier upstream release's baseline tags are retained. Its
immutable baseline tags are `combination-v1-v8.0.16-baseline` and
`therapist-web-v0.15.3-baseline`, both created from the same monorepo snapshot.

Validation recorded for this release:

- unsigned generic iOS Simulator build succeeded;
- unsigned generic iPhone `arm64` build succeeded;
- signed Debug build succeeded with automatic provisioning;
- installed and launched on `SueakKuyRaii`, iPhone 17 Pro, iOS 26.6.1;
- DWS SDK resources, Pose Heavy task, and compiled Core ML model were present
  in the installed app bundle;
- Supabase migration `20260907030508` was applied through the CLI and remote
  schema lint reported no errors;
- Therapist Web v0.15.3 passed all 34 contract tests, production build, GitHub
  CI, and Railway deployment.

This is a reproducible engineering-stable designation. Live physical DWS
movement acceptance still requires a user-performed camera session and is not
a clinical-validation or medical-device claim.

## Prior baseline — Combination V1 - V8.0.15

Selected by the user on 2026-09-05 as the new development/reference and
rollback baseline for this team-platform-based Combination V1 project.

| Baseline field | Frozen value |
| --- | --- |
| Name | Combination V1 - V8.0.15 |
| Annotated Git tag | `combination-v1-v8.0.15-baseline` |
| Snapshot commit | `c879de1143b08da7cd5aaa92e725fe74decdcc74` |
| Tested runtime commit | `e15dc74` (later snapshot changes are documentation only) |
| App / build | `8.0.15` / `15` |
| Source repository | the team's private repository |
| Review branch | `codex/combination-v1-v8-0-15-validated` |
| Device evidence | Installed/launched on the test iPhone; user confirmed the physical retest works |
| Automated evidence | 209 native tests passed, 3 expected external-replay skips |

Keep this tag fixed. Start subsequent changes on a separate `codex/` branch
from the baseline and give later releases a new version/tag. Preserve the
older V8.0.13 rollback tag and `ios-stable-v1` as historical references.

Known limitations remain part of this baseline:

- The merge review reproduced stale STS fault evidence crossing from an
  abandoned, uncounted attempt into the next completed repetition. See
  an internal scoring review record (not part of this public copy).
  This issue is still open and is not fixed by declaring a baseline.
- Physical audio/video-call validation for WebRTC M152 has not been confirmed.
- The baseline tag freezes the selected source; it does not merge the review
  branch into `main` or approve cloud deployment.

The tag points to the already-published snapshot. This designation and the
later merge-review notes are maintained on the review branch without moving
the frozen tag or changing the app's runtime.

## Release and validation context

Physical validation: user confirmed the installed V8.0.15 works on the test iPhone on
2026-09-05. Review branch: `codex/combination-v1-v8-0-15-validated`; tested
runtime commit: `e15dc74`. This release is prepared for branch comparison, not
an automatic merge into `main`.

This directory is the standalone, reproducible iOS patient app. The original
`ios-stable-v1` V8.0.2/build 10 source remains the rollback baseline; the
current local Combination V1 release is versioned independently.

- App version: `8.0.17`
- Build number: `17`
- Release identity: `PhysioAI App V8.0.17 Combination V1 + DWS Experimental`
- V8.0.13 rollback tag: `combination-v1-v8.0.13-rollback` (`2dec783`)
- Prior V8.0.14 source: `05fd5a2`; its physical count retest failed
- Preserved rollback baseline: `ios-stable-v1` / App V8.0.2 / build 10
- Minimum iOS: `17.0`
- Xcode workspace: `PhysioAINative.xcworkspace`
- Scheme: `PhysioAINative`
- Bundle identifier: `com.physioai.patient.bottlegrabqa`
- Therapist API: `https://therapist-web.example.com`

The preserved Stable Version 1 baseline means the source layout, dependencies,
device build, Supabase connection, patient plan, communication, session history,
and two-part session review form a verified engineering baseline. The current
Combination V1 release is not a clinical-validation or medical-device claim.

V8.0.15 retains the V8.0.12 engine provenance and V8.0.13 Fault Detector
scoring, and repairs Sit-to-Stand posture/counting plus guided-start speech.
The active counter uses image-plane leg spans, verifies a seated baseline,
and measures actual standing-hold time. Guidance checks seated/standing state
after hand admission. Detailed evidence remains local/export-only; the
existing session aggregate fields use the established save path. See
[the repair design](../Docs/CombinationV1V8015SitToStandPostureRepair.md).

V8.0.16 adds `cust_dynamic_weight_shifts` from upstream release
the team's `dws-ios` repository at `v3.0.0` (`356195f`). Its front-camera Pose Heavy + Core ML TCN
runtime, safety gate, repetition engine, overlays, and screen layout are kept
in a separate local pod and `DWSPracticeScreen`. Only plan dose, session
summary/history, and passive private video recording use the host app seams.
See [the integration record](../Docs/DynamicWeightShiftV300Integration.md).

## Build

Run from this `iOS/` directory:

```bash
xcodegen generate
pod install
open PhysioAINative.xcworkspace
```

The repository contains no private signing material, service-role key, LLM key, patient record, or captured session video.
