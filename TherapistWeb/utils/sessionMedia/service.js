import { createClient } from '@supabase/supabase-js';
import { getSupabaseConfig } from '../supabase/config.js';
import { createGoogleDriveClient, googleDriveConfigured } from './googleDrive.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_VIDEO_BYTES = 750 * 1024 * 1024;

function fail(message, status) {
  throw Object.assign(new Error(message), { status });
}

function adminClient() {
  const secretKey = String(process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
  if (!secretKey || !googleDriveConfigured()) fail('session_media_not_configured', 503);
  const { url } = getSupabaseConfig();
  return createClient(url, secretKey, { auth: { autoRefreshToken: false, persistSession: false } });
}

function cleanInteger(value, min, max) {
  const number = Number(value);
  return Number.isInteger(number) && number >= min && number <= max ? number : null;
}

async function mediaRow(db, id) {
  if (!UUID_PATTERN.test(String(id || ''))) fail('invalid_media_session_id', 400);
  const { data, error } = await db.from('exercise_session_media').select('*').eq('id', id).maybeSingle();
  if (error) throw error;
  if (!data) fail('media_session_not_found', 404);
  return data;
}

async function requireOwner(db, profile, id) {
  const row = await mediaRow(db, id);
  if (profile.role !== 'patient' || row.patient_id !== profile.id) fail('forbidden', 403);
  return row;
}

async function canRead(db, profile, row) {
  if (profile.role === 'patient') return profile.id === row.patient_id;
  if (profile.role !== 'therapist') return false;
  const { data, error } = await db.from('therapist_patient_assignments')
    .select('patient_id').eq('therapist_id', profile.id).eq('patient_id', row.patient_id).maybeSingle();
  if (error) throw error;
  return Boolean(data);
}

function publicManifest(row) {
  return {
    id: row.id,
    patientId: row.patient_id,
    exerciseId: row.exercise_id,
    status: row.status,
    startedAt: row.started_at,
    endedAt: row.ended_at,
    segments: (row.segments || []).map((segment) => ({
      index: segment.index,
      name: segment.name,
      mimeType: segment.mime_type,
      size: segment.size,
      durationMs: segment.duration_ms,
      startOffsetMs: segment.start_offset_ms,
      uploadedAt: segment.uploaded_at,
      playbackUrl: `/api/session-media/file?mediaSessionId=${encodeURIComponent(row.id)}&fileId=${encodeURIComponent(segment.drive_file_id)}`,
    })),
  };
}

function uploadStatus(row, segments) {
  if (!row.ended_at) return 'uploading';
  return segments.length >= (row.expected_video_segments ?? Number.MAX_SAFE_INTEGER) ? 'ready' : 'uploading';
}

export async function startMedia(profile, input) {
  if (profile.role !== 'patient') fail('patient_role_required', 403);
  const id = String(input.id || '').trim();
  const exerciseId = String(input.exerciseId || '').trim().slice(0, 120);
  if (!UUID_PATTERN.test(id) || !exerciseId) fail('invalid_media_session', 400);
  const db = adminClient();
  const { data: exercise } = await db.from('exercise_catalog').select('id').eq('id', exerciseId).eq('is_active', true).maybeSingle();
  if (!exercise) fail('exercise_not_available', 400);
  const { data, error } = await db.from('exercise_session_media').insert({
    id,
    patient_id: profile.id,
    exercise_id: exerciseId,
  }).select().single();
  if (error) throw error;
  return publicManifest(data);
}

export async function prepareUpload(profile, input) {
  const db = adminClient();
  const drive = createGoogleDriveClient();
  let row = await requireOwner(db, profile, input.mediaSessionId);
  const index = cleanInteger(input.index, 0, 10000);
  const size = cleanInteger(input.size, 1, MAX_VIDEO_BYTES);
  const mimeType = String(input.mimeType || '').toLowerCase();
  if (index == null || size == null || !['video/mp4', 'video/quicktime'].includes(mimeType)) fail('invalid_upload_metadata', 400);
  if (!row.drive_folder_id) {
    const folder = await drive.ensureSessionFolder({ patientId: row.patient_id, mediaSessionId: row.id, startedAt: row.started_at });
    const { data, error } = await db.from('exercise_session_media')
      .update({ drive_folder_id: folder.id, status: 'uploading', updated_at: new Date().toISOString() })
      .eq('id', row.id).select().single();
    if (error) throw error;
    row = data;
  }
  const extension = mimeType === 'video/quicktime' ? 'mov' : 'mp4';
  const name = `video-${String(index).padStart(4, '0')}.${extension}`;
  const uploadUrl = await drive.createResumableUpload({
    folderId: row.drive_folder_id,
    name,
    mimeType,
    size,
    appProperties: { physioaiSession: row.id, physioaiIndex: String(index) },
  });
  return { uploadUrl, name, mimeType, size };
}

export async function completeSegment(profile, input) {
  const db = adminClient();
  const drive = createGoogleDriveClient();
  const row = await requireOwner(db, profile, input.mediaSessionId);
  const index = cleanInteger(input.index, 0, 10000);
  const fileId = String(input.fileId || '').trim().slice(0, 220);
  if (index == null || !fileId || !row.drive_folder_id) fail('invalid_segment_completion', 400);
  const file = await drive.getFile(fileId);
  if (file.trashed || !file.parents?.includes(row.drive_folder_id) || !String(file.mimeType).startsWith('video/')) fail('drive_file_not_in_session', 403);
  const nextSegment = {
    index,
    drive_file_id: file.id,
    name: file.name,
    mime_type: file.mimeType,
    size: Number(file.size) || 0,
    duration_ms: cleanInteger(input.durationMs, 0, 86_400_000) ?? 0,
    start_offset_ms: cleanInteger(input.startOffsetMs, 0, 86_400_000) ?? 0,
    checksum: file.md5Checksum || null,
    uploaded_at: new Date().toISOString(),
  };
  const byIndex = new Map((row.segments || []).map((segment) => [segment.index, segment]));
  byIndex.set(index, nextSegment);
  const segments = [...byIndex.values()].sort((a, b) => a.index - b.index);
  const { data, error } = await db.from('exercise_session_media').update({
    segments,
    status: uploadStatus(row, segments),
    updated_at: new Date().toISOString(),
  }).eq('id', row.id).select().single();
  if (error) throw error;
  return publicManifest(data);
}

export async function finishMedia(profile, input) {
  const db = adminClient();
  const row = await requireOwner(db, profile, input.mediaSessionId);
  const expected = cleanInteger(input.videoSegments, 0, 10000);
  if (expected == null) fail('invalid_video_segment_count', 400);
  const endedAt = new Date().toISOString();
  const next = { ...row, ended_at: endedAt, expected_video_segments: expected };
  const { data, error } = await db.from('exercise_session_media').update({
    ended_at: endedAt,
    expected_video_segments: expected,
    status: uploadStatus(next, row.segments || []),
    updated_at: endedAt,
  }).eq('id', row.id).select().single();
  if (error) throw error;
  return publicManifest(data);
}

export async function getManifest(profile, id) {
  const db = adminClient();
  const row = await mediaRow(db, id);
  if (!(await canRead(db, profile, row))) fail('forbidden', 403);
  return publicManifest(row);
}

export async function getMediaFile(profile, id, fileId, range) {
  const db = adminClient();
  const row = await mediaRow(db, id);
  if (!(await canRead(db, profile, row))) fail('forbidden', 403);
  const segment = (row.segments || []).find((item) => item.drive_file_id === fileId);
  if (!segment) fail('media_file_not_found', 404);
  const response = await createGoogleDriveClient().download(fileId, range);
  return { response, segment };
}
