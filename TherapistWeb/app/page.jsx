import { redirect } from 'next/navigation';
import { getAuthContext } from '../utils/auth.js';
import { canUseTherapistWeb } from '../utils/roles.js';

export default async function HomePage() {
  const { profile } = await getAuthContext();
  if (!profile) redirect('/login');
  if (canUseTherapistWeb(profile.role)) redirect('/therapist/plan');
  redirect('/access-denied');
}
