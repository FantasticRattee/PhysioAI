# Supabase roles and provisioning

**Document version:** `supabase-roles-doc:v1.4.0`

**Schema version:** `plan-schema:20260831082135` (`index_exercise_catalog_foreign_key`)
**App compatibility:** `combination-v1:v8.0.15-build.15`, `therapist-web:v0.12.0`
**Session history schema:** `session-history-schema:20260831163500`

## Role contract

| Role | Allowed client | Provisioning rule |
| --- | --- | --- |
| `patient` | Native iPhone patient app | Default for every new account |
| `therapist` | Next.js Therapist Plan Builder | Must be assigned by a trusted administrator |

The authorization source of truth is `public.profiles.role`. The application
does not authorize from `raw_user_meta_data`, because a signed-in user can edit
that metadata. The database trigger only reads `raw_app_meta_data.app_role`,
which is administrator-managed, while creating a profile; otherwise it assigns
`patient`.

`exercise_sessions` is immutable to clients after insert. A Patient can insert
and read only their own rows; the assigned Therapist can read those rows but
cannot create, edit, or delete them.

## Database controls

- `profiles.id` is both the primary key and a cascading foreign key to
  `auth.users.id`.
- Row Level Security is enabled. Authenticated users can select their own
  profile plus profiles directly connected by an assignment; anonymous users
  have no table privilege.
- Browser and iPhone clients cannot update roles.
- New Auth users receive a profile through the
  `private.handle_new_auth_user()` trigger.
- `therapist_patient_assignments.patient_id` is the primary key: one Patient
  can therefore have no more than one Therapist. `therapist_id` is indexed but
  is not unique, so one Therapist can have many Patients.
- An assignment trigger verifies that `therapist_id` really has role
  `therapist` and `patient_id` really has role `patient`.
- Assignment participants can read their own connection and the connected
  person's profile. Clients cannot create, move, or delete assignments.
- The schema migrations are stored under `supabase/migrations/`: role/profile
  creation is `20260831075338_create_auth_roles.sql`, followed by least-
  privilege hardening in `20260831080352_tighten_profile_privileges.sql`.
  The one-to-many relationship is added by
  `20260831080707_create_therapist_patient_assignments.sql`.
  Profile access policies are consolidated for performance in
  `20260831080934_consolidate_profile_read_policy.sql`.
  Shared iOS plan delivery is added by
  `20260831081446_create_shared_patient_plans.sql`. The canonical exercise
  catalog and dose foreign key are added by
  `20260831081910_create_exercise_catalog.sql`; its covering index is added by
  `20260831082135_index_exercise_catalog_foreign_key.sql`.

## Shared exercise plans

- `patient_plans.patient_id` is unique, so each Patient has one current plan.
- `exercise_catalog` is the source of truth for exercise names, default doses,
  availability, order, and compatible iOS runtime version. Authenticated users
  can read active rows; clients cannot edit the catalog.
- `patient_plan_exercises` stores `exercise_id`, `reps`, `sets`, `hold_sec`,
  and display order for each prescribed exercise.
- Each prescribed `exercise_id` has a foreign key to `exercise_catalog`.
  The seeded active IDs are `bottle_grab` and `sit_to_stand`, matching the
  current Combination V1 native iOS V8.0.15 release.
- `save_patient_plan(...)` is a `SECURITY INVOKER` RPC. It validates the
  Therapist–Patient assignment and writes the plan plus all doses in one
  database transaction.
- A connected Therapist can read and update the plan. The signed-in Patient
  can read only their own plan and cannot modify it.
- The Plan Builder lists only rows allowed by the Therapist assignment RLS.
  The Therapist must explicitly choose one Patient before the form unlocks;
  the UI does not auto-select the first assignment.
- The iOS app applies the returned dose to its existing exercise runtime, so
  `reps × sets` determines the prescribed repetition target.

## Provision a therapist

1. Create or invite the Auth user in the Supabase Dashboard. Do not share a
   common therapist password between people.
2. In the Dashboard SQL editor, promote that exact account after verifying its
   email:

   ```sql
   update public.profiles
   set role = 'therapist'
   where id = (
     select id
     from auth.users
     where lower(email) = lower('therapist@example.com')
   );
   ```

3. Confirm that exactly one row changed. The therapist can then sign in at
   `/login`. If the account is used in the iPhone app, the app signs it out and
   directs the user to the Therapist website.

## Connect patients to a therapist

Run assignments from a trusted SQL/admin environment after both Auth profiles
exist and have the correct roles:

```sql
insert into public.therapist_patient_assignments (therapist_id, patient_id)
values (
  (select id from auth.users where lower(email) = lower('therapist@example.com')),
  (select id from auth.users where lower(email) = lower('patient@example.com'))
);
```

Repeat the insert with different `patient_id` values to connect more Patients
to the same Therapist. Attempting to insert the same Patient with another
Therapist fails because `patient_id` is the primary key. To transfer a Patient,
an administrator must deliberately update the existing assignment; the role
trigger checks the new pair again.

To demote an account, update the same profile to `patient`. Role changes take
effect on the next authorization check because both clients query `profiles`
rather than relying on a stale JWT role claim.

## Environment and secrets

The web reads `NEXT_PUBLIC_SUPABASE_URL` and
`NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` from `.env.local`. These are public
client configuration values protected by Auth and RLS. Never put a Supabase
service-role key in the web browser, iPhone app, repository, or `.env.local`.

## Current limitations

- Session history and live-assist messages still use the optional legacy API;
  the exercise plan itself now comes from Supabase.
- The Supabase security advisor currently reports that leaked-password
  protection is disabled. Enable it in Auth password-security settings before
  production use.
- This role boundary is an application authorization control, not a clinical
  production-readiness claim.
