import { randomUUID } from 'node:crypto';
import { NextResponse } from 'next/server';
import { getRequestAuthContext } from '../../../../utils/requestAuth.js';
import { CloudflareTurnConfigurationError, generateIceServers, getTurnConfig } from '../../../../utils/cloudflare/turn.js';
import { assignedPair } from '../../../../utils/cloudflare/assignedPair.js';
import { requestedCallMedia } from '../../../../utils/callMedia.js';
import { CALL_FIELDS, transitionCall } from '../../../../utils/callLifecycle.js';

export async function POST(request) {
  const { supabase, claims, profile } = await getRequestAuthContext(request);
  if (!profile || !claims?.sub) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const input = await request.json().catch(() => ({}));
  const patientId = typeof input.patientId === 'string' ? input.patientId : '';
  const requestedCallId = typeof input.callId === 'string' ? input.callId : '';
  const mediaType = requestedCallMedia(input.mediaType);
  if (!patientId) return NextResponse.json({ error: 'patient_id_required' }, { status: 400 });
  if (!mediaType) return NextResponse.json({ error: 'invalid_media_type' }, { status: 400 });

  let assignment;
  try {
    assignment = await assignedPair(supabase, profile, patientId);
  } catch {
    // A database outage is not proof that the pair is unassigned.
    return NextResponse.json({ error: 'pair_lookup_failed' }, { status: 500 });
  }
  if (!assignment) return NextResponse.json({ error: 'pair_not_assigned' }, { status: 403 });

  try {
    // Fetch credentials before creating state so a Cloudflare outage cannot
    // leave a new call stuck in the ringing state.
    const config = getTurnConfig();
    const iceServers = await generateIceServers(config);
    let call;
    if (requestedCallId) {
      const result = await supabase.from('communication_calls')
        .select('id, initiated_by, signaling_session_id, media_type')
        .eq('id', requestedCallId).eq('patient_id', assignment.patient_id)
        .eq('therapist_id', assignment.therapist_id).in('status', ['ringing', 'live']).maybeSingle();
      call = result.data;
      if (result.error) throw result.error;
      if (!call) return NextResponse.json({ error: 'call_not_available' }, { status: 404 });
      // Joining / TURN refresh is not proof that media has connected.
    } else {
      const result = await supabase.from('communication_calls').insert({
        patient_id: assignment.patient_id,
        therapist_id: assignment.therapist_id,
        initiated_by: profile.id,
        provider: 'cloudflare_turn',
        signaling_session_id: randomUUID(),
        media_type: mediaType,
      }).select('id, initiated_by, signaling_session_id, media_type').single();
      if (result.error) throw result.error;
      call = result.data;
    }

    return NextResponse.json({
      callId: call.id,
      patientId: assignment.patient_id,
      signalingSessionId: call.signaling_session_id,
      isInitiator: call.initiated_by === profile.id,
      // Join/refresh always use the stored choice, never the joiner's request.
      mediaType: call.media_type,
      iceServers,
      expiresIn: config.ttl,
    });
  } catch (error) {
    if (error instanceof CloudflareTurnConfigurationError) {
      return NextResponse.json({ error: 'cloudflare_turn_not_configured' }, { status: 503 });
    }
    console.error('Cloudflare TURN call creation failed', error);
    return NextResponse.json({ error: 'cloudflare_turn_failed' }, { status: 502 });
  }
}

export async function GET(request) {
  const { supabase, claims, profile } = await getRequestAuthContext(request);
  if (!profile || !claims?.sub) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const params = new URL(request.url).searchParams;
  if (params.get('history') === 'true') {
    const patientId = params.get('patientId');
    if (!patientId) return NextResponse.json({ error: 'patient_id_required' }, { status: 400 });
    const { data, error } = await supabase.from('communication_calls').select(CALL_FIELDS)
      .eq('patient_id', patientId).or(`patient_id.eq.${profile.id},therapist_id.eq.${profile.id}`)
      .in('status', ['ended', 'cancelled']).order('created_at', { ascending: false }).limit(100);
    if (error) return NextResponse.json({ error: 'call_history_failed' }, { status: 500 });
    return NextResponse.json({ calls: data ?? [] });
  }
  const { data, error } = await supabase.from('communication_calls')
    .select(CALL_FIELDS)
    .or(`patient_id.eq.${profile.id},therapist_id.eq.${profile.id}`)
    .in('status', ['ringing', 'live']).order('created_at', { ascending: false }).limit(1).maybeSingle();
  if (error) return NextResponse.json({ error: 'call_lookup_failed' }, { status: 500 });
  return NextResponse.json({ call: data ?? null });
}

export async function PATCH(request) {
  const { supabase, claims, profile } = await getRequestAuthContext(request);
  if (!profile || !claims?.sub) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const input = await request.json().catch(() => ({}));
  const callId = typeof input.callId === 'string' ? input.callId : '';
  const status = ['live', 'ended', 'cancelled'].includes(input.status) ? input.status : '';
  if (!callId || !status) return NextResponse.json({ error: 'invalid_call_state' }, { status: 400 });
  try {
    const call = await transitionCall(supabase, callId, status);
    if (!call) return NextResponse.json({ error: 'call_not_available' }, { status: 404 });
    return NextResponse.json({ call });
  } catch {
    return NextResponse.json({ error: 'call_update_failed' }, { status: 500 });
  }
}
