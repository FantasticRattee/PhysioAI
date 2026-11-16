export const APP_ROLES = Object.freeze({
  therapist: 'therapist',
  patient: 'patient',
});

export function canUseTherapistWeb(role) {
  return role === APP_ROLES.therapist;
}

export function canUsePatientApp(role) {
  return role === APP_ROLES.patient;
}
