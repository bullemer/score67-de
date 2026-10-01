# Implementation plan

## Increment 1A — first football loop (implemented, locally verified)

- [x] FastAPI app, persistent board/admin/match/event/receipt tables.
- [x] PostgreSQL-capable SQLAlchemy connection; SQLite development mode.
- [x] Scoreboard creation, six-digit PIN, hashed device cookie, PIN claim.
- [x] Device list/revocation, PIN rotation and database-backed basic limits.
- [x] Pure football rules: goals, periods, corrections, no-clock mode, finish/undo.
- [x] Revision conflicts, idempotent commands, cross-board checks.
- [x] Flutter creation, PIN, match control, settings and links screens.
- [x] HTML spectator board and transparent standard overlay.
- [x] Small/large/hidden, left/right, auto-large, delay and URL overrides.
- [x] Shared DE/EN translation files, WebSocket reconnect and polling fallback.
- [x] New match after finish; previous match retrievable by ID.
- [x] Automated backend/domain/display tests and Flutter analysis/release build.

This is the first development increment. It deliberately does not satisfy all of the original stage-1 requirements.

## Increment 1B — complete football pilot and release preparation

Requested usability extension implemented: device dashboard with game history/status filters, scheduling, archive/restore/delete; in-app back navigation; global language and new-game defaults. Creation throttling is disabled during testing and remains configurable for later use. Scheduling prepares games; kickoff is manual.

1. **Done:** Alembic baseline and the API/rules suite exercised against both SQLite and PostgreSQL. Production deployment from main, Nginx HTTPS, renewal, pre-deployment backups and daily backup timer are implemented; see PRODUCTION.md.
2. Implement email recovery with a configured SMTP provider/sender, expiring single-use hashed tokens, generic responses, rate limits and old-address notifications. Test token races and replay. Decide creation/rotation behavior when the response is lost.
3. Add QR codes, scoreboard language/name settings and admin last-used dates. Make first-load/retry errors explicit and refine the event log/undo distinction between match actions and display settings.
4. Conduct browser/mobile QA: 360 px width, 200% text scaling, keyboard/screen-reader controls, two devices, expired/revoked cookies, long team names and genuinely lost responses. Verify hold gestures and confirmation timing.
5. Provide verified operator/imprint/privacy content, TLS, reverse-proxy limits, log retention, backups, restore procedure and deployment restart behavior. Validate public creation abuse controls and proxy client IP forwarding.
6. Play a two-minute-per-half match in OBS; verify 720p legibility, transparent background, fixed-view sources and delay against the camera. Measure a 45-minute clock run and a 30-second network interruption. Record results before calling stage 1 complete.

Release blockers requiring external information: SMTP credentials/sender and the operator/legal content. These do not block local development. Server and GitHub deployment access were subsequently verified for the requested production deployment.

## Increment 2 — basketball, before roster polish

Introduce the profile, countdown state transitions, start/stop and direct remaining-time corrections. Cover all four requested formats, per-period team fouls, match-long personal fouls (number-only/unknown supported), timeouts and repeat overtime. Specify overtime team-foul carry-over and ties before implementing them. Add the basketball compact overlay. Football tests remain regression checks.

Acceptance: complete two-minute periods, repeated start/stop accuracy, countdown expiry without automatic period transition, format-specific foul defaults and period/overtime reset rules.

## Increment 3 — teams, rosters and lineups

Implemented early on request: optional per-game squads with number/name, goal and card attribution, yellow cards, reassignment and targeted corrections. Reusable teams and lineup presentation remain outstanding.

Add team/player/lineup tables with scoped ownership, minimal number-or-name validation and explicit public-name projection. Support starters/bench and large lineup display. Test 11+7 and 5+7 readability at 720p; hide personal fouls from public state.

## Increment 4 — goals and post-match output

Optional scorer selection after immediate team scoring; eight-second football goal banner; no stale celebration on reconnect; scorer/period summaries; corrections and text export. Introduce intentional semantics for older event edits rather than extending last-action undo accidentally.

## Increment 5 — design extension

Make standard/board the initial template implementations, then add bar/light, independent stream/screen selection, preview, retained custom colors, locally served font choices and re-encoded PNG/JPEG/WebP logos. Add quota, decompression-bomb and authorization tests for uploads. No arbitrary HTML/CSS uploads.

## Increment 6 — driven by actual use

Consider cards, substitutions, sponsor slots, other sports and homepage integrations only after the earlier versions have match-day evidence. Scale from measured database and live-connection load; do not introduce distributed services preemptively.
