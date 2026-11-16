import Logo from '../../src/components/Logo.jsx';
import { signOut } from '../auth/actions.js';

export const metadata = {
  title: 'Access denied · PhysioAI',
};

export default function AccessDeniedPage() {
  return (
    <main className="auth-page">
      <section className="auth-card" aria-labelledby="access-denied-title">
        <Logo compact />
        <div className="auth-heading">
          <span className="role-badge patient">PATIENT</span>
          <h1 id="access-denied-title">บัญชีนี้เข้า Therapist Web ไม่ได้</h1>
          <p>บัญชี patient ใช้งานผ่านแอป PhysioAI บน iPhone</p>
        </div>
        <form action={signOut}>
          <button className="button primary auth-submit" type="submit">ออกจากระบบ</button>
        </form>
      </section>
    </main>
  );
}
