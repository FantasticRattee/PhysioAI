import assert from 'node:assert/strict';
import test from 'node:test';
import { generateSessionReview, sessionReviewSystemPrompt, BOTTLE_GRAB_SESSION_REVIEW_SYSTEM_PROMPT, SESSION_REVIEW_SYSTEM_PROMPT, DWS_SESSION_REVIEW_SYSTEM_PROMPT } from '../utils/sessionReview/llm.js';

test('bottle prompt is isolated from DWS and other exercise prompts', () => {
  assert.equal(sessionReviewSystemPrompt({ exercise: { id: 'bottle_grab' } }), BOTTLE_GRAB_SESSION_REVIEW_SYSTEM_PROMPT);
  assert.equal(sessionReviewSystemPrompt({ exercise: { id: 'cust_dynamic_weight_shifts' } }), DWS_SESSION_REVIEW_SYSTEM_PROMPT);
  for (const id of ['sit_to_stand', 'bottle_grab_other', undefined]) {
    assert.equal(sessionReviewSystemPrompt({ exercise: { id } }), SESSION_REVIEW_SYSTEM_PROMPT);
  }
  assert.match(BOTTLE_GRAB_SESSION_REVIEW_SYSTEM_PROMPT, /Missing values are unknown, not zero/);
  assert.match(BOTTLE_GRAB_SESSION_REVIEW_SYSTEM_PROMPT, /without guessing why/);
  assert.match(BOTTLE_GRAB_SESSION_REVIEW_SYSTEM_PROMPT, /do not import shoulder-angle or five-second hold rules/);
});

test('bottle review request uses patient-facing instructions and preserves evidence', async () => {
  const oldFetch = globalThis.fetch;
  const oldKey = process.env.LLM_API_KEY;
  process.env.LLM_API_KEY = 'test-only';
  const input = { exercise: { id: 'bottle_grab' }, completedReps: 5, invalidReps: 3, overallScore: 78, poseScore: 88, motionScore: null };
  let sent;
  globalThis.fetch = async (_url, options) => {
    sent = JSON.parse(options.body);
    return { ok: true, json: async () => ({ choices: [{ message: { content: JSON.stringify({ summary: 'หยิบขวดสำเร็จ 5 ครั้งแล้วครับ', observations: ['มีบางครั้งที่ยังไม่ผ่านเกณฑ์'], focusNextSession: ['ค่อย ๆ เอื้อม หยิบ ปล่อย แล้วกลับท่าเดิมตามแผนฝึก'] }) } }] }) };
  };
  try {
    const result = await generateSessionReview(input);
    assert.equal(sent.messages[0].content, BOTTLE_GRAB_SESSION_REVIEW_SYSTEM_PROMPT);
    assert.deepEqual(JSON.parse(sent.messages[1].content.split('\n').slice(1).join('\n')), input);
    assert.equal(result.summary, 'หยิบขวดสำเร็จ 5 ครั้งแล้วครับ');
  } finally {
    globalThis.fetch = oldFetch;
    if (oldKey === undefined) delete process.env.LLM_API_KEY;
    else process.env.LLM_API_KEY = oldKey;
  }
});
