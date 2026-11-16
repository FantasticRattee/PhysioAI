# Combination V1 V8.0.15: Sit-to-Stand posture and count repair

Status: Implemented, regression verified, installed on the test iPhone, and user-confirmed working in the physical retest on 2026-09-05.

Review branch: `codex/combination-v1-v8-0-15-validated` in the team's private repository.
Tested runtime commit: `e15dc74`. Subsequent release handoff edits are documentation-only.

Baseline designation (user request, 2026-09-05): **Combination V1 - V8.0.15**,
tag `combination-v1-v8.0.15-baseline`, snapshot `c879de1`. The canonical
[baseline record](../iOS/STABLE_VERSION.md) includes the later merge-review
finding about abandoned-attempt Evidence. Baseline designation preserves this
version for future changes and rollback; it does not close that finding.

## Evidence and intended behavior

The V8.0.14 device recording shows standing classified as `seated_rest`,
sitting classified as `rising`, and zero repetitions through three attempts.
The prior threshold-only change did not fix the physical symptom. See
an internal investigation record (not part of this public copy).

Use current image-plane leg geometry for the counter and guided start. The
counter observation must not depend on the estimated depth or the NN feature
normalization. Both sides' hip-to-knee vertical separation is normalized by
the corresponding knee-to-ankle vertical separation; low ratios indicate
seated, high ratios indicate standing, and the band between stays transitional.
These are versioned development capture gates, not clinical form thresholds.

After the hands-together gate:

- Standing: say `ดีมาก นั่งลงได้เลย` once and wait for a stable seated baseline.
- Seated and settling: say/show `นั่งนิ่งสักครู่` until the counter is ready.
- Seated and ready: say `ดีมาก ลุกขึ้นได้เลย` once.
- Stable completed stand: guide the return to the seat.
- A completed sit → stand → sit cycle increments once and uses the existing
  `รอบที่ n`, dose completion, score, and review flow.

Keep cue dwell and speech deduplication. Unknown posture must not be treated
as seated merely because hands are admitted. Real detection/source loss still
invalidates a partial cycle; short NN cadence gaps must not erase valid pose
geometry. Expose current posture, derived progress, counter state and reset
reason in the existing DEBUG panel so future clips are diagnosable.

## Change-impact checklist

- [x] Counter/observation/module: `iOS/PhysioAINative/NativeSitToStandV72AIModule.swift`
- [x] Guided start: `NativeV812CoachingPolicy.swift`, `NativePracticeView.swift`
- [x] Real module and presentation regression tests in `iOS/NativeTests/`
- [x] App V8.0.15/build 15 identity, current manifest, README, release notes
- [x] `DEPENDENCIES.md` and the existing append-only mistake record
- [x] Signed physical-device build/install and metadata verification

The existing FigJam scoring/delivery architecture is unaffected by this
counter repair; its release label remains a prior V8.0.13 snapshot. No cloud
or database changes or detailed-evidence delivery are included. The user
separately authorized publishing a new review branch after the physical test.

## Validation boundary

Regression tests must exercise the real module from synthetic landmark
observations with nonzero/varying depth, starting standing and starting seated,
partial rises, capture gaps, once-only cueing, and multiple cycles. These are
regression inputs, not measured raw landmarks from the supplied recording.
Signed installation does not establish a successful physical-camera retest.
The later physical-test result is the user's explicit confirmation that this
installed V8.0.15 works well. No second video or raw trace was supplied for an
independent repeat measurement; the result applies to the reported setup.

## Rollback

- V8.0.13: `combination-v1-v8.0.13-rollback` at `2dec783`.
- Prior V8.0.14 source/build: `05fd5a2`, unchanged.

## Implemented contract and automated evidence

- Counter posture uses the bilateral thigh/shin vertical ratio: seated mean
  at most 0.55 (neither side above 0.70), standing mean at least 0.85 (neither
  side below 0.65); the intermediate band remains transitional. Progress is
  pelvis-to-ankle height in shin units. No estimated Z enters this observation.
- A seated baseline, relative rise of at least 0.25 shin units, a standing hold
  verified by actual qualifying observations for at least 200 ms, lowering,
  and seated return are required to count. Only the archived scalar entry
  retains V8.0.14's old absolute-height path.
- NN feature cadence remains 45–100 ms. Counter observation continuity accepts
  a missed frame, but a non-monotonic timestamp, gap above 500 ms, invalid pose,
  or capture-source replacement discards the partial cycle.
- Hand admission alone maps to posture checking. The UI uses the module's
  posture-aware action status; cue dwell advances on camera timestamps even
  when the published output is unchanged. The existing speech coordinator
  retains overlap prevention and once-per-episode delivery, with direction
  reminders limited per repetition.
- Eleven regression scenarios were added. Five initially failed against V8.0.14;
  a further short-spike/slow-descent test exposed and then verified the hold
  correction. Two further tests verify that countdown does not consume the
  first seated/standing instruction before TTS can speak. Final native suite:
  **209 passed, 3 expected skips, 0 failures**.
  Includes both exercises, coaching, evidence/scoring, completion, and existing
  platform integration tests. No raw-video inference replay is claimed.

## Handoff packet

- Intent/scope: repair Combination V1 STS counting and posture-aware guidance.
- Owner: `PhysioAI-Combination-V1-TitleBase/iOS`.
- Input: development screen recording SHA-256
  `57126931c29d1b6e1b0f435c3f12bddd8b051dc02ac4e5009394cb90fe402bc0`;
  source baseline `05fd5a2`; synthetic regression poses are not captured landmarks.
- Paths: counter module, coaching policy, practice DEBUG/view wiring, native
  tests, identity files, current manifests, this design, README/release/impact
  documents, and the existing STS mistake record; no files deleted.
- Versions: App 8.0.15/build 15, STS wrapper 1.3.0-dev-image-plane-posture,
  retained engine provenance 8.0.12 and scorer V13.
- Evidence: final native test result `/tmp/physioai-v8015-final-full.xcresult`;
  signed build and device metadata confirm `8.0.15 (15)` for
  `com.example.physioai.dev`. Final install and launch succeeded on the test iPhone.
- Indexes: README, `iOS/STABLE_VERSION.md`, `DEPENDENCIES.md`; root routing is
  unchanged and FigJam retains the earlier scoring/delivery snapshot.
- Rollback: V8.0.13 tag and V8.0.14 commit are preserved.
- Intentionally unchanged: Bottle Grab engine, NN assets/features, evidence
  rules/scorer, cloud/backend/auth configuration, TherapistWeb, Supabase,
  Railway, and the unrelated local production-history-deletion record.
- Physical retest: user confirmed V8.0.15 works well and approved a new GitHub
  review branch. The earlier failed V8.0.14 attempt remains in the mistake log.
- Next: compare the validated branch with `main`; merge is a separate action.

## Baseline-designation handoff — 2026-09-05

- Intent/scope: freeze the user-selected Combination V1 - V8.0.15 reference.
- Owner: this repository's `iOS/STABLE_VERSION.md` and annotated baseline tag.
- Input/source: published snapshot `c879de1143b08da7cd5aaa92e725fe74decdcc74`,
  with application runtime identical to the device-tested `e15dc74`.
- Changes: baseline tag plus README, release/design, dependency, and existing
  review documentation; no runtime files or version numbers change.
- Evidence: tag target, runtime diff, and existing automated/device evidence;
  a rebuild is unnecessary for a tag/documentation-only operation.
- Indexes: README and `DEPENDENCIES.md` point to the canonical baseline record.
- The outer workspace `MAP.md` also routes this project to V8.0.15 and its
  known limitations; that local index belongs to the separate workspace Git
  boundary and is not included in the native repository's push.
- Rollback: V8.0.13 and `ios-stable-v1` references are retained.
- Intentionally unchanged: iOS code/assets, main, cloud services, and the
  unrelated local production-history-deletion record.
- Next: future work branches from the baseline; resolve the known Evidence
  carryover issue before reconsidering main merge readiness.
