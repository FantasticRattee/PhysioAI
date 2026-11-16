# Session Video Recording and Google Drive Storage

**Patient iOS:** `app:v8.0.2` `build:10` — intended tag `v8.0.2-build.10`

**Therapist web:** `therapist-web:v0.12.0` — intended tag `therapist-web-v0.12.0`
**Database:** `session-media-schema:20260831170722` `session-media-index:20260831172801`

## Architecture

This implementation follows the session-media design in the earlier web-only prototype:

1. The authenticated patient starts a private media session through Railway.
2. The iPhone records portrait H.264 MP4 without audio and closes a segment every 60 seconds.
3. Railway creates a private Google Drive folder and a resumable upload URL.
4. The iPhone uploads each MP4 directly to Google Drive. Files remain queued in Application Support until upload succeeds, including after an app restart.
5. Railway verifies that each uploaded Drive file belongs to the expected session folder before indexing it.
6. An assigned therapist opens the recording from Session History. Video bytes pass through an authenticated same-origin Range proxy; Drive IDs and URLs are never exposed as public links.

Recording is a passive camera sidecar. It does not participate in pose inference, handedness selection, exercise phases, or repetition counting. Exercise practice remains available when session-media configuration is absent.

## Google and Railway configuration

In Google Cloud Console, enable Google Drive API and create an OAuth 2.0 client for the account that will own the private recordings. The helper requests only the `drive.file` scope.

```bash
cd TherapistWeb
GOOGLE_DRIVE_CLIENT_ID=... npm run google-drive:auth-url
GOOGLE_DRIVE_CLIENT_ID=... GOOGLE_DRIVE_CLIENT_SECRET=... npm run google-drive:exchange -- AUTHORIZATION_CODE
```

Set these server-only variables on the Railway service `physioai-therapist-web`:

```ini
SUPABASE_SECRET_KEY=...
GOOGLE_DRIVE_CLIENT_ID=...
GOOGLE_DRIVE_CLIENT_SECRET=...
GOOGLE_DRIVE_REFRESH_TOKEN=...
GOOGLE_DRIVE_ROOT_FOLDER_ID=... # optional
```

Do not add `NEXT_PUBLIC_` to any of these names. The OAuth secret, refresh token, and Supabase secret key must never ship in the iOS app or browser bundle.

## Privacy boundary

Session videos are sensitive health-related data. Before clinical or broad production use, define explicit patient consent, retention and deletion periods, access audit logging, incident response, storage quota alerts, and a privacy/legal review. This prototype records video only; it does not record microphone audio.
