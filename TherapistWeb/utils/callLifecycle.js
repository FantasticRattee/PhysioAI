export const CALL_FIELDS = 'id, patient_id, therapist_id, initiated_by, signaling_session_id, media_type, status, created_at, connected_at, ended_at';

export function isCallEnded(call) {
  return call?.status === 'ended' || call?.status === 'cancelled';
}

export async function readCall(supabase, callId) {
  // The authenticated client's participant RLS also applies to ended calls.
  const { data, error } = await supabase.from('communication_calls').select(CALL_FIELDS).eq('id', callId).maybeSingle();
  if (error) throw error;
  return data;
}

export async function transitionCall(supabase, callId, status) {
  const { data, error } = await supabase.from('communication_calls')
    .update({ status }).eq('id', callId).in('status', ['ringing', 'live']).select(CALL_FIELDS).maybeSingle();
  if (error) throw error;
  // Idempotent after a concurrent hang-up; never overwrite the end timestamp.
  return data ?? await readCall(supabase, callId);
}

export function endedCallSignals(call, userId) {
  if (!isCallEnded(call)) return [];
  // Also lets older clients consume the durable end state as a normal hang-up,
  // even after the original signal expired or was never successfully inserted.
  return [{ id: `ended-${call.id}`, sender_id: call.patient_id === userId ? call.therapist_id : call.patient_id,
    signal_type: 'hangup', payload: { reason: 'call_ended' }, created_at: call.ended_at }];
}

export function callDurationSeconds(call) {
  if (!call?.connected_at || !call?.ended_at) return null;
  const seconds = (Date.parse(call.ended_at) - Date.parse(call.connected_at)) / 1000;
  return Number.isFinite(seconds) && seconds >= 0 ? Math.floor(seconds) : null;
}

export function mergeCallHistory(current, incoming) {
  // A poll started before hang-up must not erase the card just returned by PATCH.
  return [...new Map([...current, ...incoming].map((call) => [call.id, call])).values()]
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at)).slice(0, 100);
}

export function callHistoryDetail(call, own) {
  const seconds = callDurationSeconds(call);
  if (seconds === null) return call.status === 'cancelled' ? (own ? 'ไม่ได้รับสาย' : 'สายที่ไม่ได้รับ') : 'สิ้นสุดการโทร';
  const hours = Math.floor(seconds / 3600), minutes = Math.floor(seconds % 3600 / 60);
  return [hours ? `${hours} ชม.` : '', minutes ? `${minutes} นาที` : '', `${seconds % 60} วิ`].filter(Boolean).join(' ');
}
