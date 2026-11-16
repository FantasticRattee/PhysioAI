import assert from 'node:assert/strict';
import test from 'node:test';
import { assignedPair } from '../utils/cloudflare/assignedPair.js';

const patientId = 'aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb';
const therapistId = 'cccccccc-1111-4222-8333-dddddddddddd';
const assignment = { patient_id: patientId, therapist_id: therapistId };

function database({ row = assignment, error = null } = {}) {
  const filters = [];
  let queries = 0;
  const query = {
    select(columns) {
      assert.equal(columns, 'patient_id, therapist_id');
      return this;
    },
    eq(column, value) {
      filters.push([column, value]);
      return this;
    },
    async maybeSingle() {
      const matches = row && filters.every(([column, value]) => row[column] === value);
      return { data: error || !matches ? null : row, error };
    },
  };
  return {
    filters,
    get queries() { return queries; },
    from(table) {
      assert.equal(table, 'therapist_patient_assignments');
      queries += 1;
      return query;
    },
  };
}

for (const input of [patientId, patientId.toUpperCase(), 'AAAAAAAA-1111-4222-8333-bbbbbbbbbbbb']) {
  test(`the same patient is authorized independent of UUID casing: ${input}`, async () => {
    const db = database();
    assert.deepEqual(await assignedPair(db, { id: patientId, role: 'patient' }, input), assignment);
    assert.deepEqual(db.filters, [['patient_id', patientId]]);
  });
}

test('changing casing does not let a patient call for another patient', async () => {
  const db = database();
  assert.equal(await assignedPair(db, { id: therapistId, role: 'patient' }, patientId.toUpperCase()), null);
  assert.equal(db.queries, 0);
});

test('a therapist must match the assigned therapist', async () => {
  const db = database();
  assert.deepEqual(await assignedPair(db, { id: therapistId, role: 'therapist' }, patientId.toUpperCase()), assignment);
  assert.deepEqual(db.filters, [['patient_id', patientId], ['therapist_id', therapistId]]);
  assert.equal(await assignedPair(database(), { id: patientId, role: 'therapist' }, patientId), null);
});

test('missing assignments and unsupported roles remain denied', async () => {
  assert.equal(await assignedPair(database({ row: null }), { id: patientId, role: 'patient' }, patientId), null);
  const db = database();
  assert.equal(await assignedPair(db, { id: patientId, role: 'admin' }, patientId), null);
  assert.equal(db.queries, 0);
});

test('database failures are not reported as missing assignments', async () => {
  const failure = new Error('unavailable');
  await assert.rejects(assignedPair(database({ error: failure }), { id: patientId, role: 'patient' }, patientId), failure);
});
