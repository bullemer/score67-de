# Production operations

## Delivery model

- GitHub: https://github.com/bullemer/score67-de.
- Live application: https://score67.de. `www` and HTTP redirect to the canonical HTTPS domain.
- Branch: `main` goes directly to production after automated checks. There is no staging deployment and no manual approval gate.
- GitHub environment: `production`, restricted to `main`.
- Workflow: `.github/workflows/production.yml`.

Each push runs the API/rules suite against disposable SQLite and PostgreSQL databases, display timing tests, Flutter analysis and a release build. Test databases are disposable CI resources, not a staging application. The workflow transfers a release archive over SSH, builds the runtime image on the server, backs up PostgreSQL, applies migrations, restarts the application and checks the deployed Git SHA over HTTPS. Deployments are serialized.

## Server layout

The deployment target is configured through the GitHub production environment; keep its credentials outside the repository. The host runs Nginx. Score67 has its own virtual host, Docker Compose project (`score67`), database volume, bridge network and loopback port (`127.0.0.1:8067`). No existing application is replaced.

- Immutable releases: `/opt/score67/releases/<git-sha>`.
- Current release link: `/opt/score67/current`.
- Runtime secrets: `/opt/score67/shared/.env` (root-only).
- Database backups: `/opt/score67/backups` (root-only).
- Restricted release receiver: `/usr/local/sbin/score67-deploy`.
- Backup command: `/usr/local/sbin/score67-backup`.
- Nginx site: `/etc/nginx/sites-available/score67.de.conf`.

The application runs as a non-root container user, with one Uvicorn process, no Linux capabilities, bounded logs and a memory limit. PostgreSQL is not published to a host port. Forwarded headers are overwritten by Nginx; Uvicorn trusts only the Score67 bridge gateway and loopback. See [Uvicorn proxy settings](https://www.uvicorn.org/settings/).

The dedicated `score67-deploy` SSH key cannot open a general shell or forward ports. Its forced command accepts only a release ID and bounded source archive. The root-owned receiver validates archive paths and types. GitHub stores the private key as an environment secret; it is not in Git or on the server. GitHub's verified server host key is also pinned. Treat write access to `main` as production deployment authority.

## Certificates

A Let's Encrypt certificate covers `score67.de` and `www.score67.de`, issued through the existing Certbot account and webroot challenge. It lives at `/etc/letsencrypt/live/score67.de/`. The existing twice-daily `certbot.timer` renews it. A Score67-specific deploy hook validates and reloads Nginx after a successful renewal. Renewal testing uses the ACME test CA only and never replaces the production certificate.

```bash
sudo certbot renew --cert-name score67.de --dry-run --no-random-sleep-on-renew
sudo nginx -t
```

Reference: [Certbot webroot and renewal hooks](https://github.com/certbot/certbot/blob/main/certbot/docs/using.rst).

## Database safety and rollback

Alembic migration `0001_initial` provides the production baseline; `0002_game_management` adds game lifecycle dates and allows a board to have no active game. An upgrade test verifies existing boards, credentials, scores and events survive. Production refuses automatic table creation and checks the schema revision at startup. `0003_board_location` adds a nullable venue field; existing boards remain without a location. The previous release requires revision 0002, so after this migration an old-image restart alone cannot roll back; prefer a forward fix or a compatible code revert retaining the new schema support. Update the startup schema check when adding a new revision.

Every deployment takes a PostgreSQL custom-format dump before applying migrations. A daily systemd timer also backs up the database; completed dumps are retained for 14 days. Backups currently live on the same server: they support application/database recovery, but do not protect against total server loss. Off-server backup storage remains to be configured.

If the new application fails its deployment health check, the receiver attempts to restore the previous application image. It does not downgrade or overwrite the database automatically. A migration failure leaves the old application selected. First deployment has no previous app to roll back to. A brief application restart interruption is expected; viewers reconnect automatically.

To inspect production:

```bash
cd /opt/score67/current
export RELEASE_SHA=$(basename "$(readlink -f /opt/score67/current)")
docker compose --project-name score67 --env-file /opt/score67/shared/.env -f deploy/compose.yaml ps
docker compose --project-name score67 --env-file /opt/score67/shared/.env -f deploy/compose.yaml logs --tail=100 app
curl --fail https://score67.de/health
systemctl status score67-backup.timer certbot.timer
```

To roll back code, prefer reverting the relevant commit on `main`; the checked deployment flow then rebuilds the reverted code with a new SHA. In an incident an administrator may manually start an existing immutable release using its compose file and SHA, after checking schema compatibility. Do not delete Docker volumes or restore a dump over the live database without an explicit recovery decision.

## Email

Optional email sign-in sends mail over SMTP (STARTTLS). Set `SMTP_HOST`, `SMTP_PORT`, `SMTP_USER`, `SMTP_PASSWORD` and `MAIL_FROM` in `/opt/score67/shared/.env` and redeploy; without `SMTP_HOST` the sign-in is hidden. The sender domain needs SPF/DKIM for the provider.

## Current product scope

Production contains the football increment and the v0.6 basketball pilot. Reusable teams/lineups, goal banners, QR codes and custom design templates remain future work. The latest requested controls are included: timestamp-generated board labels, tap-to-edit team names and colors, and explicit plus/minus goals with audited, nonnegative corrections. Original source documents are retained as historical requirements; these later instructions supersede their conflicting creation/design details.

The device dashboard adds historical results, future-game preparation, archive/restore/delete, visible back navigation and browser-local global defaults. Creation throttling is disabled by default for testing (`SCOREBOARD_CREATE_LIMIT=0`). A positive hourly count can be configured when needed; PIN attempt throttling remains active.

Version 0.4 adds optional per-game squads, player attribution and yellow cards using the existing match/event JSON storage. The required database revision remains `0003_board_location`.

Version 0.5 adds basketball in existing match/event JSON; no database migration is required. New games can select either sport. Four presets, countdown control, 1/2/3-point scoring, team fouls, cumulative timeouts and repeat overtime are supported. Personal fouls and competition-specific timeout allocation are not implemented. Required schema remains `0003_board_location`.

Version 0.6 adds private personal fouls, numbered basketball squads, player scoring matrices and a prominent Play/Stop control. Basketball points require a stopped clock, enforced by the API. No database migration is required; the schema remains `0003_board_location`.

Version 0.7 adds private live per-player PTS/REB/AST/STL/BLK/TO/PF tables and event recording/correction for rebounds, assists, steals, blocks and turnovers. Statistics are derived from existing match events. No schema migration is required.

Version 0.8 adds the quick-scoring basketball controller (both teams side by side in landscape, team-foul penalty and fouled-out markers, quarter scores in `period_scores`) and a client tap queue: tallies are shown immediately, sent in order and kept across offline periods and reloads with their original command IDs. Basketball points may now be scored while the clock runs; the 0.6 stopped-clock rule is removed. No schema migration is required.

Migration `0004_board_description` adds a nullable private scoreboard description (max 300 characters); the startup schema check now requires `0004_board_description`. Creation also accepts an optional future `scheduled_at` for the first game. The description is returned only in control state and the dashboard, never in public state.

Version 0.9 replaces the basketball matrix with the landscape console. New match actions (JSON only, no migration): `technical_foul`(+correction), `possession`, `lineup` (≤5 squad players in `on_court`, private). Short team names are limited to 3 characters; older longer values are trimmed when projected. Undo now also clears fields an action newly introduced.

Version 0.10 moves football to the landscape console. New football actions (JSON only, no migration): `foul`, `free_kick`, `penalty` (+corrections, private), `score` with `detail: penalty`, and lineups of up to 11. Creation skips the PIN page; the PIN is kept in the creating browser's localStorage (`score67-pin:<slug>`) and shown in the Sharing tab.

Version 0.11 adds migration `0005_match_trash` (nullable `match.trashed_at`, `trash_reason`, `touched_at`); the startup schema check requires `0005_match_trash`. An in-process hourly cleaner trashes abandoned (24 h without activity, not finished) and never-started games (24 h after the scheduled start, or 7 days untouched without one) and permanently deletes trash older than 30 days (sets `deleted_at`). The first run after deployment also trashes older abandoned test games; they remain restorable for 30 days. Dashboard "delete" now moves to the trash; permanent deletion happens from the trash.

Version 0.13 adds migration `0006_board_privacy` (`scoreboard.private` default false, `overlay_key` backfilled for existing boards); the startup schema check requires `0006_board_privacy`. Private boards return 403 `private` on public state, close public sockets and are excluded from /api/live unless the request carries a valid controller cookie or `?k=<overlay_key>`. `period_length_min` now allows 1–120.

Version 0.17 adds migration `0007_displays` (tables `display`, `display_admin`); the startup schema check requires `0007_displays`. Displays are managed by browsers holding a `score67d_<id>` cookie; devices authenticate with a bearer token obtained via `POST /api/display/pair` (30 attempts per IP and hour) and follow `/ws/display` or `GET /api/display/state`. Assigning a board requires control of that board.

Version 0.22 adds migration `0008_board_stream` (nullable `scoreboard.stream_url`, https only); the startup schema check requires `0008_board_stream`. The scoreboard description is now public for public boards (state, /api/live) alongside `stream_url`.

Version 0.23 adds migration `0009_assets` (table `asset` for team logos) and the Pillow dependency; the startup schema check requires `0009_assets`. Requests stay limited to 16 KB except `POST /api/s/<slug>/matches/<id>/logo` (400 KB) — both in the app and in Nginx (`deploy/nginx.conf`, a regex location for that path). The Nginx file is installed manually at `/etc/nginx/sites-available/score67.de.conf`; it is not part of the CI deployment, so apply changes with `nginx -t` and a reload.
