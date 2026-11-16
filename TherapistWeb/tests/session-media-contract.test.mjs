import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const read = (path) => readFile(new URL(path, import.meta.url), 'utf8');

test('session video index stays private and links one media session to exercise history', async () => {
  const migration = await read('../../supabase/migrations/20260831170722_create_private_session_media.sql');
  assert.match(migration, /enable row level security/i);
  assert.match(migration, /revoke all on table public\.exercise_session_media from anon, authenticated/i);
  assert.match(migration, /media_session_id uuid unique/i);
});

test('iPhone recorder is a passive sidecar and uploads resumable video directly to Drive', async () => {
  const camera = await read('../../iOS/PhysioAINative/CameraSession.swift');
  const recorder = await read('../../iOS/PhysioAINative/NativeSessionVideoRecorder.swift');
  const uploader = await read('../../iOS/PhysioAINative/NativeSessionMediaUploader.swift');
  assert.match(camera, /sessionVideoRecorder\?\.append\(sampleBuffer\)/);
  assert.match(recorder, /AVVideoCodecType\.h264/);
  assert.match(recorder, /segmentDurationSeconds = 60\.0/);
  assert.match(uploader, /Content-Range/);
  assert.match(uploader, /fromFile: asset\.fileURL/);
});

test('therapist playback requires an assigned pair and hides Google Drive URLs', async () => {
  const service = await read('../utils/sessionMedia/service.js');
  const workspace = await read('../src/SessionHistoryWorkspace.jsx');
  const page = await read('../app/therapist/history/page.jsx');
  assert.match(service, /therapist_patient_assignments/);
  assert.match(service, /playbackUrl: `\/api\/session-media\/file/);
  assert.doesNotMatch(service, /webViewLink|webContentLink/);
  assert.match(workspace, /ดูวิดีโอ/);
  assert.match(workspace, /<video/);
  assert.match(page, /media_session_id/);
});
