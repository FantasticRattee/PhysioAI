import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

import {
  RULE_BASED_SESSION_SCHEMA,
  readRuleBasedSessionJSON,
} from '../rule-json-reader.mjs';

const sample = {
  schema: RULE_BASED_SESSION_SCHEMA,
  moduleID: 'bottle_grab_rule_based_session_v8_local',
  moduleVersion: '0.1.0-dev',
  exerciseID: 'bottle_grab',
  trackingProfile: 'pose_plus_hand',
  anatomicalSide: 'left',
  decisionScope: 'experimental_rule_based_visible_faults',
  summary: {
    totalReps: 3,
    correctRepCount: 1,
    incorrectRepCount: 1,
    cannotAssessRepCount: 1,
    incompleteRepCount: 0,
    wrongByBodyRegion: { left_hand: 1 },
    wrongBySeverity: { medium: 1 },
  },
  repetitions: [
    {
      id: 'rep_1', repIndex: 1, outcome: 'correct', faultTags: [], bodyRegions: [], severity: null,
      assessableFrameCount: 8, skippedFrameCount: 0, skippedReasonCounts: {}, faultSignals: [],
    },
    {
      id: 'rep_2', repIndex: 2, outcome: 'incorrect', faultTags: ['incomplete_visible_finger_wrap'],
      bodyRegions: ['left_hand'], severity: 'medium', assessableFrameCount: 9, skippedFrameCount: 0,
      skippedReasonCounts: {},
      faultSignals: [{ kind: 'fault_observation', semanticID: 'incomplete_visible_finger_wrap', bodyRegion: 'left_hand', landmarkRefs: ['hand_5'], metric: { name: 'rule', value: 1, unit: 'boolean' }, severity: 'medium', confidence: 0.75, sourceEngine: 'local_rule' }],
    },
    {
      id: 'rep_3', repIndex: 3, outcome: 'cannot_assess', faultTags: [], bodyRegions: [], severity: null,
      assessableFrameCount: 1, skippedFrameCount: 4, skippedReasonCounts: { missing_hand: 4 }, faultSignals: [],
    },
  ],
  claimBoundary: {
    experimental: true, clinicalDecision: false, patientFacingApproved: false,
    rawMediaPersisted: false, rawLandmarksPersisted: false,
  },
};

test('reads a valid local rule-based session into visualizer-ready summary data', () => {
  const result = readRuleBasedSessionJSON(JSON.stringify(sample));

  assert.equal(result.valid, true);
  assert.deepEqual(result.errors, []);
  assert.equal(result.view.totalReps, 3);
  assert.equal(result.view.incorrectRepCount, 1);
  assert.deepEqual(result.view.wrongByBodyRegion, [{ label: 'left_hand', count: 1 }]);
  assert.equal(result.view.repetitions[1].severity, 'medium');
});

test('rejects a JSON record that contains raw landmark coordinates', () => {
  const unsafe = structuredClone(sample);
  unsafe.repetitions[1].faultSignals[0].rawLandmarks = [{ x: 0.1, y: 0.2 }];

  const result = readRuleBasedSessionJSON(JSON.stringify(unsafe));
  assert.equal(result.valid, false);
  assert.match(result.errors.join(' '), /raw/i);
});

test('rejects a JSON record that carries a patient identifier', () => {
  const unsafe = structuredClone(sample);
  unsafe.patientId = 'patient-123';

  const result = readRuleBasedSessionJSON(JSON.stringify(unsafe));
  assert.equal(result.valid, false);
  assert.match(result.errors.join(' '), /private|patient/i);
});

test('rejects an incompatible exercise contract instead of rendering it as Bottle Grab', () => {
  const incompatible = structuredClone(sample);
  incompatible.exerciseID = 'other_exercise';

  const result = readRuleBasedSessionJSON(JSON.stringify(incompatible));
  assert.equal(result.valid, false);
  assert.match(result.errors.join(' '), /exerciseID/i);
});

test('reads an adapter-ready Sit-to-Stand rule-based session without treating it as Bottle Grab', () => {
  const sitToStand = structuredClone(sample);
  sitToStand.schema = 'physioai.rule_based_sit_to_stand_session.v1';
  sitToStand.moduleID = 'sit_to_stand_rule_based_evidence_v1';
  sitToStand.moduleVersion = '1.0.0-dev';
  sitToStand.exerciseID = 'sit_to_stand';
  sitToStand.trackingProfile = 'pose_only';
  sitToStand.anatomicalSide = 'bilateral';
  sitToStand.decisionScope = 'experimental_rule_based_visible_form';
  sitToStand.summary = {
    totalReps: 1,
    correctRepCount: 0,
    incorrectRepCount: 1,
    cannotAssessRepCount: 0,
    incompleteRepCount: 0,
    wrongByBodyRegion: { trunk: 1 },
    wrongBySeverity: { high: 1 },
  };
  sitToStand.repetitions = [{
    id: 'rep_1', repIndex: 1, outcome: 'incorrect', faultTags: ['trunk_view_plane_tilt'],
    bodyRegions: ['trunk'], severity: 'high', assessableFrameCount: 8, skippedFrameCount: 0,
    skippedReasonCounts: {},
    faultSignals: [{ kind: 'fault_observation', semanticID: 'trunk_view_plane_tilt', bodyRegion: 'trunk', landmarkRefs: [], metric: { name: 'trunk_view_plane_tilt_deg', value: 40, unit: 'degrees' }, severity: 'high', confidence: 1, sourceEngine: 'sit_to_stand_rule_based_evidence_v1' }],
  }];

  const result = readRuleBasedSessionJSON(JSON.stringify(sitToStand));
  assert.equal(result.valid, true);
  assert.equal(result.record.exerciseID, 'sit_to_stand');
  assert.deepEqual(result.view.wrongByBodyRegion, [{ label: 'trunk', count: 1 }]);
});

test('visualizer copy declares both supported local exercise contracts', () => {
  const here = path.dirname(fileURLToPath(import.meta.url));
  const visualizer = fs.readFileSync(path.join(here, '..', 'rule-json-visualizer.html'), 'utf8');
  assert.match(visualizer, /Bottle Grab and Sit-to-Stand/);
});
