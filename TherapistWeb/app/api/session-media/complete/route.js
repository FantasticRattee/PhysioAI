import { NextResponse } from 'next/server';
import { requestJson, withMediaAuth } from '../../../../utils/sessionMedia/http.js';
import { finishMedia } from '../../../../utils/sessionMedia/service.js';

export async function POST(request) {
  return withMediaAuth(request, async (profile) => NextResponse.json(
    await finishMedia(profile, await requestJson(request)),
    { headers: { 'Cache-Control': 'private, no-store' } },
  ));
}
