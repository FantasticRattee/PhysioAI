import { createBrowserClient } from '@supabase/ssr';
import { getSupabaseConfig } from './config.js';

export function createClient() {
  const { url, publishableKey } = getSupabaseConfig();
  return createBrowserClient(url, publishableKey);
}
