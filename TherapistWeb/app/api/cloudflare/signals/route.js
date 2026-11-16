import { NextResponse } from 'next/server';
import { getRequestAuthContext } from '../../../../utils/requestAuth.js';
import { readCall, isCallEnded, endedCallSignals, transitionCall } from '../../../../utils/callLifecycle.js';

const SIGNAL_TYPES = new Set(['offer', 'answer', 'ice', 'hangup']);

export async function GET(request) {
  const { supabase, claims, profile } = await getRequestAuthContext(request);
  if (!profile || !claims?.sub) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const callId = new URL(request.url).searchParams.get('callId') ?? '';
  let call;
  try { call = callId ? await readCall(supabase, callId) : null; }
  catch { return NextResponse.json({ error: 'call_lookup_failed' }, { status: 500 }); }
  if (!call) {
    return NextResponse.json({ error: 'call_not_available' }, { status: 404 });
  }
  if (isCallEnded(call)) return NextResponse.json({ call, signals: endedCallSignals(call, profile.id) });
  const { data, error } = await supabase.from('communication_call_signals')
    .select('id, sender_id, signal_type, payload, created_at')
    .eq('call_id', callId).order('created_at', { ascending: true }).limit(500);
  if (error) return NextResponse.json({ error: 'signal_lookup_failed' }, { status: 500 });
  return NextResponse.json({ call, signals: data ?? [] });
}

export async function POST(request) {
  const { supabase, claims, profile } = await getRequestAuthContext(request);
  if (!profile || !claims?.sub) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  const input = await request.json().catch(() => ({}));
  const callId = typeof input.callId === 'string' ? input.callId : '';
  const signalType = typeof input.type === 'string' ? input.type : '';
  if (!callId || !SIGNAL_TYPES.has(signalType) || !input.payload || typeof input.payload !== 'object') {
    return NextResponse.json({ error: 'invalid_signal' }, { status: 400 });
  }
  let call;
  try { call = await readCall(supabase, callId); }
  catch { return NextResponse.json({ error: 'call_lookup_failed' }, { status: 500 }); }
  if (!call) {
    return NextResponse.json({ error: 'call_not_available' }, { status: 404 });
  }
  if (signalType === 'hangup') {
    try {
      await transitionCall(supabase, callId, 'ended');
      return NextResponse.json({ id: `ended-${callId}` }, { status: 201 });
    } catch { return NextResponse.json({ error: 'call_update_failed' }, { status: 500 }); }
  }
  if (isCallEnded(call)) return NextResponse.json({ error: 'call_not_available' }, { status: 409 });
  const { data, error } = await supabase.from('communication_call_signals').insert({
    call_id: callId, sender_id: profile.id, signal_type: signalType, payload: input.payload,
  }).select('id').single();
  if (error) return NextResponse.json({ error: 'signal_send_failed' }, { status: 500 });
  return NextResponse.json({ id: data.id }, { status: 201 });
}
