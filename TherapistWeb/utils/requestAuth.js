import { createClient as createSupabaseClient } from '@supabase/supabase-js';
import { getAuthContext } from './auth.js';
import { getSupabaseConfig } from './supabase/config.js';

export async function getRequestAuthContext(request) {
  const authorization = request.headers.get('authorization');
  if (!authorization?.startsWith('Bearer ')) return getAuthContext();

  const token = authorization.slice('Bearer '.length).trim();
  const { url, publishableKey } = getSupabaseConfig();
  const supabase = createSupabaseClient(url, publishableKey, {
    auth: { autoRefreshToken: false, persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: { user }, error: userError } = await supabase.auth.getUser(token);
  if (userError || !user) return { supabase, claims: null, profile: null };
  const { data: profile } = await supabase.from('profiles').select('id, role, full_name').eq('id', user.id).single();
  return { supabase, claims: { sub: user.id, email: user.email }, profile };
}
