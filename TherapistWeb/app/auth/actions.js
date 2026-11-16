'use server';

import { redirect } from 'next/navigation';
import { createClient } from '../../utils/supabase/server.js';
import { canUseTherapistWeb } from '../../utils/roles.js';

export async function login(_previousState, formData) {
  const email = String(formData.get('email') ?? '').trim().toLowerCase();
  const password = String(formData.get('password') ?? '');

  if (!email || !password) {
    return { error: 'กรุณากรอกอีเมลและรหัสผ่าน' };
  }

  const supabase = await createClient();
  const { error: signInError } = await supabase.auth.signInWithPassword({ email, password });

  if (signInError) {
    return { error: 'อีเมลหรือรหัสผ่านไม่ถูกต้อง' };
  }

  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  const userId = claimsData?.claims?.sub;
  if (claimsError || !userId) {
    await supabase.auth.signOut();
    return { error: 'ตรวจสอบ session ไม่สำเร็จ กรุณาลองอีกครั้ง' };
  }

  const { data: profile, error: profileError } = await supabase
    .from('profiles')
    .select('role')
    .eq('id', userId)
    .single();

  if (profileError || !profile) {
    await supabase.auth.signOut();
    return { error: 'บัญชีนี้ยังไม่มี authorization profile' };
  }

  if (!canUseTherapistWeb(profile.role)) {
    await supabase.auth.signOut();
    return { error: 'บัญชี patient ใช้งานผ่านแอป PhysioAI บน iPhone' };
  }

  redirect('/therapist/plan');
}

export async function signOut() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect('/login');
}
