create table public.session_ai_reviews (
  session_id uuid primary key
    references public.exercise_sessions (id) on delete cascade,
  status text not null default 'processing'
    check (status in ('processing', 'ready', 'failed')),
  review jsonb,
  model text,
  generated_at timestamptz,
  error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint session_ai_reviews_ready_has_review
    check (status <> 'ready' or review is not null)
);

comment on table public.session_ai_reviews is
  'Server-generated, non-diagnostic AI review for an immutable exercise session. Patient and assigned therapist may read only.';

alter table public.session_ai_reviews enable row level security;

revoke all on table public.session_ai_reviews from anon, authenticated;
grant select on table public.session_ai_reviews to authenticated;

create policy "patient or assigned therapist can read session AI reviews"
on public.session_ai_reviews
for select
to authenticated
using (
  exists (
    select 1
    from public.exercise_sessions as session
    where session.id = session_ai_reviews.session_id
      and (
        session.patient_id = (select auth.uid())
        or exists (
          select 1
          from public.therapist_patient_assignments as assignment
          where assignment.patient_id = session.patient_id
            and assignment.therapist_id = (select auth.uid())
        )
      )
  )
);
