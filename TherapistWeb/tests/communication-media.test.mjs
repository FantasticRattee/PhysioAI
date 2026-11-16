import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { callMediaConstraints, requestedCallMedia } from '../utils/callMedia.js';
import { CALL_FIELDS } from '../utils/callLifecycle.js';

test('new calls accept only audio/video and preserve legacy video clients', () => {
  assert.equal(requestedCallMedia(undefined), 'video');
  assert.equal(requestedCallMedia('audio'), 'audio');
  assert.equal(requestedCallMedia('video'), 'video');
  for (const invalid of [null, '', 'Audio', 'screen', {}, 1, false]) assert.equal(requestedCallMedia(invalid), null);
});

test('voice calls request a microphone without requesting a camera', () => {
  assert.deepEqual(callMediaConstraints('audio'), {
    audio: { echoCancellation: true, noiseSuppression: true }, video: false,
  });
  assert.equal(callMediaConstraints('video').video.facingMode, 'user');
  assert.deepEqual(callMediaConstraints(undefined), callMediaConstraints('video'));
});

test('join/refresh return the stored media type and incoming calls expose it', async () => {
  const route = await readFile(new URL('../app/api/cloudflare/calls/route.js', import.meta.url), 'utf8');
  assert.match(route, /media_type: mediaType/);
  assert.match(route, /mediaType: call\.media_type/);
  const joining = route.slice(route.indexOf('if (requestedCallId)'), route.indexOf('} else {'));
  assert.match(joining, /signaling_session_id, media_type/);
  assert.doesNotMatch(joining, /update\([^)]*media_type/);
  assert.match(route.slice(route.indexOf('export async function GET')), /select\(CALL_FIELDS\)/);
  assert.match(CALL_FIELDS, /media_type/);
});

test('migration defaults old calls to video and prevents switching audio calls to video', async () => {
  const sql = await readFile(new URL('../../supabase/migrations/20260910065201_add_communication_audio_calls.sql', import.meta.url), 'utf8');
  assert.match(sql, /media_type text not null default 'video'/);
  assert.match(sql, /check \(media_type in \('audio', 'video'\)\)/);
  assert.match(sql, /new\.media_type is distinct from old\.media_type/);
  assert.doesNotMatch(sql, /disable row level security|security definer|drop policy/i);
});

test('native audio calls skip camera capture and video negotiation', async () => {
  const native = await readFile(new URL('../../iOS/PhysioAINative/NativeWebRTCCallPresenter.swift', import.meta.url), 'utf8');
  assert.match(native, /if !isAudioOnly \{[\s\S]*?RTCCameraVideoCapturer/);
  assert.match(native, /private func startCapture\(\) async throws \{[\s\S]*?guard !isAudioOnly else \{ return \}/);
  assert.equal((native.match(/"OfferToReceiveVideo": isAudioOnly \? "false" : "true"/g) ?? []).length, 2);
  assert.match(native, /isAudioOnly \? \.voiceChat : \.videoChat/);
});
