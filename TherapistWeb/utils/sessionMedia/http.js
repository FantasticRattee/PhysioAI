import { NextResponse } from 'next/server';
import { getRequestAuthContext } from '../requestAuth.js';

export async function withMediaAuth(request, operation) {
  const { profile } = await getRequestAuthContext(request);
  if (!profile) return NextResponse.json({ error: 'unauthorized' }, { status: 401 });
  try {
    return await operation(profile);
  } catch (error) {
    console.error('Session media request failed', error?.message || error);
    return NextResponse.json(
      { error: error?.message || 'session_media_failed' },
      { status: error?.status || 500, headers: { 'Cache-Control': 'private, no-store' } },
    );
  }
}

export async function requestJson(request) {
  return request.json().catch(() => ({}));
}
