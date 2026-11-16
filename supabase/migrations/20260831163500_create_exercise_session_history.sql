create table public.exercise_sessions (
  id uuid primary key,
  patient_id uuid not null
    references public.profiles (id) on delete cascade,
  exercise_id text not null
    references public.exercise_catalog (id) on update cascade on delete restrict,
  kind text not null default 'plan'
    check (kind in ('plan', 'extra')),
  started_at timestamptz not null,
  ended_at timestamptz not null,
  duration_seconds integer not null default 0
    check (duration_seconds between 0 and 86400),
  completed_reps integer not null default 0
    check (completed_reps between 0 and 10000),
  completed_sets integer not null default 0
    check (completed_sets between 0 and 1000),
  invalid_reps integer not null default 0
    check (invalid_reps between 0 and 10000),
  cues_presented integer not null default 0
    check (cues_presented between 0 and 10000),
  overall_score smallint
    check (overall_score between 0 and 100),
  pose_score smallint
    check (pose_score between 0 and 100),
  motion_score smallint
    check (motion_score between 0 and 100),
  experimental_only boolean not null default false,
  created_at timestamptz not null default now(),
  constraint exercise_sessions_time_order
    check (ended_at >= started_at)
);

comment on table public.exercise_sessions is
  'Immutable exercise session history written by a Patient and readable by that Patient or their assigned Therapist.';

create index exercise_sessions_patient_ended_at_idx
  on public.exercise_sessions (patient_id, ended_at desc);

create index exercise_sessions_exercise_id_idx
  on public.exercise_sessions (exercise_id);

alter table public.exercise_sessions enable row level security;

revoke all on table public.exercise_sessions from anon, authenticated;
grant select, insert on table public.exercise_sessions to authenticated;

create policy "patient or assigned therapist can read exercise sessions"
on public.exercise_sessions
for select
to authenticated
using (
  patient_id = (select auth.uid())
  or exists (
    select 1
    from public.therapist_patient_assignments as assignment
    where assignment.patient_id = exercise_sessions.patient_id
      and assignment.therapist_id = (select auth.uid())
  )
);

create policy "patient can create own exercise session"
on public.exercise_sessions
for insert
to authenticated
with check (
  patient_id = (select auth.uid())
  and exists (
    select 1
    from public.profiles as profile
    where profile.id = (select auth.uid())
      and profile.role = 'patient'::public.app_role
  )
);
