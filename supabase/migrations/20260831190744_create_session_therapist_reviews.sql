create table public.session_therapist_reviews (
  session_id uuid primary key
    references public.exercise_sessions (id) on delete cascade,
  therapist_id uuid not null
    references public.profiles (id) on delete restrict,
  body text not null
    check (length(trim(body)) between 1 and 4000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.session_therapist_reviews is
  'Therapist-authored review for one patient exercise session. Patient reads own review; only the assigned therapist writes it.';

create index session_therapist_reviews_therapist_id_idx
  on public.session_therapist_reviews (therapist_id);

alter table public.session_therapist_reviews enable row level security;

revoke all on table public.session_therapist_reviews from anon, authenticated;
grant select, insert, update on table public.session_therapist_reviews to authenticated;

create policy "patient or assigned therapist can read therapist session reviews"
on public.session_therapist_reviews
for select
to authenticated
using (
  exists (
    select 1
    from public.exercise_sessions as session
    where session.id = session_therapist_reviews.session_id
      and (
        session.patient_id = (select auth.uid())
        or exists (
          select 1
          from public.therapist_patient_assignments as assignment
          where assignment.patient_id = session.patient_id
            and assignment.therapist_id = (select auth.uid())
            and assignment.therapist_id = session_therapist_reviews.therapist_id
        )
      )
  )
);

create policy "assigned therapist can create therapist session review"
on public.session_therapist_reviews
for insert
to authenticated
with check (
  therapist_id = (select auth.uid())
  and exists (
    select 1
    from public.exercise_sessions as session
    join public.therapist_patient_assignments as assignment
      on assignment.patient_id = session.patient_id
    where session.id = session_therapist_reviews.session_id
      and assignment.therapist_id = (select auth.uid())
  )
  and exists (
    select 1
    from public.profiles as profile
    where profile.id = (select auth.uid())
      and profile.role = 'therapist'::public.app_role
  )
);

create policy "assigned therapist can update own therapist session review"
on public.session_therapist_reviews
for update
to authenticated
using (
  therapist_id = (select auth.uid())
  and exists (
    select 1
    from public.exercise_sessions as session
    join public.therapist_patient_assignments as assignment
      on assignment.patient_id = session.patient_id
    where session.id = session_therapist_reviews.session_id
      and assignment.therapist_id = (select auth.uid())
  )
)
with check (
  therapist_id = (select auth.uid())
  and exists (
    select 1
    from public.exercise_sessions as session
    join public.therapist_patient_assignments as assignment
      on assignment.patient_id = session.patient_id
    where session.id = session_therapist_reviews.session_id
      and assignment.therapist_id = (select auth.uid())
  )
);
