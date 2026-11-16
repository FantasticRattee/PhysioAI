export async function updateCallState(callId, status) {
  let lastError;
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      const response = await fetch('/api/cloudflare/calls', {
        method: 'PATCH', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ callId, status }), keepalive: status !== 'live',
        signal: AbortSignal.timeout(4000),
      });
      if (response.ok) return await response.json();
      if (response.status < 500) throw Object.assign(new Error(`call_${response.status}`), { permanent: true });
      throw new Error(`call_${response.status}`);
    } catch (error) {
      if (error.permanent) throw error;
      lastError = error;
    }
    if (attempt < 2) await new Promise((resolve) => setTimeout(resolve, 300 * (attempt + 1)));
  }
  throw lastError;
}
