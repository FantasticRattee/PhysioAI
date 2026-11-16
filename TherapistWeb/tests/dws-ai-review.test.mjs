import assert from 'node:assert/strict';
import test from 'node:test';
import { generateSessionReview, sessionReviewSystemPrompt, SESSION_REVIEW_SYSTEM_PROMPT, DWS_SESSION_REVIEW_SYSTEM_PROMPT } from '../utils/sessionReview/llm.js';

test('only the exact DWS exercise uses the patient-friendly prompt', () => {
  assert.equal(sessionReviewSystemPrompt({ exercise: { id: 'cust_dynamic_weight_shifts' } }), DWS_SESSION_REVIEW_SYSTEM_PROMPT);
  for (const input of [undefined, {}, { exercise: { id: 'sit_to_stand' } }, { dwsMetrics: {} }]) {
    assert.equal(sessionReviewSystemPrompt(input), SESSION_REVIEW_SYSTEM_PROMPT);
  }
});

test('DWS prompt keeps supportive comments grounded in available measurements', () => {
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /never claim to be a human therapist/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /Missing metrics are unknown, not zero/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /no direct excessive-movement measure/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /If one/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /two or more/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /array of exactly 1 short string/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /praise is optional/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /not a fixed praise-caution-advice template/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /each field adds something new/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /No previous comments are supplied/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /Do not mention fallback, AI\/rule disagreement/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /Do not replace those details with a claim that AI confirmed every rep/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /If below target/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /Omit assessments of unavailable metrics instead/);
  assert.match(DWS_SESSION_REVIEW_SYSTEM_PROMPT, /Never turn missing values into zero/);
});

test('DWS review sends measured events to the LLM without inventing quality scores', async () => {
  const savedFetch = globalThis.fetch;
  const savedKey = process.env.LLM_API_KEY;
  process.env.LLM_API_KEY = 'test-only';
  let requestBody;
  globalThis.fetch = async (_url, options) => {
    requestBody = JSON.parse(options.body);
    return { ok: true, json: async () => ({ choices: [{ message: { content: JSON.stringify({
      summary: 'ฝึกสำเร็จ 2 จาก 4 ครั้ง', observations: ['ค้างไม่ครบ 1 เหตุการณ์'], focusNextSession: ['รักษาแนวไหล่ตามคำแนะนำ'],
    }) } }] }) };
  };
  try {
    const input = { exercise: { id: 'cust_dynamic_weight_shifts' }, completedReps: 2, poseScore: null, dwsMetrics: {
      schema: 'physioai.dws-session.v1', targetReps: 4, correctReps: 1,
      ruleFallbackReps: 1, incompleteHolds: 1, shoulderTiltEpisodes: 1, trackingInterruptions: 2,
    } };
    const review = await generateSessionReview(input);
    assert.equal(requestBody.messages[0].content, DWS_SESSION_REVIEW_SYSTEM_PROMPT);
    assert.deepEqual(JSON.parse(requestBody.messages[1].content.split('\n').slice(1).join('\n')), input);
    assert.match(requestBody.messages[0].content, /not excessive torso lean/);
    assert.match(requestBody.messages[0].content, /must not be summed as failed reps/);
    assert.equal(review.summary, 'ฝึกสำเร็จ 2 จาก 4 ครั้ง');
    assert.equal(requestBody.messages[1].content.includes('test-only'), false);
  } finally {
    globalThis.fetch = savedFetch;
    if (savedKey === undefined) delete process.env.LLM_API_KEY;
    else process.env.LLM_API_KEY = savedKey;
  }
});
