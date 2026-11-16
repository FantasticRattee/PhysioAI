import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const migration = await readFile(new URL('../../supabase/migrations/20260831163500_create_exercise_session_history.sql', import.meta.url), 'utf8');
const nativeClient = await readFile(new URL('../../iOS/PhysioAINative/NativeSupabaseAuthClient.swift', import.meta.url), 'utf8');
const historyPage = await readFile(new URL('../app/therapist/history/page.jsx', import.meta.url), 'utf8');
const historyWorkspace = await readFile(new URL('../src/SessionHistoryWorkspace.jsx', import.meta.url), 'utf8');

test('session history is immutable and indexed by patient and completion time', () => {
  assert.match(migration, /create table public\.exercise_sessions/);
  assert.match(migration, /exercise_sessions_patient_ended_at_idx[\s\S]*patient_id, ended_at desc/);
  assert.match(migration, /grant select, insert on table public\.exercise_sessions to authenticated/);
  assert.doesNotMatch(migration, /grant[^;]*(update|delete)[^;]*exercise_sessions/i);
});

test('RLS allows the patient and assigned therapist to read but only the patient to insert', () => {
  assert.match(migration, /patient_id = \(select auth\.uid\(\)\)/);
  assert.match(migration, /assignment\.therapist_id = \(select auth\.uid\(\)\)/);
  assert.match(migration, /patient can create own exercise session/);
  assert.match(migration, /profile\.role = 'patient'::public\.app_role/);
});

test('iOS writes directly to Supabase and Therapist Web reads assigned patient history', () => {
  assert.match(nativeClient, /from\("exercise_sessions"\)/);
  assert.match(nativeClient, /func saveSession/);
  assert.match(historyPage, /from\('exercise_sessions'\)/);
  assert.match(historyPage, /therapist_patient_assignments/);
});

test('session history patient picker supports dropdown search for multiple patients', () => {
  assert.match(historyWorkspace, /aria-haspopup="listbox"/);
  assert.match(historyWorkspace, /type="search"/);
  assert.match(historyWorkspace, /filteredPatients/);
  assert.match(historyWorkspace, /ค้นหาชื่อหรือรหัสผู้ป่วย/);
  assert.match(historyWorkspace, /role="option"/);
});
