import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const migrationUrl = new URL(
  '../../supabase/migrations/20260831080707_create_therapist_patient_assignments.sql',
  import.meta.url,
);
const migration = await readFile(migrationUrl, 'utf8');
const planBuilder = await readFile(new URL('../src/PlanBuilder.jsx', import.meta.url), 'utf8');
const patientSelector = await readFile(new URL('../src/components/PatientPlanSelector.jsx', import.meta.url), 'utf8');

test('patient primary key enforces one therapist per patient', () => {
  assert.match(migration, /patient_id uuid primary key/);
});

test('therapist foreign key is indexed and remains one-to-many', () => {
  assert.match(migration, /therapist_id uuid not null/);
  assert.match(migration, /create index therapist_patient_assignments_therapist_id_idx/);
  assert.doesNotMatch(migration, /unique\s*\(therapist_id\)/i);
});

test('assignment trigger validates therapist and patient roles', () => {
  assert.match(migration, /assigned_therapist_role is distinct from 'therapist'/);
  assert.match(migration, /assigned_patient_role is distinct from 'patient'/);
  assert.match(migration, /therapist_patient_assignments_enforce_roles/);
});

test('plan builder requires an explicit assigned patient selection', () => {
  assert.match(planBuilder, /useState\(''\)/);
  assert.match(planBuilder, /selectedPatient \? \(/);
  assert.match(planBuilder, /<PatientPlanSelector/);
  assert.match(patientSelector, /aria-haspopup="listbox"/);
  assert.match(patientSelector, /plans? will be delivered only to the selected Patient account/i);
});

test('patient selector scales to multiple patients with search and a scrollable result list', () => {
  assert.match(patientSelector, /type="search"/);
  assert.match(patientSelector, /filteredPatients/);
  assert.match(patientSelector, /role="listbox"/);
  assert.match(patientSelector, /role="option"/);
  assert.match(patientSelector, /patients\.length\.toLocaleString/);
});
