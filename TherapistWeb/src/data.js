export function localDateString(date = new Date()) {
  const offset = date.getTimezoneOffset() * 60_000;
  return new Date(date.getTime() - offset).toISOString().slice(0, 10);
}

export function makePlanItem(exercise) {
  return {
    exerciseId: exercise.id,
    reps: exercise.reps,
    sets: exercise.sets,
    holdSec: exercise.holdSec,
  };
}

export function makeDefaultPlan(patientId, startDate = localDateString()) {
  return {
    patientId,
    items: [],
    freqPerDay: 2,
    startDate,
    durationDays: 28,
    notes: '',
    updatedAt: null,
  };
}
