export async function assignedPair(supabase, profile, patientId) {
  // Swift UUID.uuidString is uppercase; Postgres returns lowercase UUIDs.
  // Compare the identity, not its casing, while still denying other patients.
  const canonicalPatientId = patientId.toLowerCase();
  if (profile.role === 'patient' && profile.id.toLowerCase() !== canonicalPatientId) return null;
  if (!['patient', 'therapist'].includes(profile.role)) return null;

  let query = supabase.from('therapist_patient_assignments')
    .select('patient_id, therapist_id').eq('patient_id', canonicalPatientId);
  if (profile.role === 'therapist') query = query.eq('therapist_id', profile.id);
  const { data, error } = await query.maybeSingle();
  if (error) throw error;
  return data ?? null;
}
