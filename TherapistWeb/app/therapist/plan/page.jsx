import PlanBuilder from '../../../src/PlanBuilder.jsx';
import { signOut } from '../../auth/actions.js';
import { savePatientPlan } from './actions.js';
import { getAuthContext } from '../../../utils/auth.js';
import { canUseTherapistWeb } from '../../../utils/roles.js';
import { redirect } from 'next/navigation';

export const metadata = {
  title: 'Therapist Plan Builder · PhysioAI',
};

function bangkokDateString() {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Bangkok',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(new Date());
  const value = Object.fromEntries(parts.map(({ type, value: partValue }) => [type, partValue]));
  return `${value.year}-${value.month}-${value.day}`;
}

export default async function TherapistPlanPage() {
  const { supabase, claims, profile } = await getAuthContext();
  if (!profile) redirect('/login');
  if (!canUseTherapistWeb(profile.role)) redirect('/access-denied');

  const catalogPromise = supabase
      .from('exercise_catalog')
      .select(`
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
        sort_order
      `)
      .eq('is_active', true)
      .order('sort_order', { ascending: true });

  const assignmentsPromise = supabase
    .from('therapist_patient_assignments')
    .select(`
      patient_id,
      patient:profiles!therapist_patient_assignments_patient_id_fkey (
        id,
        full_name
      )
    `)
    .eq('therapist_id', profile.id)
    .order('assigned_at', { ascending: true });

  const [
    { data: catalogRows, error: catalogError },
    { data: assignments, error: assignmentsError },
  ] = await Promise.all([catalogPromise, assignmentsPromise]);

  if (catalogError) {
    throw new Error(`Could not load exercise catalog: ${catalogError.message}`);
  }

  const exercises = (catalogRows ?? []).map((exercise) => ({
    id: exercise.id,
    group: exercise.group_id,
    titleTh: exercise.title_th,
    titleEn: exercise.title_en,
    type: exercise.exercise_type,
    reps: exercise.default_reps,
    sets: exercise.default_sets,
    holdSec: Number(exercise.default_hold_sec),
    readinessTh: exercise.readiness_th,
    readinessEn: exercise.readiness_en,
    runtime: exercise.runtime_version,
  }));

  if (assignmentsError) {
    throw new Error(`Could not load assigned patients: ${assignmentsError.message}`);
  }

  const patientNameCollator = new Intl.Collator('th', { numeric: true, sensitivity: 'base' });
  const patients = (assignments ?? []).flatMap(({ patient }) => {
    if (!patient) return [];
    const caseCode = `PT-${patient.id.slice(0, 8).toUpperCase()}`;
    return [{
      id: patient.id,
      name: patient.full_name?.trim() || caseCode,
      caseCode,
    }];
  }).toSorted((left, right) => patientNameCollator.compare(left.name, right.name));

  let planRows = [];
  if (patients.length) {
    const { data, error } = await supabase
      .from('patient_plans')
      .select(`
        patient_id,
        freq_per_day,
        start_date,
        duration_days,
        notes,
        updated_at,
        items:patient_plan_exercises (
          exercise_id,
          reps,
          sets,
          hold_sec,
          sort_order
        )
      `)
      .in('patient_id', patients.map(({ id }) => id));

    if (error) {
      throw new Error(`Could not load patient plans: ${error.message}`);
    }
    planRows = data ?? [];
  }

  const initialPlans = Object.fromEntries(planRows.map((row) => [
    row.patient_id,
    {
      patientId: row.patient_id,
      items: (row.items ?? [])
        .toSorted((left, right) => left.sort_order - right.sort_order)
        .map((item) => ({
          exerciseId: item.exercise_id,
          reps: item.reps,
          sets: item.sets,
          holdSec: Number(item.hold_sec),
        })),
      freqPerDay: row.freq_per_day,
      startDate: row.start_date,
      durationDays: row.duration_days,
      notes: row.notes,
      updatedAt: row.updated_at,
    },
  ]));

  return (
    <PlanBuilder
      exercises={exercises}
      initialDate={bangkokDateString()}
      initialPatients={patients}
      initialPlans={initialPlans}
      onSignOut={signOut}
      onSavePlan={savePatientPlan}
      therapist={{
        name: profile.full_name || claims?.email || 'Therapist',
        role: profile.role,
      }}
    />
  );
}
