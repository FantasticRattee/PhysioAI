insert into public.exercise_catalog (
  id,
  group_id,
  title_th,
  title_en,
  exercise_type,
  default_reps,
  default_sets,
  default_hold_sec,
  readiness_th,
  readiness_en,
  runtime_version,
  sort_order,
  is_active
)
values (
  'cust_dynamic_weight_shifts',
  'production',
  'ฝึกเลื่อนน้ำหนักขณะนั่ง',
  'Dynamic Weight Shift',
  'rep',
  10,
  1,
  5,
  'พร้อมใช้ในแอปผู้ป่วย iOS · DWS รุ่นทดลอง',
  'Available in the experimental iOS patient app · DWS',
  'DWS Native v3.0.0',
  30,
  true
)
on conflict (id) do update
set group_id = excluded.group_id,
    title_th = excluded.title_th,
    title_en = excluded.title_en,
    exercise_type = excluded.exercise_type,
    default_reps = excluded.default_reps,
    default_sets = excluded.default_sets,
    default_hold_sec = excluded.default_hold_sec,
    readiness_th = excluded.readiness_th,
    readiness_en = excluded.readiness_en,
    runtime_version = excluded.runtime_version,
    sort_order = excluded.sort_order,
    is_active = excluded.is_active;

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
    or jsonb_array_length(target_items) > 3 then
    raise exception 'plan must contain one to three supported exercises'
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
