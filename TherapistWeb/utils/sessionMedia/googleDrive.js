const DRIVE_API = 'https://www.googleapis.com/drive/v3';
const DRIVE_UPLOAD_API = 'https://www.googleapis.com/upload/drive/v3';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const FOLDER_MIME = 'application/vnd.google-apps.folder';

function required(name) {
  const value = String(process.env[name] || '').trim();
  if (!value) throw Object.assign(new Error('session_media_not_configured'), { status: 503 });
  return value;
}

function safeName(value, fallback) {
  const cleaned = String(value || '').normalize('NFKC').replace(/[\u0000-\u001f/\\]+/g, '-').trim().slice(0, 120);
  return cleaned || fallback;
}

function quoteQuery(value) {
  return String(value).replace(/\\/g, '\\\\').replace(/'/g, "\\'");
}

async function responseBody(response) {
  const text = await response.text();
  if (!text) return {};
  try { return JSON.parse(text); } catch { return { message: text }; }
}

export function googleDriveConfigured() {
  return Boolean(
    process.env.GOOGLE_DRIVE_CLIENT_ID
    && process.env.GOOGLE_DRIVE_CLIENT_SECRET
    && process.env.GOOGLE_DRIVE_REFRESH_TOKEN,
  );
}

export function createGoogleDriveClient({ fetchImpl = fetch } = {}) {
  const clientId = required('GOOGLE_DRIVE_CLIENT_ID');
  const clientSecret = required('GOOGLE_DRIVE_CLIENT_SECRET');
  const refreshToken = required('GOOGLE_DRIVE_REFRESH_TOKEN');
  let cachedToken = null;

  async function accessToken(force = false) {
    if (!force && cachedToken?.expiresAt > Date.now() + 60_000) return cachedToken.value;
    const response = await fetchImpl(TOKEN_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: clientId,
        client_secret: clientSecret,
        refresh_token: refreshToken,
        grant_type: 'refresh_token',
      }),
    });
    const body = await responseBody(response);
    if (!response.ok || !body.access_token) throw new Error('google_oauth_failed');
    cachedToken = {
      value: body.access_token,
      expiresAt: Date.now() + Math.max(60, Number(body.expires_in) || 3600) * 1000,
    };
    return cachedToken.value;
  }

  async function authorizedFetch(url, options = {}, retry = true) {
    const response = await fetchImpl(url, {
      ...options,
      headers: { ...(options.headers || {}), Authorization: `Bearer ${await accessToken(!retry)}` },
    });
    if (response.status === 401 && retry) {
      cachedToken = null;
      return authorizedFetch(url, options, false);
    }
    return response;
  }

  async function driveJson(url, options = {}) {
    const response = await authorizedFetch(url, options);
    const body = await responseBody(response);
    if (!response.ok) throw new Error(`google_drive_failed:${response.status}`);
    return body;
  }

  async function findFolder(name, parentId) {
    const url = new URL(`${DRIVE_API}/files`);
    url.searchParams.set('q', [
      `mimeType='${FOLDER_MIME}'`,
      `name='${quoteQuery(name)}'`,
      `'${quoteQuery(parentId)}' in parents`,
      'trashed=false',
    ].join(' and '));
    url.searchParams.set('spaces', 'drive');
    url.searchParams.set('pageSize', '1');
    url.searchParams.set('fields', 'files(id,name)');
    const body = await driveJson(url);
    return body.files?.[0] || null;
  }

  async function createFolder(name, parentId) {
    return driveJson(`${DRIVE_API}/files?fields=id,name`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ name, mimeType: FOLDER_MIME, parents: [parentId] }),
    });
  }

  async function ensureFolder(name, parentId) {
    return (await findFolder(name, parentId)) || createFolder(name, parentId);
  }

  async function ensureSessionFolder({ patientId, mediaSessionId, startedAt }) {
    const configuredRoot = String(process.env.GOOGLE_DRIVE_ROOT_FOLDER_ID || '').trim();
    const root = configuredRoot ? { id: configuredRoot } : await ensureFolder('PhysioAI-Sessions', 'root');
    const patient = await ensureFolder(safeName(`patient-${patientId}`, 'patient'), root.id);
    const date = String(startedAt || new Date().toISOString()).slice(0, 10);
    return ensureFolder(safeName(`${date}_${mediaSessionId}`, mediaSessionId), patient.id);
  }

  async function createResumableUpload({ folderId, name, mimeType, size, appProperties }) {
    const response = await authorizedFetch(`${DRIVE_UPLOAD_API}/files?uploadType=resumable&fields=id,name,size,mimeType,md5Checksum,parents`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json; charset=UTF-8',
        'x-upload-content-type': mimeType,
        'x-upload-content-length': String(size),
      },
      body: JSON.stringify({ name: safeName(name, 'session-video.mp4'), parents: [folderId], appProperties }),
    });
    if (!response.ok) throw new Error(`google_drive_upload_init_failed:${response.status}`);
    const uploadUrl = response.headers.get('location');
    if (!uploadUrl) throw new Error('google_drive_upload_location_missing');
    return uploadUrl;
  }

  async function getFile(fileId) {
    const url = new URL(`${DRIVE_API}/files/${encodeURIComponent(fileId)}`);
    url.searchParams.set('fields', 'id,name,size,mimeType,md5Checksum,parents,trashed');
    return driveJson(url);
  }

  async function download(fileId, range) {
    return authorizedFetch(`${DRIVE_API}/files/${encodeURIComponent(fileId)}?alt=media`, {
      headers: range ? { Range: range } : {},
    });
  }

  return { ensureSessionFolder, createResumableUpload, getFile, download };
}
