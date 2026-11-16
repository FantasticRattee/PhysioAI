import { NextResponse } from 'next/server';
import { withMediaAuth } from '../../../utils/sessionMedia/http.js';
import { getManifest } from '../../../utils/sessionMedia/service.js';

export async function GET(request) {
  return withMediaAuth(request, async (profile) => {
    const mediaSessionId = new URL(request.url).searchParams.get('mediaSessionId');
    return NextResponse.json(await getManifest(profile, mediaSessionId), {
      headers: { 'Cache-Control': 'private, no-store' },
    });
  });
}
