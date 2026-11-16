-- One durable row is shared by both peers. Do not count ringing as talk time.
alter table public.communication_calls add column connected_at timestamptz;
alter table public.communication_calls add constraint communication_calls_connected_time_valid
  check (connected_at is null or (connected_at >= created_at and (ended_at is null or ended_at >= connected_at)));

create function public.enforce_communication_call_lifecycle()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    new.status := 'ringing';
    new.connected_at := null;
    new.ended_at := null;
  elsif old.status in ('ended', 'cancelled') then
    -- A late join, connection callback, or second hang-up cannot reopen a call
    -- or lengthen its duration. Identity changes are checked by the other trigger.
    new.status := old.status;
    new.connected_at := old.connected_at;
    new.ended_at := old.ended_at;
  else
    new.connected_at := old.connected_at;
    new.ended_at := null;
    if new.status = 'live' then
      new.connected_at := coalesce(old.connected_at, greatest(clock_timestamp(), old.created_at));
    elsif new.status in ('ended', 'cancelled') then
      new.status := case when old.status = 'ringing' and old.connected_at is null then 'cancelled' else 'ended' end;
      new.ended_at := greatest(clock_timestamp(), old.created_at, old.connected_at);
    else
      -- Reordered requests cannot move a live call back to ringing.
      new.status := old.status;
    end if;
  end if;
  return new;
end;
$$;

create trigger communication_calls_lifecycle
before insert or update on public.communication_calls
for each row execute function public.enforce_communication_call_lifecycle();

revoke all on function public.enforce_communication_call_lifecycle() from public, anon, authenticated;
comment on column public.communication_calls.connected_at is
  'Server time of the first WebRTC connected report. NULL for unanswered or legacy calls with unknown talk duration.';
