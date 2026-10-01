# Score67

A small, self-hosted scoreboard for sports streams. This checkout contains the **first football implementation increment**, deployed directly from `main`; it is not the complete specification.

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

- Independent football scoreboards; automatic timestamp labels, random public links and six-digit PINs.
- Hashed device cookies, additional devices, revocation, PIN rotation and persistent rate limits.
- Flutter phone controller; Jinja/HTML landing page, spectator page and transparent OBS overlay.
- Home/Guest defaults, editable names and abbreviations, 1–12 periods of 1–60 minutes, optional clock.
- Red cards per team with plus/minus correction, undo and live card icons in spectator/OBS views.
- Plus/minus goals, tap-to-edit team names and colors, period transitions, clock correction, final whistle, undo and new games. Archived match state remains available by ID.
- Revision checks, idempotent command retries, persistent event records and reconnecting live state.
- Small, large, hidden, left/right and automatic break/final views; configurable broadcast delay.
- Shared German and English JSON translations.
- Device dashboard at `/dashboard`: planned (with or without a date), running, completed and archived games; archive, restore and delete controls.
- Public `/live` directory of active games, including breaks, with automatically updated scores, clocks and red cards. No sign-in required.
- WhatsApp, Facebook, copy-link and native sharing for spectator links from the public view and controller.
- Future games can be prepared without interrupting the live game. Opening their controls activates them; kickoff remains manual.
- Visible back navigation and global language/default game-format settings, saved on this browser.

The five-scoreboards-per-hour creation cap is disabled during testing. `SCOREBOARD_CREATE_LIMIT=0` (default) keeps it off; a positive value enables an hourly IP limit later. PIN protection remains enabled.

## Not yet included

Email recovery, QR codes, basketball controls/rules, rosters, goal banners, match export, custom branding and additional templates. The initial template styling is an interpretation of the textual design document, which contains no visual mockups.

Production uses the current football increment. Email recovery, the remaining stage-1 acceptance criteria, mobile/OBS field testing and operator/legal pages are still outstanding. Database migrations and PostgreSQL integration checks are part of every deployment.

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
