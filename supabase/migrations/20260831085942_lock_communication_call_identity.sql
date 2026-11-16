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
    or new.provider_meeting_id is distinct from old.provider_meeting_id
    or new.created_at is distinct from old.created_at
  then
    raise exception 'Communication call identity fields are immutable';
  end if;

  return new;
end;
$$;

drop trigger if exists communication_calls_lock_identity
  on public.communication_calls;

create trigger communication_calls_lock_identity
before update on public.communication_calls
for each row
execute function public.enforce_communication_call_identity_immutable();

comment on function public.enforce_communication_call_identity_immutable() is
  'Allows participants to update call status/end time without moving a call to another assignment.';
