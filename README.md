# Score67

A small, self-hosted scoreboard for sports streams. This checkout contains the **football MVP and basketball pilot**, deployed directly from `main`; it is not the complete specification.

Original requirements remain unchanged in `Spezifikation Scoreboard für Sport-Livestreams.md` and `Score67-Designs-und-Vorlagen.docx`.

- [Critical assessment and decisions](docs/PROJECT-ANALYSIS.md)
- [Implementation stages and acceptance checklist](docs/IMPLEMENTATION-PLAN.md)
- [API and implementation notes](docs/ARCHITECTURE.md)
- [Production deployment, certificates and backups](docs/PRODUCTION.md)

## Run locally

Requires Python 3.11+, uv, and Flutter (built with Flutter 3.38.9 / Dart 3.10.8). Node 22 is used only for display unit tests.

```bash
cd /home/carsten/DEVPROJECTS/score67-de
python scripts/stamp_release.py
cd control
flutter pub get
flutter build web --release --base-href /app/ --no-web-resources-cdn
cd ../backend
uv sync --locked
COOKIE_SECURE=false uv run uvicorn score67.app:app --host 127.0.0.1 --port 8067 --workers 1
```

Open http://127.0.0.1:8067. Create a board, **save its PIN**, and open its control link. The OBS URL is shown under Links & access. Use a browser source of 1920 × 1080. Add `?preview=1` for an opaque browser preview.

The development database is `backend/data/score67.db` when started from `backend/`. It survives restarts. Local HTTP requires `COOKIE_SECURE=false`; production defaults to secure cookies. Flutter is served by FastAPI under the same origin, without a separate development server or CORS setup. The release build bundles renderer assets locally.

## Included

- Optional private description (up to 300 characters) and planned start time when creating a scoreboard; the controller and dashboard show the description, creation time and scheduled start. Edit the description in the controller.
- Optional venue with browser/mobile geolocation, draggable map pin, coordinate/Google Maps link import, and a private-by-default visibility switch. Edit/remove it in the controller.
- Independent football and basketball scoreboards; automatic timestamp labels, random public links and six-digit PINs.
- Hashed device cookies, additional devices, revocation, PIN rotation and persistent rate limits.
- Flutter phone controller; Jinja/HTML landing page, spectator page and transparent OBS overlay.
- Home/Guest defaults, editable names and abbreviations, 1–12 periods of 1–60 minutes, optional clock.
- Red and yellow cards per team with plus/minus correction, undo and live card icons in spectator/OBS views.
- Optional per-game squads (up to 40 players per team): shirt number, name or both; goal/card attribution, later reassignment and a public event log. Second-yellow dismissals are recorded manually as a red card.
- Plus/minus goals, tap-to-edit team names and colors, period transitions, clock correction, final whistle, undo and new games. Archived match state remains available by ID.
- Revision checks, idempotent command retries, persistent event records and reconnecting live state.
- Taps never wait for each other: points, fouls, rebounds, timeouts and cards are queued, shown immediately and sent in order. Without a connection they stay on the device (also across reloads) and are sent automatically with their original command IDs, so nothing is counted twice. Clock, period and settings changes still require a live connection. The controller keeps the phone screen awake where the browser supports it.
- Small, large, hidden, left/right and automatic break/final views; configurable broadcast delay.
- Shared German and English JSON translations.
- Trash (Papierkorb): an hourly cleaner moves games that were started but not ended and had no activity for 24 h, planned games still not started 24 h after their start time, and unscheduled games untouched for 7 days to the trash. Finished games are never touched. Trashed games leave live views; restore them from the dashboard within 30 days, after which they are deleted. "Move to trash" on the dashboard does the same by hand. Thresholds: `TRASH_STALE_HOURS`, `TRASH_PLANNED_GRACE_HOURS`, `TRASH_UNSCHEDULED_DAYS`, `TRASH_RETENTION_DAYS`, `TRASH_INTERVAL_SECONDS` (0 disables).
- Device dashboard at `/dashboard`: planned (with or without a date), running, completed and archived games; archive, restore and delete controls.
- Public `/live` directory of active games, including breaks, with automatically updated scores, clocks and red cards. No sign-in required.
- WhatsApp, Facebook, copy-link and native sharing for spectator links from the public view and controller.
- Future games can be prepared without interrupting the live game. Opening their controls activates them; kickoff remains manual.
- Visible back navigation and global language/default game-format settings, saved on this browser.

The five-scoreboards-per-hour creation cap is disabled during testing. `SCOREBOARD_CREATE_LIMIT=0` (default) keeps it off; a positive value enables an hourly IP limit later. PIN protection remains enabled.

## Basketball pilot (v0.7)

Choose Basketball when creating a scoreboard or preparing a game in the dashboard. Presets: 4 × 10 (default), 4 × 12, 8 × 5 and 2 × 20; custom lengths/counts remain editable in match settings. Games remain planned until the operator prepares the first period. Preparing a period resets its countdown and leaves it stopped; use Start clock at the referee’s signal. At zero the clock stops without ending the period automatically. Set remaining time uses MM:SS.

Scoring supports +1/+2/+3 whether the clock runs or not; made baskets do not stop the clock. Use the Play/Stop button in the header for whistles and timeouts. Each team has a squad editor; basketball squad entries require shirt numbers. With a squad, tap +1, +2 or +3 in the player’s row of the scoring matrix. The first matrix row is always Unknown player, including when a squad exists. Use this row to record points without player attribution. Remove event reverses the full selected basket; add a replacement if its value was wrong. Team fouls reset between regular periods and carry from the last regular period through repeated five-minute overtime. Overtime is offered after ending the final period with tied scores. Timeouts stop the clock and count total used across the game; competition-specific quotas are not enforced. Foul modes are team, personal, both, or off; 8 × 5 defaults to personal fouls. Personal foul totals and number-only entries remain private to controllers, with warnings at four and five fouls. Automatic player disqualification, shot clock and period-result summaries are not included.

### Football console (landscape)

Football uses the same landscape console. Header: menu, short name, yellow/red card and foul counts, scores, half, running clock and a Play button that kicks off each half (the football clock is not stopped). Team columns show the team tile plus the players on the pitch (lineup of up to 11, otherwise the squad) and scroll vertically; tiles show goals and yellow/red cards. Actions: GOAL, YELLOW, RED, PENALTY, FOUL, FREE KICK, Undo, SUBSTITUTIONS — action first, then player or team tile. PENALTY records the awarded penalty and offers an inline Goal/Missed bar; Goal records a goal marked "penalty". The Period tab has kick-off/half-time/final whistle and clock corrections. Fouls, free kicks, penalties awarded and lineups stay private to controllers.

### Team tab

The console's middle panel has the tabs Spielverlauf (game flow), Team, Periods, Einstellungen and Teilen. Team edits both rosters inline: shirt number, optional name (basketball requires numbers) and an on-court checkbox (max. 5 in basketball, 11 in football). A new empty row appears automatically; a pasted list ("7 Alex" per line) can be imported. Save sends the squad, then the lineup; ticked players appear in the left columns and can be selected for actions. Unsaved edits are kept per team while switching teams or tabs (marked with •).

Double-tap a team tile to edit the team name, short name and colour; double-tap a player tile to change number or name (only while no action is selected, so scoring taps stay instant). In basketball, Play also opens the next period or overtime and starts the clock in one tap.

### Private games

Games are public by default. The "Private game" switch at the top of the Sharing tab hides the spectator page (it shows a private notice), the public state API, live socket and the /live directory from everyone except this board's control devices. The OBS overlay link carries an overlay key (`?k=…`) and keeps working while private; switching back to public re-enables all sharing links.

### Game flow

Spielverlauf shows sporting events only: clock start/stop, squad edits, settings and the pre-game lineup are recorded but hidden; in-game substitutions are shown. Undo removes the last visible entry (a score after a hidden clock stop is removed without restarting the clock).

### Formats at creation

The create form has free controls for the number of periods (1–12) and the length per period (1–120 min): − / + buttons around a typeable number, plus one-tap presets (football 2×45, 2×40, 2×35, 2×30, 2×20, 1×10; basketball 4×10, 4×12, 8×5, 2×20). Defaults: football 2 × 45, basketball 4 × 10, reset when switching sport.

### Sharing tab and creation

Creating a scoreboard opens the console directly. The console's Sharing tab shows the admin PIN (kept only in the creating or renewing browser, because the server stores it hashed), PIN renewal, device management, social sharing and the spectator, OBS and control links.

### Basketball console (landscape)

The live basketball control is a full-screen landscape console modelled on InGame. Header: menu, possession arrow per team (tap to set), team fouls (amber at 4, red from 5), timeouts used/allowed in the current window (FIBA 2 first half, 3 second half, 1 per overtime; total only for other formats), both scores in team colours, period, connection, clock (tap to set) and Play/Stop. Left: one column per team — the team tile (3-letter short name) and the players on court (or the whole squad until a lineup is set), each with a five-segment foul bar and points. Right: FREE THROW, 2 POINTS, 3 POINTS, FOUL, TECH. F., T.O., Undo and SUBSTITUTIONS.

Pick the action first, then a player; tap the team tile when the player is unknown — the entry then counts for the team only. FOUL records a personal foul (personal/both modes) or a team foul (team mode). A player's technical foul counts as a personal and team foul; on the team tile it is a coach/bench technical that counts for neither. SUBSTITUTIONS then a team opens the on-court picker (max. 5). The middle panel has Game flow (tap an entry to remove it or assign a player), Period (start/end/overtime/final, quarter scores, clock) and Game settings. Points can be scored while the clock runs. Short team names are limited to three letters.

Statistics (points, personal fouls, rebounds and hidden AST/STL/BLK/TO history) stay private to controllers; public spectator and OBS views are unchanged.

## Not yet included

Email recovery, QR codes, basketball period summaries, reusable team rosters/lineups, goal banners, match export, custom branding and additional templates. The initial template styling is an interpretation of the textual design document, which contains no visual mockups.

Production supports football and a focused basketball pilot. Email recovery, the remaining stage-1 acceptance criteria, mobile/OBS field testing and operator/legal pages are still outstanding. Database migrations and PostgreSQL integration checks are part of every deployment.

## Checks

```bash
cd backend
uv run pytest
cd ../control
flutter analyze
flutter build web --release --base-href /app/ --no-web-resources-cdn
cd ..
node --test tests/display.test.mjs
```

## Production

Repository: https://github.com/bullemer/score67-de · Application: https://score67.de

Pushes to `main` run the checked production workflow. There is no staging application. Nginx provides HTTPS with a renewing Let's Encrypt certificate for both domain names. See [production operations](docs/PRODUCTION.md) for the release layout, backups, rollback and remaining limitations.

## Release identity

The app and public page footers show the version and UTC build date/time. The OBS overlay remains free of app UI. `scripts/stamp_release.py` reads the version from `backend/pyproject.toml` and creates matching metadata for server templates and the compiled Flutter app. CI runs it for every production build. When releasing a new version, also align `control/pubspec.yaml` and refresh the backend lockfile with `uv lock --project backend`.
