create type public.app_role as enum ('therapist', 'patient');

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  role public.app_role not null default 'patient',
  full_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profiles_full_name_length check (full_name is null or char_length(full_name) <= 120)
);

comment on table public.profiles is 'Authorization profile for each Supabase Auth user.';
comment on column public.profiles.role is 'Server-managed application role. Never authorize from raw_user_meta_data.';

create index profiles_role_idx on public.profiles (role);

alter table public.profiles enable row level security;

grant usage on schema public to authenticated;
grant select on table public.profiles to authenticated;
revoke all on table public.profiles from anon;

create policy "users can read own authorization profile"
on public.profiles
for select
to authenticated
using ((select auth.uid()) = id);

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create function private.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  assigned_role public.app_role := 'patient';
begin
  if coalesce(new.raw_app_meta_data ->> 'app_role', '') in ('therapist', 'patient') then
    assigned_role := (new.raw_app_meta_data ->> 'app_role')::public.app_role;
  end if;

  insert into public.profiles (id, role, full_name)
  values (
    new.id,
    assigned_role,
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), '')
  );

  return new;
end;
$$;

revoke execute on function private.handle_new_auth_user() from public, anon, authenticated;

create trigger on_auth_user_created_create_profile
after insert on auth.users
for each row execute function private.handle_new_auth_user();

create function private.set_profile_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

revoke execute on function private.set_profile_updated_at() from public, anon, authenticated;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function private.set_profile_updated_at();

insert into public.profiles (id, role, full_name)
select
  users.id,
  case
    when coalesce(users.raw_app_meta_data ->> 'app_role', '') = 'therapist'
      then 'therapist'::public.app_role
    else 'patient'::public.app_role
  end,
  nullif(trim(users.raw_user_meta_data ->> 'full_name'), '')
from auth.users as users
on conflict (id) do nothing;
