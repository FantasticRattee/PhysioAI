revoke all on function public.purge_expired_communication_call_signals() from public, anon, authenticated;

create index communication_call_signals_sender_id_idx
  on public.communication_call_signals (sender_id);
