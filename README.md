# Score67

A small, self-hosted scoreboard for sports streams. This checkout contains the **football, basketball and tennis scoreboards**, deployed directly from `main`; it is not the complete specification.

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

- Optional description (up to 300 characters), livestream link (https only, e.g. YouTube/Facebook) and planned start time when creating a scoreboard; both texts can be edited later in the controller (Description & livestream). For public games the description, the public venue and a "▶ Livestream" button appear in the live directory and the ticker menu; the controller and dashboard also show creation time and scheduled start.
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
- Email sign-in (optional, no password): "Meine Scoreboards" sends a single-use link (30 min). Signing in links the boards this browser controls to the address; on any other signed-in device those boards appear and can be controlled without the PIN. Boards created while signed in are linked at once. The PIN screen offers the same sign-in ("PIN vergessen"), and game settings show/link/unlink the email (unlinking notifies the owner). Hidden until SMTP is configured: `SMTP_HOST`, `SMTP_PORT` (587, STARTTLS), `SMTP_USER`, `SMTP_PASSWORD`, `MAIL_FROM` in the server's runtime `.env`; `MAIL_LOG=true` prints mails locally.
- Auto end: games that were started but never ended are ended automatically once twice their planned playing time has passed since kickoff (at least 3 h, so a 2×45 football game ends 180 min after kickoff) and nothing was entered for 15 min. The clock freezes at the end of the regular period. Thresholds: `AUTO_END_FACTOR`, `AUTO_END_MIN_MINUTES`, `AUTO_END_QUIET_MINUTES`.
- Trash (Papierkorb): a cleaner (every 10 min) moves games that were started but not ended and had no activity for 24 h, planned games still not started 24 h after their start time, and unscheduled games untouched for 7 days to the trash. Finished games are never touched. Trashed games leave live views; restore them from the dashboard within 30 days, after which they are deleted. "Move to trash" on the dashboard does the same by hand. Thresholds: `TRASH_STALE_HOURS`, `TRASH_PLANNED_GRACE_HOURS`, `TRASH_UNSCHEDULED_DAYS`, `TRASH_RETENTION_DAYS`, `TRASH_INTERVAL_SECONDS` (0 disables).
- Device dashboard at `/dashboard`: planned (with or without a date), running, completed and archived games; archive, restore and delete controls. Each game has one clear main action instead of a generic "Controls": planned → **Spiel starten**, running → **Fortsetzen**, completed → **Neu starten (gleiche Teams)** (a new game with the same names, colours, logos, squads and format; refused with `game_running` while another game runs on the board) plus *Ergebnis korrigieren* / *Ergebnis ansehen*.
- Public `/live` directory with two tabs: Live (running games, including breaks, with automatically updated scores, clocks and cards) and Upcoming (public games scheduled within the next 72 hours, `LIVE_UPCOMING_HOURS`, soonest first, with date, time, format and venue). Private, trashed and archived games are never listed. No sign-in required.
- WhatsApp, Facebook, copy-link and native sharing for spectator links from the public view and controller.
- Game import (optional, Germany): paste the link of a game page on fussball.de (`/spiel/<32-char id>`) or basketball-bund.net (`#/spiel/<id>`) when creating a scoreboard or a game in My scoreboards. `POST /api/fixtures/lookup` (`backend/score67/fixtures.py`, 60 lookups per IP and hour, `FIXTURE_LOOKUP_LIMIT`) fills in teams (name, club, team, guessed three-letter short name; basketball uses the federation's short name), kickoff (Europe/Berlin), venue address (geocoded street-level via OpenStreetMap Nominatim, hidden by default), league, matchday, game number, description, and suggests a format from the age group (e.g. C-Junioren 2×35 with 7 players for "7er" teams, U12 and younger basketball 8×5). fussball.de draws date and time with a scrambled web font; the parser maps glyph outlines to digits (`GLYPHS`) and also learns them from the plain date in the page title. Only IDs are taken from the pasted link, so the server never fetches user-given URLs. The facts are stored per game in `match.fixture` (migration `0014_fixture`) and shown to controllers and in My scoreboards with a link back to the source. Other countries' sites can be added to `fixtures.SOURCES`.
- Future games can be prepared without interrupting the live game. Opening their controls activates them; kickoff remains manual.
- Visible back navigation and global language/default game-format settings (⚙, saved on this browser): one default format for football and one for basketball, each with one-tap presets (basketball 4×10, 4×12, 8×5, 2×20). Creating a scoreboard and preparing a game start with the chosen sport's default.

### Website pages and forum (v0.27)

The landing page shows the headline and the three entry points (Create scoreboard, My scoreboards, Live tickers); a header navigation links **Features** (`/features`, every current feature as cards), **About** (`/about`, why the project exists) and the **Forum** (`/forum`). Texts live in `shared/i18n` like everything else (`nav.*`, `about.*`, `features.*`, `forum.*`); `static/site.mjs` renders them and keeps the language in links.

The forum (`backend/score67/forum.py`, table `forum_post`, migration `0011_forum`) has topics and replies. Posting needs a confirmed email: without an account the post stays unpublished and a six-digit code is mailed (30 min, 5 attempts, 5 codes per address and hour, 20 posts per IP and hour, a hidden honeypot field). Entering the code publishes the post and signs the browser in (the same account session as the email sign-in), so later posts publish at once. Addresses are stored but never returned by the API; names, titles and texts are rendered as plain text. Unconfirmed posts are dropped after a day. With `FORUM_MODERATOR_EMAIL` set, every published post is mailed there with a one-click link to `/forum/moderate/<id>` (hide / show again; the key is only in that mail). Posting requires SMTP like the sign-in; without it the forum is read-only and says so.

The five-scoreboards-per-hour creation cap is disabled during testing. `SCOREBOARD_CREATE_LIMIT=0` (default) keeps it off; a positive value enables an hourly IP limit later. PIN protection remains enabled.

## Basketball pilot (v0.7)

Choose Basketball when creating a scoreboard or preparing a game in the dashboard. Presets: 4 × 10 (default), 4 × 12, 8 × 5 and 2 × 20; custom lengths/counts remain editable in match settings. Games remain planned until the operator prepares the first period. Preparing a period resets its countdown and leaves it stopped; use Start clock at the referee’s signal. At zero the clock stops without ending the period automatically. Set remaining time uses MM:SS.

Scoring supports +1/+2/+3 whether the clock runs or not; made baskets do not stop the clock. Use the Play/Stop button in the header for whistles and timeouts. Each team has a squad editor; basketball squad entries require shirt numbers. With a squad, tap +1, +2 or +3 in the player’s row of the scoring matrix. The first matrix row is always Unknown player, including when a squad exists. Use this row to record points without player attribution. Remove event reverses the full selected basket; add a replacement if its value was wrong. Team fouls reset between regular periods and carry from the last regular period through repeated five-minute overtime. Overtime is offered after ending the final period with tied scores. Timeouts stop the clock and count total used across the game; competition-specific quotas are not enforced. Foul modes are team, personal, both, or off; 8 × 5 defaults to personal fouls. Personal foul totals and number-only entries remain private to controllers, with warnings at four and five fouls. Automatic player disqualification, shot clock and period-result summaries are not included.

### Football console (landscape)

Football uses the same landscape console. Header: menu, short name, yellow/red card and foul counts, scores, half, running clock and a Play button that kicks off each half (the football clock is not stopped). Team columns show the team tile plus the whole squad, players on the pitch first (see On court below), and scroll vertically; tiles show goals and yellow/red cards. Actions: GOAL, YELLOW, RED, PENALTY, FOUL, FREE KICK, Undo, SUBSTITUTIONS — action first, then player or team tile. PENALTY records the awarded penalty and offers an inline Goal/Missed bar; Goal records a goal marked "penalty". The Period tab has kick-off/half-time/final whistle and clock corrections. Fouls, free kicks, penalties awarded and lineups stay private to controllers.

### Team tab

The console's middle panel has the tabs Spielverlauf (game flow), Team, Periods, Teilen, LED and Box Score. Team edits both rosters inline: shirt number, optional name (basketball requires numbers) and an on-court checkbox (max. 5 in basketball, 11 in football). A new empty row appears automatically; a pasted list ("7 Alex" per line) can be imported. Save sends the squad, then the lineup; ticked players appear bright at the top of the left columns. Unsaved edits are kept per team while switching teams or tabs (marked with •).

Double-tap a team tile to edit the team name, short name and colour; double-tap a player tile to change number or name (only while no action is selected, so scoring taps stay instant). In basketball, Play also opens the next period or overtime and starts the clock in one tap.

### Ticker page views

The public ticker (`/s/<code>`) shows only the score, phase, period and time; everything else (Simple/Extended view, share icons, OBS link, take over control, venue, language, live directory, connection and version) is in the ☰ pop-up menu. Scores are sized from the viewport: portrait phones stack the teams as rows with large numbers, landscape and tablets show them side by side; three-digit scores shrink to fit. Simple view fills exactly one screen. The Extended view adds, for football, all goals in chronological order with minute, scorer, penalty marker, team and running score; for basketball, points per player for both teams plus quarter scores; and the game log. A small dot on the menu button signals a lost connection.

### Editing games and team logos

In My scoreboards every game card has an Edit button: team names, optional team logos, description and livestream link. Logos (PNG, JPEG or WebP) are downscaled in the browser (max. 512 px), then decoded and re-encoded server-side as PNG (max. 256 px, max. 4 megapixels input, decompression bombs rejected) and stored in the database (`asset`, max. 30 per scoreboard; unused ones are cleaned up automatically). They are public at `/media/<id>.png` and appear on the ticker, live directory cards and OBS overlay. Only stored logos can be referenced in team settings.

### Private games

Games are public by default. The "Private game" switch under Game settings → Privacy and access hides the spectator page (it shows a private notice), the public state API, live socket and the /live directory from everyone except this board's control devices. The OBS overlay link carries an overlay key (`?k=…`) and keeps working while private; switching back to public re-enables all sharing links.

### Game flow

Spielverlauf shows sporting events only: clock start/stop, squad edits, settings and the pre-game lineup are recorded but hidden; in-game substitutions are shown. Undo removes the last visible entry (a score after a hidden clock stop is removed without restarting the clock).

### Formats at creation

The create form has free controls for the number of periods (1–12) and the length per period (1–120 min): − / + buttons around a typeable number, plus one-tap presets (football 2×45, 2×40, 2×35, 2×30, 2×20, 1×10; basketball 4×10, 4×12, 8×5, 2×20). Defaults: football 2 × 45, basketball 4 × 10, reset when switching sport.

### Score corrections and period flow

Tap a score in the console header to correct it (− / + or type the right score). The change is stored as an admin correction (`score_adjust`, any non-zero delta), shown in the game flow and to spectators as "Score corrected", and can be undone.

When the basketball clock reaches 0:00 the Play button turns into ⏭: one tap ends the period. While a period runs with the clock stopped (basketball) or at any time in a football half, a second ⏭ button next to Play ends the period early — tap, then tap "End?" within 3 s (a clock that was never started no longer blocks the next period). In the last period that button is a 🏁 and opens the final-result confirmation instead. During the break the console already shows the next period (e.g. Q2 10:00, or 2nd half 45:00 in football) and Play starts it. Ending the last basketball period ends the match automatically unless it is tied (then overtime is offered); the automatic game end is marked `automatic` and can be undone. Clock start/stop/set/adjust entries are hidden from the game flow.

### Displays (Anzeigetafeln)

Settings → Anzeigetafeln (also in the console menu) connects physical scoreboard drivers such as a Raspberry Pi next to an LED board. "Connect display" creates a 6-character pairing code (valid 10 minutes) that is entered on the device's setup page; afterwards choose which of your scoreboards it shows and switch at any time. The list shows online/offline/waiting status, rename, new code and remove. A paired display follows the assigned board's current game, including private games. Device protocol: [docs/DISPLAY-API.md](docs/DISPLAY-API.md).

### Bluetooth LED displays (Android)

In Settings → Anzeigetafeln, up to two LED displays can be driven directly by the phone via Web Bluetooth (Chrome on Android or desktop; not iPhone). Per display: name, LED size in pixels (presets or free width × height; 6 × 8 px per character), content (score and time / score / time), time updates (whole minutes – default, every second, none) and protocol, with a live preview. The console header shows connected displays (tap to connect the next one) and sends a frame on every change plus a 5-second heartbeat. Implemented protocols: plain text over common serial BLE modules (Nordic UART, HM-10/BT05 FFE0, FFF0) and a `S67;…` data line for custom firmware. Vendor drivers (e.g. CoolLED1248 / iPixel Color panels) are added per device model.

### Periods, free throws, on court, final result (v0.26)

- **Entries outside a period.** Before kickoff an entry opens the first period by itself. In a break an inline bar asks once: book to the period that just ended (e.g. free throws after the buzzer; later entries in the same break follow without asking) or ▶ start the next period and book there. The header shows the period larger, orange with PAUSE in breaks and ENDE/FINAL once finished.
- **Free throws.** FREE THROW → player → Hit/Miss records one shot and closes the bar; the next free throw is entered with FREE THROW again, so a double tap cannot add points.
- **On court.** With no action selected, tapping a player moves them on court or back to the bench (max. 5 basketball, 11 football; youth formats with 4 or 7 simply activate fewer). Players on court are bright and on top, the bench is dimmed below; the team tile shows how many are on court. Without any lineup all players are bright. Actions still accept bench players (forgotten substitution). Each change is a substitution entry in the game flow, queued and shown at once like a score.
- **Final result.** Ending the match (🏁 in the last period, Play at 0:00 of the last period, Period tab, menu Close game) shows one confirmation with the final score and the score per period.

### Named periods, start warning, players on the field, inline settings (v0.28)

- Period buttons name their period: "2. Viertel vorbereiten", "Periode 5/8 beenden", "2. Halbzeit anpfeifen" (EN "Prepare Quarter 2", …); the game flow says "Periode 1/8 gestartet / beendet".
- An entry before its period has started never starts it silently: an inline warning asks "Periode X ist noch nicht gestartet. Jetzt starten?" (▶ starts the period and its clock, then books the entry). In a break: book to the ended period (free throws after the buzzer) or start the next one. In a prepared basketball period whose clock never ran: start the clock or book without it. Each answer holds for that period.
- **Players on the field at once** (`lineup_size`, 1–5 basketball, 1–11 football; default the maximum): set when creating a scoreboard (presets 4/5 or 5/7/9/11), kept for games prepared from My scoreboards, editable in Einstellungen. The console, the Team tab and substitutions never mark more players active; shrinking below the players on court is refused (`lineup_too_large`).
- **Einstellungen** holds game format (presets, periods, length, players on the field, clock, stream delay), foul mode, teams (name, short name, colour), overlay, description & livestream, venue map, privacy, PIN/account access and LED match connection. The LED tab holds pairing, match connection, messages and panel management; global Settings also lets the operator assign or disconnect a scoreboard. Sections with unsaved edits are marked • and keep their drafts while the game changes (Save / Reset). Teilen holds sharing actions and links.

### Link previews (v0.28)

Shared ticker links show a real preview in WhatsApp, Facebook, Signal, Telegram etc.: `/s/<code>` renders Open Graph tags server-side (title "Bramfeld 74 : 70 Scaletta · LIVE" / "· ENDSTAND", or "Bramfeld – Scaletta · <kick-off>" before the game; description with sport, period, venue, the game description) and `og:image` points to `/s/<code>/preview.png` — a 1200 × 630 PNG card drawn with Pillow (team colours, logos, score, status, period; `backend/score67/preview.py`, bundled DejaVu fonts). The image URL carries the revision, so a new score is a new image; `?match=` links preview that game. Private games show only "Privates Spiel". Site pages use the generic card `/preview.png`. Apps cache previews: Facebook's Sharing Debugger (developers.facebook.com/tools/debug) re-scrapes a link on demand.

### Just finished in the live directory

`/live` keeps public games that ended within `LIVE_FINISHED_HOURS` (default 6) in a "Gerade beendet" section under the running games: final score, end time, "ended automatically" when the auto end closed it, venue, description and livestream link. The card opens that game's ticker (`?match=` when the board has moved on to another game).

### Box score (BS tab)

The console's sixth tab "BS" lists the selected team's statistics for the whole game or one period: basketball MIN, PTS, FT (made/attempted), FT%, 2P, 3P, PF (personal + player technicals), RB; football MIN, goals, YC, RC. One row per squad player, a "Team" row for entries without a player (incl. admin score corrections, so the sum equals the score) and the total. Minutes are game-clock time on court, replayed from the lineup (players tapped on court, substitutions) and the period starts/ends, the running period up to now; without a lineup or clock they show "–". Undone and corrected entries do not count (`control/lib/box_score.dart`, tested in `box_score_test.dart`).

### Controller and Viewer

The two roles are always called **Controller** (the scoring console, `/s/<code>/control`) and **Viewer** (the public scoreboard page, `/s/<code>`), in German too. A browser that already controls a board (PIN cookie or signed-in owner) sees a **Controller** button in the Viewer's top bar and "Controller" in its menu; everybody else gets "Controller (mit PIN)". The Controller's ☰ menu has **Viewer** (opens in a new tab), and every game in My scoreboards has a **Viewer** button.

### Search engines (SEO basics)

All server pages (start, Funktionen, Über, Forum incl. every topic, Live list, Impressum, Datenschutz, Viewer) are rendered with their texts already in the HTML (`backend/score67/seo.py` fills every `data-i18n` element from shared/i18n); the page scripts still switch language in place. The URL decides the language: German by default, English with `?lang=en`; only a visitor's own choice (stored) overrides it, not the browser locale. Each page has its own title/description (`seo.<page>.*`), canonical and hreflang (de / en / x-default) links; the start page carries schema.org `WebApplication` + `Organization` (Navisense GmbH) JSON-LD (deliberately no FAQ markup). `robots.txt` blocks the API, the Flutter app (create, My scoreboards, Controller), overlays and moderation and points to `sitemap.xml` (site pages in both languages plus forum topics). Single games (`/s/<code>`) and the Flutter routes are `noindex` (meta + `X-Robots-Tag`): shared, but not search results.

### Guide pages (search content)

Five server-rendered pages answer what people search for, each in German (default) and English (`?lang=en`), with real app screenshots (`static/guides/*.webp`): `/basketball-liveticker`, `/fussball-liveticker`, `/obs-scoreboard-overlay`, `/anzeigetafel`, `/anleitung/spielstand-whatsapp-teilen`, plus the DIY build guide `/anzeigetafel/led-bauanleitung` (Waveshare P5 64×32 panel + Adafruit Matrix Portal S3 + 5 V/≥4 A supply, parts list). The LED panel and live feed have been tested with a development server; a public self-installable firmware beta is pending production TLS, hotspot and browser-flashing field tests. Registry in `backend/score67/guides.py`, one template per page and language in `templates/guides/<key>.<lang>.html`, titles/descriptions in `seo.guide.<key>.*`. They are in the sitemap and linked from the footers of the start page, Funktionen and Über. Only describe what the app really does.

### LED panels (ESP32 firmware) — server side

Self-registering LED panels: `POST /api/display/register` (device key → token + code shown on the panel), claim in the app (Einstellungen → Anzeigetafeln → "Code von der LED-Tafel"), brightness and "Identifizieren" per panel, firmware/Wi-Fi status reported by the device, and a compact feed (`format=compact`, ~400 bytes instead of the full state) on the existing display socket. LED preview for every game: `/s/<code>/led` (Viewer menu → "LED-Vorschau"), draws the 64 × 32 pixels from `/api/s/<code>/led` exactly as the panel will; an animated demo runs on the build guide. Layout and bitmap fonts in `backend/score67/static/led.mjs` are the reference for the firmware. Concept and firmware plan: `docs/DISPLAY-FIRMWARE.md`; protocol: `docs/DISPLAY-API.md`; test without hardware: `cd backend && uv run python ../tools/display_sim.py [https://score67.de]`.

### Console menu

The ☰ menu opens settings or leaves the console: **Start** (start page), **Meine Scoreboards**, **Viewer** and **Verlassen** (stops a running basketball clock first; the game stays open and can be resumed from My scoreboards). Teams are in Team, privacy/PIN/account access in Game settings, sharing links in Teilen, LED controls in LED, and game end via 🏁 / the Period tab.

### Typing on a phone

While a text field in the console's middle panel has focus, the header, team columns and actions hide so the panel uses the full screen above the phone keyboard; the edited row scrolls to the top; the panel's tab bar hides too. The page declares `interactive-widget=resizes-content`, so Android Chrome shrinks the app to the space above the keyboard instead of covering it. Edit dialogs (team, player, description, settings, clock, squad) open at the top of the screen.

### Sharing tab and creation

Creating a scoreboard opens the console directly. The console's Sharing tab contains social sharing and the spectator, OBS and control links. Game settings show the admin PIN (kept only in the creating or renewing browser, because the server stores it hashed), PIN renewal, device management and privacy.

### Basketball console (landscape)

The live basketball control is a full-screen landscape console modelled on InGame. Header: menu, possession arrow per team (tap to set), team fouls (amber at 4, red from 5), timeouts used/allowed in the current window (FIBA 2 first half, 3 second half, 1 per overtime; total only for other formats), both scores in team colours, period, connection, clock (tap to set) and Play/Stop. Left: one column per team — the team tile (3-letter short name) and the players on court (or the whole squad until a lineup is set), each with a five-segment foul bar and points. Right: FREE THROW, 2 POINTS, 3 POINTS, FOUL, TECH. F., REBOUND, T.O., Undo and SUBSTITUTIONS. Rebounds are recorded per player or, via the team tile, as team rebounds. FREE THROW then a player opens an inline Hit/Miss bar that stays open for the next attempts; hits score 1 point marked as free throw, misses are recorded privately (statistics `ftm`/`ftx`).

Pick the action first, then a player; tap the team tile when the player is unknown — the entry then counts for the team only. FOUL records a personal foul (personal/both modes) or a team foul (team mode). A player's technical foul counts as a personal and team foul; on the team tile it is a coach/bench technical that counts for neither. SUBSTITUTIONS then a team opens the on-court picker (max. 5). The middle panel has Game flow (tap an entry to remove it or assign a player), Period (start/end/overtime/final, quarter scores, clock) and Game settings. Points can be scored while the clock runs. Short team names are limited to three letters.

Statistics (points, personal fouls, rebounds and hidden AST/STL/BLK/TO history) stay private to controllers; public spectator and OBS views are unchanged.

## Not yet included

QR codes, basketball period summaries, reusable team rosters/lineups, goal banners, match export, custom branding and additional templates. The initial template styling is an interpretation of the textual design document, which contains no visual mockups.

Production supports football and a focused basketball pilot. The remaining stage-1 acceptance criteria, mobile/OBS field testing and operator/legal pages are still outstanding. Database migrations and PostgreSQL integration checks are part of every deployment.

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

### Tennis

Tennis is available in homepage Quickstart, scoreboard creation, and new matches on saved scoreboards. Choose Women or Men and best of 3 (two sets to win) or best of 5 (three sets to win). Both categories default to best of 3; the match format is independent of the category.

- **Simple:** count games directly, or enter a completed set result (6–0 through 6–4, 7–5 or 7–6), optionally including the tie-break points. At 6–6 the game counter switches to tie-break points.
- **Detailed:** score every point (0/15/30/40, deuce, advantage), with automatic games, sets and match completion.
- Tie-break sets at 6–6 use seven points with a two-point lead; the deciding set can use seven or ten points. This does not replace the deciding set with a match tie-break.
- Choose the first server before the start; service then rotates automatically. Undo restores the full point/game/set transition, even after match point. Format and mode are selected before the match starts. Rematches retain them.
- The tennis Control Center works in portrait or landscape. The viewer and OBS display completed sets, current games, and point scores. Existing LED firmware shows the set total and set label. Tennis has no match clock or timed automatic finish.

Scoring follows the [ITF scoring definitions](https://www.itftennis.com/en/about-us/organisation/tennis-glossary/).
