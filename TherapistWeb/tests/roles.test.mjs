import assert from 'node:assert/strict';
import test from 'node:test';
import {
  APP_ROLES,
  canUsePatientApp,
  canUseTherapistWeb,
} from '../utils/roles.js';

test('role contract exposes exactly therapist and patient', () => {
  assert.deepEqual(Object.values(APP_ROLES), ['therapist', 'patient']);
});

test('therapist web accepts only therapist', () => {
  assert.equal(canUseTherapistWeb('therapist'), true);
  assert.equal(canUseTherapistWeb('patient'), false);
  assert.equal(canUseTherapistWeb(undefined), false);
});

test('patient app accepts only patient', () => {
  assert.equal(canUsePatientApp('patient'), true);
  assert.equal(canUsePatientApp('therapist'), false);
  assert.equal(canUsePatientApp(undefined), false);
});
