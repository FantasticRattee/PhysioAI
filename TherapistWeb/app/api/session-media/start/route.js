import { NextResponse } from 'next/server';
import { requestJson, withMediaAuth } from '../../../../utils/sessionMedia/http.js';
import { startMedia } from '../../../../utils/sessionMedia/service.js';

export async function POST(request) {
  return withMediaAuth(request, async (profile) => NextResponse.json(
    await startMedia(profile, await requestJson(request)),
    { status: 201, headers: { 'Cache-Control': 'private, no-store' } },
  ));
}
