#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { extractMotionFeatures } from '../shared/ai/MotionFeatureExtractor.js';

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const outIndex = process.argv.indexOf('--out');
if (outIndex >= 0 && !process.argv[outIndex + 1]) throw new Error('--out requires a path');
const outputPath = outIndex >= 0
  ? path.resolve(process.argv[outIndex + 1])
  : path.resolve(scriptDir, '../artifacts/dws_feature_parity.json');
const landmarks = Array.from({ length: 33 }, (_, index) => ({
  x: 0.5,
  y: 0.5 + index * 0.0001,
  z: index * -0.001,
  visibility: 0.99,
}));
Object.assign(landmarks[7], { x: 0.62, y: 0.20 });
Object.assign(landmarks[8], { x: 0.38, y: 0.20 });
Object.assign(landmarks[11], { x: 0.68, y: 0.33, z: -0.08, visibility: 0.96 });
Object.assign(landmarks[12], { x: 0.32, y: 0.35, z: -0.06, visibility: 0.97 });
Object.assign(landmarks[15], { x: 0.78, y: 0.62 });
Object.assign(landmarks[16], { x: 0.22, y: 0.62 });
Object.assign(landmarks[23], { x: 0.61, y: 0.62, z: -0.03, visibility: 0.98 });
Object.assign(landmarks[24], { x: 0.39, y: 0.64, z: -0.02, visibility: 0.99 });
Object.assign(landmarks[25], { x: 0.60, y: 0.78 });
Object.assign(landmarks[26], { x: 0.40, y: 0.78 });
Object.assign(landmarks[27], { x: 0.59, y: 0.92 });
Object.assign(landmarks[28], { x: 0.41, y: 0.92 });

const result = extractMotionFeatures({ tMs: 1000, landmarks }, {
  landmarkSchemaId: 'seated_balance.v2',
  derivedFeatureContract: 'dynamic_weight_shifts_torso_geometry.v1',
  screenMirrorX: false,
});
await fs.mkdir(path.dirname(outputPath), { recursive: true });
await fs.writeFile(outputPath, JSON.stringify({ landmarks, expected: result.featureVector }));
console.log(JSON.stringify({ ok: true, featureSize: result.featureVector.length, out: outputPath }, null, 2));
