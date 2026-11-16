create table public.therapist_patient_assignments (
  patient_id uuid primary key
    references public.profiles (id) on delete cascade,
  therapist_id uuid not null
    references public.profiles (id) on delete cascade,
  assigned_at timestamptz not null default now(),
  constraint therapist_patient_assignments_distinct_users
    check (patient_id <> therapist_id)
);

comment on table public.therapist_patient_assignments is
  'One therapist can supervise many patients; each patient can have at most one therapist.';
comment on column public.therapist_patient_assignments.patient_id is
  'Primary key enforces one therapist assignment per patient.';

create index therapist_patient_assignments_therapist_id_idx
  on public.therapist_patient_assignments (therapist_id);

alter table public.therapist_patient_assignments enable row level security;

revoke all on table public.therapist_patient_assignments from anon, authenticated;
grant select on table public.therapist_patient_assignments to authenticated;

create policy "assignment participants can read connection"
on public.therapist_patient_assignments
for select
to authenticated
using (
  (select auth.uid()) = therapist_id
  or (select auth.uid()) = patient_id
);

create function private.enforce_therapist_patient_roles()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  assigned_therapist_role public.app_role;
  assigned_patient_role public.app_role;
begin
  select role
  into assigned_therapist_role
  from public.profiles
  where id = new.therapist_id;

  select role
  into assigned_patient_role
  from public.profiles
  where id = new.patient_id;

  if assigned_therapist_role is distinct from 'therapist'::public.app_role then
    raise exception 'therapist_id must reference a therapist profile'
      using errcode = '23514';
  end if;

  if assigned_patient_role is distinct from 'patient'::public.app_role then
    raise exception 'patient_id must reference a patient profile'
      using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke execute on function private.enforce_therapist_patient_roles()
  from public, anon, authenticated;

create trigger therapist_patient_assignments_enforce_roles
before insert or update
on public.therapist_patient_assignments
for each row execute function private.enforce_therapist_patient_roles();

create policy "connected users can read each other profiles"
on public.profiles
for select
to authenticated
using (
  exists (
    select 1
    from public.therapist_patient_assignments as assignment
    where (
      assignment.therapist_id = (select auth.uid())
      and assignment.patient_id = profiles.id
    ) or (
      assignment.patient_id = (select auth.uid())
      and assignment.therapist_id = profiles.id
    )
  )
);
