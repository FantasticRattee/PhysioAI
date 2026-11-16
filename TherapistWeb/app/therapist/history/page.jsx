import { redirect } from 'next/navigation';
import SessionHistoryWorkspace from '../../../src/SessionHistoryWorkspace.jsx';
import { signOut } from '../../auth/actions.js';
import { getAuthContext } from '../../../utils/auth.js';
import { canUseTherapistWeb } from '../../../utils/roles.js';

export const metadata = { title: 'ประวัติการฝึก · PhysioAI Therapist' };

export default async function TherapistHistoryPage() {
  const { supabase, claims, profile } = await getAuthContext();
  if (!profile) redirect('/login');
  if (!canUseTherapistWeb(profile.role)) redirect('/access-denied');

  const assignmentsPromise = supabase
    .from('therapist_patient_assignments')
    .select('patient_id, patient:profiles!therapist_patient_assignments_patient_id_fkey(id, full_name)')
    .eq('therapist_id', profile.id)
    .order('assigned_at', { ascending: true });
  const catalogPromise = supabase
    .from('exercise_catalog')
    .select('id, title_th, title_en')
    .eq('is_active', true);

  const [
    { data: assignments, error: assignmentsError },
    { data: catalog, error: catalogError },
  ] = await Promise.all([assignmentsPromise, catalogPromise]);
  if (assignmentsError) throw new Error(`Could not load assigned patients: ${assignmentsError.message}`);
  if (catalogError) throw new Error(`Could not load exercise catalog: ${catalogError.message}`);

  const patients = (assignments ?? []).flatMap(({ patient }) => patient ? [{
    id: patient.id,
    name: patient.full_name?.trim() || `PT-${patient.id.slice(0, 8).toUpperCase()}`,
    caseCode: `PT-${patient.id.slice(0, 8).toUpperCase()}`,
  }] : []);

  let sessions = [];
  let reviews = [];
  let therapistReviews = [];
  if (patients.length) {
    const { data, error } = await supabase
      .from('exercise_sessions')
      .select('id, patient_id, exercise_id, kind, started_at, ended_at, duration_seconds, completed_reps, completed_sets, invalid_reps, cues_presented, overall_score, pose_score, motion_score, experimental_only, media_session_id')
      .in('patient_id', patients.map(({ id }) => id))
      .order('ended_at', { ascending: false })
      .limit(1000);
    if (error) throw new Error(`Could not load exercise sessions: ${error.message}`);
    sessions = data ?? [];
    if (sessions.length) {
      const sessionIds = sessions.map(({ id }) => id);
      const [
        { data: reviewData, error: reviewError },
        { data: therapistReviewData, error: therapistReviewError },
      ] = await Promise.all([
        supabase
          .from('session_ai_reviews')
          .select('session_id, status, review, model, generated_at')
          .in('session_id', sessionIds),
        supabase
          .from('session_therapist_reviews')
          .select('session_id, therapist_id, body, created_at, updated_at')
          .in('session_id', sessionIds),
      ]);
      if (reviewError) throw new Error(`Could not load session AI reviews: ${reviewError.message}`);
      reviews = reviewData ?? [];
      if (therapistReviewError) throw new Error(`Could not load therapist session reviews: ${therapistReviewError.message}`);
      therapistReviews = therapistReviewData ?? [];
    }
  }

  return (
    <SessionHistoryWorkspace
      catalog={catalog ?? []}
      initialReviews={reviews}
      initialSessions={sessions}
      initialTherapistReviews={therapistReviews}
      onSignOut={signOut}
      patients={patients}
      therapist={{ name: profile.full_name || claims?.email || 'Therapist', role: profile.role }}
    />
  );
}
