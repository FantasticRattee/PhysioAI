const TURN_CREDENTIAL_ENDPOINT = 'https://rtc.live.cloudflare.com/v1/turn/keys';
const DEFAULT_TTL_SECONDS = 3600;
const MAX_TTL_SECONDS = 172800;

export class CloudflareTurnConfigurationError extends Error {
  constructor() {
    super('cloudflare_turn_not_configured');
    this.name = 'CloudflareTurnConfigurationError';
  }
}

export function getTurnConfig() {
  const keyId = process.env.CLOUDFLARE_TURN_KEY_ID?.trim();
  const apiToken = process.env.CLOUDFLARE_TURN_KEY_API_TOKEN?.trim();
  const configuredTTL = Number.parseInt(process.env.PHYSIOAI_TURN_TTL_SECONDS ?? '', 10);
  const ttl = Number.isFinite(configuredTTL)
    ? Math.min(Math.max(configuredTTL, 300), MAX_TTL_SECONDS)
    : DEFAULT_TTL_SECONDS;
  if (!keyId || !apiToken) throw new CloudflareTurnConfigurationError();
  return { keyId, apiToken, ttl };
}

export async function generateIceServers(config) {
  const response = await fetch(
    `${TURN_CREDENTIAL_ENDPOINT}/${encodeURIComponent(config.keyId)}/credentials/generate-ice-servers`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${config.apiToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ ttl: config.ttl }),
      cache: 'no-store',
    },
  );
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !Array.isArray(payload.iceServers)) {
    throw new Error(payload.error ?? payload.message ?? `Cloudflare TURN HTTP ${response.status}`);
  }
  return payload.iceServers.map((server) => ({
    ...server,
    // Port 53 is intentionally removed because browsers commonly block it.
    urls: (Array.isArray(server.urls) ? server.urls : [server.urls]).filter((url) => !String(url).includes(':53')),
  })).filter((server) => server.urls.length > 0);
}
