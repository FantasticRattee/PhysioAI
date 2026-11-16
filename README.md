# PhysioAI

> **Public snapshot of a team project.** PhysioAI guides people with mobility
> disabilities through physiotherapy exercises at home. An iPhone app follows each
> exercise through the camera and counts repetitions; a therapist assigns the plan
> and reviews sessions on the web. PhysioAI won First Prize at the 2026 national
> final of AI Innovation for Disability. The award recognizes the project;
> development and evaluation continue.
>
> My part (Rattee): the patient experience, the therapist workflow, and training
> the PhaseNet models. Project page with screens, a clickable demo and the award
> sources: <https://portfolio-web-production-47a8.up.railway.app/projects/physioai>
>
> This repository is a single-commit copy of the team's working repository. Left
> out of the copy: live backend addresses and keys (the build settings are empty,
> so the app runs in fixture mode until you set your own backend), the three
> bundled example videos, the two GitHub Actions workflow files, and internal
> investigation notes. It is an experimental prototype, not a clinical or
> production release.

The rest of this file is the working repository's own README (release
**PhysioAI Final**), kept as written for the engineering record.

**Feature-branch version: Combination V1 App V8.0.17 / build 17.** This is the
user-tested clean-UI variant of V8.0.16: DEBUG and the duplicate center
positioning copy are retained at opacity zero. Promotion to V8.0.17 changes
release labels only; AI, counters, TTS, scoring, and platform behavior are
unchanged. See the [V8.0.17 release and rollback record](Docs/CombinationV1V8017CleanUIRelease.md).
Review branch: `codex/combination-v1-v8-0-17-clean-ui`. The separate rollback
branch `codex/combination-v1-v8-0-16-rollback` identifies the original
`b9b0d52` V8.0.16 snapshot; do not develop on or force-update that backup.
The local read-only rollback clone is retained separately. Publication of
these branches does not merge either one into `main`.

This repository contains the native iOS **Combination V1 App V8.0.17** patient
release under `iOS/`, derived from the retained V8.0.2 team-platform baseline,
and a standalone Next.js Therapist Plan Builder. The native handoff includes its local
resources, tests, and the reusable `PhysioAIFaultEvidenceKit`. It also includes
the standalone Railway web/API source and private Google Drive session-video
integration. The `DWS/` workspace includes the original DWS training landmark
records, feature snapshots, checkpoints and training/export tools. It does
**not** include the Expo app, production secrets, production patient records,
captured patient videos, or device provisioning files.

## Repository layout

- `iOS/` — Patient iPhone app, native tests, model resources, XcodeGen config, CocoaPods lockfile, and the `ios-stable-v1` manifest.
- `TherapistWeb/` — Therapist-only Next.js application and Railway API.
- `supabase/` — Versioned database migrations shared by both clients.
- `Docs/` — Architecture, communication, media, review, and investigation notes.
- `DWS/` — Complete DWS training workspace, original datasets, frozen `left-tcn-v3` features/checkpoints, TFJS export and Core ML verification. Start with [DWS/README.md](DWS/README.md).

**Current release labels:** `combination-v1` `app:v8.0.17` `build:17` `ios:17.0+` `swift:5.0`
`supabase-swift:2.55.1` `mediapipe:0.10.35`
`webrtc-ios:M152.0.0` `dws-ios:v3.0.0` `dws-pod:2.0.0` `therapist-web:v0.15.3` `next:16.3.1`
`node:22+` `npm:12.0.2` `supabase-js:2.112.4` `supabase-ssr:0.12.5`
`webrtc-web:native` `cloudflare-turn:2026-04-21` `plan-schema:20260831082135`
`communication-schema:20260831222500` `session-history-schema:20260831163500`
`session-media-schema:20260831170722`
`session-media-index:20260831172801`
`dws-catalog-schema:20260907030508`

## Version manifest

The labels below identify the exact app, platform, dependency, and build-tool
versions used by this handoff. They are documentation labels; a label is not
necessarily the name of an upstream Git tag.

### App, platform, and direct dependencies

| Item | Version | Version label / release tag | Pinned in |
| --- | ---: | --- | --- |
| PhysioAI App | 8.0.17 | `combination-v1-v8.0.17` (local label, not a published tag) | `iOS/PhysioAINative/Info.plist` |
| iOS app build | 17 | `build-17` / `v8.0.17-build.17` | `iOS/PhysioAINative/Info.plist` |
| Minimum iOS | 17.0 | `ios-17.0` | `iOS/project.yml`, `iOS/Podfile` |
| Swift language mode | 5.0 | `swift-5.0` | `iOS/project.yml` |
| Supabase Swift SDK | 2.55.1 | `supabase-swift@2.55.1` | `iOS/project.yml`, `Package.resolved` |
| WebRTC iOS binary | M152.0.0 | `WebRTC@152.0.0` | `iOS/project.yml`, `Package.resolved` |
| MediaPipe Tasks Common | 0.10.35 | `MediaPipeTasksCommon@0.10.35` | `iOS/Podfile.lock` |
| MediaPipe Tasks Vision | 0.10.35 | `MediaPipeTasksVision@0.10.35` | `iOS/Podfile.lock` |
| Dynamic Weight Shift source | 3.0.0 | `dws-ios@v3.0.0` (`356195f`) | `iOS/Modules/PhysioAIDynamicWeightShiftSDK/` |
| Dynamic Weight Shift pod | 2.0.0 | `PhysioAIDynamicWeightShiftSDK@2.0.0` | local podspec |

### Swift package lock versions

These transitive versions are resolved by Swift Package Manager and committed
in `iOS/PhysioAINative.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

| Package | Locked version | Version label |
| --- | ---: | --- |
| `supabase-swift` | 2.55.1 | `supabase-swift@2.55.1` |
| `WebRTC` | 151.0.0 | `WebRTC@151.0.0` |
| `swift-asn1` | 1.7.1 | `swift-asn1@1.7.1` |
| `swift-clocks` | 1.1.1 | `swift-clocks@1.1.1` |
| `swift-concurrency-extras` | 1.4.1 | `swift-concurrency-extras@1.4.1` |
| `swift-crypto` | 4.5.1 | `swift-crypto@4.5.1` |
| `swift-http-types` | 1.6.0 | `swift-http-types@1.6.0` |
| `xctest-dynamic-overlay` | 1.13.1 | `xctest-dynamic-overlay@1.13.1` |

### Verified build tools

| Tool | Verified version | Version label |
| --- | ---: | --- |
| Xcode | 26.6 (`17F113`) | `xcode@26.6` |
| XcodeGen | 2.46.0 | `xcodegen@2.46.0` |
| CocoaPods | 1.16.2 | `cocoapods@1.16.2` |

### Therapist web

The standalone [Therapist Plan Builder](TherapistWeb/README.md) runs on
Next.js 16.3.1 with Node.js 22+. Its intended release tag is
`therapist-web-v0.15.3`. Supabase `exercise_catalog` is the web catalog source
of truth and contains `bottle_grab`, `sit_to_stand`, and
`cust_dynamic_weight_shifts`.

The preserved iOS Stable Version 1 baseline is tagged `ios-stable-v1` and
remains V8.0.2/build 10 for rollback evidence. The current Combination V1
release uses `CFBundleShortVersionString=8.0.17` and `CFBundleVersion=17`.

Dynamic Weight Shift is imported from upstream the team's `dws-ios` repository at `v3.0.0` with
its complete camera/AI/safety runtime, model resources, tests, and practice
layout. It is routed through `DWSPracticeScreen` and never enters the legacy
`NativePracticeView` runtime. See [DWS integration provenance](Docs/DynamicWeightShiftV300Integration.md).

## Status and scope

**Previous stable engineering release: Combination V1 - V8.0.16 / build 16 and
Therapist Web v0.15.3**, released together on 2026-09-07. The release tags are
`combination-v1-v8.0.16` and `therapist-web-v0.15.3`; both point to the same
monorepo release commit so the iPhone exercise contract, Supabase migration,
and deployed web catalog remain reproducible together. See the
[stable release record](Docs/StableReleaseV8016Web0153.md).

**Preserved upstream stable rollback snapshot (2026-09-09):**
`physioai-stable-2026-09-09`, covering both iPhone and Therapist Web application
code at `41625b1`. Embedded app versions are unchanged; use this tag to identify
the exact snapshot. See [rollback instructions and known limits](Docs/StableSnapshot20260909.md).

Immutable baseline tag: `physioai-baseline-2026-09-09`. It points to the same
commit `85e7750` as `physioai-stable-2026-09-09` for both iPhone and Web.
Use this snapshot as the reference for subsequent changes; do not move either tag.

The previous 2026-09-07 baseline is retained. Immutable baseline tags
`combination-v1-v8.0.16-baseline` and
`therapist-web-v0.15.3-baseline` point to the same monorepo snapshot.

**Prior rollback baseline: Combination V1 - V8.0.15**, selected by the user on
2026-09-05. Immutable reference tag: `combination-v1-v8.0.15-baseline` at
`c879de1` (tested runtime `e15dc74`). This snapshot remains available for
rollback. See [baseline identity and known limitations](iOS/STABLE_VERSION.md).

The user confirmed V8.0.15 works in the physical-device retest on 2026-09-05.
The review branch is `codex/combination-v1-v8-0-15-validated`, with runtime
source from `e15dc74`. Compare it with `main` before choosing a merge; see the
[V8.0.15 validation handoff](Docs/CombinationV1V8015SitToStandPostureRepair.md).

### Local Combination V1 V8.0.15 posture/count repair

The local branch `codex/combination-v1-v8-0-15-sts-posture` now identifies as
Combination V1 `app:v8.0.15`, build `15`, while retaining V8.0.12 engine
provenance and the V8.0.2/build 10 team-platform baseline for rollback. It
keeps Rattee's V8.0.12-derived Sit-to-Stand evidence/completion seam **and**
the V8.0.12 coaching/count presentation runtime for Bottle Grab and
Sit-to-Stand: calm visual-cue dwell, one spoken instruction per live episode,
one controlled no-participant reminder, and an authoritative `Rep n` / `รอบที่ n`
announcement. V8.0.15 retains the V8.0.13 post-session score. It fixes the
Sit-to-Stand counter's standing/seated inversion by using image-plane leg
geometry, and guides seated or standing patients appropriately after hand
admission. NN features and scoring rules retain their prior definitions.
It does not alter
`TherapistWeb/`, Supabase migrations, Railway, the session-AI-review route, or
the therapist communication flow. The
local-only design, validation evidence, and deferred full-evidence persistence are recorded in
[`Docs/CombinationV1V8PortDesign.md`](Docs/CombinationV1V8PortDesign.md).

The implemented post-session Fault Detector scoring design for Combination V1
App V8.0.13 is recorded in
[`Docs/CombinationV1V8013FaultScoringDesign.md`](Docs/CombinationV1V8013FaultScoringDesign.md).
The current repair and validation are recorded in
[`Docs/CombinationV1V8015SitToStandPostureRepair.md`](Docs/CombinationV1V8015SitToStandPostureRepair.md).
The earlier [V8.0.14 attempt](Docs/CombinationV1V8014SitToStandCounterDesign.md)
is retained as history; its physical-camera retest failed.

The original WebRTC M151 binary asset is no longer resolvable from a fresh
clone. The approved local branch uses M152.0.0 solely to restore reproducible
Xcode builds; physical WebRTC call validation remains a separate gate.

### Railway deployment ownership

- `TherapistWeb/` belongs to the Railway project `physioai-therapist-web` and
  service `therapist-web` only.
- Do not deploy `TherapistWeb/` over `physioai-ios-production` or its
  `physioai-ios-web` service. That project is a separate existing system.
- Current Therapist Web production URL:
  `https://therapist-web.example.com`.
- GitHub source of truth: the team's private repository, branch `main`.
- `.github/workflows/therapist-web-ci.yml` runs `npm ci`, tests, and a production
  build. Railway is connected to the same branch; the root npm launcher builds
  and starts `TherapistWeb/`, while watch paths ignore unrelated iOS-only
  changes. Keep Railway **Wait for CI** enabled so failed checks skip deployment.

- Experimental developer build; not a clinical, diagnostic, patient-facing, or
  production-readiness claim.
- Bottle Grab plan dose can run as `reps × sets` and the Debug summary can
  export a local, de-identified RuleBasedSession JSON file.
- The JSON describes experimental derived rule observations only. It is not
  proof of grip force, bottle contact, clinical form correctness, or model
  accuracy.
- Camera frames and inference remain on device. The production Patient app
  resolves the Therapist Web URL from its build setting and retains the same
  HTTPS production URL as a fallback if that setting is absent.
- Supabase Auth is divided into `patient` and `therapist` roles. The iOS app
  accepts patients, while the standalone web accepts therapists. See
  [Supabase roles and provisioning](Docs/SupabaseRoles.md).
- Therapist exercise plans are stored in Supabase with the prescribed reps,
  sets, and hold time per exercise. The connected Patient account reads that
  plan directly in the iOS app.
- The Therapist must explicitly select an assigned Patient before the plan form
  unlocks; the app never chooses the first Patient automatically.
- Exercise definitions and default doses are stored in Supabase
  `exercise_catalog`; prescribed rows reference it with a foreign key.
- Assigned Patient and Therapist accounts have persistent one-to-one text chat
  and WebRTC video calls relayed by Cloudflare TURN when a direct path is unavailable. See
  [Patient–Therapist Communication](Docs/Communication.md) for the security
  boundary and required server-only Cloudflare configuration.

## Requirements

- macOS with Xcode and an iOS Simulator or a physical iPhone.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) and CocoaPods.
- Your own Apple Development Team and unique bundle identifiers for a physical
  device build.

## Fresh-clone setup

1. Change into `iOS/`, then in `project.yml` set `DEVELOPMENT_TEAM` to your Apple team and replace
   the example app/test bundle IDs with unique values you control.
2. `PHYSIOAI_API_BASE_URL` points to the separate production Therapist Web
   service. A local override or build setting takes precedence over the bundled
   production fallback for development.
3. Set `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` in the Xcode build
   settings for the Supabase project used by email/password authentication.
   Use a publishable key only; never add a Supabase service-role key to the
   iOS app.
4. Generate native project files and install dependencies:

   ```bash
   xcodegen generate
   pod install
   open PhysioAINative.xcworkspace
   ```

5. Choose your Team in Xcode, then build/run. For test verification, select an
   installed Simulator destination, for example:

   ```bash
   xcodebuild \
     -workspace PhysioAINative.xcworkspace \
     -scheme PhysioAINative \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
     test
   ```

The generated `Pods/`, Xcode workspace/project user state, app build output,
and Swift Package build cache are intentionally ignored. Run `xcodegen
generate` and `pod install` again after a fresh clone.

## Evidence JSON

`iOS/PhysioAIFaultEvidenceKit/` is Foundation-only and can be used independently
by another Swift/iOS host. It includes:

- rule-based session schemas;
- a host-adapter example;
- package tests;
- a terminal reader and browser visualizer under `Tools/`.

The app's **Export Evidence JSON** action is explicit and local-only; it does
not upload to a dashboard, backend, LLM, or cloud service.

## Known investigations

- [Bottle Grab handedness instability in live camera](Docs/BottleGrabHandednessInstability.md)
  documents the observed frame-to-frame `Left`/`Right` oscillation, current
  thresholds, limitations of the stable-landmark tests, and possible future
  mitigation directions. It records an unresolved investigation, not a fix.

## Third-party dependencies

The native app uses Supabase Swift `2.55.1` for email/password authentication,
the community WebRTC binary `151.0.0` for calls, and MediaPipe Tasks Vision
`0.10.35` via CocoaPods. It also bundles upstream MediaPipe model assets.
Review their upstream licenses and terms before redistributing a derivative
application.

## What is intentionally absent

No Apple signing team, provisioning profile, device identifiers, production
backend endpoint, secrets, production patient records, raw media, or generated
build output is included in this repository.

The public copy also leaves out the three example videos the app plays before an
exercise (`Resources/grabbottle.mov`, `Resources/dws-example.mov`,
`Resources/sit-to-stand.mov`) and their entries in `iOS/project.yml`, so the
example player has nothing to show until you add your own clips with those names.
