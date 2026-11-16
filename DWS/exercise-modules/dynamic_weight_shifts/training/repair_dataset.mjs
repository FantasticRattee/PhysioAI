#!/usr/bin/env node

import { readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { prepareDynamicWeightShiftDatasetRow } from '../runtime/datasetReview.js';

export async function repairDynamicWeightShiftDatasetDirectory(datasetDir) {
  const indexPath = path.join(datasetDir, 'index.json');
  const existingIndex = JSON.parse(await readFile(indexPath, 'utf8'));
  const existingById = new Map(existingIndex.map((row) => [row.id, row]));
  const files = (await readdir(datasetDir))
    .filter((file) => file.endsWith('.json') && file !== 'index.json')
    .sort();
  const repairedRows = [];

  for (const file of files) {
    const filePath = path.join(datasetDir, file);
    const source = JSON.parse(await readFile(filePath, 'utf8'));
    const repaired = prepareDynamicWeightShiftDatasetRow(source);
    await writeFile(filePath, `${JSON.stringify(repaired, null, 2)}\n`);
    repairedRows.push(repaired);
  }

  const summaries = repairedRows.map((row) => {
    const { frames, ...summary } = row;
    return {
      ...existingById.get(row.id),
      ...summary,
      frameCount: frames.length,
    };
  });
  await writeFile(indexPath, `${JSON.stringify(summaries, null, 2)}\n`);
  return {
    ok: true,
    datasetDir,
    rows: repairedRows.length,
    frames: repairedRows.reduce((total, row) => total + row.frames.length, 0),
    schemaIds: [...new Set(repairedRows.map((row) => row.landmarkSchemaId))],
    featureContract: 'shoulder_hip_landmarks_only.v1',
  };
}

if (fileURLToPath(import.meta.url) === process.argv[1]) {
  const datasetDir = process.argv[2];
  if (!datasetDir) throw new Error('Usage: repair_dataset.mjs <dataset-directory>');
  repairDynamicWeightShiftDatasetDirectory(path.resolve(datasetDir))
    .then((summary) => console.log(JSON.stringify(summary, null, 2)))
    .catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
}
