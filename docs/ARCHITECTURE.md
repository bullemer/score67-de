# First-increment architecture

## Processes and state

FastAPI serves the REST API, WebSocket snapshots, Jinja pages and compiled Flutter assets. The browser never stores the admin token in JavaScript; the server sets an HttpOnly cookie. The Flutter controller uses same-origin HTTP. Browser preferences store only the language. The public outputs use no Flutter code.

`backend/score67/domain.py` implements rules without I/O. `db.py` contains SQLAlchemy tables. `app.py` coordinates authentication, bounded input, transactions and state projection. The frontend shares its JSON translations with the server-rendered pages under `shared/i18n/`.

For this increment, times on the wire are UTC epoch milliseconds (not the illustrative ISO strings from the spec). The API is internal to this checkout and version 0.1. IDs for matches/devices are UUIDs. Score is derived from non-cancelled goal events. Current match lifecycle and clock state are materialized in JSON, with field snapshots for last-action undo. Each event preserves its original format for stable historical time labels.

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

Actions: `score`, `score_correction`, `period_start`, `period_end`, `game_end`, `clock_adjust`, `settings`, `overlay`, `undo`, `new_match`. Undo includes `data.event_id`. Creating a new match requires the current match to be finished. All writes authorize first, including retries; revoked devices cannot use old command IDs to regain access.

A successful command returns the full active state. A repeated command with the same ID/body returns the latest state without reapplying it. A reused ID with different content returns 409. A stale revision returns `state_changed` (409); the UI refreshes and asks the operator to re-evaluate. Errors have an `error` code and no user-submitted data echo. Commands are serialized in one process and committed atomically. Run **exactly one worker** until database-level locking is added.

The separate events/clock/overlay write endpoints from the full spec have not been implemented as redundant adapters. Add them only if an external client needs that exact interface. Likewise there are no stub email, roster or upload endpoints.

## Live displays

The socket checks the current revision every 250 ms, sends full state initially/on change, and responds to `ping`. Clients reconnect with bounded backoff. REST remains available for fallback. The HTML client polls every two seconds while disconnected and periodically resynchronizes server time even while connected. It continues the last known clock during an outage and never puts a connection error into the overlay.

Overlay query options implemented: `delay=0..30000`, `preview=1`, `view=small|big`, `pos=tl|tr`, `lang=de|en`. Only the initial standard template exists; `template` selection is deferred. Hidden takes precedence over automatic big mode; a fixed URL view takes precedence over controller settings. Spectators receive immediate scores, independent of broadcast delay.

Known limitation: on initial connection/reconnect the server supplies the current state, not a historical delay window. It cannot reconstruct the exact last N seconds if disconnected; it holds the previous display and applies the fresh state after its configured delay. Validate this behavior with real streams.

## Operations

`COOKIE_SECURE` defaults to true. Disable only for local HTTP. Set `PUBLIC_ORIGIN` to the real HTTPS origin behind the proxy. Do not enable arbitrary CORS. State-changing requests require JSON and reject foreign origins. Bodies are capped at 16 KiB; configure an outer proxy limit as well.

Only the trusted reverse proxy should reach Uvicorn. Correctly configure trusted forwarded IPs before relying on the IP creation limit. Do not trust forwarded headers from arbitrary internet clients. The production container trusts the dedicated bridge gateway (172.30.67.1) and loopback; Nginx overwrites forwarded addresses with the actual peer address. Do not expose the upstream port beyond loopback.

Local development can create fresh tables automatically. Production instead runs versioned Alembic migrations before startup. Each release takes a database backup; daily backups are also configured. Receipt/event retention and off-server backup storage remain future work.
