create table public.communication_messages (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null,
  therapist_id uuid not null,
  sender_id uuid not null references public.profiles (id) on delete restrict,
  body text not null check (char_length(body) between 1 and 4000),
  message_type text not null default 'text' check (message_type = 'text'),
  created_at timestamptz not null default now(),
  constraint communication_messages_assignment_fkey
    foreign key (patient_id, therapist_id)
    references public.therapist_patient_assignments (patient_id, therapist_id)
    on update cascade
    on delete cascade,
  constraint communication_messages_sender_is_participant
    check (sender_id = patient_id or sender_id = therapist_id)
);

comment on table public.communication_messages is
  'Append-only one-to-one messages between an assigned patient and therapist.';

create index communication_messages_pair_created_at_idx
  on public.communication_messages (patient_id, therapist_id, created_at desc);

create index communication_messages_sender_id_idx
  on public.communication_messages (sender_id);

alter table public.communication_messages enable row level security;
revoke all on table public.communication_messages from anon, authenticated;
grant select, insert on table public.communication_messages to authenticated;

create policy "assigned pair can read messages"
on public.communication_messages
for select
to authenticated
using (
  (select auth.uid()) = patient_id
  or (select auth.uid()) = therapist_id
);

create policy "assigned pair can send as self"
on public.communication_messages
for insert
to authenticated
with check (
  sender_id = (select auth.uid())
  and (
    (select auth.uid()) = patient_id
    or (select auth.uid()) = therapist_id
  )
);

create table public.communication_calls (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null,
  therapist_id uuid not null,
  initiated_by uuid not null references public.profiles (id) on delete restrict,
  provider text not null default 'cloudflare_realtimekit'
    check (provider = 'cloudflare_realtimekit'),
  provider_meeting_id text not null unique
    check (char_length(provider_meeting_id) between 1 and 255),
  status text not null default 'ringing'
    check (status in ('ringing', 'live', 'ended', 'cancelled')),
  created_at timestamptz not null default now(),
  ended_at timestamptz,
  constraint communication_calls_assignment_fkey
    foreign key (patient_id, therapist_id)
    references public.therapist_patient_assignments (patient_id, therapist_id)
    on update cascade
    on delete cascade,
  constraint communication_calls_initiator_is_participant
    check (initiated_by = patient_id or initiated_by = therapist_id),
  constraint communication_calls_end_time_valid
    check (ended_at is null or ended_at >= created_at)
);

comment on table public.communication_calls is
  'Cloudflare RealtimeKit call metadata only; recording and transcription stay disabled.';

create index communication_calls_pair_created_at_idx
  on public.communication_calls (patient_id, therapist_id, created_at desc);

create index communication_calls_initiated_by_idx
  on public.communication_calls (initiated_by);

alter table public.communication_calls enable row level security;
revoke all on table public.communication_calls from anon, authenticated;
grant select, insert, update on table public.communication_calls to authenticated;

create policy "assigned pair can read calls"
on public.communication_calls
for select
to authenticated
using (
  (select auth.uid()) = patient_id
  or (select auth.uid()) = therapist_id
);

create policy "assigned pair can create call as self"
on public.communication_calls
for insert
to authenticated
with check (
  initiated_by = (select auth.uid())
  and (
    (select auth.uid()) = patient_id
    or (select auth.uid()) = therapist_id
  )
);

create policy "assigned pair can update call state"
on public.communication_calls
for update
to authenticated
using (
  (select auth.uid()) = patient_id
  or (select auth.uid()) = therapist_id
)
with check (
  (select auth.uid()) = patient_id
  or (select auth.uid()) = therapist_id
);

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'communication_messages'
  ) then
    alter publication supabase_realtime add table public.communication_messages;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'communication_calls'
  ) then
    alter publication supabase_realtime add table public.communication_calls;
  end if;
end
$$;
