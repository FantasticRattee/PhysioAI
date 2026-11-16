import { redirect } from 'next/navigation';
import Logo from '../../src/components/Logo.jsx';
import { getAuthContext } from '../../utils/auth.js';
import LoginForm from './LoginForm.jsx';

export const metadata = {
  title: 'Therapist Login · PhysioAI',
};

export default async function LoginPage() {
  const { profile } = await getAuthContext();
  if (profile?.role === 'therapist') redirect('/therapist/plan');

  return (
    <main className="auth-page">
      <section className="auth-card" aria-labelledby="therapist-login-title">
        <Logo compact />
        <div className="auth-heading">
          <span className="role-badge">THERAPIST</span>
          <h1 id="therapist-login-title">เข้าสู่ระบบนักกายภาพ</h1>
          <p>ใช้บัญชี Supabase ที่ได้รับ role <code>therapist</code></p>
        </div>
        <LoginForm />
        <p className="auth-footnote">
          บัญชี <code>patient</code> ใช้งานผ่านแอป PhysioAI บน iPhone เท่านั้น
        </p>
      </section>
    </main>
  );
}
