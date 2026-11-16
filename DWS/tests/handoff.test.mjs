import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { extractMotionFeatures } from '../shared/ai/MotionFeatureExtractor.js';

const root = fileURLToPath(new URL('../', import.meta.url));

test('the training extractor matches the fixture shipped with the native DWS SDK', async () => {
  const fixture = JSON.parse(await readFile(new URL(
    '../../iOS/NativeTests/Fixtures/dws_feature_parity.json', import.meta.url), 'utf8'));
  const result = extractMotionFeatures({ tMs: 1000, landmarks: fixture.landmarks }, {
    landmarkSchemaId: 'seated_balance.v2',
    derivedFeatureContract: 'dynamic_weight_shifts_torso_geometry.v1',
    screenMirrorX: false,
  });
  assert.equal(result.featureVector.length, 23);
  for (let index = 0; index < 23; index++) {
    assert(Math.abs(result.featureVector[index] - fixture.expected[index]) < 1e-7,
      `Feature ${index} differs from the native fixture`);
  }
});

test('running a training stage cannot overwrite the frozen left-tcn-v3 snapshot', async () => {
  const artifact = new URL('../data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts/training_runs/left-tcn-v3/exercise.resolved.json', import.meta.url);
  const before = await readFile(artifact);
  const result = spawnSync(process.execPath, [
    'exercise-modules/dynamic_weight_shifts/training/run_left.mjs',
    '--run', 'left-tcn-v3', '--stage', 'features',
  ], { cwd: root, encoding: 'utf8' });
  assert.equal(result.status, 1);
  assert.match(result.stderr, /frozen shipped-model record/);
  assert.deepEqual(await readFile(artifact), before);
});
