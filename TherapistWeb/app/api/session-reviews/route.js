import { createClient } from '@supabase/supabase-js';
import { NextResponse } from 'next/server';
import { getRequestAuthContext } from '../../../utils/requestAuth.js';
import { canUsePatientApp, canUseTherapistWeb } from '../../../utils/roles.js';
import { generateSessionReview, sessionReviewModel } from '../../../utils/sessionReview/llm.js';
import { getSupabaseConfig } from '../../../utils/supabase/config.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function fail(message, status) {
  throw Object.assign(new Error(message), { status });
}

function canUseSessionReview(role) {
  return canUsePatientApp(role) || canUseTherapistWeb(role);
}

function adminClient() {
  const secretKey = String(process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY || '').trim();
  if (!secretKey) fail('session_review_storage_not_configured', 503);
  const { url } = getSupabaseConfig();
  return createClient(url, secretKey, { auth: { autoRefreshToken: false, persistSession: false } });
}

function sessionSummary(session, exercise) {
  return {
    schema: 'physioai.session-summary.v1',
    sessionId: session.id,
    exercise: {
      id: session.exercise_id,
      titleTh: exercise?.title_th || session.exercise_id,
      titleEn: exercise?.title_en || null,
    },
    completedAt: session.ended_at,
    durationSeconds: session.duration_seconds,
    completedReps: session.completed_reps,
    completedSets: session.completed_sets,
    invalidReps: session.invalid_reps,
    cuesPresented: session.cues_presented,
    overallScore: session.overall_score,
    poseScore: session.pose_score,
    motionScore: session.motion_score,
    experimentalOnly: session.experimental_only,
    dwsMetrics: session.dws_metrics ?? null,
  };
}

function publicReview(row) {
  return {
    sessionId: row.session_id,
    status: row.status,
    review: row.review,
    model: row.model,
    generatedAt: row.generated_at,
  };
}

async function readableSession(supabase, profile, sessionId) {
  const { data: session, error } = await supabase
    .from('exercise_sessions')
    .select('id, patient_id, exercise_id, ended_at, duration_seconds, completed_reps, completed_sets, invalid_reps, cues_presented, overall_score, pose_score, motion_score, experimental_only, dws_metrics')
    .eq('id', sessionId)
    .maybeSingle();
  if (error) throw error;
  if (!session) fail('session_not_found', 404);
  if (canUsePatientApp(profile.role) && session.patient_id !== profile.id) fail('forbidden', 403);
  return session;
}

async function reviewRow(supabase, sessionId) {
  const { data, error } = await supabase
    .from('session_ai_reviews')
    .select('session_id, status, review, model, generated_at, error_code')
    .eq('session_id', sessionId)
    .maybeSingle();
  if (error) throw error;
  return data;
}

export async function GET(request) {
  const { supabase, profile } = await getRequestAuthContext(request);
  if (!profile) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  if (!canUseSessionReview(profile.role)) return NextResponse.json({ error: 'role_not_allowed' }, { status: 403 });
  try {
    const sessionId = new URL(request.url).searchParams.get('sessionId');
    if (!UUID_PATTERN.test(String(sessionId || ''))) fail('invalid_session_id', 400);
    await readableSession(supabase, profile, sessionId);
    const row = await reviewRow(supabase, sessionId);
    if (!row) fail('session_review_not_found', 404);
    return NextResponse.json(publicReview(row), { headers: { 'Cache-Control': 'private, no-store' } });
  } catch (error) {
    console.error('Session AI review lookup failed', error?.message || error);
    return NextResponse.json({ error: error?.message || 'session_review_lookup_failed' }, { status: error?.status || 500 });
  }
}

export async function POST(request) {
  const { supabase, profile } = await getRequestAuthContext(request);
  if (!profile) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  if (!canUseSessionReview(profile.role)) return NextResponse.json({ error: 'role_not_allowed' }, { status: 403 });

  let storage;
  let sessionId;
  try {
    ({ sessionId } = await request.json().catch(() => ({})));
    if (!UUID_PATTERN.test(String(sessionId || ''))) fail('invalid_session_id', 400);
    const session = await readableSession(supabase, profile, sessionId);
    const existing = await reviewRow(supabase, sessionId);
    if (existing?.status === 'ready' || existing?.status === 'processing') {
      return NextResponse.json(publicReview(existing), { status: existing.status === 'processing' ? 202 : 200 });
    }

    const { data: exercise, error: exerciseError } = await supabase
      .from('exercise_catalog')
      .select('id, title_th, title_en')
      .eq('id', session.exercise_id)
      .maybeSingle();
    if (exerciseError) throw exerciseError;

    storage = adminClient();
    const startedAt = new Date().toISOString();
    const { error: startError } = await storage.from('session_ai_reviews').upsert({
      session_id: sessionId,
      status: 'processing',
      review: null,
      model: sessionReviewModel(),
      generated_at: null,
      error_code: null,
      updated_at: startedAt,
    }, { onConflict: 'session_id' });
    if (startError) throw startError;

    const review = await generateSessionReview(sessionSummary(session, exercise));
    const generatedAt = new Date().toISOString();
    const { data: stored, error: storeError } = await storage.from('session_ai_reviews').update({
      status: 'ready', review, model: sessionReviewModel(), generated_at: generatedAt, error_code: null, updated_at: generatedAt,
    }).eq('session_id', sessionId).select('session_id, status, review, model, generated_at, error_code').single();
    if (storeError) throw storeError;
    return NextResponse.json(publicReview(stored), { headers: { 'Cache-Control': 'private, no-store' } });
  } catch (error) {
    if (storage && UUID_PATTERN.test(String(sessionId || ''))) {
      await storage.from('session_ai_reviews').update({
        status: 'failed', error_code: String(error?.message || 'session_review_failed').slice(0, 120), updated_at: new Date().toISOString(),
      }).eq('session_id', sessionId);
    }
    console.error('Session AI review generation failed', error?.message || error);
    return NextResponse.json({ error: error?.message || 'session_review_failed' }, { status: error?.status || 500 });
  }
}
