# DWS session review v1 (development)

Base: iOS 8.0.16 / Web 0.15.3. Stable baseline tags remain unchanged.

## Behavior

- Thai on-device TTS announces setup, hold entry, completed reps, incomplete holds, and shoulder tilt. The speaker button mutes speech; leaving the screen stops it.
- Short TTS cues are spaced at least 8 seconds apart; the same phrase cannot
  repeat within 20 seconds. Cues during speech or cooldown are skipped, never
  queued for later. These limits only affect audio, not counting or observations.
- Startup says “ขยับให้เห็นร่างกายครบในกรอบ”. While the boundary has not
  turned green, this reminder may repeat under the same 20-second cooldown.
  It stops once the existing safety gate first reports ready, or the view exits.
- DWS SDK v3.0.0 remains authoritative for counted reps and the five-second continuous hold. No SDK thresholds were changed.
- `completedReps` is copied directly from the SDK snapshot, never independently counted by the scoreboard.
- Shoulder tilt means **greater than 7 degrees**, not torso lean. A warning episode needs 0.5 seconds persistence; it rearms at 6 degrees or less to avoid frame-by-frame duplicates.
- A hold candidate interrupted while tracking is valid is an incomplete hold event
  only when SDK `holdElapsedMs` is strictly greater than 2000 and less than the
  required hold time (5000 ms). Exactly two seconds or a shorter flicker produces
  neither an incomplete-hold count nor its TTS. The same filter applies when
  shoulder tilt interrupts a hold. Tracking loss and stopping the session
  mid-hold remain separate, not classified as patient faults.
- Correct reps exclude `wrong_rule_fallback` reps, even though the SDK counts those toward completion.
- The scoreboard's percentage is completion against prescribed reps × sets. It is not a clinical or form quality score. Fault event counts can overlap and are never added as invalid reps.

## Persistence and automatic AI comment

`exercise_sessions.dws_metrics` stores a bounded JSON object with schema
`physioai.dws-session.v1`, completed/correct/fallback reps, incomplete holds,
shoulder tilt episodes, tracking interruptions, interrupted-at-stop holds,
target reps, hold seconds, and shoulder threshold.

The existing session insert policy and patient/assigned-therapist read policy
also protect this column. Sessions without DWS metrics remain compatible.
After saving the session, iOS requests the existing `/api/session-reviews`
endpoint. The server adds the stored DWS metrics to its LLM input; the API key
remains server-side. The scoreboard observes the fetched review, and the same
review is available in patient history and therapist history.

Deployment order: apply the additive migration, deploy the Web API, then install
the new iOS build. Historical sessions without metrics cannot reconstruct
hold or shoulder events. Physical-camera and audible TTS acceptance must be
checked on an iPhone; synthetic tests cannot validate live pose accuracy.

## Verification

### DWS prompt v2 (2026-09-08, local)

- Selected only for exercise ID `cust_dynamic_weight_shifts`; other exercises keep their existing prompt.
- Short, patient-facing Thai encouragement: one summary, one observation, one next-session reminder. Still attributed to AI, not a human therapist.
- Praise completion separately from form. One shoulder event gets a gentle caution; two or more can be described as repeated shoulder tilt.
- Missing metrics are not zero. Interrupted holds do not prove excessive movement, and zero recorded events do not guarantee perfect form.
- Existing saved reviews are unchanged; new comments require deploying the Web API and generating a new review.

### Existing build verification

Prompt v3 (2026-09-08, local): DWS comments no longer require a praise-first
opening or copyable full examples. The model chooses emphasis from measured
events, uses at most one polite closing, and gives each field a distinct purpose.
Wording may vary, but facts, uncertainty, and AI attribution remain unchanged.
No previous-session comparison or cross-session uniqueness is promised.

### 2026-09-08 installation and smoke test

- Web: 37 tests pass and production build succeeds. Signed iPhone build succeeds;
  installed on the connected iPhone 17 Pro without changing the stable tags.
- Live LLM smoke test used three synthetic summaries (zero, one, and three
  shoulder events; the third also had two incomplete holds). All returned valid
  reviews. No patient data was used and no reviews were persisted.
- Language remains somewhat report-like: all three responses began with target
  completion. Prompt routing and data grounding work, but broad natural-language
  variety is not yet demonstrated by this small sample.
- Server prompt is still local until pushed/deployed; installing iOS alone does
  not activate the new server prompt or replace saved reviews.

- Eight DWS integration tests exercise the SDK contract, direct completion totals,
  fallback labeling, hold interruptions, and persistent shoulder warnings.
- Web suite includes mocked LLM input and DWS-only prompt routing checks (no live model call).
- Web production build and signed iPhone build pass.
- The additive migration was applied and the JSONB column and existing RLS were verified.
- XCTest target overrides inherited CocoaPods graph `-force_load` flags because
  the app host already loads MediaPipe. This fixes test-runner startup without
  changing the shipping app target or SDK.
- Web API deployment and physical-device TTS/session acceptance are still pending.
