import { redirect } from 'next/navigation';
import ChatWorkspace from '../../../src/ChatWorkspace.jsx';
import { signOut } from '../../auth/actions.js';
import { getAuthContext } from '../../../utils/auth.js';
import { canUseTherapistWeb } from '../../../utils/roles.js';

export const metadata = { title: 'ข้อความ · PhysioAI Therapist' };

export default async function TherapistMessagesPage() {
  const { supabase, claims, profile } = await getAuthContext();
  if (!profile) redirect('/login');
  if (!canUseTherapistWeb(profile.role)) redirect('/access-denied');

  const { data: assignments, error: assignmentsError } = await supabase
    .from('therapist_patient_assignments')
    .select('patient_id, patient:profiles!therapist_patient_assignments_patient_id_fkey(id, full_name)')
    .eq('therapist_id', profile.id)
    .order('assigned_at', { ascending: true });
  if (assignmentsError) throw new Error(`Could not load assigned patients: ${assignmentsError.message}`);

  const patients = (assignments ?? []).flatMap(({ patient }) => patient ? [{
    id: patient.id,
    name: patient.full_name?.trim() || `PT-${patient.id.slice(0, 8).toUpperCase()}`,
  }] : []);

  let messageRows = [];
  if (patients.length) {
    const { data, error } = await supabase
      .from('communication_messages')
      .select('id, patient_id, therapist_id, sender_id, body, created_at')
      .eq('therapist_id', profile.id)
      .in('patient_id', patients.map(({ id }) => id))
      .order('created_at', { ascending: true })
      .limit(500);
    if (error) throw new Error(`Could not load messages: ${error.message}`);
    messageRows = data ?? [];
  }

  const initialMessages = Object.fromEntries(patients.map(({ id }) => [id, messageRows.filter(({ patient_id }) => patient_id === id)]));
  return <ChatWorkspace initialMessages={initialMessages} onSignOut={signOut} patients={patients} therapist={{ id: profile.id, name: profile.full_name || claims?.email || 'Therapist', role: profile.role }} />;
}
