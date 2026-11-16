import { Noto_Sans_Thai, Nunito } from 'next/font/google';
import './globals.css';

const thai = Noto_Sans_Thai({
  subsets: ['thai', 'latin'],
  variable: '--font-thai',
  display: 'swap',
});

const nunito = Nunito({
  subsets: ['latin'],
  variable: '--font-nunito',
  display: 'swap',
});

export const metadata = {
  title: 'PhysioAI · Therapist Plan Builder',
  description: 'สร้างโปรแกรมกายภาพสำหรับผู้ป่วยด้วย PhysioAI',
  icons: { icon: '/favicon.svg' },
};

export default function RootLayout({ children }) {
  return (
    <html lang="th" className={`${thai.variable} ${nunito.variable}`}>
      <body>{children}</body>
    </html>
  );
}
