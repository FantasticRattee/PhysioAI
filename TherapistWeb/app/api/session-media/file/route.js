import { NextResponse } from 'next/server';
import { withMediaAuth } from '../../../../utils/sessionMedia/http.js';
import { getMediaFile } from '../../../../utils/sessionMedia/service.js';

export async function GET(request) {
  return withMediaAuth(request, async (profile) => {
    const url = new URL(request.url);
    const { response, segment } = await getMediaFile(
      profile,
      url.searchParams.get('mediaSessionId'),
      url.searchParams.get('fileId'),
      request.headers.get('range') || '',
    );
    if (!response.ok) return NextResponse.json({ error: 'drive_download_failed' }, { status: response.status });
    const headers = new Headers({
      'Content-Type': response.headers.get('content-type') || segment.mime_type || 'video/mp4',
      'Cache-Control': 'private, no-store',
      'Content-Disposition': `inline; filename="${String(segment.name || 'session-video.mp4').replace(/["\\]/g, '_')}"`,
    });
    for (const name of ['content-length', 'content-range', 'accept-ranges', 'etag']) {
      const value = response.headers.get(name);
      if (value) headers.set(name, value);
    }
    return new Response(response.body, { status: response.status, headers });
  });
}
