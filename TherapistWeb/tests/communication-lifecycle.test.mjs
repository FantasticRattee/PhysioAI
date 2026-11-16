import assert from 'node:assert/strict';
import test from 'node:test';
import { readFile } from 'node:fs/promises';
import { callDurationSeconds, callHistoryDetail, endedCallSignals, isCallEnded, mergeCallHistory, transitionCall } from '../utils/callLifecycle.js';

test('talk duration excludes ringing and formats hours, minutes and seconds', () => {
  const call = { created_at: '2026-09-10T00:00:00Z', connected_at: '2026-09-10T00:01:00Z', ended_at: '2026-09-10T01:25:35Z', status: 'ended' };
  assert.equal(callDurationSeconds(call), 5075);
  assert.equal(callHistoryDetail(call, true), '1 ชม. 24 นาที 35 วิ');
  assert.equal(callHistoryDetail({ ...call, ended_at: call.connected_at }, false), '0 วิ');
  for (const connected_at of [null, 'bad-date', '2026-09-11T00:00:00Z']) {
    assert.equal(callDurationSeconds({ ...call, connected_at }), null);
  }
  assert.equal(callHistoryDetail({ status: 'ended' }, false), 'สิ้นสุดการโทร');
  assert.equal(callHistoryDetail({ status: 'cancelled' }, false), 'สายที่ไม่ได้รับ');
  assert.equal(callHistoryDetail({ status: 'cancelled' }, true), 'ไม่ได้รับสาย');
});

test('both participants receive a durable terminal hangup even when no transient signal exists', () => {
  const call = { id: 'call', status: 'ended', patient_id: 'p', therapist_id: 't', ended_at: '2026-09-10T01:00:00Z' };
  assert.equal(endedCallSignals(call, 'p')[0].sender_id, 't');
  assert.equal(endedCallSignals(call, 't')[0].sender_id, 'p');
  assert.equal(endedCallSignals(call, 'p')[0].signal_type, 'hangup');
  assert.equal(isCallEnded({ status: 'cancelled' }), true);
  assert.deepEqual(endedCallSignals({ ...call, status: 'live' }, 'p'), []);
});

test('a delayed history poll does not remove the new call card or duplicate it', () => {
  const call = { id: 'call', created_at: '2026-09-10T01:00:00Z', status: 'ended' };
  assert.deepEqual(mergeCallHistory([call], []), [call]);
  assert.deepEqual(mergeCallHistory([call], [call]), [call]);
});

test('ending a call only updates active states and retries read the unchanged terminal row', async () => {
  const calls = [];
  const terminal = { id: 'call', status: 'ended', ended_at: 'fixed' };
  const supabase = { from(table) {
    const query = { table };
    const builder = {
      update(value) { query.update = value; return this; }, select() { return this; },
      eq(key, value) { query[key] = value; return this; }, in(key, value) { query.in = [key, value]; return this; },
      async maybeSingle() { calls.push(query); return { data: query.update ? null : terminal, error: null }; },
    };
    return builder;
  } };
  assert.equal(await transitionCall(supabase, 'call', 'ended'), terminal);
  assert.deepEqual(calls[0].in, ['status', ['ringing', 'live']]);
  assert.deepEqual(calls[0].update, { status: 'ended' });
  assert.equal(calls[1].id, 'call');
});

test('terminal polls remain readable and a late join cannot resurrect the call', async () => {
  const signals = await readFile(new URL('../app/api/cloudflare/signals/route.js', import.meta.url), 'utf8');
  const calls = await readFile(new URL('../app/api/cloudflare/calls/route.js', import.meta.url), 'utf8');
  assert.ok(signals.indexOf('if (isCallEnded(call)) return NextResponse.json') < signals.indexOf("from('communication_call_signals')"));
  assert.match(signals, /endedCallSignals\(call, profile.id\)/);
  assert.doesNotMatch(calls.slice(0, calls.indexOf('export async function GET')), /update\(\{ status: 'live'/);
  assert.match(calls, /eq\('patient_id', patientId\)\.or/);
  const sql = await readFile(new URL('../../supabase/migrations/20260910093405_finalize_communication_call_history.sql', import.meta.url), 'utf8');
  assert.match(sql, /old.status in \('ended', 'cancelled'\)/);
  assert.match(sql, /new.ended_at := old.ended_at/);
  assert.match(sql, /security invoker/);
  assert.doesNotMatch(sql, /security definer|disable row level security/i);
});
