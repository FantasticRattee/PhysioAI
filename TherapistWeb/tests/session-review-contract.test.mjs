import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (path) => readFile(new URL(path, import.meta.url), 'utf8');

test('therapist review table is private and limited to assigned therapist writes', async () => {
  const migration = await read('../../supabase/migrations/20260831190744_create_session_therapist_reviews.sql');
  assert.match(migration, /enable row level security/i);
  assert.match(migration, /grant select, insert, update on table public\.session_therapist_reviews to authenticated/i);
  assert.doesNotMatch(migration, /grant[^;]*delete[^;]*session_therapist_reviews/i);
  assert.match(migration, /session\.patient_id = \(select auth\.uid\(\)\)/);
  assert.match(migration, /assignment\.therapist_id = \(select auth\.uid\(\)\)/);
  assert.match(migration, /profile\.role = 'therapist'::public\.app_role/);
});

test('therapist review API validates role, assigned session, and bounded text', async () => {
  const route = await read('../app/api/therapist-reviews/route.js');
  assert.match(route, /getRequestAuthContext/);
  assert.match(route, /canUseTherapistWeb/);
  assert.match(route, /body\.length > 4000/);
  assert.match(route, /from\('exercise_sessions'\)/);
  assert.match(route, /from\('session_therapist_reviews'\)/);
  assert.match(route, /therapist_id: profile\.id/);
});

test('therapist web offers two review sections while patient reads them in the iPhone app', async () => {
  const workspace = await read('../src/SessionHistoryWorkspace.jsx');
  const nativeHistory = await read('../../iOS/PhysioAINative/NativeSessionHistoryView.swift');
  const nativeClient = await read('../../iOS/PhysioAINative/NativeSupabaseAuthClient.swift');
  assert.match(workspace, /Therapist review/);
  assert.match(workspace, /AI review/);
  assert.match(workspace, /\/api\/therapist-reviews/);
  assert.match(nativeHistory, /Therapist review/);
  assert.match(nativeHistory, /AI review/);
  assert.match(nativeClient, /fetchSessionReviews/);
  assert.match(nativeClient, /from\("session_therapist_reviews"\)/);
});
