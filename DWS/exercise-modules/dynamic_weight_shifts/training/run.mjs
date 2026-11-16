#!/usr/bin/env node

import { fileURLToPath } from 'node:url';
import path from 'node:path';
import { dynamicWeightShiftsTrainingProfile } from './profile.mjs';
import {
  exerciseTrainingUsage,
  parseExerciseTrainingArgs,
  runExerciseTraining,
} from '../../training/runner.mjs';

export async function runDynamicWeightShiftsTraining(argv = process.argv.slice(2)) {
  const args = parseExerciseTrainingArgs(argv);
  if (args.help) return { help: exerciseTrainingUsage() };
  if (!args.runId) throw new Error('--run is required');
  return runExerciseTraining(dynamicWeightShiftsTrainingProfile, args);
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  runDynamicWeightShiftsTraining()
    .then((summary) => console.log(summary.help || JSON.stringify(summary, null, 2)))
    .catch((error) => {
      console.error(error.message);
      process.exitCode = 1;
    });
}
