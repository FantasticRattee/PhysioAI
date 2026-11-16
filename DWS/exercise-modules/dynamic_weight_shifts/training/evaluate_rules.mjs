#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  createDynamicWeightShiftsDecisionEngine,
  DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY,
} from '../runtime/rules.js';
import { dynamicWeightShiftMetrics } from '../runtime/metrics.js';

function parseArgs(argv = process.argv.slice(2)) {
  const options = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith('--')) continue;
    options[key.slice(2)] = argv[index + 1];
    index += 1;
  }
  return options;
}

function safeBoundary(frame = {}) {
  const scoreable = frame.safetyStatus !== 'blocked' && frame.dataQuality !== 'unusable';
  return {
    status: frame.boundaryStatus || (scoreable ? 'inside' : 'outside'),
    ok: scoreable,
    scoreable,
    dataQuality: frame.dataQuality || (scoreable ? 'usable' : 'unusable'),
  };
}

export function evaluateDynamicWeightShiftRules(rows = []) {
  const centerReturnThreshold = Number(DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY.restResetDeg);
  const shoulderTiltMaxDeg = Number(
    DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY.requiredJointRules
      .find((rule) => rule.joint === 'shoulder_tilt')?.reachedTargetMaxDeg,
  );
  const confusion = {
    trueReached: 0,
    falseReached: 0,
    trueNotReached: 0,
    falseNotReached: 0,
  };
  const reps = [];

  for (const row of rows) {
    const engine = createDynamicWeightShiftsDecisionEngine({
      decisionMode: 'rule',
      targetHoldMs: 0,
      fallbackHoldMs: 150,
      restHoldMs: 0,
    });
    let completion = null;
    let minimumPostTargetAngle = null;
    for (const frame of row.frames || []) {
      const metrics = dynamicWeightShiftMetrics(frame?.landmarks || []);
      const storedTrunkShift = Number(frame?.angles?.trunk_shift);
      const storedShoulderTilt = Number(frame?.angles?.shoulder_tilt);
      const trunkShift = Number.isFinite(storedTrunkShift)
        ? storedTrunkShift
        : metrics.valid ? metrics.trunkShiftDeg : null;
      const shoulderTilt = Number.isFinite(storedShoulderTilt)
        ? storedShoulderTilt
        : metrics.valid ? metrics.shoulderTiltDeg : null;
      const snapshot = engine.push({
        timestamp: Number(frame.t || 0),
        jointAngles: {
          trunk_shift: trunkShift,
          shoulder_tilt: shoulderTilt,
        },
        boundary: safeBoundary(frame),
      });
      completion ||= snapshot.completedRep || null;
      if (completion && Number.isFinite(trunkShift)) {
        minimumPostTargetAngle = minimumPostTargetAngle == null
          ? trunkShift
          : Math.min(minimumPostTargetAngle, trunkShift);
      }
    }

    const returnedToCenter = Boolean(completion) &&
      Number.isFinite(minimumPostTargetAngle) && minimumPostTargetAngle <= centerReturnThreshold;
    const predictedReached = Boolean(completion && returnedToCenter);
    const expectedReached = row.label === 'reached_target';
    if (expectedReached && predictedReached) confusion.trueReached += 1;
    else if (!expectedReached && predictedReached) confusion.falseReached += 1;
    else if (!expectedReached) confusion.trueNotReached += 1;
    else confusion.falseNotReached += 1;
    reps.push({
      repId: row.repId,
      expectedReached,
      predictedReached,
      returnedToCenter,
      minimumPostTargetAngleDeg: minimumPostTargetAngle,
      completion: completion ? {
        ...completion,
        returnAngle: minimumPostTargetAngle,
        returnedToCenter,
      } : null,
    });
  }

  const total = rows.length;
  const reachedTotal = confusion.trueReached + confusion.falseNotReached;
  const notReachedTotal = confusion.trueNotReached + confusion.falseReached;
  const metrics = {
    repAccuracy: total ? (confusion.trueReached + confusion.trueNotReached) / total : 0,
    reachedRecall: reachedTotal ? confusion.trueReached / reachedTotal : 0,
    notReachedRecall: notReachedTotal ? confusion.trueNotReached / notReachedTotal : 0,
    falseReachedRate: notReachedTotal ? confusion.falseReached / notReachedTotal : 0,
  };
  return {
    schema: 'physioai.dynamic_weight_shifts_rule_evaluation.v1',
    sampleCount: total,
    targetThresholdDeg: Number(DYNAMIC_WEIGHT_SHIFTS_TARGET_POLICY.reachedTargetMinDeg),
    shoulderTiltMaxDeg,
    centerReturnThresholdDeg: centerReturnThreshold,
    targetHoldMs: 150,
    restHoldMs: 0,
    confusion,
    metrics,
    passed: metrics.repAccuracy === 1 && metrics.falseReachedRate === 0,
    reps,
  };
}

async function main() {
  const args = parseArgs();
  if (!args.dataset || !args.out) {
    throw new Error('Usage: --dataset <dataset.jsonl> --out <rule-evaluation.json>');
  }
  const rows = (await readFile(path.resolve(args.dataset), 'utf8'))
    .split(/\r?\n/)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  const result = evaluateDynamicWeightShiftRules(rows);
  await writeFile(path.resolve(args.out), `${JSON.stringify(result, null, 2)}\n`, 'utf8');
  console.log(JSON.stringify({
    ...result,
    reps: undefined,
    out: path.resolve(args.out),
  }, null, 2));
  if (!result.passed) process.exitCode = 1;
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isMain) {
  main().catch((error) => {
    console.error(error?.stack || error);
    process.exitCode = 1;
  });
}
