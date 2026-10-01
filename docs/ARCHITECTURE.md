# First-increment architecture

## Processes and state

FastAPI serves the REST API, WebSocket snapshots, Jinja pages and compiled Flutter assets. The browser never stores the admin token in JavaScript; the server sets an HttpOnly cookie. The Flutter controller uses same-origin HTTP. Browser preferences store language and defaults for new game formats. The public outputs use no Flutter code.

`backend/score67/domain.py` implements rules without I/O. `db.py` contains SQLAlchemy tables. `app.py` coordinates authentication, bounded input, transactions and state projection. The frontend shares its JSON translations with the server-rendered pages under `shared/i18n/`.

For this increment, times on the wire are UTC epoch milliseconds (not the illustrative ISO strings from the spec). The API is internal to this checkout and version 0.1. IDs for matches/devices are UUIDs. Scores and red-card counters are derived from non-cancelled events. Red-card corrections cannot make a counter negative; card events preserve the running clock and reset with each new game. Current match lifecycle and clock state are materialized in JSON, with field snapshots for last-action undo. Each event preserves its original format for stable historical time labels.

## Narrow command API

Public routes match the specification: `/`, `/new`, `/s/{slug}`, `/s/{slug}/control`, `/s/{slug}/overlay`, `/api/s/{slug}/state`, and `/ws/s/{slug}`. This first increment consolidates match writes in one endpoint:

```http
POST /api/s/{slug}/matches/{match_id}/commands
Content-Type: application/json

{
  "command_id": "a newly generated UUID",
  "expected_revision": 0,
  "action": "score",
  "data": {"team": "home", "points": 1}
}
```

Actions: `score`, `score_correction`, `red_card`, `red_card_correction`, `period_start`, `period_end`, `game_end`, `clock_adjust`, `settings`, `overlay`, `undo`, `new_match`. Undo includes `data.event_id`. Creating a new match requires the current match to be finished. All writes authorize first, including retries; revoked devices cannot use old command IDs to regain access.

A successful command returns the full active state. A repeated command with the same ID/body returns the latest state without reapplying it. A reused ID with different content returns 409. A stale revision returns `state_changed` (409); the UI refreshes and asks the operator to re-evaluate. Errors have an `error` code and no user-submitted data echo. Commands are serialized in one process and committed atomically. Run **exactly one worker** until database-level locking is added.

The separate events/clock/overlay write endpoints from the full spec have not been implemented as redundant adapters. Add them only if an external client needs that exact interface. Likewise there are no stub email, roster or upload endpoints.

## Dashboard and game management

`/dashboard` lists boards authorized by this browser's existing board cookies; it is not an account or a public directory. Another device must claim each board using its control link and PIN. Clearing cookies removes dashboard access until the PIN is entered again.

`GET /api/dashboard` projects authorized boards and their non-deleted games. `POST /api/s/{slug}/matches` prepares a game independently of the active one. Additional commands are `activate`, `schedule`, `archive`, `restore` and `delete`; these retain UUID retry protection and revision checks. Activating a prepared game is blocked while another game is running or in a break. Scheduling stores a UTC timestamp and displays local browser time; it never automatically starts a match.

Archive and delete cannot interrupt a running game. Deleting is a soft deletion: it hides the game from the dashboard and returns HTTP 410 for its historical state, retaining database records for consistency. Archiving the active game clears the active pointer and hides the overlay until another game is activated. Historical spectator links use `?match=<uuid>` and never switch to a newer game.

## Live displays

`/live` uses the public `GET /api/live` projection, restricted to active, non-archived/non-deleted games in play or in a break. It includes only public display fields and polls every five seconds; clocks interpolate between snapshots. Finished and planned games are excluded. No cookie or account is required.

Sharing links target only the spectator page, preserving a historical match ID when sharing an old result. WhatsApp and Facebook open their share composer; the user chooses whether to send. No third-party SDK or automatic posting is used.

The socket checks the current revision every 250 ms, sends full state initially/on change, and responds to `ping`. Clients reconnect with bounded backoff. REST remains available for fallback. The HTML client polls every two seconds while disconnected and periodically resynchronizes server time even while connected. It continues the last known clock during an outage and never puts a connection error into the overlay.

Overlay query options implemented: `delay=0..30000`, `preview=1`, `view=small|big`, `pos=tl|tr`, `lang=de|en`. Only the initial standard template exists; `template` selection is deferred. Hidden takes precedence over automatic big mode; a fixed URL view takes precedence over controller settings. Spectators receive immediate scores, independent of broadcast delay.

Known limitation: on initial connection/reconnect the server supplies the current state, not a historical delay window. It cannot reconstruct the exact last N seconds if disconnected; it holds the previous display and applies the fresh state after its configured delay. Validate this behavior with real streams.

## Operations

`COOKIE_SECURE` defaults to true. Disable only for local HTTP. Set `PUBLIC_ORIGIN` to the real HTTPS origin behind the proxy. Do not enable arbitrary CORS. State-changing requests require JSON and reject foreign origins. Bodies are capped at 16 KiB; configure an outer proxy limit as well.

Only the trusted reverse proxy should reach Uvicorn. Correctly configure trusted forwarded IPs before relying on the IP creation limit. Do not trust forwarded headers from arbitrary internet clients. The production container trusts the dedicated bridge gateway (172.30.67.1) and loopback; Nginx overwrites forwarded addresses with the actual peer address. Do not expose the upstream port beyond loopback.

Local development can create fresh tables automatically. Production instead runs versioned Alembic migrations before startup. Each release takes a database backup; daily backups are also configured. Receipt/event retention and off-server backup storage remain future work.

## Optional venue

A scoreboard has an optional JSON location (latitude, longitude, label and visibility). It is private by default. Public state, history, WebSocket and live-directory projections return only a published location; private coordinates never enter event records. Authenticated GET/PUT `/api/s/{slug}/location` supports changing, hiding and deleting the venue. Edits use last-write-wins for the venue and bump the active match revision to notify displays.

The same-origin map picker uses locally hosted Leaflet 1.9.4 and OpenStreetMap tiles, loaded only when the picker is opened. Browser geolocation runs only after a click and the browser permission prompt. No reverse-geocoding service is used. Parent/frame messages check both origin and window identity; coordinates are passed in messages, not URLs. Google Maps opens externally for search/navigation; importing supports numeric coordinate pairs and full Google Maps links containing selected-place coordinates. Short links and map-centre-only URLs require copying coordinates from Google Maps. Tile attribution, browser caching and origin referrers follow the [OSM tile policy](https://operations.osmfoundation.org/policies/tiles/). Automated browser tests stub tile requests.
