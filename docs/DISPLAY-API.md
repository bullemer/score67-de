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
