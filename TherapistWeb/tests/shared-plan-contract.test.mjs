import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const migration = await readFile(new URL(
  '../../supabase/migrations/20260831081446_create_shared_patient_plans.sql',
  import.meta.url,
), 'utf8');

const catalogMigration = await readFile(new URL(
  '../../supabase/migrations/20260831081910_create_exercise_catalog.sql',
  import.meta.url,
), 'utf8');

const nativeClient = await readFile(new URL(
  '../../iOS/PhysioAINative/NativeSupabaseAuthClient.swift',
  import.meta.url,
), 'utf8');

test('shared plan stores one current plan per patient', () => {
  assert.match(migration, /patient_id uuid not null unique/);
  assert.match(migration, /foreign key \(patient_id, therapist_id\)/);
});

test('exercise dose stores reps, sets, and hold seconds', () => {
  assert.match(migration, /reps smallint not null/);
  assert.match(migration, /sets smallint not null/);
  assert.match(migration, /hold_sec numeric\(5,2\) not null/);
  assert.match(catalogMigration, /patient_plan_exercises_exercise_id_fkey/);
  assert.match(catalogMigration, /references public\.exercise_catalog \(id\)/);
});

test('atomic plan RPC uses caller permissions and validates assignment', () => {
  assert.match(migration, /create function public\.save_patient_plan/);
  assert.match(migration, /security invoker/);
  assert.match(migration, /patient is not assigned to this therapist/);
  assert.match(catalogMigration, /from public\.exercise_catalog as exercise/);
});

test('native patient client reads the Supabase dose fields', () => {
  assert.match(nativeClient, /from\("patient_plans"\)/);
  assert.match(nativeClient, /items:patient_plan_exercises/);
  assert.match(nativeClient, /case holdSec = "hold_sec"/);
});
