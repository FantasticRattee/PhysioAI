# Combination V1 V8.0.12 Native AI Port Design

Status: Historical V8.0.12 engine-port record; superseded as the current local
release by V8.0.13 post-session Fault Detector scoring

Environment note: the baseline WebRTC M151 binary was no longer resolvable from
a fresh clone. The user-approved local branch uses M152.0.0 to restore testing
and building; the complete resolution history is in
an internal investigation record (not part of this public copy).

## Goal

Integrate Rattee's V8.0.12-derived evidence/completion seam and its
coaching/count presentation runtime into the local clone of
the team's private repository, while preserving the collaborator platform's
direct-native iOS app, Supabase project, Therapist Web, session history, and
automatic session-review flow.

## Source and ownership boundary

- **Target baseline:** this local clone at GitHub `main` commit
  `d00ab39a8eae9ee49ba1d8c317d19f7cb1dcf943` (`ios-stable-v1`, App V8.0.2).
- **AI source:** Rattee's local V8.0.12 worktree at
  `App/App-V5/.worktrees/v8-0-11-guided-sit-to-stand`.
- **Preserved rollback:** `PhysioAI-Combination-V1/` remains untouched as the
  separate independent-stack adapter proof; it is not the deployment target for
  this port.
- **No cloud action yet:** no push, Railway deploy, Supabase migration, role
  edit, test-account edit, secret write, or physical-device installation is
  part of this design phase.

## Existing platform flow to preserve

```text
Patient native iOS app
  -> direct Supabase Auth and plan read
  -> native Camera / MediaPipe / exercise engine
  -> immutable exercise_sessions row
  -> existing Railway session-review endpoint
  -> session_ai_reviews
  -> TherapistWeb history and patient review screens
```

The target already owns `bottle_grab` and `sit_to_stand`, uses the collaborator
Supabase project, and triggers an automatic, non-diagnostic AI review after a
session is saved. It must not be replaced with the old Combination V1 WebKit
host, its independent Railway service, or its independent Supabase project.

## Confirmed V8.0.12-derived port scope

The native port is a direct iOS integration rather than a second sidecar. It
selectively ports the following V8.0.12-derived capabilities:

- `NativeSitToStandRuleBasedEvidenceV12Module.swift` and its schema resource;
- derived Sit-to-Stand metrics plus observer-only evidence lifecycle in
  `NativeSitToStandV72AIModule.swift` and `CameraSession.swift`;
- prescribed `reps × sets` completion for both supported exercises in
  `NativePracticeView.swift` and `NativeModels.swift`;
- evidence finalization/export selection in `NativeEvidenceExport.swift` and
  `NativeSummaryView.swift`;
- `NativeV812CoachingPolicy.swift`, which supplies concise setup/movement copy,
  visible-cue dwell, a one-episode voice policy, and a controlled
  no-participant reminder;
- `NativeSpeechCommentCoordinator.swift` and the retained native practice
  surface wiring, which keep model/hand comments visual-only, drop stale form
  utterances, and announce each authoritative total as `รอบที่ n` / `Rep n` for
  both Bottle Grab and Sit-to-Stand;
- matching manifests, app version documentation, and XCTest/package tests.

The port must not modify model weights, MediaPipe task assets, the authoritative
geometry counter, PhaseNet, camera ownership, the existing Supabase Auth roles,
existing Therapist plan workflow, or raw-media policy. It adopts the
V8.0.12-derived entry-only Sit-to-Stand hand-admission latch; that gate remains
an engine precondition, not a new cloud/platform workflow. Bottle Grab's
authoritative detector/pose counter remains the team-platform V8.0.2 core because its
source is already identical to the V8.0.12 reference; its calm coaching and
authoritative rep-announcement presentation are now ported.

## Fault Evidence delivery decision

V8.0.12 creates a privacy-safe, derived JSON record. The existing platform has
`exercise_sessions` summary fields and an AI-review flow, but it has no
dedicated persisted Fault Evidence record/table. **Option A is the approved
scope for this port.**

### Option A — Local evidence plus existing session summary first (approved)

- Port V8.0.12 and preserve local JSON export/validation for both exercises.
- Store the already-supported aggregate count (`invalid_reps`) in
  `exercise_sessions`; the current automatic AI review continues to use its
  existing compact session summary.
- Do not add a Supabase migration, evidence API, or Therapist UI in this pass.
- Validate locally and on device first. Add persistent full evidence only after
  the native output is confirmed.

### Option B — Persist full Fault Evidence with the first port

- Add an immutable, session-linked `exercise_session_evidence` table with RLS,
  strict schema validation, Patient insert, and Therapist read/export surface.
- Extend the existing session-review summary with only compact derived evidence
  aggregates; do not send raw JSON or raw landmarks to an LLM.
- Requires a Supabase migration plus TherapistWeb/API tests and later explicit
  deployment authorization.

## Test plan

1. Add RED XCTest/package tests for plan completion, valid Sit-to-Stand
   evidence, no-fault treatment of missing coverage, unchanged Bottle Grab,
   non-repeating voice episodes, concise count copy, and action-cue dwell.
2. Port the minimum native code until focused tests turn GREEN.
3. Run the full native Simulator suite, Swift package tests, and TherapistWeb
   contract tests relevant to the selected delivery option.
4. Build locally first. A signed physical-device install is a later, separately reported
   gate. It does not prove camera, repetition, evidence upload, or dashboard
   behavior by itself.

## Local validation completed

- TDD RED: V8.0.2 could compile only after its obsolete WebRTC dependency was
  repaired; the new Sit-to-Stand evidence tests then failed for the expected
  missing V8.0.12 symbols.
- Focused iOS XCTest: **14/14 passed** after the initial port; the final full
  suite including the aggregate-session check passed **179 tests, 3 expected
  external-replay skips, 0 failures**.
- The V8.0.12 coaching/count RED tests then proved that the former target
  repeated a setup cue after 30 seconds and a form cue after 9 seconds. After
  the port, focused coaching/count tests passed and the native full suite passed
  **189 tests, 3 expected external-replay skips, 0 failures**.
- An unsigned generic arm64 iPhone build of this coaching/count update passed.
  It validates device compilation and linking only; physical camera/TTS/session
  behavior remains a separate gate.
- `PhysioAIFaultEvidenceKit` Swift package: **17/17 passed**.
- JSON reader/visualizer tools: **7/7 passed**.
- TherapistWeb, which was not modified: **34/34 tests passed** and its
  production build succeeded.
- The unsigned generic arm64 iPhone build succeeded. The simulator app was
  installed, launched, and visibly rendered the patient home with both native
  exercises and the existing message entry point.
- A separately signed physical **Combination V1 App V8.0.12/build 12** build
  was installed and launched on the test iPhone as `com.example.physioai.dev`. This
  validates install/launch and release metadata only, not camera, session,
  Supabase, AI-review, or WebRTC behavior.

At completion of this port, the user-facing release was **Combination V1 App V8.0.12 build 12**.
It carries the V8.0.12-derived Sit-to-Stand evidence/completion seam **and**
V8.0.12 coaching/count runtime for both exercises. Its retained V8.0.2/build
10 team-platform source remains the explicit rollback baseline; the release
label does not imply a cloud, schema, or collaborator-platform deployment.

No Supabase migration, dashboard/API/LLM/chat source change, account mutation,
Railway deployment, or main-branch merge occurred. The reviewed patch is
available on remote feature branch `codex/combination-v1-v8-0-12-local-ai-port`
at commit `74a515d`; this coaching/count update was signed with the existing
application team, installed, and launched on the test iPhone, but has not yet received
separate physical-camera/session verification.

## Acceptance criteria

- A prescribed 5×1 Sit-to-Stand session reaches Summary exactly once at five
  authoritative counts.
- Both exercises show calm, dwell-filtered action guidance; model/hand comments
  remain visual-only, and each authoritative count increment speaks exactly
  one `รอบที่ n` / `Rep n` announcement.
- Both exercise IDs retain their existing platform plan assignment and session
  history behavior.
- Fault Evidence remains derived-only and excludes raw frames, landmarks,
  patient identity, and video.
- The existing automatic AI review and therapist communication remain intact.
- The selected delivery option has focused tests and no unrelated platform
  regression.

## Deferred work

Option B — an immutable, session-linked Fault Evidence table, RLS, API and
Therapist History export — is explicitly deferred. It requires a later separate
design, tests, Supabase migration, and deployment authorization.
