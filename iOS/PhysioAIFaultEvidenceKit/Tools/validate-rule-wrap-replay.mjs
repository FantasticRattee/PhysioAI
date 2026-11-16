#!/usr/bin/env node

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

import { RULE_BASED_SESSION_SCHEMA } from './rule-json-reader.mjs';

const TAG_METADATA = Object.freeze({
  finger: {
    semanticID: 'incomplete_visible_finger_wrap',
    bodyRegion: 'left_hand',
    landmarkRefs: ['hand_5', 'hand_20'],
    severity: 'medium',
  },
  shoulder: {
    semanticID: 'working_shoulder_elevation',
    bodyRegion: 'left_shoulder',
    landmarkRefs: ['pose_11', 'pose_7'],
    severity: 'medium',
  },
});

function sorted(values) {
  return [...new Set(values)].sort();
}

function severityFor(tags) {
  return tags.length >= 2 ? 'high' : tags.length === 1 ? 'medium' : null;
}

function signalFor(tag, version) {
  const meta = TAG_METADATA[tag];
  if (!meta) throw new Error(`Unsupported Rule-Wrap tag: ${tag}`);
  return {
    kind: 'fault_observation',
    semanticID: meta.semanticID,
    bodyRegion: meta.bodyRegion,
    landmarkRefs: meta.landmarkRefs,
    metric: { name: `rule_wrap_${tag}_qualified`, value: 1, unit: 'boolean' },
    severity: meta.severity,
    confidence: 0.75,
    sourceEngine: `bottle_grab_rule_wrap_hybrid_v1@${version}`,
  };
}

function aggregate(repetitions) {
  const summary = {
    totalReps: repetitions.length,
    correctRepCount: 0,
    incorrectRepCount: 0,
    cannotAssessRepCount: 0,
    incompleteRepCount: 0,
    wrongByBodyRegion: {},
    wrongBySeverity: {},
  };
  for (const repetition of repetitions) {
    if (repetition.outcome === 'correct') summary.correctRepCount += 1;
    if (repetition.outcome === 'incorrect') {
      summary.incorrectRepCount += 1;
      for (const region of repetition.bodyRegions) {
        summary.wrongByBodyRegion[region] = (summary.wrongByBodyRegion[region] || 0) + 1;
      }
      if (repetition.severity) {
        summary.wrongBySeverity[repetition.severity] = (summary.wrongBySeverity[repetition.severity] || 0) + 1;
      }
    }
    if (repetition.outcome === 'cannot_assess') summary.cannotAssessRepCount += 1;
    if (repetition.outcome === 'incomplete') summary.incompleteRepCount += 1;
  }
  return summary;
}

export function sessionFromRuleWrapReplay(replay) {
  if (!Array.isArray(replay?.results)) throw new Error('Rule-Wrap replay must contain results[]');
  const version = String(replay.version || 'unknown');
  const repetitions = replay.results.map((row, index) => {
    const tags = sorted((row.predictedTags || []).filter((tag) => TAG_METADATA[tag]));
    const outcome = row.assessable === false
      ? 'cannot_assess'
      : tags.length ? 'incorrect' : 'correct';
    const signals = outcome === 'incorrect' ? tags.map((tag) => signalFor(tag, version)) : [];
    return {
      // The portable session deliberately uses an ordinal only. Source clip
      // IDs are replay provenance, not a field for a downstream app result.
      id: `rep_${index + 1}`,
      repIndex: index + 1,
      outcome,
      faultTags: signals.map((signal) => signal.semanticID),
      bodyRegions: sorted(signals.map((signal) => signal.bodyRegion)),
      severity: severityFor(tags),
      assessableFrameCount: row.assessable === false ? 0 : Number(row.ruleEvidence?.assessableFrameCount || 0),
      skippedFrameCount: row.assessable === false ? 1 : 0,
      skippedReasonCounts: row.assessable === false ? { replay_not_assessable: 1 } : {},
      faultSignals: signals,
    };
  });
  return {
    schema: RULE_BASED_SESSION_SCHEMA,
    moduleID: 'bottle_grab_rule_based_session_v8_local',
    moduleVersion: '0.1.0-dev',
    exerciseID: 'bottle_grab',
    trackingProfile: 'pose_plus_hand',
    anatomicalSide: 'left',
    decisionScope: 'experimental_rule_based_visible_faults',
    summary: aggregate(repetitions),
    repetitions,
    claimBoundary: {
      experimental: true,
      clinicalDecision: false,
      patientFacingApproved: false,
      rawMediaPersisted: false,
      rawLandmarksPersisted: false,
    },
  };
}

export function evaluateRuleWrapReplay(replay, session) {
  let truePositive = 0;
  let trueNegative = 0;
  let falsePositive = 0;
  let falseNegative = 0;
  let exactTagAgreement = 0;
  for (let index = 0; index < replay.results.length; index += 1) {
    const source = replay.results[index];
    const expected = sorted((source.expectedTags || []).filter((tag) => TAG_METADATA[tag]));
    const predicted = sorted((source.predictedTags || []).filter((tag) => TAG_METADATA[tag]));
    if (expected.join('|') === predicted.join('|')) exactTagAgreement += 1;
    const actualWrong = expected.length > 0;
    const predictedWrong = session.repetitions[index].outcome === 'incorrect';
    if (actualWrong && predictedWrong) truePositive += 1;
    if (!actualWrong && !predictedWrong) trueNegative += 1;
    if (!actualWrong && predictedWrong) falsePositive += 1;
    if (actualWrong && !predictedWrong) falseNegative += 1;
  }
  const total = replay.results.length;
  const precision = truePositive + falsePositive
    ? truePositive / (truePositive + falsePositive) : null;
  const recall = truePositive + falseNegative
    ? truePositive / (truePositive + falseNegative) : null;
  return {
    schema: 'physioai.rule_based_bottle_grab_validation.v1',
    inputReplaySchema: replay.schema || null,
    inputReplayVersion: replay.version || null,
    repetitionBoundaryStatus: 'not_evaluated_by_this_replay',
    labelUsage: 'comparison_only_after_rule_output',
    totalRepetitions: total,
    exactTagAgreement,
    exactTagAgreementPercent: total ? (exactTagAgreement / total) * 100 : null,
    binaryWrongVsNominal: {
      truePositive,
      trueNegative,
      falsePositive,
      falseNegative,
      accuracy: total ? (truePositive + trueNegative) / total : null,
      precision,
      recall,
      f1: precision != null && recall != null && precision + recall > 0
        ? (2 * precision * recall) / (precision + recall) : null,
    },
    expected: {
      correctRepCount: trueNegative + falsePositive,
      incorrectRepCount: truePositive + falseNegative,
    },
    predicted: {
      correctRepCount: session.summary.correctRepCount,
      incorrectRepCount: session.summary.incorrectRepCount,
      cannotAssessRepCount: session.summary.cannotAssessRepCount,
    },
  };
}

function sha256(pathname) {
  return crypto.createHash('sha256').update(fs.readFileSync(pathname)).digest('hex');
}

function argumentsFrom(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    if (!argv[index].startsWith('--')) continue;
    const key = argv[index].slice(2);
    const value = argv[index + 1];
    if (!value || value.startsWith('--')) throw new Error(`Missing value for --${key}`);
    values[key] = value;
    index += 1;
  }
  return values;
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const args = argumentsFrom(process.argv.slice(2));
  if (!args.replay || !args.sessionOut || !args.validationOut) {
    throw new Error('usage: node validate-rule-wrap-replay.mjs --replay <replay.json> --sessionOut <session.json> --validationOut <validation.json>');
  }
  const replay = JSON.parse(fs.readFileSync(args.replay, 'utf8'));
  const session = sessionFromRuleWrapReplay(replay);
  const validation = {
    replay: { path: args.replay, sha256: sha256(args.replay) },
    session,
    evaluation: evaluateRuleWrapReplay(replay, session),
  };
  fs.writeFileSync(args.sessionOut, `${JSON.stringify(session, null, 2)}\n`, 'utf8');
  fs.writeFileSync(args.validationOut, `${JSON.stringify(validation, null, 2)}\n`, 'utf8');
  console.log(JSON.stringify(validation.evaluation, null, 2));
}
