# PhysioAI Therapist Plan Builder

Standalone therapist web interface for preparing an exercise plan that matches
the exercise catalog available in the PhysioAI iOS patient app.

**Version labels:** `therapist-web:v0.15.3` `next:16.3.1` `node:22+`
`react:19.2.4` `npm:12.0.2` `supabase-js:2.112.4`
`supabase-ssr:0.12.5` `webrtc-web:native` `cloudflare-turn:2026-04-21`
`plan-schema:20260831082135` `communication-schema:20260831222500`
`session-history-schema:20260831163500` `session-media-schema:20260831170722`
`session-media-index:20260831172801`
`dws-catalog-schema:20260907030508`

## Version manifest

| Item | Version | Version label / release tag | Pinned in |
| --- | ---: | --- | --- |
| Therapist Plan Builder | 0.15.3 | `therapist-web-v0.15.3` | `package.json` |
| Next.js | 16.3.1 | `next@16.3.1` | `package.json`, `package-lock.json` |
| React | 19.2.4 | `react@19.2.4` | `package.json`, `package-lock.json` |
| React DOM | 19.2.4 | `react-dom@19.2.4` | `package.json`, `package-lock.json` |
| Node.js runtime | 22 or newer (verified 24.19.0) | `node@22+` | `package.json` |
| npm | 12.0.2 | `npm@12.0.2` | `package.json`, `package-lock.json` |
| Supabase JavaScript | 2.112.4 | `@supabase/supabase-js@2.112.4` | `package.json`, `package-lock.json` |
| Supabase SSR | 0.12.5 | `@supabase/ssr@0.12.5` | `package.json`, `package-lock.json` |
| Browser WebRTC | Native API | `webrtc-web:native` | `src/components/WebRTCCall.jsx` |
| Cloudflare TURN credential API | 2026-04-21 docs | `cloudflare-turn:2026-04-21` | `utils/cloudflare/turn.js` |
| Shared plan schema | 20260831081446 | `create_shared_patient_plans` | `supabase/migrations/` |
| Exercise catalog schema | 20260831081910 | `create_exercise_catalog` | `supabase/migrations/` |
| Catalog FK index | 20260831082135 | `index_exercise_catalog_foreign_key` | `supabase/migrations/` |
| DWS catalog + 3-item plan limit | 20260907030508 | `dws-catalog-schema:20260907030508` | `supabase/migrations/` |
| Patient–Therapist communication | 20260831222500 | `communication-schema:20260831222500` | `supabase/migrations/` |
| Exercise session history | 20260831163500 | `session-history-schema:20260831163500` | `supabase/migrations/` |
| Private Drive session video | 20260831170722 | `session-media-schema:20260831170722` | `supabase/migrations/` |
| Session video exercise index | 20260831172801 | `session-media-index:20260831172801` | `supabase/migrations/` |

`therapist-web-v0.15.3` is the stable release tag. It points to the same
monorepo release commit as iPhone tag `combination-v1-v8.0.16`, keeping the web
catalog, Supabase migration, and iOS exercise contract aligned.

## Exercise contract

The web reads active exercise definitions from Supabase `exercise_catalog`.
The table contains the three experimental exercises supported by the iOS
V8.0.16 build profile. Dynamic Weight Shift uses its own DWS v3.0.0 runtime.

| Exercise ID | Thai title | English title | Default dose |
| --- | --- | --- | --- |
| `bottle_grab` | หยิบขวด | Bottle Grab | 1 rep × 1 set |
| `sit_to_stand` | ลุก-นั่งจากเก้าอี้ | Sit to Stand | 5 reps × 1 set |
| `cust_dynamic_weight_shifts` | ฝึกเลื่อนน้ำหนักขณะนั่ง | Dynamic Weight Shift | 10 reps × 1 set, 5-second hold |

## Run locally

Requirements: Node.js 22 or newer and npm 12.0.2.

## CI/CD

The team's private repository is the deployment source of truth. Pushes that change
`TherapistWeb/**` run `.github/workflows/therapist-web-ci.yml`; the workflow
installs the lockfile exactly, runs all contract tests, and builds Next.js.
Railway watches branch `main`; the repository-root npm launcher delegates the
build and start commands to `TherapistWeb/`, and Railway watch paths ignore
unrelated iOS-only changes. Railway **Wait for CI** is enabled so production
deploys only after the GitHub check succeeds. Railway and
Google/Supabase secrets stay in Railway variables and are never copied into
GitHub or the repository.

```bash
npm install
npm run dev
```

Open [http://localhost:3000/therapist/plan](http://localhost:3000/therapist/plan).
Unauthenticated users are redirected to `/login`. Only a Supabase user whose
`public.profiles.role` is `therapist` can open the plan builder.

Production check:

```bash
npm run build
npm test
npm start
```

Production is deployed as a separate Railway project and service:
[`https://therapist-web.example.com`](https://therapist-web.example.com).
It must not replace the existing `physioai-ios-web` service.

## Current scope

- Next.js App Router running on the default Node.js runtime.
- Responsive Thai/English therapist UI based on the layout and design tokens in
  an earlier web-only prototype. That source project is a visual
  reference only; this app does not import from it or connect to its runtime.
- Patient selection from the signed-in therapist's Supabase assignments,
  exercise selection, dosage, schedule, notes, program summary, and atomic
  Supabase save. Each exercise stores `reps`, `sets`, and `hold_sec` for the
  connected iOS patient account.
- Patient selection is mandatory and explicit. The plan form remains locked
  until the Therapist chooses its recipient; no Patient is auto-selected.
- The recipient control supports name/case-code search, a bounded scrollable
  result list, connected-patient counts, and alphabetical ordering so one
  Therapist account remains usable as its assigned Patient list grows.
- Supabase email/password login with SSR cookie refresh. Authorization reads
  the server-managed `public.profiles.role`; it never trusts editable user
  metadata for a role decision.
- Exercise definitions are stored in `exercise_catalog`. Plans are stored in
  `patient_plans` and `patient_plan_exercises`, whose exercise IDs have a
  foreign key to the catalog. The iOS app
  reads its signed-in Patient's plan directly through Supabase RLS.
- `/therapist/messages` provides a Messenger-style conversation list, one-to-one
  persistent Supabase text chat and WebRTC video calls using Cloudflare TURN for the
  selected assigned Patient.
- `/therapist/history` shows immutable iPhone exercise sessions for the selected
  assigned Patient, including date, repetitions, sets, duration, and score when
  the exercise runtime provides one.
- Therapist account details and Logout are grouped in the circular profile menu
  in the top bar. The menu closes on outside press or Escape.

## Communication setup

Add these server-only variables to `.env.local`; do not prefix them with
`NEXT_PUBLIC_`:

```ini
CLOUDFLARE_TURN_KEY_ID=
CLOUDFLARE_TURN_KEY_API_TOKEN=
PHYSIOAI_TURN_TTL_SECONDS=3600
```

The iOS app must set `PHYSIOAI_API_BASE_URL` to this deployed Next.js server.
Calls cannot start until a Cloudflare TURN key and its server-only token exist.
Recording and transcription are not enabled.

WebRTC media is DTLS-SRTP encrypted peer-to-peer; Cloudflare TURN relays encrypted
packets and cannot read their media content. Persistent chat is access-controlled
with Supabase RLS but is not client-side zero-knowledge E2EE. See
[`Docs/Communication.md`](../Docs/Communication.md).

Authentication, role gating, Therapist–Patient assignment, shared exercise
plans, and session history are connected directly through Supabase. See
[`Docs/SupabaseRoles.md`](../Docs/SupabaseRoles.md) before provisioning users.
