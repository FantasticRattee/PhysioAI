alter table public.therapist_patient_assignments
  add constraint therapist_patient_assignments_patient_therapist_key
  unique (patient_id, therapist_id);

create table public.patient_plans (
  id uuid primary key default gen_random_uuid(),
  patient_id uuid not null unique,
  therapist_id uuid not null,
  freq_per_day smallint not null default 1
    check (freq_per_day between 1 and 10),
  start_date date not null default current_date,
  duration_days smallint not null default 28
    check (duration_days between 1 and 365),
  notes text not null default ''
    check (char_length(notes) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint patient_plans_assignment_fkey
    foreign key (patient_id, therapist_id)
    references public.therapist_patient_assignments (patient_id, therapist_id)
    on update cascade
    on delete cascade
);

comment on table public.patient_plans is
  'Current therapist-authored exercise plan delivered to one iOS patient account.';

create index patient_plans_therapist_id_idx
  on public.patient_plans (therapist_id);

create table public.patient_plan_exercises (
  plan_id uuid not null
    references public.patient_plans (id) on delete cascade,
  exercise_id text not null
    check (exercise_id in ('bottle_grab', 'sit_to_stand')),
  reps smallint not null
    check (reps between 1 and 100),
  sets smallint not null
    check (sets between 1 and 20),
  hold_sec numeric(5,2) not null default 0
    check (hold_sec between 0 and 120),
  sort_order smallint not null default 0
    check (sort_order between 0 and 20),
  primary key (plan_id, exercise_id)
);

comment on table public.patient_plan_exercises is
  'Per-exercise dose prescribed by the connected therapist.';

alter table public.patient_plans enable row level security;
alter table public.patient_plan_exercises enable row level security;

revoke all on table public.patient_plans from anon, authenticated;
revoke all on table public.patient_plan_exercises from anon, authenticated;

grant select, insert, update on table public.patient_plans to authenticated;
grant select, insert, update, delete on table public.patient_plan_exercises to authenticated;

create policy "plan participants can read plan"
on public.patient_plans
for select
to authenticated
using (
  patient_id = (select auth.uid())
  or (
    therapist_id = (select auth.uid())
    and exists (
      select 1
      from public.therapist_patient_assignments as assignment
      where assignment.patient_id = patient_plans.patient_id
        and assignment.therapist_id = (select auth.uid())
    )
  )
);

create policy "connected therapist can insert plan"
on public.patient_plans
for insert
to authenticated
with check (
  therapist_id = (select auth.uid())
  and exists (
    select 1
    from public.therapist_patient_assignments as assignment
    where assignment.patient_id = patient_plans.patient_id
      and assignment.therapist_id = (select auth.uid())
  )
);

create policy "connected therapist can update plan"
on public.patient_plans
for update
to authenticated
using (
  therapist_id = (select auth.uid())
  and exists (
    select 1
    from public.therapist_patient_assignments as assignment
    where assignment.patient_id = patient_plans.patient_id
      and assignment.therapist_id = (select auth.uid())
  )
)
with check (
  therapist_id = (select auth.uid())
  and exists (
    select 1
    from public.therapist_patient_assignments as assignment
    where assignment.patient_id = patient_plans.patient_id
      and assignment.therapist_id = (select auth.uid())
  )
);

create policy "plan participants can read exercise doses"
on public.patient_plan_exercises
for select
to authenticated
using (
  exists (
    select 1
    from public.patient_plans as plan
    where plan.id = patient_plan_exercises.plan_id
      and (
        plan.patient_id = (select auth.uid())
        or plan.therapist_id = (select auth.uid())
      )
  )
);

create policy "connected therapist can insert exercise doses"
on public.patient_plan_exercises
for insert
to authenticated
with check (
  exists (
    select 1
    from public.patient_plans as plan
    where plan.id = patient_plan_exercises.plan_id
      and plan.therapist_id = (select auth.uid())
  )
);

create policy "connected therapist can update exercise doses"
on public.patient_plan_exercises
for update
to authenticated
using (
  exists (
    select 1
    from public.patient_plans as plan
    where plan.id = patient_plan_exercises.plan_id
      and plan.therapist_id = (select auth.uid())
  )
)
with check (
  exists (
    select 1
    from public.patient_plans as plan
    where plan.id = patient_plan_exercises.plan_id
      and plan.therapist_id = (select auth.uid())
  )
);

create policy "connected therapist can delete exercise doses"
on public.patient_plan_exercises
for delete
to authenticated
using (
  exists (
    select 1
    from public.patient_plans as plan
    where plan.id = patient_plan_exercises.plan_id
      and plan.therapist_id = (select auth.uid())
  )
);

create function private.set_patient_plan_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke execute on function private.set_patient_plan_updated_at()
  from public, anon, authenticated;

create trigger patient_plans_set_updated_at
before update on public.patient_plans
for each row execute function private.set_patient_plan_updated_at();

create function public.save_patient_plan(
  target_patient_id uuid,
  target_items jsonb,
  target_freq_per_day smallint,
  target_start_date date,
  target_duration_days smallint,
  target_notes text
)
returns timestamptz
language plpgsql
security invoker
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  saved_plan_id uuid;
  saved_updated_at timestamptz;
begin
  if caller_id is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.therapist_patient_assignments
    where patient_id = target_patient_id
      and therapist_id = caller_id
  ) then
    raise exception 'patient is not assigned to this therapist'
      using errcode = '42501';
  end if;

  if target_items is null
    or jsonb_typeof(target_items) <> 'array'
    or jsonb_array_length(target_items) < 1
    or jsonb_array_length(target_items) > 2 then
    raise exception 'plan must contain one or two supported exercises'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(target_items) as payload(item)
    where jsonb_typeof(payload.item) <> 'object'
      or payload.item ->> 'exercise_id' not in ('bottle_grab', 'sit_to_stand')
      or (payload.item ->> 'reps')::integer not between 1 and 100
      or (payload.item ->> 'sets')::integer not between 1 and 20
      or (payload.item ->> 'hold_sec')::numeric not between 0 and 120
  ) then
    raise exception 'invalid exercise dose' using errcode = '23514';
  end if;

  if (
    select count(distinct payload.item ->> 'exercise_id')
    from jsonb_array_elements(target_items) as payload(item)
  ) <> jsonb_array_length(target_items) then
    raise exception 'exercise IDs must be unique' using errcode = '23514';
  end if;

  insert into public.patient_plans (
    patient_id,
    therapist_id,
    freq_per_day,
    start_date,
    duration_days,
    notes
  )
  values (
    target_patient_id,
    caller_id,
    target_freq_per_day,
    target_start_date,
    target_duration_days,
    coalesce(target_notes, '')
  )
  on conflict (patient_id) do update
  set therapist_id = excluded.therapist_id,
      freq_per_day = excluded.freq_per_day,
      start_date = excluded.start_date,
      duration_days = excluded.duration_days,
      notes = excluded.notes
  returning id, updated_at into saved_plan_id, saved_updated_at;

  delete from public.patient_plan_exercises
  where plan_id = saved_plan_id;

  insert into public.patient_plan_exercises (
    plan_id,
    exercise_id,
    reps,
    sets,
    hold_sec,
    sort_order
  )
  select
    saved_plan_id,
    payload.item ->> 'exercise_id',
    (payload.item ->> 'reps')::smallint,
    (payload.item ->> 'sets')::smallint,
    (payload.item ->> 'hold_sec')::numeric,
    (payload.ordinality - 1)::smallint
  from jsonb_array_elements(target_items)
    with ordinality as payload(item, ordinality);

  return saved_updated_at;
end;
$$;

revoke all on function public.save_patient_plan(
  uuid,
  jsonb,
  smallint,
  date,
  smallint,
  text
) from public, anon;

grant execute on function public.save_patient_plan(
  uuid,
  jsonb,
  smallint,
  date,
  smallint,
  text
) to authenticated;
