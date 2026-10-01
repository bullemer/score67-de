# Project assessment · 1 October 2026

This assessment describes the initial scope. Later in the same session the user authorized direct main-to-production deployment and requested automatic timestamp labels, direct team name/color editing and minus-goal controls. See PRODUCTION.md for current implementation and operational status.

## Recommendation

Build one small, independently deployable service and validate it at a real football match before extending it. Low initial traffic does not require microservices, a message broker, Kubernetes, accounts, a design editor or native app packaging. Reliability at the field matters more than adding screens: the operator needs to know whether a tap counted, the overlay must recover after a network interruption, and the clock must agree with the camera.

Keep FastAPI, Flutter Web and lightweight HTML displays as specified. Use PostgreSQL for the deployed service and SQLite as an optional zero-configuration local development database. One application process, one database, one origin and an HTTPS reverse proxy are enough for the initial architecture. There is no measured capacity claim yet.

## What is already strong

The no-account flow removes a major barrier. The Home/Guest defaults, optional roster and optional clock make it usable at informal and youth games. A stable OBS URL avoids reconfiguring streams. Separating the heavy operator application from the small transparent output is appropriate. Sport profiles, language-neutral state, shared translations and staged templates offer sensible extension points.

Timestamp-based clocks are the right starting point: persist when the clock starts and its accumulated elapsed time, rather than updating the database every second. Event-based scoring makes score correction auditable.

## Where the scope needs tightening

The specification's first stage is not a small MVP. It contains anonymous provisioning, device authorization, revocation, password-like PIN protection, email recovery, internationalization, synchronized clocks, an editable match lifecycle, two display layouts and an admin UI. Building all of that before a single end-to-end match would postpone feedback.

The first increment therefore deliberately implements the football scoring loop and PIN/device access, while leaving email recovery and the remaining first-stage acceptance work visible in the plan. This is a subdivision of stage 1, not a claim that stage 1 is finished.

Flutter preserves the user's proposed future native-app path, but adds a second UI technology and a larger initial download. A responsive HTML controller would be the fastest alternative if native apps cease to matter. There is no need to change stacks now: Flutter is available here, and the release build is served by the same FastAPI origin. UI code currently contains web-specific browser access; future native builds will require an adapter for navigation, storage and cookie/session handling.

The Word document is a concise restatement of the design requirements. It contains no embedded images, actual layouts, selected fonts or color specifications beyond the requirements. The first visual direction is therefore provisional: dark navy surfaces, large tabular digits, red/blue team accents, a green action accent, separate transparent stream and full-screen spectator layouts. Logo uploads and a general template engine do not belong in this first increment.

## Reliability gaps resolved in the foundation

1. **Duplicate writes:** an HTTP timeout does not tell a phone whether a goal was stored. Each match command has a unique ID and a persisted fingerprint. Retrying the same command does not count it again. Reusing an ID for a different payload is rejected. Uncertain writes block new UI actions until checked. Uncertain creation/PIN rotation remains a follow-up edge case; the create flow is not yet idempotent.
2. **Two admins:** each command includes the match revision it was based on. A stale edit returns a conflict and refreshes the UI. The operator explicitly repeats the intended action. Even additive goals use this policy initially to avoid guessing whether two operators recorded the same physical goal.
3. **Undo:** score events are cancelled, never deleted. State-changing actions store only the prior fields they changed. Undoing a goal therefore does not rewind the clock. Undo applies to the last non-cancelled recorded action and identifies that action explicitly. Settings/overlay actions are currently included in that log; refine this UX before match-day acceptance if operators expect only sporting events.
4. **Clock and broadcast delay:** delaying score messages alone leaves the overlay clock ahead of the camera. The display queues snapshots and also renders the clock against delayed server time. It uses a monotonic browser timer and periodically estimates server time from a REST round trip. This must still be measured in OBS and over mobile data.
5. **Scope separation:** every match/admin lookup verifies scoreboard ownership. Public state is assembled deliberately; PIN hashes, admin identities, device tokens and internal undo snapshots are not serialized.
6. **Restart behavior:** matches, events, command receipts, PIN failure counters and creation limits are stored in the database. WebSocket reconnect loads the current snapshot. No offline write queue is introduced.

## Ambiguities and inconsistencies in the source

| Topic | Issue | Initial decision / later resolution |
| --- | --- | --- |
| 'Twelve open points' | The list is longer, and some entries are decided | Treat the checklist entries individually; do not infer unresolved scope from the count. |
| Standard colors | One section always uses team colors; another ignores custom colors in standard mode | Fixed red/blue initially; implement explicit standard/custom modes with the design increment. |
| Basketball stoppability | Profile says stoppable; open decisions mention switchable continuous time | Defer the switch; implement standard stopped countdown first when basketball begins. |
| Personal fouls | The description says a player is required, but permits an unknown player | Represent unknown fouls without a player and count them for no individual until assigned. Define team-foul implications in stage 2. |
| Changing period length | Historical event minute labels could change retroactively | Store period count/length with each event. The current clock follows the edited current format. |
| Arbitrary event cancellation | REST proposes any event deletion; UI only promises last-event undo | First increment supports last-event undo only. Arbitrary lifecycle event cancellation needs replay semantics and separate validation. |
| Hidden versus auto-large | Automatic break display could override manual hiding | Hidden wins unless the OBS URL explicitly fixes a view. Manual small/large also disables auto-large until re-enabled. |
| Clock re-enable | Needs an explicit time when enabled mid-game | Require elapsed time in the current period; no guessing. |
| Recovery email | SMTP and sender are unspecified | Do not collect addresses or show a nonfunctional recovery link. Implement and test when transport is configured. |
| Youth/player names | 'Name consent' is a data rule, not a complete privacy policy | No players in this increment. Add public projection tests before introducing player data. |
| Inactive cleanup | Twelve months without 'usage' is underspecified | Defer deletion; decide whether reading, writing or both count, and how notification/export works. |
| PIN attack lockout | Global board lockout also allows denial of service by anyone knowing its URL | Implement specified limit initially; evaluate per-source backoff and reverse-proxy limits before public release. |

## Keep infrastructure small, leave a clear growth path

The application is a modular monolith: pure rules, database models, HTTP/WebSocket interface, controller and display code. Match state is currently a compact JSON projection plus an append-only/cancelled event ledger. This avoids creating unused roster/asset tables now. Add normalized teams and players with migrations when that work starts.

One Uvicorn worker is an intentional constraint. The current write lock is process-local; WebSocket clients poll revisions in the database every 250 ms and fetch full state only when it changes. This is adequate as a simple implementation to measure, not an architecture for thousands of concurrent viewers. FastAPI documents the same single-process limitation for process-local connection management: [FastAPI WebSockets](https://fastapi.tiangolo.com/advanced/websockets/).

Measure active boards, connected viewers, command latency, conflict rate, database query load and reconnects first. If the process becomes constrained, move serialization into database row locks/transactions, batch fan-out by scoreboard and introduce Redis or PostgreSQL notifications as justified. Only then add workers or instances. Add cache/CDN handling for static Flutter assets independently. Avoid an automatic 'scale after N users' rule: spectators and simultaneous matches create different workloads.

## Before public operation

The critical remaining work is migrations, real PostgreSQL integration tests, tested backup/restore, recovery email, TLS/proxy rate-limit verification, legal/operator information, and field acceptance. Dependency lockfiles are included; schema creation currently bootstraps fresh databases and is not a migration system. A real 45-minute clock measurement, 720p OBS readability test and 30-second network loss exercise have not yet been performed. Do not describe local unit tests as substitutes for those checks.
