-- Replace managed RealtimeKit meeting identity with WebRTC signaling over
-- Cloudflare TURN. Existing call history is preserved and marked ended.

drop trigger if exists communication_calls_lock_identity on public.communication_calls;

update public.communication_calls
set status = 'ended', ended_at = coalesce(ended_at, now())
where status in ('ringing', 'live');

alter table public.communication_calls
  drop constraint if exists communication_calls_provider_check;

alter table public.communication_calls
  alter column provider set default 'cloudflare_turn';

update public.communication_calls
set provider = 'cloudflare_turn';

alter table public.communication_calls
  add constraint communication_calls_provider_check
  check (provider = 'cloudflare_turn');

alter table public.communication_calls
  rename column provider_meeting_id to signaling_session_id;

comment on table public.communication_calls is
  'One-to-one WebRTC call state using Cloudflare TURN; recording and transcription are disabled.';

create or replace function public.enforce_communication_call_identity_immutable()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
    or new.patient_id is distinct from old.patient_id
    or new.therapist_id is distinct from old.therapist_id
    or new.initiated_by is distinct from old.initiated_by
    or new.provider is distinct from old.provider
    or new.signaling_session_id is distinct from old.signaling_session_id
    or new.created_at is distinct from old.created_at
  then
    raise exception 'Communication call identity fields are immutable';
  end if;
  return new;
end;
$$;

create trigger communication_calls_lock_identity
before update on public.communication_calls
for each row execute function public.enforce_communication_call_identity_immutable();

create table public.communication_call_signals (
  id uuid primary key default gen_random_uuid(),
  call_id uuid not null references public.communication_calls (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete restrict,
  signal_type text not null check (signal_type in ('offer', 'answer', 'ice', 'hangup')),
  payload jsonb not null check (jsonb_typeof(payload) = 'object' and octet_length(payload::text) <= 65536),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'),
  constraint communication_call_signals_sender_participates
    check (sender_id is not null)
);

comment on table public.communication_call_signals is
  'Short-lived WebRTC SDP and ICE signaling. Rows expire after 24 hours and are visible only to call participants.';

create index communication_call_signals_call_created_idx
  on public.communication_call_signals (call_id, created_at);
create index communication_call_signals_expires_idx
  on public.communication_call_signals (expires_at);

alter table public.communication_call_signals enable row level security;
revoke all on table public.communication_call_signals from anon, authenticated;
grant select, insert on table public.communication_call_signals to authenticated;

create policy "call participants can read unexpired signals"
on public.communication_call_signals for select to authenticated
using (
  expires_at > now()
  and exists (
    select 1 from public.communication_calls c
    where c.id = call_id
      and ((select auth.uid()) = c.patient_id or (select auth.uid()) = c.therapist_id)
  )
);

create policy "call participants can signal as self"
on public.communication_call_signals for insert to authenticated
with check (
  sender_id = (select auth.uid())
  and expires_at <= now() + interval '24 hours'
  and exists (
    select 1 from public.communication_calls c
    where c.id = call_id
      and c.status in ('ringing', 'live')
      and ((select auth.uid()) = c.patient_id or (select auth.uid()) = c.therapist_id)
  )
);

create or replace function public.purge_expired_communication_call_signals()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.communication_call_signals where expires_at <= now();
  return new;
end;
$$;

create trigger communication_call_signals_purge_expired
after insert on public.communication_call_signals
for each statement execute function public.purge_expired_communication_call_signals();
