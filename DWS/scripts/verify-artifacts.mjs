#!/usr/bin/env node
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('../', import.meta.url));
const repoRoot = path.resolve(root, '..');
const manifest = JSON.parse(await readFile(path.join(root, 'artifact-manifest.json'), 'utf8'));
for (const file of manifest.files) {
  const absolute = path.resolve(root, file.path);
  const relative = path.relative(repoRoot, absolute);
  assert(!relative.startsWith('..') && !path.isAbsolute(relative), `Path outside repository: ${file.path}`);
  const bytes = await readFile(absolute);
  assert.equal(bytes.length, file.bytes, `Size mismatch: ${file.path}`);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), file.sha256, `Hash mismatch: ${file.path}`);
}
const dataRoot = path.join(root, 'data/local/exercises/dynamic_weight_shifts__cust_dynamic_weight_shifts');
const records = (await readdir(path.join(dataRoot, 'datasets')))
  .filter(name => name.endsWith('.json') && name !== 'index.json');
assert.equal(records.length, manifest.datasetRecords);
const frozen = JSON.parse(await readFile(path.join(dataRoot, 'training_runs/left-tcn-v3/features.json'), 'utf8'));
assert.deepEqual(frozen.inputShape, [30, 23]);
assert.deepEqual(frozen.phases, ['rest', 'target']);
assert.deepEqual(frozen.qualities, ['correct_left', 'wrong_left']);
assert.equal(frozen.samples.length, manifest.frozenFeatureWindows);
const native = JSON.parse(await readFile(path.join(repoRoot,
  'iOS/Modules/PhysioAIDynamicWeightShiftSDK/Resources/dws_manifest.json'), 'utf8'));
assert.equal(native.version, manifest.modelVersion);
assert.deepEqual(native.inputShape, frozen.inputShape);
console.log(JSON.stringify({
  ok: true, checkedFiles: manifest.files.length, datasetRecords: records.length,
  frozenFeatureWindows: frozen.samples.length, modelVersion: native.version,
  inputShape: frozen.inputShape,
}, null, 2));
