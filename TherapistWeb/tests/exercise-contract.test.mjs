import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { makeDefaultPlan } from '../src/data.js';

const catalogMigration = await readFile(new URL(
  '../../supabase/migrations/20260831081910_create_exercise_catalog.sql',
  import.meta.url,
), 'utf8');

const dwsMigration = await readFile(new URL(
  '../../supabase/migrations/20260907030508_add_dynamic_weight_shift_exercise.sql',
  import.meta.url,
), 'utf8');

const planPage = await readFile(new URL(
  '../app/therapist/plan/page.jsx',
  import.meta.url,
), 'utf8');

const planActions = await readFile(new URL(
  '../app/therapist/plan/actions.js',
  import.meta.url,
), 'utf8');

test('database catalog contains every supported iOS exercise', () => {
  assert.match(catalogMigration, /'bottle_grab'[\s\S]*'Bottle Grab'[\s\S]*'iOS V8\.0\.2'/);
  assert.match(catalogMigration, /'sit_to_stand'[\s\S]*'Sit to Stand'[\s\S]*'iOS V8\.0\.2'/);
  assert.match(dwsMigration, /'cust_dynamic_weight_shifts'[\s\S]*'Dynamic Weight Shift'[\s\S]*'DWS Native v3\.0\.0'/);
  assert.match(dwsMigration, /jsonb_array_length\(target_items\) > 3/);
});

test('a new patient plan starts empty until the therapist selects catalog rows', () => {
  const plan = makeDefaultPlan('patient-id', '2026-08-31');
  assert.equal(plan.startDate, '2026-08-31');
  assert.deepEqual(plan.items, []);
});

test('plan UI and save validation both read the active database catalog', () => {
  assert.match(planPage, /from\('exercise_catalog'\)/);
  assert.match(planPage, /exercises=\{exercises\}/);
  assert.match(planActions, /from\('exercise_catalog'\)/);
  assert.match(planActions, /allowedExerciseIds/);
  assert.match(planActions, /items\.length > 3/);
});
