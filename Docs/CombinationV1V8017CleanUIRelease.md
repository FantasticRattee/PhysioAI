# Combination V1 App V8.0.17 — clean UI

Release date: 2026-09-10. This is a presentation-only variant of the
V8.0.16 snapshot below, with app/build identity updated to 8.0.17 / 17.
Branch publication and a main merge are separate actions.

## Version references

| Purpose | Reference |
| --- | --- |
| V8.0.17 review branch | `codex/combination-v1-v8-0-17-clean-ui` |
| V8.0.16 cloud rollback branch | `codex/combination-v1-v8-0-16-rollback` |
| Original V8.0.16 commit | `b9b0d528373e8d4ef20548da8e54ea708567b755` |
| Original V8.0.16 tree | `8dd2a0e6822843442e1a2e3545ed83675c72ab5a` |

The rollback branch must continue to identify the original commit; do not
develop on it or force-update it. A separate local rollback clone is
read-only and independent of this working repository. Git does not version
those local read-only permissions, and this release does not claim that
GitHub branch-protection settings were changed. To roll back, build from a
separate writable checkout of the frozen commit.

## Exact runtime difference

The user confirmed the clean-UI variant works on their test iPhone while it
still carried the V8.0.16/build 16 label. V8.0.17 retains that exact
`NativePracticeView.swift`:

`SHA-256: 4f9bdd6f715f806988a46e5419de3066fac069b3f0272b19ab4c68a08c0f6a7e`

- The DEBUG panel remains implemented, with opacity zero.
- The duplicate center positioning comment remains implemented, with opacity zero.
- Hidden content is excluded from hit testing and accessibility navigation.
- Countdown numerals, lower coaching cues, skeleton and controls remain.
- Restoring either existing layer only requires setting its matching opacity
  constant to 1.

Compared with unmodified V8.0.16, only three runtime files differ:

1. `NativePracticeView.swift`: the already-tested presentation modifiers.
2. `Info.plist`: version 8.0.17, build 17, and display-name labels.
3. `NativeAppBuildProfile.swift`: matching version/display labels.

Camera/AI modules, model weights and manifests, counters, coaching/TTS
decisions, evidence contracts, scoring, the DWS SDK, dependencies,
TherapistWeb, Supabase migrations and Railway configuration are unchanged.
Older version strings in frozen engine manifests describe provenance, not
the current app release.

## Verification and limits

- Release-identity tests were updated first and failed for the expected old
  8.0.16/16 values; they pass after the metadata update.
- Version, bundle-provenance and all three presentation tests pass.
- Full native suite: 250 tests, three skipped and two pre-existing failures.
  The same failures were reproduced on a clean, unmodified `b9b0d52` checkout:
  - `DWSHybridEngineTests.testStrictAIAndRuleDoesNotLetAICorrectOverrideFailedRules`:
    actual `ready_to_move`, expected `waiting_for_ai_rule_match`.
  - `NativeSitToStandV72Tests.testNativeUserCatalogIncludesSitToStandAlongsideBottleGrab`:
    the test expects two exercises, while the retained V8.0.16 catalog includes DWS.
- No unrelated engine or test-expectation repair was included in this release.
  The full native suite is not claimed to pass.
- Signed iPhone build and strict code-signature verification passed with
  8.0.17/build 17 metadata. Signing was supplied through local build-command
  overrides, not committed credentials or project team settings.
- Normalizing only version/build strings makes the two identity files
  byte-identical to V8.0.16. The tested practice-view hash is unchanged.
- The user's physical acceptance applies to this same UI/runtime before
  metadata promotion. It is not a new clinical-validation claim.

Generated app bundles, provisioning material, local device logs and
workstation-specific audit notes are intentionally excluded from this repo.
Fresh cloners should follow the repository README: select their own Apple
Team and bundle identifier, run XcodeGen, then install the locked Pods.

## Merge boundary

A Git conflict check only answers whether Git can combine the changes.
It does not prove runtime correctness. Re-fetch and re-check against the
latest `main` immediately before a merge, even for UI-only work.
No main merge, cloud deployment or production-data change is part of this
branch publication.
