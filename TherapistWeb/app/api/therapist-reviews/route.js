import { NextResponse } from 'next/server';
import { getRequestAuthContext } from '../../../utils/requestAuth.js';
import { canUseTherapistWeb } from '../../../utils/roles.js';

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function fail(message, status) {
  throw Object.assign(new Error(message), { status });
}

export async function POST(request) {
  const { supabase, profile } = await getRequestAuthContext(request);
  if (!profile) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  if (!canUseTherapistWeb(profile.role)) return NextResponse.json({ error: 'therapist_role_required' }, { status: 403 });

  try {
    const input = await request.json().catch(() => ({}));
    const sessionId = String(input.sessionId || '');
    const body = String(input.body || '').trim();
    if (!UUID_PATTERN.test(sessionId)) fail('invalid_session_id', 400);
    if (!body || body.length > 4000) fail('invalid_therapist_review', 400);

    const { data: session, error: sessionError } = await supabase
      .from('exercise_sessions')
      .select('id')
      .eq('id', sessionId)
      .maybeSingle();
    if (sessionError) throw sessionError;
    if (!session) fail('session_not_found', 404);

    const now = new Date().toISOString();
    const { data, error } = await supabase
      .from('session_therapist_reviews')
      .upsert({ session_id: sessionId, therapist_id: profile.id, body, updated_at: now }, { onConflict: 'session_id' })
      .select('session_id, therapist_id, body, created_at, updated_at')
      .single();
    if (error) throw error;
    return NextResponse.json({ review: data }, { headers: { 'Cache-Control': 'private, no-store' } });
  } catch (error) {
    console.error('Therapist session review save failed', error?.message || error);
    return NextResponse.json(
      { error: error?.message || 'therapist_review_failed' },
      { status: error?.status || 500, headers: { 'Cache-Control': 'private, no-store' } },
    );
  }
}
