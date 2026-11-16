// PhysioAI · Therapist (web) — backend API client.
//
// Same-origin by default: the root Next server owns both the frontend and API.
// Override before loading the app with: window.PHYSIOAI_API_BASE = 'https://...'
export const API_BASE = String(globalThis.PHYSIOAI_API_BASE || '').replace(/\/+$/, '');

let apiBase = API_BASE;
let tokenKey = 'physioai.v1.token';
let authTokenProvider = defaultAuthTokenProvider;

export function configureApi({
  base = null,
  tokenKey: nextTokenKey = null,
  authTokenProvider: nextAuthTokenProvider = null,
} = {}) {
  if (base != null) apiBase = String(base || '').replace(/\/+$/, '');
  if (nextTokenKey) tokenKey = String(nextTokenKey);
  if (typeof nextAuthTokenProvider === 'function') authTokenProvider = nextAuthTokenProvider;
}

export const isCloud = () => !!apiBase;

const DEFAULT_TIMEOUT_MS = 10000;
const DEFAULT_GET_RETRIES = 1;
export function getToken() { try { return localStorage.getItem(tokenKey); } catch { return null; } }
export function setToken(tk) { try { if (tk) localStorage.setItem(tokenKey, tk); else localStorage.removeItem(tokenKey); } catch {} }

async function defaultAuthTokenProvider() {
  // Keep the static patient runtime browser-compatible. Next.js resolves the
  // package import inside supabase.js when this lazy path is used by the web
  // workspaces, while the patient app injects its UMD-backed token provider
  // before making API requests.
  try {
    const { getSupabaseClient } = await import('./supabase.js');
    const supabase = getSupabaseClient();
    if (supabase) {
      const { data, error } = await supabase.auth.getSession();
      if (error) throw error;
      return data?.session?.access_token || null;
    }
  } catch (error) {
    const message = String(error?.message || '');
    const resolutionFailed = error?.code === 'ERR_MODULE_NOT_FOUND'
      || /failed to resolve module specifier|cannot find package/i.test(message);
    if (!resolutionFailed) throw error;
  }
  return getToken();
}

function timeoutError(path, timeoutMs) {
  const err = new Error('request_timeout');
  err.code = 'request_timeout';
  err.path = path;
  err.timeoutMs = timeoutMs;
  return err;
}

async function fetchWithTimeout(url, options, timeoutMs) {
  if (!timeoutMs || typeof AbortController === 'undefined') return fetch(url, options);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal });
  } catch (error) {
    if (error?.name === 'AbortError') throw timeoutError(url, timeoutMs);
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

async function req(path, { method = 'GET', body, auth = true, timeoutMs = DEFAULT_TIMEOUT_MS, retries } = {}) {
  const headers = { 'content-type': 'application/json' };
  if (auth) {
    const tk = await authTokenProvider();
    if (tk) headers.authorization = 'Bearer ' + tk;
  }
  const safeMethod = String(method || 'GET').toUpperCase();
  const maxRetries = safeMethod === 'GET' ? Number(retries ?? DEFAULT_GET_RETRIES) || 0 : 0;
  let attempt = 0;
  let res = null;
  while (attempt <= maxRetries) {
    try {
      res = await fetchWithTimeout(apiBase + path, {
        method: safeMethod,
        headers,
        body: body != null ? JSON.stringify(body) : undefined,
      }, timeoutMs);
      break;
    } catch (error) {
      if (attempt >= maxRetries) throw error;
      attempt += 1;
      continue;
    }
  }
  let data = null;
  try { data = await res.json(); } catch {}
  if (!res.ok) {
    const err = new Error((data && data.error) || ('http_' + res.status));
    err.code = data && data.error;
    err.detail = data && data.message;
    err.status = res.status;
    throw err;
  }
  return data;
}

export const apiGet = (p, opts) => req(p, { method: 'GET', ...(opts || {}) });
export const apiPost = (p, body, opts) => req(p, { method: 'POST', body, ...(opts || {}) });
export const apiPut = (p, body, opts) => req(p, { method: 'PUT', body, ...(opts || {}) });
export const apiDelete = (p, body, opts) => req(p, { method: 'DELETE', body, ...(opts || {}) });
