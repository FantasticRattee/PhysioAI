-- Private Google Drive media index for completed exercise sessions.
-- Raw files remain in Google Drive; this table is server-only metadata.

create table public.exercise_session_media (
  id uuid primary key,
  patient_id uuid not null references public.profiles(id) on delete cascade,
  exercise_id text not null references public.exercise_catalog(id),
  status text not null default 'recording'
    check (status in ('recording', 'uploading', 'ready', 'upload_failed')),
  drive_folder_id text,
  segments jsonb not null default '[]'::jsonb
    check (jsonb_typeof(segments) = 'array' and octet_length(segments::text) <= 1048576),
  expected_video_segments integer
    check (expected_video_segments is null or expected_video_segments between 0 and 10000),
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  updated_at timestamptz not null default now()
);

create index exercise_session_media_patient_started_at_idx
on public.exercise_session_media (patient_id, started_at desc);

alter table public.exercise_sessions
add column media_session_id uuid unique
references public.exercise_session_media(id) on delete set null;

alter table public.exercise_session_media enable row level security;

-- Media rows contain private Drive identifiers. Only the server-side Supabase
-- secret may access them; Patient and Therapist clients use checked API routes.
revoke all on table public.exercise_session_media from anon, authenticated;

comment on table public.exercise_session_media is
'Server-only index of private Google Drive video segments for exercise sessions.';

comment on column public.exercise_sessions.media_session_id is
'Opaque link to private session video. Playback is authorized by the Railway API.';
