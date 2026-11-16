# Stable rollback snapshot — 2026-09-09

User-selected stable snapshot for both patient iPhone and Therapist Web.

## Active baseline

This snapshot is also the user-selected active baseline as of 2026-09-09.
`physioai-baseline-2026-09-09` and `physioai-stable-2026-09-09` both resolve to
`85e7750cf0d6ba0f055dc398574492536f81b37f`. Subsequent documentation updates do
not move either immutable tag. Application code remains `41625b1`.

- Immutable Git tag: `physioai-stable-2026-09-09`
- Application code commit: `41625b11f363f45d94ce455285f76db4ecd42436`
- The tag includes this release record and README update; application code is unchanged.
- Embedded versions remain iOS 8.0.16 / build 16 and Web 0.15.3. Use the Git tag,
  not those reused version numbers, to identify this exact rollback snapshot.
- Prior baseline tags remain untouched.

## Included behavior

- DWS preparation page, TTS and session scoreboard.
- Incomplete-hold events require SDK hold time > 2 seconds and < 5 seconds.
- Scoreboard shows recorded completion, not a claim that AI confirmed all form.
- DWS-only AI comments focus on available results without stock missing-data text.
- Existing DWS runtime, mirror behavior and fallback counting are unchanged.

## Verification and limits

- Web: 37 tests pass; production build succeeds.
- iOS: eight DWS integration tests passed before the final display-only change;
  latest signed build succeeded and installed/launched on the connected iPhone.
- Railway deployment `1ccdccc8-61d9-4aa2-af37-fd607d562904` succeeded for the
  application code commit; `/login` returned HTTP 200.
- This is a user-selected rollback point, not clinical validation. The reported
  DWS left/right behavior remains uninvestigated in full; the live hold message
  may say AI and rules agree during fallback. Neither issue is fixed here.

## Restore without overwriting current work

```bash
git fetch origin --tags
git worktree add --detach ../PhysioAI-stable-2026-09-09 physioai-stable-2026-09-09
```

Build/install iOS from that separate checkout using its existing setup instructions.
For Web, use Railway's deployment rollback for the successful deployment above,
or deploy the tagged source through the reviewed GitHub workflow. Do not force-push
main or move the tag. Environment variables, database data, credentials and Drive
videos are not backed up by Git. Keep the additive `dws_metrics` migration; a code
rollback does not authorize deleting session data or reversing database migrations.
