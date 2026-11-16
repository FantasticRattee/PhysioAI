alter table public.exercise_sessions
  add column dws_metrics jsonb
  check (dws_metrics is null or (
    exercise_id = 'cust_dynamic_weight_shifts'
    and jsonb_typeof(dws_metrics) = 'object'
    and octet_length(dws_metrics::text) <= 4096
  ));

comment on column public.exercise_sessions.dws_metrics is
  'Versioned DWS host observations. Shoulder tilt episodes are not invalid reps; interrupted tracking is not a patient fault. Existing session RLS applies.';
