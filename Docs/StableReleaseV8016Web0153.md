# Stable Release: iPhone V8.0.16 + Therapist Web v0.15.3

Release date: 2026-09-07

This monorepo release freezes the matching patient iPhone application,
Therapist Web application, and Supabase exercise contract at one Git commit.

## Release tags

| Component | Version | Annotated Git tag |
| --- | --- | --- |
| Patient iPhone app | 8.0.16, build 16 | `combination-v1-v8.0.16` |
| Therapist Plan Builder | 0.15.3 | `therapist-web-v0.15.3` |
| Dynamic Weight Shift source | upstream 3.0.0 | `dws-ios@v3.0.0` |
| Dynamic Weight Shift local pod | 2.0.0 | `PhysioAIDynamicWeightShiftSDK@2.0.0` |
| Minimum supported iOS | 17.0 | `ios-17.0` |
| Exercise catalog migration | 20260907030508 | `dws-catalog-schema:20260907030508` |

Both application tags point to the same monorepo commit. Do not move either
tag; issue a new version for later changes.

## Active baseline

This release is the active baseline for subsequent development and rollback.
The immutable baseline tags are:

- `combination-v1-v8.0.16-baseline`
- `therapist-web-v0.15.3-baseline`

Both baseline tags point to the same monorepo snapshot. The older
`combination-v1-v8.0.15-baseline` tag remains unchanged as historical rollback
evidence.

## Verified release evidence

- Therapist Web: 34 contract tests passed and the Next.js production build
  succeeded.
- GitHub: Therapist Web CI passed for the integration commit.
- Railway: the integration deployment became Active and the production Plan
  Builder displayed all three iOS exercises, including DWS Native v3.0.0.
- Supabase: migration history matches local files, migration 20260907030508 is
  applied, and the linked public schema passed CLI lint.
- iPhone build: generic Simulator, generic device arm64, and signed device
  builds succeeded.
- Device install: the signed application installed and launched on
  `SueakKuyRaii` (iPhone 17 Pro, iOS 26.6.1).
- DWS packaging: the standalone SDK bundle contains its manifest, Pose Heavy
  task, and compiled Core ML model in the device build.

## Stability boundary

Dynamic Weight Shift remains isolated in its local pod and
`DWSPracticeScreen`; it does not enter the legacy Bottle Grab/Sit-to-Stand
runtime. Shared seams are limited to assigned plan dose, session history, and
passive session-video recording.

This release is engineering-stable and reproducible. It does not claim clinical
validation. Final live-camera movement acceptance must be performed by a user
on the physical iPhone.
