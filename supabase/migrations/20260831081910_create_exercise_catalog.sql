create table public.exercise_catalog (
  id text primary key
    check (id ~ '^[a-z][a-z0-9_]*$'),
  group_id text not null default 'production',
  title_th text not null
    check (char_length(title_th) between 1 and 120),
  title_en text not null
    check (char_length(title_en) between 1 and 120),
  exercise_type text not null
    check (exercise_type in ('rep', 'hold')),
  default_reps smallint not null
    check (default_reps between 1 and 100),
  default_sets smallint not null
    check (default_sets between 1 and 20),
  default_hold_sec numeric(5,2) not null default 0
    check (default_hold_sec between 0 and 120),
  readiness_th text not null default '',
  readiness_en text not null default '',
  runtime_version text not null,
  sort_order smallint not null default 0
    check (sort_order between 0 and 1000),
  is_active boolean not null default true
);

comment on table public.exercise_catalog is
  'Canonical exercise catalog shared by the Therapist Web and patient iOS app.';

insert into public.exercise_catalog (
  id,
  title_th,
  title_en,
  exercise_type,
  default_reps,
  default_sets,
  default_hold_sec,
  readiness_th,
  readiness_en,
  runtime_version,
  sort_order
)
values
  (
    'bottle_grab',
    'หยิบขวด',
    'Bottle Grab',
    'rep',
    1,
    1,
    0.5,
    'พร้อมใช้ในแอปผู้ป่วย iOS · รุ่นทดลอง',
    'Available in the experimental iOS patient app',
    'iOS V8.0.2',
    10
  ),
  (
    'sit_to_stand',
    'ลุก-นั่งจากเก้าอี้',
    'Sit to Stand',
    'rep',
    5,
    1,
    0.5,
    'พร้อมใช้ในแอปผู้ป่วย iOS · รุ่นทดลอง',
    'Available in the experimental iOS patient app',
    'iOS V8.0.2',
    20
  );

alter table public.exercise_catalog enable row level security;

revoke all on table public.exercise_catalog from anon, authenticated;
grant select on table public.exercise_catalog to authenticated;

create policy "authenticated users can read active exercise catalog"
on public.exercise_catalog
for select
to authenticated
using (is_active);

alter table public.patient_plan_exercises
  drop constraint patient_plan_exercises_exercise_id_check;

alter table public.patient_plan_exercises
  add constraint patient_plan_exercises_exercise_id_fkey
  foreign key (exercise_id)
  references public.exercise_catalog (id)
  on update cascade
  on delete restrict;

create index patient_plans_patient_therapist_idx
  on public.patient_plans (patient_id, therapist_id);

create or replace function public.save_patient_plan(
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
      or not exists (
        select 1
        from public.exercise_catalog as exercise
        where exercise.id = payload.item ->> 'exercise_id'
          and exercise.is_active
      )
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
