import { NextResponse } from 'next/server';
import { requestJson, withMediaAuth } from '../../../../../utils/sessionMedia/http.js';
import { completeSegment } from '../../../../../utils/sessionMedia/service.js';

export async function POST(request) {
  return withMediaAuth(request, async (profile) => NextResponse.json(
    await completeSegment(profile, await requestJson(request)),
    { headers: { 'Cache-Control': 'private, no-store' } },
  ));
}
