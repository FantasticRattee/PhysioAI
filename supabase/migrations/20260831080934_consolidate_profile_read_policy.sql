drop policy "users can read own authorization profile" on public.profiles;
drop policy "connected users can read each other profiles" on public.profiles;

create policy "users can read own or connected profiles"
on public.profiles
for select
to authenticated
using (
  (select auth.uid()) = id
  or exists (
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
