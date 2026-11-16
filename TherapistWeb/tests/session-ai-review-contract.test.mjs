import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (path) => readFile(new URL(path, import.meta.url), 'utf8');

test('AI review uses a server-only LLM key and a bounded non-diagnostic system prompt', async () => {
  const llm = await read('../utils/sessionReview/llm.js');
  assert.match(llm, /process\.env\[name\]/);
  assert.match(llm, /'LLM_API_KEY'/);
  assert.doesNotMatch(llm, /NEXT_PUBLIC_LLM_API_KEY/);
  assert.match(llm, /Do not diagnose/);
  assert.match(llm, /Session summary JSON/);
  assert.match(llm, /response_format: \{ type: 'json_object' \}/);
  assert.match(llm, /max_completion_tokens: 550/);
  assert.doesNotMatch(llm, /max_tokens:/);
});

test('review route authorizes the patient or therapist and persists an automatic review', async () => {
  const route = await read('../app/api/session-reviews/route.js');
  const migration = await read('../../supabase/migrations/20260831184455_create_session_ai_reviews.sql');
  const nativeClient = await read('../../iOS/PhysioAINative/NativeAPIClient.swift');
  const nativeModel = await read('../../iOS/PhysioAINative/NativeModels.swift');
  assert.match(route, /getRequestAuthContext/);
  assert.match(route, /canUseTherapistWeb/);
  assert.match(route, /canUsePatientApp/);
  assert.match(route, /from\('exercise_sessions'\)/);
  assert.match(route, /schema: 'physioai\.session-summary\.v1'/);
  assert.match(route, /from\('session_ai_reviews'\)/);
  assert.doesNotMatch(route, /media_session_id/);
  assert.match(migration, /enable row level security/i);
  assert.match(migration, /grant select on table public\.session_ai_reviews to authenticated/i);
  assert.match(migration, /patient or assigned therapist can read session AI reviews/i);
  assert.match(nativeClient, /createAutomaticSessionReview/);
  assert.match(nativeModel, /createAutomaticSessionReview\(sessionID: record\.id\)/);
});

test('completed session history shows the automatically stored AI review without exporting JSON', async () => {
  const workspace = await read('../src/SessionHistoryWorkspace.jsx');
  const page = await read('../app/therapist/history/page.jsx');
  assert.match(workspace, /AI review/);
  assert.match(workspace, /กำลังสรุป session นี้อัตโนมัติ/);
  assert.match(workspace, /สร้าง AI review ตอนนี้/);
  assert.match(workspace, /method: 'POST'/);
  assert.match(workspace, /JSON\.stringify\(\{ sessionId: session\.id \}\)/);
  assert.doesNotMatch(workspace, /new Blob/);
  assert.match(workspace, /\/api\/session-reviews/);
  assert.match(page, /from\('session_ai_reviews'\)/);
});
