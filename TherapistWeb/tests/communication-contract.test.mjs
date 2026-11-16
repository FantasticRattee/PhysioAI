import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const migration = await readFile(new URL('../../supabase/migrations/20260831083756_create_pair_communications.sql', import.meta.url), 'utf8');
const callIdentityMigration = await readFile(new URL('../../supabase/migrations/20260831085942_lock_communication_call_identity.sql', import.meta.url), 'utf8');
const chatWorkspace = await readFile(new URL('../src/ChatWorkspace.jsx', import.meta.url), 'utf8');
const callRoute = await readFile(new URL('../app/api/cloudflare/calls/route.js', import.meta.url), 'utf8');
const assignmentLookup = await readFile(new URL('../utils/cloudflare/assignedPair.js', import.meta.url), 'utf8');
const signalRoute = await readFile(new URL('../app/api/cloudflare/signals/route.js', import.meta.url), 'utf8');
const turnClient = await readFile(new URL('../utils/cloudflare/turn.js', import.meta.url), 'utf8');
const turnMigration = await readFile(new URL('../../supabase/migrations/20260831222000_replace_realtimekit_with_turn.sql', import.meta.url), 'utf8');

test('communication messages are append-only and constrained to an assigned pair', () => {
  assert.match(migration, /foreign key \(patient_id, therapist_id\)[\s\S]*therapist_patient_assignments/);
  assert.match(migration, /grant select, insert on table public\.communication_messages/);
  assert.doesNotMatch(migration, /grant[^;]*update[^;]*communication_messages/i);
  assert.match(migration, /sender_id = \(select auth\.uid\(\)\)/);
});

test('chat UI subscribes to RLS-protected database changes and sends as the therapist', () => {
  assert.match(chatWorkspace, /table: 'communication_messages'/);
  assert.match(chatWorkspace, /sender_id: therapist\.id/);
  assert.match(chatWorkspace, /\/api\/cloudflare\/calls/);
});

test('Cloudflare TURN secret remains server-side and assignment is checked before issuing credentials', () => {
  assert.match(assignmentLookup, /therapist_patient_assignments/);
  assert.match(callRoute, /await assignedPair\(supabase, profile, patientId\)/);
  assert.match(callRoute, /pair_not_assigned/);
  assert.match(turnClient, /CLOUDFLARE_TURN_KEY_API_TOKEN/);
  assert.doesNotMatch(chatWorkspace, /CLOUDFLARE_TURN_KEY_API_TOKEN/);
  assert.match(turnClient, /generate-ice-servers/);
});

test('video calls are discoverable in both directions and close their active state', () => {
  assert.match(chatWorkspace, /refreshIncomingCall/);
  assert.match(chatWorkspace, /joinIncomingVideoCall/);
  assert.match(chatWorkspace, /updateCallState\(callId, 'ended'\)/);
  assert.match(callRoute, /export async function PATCH/);
  assert.match(callRoute, /transitionCall\(supabase, callId, status\)/);
  assert.match(callIdentityMigration, /communication_calls_lock_identity/);
  assert.match(turnMigration, /signaling_session_id is distinct from old\.signaling_session_id/);
  assert.match(signalRoute, /communication_call_signals/);
  assert.match(turnMigration, /expires_at[\s\S]*24 hours/);
});
