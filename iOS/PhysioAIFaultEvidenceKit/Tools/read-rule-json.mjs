#!/usr/bin/env node

import fs from 'node:fs';
import process from 'node:process';

import { readRuleBasedSessionJSON } from './rule-json-reader.mjs';

const pathname = process.argv[2];
if (!pathname) {
  throw new Error('usage: node read-rule-json.mjs <rule-based-session.json>');
}
const result = readRuleBasedSessionJSON(fs.readFileSync(pathname, 'utf8'));
if (!result.valid) {
  process.stderr.write(`${result.errors.join('\n')}\n`);
  process.exitCode = 1;
} else {
  process.stdout.write(`${JSON.stringify(result.view, null, 2)}\n`);
}
