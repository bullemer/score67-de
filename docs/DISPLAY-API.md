# Display (Anzeigetafel) API

A display is a Score67 LED panel (ESP32 firmware in `firmware/`) that shows one scoreboard's current game, including private games. It is managed in the app under **Einstellungen → Anzeigetafeln** and, per game, under **Teilen → LED-Tafel**.

## Registration and claim (self-registering panels)

1. The panel registers itself with a device key it generated once (`POST /api/display/register`, see below) and gets a token plus a 6-digit code, which it shows.
2. The user enters the code in the app (`POST /api/displays/claim`, or `POST /api/s/{slug}/displays` to connect a game at the same time). The browser receives a management cookie `score67d_<display id>`; from then on the panel follows the games its owner opens (`display.follow`).
3. The panel keeps its token persistently; it is the only credential. Removing the panel in the app invalidates it (the socket closes with 1008), and the panel registers again and shows a new code.

The earlier flow where the app created a display and a device typed its code (Raspberry Pi idea) was removed on 9 October 2026; such displays were deleted (migration 0016).

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

### Over-the-air updates

When a newer firmware release is approved for the panel (channel `stable`, or also `test` for panels with "Beta-Firmware erhalten"), its compact messages carry:

```json
"firmware": {"version": "0.2.0", "url": "/fw/0.2.0.bin", "sha256": "…", "size": 1503232}
```

Only panels that report a plain `x.y.z` version (`fw` at registration or in status) are offered updates. Install only while no game is running. `GET /fw/0.2.0.bin` with `Authorization: Bearer <panel token>` returns the image (`X-Checksum-SHA256` header); compare the SHA-256 of the downloaded bytes before switching partitions. Report progress with status messages such as `{"ota": "downloading 0.2.0"}`, `{"ota": "failed: sha256"}`, `{"ota": "installed 0.2.0", "fw": "0.2.0"}`; the app shows them.

Operator API (bearer `FIRMWARE_ADMIN_TOKEN`; `tools/fw_release.py`): `POST /api/firmware` `{"version", "channel": "test", "notes", "sha256", "data": "<base64>"}` (max. 4 MB image), `PUT /api/firmware/{version}` `{"channel": "stable" | "test" | "off"}`, `GET /api/firmware`.

