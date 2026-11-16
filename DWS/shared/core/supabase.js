import { createClient } from '@supabase/supabase-js';

let singleton = null;
let singletonKey = '';
const DEFAULT_PUBLIC_ENV = Object.freeze({
  NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
});

function clean(value) {
  return String(value || '').trim();
}

export function readSupabaseConfig(env = DEFAULT_PUBLIC_ENV) {
  const url = clean(env?.NEXT_PUBLIC_SUPABASE_URL);
  const publishableKey = clean(env?.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY);
  const configured = Boolean(url && publishableKey);

  if (!configured) return { configured: false, url: '', publishableKey: '' };

  let parsed;
  try {
    parsed = new URL(url);
  } catch {
    throw new Error('invalid_supabase_url');
  }
  if (parsed.protocol !== 'https:' || !parsed.hostname.endsWith('.supabase.co')) {
    throw new Error('invalid_supabase_url');
  }
  if (!publishableKey.startsWith('sb_publishable_')) {
    throw new Error('invalid_supabase_publishable_key');
  }

  return { configured: true, url: parsed.origin, publishableKey };
}

export function isSupabaseConfigured(env = DEFAULT_PUBLIC_ENV) {
  try {
    return readSupabaseConfig(env).configured;
  } catch {
    return false;
  }
}

export function getSupabaseClient({
  env = DEFAULT_PUBLIC_ENV,
  createClientImpl = createClient,
} = {}) {
  const config = readSupabaseConfig(env);
  if (!config.configured) return null;

  const cacheKey = `${config.url}|${config.publishableKey}`;
  if (createClientImpl === createClient && singleton && singletonKey === cacheKey) return singleton;

  const client = createClientImpl(config.url, config.publishableKey, {
    auth: {
      autoRefreshToken: true,
      detectSessionInUrl: true,
      persistSession: true,
    },
    realtime: {
      params: { eventsPerSecond: 10 },
    },
  });

  if (createClientImpl === createClient) {
    singleton = client;
    singletonKey = cacheKey;
  }
  return client;
}

function missingSessionError(error) {
  return error?.name === 'AuthSessionMissingError'
    || ['session_not_found', 'refresh_token_not_found', 'invalid_refresh_token'].includes(error?.code);
}

export async function getSupabaseSessionAppUser(client = getSupabaseClient()) {
  if (!client?.auth?.getSession) return null;
  const { data, error } = await client.auth.getSession();
  if (error) {
    if (missingSessionError(error)) return null;
    throw error;
  }
  const authUser = data?.session?.user;
  if (!authUser?.id) return null;
  const role = String(authUser.app_metadata?.role || '').trim();
  return {
    id: authUser.id,
    email: authUser.email || '',
    name: authUser.user_metadata?.display_name
      || authUser.user_metadata?.name
      || authUser.email
      || '',
    // Supabase app_metadata can only be changed with administrator privileges.
    role,
  };
}

export async function getSupabaseAppUser(client = getSupabaseClient()) {
  if (!client) return null;
  const { data: authData, error: authError } = await client.auth.getUser();
  if (authError) {
    if (missingSessionError(authError)) return null;
    throw authError;
  }
  if (!authData?.user?.id) return null;

  const { data: profile, error: profileError } = await client
    .from('profiles')
    .select('id,email,display_name,role')
    .eq('id', authData.user.id)
    .single();
  if (profileError) throw profileError;

  return {
    id: profile.id,
    email: profile.email || authData.user.email || '',
    name: profile.display_name || authData.user.email || '',
    role: profile.role,
  };
}

export default getSupabaseClient;
