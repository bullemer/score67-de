# Display (Anzeigetafel) API

A display is a device that drives a physical scoreboard, typically a Raspberry Pi next to an LED board. It is managed in the app under **Settings → Anzeigetafeln** (also in the console menu). It shows whichever scoreboard the user assigns and follows that board's current game automatically, including private games.

## Pairing flow

1. In the app, the user taps **Connect display**. The server creates the display and a pairing code (6 characters, `A–Z` without `O`/`I`, digits `2–9`), valid for 10 minutes. The browser receives a management cookie `score67d_<display id>`.
2. The user enters the code on the device's setup page (the Pi's own setup Wi-Fi with a captive portal, where the venue Wi-Fi and password are also entered).
3. The device exchanges the code for its own token:

```http
POST /api/display/pair
Content-Type: application/json

{"code": "K7M2P9"}
```

```json
{"display_id": "q3x8…", "name": "Halle 1", "token": "<secret>"}
```

Case, spaces and dashes in the code are ignored. Each code works once. Invalid or expired codes return `404 {"error": "pairing_code_invalid"}`. There are at most 30 attempts per IP per hour (`429 rate_limited`). Store the token persistently on the device; it is the only credential. **New code** in the app followed by pairing again replaces the token; removing the display invalidates it.

## Following the assigned board

Live socket (preferred):

```
wss://score67.de/ws/display?token=<token>
```

The server sends a JSON message immediately and whenever the assignment, the display name, the active game or its revision changes:

```json
{
  "display": {"id": "q3x8…", "name": "Halle 1"},
  "board": "vhl61bqbyj",
  "state": { …public game state… },
  "server_now": 1790892360000
}
```

`board` and `state` are `null` while nothing is assigned. The socket is closed with code 1008 when the token is invalid, the display was removed or re-paired; the device should then return to setup mode.

Polling fallback (also updates "online" status):

```http
GET /api/display/state
Authorization: Bearer <token>
```

The display counts as online for 30 seconds after its last request or socket heartbeat.

## Game state fields useful for a scoreboard

The `state` object is the same public state the spectator page and OBS overlay use:

- `home` / `away`: `name`, `short` (max. 3 letters), `color`, `score`, `period_scores`, `counters` (`team_fouls`, `timeouts`, `fouls`, `red_cards`, `yellow_cards`).
- `sport` (`football` / `basketball`), `phase` (`pre_game`, `period_running`, `break`, `finished`, `no_match`), `period`, `period_count`, `period_length_min`, `overtime_length_min`.
- `clock`: `enabled`, `direction` (`up`/`down`), `running`, `started_at` (server ms), `elapsed_ms`. Compute the displayed time locally: `elapsed = elapsed_ms + (running ? now_server - started_at : 0)`, with `now_server` derived from `server_now` plus local elapsed time since the message arrived. Basketball counts down from the period length (overtime: `overtime_length_min`).
- `possession` (basketball arrow): `home`, `away` or `null`.

Personal fouls, lineups and other controller-only data are not included.

## Self-registering LED panels (ESP32 firmware) — compact feed

LED panels with the Score67 firmware (see `docs/DISPLAY-FIRMWARE.md`) do not get a code from the app; they **show** a code and the app claims them.

### Register (device)

```http
POST /api/display/register
Content-Type: application/json

{"device_key": "<random, ≥ 32 chars, generated once and kept in NVS>", "fw": "0.1.0"}
```

```json
{"display_id": "bdnxj865x5vk", "name": "Anzeigetafel", "token": "<secret>", "code": "Q6JYPU"}
```

The same `device_key` again returns a **new token** (the old one stops working) and keeps owner and assigned board; `code` is `null` once the panel is claimed. A new key creates a new, unclaimed display. 30 registrations per IP and hour (`429 rate_limited`).

### Claim (app)

`POST /api/displays/claim` with `{"code": "Q6JYPU", "name": "Halle 1"}` (name optional; case, spaces and dashes ignored). The browser gets the management cookie as with `POST /api/displays`; afterwards `PUT /api/displays/{id}` sets `board`, `name` and `brightness` (10–100), `POST /api/displays/{id}/identify` makes the panel flash for 10 s. Unknown, expired or already claimed codes: `404 pairing_code_invalid`. Claim codes are valid for 24 h and renewed automatically while the panel is unclaimed.

### Compact feed

`wss://score67.de/ws/display?token=<token>&format=compact` (or `GET /api/display/state?format=compact` with `Authorization: Bearer <token>`). A message is sent on connect and whenever something visible changes; always the complete state:

```json
{
  "v": 1, "seq": 1791207360000, "server_now": 1791207360000,
  "mode": "game", "name": "Halle 1", "brightness": 60, "identify": false,
  "sport": "basketball", "phase": "period_running", "period": "Q3",
  "home":  {"short": "HOM", "score": 34, "color": "#c8102e", "fouls": 3, "red_cards": null},
  "guest": {"short": "GUE", "score": 32, "color": "#1d4ed8", "fouls": 2, "red_cards": null},
  "possession": "home",
  "clock": {"visible": true, "running": true, "direction": "down", "ms": 512000, "at": 1791207360000}
}
```

- `mode`: `pairing` (adds `code`; show it), `idle` (claimed, no board assigned), `game`.
- `seq` increases; drop messages with a lower `seq` than the last one processed.
- `period`: short ASCII label made by the server — `Q1`–`Q4` (4 periods), `H1`/`H2` (halves), `5/8` (other formats), `OT1` (overtime), empty before kickoff.
- `clock.ms` is the value shown at `server_now`: basketball counts **down** the period, football counts **up** across halves (2nd half starts at 45:00 for 2 × 45). While `running`, the device adds/subtracts its own elapsed time since the message arrived; no NTP needed. `{"visible": false}` before kickoff or without time keeping.
- `fouls`: basketball team fouls when the game counts team fouls, else `null`; `red_cards` for football.

### Status (device → server)

Text messages on the same socket: `{"fw": "0.1.0", "rssi": -61, "uptime": 3600}` (any subset). They update the panel's firmware version, Wi-Fi strength and online time shown in the app. Anything else is ignored.

`tools/display_sim.py` simulates a panel end to end (register, code, compact feed with a local clock, status).
