import { createClient } from './supabase/server.js';

export async function getAuthContext() {
  const supabase = await createClient();
  const { data: claimsData, error: claimsError } = await supabase.auth.getClaims();
  const userId = claimsData?.claims?.sub;

  if (claimsError || !userId) {
    return { supabase, claims: null, profile: null };
  }

  const { data: profile, error: profileError } = await supabase
    .from('profiles')
    .select('id, role, full_name')
    .eq('id', userId)
    .single();

  if (profileError || !profile) {
    return { supabase, claims: claimsData.claims, profile: null };
  }

  return { supabase, claims: claimsData.claims, profile };
}
