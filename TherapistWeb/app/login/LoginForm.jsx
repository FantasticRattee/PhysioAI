'use client';

import { useActionState } from 'react';
import { useFormStatus } from 'react-dom';
import { login } from '../auth/actions.js';

function SubmitButton() {
  const { pending } = useFormStatus();
  return (
    <button className="button primary auth-submit" disabled={pending} type="submit">
      {pending ? 'กำลังเข้าสู่ระบบ…' : 'เข้าสู่ระบบ Therapist'}
    </button>
  );
}

export default function LoginForm() {
  const [state, formAction] = useActionState(login, { error: '' });

  return (
    <form action={formAction} className="auth-form">
      <label htmlFor="email">
        <span>อีเมล</span>
        <input autoComplete="email" id="email" name="email" required type="email" />
      </label>
      <label htmlFor="password">
        <span>รหัสผ่าน</span>
        <input autoComplete="current-password" id="password" name="password" required type="password" />
      </label>
      {state.error ? <p className="auth-error" role="alert">{state.error}</p> : null}
      <SubmitButton />
    </form>
  );
}
