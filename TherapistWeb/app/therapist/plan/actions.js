'use server';

import { getAuthContext } from '../../../utils/auth.js';
import { canUseTherapistWeb } from '../../../utils/roles.js';

function isIntegerBetween(value, minimum, maximum) {
  return Number.isInteger(value) && value >= minimum && value <= maximum;
}

function isNumberBetween(value, minimum, maximum) {
  return Number.isFinite(value) && value >= minimum && value <= maximum;
}

export async function savePatientPlan(plan) {
  const { supabase, profile } = await getAuthContext();
  if (!profile || !canUseTherapistWeb(profile.role)) {
    return { error: 'ไม่มีสิทธิ์บันทึกแผนการรักษา' };
  }

  if (!plan || typeof plan.patientId !== 'string' || !Array.isArray(plan.items)) {
    return { error: 'รูปแบบแผนไม่ถูกต้อง' };
  }

  if (plan.items.length < 1 || plan.items.length > 3) {
    return { error: 'แผนต้องมีท่าฝึกอย่างน้อย 1 ท่า และไม่เกิน 3 ท่า' };
  }

  const { data: catalog, error: catalogError } = await supabase
    .from('exercise_catalog')
    .select('id')
    .eq('is_active', true);

  if (catalogError) {
    return { error: 'โหลดรายการท่าฝึกจากฐานข้อมูลไม่สำเร็จ' };
  }

  const allowedExerciseIds = new Set((catalog ?? []).map(({ id }) => id));

  const exerciseIds = new Set(plan.items.map(({ exerciseId }) => exerciseId));
  const validItems = exerciseIds.size === plan.items.length && plan.items.every((item) => (
    allowedExerciseIds.has(item.exerciseId)
    && isIntegerBetween(item.reps, 1, 100)
    && isIntegerBetween(item.sets, 1, 20)
    && isNumberBetween(item.holdSec, 0, 120)
  ));

  if (!validItems) {
    return { error: 'จำนวนครั้ง จำนวนเซ็ต หรือเวลาค้างของท่าฝึกไม่ถูกต้อง' };
  }

  if (!isIntegerBetween(plan.freqPerDay, 1, 10)
    || !isIntegerBetween(plan.durationDays, 1, 365)
    || typeof plan.startDate !== 'string'
    || !/^\d{4}-\d{2}-\d{2}$/.test(plan.startDate)
    || typeof plan.notes !== 'string'
    || plan.notes.length > 2000) {
    return { error: 'กำหนดการหรือหมายเหตุไม่ถูกต้อง' };
  }

  const { data: updatedAt, error } = await supabase.rpc('save_patient_plan', {
    target_patient_id: plan.patientId,
    target_items: plan.items.map((item) => ({
      exercise_id: item.exerciseId,
      reps: item.reps,
      sets: item.sets,
      hold_sec: item.holdSec,
    })),
    target_freq_per_day: plan.freqPerDay,
    target_start_date: plan.startDate,
    target_duration_days: plan.durationDays,
    target_notes: plan.notes,
  });

  if (error) {
    return { error: 'บันทึกแผนไม่สำเร็จ กรุณาตรวจสอบการเชื่อม Patient กับ Therapist' };
  }

  return { updatedAt };
}
