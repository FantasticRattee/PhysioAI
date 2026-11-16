# Session Review

**Patient iOS:** `combination-v1:v8.0.15` `build:15` — derived from the
preserved `app:v8.0.2` / build 10 team-platform baseline

**Therapist web:** `therapist-web:v0.15.2` — intended tag `therapist-web-v0.15.2`

**Database schema:** `session-ai-reviews-schema:20260831184455` `session-therapist-reviews-schema:20260831190744`

## What it does

After a patient finishes a session, the iPhone saves the existing immutable `exercise_sessions` summary and then asks Railway to create an AI review automatically. Railway turns the permitted metrics into `physioai.session-summary.v1` JSON, sends that JSON to OpenAI, and stores the returned review in the private `session_ai_reviews` table. There is no JSON export step.

For V8.0.15 Bottle Grab and Sit-to-Stand sessions, the existing summary may now
include the experimental Fault Detector aggregate `overall_score`, the Form
Quality aggregate in `pose_score`, and the flagged-repetition count in
`invalid_reps`. `motion_score` remains null. Consistency, Evidence Coverage,
fault categories, per-repetition evidence, raw landmarks, and the local Export
Evidence JSON are **not** sent through this review flow.

Session review has two parts:

1. **Therapist review** — the assigned therapist writes and updates it from Therapist Web.
2. **AI review** — Railway creates it automatically from the session summary JSON.

For sessions created by an older iPhone build, Therapist Web also provides **สร้าง AI review ตอนนี้**. This generates and stores the same review without requiring the patient to repeat the exercise or export JSON manually.

There is no Patient Web. The patient opens Session history and both review sections in the iPhone app. Therapist Web remains therapist-only.

No session video, Google Drive URL, patient email, raw camera landmarks, or LLM key is sent to the browser or used as LLM input.

The prompt is deliberately non-diagnostic: it makes a short operational summary, observations, and next-session focus items for a therapist to review. It must not be treated as medical advice.

Supabase RLS permits the patient to read reviews for their own sessions and permits only the currently assigned therapist to create or update a Therapist review. Neither review table grants delete access to authenticated clients.

## Railway configuration

Add these server-only variables to the `physioai-therapist-web` Railway service:

```ini
LLM_API_KEY=...
LLM_MODEL=gpt-5.6-luna
LLM_BASE_URL=https://api.openai.com/v1
```

`LLM_MODEL` and `LLM_BASE_URL` are optional defaults. `gpt-5.6-luna` is the configured default. Do not prefix these names with `NEXT_PUBLIC_`, and never place the API key in the iPhone app or a Git commit.

Without `LLM_API_KEY`, the page remains safe and shows a setup message; it does not send the session anywhere.
