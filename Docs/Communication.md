# Patient–Therapist Communication

**Document version:** `communication-doc:v2.0.2`

**Schema version:** `communication-schema:20260831222500`

**Therapist web:** `therapist-web:v0.12.0` — intended tag `therapist-web-v0.12.0`

**Patient iOS:** `combination-v1:v8.0.15` `build:15` — derived from the
preserved `app:v8.0.2` / build 10 team-platform baseline

**Browser media:** native WebRTC — label `webrtc-web:native`

**iOS media:** community WebRTC binary `151.0.0` — label `WebRTC@151.0.0`
**Cloudflare TURN API contract:** docs updated 2026-04-21 — label `cloudflare-turn:2026-04-21`

## Railway production deployment

- Project: `physioai-therapist-web` (`48b23924-27b6-4f07-8fb1-416a6767ffad`)
- Service: `therapist-web` (`ed97a1ac-e69e-47be-b814-2fa007a6b68c`)
- URL: `https://therapist-web.example.com`
- iOS `PHYSIOAI_API_BASE_URL` uses the URL above.

The existing `physioai-ios-production/physioai-ios-web` service is separate.
Never deploy `TherapistWeb/` over that service.

## What is implemented

- Messenger-style one-to-one chat for Therapist web and Patient iOS.
- The Patient home screen exposes chat as a persistent 54-point capsule action
  at the bottom-right safe-area edge instead of a small header icon.
- The Patient message composer explicitly uses the dark ink text color and
  forest cursor color so typed text stays readable on its light background.
- The Patient home header has no back button or exposed logout button. Logout
  is available from the circular profile menu at the top-right.
- Persistent chat history in Supabase `communication_messages`; reopening either
  client reloads the existing history. Client roles cannot edit or delete it.
- Native WebRTC audio/video on web and iOS.
- Short-lived Cloudflare TURN credentials issued by the Next.js server after it
  verifies the Supabase user and active Therapist–Patient assignment.
- WebRTC offer, answer, ICE, and hang-up signaling in
  `communication_call_signals`, protected by pair RLS and expired after 24 hours.
- Call history/state in `communication_calls`; signaling is not chat history.
- Either participant may initiate or receive while the relevant client is open.
- Separate audio-only and video call buttons on web and iOS. Voice calls use
  microphone-only WebRTC, never start the camera, and provide mute/hang-up;
  iOS voice calls start on the receiver and offer a speaker toggle.
- No recording, transcription, raw camera upload, or microphone upload to the app server.

### Audio-call rollout

Apply `20260910065201_add_communication_audio_calls.sql` before deploying the
new server and then updating iOS. `communication_calls.media_type` is immutable
for a call (`audio` or `video`); existing rows and older create requests default
to `video`. Joining and credential refresh use the stored media type, not a
new caller-provided value. Older apps are video-only and must be updated before
receiving voice calls. This is Internet calling, not carrier/PSTN calling;
the foreground-only incoming-call limitation below still applies.

### Hang-up and chat call history

Also apply `20260910093405_finalize_communication_call_history.sql` before
deploying the server/client updates. Each call remains one row in
`communication_calls`; both chat timelines show its media type, direction, and
duration from the first WebRTC-connected report (`connected_at`) to the server's
`ended_at`. Ringing time is excluded. Old history without a connected timestamp
shows a completed call without inventing a duration. Calls ended before a
connection show an unanswered-call label.

Hang-up immediately stops local media and persists terminal state with bounded
retries. Signal polling remains readable for ended calls and returns both the
terminal row and a compatibility hang-up event, so the other peer closes even
if it missed the transient signal. Database triggers freeze terminal status
and timestamps: simultaneous hang-ups or late connection/refresh requests
cannot revive a call, duplicate history, or extend talk time. History is
participant-RLS-protected and currently loads the latest 100 calls per patient.
Both peers must be online to receive the end notification; a failed end request
is shown to the user rather than claiming that the remote side was notified.

One Therapist can have many Patient conversations. A Patient has at most one
Therapist because `therapist_patient_assignments.patient_id` is the primary key.

## Server-only configuration

```ini
CLOUDFLARE_TURN_KEY_ID=
CLOUDFLARE_TURN_KEY_API_TOKEN=
PHYSIOAI_TURN_TTL_SECONDS=3600
```

Never prefix these with `NEXT_PUBLIC_` and never embed the TURN key token in
iOS. The server calls Cloudflare's `generate-ice-servers` endpoint and returns
only expiring ICE credentials. The TTL is clamped to 300–172,800 seconds; the
production default is one hour. Both clients refresh ICE credentials at 80% of
the TTL with `RTCPeerConnection.setConfiguration()` so an active call can
continue beyond one credential lifetime while the backend remains available.

## Encryption and stored data

WebRTC media uses DTLS-SRTP encryption between the two endpoints. Cloudflare
TURN can see connection metadata required to relay traffic but, according to
Cloudflare's TURN documentation, cannot decrypt the relayed audio/video payload.

Chat is persistent application data. Supabase TLS and RLS restrict access to
the assigned pair, but chat text is not client-side encrypted with keys that
Supabase cannot access. Do not market chat as zero-knowledge E2EE until a
separate audited cross-platform key-management design is implemented.

- Messages are 1–4,000 characters and remain stored until an authorized data
  retention/deletion feature is deliberately added.
- Signaling payloads may contain network candidates; they expire after 24 hours
  and an insert trigger purges expired rows.
- Call states are `ringing`, `live`, `ended`, and `cancelled`.
- Call identity fields are immutable; participants may change only lifecycle state.

## Availability boundary

Chat can be reopened whenever Supabase and the network are available. Video
calling also depends on Railway (credential/signaling API), Supabase, Cloudflare
TURN, camera/microphone permission, and a usable network. No Internet service
is guaranteed to be available 100% of the time.

The current iOS foreground flow discovers incoming calls while the app is open.
Receiving calls reliably while the iPhone app is suspended or terminated needs
a later PushKit/APNs + CallKit phase and is not claimed by this version.

## RealtimeKit removal

`therapist-web:v0.9.0` removes the RealtimeKit React packages, iOS RealtimeKit
packages, meeting-token API logic, presets, and RealtimeKit environment names.
The Cloudflare RealtimeKit app itself is an external resource and must be
deleted only after production TURN verification and explicit destructive-action
confirmation.

## Design references

- `Docs/design-concepts/communication-web-v1.png`
- `Docs/design-concepts/communication-ios-v1.png`
- `Docs/design-concepts/communication-web-render-v1.png`
- `Docs/design-concepts/communication-web-mobile-render-v1.png`

The version tags above are intended release tags only; this change does not
create Git tags automatically.
