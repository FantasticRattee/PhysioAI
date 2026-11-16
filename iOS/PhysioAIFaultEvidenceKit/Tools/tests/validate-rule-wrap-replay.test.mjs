import assert from 'node:assert/strict';
import test from 'node:test';

import { sessionFromRuleWrapReplay } from '../validate-rule-wrap-replay.mjs';

test('converts frozen replay output without exporting a source clip identifier', () => {
  const session = sessionFromRuleWrapReplay({
    version: '1.9.0-dev-calibration-3-rule-wrap-hybrid-1',
    results: [{
      clipId: 'source-video-should-not-leave-the-replay',
      repetition: 9,
      assessable: true,
      predictedTags: ['finger'],
      expectedTags: ['finger'],
      ruleEvidence: { assessableFrameCount: 8 },
    }],
  });

  assert.equal(session.repetitions[0].id, 'rep_1');
  assert.doesNotMatch(JSON.stringify(session), /source-video-should-not-leave-the-replay/);
});
