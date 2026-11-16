-- Preserve existing video calls and keep the media choice fixed for the call.
alter table public.communication_calls
  add column media_type text not null default 'video'
  constraint communication_calls_media_type_check check (media_type in ('audio', 'video'));

comment on column public.communication_calls.media_type is
  'Media selected by the caller. Audio calls must never request or send camera video.';

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
    or new.signaling_session_id is distinct from old.signaling_session_id
    or new.media_type is distinct from old.media_type
    or new.created_at is distinct from old.created_at
  then
    raise exception 'Communication call identity fields are immutable';
  end if;
  return new;
end;
$$;
