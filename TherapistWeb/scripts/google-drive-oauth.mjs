import process from 'node:process';

const AUTH_URL = 'https://accounts.google.com/o/oauth2/v2/auth';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';
const DRIVE_FILE_SCOPE = 'https://www.googleapis.com/auth/drive.file';

function required(name) {
  const value = String(process.env[name] || '').trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function redirectUri() {
  return String(process.env.GOOGLE_DRIVE_REDIRECT_URI || 'http://127.0.0.1:53682/oauth2/callback').trim();
}

function authorizationUrl() {
  const url = new URL(AUTH_URL);
  url.searchParams.set('client_id', required('GOOGLE_DRIVE_CLIENT_ID'));
  url.searchParams.set('redirect_uri', redirectUri());
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('scope', DRIVE_FILE_SCOPE);
  url.searchParams.set('access_type', 'offline');
  url.searchParams.set('prompt', 'consent');
  url.searchParams.set('include_granted_scopes', 'true');
  return url.toString();
}

async function exchange(code) {
  if (!code) throw new Error('Pass the authorization code after "exchange"');
  const response = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      client_id: required('GOOGLE_DRIVE_CLIENT_ID'),
      client_secret: required('GOOGLE_DRIVE_CLIENT_SECRET'),
      code,
      grant_type: 'authorization_code',
      redirect_uri: redirectUri(),
    }),
  });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || !body.refresh_token) {
    throw new Error(`Google OAuth exchange failed: ${body.error_description || body.error || response.status}`);
  }
  process.stdout.write(`GOOGLE_DRIVE_REFRESH_TOKEN=${body.refresh_token}\n`);
}

const command = process.argv[2] || 'url';
if (command === 'url') process.stdout.write(`${authorizationUrl()}\n`);
else if (command === 'exchange') await exchange(process.argv[3]);
else throw new Error('Use "url" or "exchange <authorization-code>"');
