import asyncio
from contextlib import asynccontextmanager
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import hmac
import json
import re
import os
from pathlib import Path
import secrets
import threading
import time
from typing import Literal
from uuid import UUID, uuid4

from fastapi import FastAPI, HTTPException, Request, Response, WebSocket, WebSocketDisconnect
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import func, select

from . import display_feed, firmware, fixtures, forum, guides, led_messages, mail, preview, seo
from .db import Account, AccountSession, Admin, Asset, Device, DeviceToken, LoginToken, Board, Display, DisplayAdmin, Match, MatchEvent, RateLimit, Receipt, database
from .domain import FOOTBALL, BASKETBALL, TENNIS, RuleError, apply, period_ms, initial_state, normalize_clock, foul_mode, BASKETBALL_STATS, player_statistics, SHORT_MAX, FOOTBALL_EVENTS

ROOT = Path(__file__).resolve().parents[2]
RELEASE = json.loads((ROOT / "shared/release.json").read_text())


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def hash_pin(pin, salt=None):
    salt = salt or secrets.token_hex(16)
    return salt + ":" + hashlib.pbkdf2_hmac("sha256", pin.encode(), salt.encode(), 300000).hex()


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Location(StrictModel):
    lat: float = Field(ge=-85, le=85, allow_inf_nan=False)
    lng: float = Field(ge=-180, le=180, allow_inf_nan=False)
    label: str = Field(default="", max_length=120)
    visible: bool = False


class LocationUpdate(StrictModel):
    location: Location | None = None


DISPLAY_CODE_ALPHABET = "0123456789"   # digits only: read off a panel, typed on a number pad
CLAIM_CODE_SECONDS = 24 * 3600   # code shown on a self-registered panel until someone claims it
IDENTIFY_SECONDS = 10


class DisplayUpdate(StrictModel):
    name: str | None = Field(default=None, min_length=1, max_length=60)
    board: str | None = Field(default=None, max_length=10)
    brightness: int | None = Field(default=None, ge=10, le=100)
    beta: bool | None = None   # also install "test" firmware releases
    follow: bool | None = None   # switch to the game the owner opens in the control center


class DisplayRegister(StrictModel):
    """A self-registering device (ESP32 firmware); the key never leaves it except here."""
    device_key: str = Field(min_length=32, max_length=128)
    name: str | None = Field(default=None, min_length=1, max_length=60)
    fw: str | None = Field(default=None, max_length=20)


class DisplayDisconnect(StrictModel):
    expected_board: str = Field(min_length=1, max_length=10)
    expected_match: str | None = Field(max_length=36)


class DisplayClaim(StrictModel):
    code: str = Field(min_length=6, max_length=12)
    name: str | None = Field(default=None, min_length=1, max_length=60)


class LedMessage(StrictModel):
    kind: str = Field(default="text", max_length=10)
    text: str | None = Field(default=None, max_length=200)
    icon: str | None = Field(default=None, max_length=20)
    effect: str | None = Field(default=None, max_length=10)
    color: str | None = Field(default=None, max_length=7)
    seconds: int = Field(default=8, ge=1, le=600)


class DisplayConnect(StrictModel):
    code: str = Field(min_length=6, max_length=12)


LOGO_PATH = re.compile(r"^/api/s/[^/]+/matches/[^/]+/logo$")
LOGO_MAX_REQUEST = 400_000
LOGO_MAX_PIXELS = 4_000_000


class LogoUpload(StrictModel):
    team: Literal["home", "away"]
    data: str | None = Field(default=None, max_length=LOGO_MAX_REQUEST)


def encode_logo(data_url):
    """Decode an uploaded PNG/JPEG/WebP and re-encode it as PNG (max 256 px).

    Only the re-encoded pixels are stored, never the uploaded bytes; oversized
    or malformed images ("decompression bombs") are rejected before decoding."""
    import base64
    match = re.fullmatch(r"data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/=]+)", data_url or "")
    if not match:
        raise HTTPException(422, "logo_invalid")
    try:
        raw = base64.b64decode(match[2], validate=True)
    except ValueError as exc:
        raise HTTPException(422, "logo_invalid") from exc
    return encode_logo_bytes(raw)


def encode_logo_bytes(raw):
    """Re-encode image bytes (PNG/JPEG/WebP) as PNG, max 256 px; 422 logo_invalid otherwise."""
    import io
    from PIL import Image
    try:
        with Image.open(io.BytesIO(raw)) as image:
            if image.format not in ("PNG", "JPEG", "WEBP") or image.width * image.height > LOGO_MAX_PIXELS:
                raise ValueError("unsupported")
            image.load()
            picture = image.convert("RGBA")
        picture.thumbnail((256, 256))
        out = io.BytesIO()
        picture.save(out, "PNG", optimize=True)
        return out.getvalue()
    except (Image.DecompressionBombError, OSError, ValueError, SyntaxError) as exc:
        raise HTTPException(422, "logo_invalid") from exc


class PrivacyUpdate(StrictModel):
    private: bool


class DescriptionUpdate(StrictModel):
    description: str | None = Field(default=None, max_length=300)


def clean_description(value):
    return (value or "").strip() or None


def clean_stream_url(value):
    """Public livestream link: https only, so no javascript:/data: links reach viewers."""
    value = (value or "").strip()
    if not value:
        return None
    from urllib.parse import urlparse
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or len(value) > 300 or any(c in value for c in ' "<>'):
        raise HTTPException(422, "stream_url_invalid")
    return value


class StreamUpdate(StrictModel):
    stream_url: str | None = Field(default=None, max_length=300)


class CreateBoard(StrictModel):
    sport: Literal["football", "basketball", "tennis"] = "football"
    tennis_category: Literal["women", "men"] = "women"
    tennis_best_of: Literal[3, 5] = 3
    tennis_mode: Literal["simple", "detailed"] = "detailed"
    tennis_final_tiebreak: Literal[7, 10] = 7
    language: Literal["de", "en"] = "de"
    description: str | None = Field(default=None, max_length=300)
    stream_url: str | None = Field(default=None, max_length=300)
    scheduled_at: int | None = Field(default=None, ge=0)
    period_count: int | None = Field(default=None, ge=1, le=12)
    period_length_min: int | None = Field(default=None, ge=1, le=120)
    lineup_size: int | None = Field(default=None, ge=1, le=11)
    location: Location | None = None
    # Optional, e.g. from a fussball.de / basketball-bund.net lookup (fixture = its result).
    home: str | None = Field(default=None, max_length=60)
    away: str | None = Field(default=None, max_length=60)
    home_short: str | None = Field(default=None, max_length=SHORT_MAX)
    away_short: str | None = Field(default=None, max_length=SHORT_MAX)
    fixture: dict | None = None
    # Take the clubs' logos from the source site (fussball.de).
    fixture_logos: bool = False


class FixtureLookup(StrictModel):
    url: str = Field(min_length=10, max_length=500)


def fixture_logos(body):
    """Club logos for a new game from the source site, fetched before the
    database lock: {"home": png, ...}. Missing or broken logos are skipped."""
    fixture = fixtures.stored(body.fixture) if body.fixture_logos else None
    logos = {}
    for team in ("home", "away"):
        club_id = (fixture or {}).get(team, {}).get("club_id")
        try:
            raw = fixtures.club_logo(club_id) if club_id else None
            if raw:
                logos[team] = encode_logo_bytes(raw)
        except (fixtures.FixtureError, HTTPException):
            continue
    return logos


def name_teams(s, body):
    """Team names and short names of a new game; a missing short name is guessed."""
    for team in ("home", "away"):
        name = (getattr(body, team) or "").strip()
        if not name:
            continue
        short = fixtures.ascii_upper(getattr(body, f"{team}_short") or "")[:SHORT_MAX] or fixtures.guess_short(name)
        s[team].update(name=name, short=short)


class CreateMatch(StrictModel):
    sport: Literal["football", "basketball", "tennis"] = "football"
    tennis_category: Literal["women", "men"] = "women"
    tennis_best_of: Literal[3, 5] = 3
    tennis_mode: Literal["simple", "detailed"] = "detailed"
    tennis_final_tiebreak: Literal[7, 10] = 7
    command_id: UUID
    home: str = Field(default="Home", min_length=1, max_length=60)
    away: str = Field(default="Guest", min_length=1, max_length=60)
    scheduled_at: int | None = Field(default=None, ge=0)
    period_count: int | None = Field(default=None, ge=1, le=12)
    period_length_min: int | None = Field(default=None, ge=1, le=120)
    lineup_size: int | None = Field(default=None, ge=1, le=11)
    home_short: str | None = Field(default=None, max_length=SHORT_MAX)
    away_short: str | None = Field(default=None, max_length=SHORT_MAX)
    fixture: dict | None = None
    fixture_logos: bool = False


class Claim(StrictModel):
    pin: str = Field(pattern=r"^\d{6}$")
    label: str = Field(default="Browser", min_length=1, max_length=60)


class DeviceJoin(StrictModel):
    code: str = Field(min_length=16, max_length=64)


class LoginRequest(StrictModel):
    email: str = Field(min_length=3, max_length=254)
    language: Literal["de", "en"] = "de"


class LoginVerify(StrictModel):
    token: str = Field(min_length=20, max_length=100)


class Ownership(StrictModel):
    linked: bool


EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
ACCOUNT_COOKIE = "score67_account"
# One cookie per browser; the server keeps which boards it controls. Older
# releases set one cookie per board (score67_<slug>); those are taken over.
DEVICE_COOKIE = "score67_device"
DEVICE_SECONDS = 400 * 86400  # the longest lifetime browsers accept
LOGIN_TOKEN_SECONDS = 1800
SESSION_SECONDS = 180 * 86400


def mask_email(email):
    name, domain = email.split("@", 1)
    return f"{name[:2]}{'•' * max(1, len(name) - 2)}@{domain}"


def login_mail(language, link):
    texts = json.loads((ROOT / f"shared/i18n/{language}.json").read_text())
    return texts["email.login.subject"], texts["email.login.body"].replace("{link}", link)


def notice_mail(language, key, name):
    texts = json.loads((ROOT / f"shared/i18n/{language}.json").read_text())
    return texts[f"{key}.subject"], texts[f"{key}.body"].replace("{name}", name)


class Command(StrictModel):
    command_id: UUID
    expected_revision: int = Field(ge=0)
    action: str = Field(max_length=30)
    data: dict = Field(default_factory=dict)


COUNTED_EVENTS = ("score", "red_card", "yellow_card", "team_foul", "timeout", "personal_foul", "technical_foul") + BASKETBALL_STATS + FOOTBALL_EVENTS
PRIVATE_EVENTS = ("personal_foul", "technical_foul", "assign_foul_player", "lineup") + FOOTBALL_EVENTS
CORRECTION_EVENTS = tuple(f"{kind}_correction" for kind in COUNTED_EVENTS)


def hours_env(name, default):
    return float(os.getenv(name, default)) * 3600


def clean_matches(db, now=None):
    """Move abandoned and never-started games to the trash; purge old trash.

    Finished games are never touched, and an abandoned game in which something
    was scored is ended (flagged automatic) instead of trashed: a played game
    must stay under "finished". Returns (trashed, purged)."""
    now = now or time.time()
    stale = hours_env("TRASH_STALE_HOURS", 24)
    planned = hours_env("TRASH_PLANNED_GRACE_HOURS", 24)
    unscheduled = hours_env("TRASH_UNSCHEDULED_DAYS", 7) * 24
    retention = hours_env("TRASH_RETENTION_DAYS", 30) * 24
    trashed = purged = 0
    candidates = db.scalars(select(Match).where(Match.deleted_at.is_(None), Match.trashed_at.is_(None),
                                                Match.archived_at.is_(None))).all()
    for m in candidates:
        phase = m.state.get("phase")
        if phase == "finished":
            continue
        last = db.scalar(select(MatchEvent).where(MatchEvent.match_id == m.id).order_by(MatchEvent.id.desc()).limit(1))
        activity = max(m.created_at, m.touched_at or 0, (last.payload.get("occurred_at", 0) / 1000) if last else 0)
        if phase == "pre_game":
            due = (max(m.scheduled_at, m.touched_at or 0) + planned) if m.scheduled_at else activity + unscheduled
            reason = "not_started"
        else:
            due, reason = activity + stale, "abandoned"
        if now < due:
            continue
        if reason == "abandoned" and end_played(db, m, now):
            continue
        m.trashed_at, m.trash_reason = now, reason
        b = db.get(Board, m.slug)
        if b and b.active_match == m.id:
            b.active_match = None
        m.revision += 1
        trashed += 1
    for m in db.scalars(select(Match).where(Match.deleted_at.is_(None), Match.trashed_at.is_not(None),
                                            Match.trashed_at < now - retention)).all():
        m.deleted_at = now
        purged += 1
    db.commit()
    return trashed, purged


def end_played(db, m, now):
    """End a forgotten game that has scoring in it (tennis has no automatic end
    by clock). Returns False when there is nothing worth keeping."""
    events = db.scalars(select(MatchEvent).where(MatchEvent.match_id == m.id).order_by(MatchEvent.id)).all()
    if not any(not e.cancelled and (e.payload.get("type") in COUNTED_EVENTS or e.payload.get("type", "").startswith("tennis_"))
               for e in events):
        return False
    try:
        m.state, payload, before = apply(m.state, "game_end", {}, round(now * 1000))
    except RuleError:
        return False
    payload["automatic"] = True
    db.add(MatchEvent(match_id=m.id, admin_id=events[-1].admin_id, payload=payload, before=before))
    m.revision += 1
    return True


def release_idle_displays(db, now=None):
    """LED panels go back to their code when the game they show is over.

    A panel is released LED_RELEASE_FINISHED_MINUTES after its game ended,
    LED_RELEASE_IDLE_HOURS after the last activity of a game that never ended,
    and at once when the board has no game. Returns the number released."""
    now = now or time.time()
    finished = float(os.getenv("LED_RELEASE_FINISHED_MINUTES", 120)) * 60
    idle = float(os.getenv("LED_RELEASE_IDLE_HOURS", 6)) * 3600
    released = 0
    for d in db.scalars(select(Display).where(Display.board_slug.is_not(None))).all():
        b = db.get(Board, d.board_slug)
        m = db.get(Match, b.active_match) if b and b.active_match else None
        if m and not m.deleted_at and not m.trashed_at:
            last = db.scalar(select(MatchEvent).where(MatchEvent.match_id == m.id).order_by(MatchEvent.id.desc()).limit(1))
            activity = max(m.created_at, m.touched_at or 0, (last.payload.get("occurred_at", 0) / 1000) if last else 0)
            limit = finished if m.state.get("phase") == "finished" else idle
            if now < activity + limit:
                continue
        d.board_slug = None
        released += 1
    return released


def finish_overdue_matches(db, now=None):
    """End started games the user forgot to end.

    A game is due once twice its planned playing time (period_count ×
    period_length_min, at least AUTO_END_MIN_MINUTES) has passed since kickoff
    and nothing was entered for AUTO_END_QUIET_MINUTES. A football game of
    2×45 min therefore ends 180 min after kickoff. Returns the number ended."""
    now = now or time.time()
    factor = float(os.getenv("AUTO_END_FACTOR", 2))
    minimum = float(os.getenv("AUTO_END_MIN_MINUTES", 180)) * 60
    quiet = float(os.getenv("AUTO_END_QUIET_MINUTES", 15)) * 60
    ended = 0
    candidates = db.scalars(select(Match).where(Match.deleted_at.is_(None), Match.trashed_at.is_(None),
                                                Match.archived_at.is_(None))).all()
    for m in candidates:
        if m.state.get("sport") == "tennis" or m.state.get("phase") in ("pre_game", "finished"):
            continue
        events = [e for e in db.scalars(select(MatchEvent).where(MatchEvent.match_id == m.id).order_by(MatchEvent.id)).all()
                  if not e.cancelled]
        kickoff = next((e for e in events if e.payload.get("type") == "period_start"), None)
        if not kickoff:
            continue
        planned = m.state["period_count"] * m.state["period_length_min"] * 60
        due = kickoff.payload["occurred_at"] / 1000 + max(planned * factor, minimum)
        last = max(events[-1].payload.get("occurred_at", 0) / 1000, m.touched_at or 0)
        if now < due or now < last + quiet:
            continue
        try:
            m.state, payload, before = apply(m.state, "game_end", {}, round(now * 1000))
        except RuleError:
            continue
        # A forgotten clock kept running; freeze it at the regular period end.
        clock = m.state["clock"]
        if clock["elapsed_ms"] > period_ms(m.state):
            m.state = {**m.state, "clock": {**clock, "elapsed_ms": period_ms(m.state)}}
            payload["clock_ms"] = period_ms(m.state)
        payload["automatic"] = True
        db.add(MatchEvent(match_id=m.id, admin_id=kickoff.admin_id, payload=payload, before=before))
        m.revision += 1
        ended += 1
    db.commit()
    return ended


def available_events(events):
    available = []
    for event in events:
        if event.cancelled:
            continue
        kind = event.payload["type"]
        if kind in COUNTED_EVENTS:
            available.append(event)
        elif kind in CORRECTION_EVENTS:
            candidates = [e for e in available if e.payload["type"] == kind.removesuffix("_correction") and e.payload.get("team") == event.payload.get("team")]
            target = next((e for e in candidates if e.id == event.payload.get("corrects")), None) if event.payload.get("corrects") else (candidates[-1] if candidates else None)
            if target:
                available.remove(target)
    return available


def create_app(db_url=None, secure_cookies=None):
    secure = secure_cookies if secure_cookies is not None else os.getenv("COOKIE_SECURE", "true").lower() == "true"
    lock = threading.RLock()

    @asynccontextmanager
    async def lifespan(app):
        engine, sessions = database(db_url)
        app.state.sessions = sessions

        def clean():
            with lock, sessions() as db:
                finish_overdue_matches(db)
                release_idle_displays(db)
                return clean_matches(db)

        async def cleaner():
            interval = float(os.getenv("TRASH_INTERVAL_SECONDS", 600))
            while interval > 0:
                try:
                    await asyncio.to_thread(clean)
                except Exception:  # noqa: BLE001 - the cleaner must never stop the app
                    pass
                await asyncio.sleep(interval)

        task = asyncio.create_task(cleaner())
        yield
        task.cancel()
        engine.dispose()

    app = FastAPI(title="Score67", version=RELEASE["version"], lifespan=lifespan)
    app.state.send_mail = mail.send
    templates = Jinja2Templates(directory=ROOT / "backend/score67/templates")
    templates.env.globals["release_label"] = RELEASE["label"]
    templates.env.globals["public_origin"] = os.getenv("PUBLIC_ORIGIN", "")
    templates.env.globals["ms_date"] = lambda ms: datetime.fromtimestamp(ms / 1000, timezone.utc).strftime("%d.%m.%Y") if ms else ""
    # Footers show the build time in the viewer's time zone (common.mjs).
    templates.env.globals["release_version"] = RELEASE["version"]
    templates.env.globals["release_built_at"] = RELEASE["built_at"]
    app.mount("/static", StaticFiles(directory=ROOT / "backend/score67/static"), name="static")
    app.mount("/i18n", StaticFiles(directory=ROOT / "shared/i18n"), name="i18n")
    build = ROOT / "control/build/web"
    if build.exists():
        app.mount("/app", StaticFiles(directory=build), name="flutter")

    @app.middleware("http")
    async def protections(request, call_next):
        if request.method in ("POST", "PUT", "PATCH", "DELETE"):
            origin = request.headers.get("origin")
            expected = os.getenv("PUBLIC_ORIGIN", str(request.base_url).rstrip("/"))
            if origin and origin != expected:
                return JSONResponse({"error": "origin_rejected"}, status_code=403)
            if request.headers.get("sec-fetch-site") == "cross-site":
                return JSONResponse({"error": "origin_rejected"}, status_code=403)
            if request.method != "DELETE" and request.headers.get("content-type", "").split(";")[0] != "application/json":
                return JSONResponse({"error": "json_required"}, status_code=415)
            # Logo uploads (already downscaled by the client) may be larger.
            limit = (LOGO_MAX_REQUEST if LOGO_PATH.match(request.url.path)
                     else firmware.MAX_REQUEST if request.url.path == "/api/firmware" else 16384)
            length = request.headers.get("content-length", "0")
            if not length.isdigit() or int(length) > limit:
                return JSONResponse({"error": "request_too_large"}, status_code=413)
            # Also bound chunked requests, for which Content-Length can be absent.
            size = 0
            chunks = []
            async for chunk in request.stream():
                size += len(chunk)
                if size > limit:
                    return JSONResponse({"error": "request_too_large"}, status_code=413)
                chunks.append(chunk)
            request._body = b"".join(chunks)
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin" if request.url.path == "/location-picker" else "no-referrer"
        if request.url.path.startswith("/api/") or request.url.path.endswith("/control") or request.url.path in ("/", "/new", "/dashboard", "/login", "/settings"):
            response.headers["Cache-Control"] = "no-store"
        return response

    @app.exception_handler(HTTPException)
    async def http_error(_, exc):
        return JSONResponse({"error": exc.detail}, status_code=exc.status_code)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_, exc):
        return JSONResponse({"error": "invalid_request"}, status_code=422)

    def board(db, slug):
        b = db.get(Board, slug)
        if not b:
            raise HTTPException(404, "not_found")
        return b

    def current_account(db, cookies):
        token = cookies.get(ACCOUNT_COOKIE, "")
        session = db.scalar(select(AccountSession).where(AccountSession.token_hash == digest(token))) if token else None
        if not session or session.last_seen_at < time.time() - SESSION_SECONDS:
            return None
        session.last_seen_at = time.time()
        return db.get(Account, session.account_id)

    def owner_admin(db, b, cookies):
        """The admin entry of the signed-in owner; access follows ownership."""
        account = current_account(db, cookies) if b.owner_id else None
        if not account or account.id != b.owner_id:
            return None
        admin = db.scalar(select(Admin).where(Admin.slug == b.slug, Admin.account_id == account.id))
        if not admin:
            admin = Admin(id=str(uuid4()), slug=b.slug, token_hash=digest(secrets.token_urlsafe(32)),
                          label=account.email, last_seen_at=time.time(), account_id=account.id)
            db.add(admin)
            db.flush()
        admin.revoked = False
        return admin

    def current_device(db, cookies):
        token = cookies.get(DEVICE_COOKIE, "")
        row = db.get(DeviceToken, digest(token)) if token else None
        if not row:
            return None
        row.last_seen_at = time.time()
        return row.device_id

    def device_of(db, request):
        """This browser's device, including one created earlier in the same request."""
        return getattr(request.state, "device_id", None) or current_device(db, request.cookies)

    def ensure_device(db, request, response):
        device_id = device_of(db, request)
        if device_id:
            token = request.cookies.get(DEVICE_COOKIE)
        else:
            device_id, token = str(uuid4()), secrets.token_urlsafe(32)
            db.add(Device(id=device_id, created_at=time.time()))
            db.add(DeviceToken(token_hash=digest(token), device_id=device_id, created_at=time.time(), last_seen_at=time.time()))
            db.flush()
        if token:
            set_device_cookie(response, token)
        request.state.device_id = device_id
        return device_id

    def set_device_cookie(response, token):
        response.set_cookie(DEVICE_COOKIE, token, httponly=True, secure=secure,
                            samesite="lax", max_age=DEVICE_SECONDS, path="/")

    def legacy_slugs(cookies):
        return [cookie[8:] for cookie in cookies if cookie.startswith("score67_") and len(cookie) == 18]

    def adopt_legacy(db, request, response):
        """Move per-board cookies of older releases onto this browser's device and
        drop them, so the request header stays small however many boards there are."""
        for slug in legacy_slugs(request.cookies):
            token = request.cookies[f"score67_{slug}"]
            admin = db.scalar(select(Admin).where(Admin.slug == slug, Admin.token_hash == digest(token)))
            if admin and not admin.revoked:
                device_id = ensure_device(db, request, response)
                if admin.device_id not in (None, device_id):
                    continue
                admin.device_id = device_id
            response.delete_cookie(f"score67_{slug}", path="/")

    def device_slugs(db, request):
        """Boards this browser controls: its device first, then leftover per-board cookies."""
        device_id = device_of(db, request)
        slugs = list(db.scalars(select(Admin.slug).where(Admin.device_id == device_id, Admin.revoked == False)
                                .distinct())) if device_id else []
        return slugs + [slug for slug in legacy_slugs(request.cookies) if slug not in slugs]

    def cookie_admin(db, slug, cookies, device_id=None):
        """The admin entry this browser holds for the board, if any."""
        token = cookies.get(f"score67_{slug}", "")
        admin = db.scalar(select(Admin).where(Admin.slug == slug, Admin.token_hash == digest(token))) if token else None
        if admin and not admin.revoked:
            return admin
        device_id = device_id or current_device(db, cookies)
        if not device_id:
            return None
        return db.scalar(select(Admin).where(Admin.slug == slug, Admin.device_id == device_id, Admin.revoked == False)
                         .order_by(Admin.last_seen_at.desc()).limit(1))

    def authorize(db, slug, request):
        admin = cookie_admin(db, slug, request.cookies, getattr(request.state, "device_id", None))
        if not admin or admin.last_seen_at < time.time() - 180 * 86400:
            admin = owner_admin(db, board(db, slug), request.cookies)
            if not admin:
                raise HTTPException(401, "admin_required")
        admin.last_seen_at = time.time()
        return admin

    def viewer_allowed(db, b, cookies, key):
        """Public boards are open; private ones only to controllers and OBS (overlay key)."""
        if not b.private or (key and b.overlay_key and hmac.compare_digest(key, b.overlay_key)):
            return True
        if cookie_admin(db, b.slug, cookies):
            return True
        account = current_account(db, cookies) if b.owner_id else None
        return bool(account and account.id == b.owner_id)

    def public_board(db, slug, request):
        b = board(db, slug)
        if not viewer_allowed(db, b, request.cookies, request.query_params.get("k")):
            raise HTTPException(403, "private")
        return b

    def grant(db, slug, request, response, label):
        device_id = ensure_device(db, request, response)
        db.add(Admin(id=str(uuid4()), slug=slug, token_hash=digest(secrets.token_urlsafe(32)), label=label,
                     last_seen_at=time.time(), device_id=device_id))

    def state(db, b, match_id=None, private=False):
        public_location = {k: b.location[k] for k in ("lat", "lng", "label")} if b.location and b.location.get("visible") else None
        target = match_id or b.active_match
        if not target:
            s = initial_state()
            s.update(scoreboard=b.slug, name=b.name, language=b.language, match_id=None,
                     revision=0, server_now=round(time.time() * 1000), phase="no_match", events=[], location=public_location,
                     description=b.description, stream_url=b.stream_url)
            s["overlay"]["view"] = "hidden"
            for team in ("home", "away"):
                s[team].update(score=0, squad=[], counters={"red_cards": 0, "yellow_cards": 0})
            return s
        m = db.get(Match, target)
        if not m or m.slug != b.slug:
            raise HTTPException(404, "not_found")
        if m.deleted_at:
            raise HTTPException(410, "match_deleted")
        s = deepcopy(m.state)
        s.setdefault("team_fouls_enabled", False)
        s["foul_mode"] = foul_mode(s)
        s.setdefault("overtime_length_min", 5)
        normalize_clock(s, round(time.time() * 1000))
        events = db.scalars(select(MatchEvent).where(MatchEvent.match_id == m.id).order_by(MatchEvent.id)).all()
        s.update(description=b.description, stream_url=b.stream_url)
        s.update(scoreboard=b.slug, name=b.name, language=b.language, match_id=m.id,
                 revision=m.revision, server_now=round(time.time() * 1000),
                 created_at=round(m.created_at * 1000),
                 scheduled_at=round(m.scheduled_at * 1000) if m.scheduled_at else None,
                 archived=bool(m.archived_at), active=m.id == b.active_match, location=public_location,
                 trashed=bool(m.trashed_at), trash_reason=m.trash_reason,
                 trashed_at=round(m.trashed_at * 1000) if m.trashed_at else None)
        for team in ("home", "away"):
            s[team]["score"] = sum(e.payload.get("points", 0) for e in events
                                   if not e.cancelled and e.payload.get("team") == team and e.payload["type"] in ("score", "score_correction", "score_adjust"))
            s[team].setdefault("squad", [])
            s[team]["short"] = s[team]["short"][:SHORT_MAX]
            s[team]["counters"] = {f"{color}_cards": sum(e.payload.get("cards", 0) for e in events
                if not e.cancelled and e.payload.get("team") == team
                and e.payload["type"] in (f"{color}_card", f"{color}_card_correction")) for color in ("red", "yellow")}
        available = available_events(events)
        for team in ("home", "away"):
            s[team]["counters"].update(
                team_fouls=sum(1 for e in available if (e.payload["type"] == "team_foul" or (e.payload["type"] in ("personal_foul", "technical_foul") and e.payload.get("counts_team"))) and e.payload.get("team") == team
                               and min(e.payload["period"], s["period_count"]) == min(s["period"], s["period_count"])),
                timeouts=sum(1 for e in available if e.payload["type"] == "timeout" and e.payload.get("team") == team),
                fouls=sum(1 for e in available if e.payload["type"] == "foul" and e.payload.get("team") == team))
            # Points by the period they were scored in; corrections remove their target basket.
            periods = [0] * max(s["period"], s["period_count"], 1)
            for e in available:
                if e.payload["type"] == "score" and e.payload.get("team") == team:
                    index = min(max(e.payload.get("period", 0), 1), len(periods)) - 1
                    periods[index] += e.payload.get("points", 0)
            for e in events:
                if e.payload["type"] == "score_adjust" and not e.cancelled and e.payload.get("team") == team:
                    index = min(max(e.payload.get("period", 0), 1), len(periods)) - 1
                    periods[index] += e.payload.get("points", 0)
            s[team]["period_scores"] = periods
        if s["sport"] == "tennis":
            from .tennis import point_labels
            s["tennis"]["point_labels"] = point_labels(s["tennis"])
            for i, side in enumerate(("home", "away")):
                s[side]["score"] = s["tennis"]["sets"][i]
                s[side]["period_scores"] = [r["games"][i] for r in s["tennis"]["set_scores"]]
        available_ids = {e.id for e in available}
        s["events"] = [{**e.payload, "id": e.id, "cancelled": e.cancelled,
            "corrected": e.payload["type"] in COUNTED_EVENTS and not e.cancelled and e.id not in available_ids} for e in events]
        if private:
            s.update(description=b.description, board_created_at=round(b.created_at * 1000),
                     private=bool(b.private), overlay_key=b.overlay_key, fixture=m.fixture)
            for team in ("home", "away"):
                if s["sport"] == "basketball":
                    s[team]["statistics"] = player_statistics(s[team], [
                        e.payload for e in available if e.payload.get("team") == team])
                totals = {}
                for player in s[team].get("foul_players", []) + s[team].get("squad", []):
                    totals[player["id"]] = {**player, "fouls": 0}
                unassigned = 0
                for e in available:
                    if e.payload["type"] not in ("personal_foul", "technical_foul") or e.payload["team"] != team:
                        continue
                    player = e.payload.get("player")
                    if e.payload["type"] == "technical_foul" and not player:
                        continue
                    if player:
                        totals.setdefault(player["id"], {**player, "fouls": 0})["fouls"] += 1
                    else:
                        unassigned += 1
                s[team]["personal_fouls"] = list(totals.values())
                s[team]["unassigned_fouls"] = unassigned
        else:
            for team in ("home", "away"):
                s[team].pop("foul_players", None)
            s["events"] = [e for e in s["events"] if e["type"].removesuffix("_correction") not in PRIVATE_EVENTS
                           and e["type"].removesuffix("_correction") not in BASKETBALL_STATS]
            for team in ("home", "away"):
                s[team].pop("on_court", None)
        return s

    @app.get("/health")
    def health():
        with app.state.sessions() as db:
            db.execute(select(1))
        return {"status": "ok", "release": os.getenv("RELEASE_SHA", "development")}

    @app.get("/api/sports")
    def sports():
        return [FOOTBALL, BASKETBALL, TENNIS]

    @app.get("/api/templates")
    def available_templates():
        return [{"id": "standard", "kind": "stream", "views": ["scoreboard", "score_big", "hidden"]},
                {"id": "board", "kind": "screen", "views": ["score_big"]}]

    @app.post("/api/scoreboards", status_code=201)
    def create(body: CreateBoard, request: Request, response: Response):
        logos = fixture_logos(body)
        with lock, app.state.sessions() as db:
            now = time.time()
            key = "create:" + digest(request.client.host if request.client else "unknown")
            limit = db.get(RateLimit, key)
            create_limit = int(os.getenv("SCOREBOARD_CREATE_LIMIT", "0"))
            if create_limit > 0 and limit and limit.reset_at > now and limit.count >= create_limit:
                raise HTTPException(429, "rate_limited")
            if not limit:
                limit = RateLimit(key=key, count=0, reset_at=now + 3600)
                db.add(limit)
            if limit.reset_at <= now:
                limit.count, limit.reset_at = 0, now + 3600
            if body.scheduled_at is not None and body.scheduled_at <= now * 1000:
                raise HTTPException(422, "schedule_future")
            limit.count += 1
            slug = "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(10))
            while db.get(Board, slug):
                slug = "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(10))
            pin, match_id = f"{secrets.randbelow(1000000):06d}", str(uuid4())
            label = datetime.fromtimestamp(now, timezone.utc).isoformat(sep=" ", timespec="milliseconds").replace("+00:00", " UTC")
            b = Board(slug=slug, name=label, language=body.language, pin_hash=hash_pin(pin),
                      active_match=match_id, created_at=now, location=body.location.model_dump() if body.location else None,
                      description=clean_description(body.description), overlay_key=secrets.token_urlsafe(12),
                      stream_url=clean_stream_url(body.stream_url))
            account = current_account(db, request.cookies)
            b.owner_id = account.id if account else None
            db.add(b)
            db.flush()
            s = initial_state(body.period_count, body.period_length_min, body.sport, body.lineup_size, body.tennis_category, body.tennis_best_of, body.tennis_mode, body.tennis_final_tiebreak)
            name_teams(s, body)
            add_logos(db, slug, s, logos)
            db.add(Match(id=match_id, slug=slug, state=s, fixture=fixtures.stored(body.fixture),
                         created_at=now, scheduled_at=body.scheduled_at / 1000 if body.scheduled_at else None))
            grant(db, slug, request, response, "Browser")
            db.commit()
            return {"slug": slug, "pin": pin, "links": {"public": f"/s/{slug}",
                    "overlay": f"/s/{slug}/overlay", "control": f"/s/{slug}/control"}}

    @app.post("/api/fixtures/lookup")
    def lookup_fixture(body: FixtureLookup, request: Request):
        """Prefill a new game from a fussball.de or basketball-bund.net game link.
        The site is fetched outside the lock; nothing is stored here."""
        link = body.url.strip()
        try:
            fixtures.parse_link(link)
        except fixtures.FixtureError as e:
            raise HTTPException(422, e.code)
        with lock, app.state.sessions() as db:
            now = time.time()
            key = "fixture:" + digest(request.client.host if request.client else "unknown")
            limit = db.get(RateLimit, key)
            if not limit:
                limit = RateLimit(key=key, count=0, reset_at=now + 3600)
                db.add(limit)
            if limit.reset_at <= now:
                limit.count, limit.reset_at = 0, now + 3600
            if limit.count >= int(os.getenv("FIXTURE_LOOKUP_LIMIT", "60")):
                raise HTTPException(429, "rate_limited")
            limit.count += 1
            db.commit()
        try:
            return fixtures.lookup(link)
        except fixtures.FixtureError as e:
            raise HTTPException({"fixture_not_found": 404, "fixture_url": 422}.get(e.code, 502), e.code)

    @app.get("/api/s/{slug}/location")
    def get_location(slug: str, request: Request):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            return {"location": board(db, slug).location}

    @app.put("/api/s/{slug}/location")
    def update_location(slug: str, body: LocationUpdate, request: Request):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            b = board(db, slug)
            b.location = body.location.model_dump() if body.location else None
            if b.active_match:
                db.get(Match, b.active_match).revision += 1
            db.commit()
            return {"location": b.location}

    @app.put("/api/s/{slug}/privacy")
    def update_privacy(slug: str, body: PrivacyUpdate, request: Request):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            b = board(db, slug)
            b.private = body.private
            b.overlay_key = b.overlay_key or secrets.token_urlsafe(12)
            if b.active_match:
                db.get(Match, b.active_match).revision += 1
            db.commit()
            return {"private": b.private}

    @app.post("/api/s/{slug}/matches/{match_id}/logo")
    def upload_logo(slug: str, match_id: str, body: LogoUpload, request: Request):
        png = encode_logo(body.data) if body.data is not None else None
        with lock, app.state.sessions() as db:
            admin = authorize(db, slug, request)
            b = board(db, slug)
            m = db.get(Match, match_id)
            if not m or m.slug != slug or m.deleted_at:
                raise HTTPException(404, "not_found")
            url = store_logo(db, slug, png) if png is not None else None
            try:
                updated, payload, before = apply(m.state, "settings", {body.team: {"logo": url}}, round(time.time() * 1000))
            except RuleError as exc:
                raise HTTPException(422, str(exc)) from exc
            m.state = updated
            payload["command_id"] = str(uuid4())
            db.add(MatchEvent(match_id=m.id, admin_id=admin.id, payload=payload, before=before))
            m.revision += 1
            db.commit()
            return state(db, b, m.id, private=True)

    def store_logo(db, slug, png):
        """Keep a re-encoded logo for a board (max 30, unused ones are dropped first); its URL."""
        assets = db.scalars(select(Asset).where(Asset.slug == slug).order_by(Asset.created_at)).all()
        if len(assets) >= 30:
            used = " ".join(json.dumps(x.state) for x in db.scalars(select(Match).where(Match.slug == slug)))
            for asset in assets:
                if asset.id not in used:
                    db.delete(asset)
            db.flush()
            if db.scalar(select(func.count()).select_from(Asset).where(Asset.slug == slug)) >= 30:
                raise HTTPException(422, "logo_quota")
        asset = Asset(id=uuid4().hex, slug=slug, content_type="image/png", data=png, created_at=time.time())
        db.add(asset)
        return f"/media/{asset.id}.png"

    def add_logos(db, slug, s, logos):
        for team, png in logos.items():
            try:
                s[team]["logo"] = store_logo(db, slug, png)
            except HTTPException:
                break  # Logo quota: the game is created without them.

    @app.get("/api/fixtures/logo/{club_id}.png")
    def fixture_logo_preview(club_id: str):
        """Preview of a club logo on the source site, served from here (same origin)."""
        if not fixtures.CLUB_ID.fullmatch(club_id):
            raise HTTPException(404, "not_found")
        try:
            raw = fixtures.club_logo(club_id)
        except fixtures.FixtureError:
            raise HTTPException(502, "fixture_unavailable")
        if not raw:
            raise HTTPException(404, "not_found")
        return Response(encode_logo_bytes(raw), media_type="image/png", headers={"Cache-Control": "public, max-age=86400"})

    @app.get("/media/{name}")
    def media(name: str):
        if not re.fullmatch(r"[0-9a-f]{32}\.png", name):
            raise HTTPException(404, "not_found")
        with app.state.sessions() as db:
            asset = db.get(Asset, name[:-4])
            if not asset:
                raise HTTPException(404, "not_found")
            return Response(asset.data, media_type=asset.content_type,
                            headers={"Cache-Control": "public, max-age=31536000, immutable"})

    @app.put("/api/s/{slug}/stream")
    def update_stream(slug: str, body: StreamUpdate, request: Request):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            b = board(db, slug)
            b.stream_url = clean_stream_url(body.stream_url)
            if b.active_match:
                db.get(Match, b.active_match).revision += 1
            db.commit()
            return {"stream_url": b.stream_url}

    @app.put("/api/s/{slug}/description")
    def update_description(slug: str, body: DescriptionUpdate, request: Request):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            b = board(db, slug)
            b.description = clean_description(body.description)
            if b.active_match:
                db.get(Match, b.active_match).revision += 1
            db.commit()
            return {"description": b.description}

    @app.post("/api/s/{slug}/admin/claim")
    def claim(slug: str, body: Claim, request: Request, response: Response):
        with lock, app.state.sessions() as db:
            b = board(db, slug)
            if b.locked_until > time.time():
                raise HTTPException(429, "pin_locked")
            if not hmac.compare_digest(hash_pin(body.pin, b.pin_hash.split(":")[0]), b.pin_hash):
                b.failed_count += 1
                if b.failed_count >= 5:
                    b.locked_until, b.failed_count = time.time() + 900, 0
                db.commit()
                raise HTTPException(401, "pin_invalid")
            b.failed_count, b.locked_until = 0, 0
            grant(db, slug, request, response, body.label.strip() or "Browser")
            db.commit()
            return {"ok": True}

    @app.get("/api/s/{slug}/admins")
    def admins(slug: str, request: Request, response: Response):
        with lock, app.state.sessions() as db:
            a = authorize(db, slug, request)
            result = [{"id": x.id, "label": x.label, "last_seen_at": x.last_seen_at, "email": bool(x.account_id),
                       "current": x.id == a.id} for x in db.scalars(select(Admin).where(Admin.slug == slug, Admin.revoked == False))]
            db.commit()
            adopt_legacy(db, request, response)
            db.commit()
            return result

    @app.delete("/api/s/{slug}/admins/{admin_id}")
    def revoke(slug: str, admin_id: str, request: Request):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            target = db.get(Admin, admin_id)
            if not target or target.slug != slug:
                raise HTTPException(404, "not_found")
            target.revoked = True
            if target.account_id:
                # Removing the signed-in owner's access unlinks the board from that email.
                b = board(db, slug)
                if b.owner_id == target.account_id:
                    b.owner_id = None
            db.commit()
        return {"ok": True}

    @app.post("/api/s/{slug}/pin")
    def rotate_pin(slug: str, request: Request):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            b = board(db, slug)
            pin = f"{secrets.randbelow(1000000):06d}"
            b.pin_hash, b.failed_count, b.locked_until = hash_pin(pin), 0, 0
            db.commit()
            return {"pin": pin}

    def limited(db, key, limit, window, now):
        """Count one attempt; True if the limit for this window is exceeded."""
        row = db.get(RateLimit, key)
        if not row:
            row = RateLimit(key=key, count=0, reset_at=now + window)
            db.add(row)
        if row.reset_at <= now:
            row.count, row.reset_at = 0, now + window
        row.count += 1
        return row.count > limit

    def sign_in(db, email, response):
        """Start an account session for a confirmed address (sign-in link or
        forum code); creates the account on first use. Returns its id."""
        now = time.time()
        account = db.scalar(select(Account).where(Account.email == email))
        if not account:
            account = Account(id=str(uuid4()), email=email, language="de", created_at=now)
            db.add(account)
            db.flush()
        token = secrets.token_urlsafe(32)
        db.add(AccountSession(id=str(uuid4()), account_id=account.id, token_hash=digest(token), created_at=now, last_seen_at=now))
        response.set_cookie(ACCOUNT_COOKIE, token, httponly=True, secure=secure,
                            samesite="lax", max_age=SESSION_SECONDS, path="/")
        return account.id

    @app.get("/api/account")
    def account_info(request: Request):
        with lock, app.state.sessions() as db:
            account = current_account(db, request.cookies)
            db.commit()
            return {"mail_enabled": mail.enabled(), "email": account.email if account else None}

    @app.post("/api/account/login")
    async def request_login(body: LoginRequest, request: Request):
        """Send a sign-in link. The answer never reveals whether the address is known."""
        email = body.email.strip().lower()
        if not EMAIL.match(email):
            raise HTTPException(422, "email_invalid")
        if not mail.enabled():
            raise HTTPException(503, "mail_disabled")
        now = time.time()
        token = secrets.token_urlsafe(32)
        with lock, app.state.sessions() as db:
            ip = request.client.host if request.client else "unknown"
            blocked = limited(db, "login-ip:" + digest(ip), 20, 3600, now) | limited(db, "login-mail:" + digest(email), 5, 3600, now)
            if not blocked:
                db.add(LoginToken(token_hash=digest(token), email=email, created_at=now, expires_at=now + LOGIN_TOKEN_SECONDS))
            db.commit()
        if blocked:
            raise HTTPException(429, "login_rate_limited")
        origin = os.getenv("PUBLIC_ORIGIN", str(request.base_url).rstrip("/"))
        subject, text_body = login_mail(body.language, f"{origin}/login?lang={body.language}#t={token}")
        try:
            await asyncio.to_thread(app.state.send_mail, email, subject, text_body)
        except Exception:  # noqa: BLE001 - report a delivery problem without details
            raise HTTPException(502, "mail_failed")
        return {"ok": True}

    @app.post("/api/account/verify")
    def verify_login(body: LoginVerify, request: Request, response: Response):
        """Use a sign-in link once. Boards this browser controls become the account's."""
        with lock, app.state.sessions() as db:
            now = time.time()
            login = db.get(LoginToken, digest(body.token))
            if not login or login.used_at or login.expires_at < now:
                raise HTTPException(401, "login_invalid")
            login.used_at = now
            account = db.get(Account, sign_in(db, login.email, response))
            linked = 0
            for slug in device_slugs(db, request):
                try:
                    authorize(db, slug, request)
                except HTTPException:
                    continue
                b = board(db, slug)
                if not b.owner_id:
                    b.owner_id = account.id
                    linked += 1
            db.commit()
            return {"email": account.email, "linked": linked}

    @app.post("/api/account/logout")
    def logout(request: Request, response: Response):
        with lock, app.state.sessions() as db:
            token = request.cookies.get(ACCOUNT_COOKIE, "")
            session = db.scalar(select(AccountSession).where(AccountSession.token_hash == digest(token))) if token else None
            if session:
                db.delete(session)
            db.commit()
        response.delete_cookie(ACCOUNT_COOKIE, path="/")
        return {"ok": True}

    @app.get("/api/s/{slug}/owner")
    def get_owner(slug: str, request: Request):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            b = board(db, slug)
            account = current_account(db, request.cookies)
            owner = db.get(Account, b.owner_id) if b.owner_id else None
            db.commit()
            return {"email": (owner.email if account and owner.id == account.id else mask_email(owner.email)) if owner else None,
                    "mine": bool(owner and account and owner.id == account.id),
                    "signed_in": account.email if account else None}

    @app.put("/api/s/{slug}/owner")
    def set_owner(slug: str, body: Ownership, request: Request):
        """Link the board to the signed-in email, or remove the link."""
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            b = board(db, slug)
            if body.linked:
                account = current_account(db, request.cookies)
                if not account:
                    raise HTTPException(401, "login_required")
                if b.owner_id and b.owner_id != account.id:
                    raise HTTPException(409, "owner_exists")
                b.owner_id = account.id
            else:
                owner = db.get(Account, b.owner_id) if b.owner_id else None
                account = current_account(db, request.cookies)
                b.owner_id = None
                # Tell the owner when someone else removed their email.
                notify = owner if owner and (not account or account.id != owner.id) else None
            db.commit()
        if not body.linked and notify and mail.enabled():
            subject, text_body = notice_mail(b.language, "email.unlinked", b.name)
            try:
                app.state.send_mail(notify.email, subject, text_body)
            except Exception:  # noqa: BLE001 - the change itself already succeeded
                pass
        return {"ok": True}

    @app.get("/api/s/{slug}/state")
    def current_state(slug: str, request: Request):
        with lock, app.state.sessions() as db:
            return state(db, public_board(db, slug, request))

    @app.get("/api/s/{slug}/led")
    def led_preview_feed(slug: str, request: Request):
        """The compact LED feed for one game (the LED preview page); private games
        need the same access as the Viewer."""
        with lock, app.state.sessions() as db:
            b = public_board(db, slug, request)
            now_ms = round(time.time() * 1000)
            common = {"now_ms": now_ms, "name": b.name, "brightness": 100, "identify": False}
            if not b.active_match:
                return display_feed.payload(mode="idle", **common)
            return display_feed.payload(mode="game", s=state(db, b), msg=led_messages.feed_part(b.slug), lang=b.language, **common)

    @app.post("/api/s/{slug}/led/message")
    def send_led_message(slug: str, body: LedMessage, request: Request):
        """Greeting, cheer or small graphic on every LED panel showing this game,
        for a few seconds; then the score again."""
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            b = board(db, slug)
            if not b.active_match:
                raise HTTPException(409, "no_match")
            events = db.scalars(select(MatchEvent).where(
                MatchEvent.match_id == b.active_match, MatchEvent.cancelled.is_(False)).order_by(MatchEvent.id)).all()
            try:
                return led_messages.create(slug, state(db, b), events, kind=body.kind, text=body.text, icon=body.icon,
                                           effect=body.effect, color=body.color, seconds=body.seconds)
            except ValueError as error:
                raise HTTPException(422, f"invalid_{error}")

    @app.delete("/api/s/{slug}/led/message")
    def clear_led_message(slug: str, request: Request):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            led_messages.clear(slug)
            return {"ok": True}

    @app.get("/api/s/{slug}/control-state")
    @app.get("/api/s/{slug}/matches/{match_id}/control-state")
    def control_state(slug: str, request: Request, match_id: str | None = None):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            result = state(db, board(db, slug), match_id, private=True)
            db.commit()
            return result

    @app.get("/api/dashboard")
    def dashboard(request: Request, response: Response):
        with lock, app.state.sessions() as db:
            boards = []
            adopt_legacy(db, request, response)
            slugs = device_slugs(db, request)
            account = current_account(db, request.cookies)
            if account:
                slugs += [slug for slug in db.scalars(select(Board.slug).where(Board.owner_id == account.id)) if slug not in slugs]
            for slug in slugs:
                try:
                    authorize(db, slug, request)
                except HTTPException:
                    continue
                b = board(db, slug)
                games = []
                for m in db.scalars(select(Match).where(Match.slug == slug, Match.deleted_at.is_(None))
                                    .order_by(Match.created_at.desc())):
                    s = state(db, b, m.id)
                    games.append({**{k: s[k] for k in ("sport", "team_fouls_enabled", "match_id", "revision", "phase", "home", "away", "period_count",
                        "period_length_min", "created_at", "scheduled_at", "archived", "active", "trashed", "trash_reason", "trashed_at")},
                        "lineup_size": s.get("lineup_size"), "fixture": m.fixture,
                        **({"tennis": s["tennis"]} if s["sport"] == "tennis" else {})})
                boards.append({"slug": b.slug, "name": b.name, "active_match": b.active_match, "description": b.description, "stream_url": b.stream_url,
                               "created_at": round(b.created_at * 1000), "matches": games,
                               "owned": bool(account and b.owner_id == account.id)})
            device_id = device_of(db, request)
            if device_id and request.cookies.get(DEVICE_COOKIE):
                set_device_cookie(response, request.cookies[DEVICE_COOKIE])
            browsers = db.scalar(select(func.count()).select_from(DeviceToken).where(DeviceToken.device_id == device_id)) if device_id else 0
            db.commit()
            return {"boards": sorted(boards, key=lambda b: b["created_at"], reverse=True),
                    "account": {"email": account.email} if account else None,
                    "device": {"browsers": browsers}}

    @app.post("/api/device/link")
    def device_link(request: Request, response: Response):
        """A link that connects another browser to this one: both then show the
        same boards. Kept as a backup it brings the list back after the browser
        data was cleared. A new link replaces the previous one."""
        with lock, app.state.sessions() as db:
            adopt_legacy(db, request, response)
            device = db.get(Device, ensure_device(db, request, response))
            code = secrets.token_urlsafe(18)
            device.link_hash = digest(code)
            db.commit()
            return {"code": code}

    @app.post("/api/device/join")
    def device_join(body: DeviceJoin, request: Request, response: Response):
        with lock, app.state.sessions() as db:
            target = db.scalar(select(Device).where(Device.link_hash == digest(body.code.strip())))
            if not target:
                raise HTTPException(404, "link_invalid")
            adopt_legacy(db, request, response)
            own = device_of(db, request)
            if own and own != target.id:
                # Merge: this browser's boards and every browser already joined to it move over.
                for admin in db.scalars(select(Admin).where(Admin.device_id == own)):
                    admin.device_id = target.id
                for row in db.scalars(select(DeviceToken).where(DeviceToken.device_id == own)):
                    row.device_id = target.id
                db.flush()
                db.delete(db.get(Device, own))
            elif not own:
                token = secrets.token_urlsafe(32)
                db.add(DeviceToken(token_hash=digest(token), device_id=target.id, created_at=time.time(), last_seen_at=time.time()))
                set_device_cookie(response, token)
            request.state.device_id = target.id
            boards = len(device_slugs(db, request))
            db.commit()
            return {"boards": boards}

    @app.get("/api/live")
    def live_games():
        with lock, app.state.sessions() as db:
            games = []
            active = db.scalars(select(Board).join(Match, Board.active_match == Match.id).where(
                Board.private.is_(False), Match.deleted_at.is_(None), Match.archived_at.is_(None),
                Match.state["phase"].as_string().in_(("period_running", "break")))
                .order_by(Match.created_at.desc(), Board.slug))
            for b in active:
                s = state(db, b)
                games.append({k: s[k] for k in ("sport", "overtime_length_min", "team_fouls_enabled", "scoreboard", "match_id", "home", "away", "clock",
                    "phase", "period", "period_count", "period_length_min", "server_now", "location", "description", "stream_url")})
            # Planned games with a start time in the next days (public boards only).
            now = time.time()
            horizon = now + hours_env("LIVE_UPCOMING_HOURS", 72)
            upcoming = []
            planned = db.scalars(select(Match).join(Board, Board.slug == Match.slug).where(
                Board.private.is_(False), Match.deleted_at.is_(None), Match.archived_at.is_(None),
                Match.trashed_at.is_(None), Match.scheduled_at.is_not(None),
                Match.scheduled_at >= now - 3600, Match.scheduled_at <= horizon,
                Match.state["phase"].as_string() == "pre_game").order_by(Match.scheduled_at, Match.slug))
            for m in planned:
                b = db.get(Board, m.slug)
                location = b.location if b.location and b.location.get("visible") else None
                upcoming.append({
                    "scoreboard": b.slug, "match_id": m.id, "active": b.active_match == m.id,
                    "scheduled_at": round(m.scheduled_at * 1000), "sport": m.state["sport"],
                    "period_count": m.state["period_count"], "period_length_min": m.state["period_length_min"],
                    **({"tennis": m.state["tennis"]} if m.state["sport"] == "tennis" else {}),
                    "home": {**{k: m.state["home"][k] for k in ("name", "color")}, "logo": m.state["home"].get("logo")},
                    "away": {**{k: m.state["away"][k] for k in ("name", "color")}, "logo": m.state["away"].get("logo")},
                    "location": {k: location[k] for k in ("lat", "lng", "label")} if location else None,
                    "description": b.description, "stream_url": b.stream_url})
            # Just finished: public games that ended within LIVE_FINISHED_HOURS, so a
            # game does not vanish silently at the final whistle (or its automatic end).
            since = now - hours_env("LIVE_FINISHED_HOURS", 6)
            finished = []
            ended = db.scalars(select(Match).join(Board, Board.slug == Match.slug).where(
                Board.private.is_(False), Match.deleted_at.is_(None), Match.archived_at.is_(None),
                Match.trashed_at.is_(None), Match.created_at >= since - 3 * 86400,
                Match.state["phase"].as_string() == "finished"))
            for m in ended:
                end = next((e for e in db.scalars(select(MatchEvent).where(MatchEvent.match_id == m.id)
                                                  .order_by(MatchEvent.id.desc()).limit(20))
                            if not e.cancelled and (e.payload.get("type") == "game_end" or e.payload.get("match_won"))), None)
                if not end or end.payload["occurred_at"] / 1000 < since:
                    continue
                b = db.get(Board, m.slug)
                s = state(db, b, m.id)
                location = b.location if b.location and b.location.get("visible") else None
                finished.append({
                    "scoreboard": b.slug, "match_id": m.id, "active": b.active_match == m.id,
                    "sport": s["sport"], "period": s["period"], "period_count": s["period_count"],
                    "ended_at": end.payload["occurred_at"], "automatic": bool(end.payload.get("automatic")),
                    "home": {k: s["home"].get(k) for k in ("name", "color", "logo", "score", "counters")},
                    "away": {k: s["away"].get(k) for k in ("name", "color", "logo", "score", "counters")},
                    "location": {k: location[k] for k in ("lat", "lng", "label")} if location else None,
                    "description": b.description, "stream_url": b.stream_url})
            finished.sort(key=lambda g: g["ended_at"], reverse=True)
            return {"games": games, "upcoming": upcoming, "finished": finished[:30], "server_now": round(now * 1000)}

    @app.post("/api/s/{slug}/matches", status_code=201)
    def create_match(slug: str, body: CreateMatch, request: Request):
        logos = fixture_logos(body)
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            b = board(db, slug)
            key = f"{slug}:{body.command_id}"
            fingerprint = digest("create_match:" + json.dumps(body.model_dump(mode="json"), sort_keys=True))
            receipt = db.get(Receipt, key)
            if receipt:
                if receipt.fingerprint != fingerprint:
                    raise HTTPException(409, "command_reused")
                return {"ok": True}
            if body.scheduled_at is not None and body.scheduled_at <= time.time() * 1000:
                raise HTTPException(422, "schedule_future")
            if not body.home.strip() or not body.away.strip():
                raise HTTPException(422, "invalid_value")
            s = initial_state(body.period_count, body.period_length_min, body.sport, body.lineup_size, body.tennis_category, body.tennis_best_of, body.tennis_mode, body.tennis_final_tiebreak)
            name_teams(s, body)
            add_logos(db, slug, s, logos)
            m = Match(id=str(uuid4()), slug=slug, state=s, fixture=fixtures.stored(body.fixture),
                      scheduled_at=body.scheduled_at / 1000 if body.scheduled_at else None)
            db.add(m)
            db.add(Receipt(id=key, fingerprint=fingerprint))
            db.commit()
            return {"ok": True, "match_id": m.id}

    @app.get("/api/s/{slug}/matches/{match_id}/state")
    def archived_state(slug: str, match_id: str, request: Request):
        with lock, app.state.sessions() as db:
            return state(db, public_board(db, slug, request), match_id)

    @app.post("/api/s/{slug}/matches/{match_id}/commands")
    def command(slug: str, match_id: str, body: Command, request: Request):
        # One process by design. All checks and writes are one locked transaction.
        with lock, app.state.sessions() as db:
            admin = authorize(db, slug, request)
            b = board(db, slug)
            m = db.get(Match, match_id)
            if not m or m.slug != slug:
                raise HTTPException(404, "not_found")
            key = f"{slug}:{body.command_id}"
            fingerprint = digest(match_id + json.dumps(body.model_dump(mode="json"), sort_keys=True))
            receipt = db.get(Receipt, key)
            if receipt:
                if receipt.fingerprint != fingerprint:
                    raise HTTPException(409, "command_reused")
                return state(db, b, private=True)
            management = body.action in ("activate", "archive", "restore", "delete", "schedule", "trash")
            if m.deleted_at:
                raise HTTPException(410, "match_deleted")
            # A rematch may start from any finished game of the board (it becomes the active one).
            if (not management and body.action != "new_match" and b.active_match != m.id) or m.revision != body.expected_revision:
                raise HTTPException(409, "state_changed")
            if management:
                if body.action == "activate":
                    if body.data.get("expected_active_match", b.active_match) != b.active_match:
                        raise HTTPException(409, "state_changed")
                    current = db.get(Match, b.active_match) if b.active_match else None
                    if current and current.id != m.id and current.state["phase"] in ("period_running", "break"):
                        raise HTTPException(409, "finish_first")
                    if m.archived_at or m.trashed_at:
                        raise HTTPException(409, "restore_first")
                    b.active_match = m.id
                    m.touched_at = time.time()
                elif body.action in ("archive", "delete"):
                    if body.action == "archive" and m.state["phase"] in ("period_running", "break"):
                        raise HTTPException(409, "finish_first")
                    if body.action == "archive":
                        m.archived_at = time.time()
                    else:
                        m.deleted_at = time.time()
                    if b.active_match == m.id:
                        b.active_match = None
                elif body.action in ("restore", "trash"):
                    if body.action == "trash":
                        m.trashed_at, m.trash_reason = time.time(), "manual"
                        if b.active_match == m.id:
                            b.active_match = None
                    else:
                        m.archived_at = m.trashed_at = m.trash_reason = None
                        m.touched_at = time.time()
                elif body.action == "schedule":
                    value = body.data.get("scheduled_at")
                    if m.state["phase"] != "pre_game" or m.archived_at or m.trashed_at:
                        raise HTTPException(409, "invalid_transition")
                    if value is not None and (type(value) is not int or value <= time.time() * 1000):
                        raise HTTPException(422, "schedule_future")
                    m.scheduled_at = value / 1000 if value else None
                    m.touched_at = time.time()
            elif body.action == "new_match":
                if m.state["phase"] != "finished":
                    raise HTTPException(409, "finish_first")
                # A rematch never replaces a game that is running on this board.
                active = db.get(Match, b.active_match) if b.active_match and b.active_match != m.id else None
                if active and active.state["phase"] in ("period_running", "break"):
                    raise HTTPException(409, "game_running")
                new = Match(id=str(uuid4()), slug=slug,
                            state=initial_state(m.state["period_count"], m.state["period_length_min"], m.state["sport"], m.state.get("lineup_size")))
                if m.state["sport"] == "tennis":
                    from .tennis import initial
                    t = m.state["tennis"]
                    new.state["tennis"] = initial(t["category"], t["best_of"], t["mode"], t["final_tiebreak"])
                    new.state["period_count"] = t["best_of"]
                new.state["team_fouls_enabled"] = m.state.get("team_fouls_enabled", False)
                new.state["foul_mode"] = foul_mode(m.state)
                # Same teams: names, colours, logos and squads; no score, fouls or lineup.
                for team in ("home", "away"):
                    new.state[team].update({k: deepcopy(m.state[team][k]) for k in ("name", "short", "color", "logo", "squad")
                                            if k in m.state[team]})
                db.add(new)
                b.active_match = new.id
            elif body.action == "undo":
                last = db.scalar(select(MatchEvent).where(MatchEvent.match_id == m.id, MatchEvent.cancelled == False)
                                 .order_by(MatchEvent.id.desc()).limit(1))
                if not last or body.data.get("event_id") != last.id:
                    raise HTTPException(409, "undo_changed")
                if last.payload["type"] in ("assign_player", "assign_foul_player"):
                    target = db.get(MatchEvent, last.payload["target"])
                    target.payload = {**target.payload, "player": last.before.get("player")}
                    updated = deepcopy(m.state)
                    updated.update({k: v for k, v in last.before.items() if k != "player"})
                    m.state = updated
                else:
                    updated = deepcopy(m.state)
                    updated.update(last.before)
                    m.state = updated
                last.cancelled = True
            else:
                target = None
                correcting = body.action in CORRECTION_EVENTS
                if correcting or body.action in ("assign_player", "assign_foul_player"):
                    match_events = db.scalars(select(MatchEvent).where(MatchEvent.match_id == m.id).order_by(MatchEvent.id)).all()
                    available = available_events(match_events)
                    if correcting:
                        kind = body.action.removesuffix("_correction")
                        candidates = [e for e in available if e.payload["type"] == kind and e.payload.get("team") == body.data.get("team")]
                        target_id = body.data.get("event_id")
                        target = next((e for e in candidates if e.id == target_id), None) if target_id is not None else (candidates[-1] if candidates else None)
                        if not target:
                            raise HTTPException(422, "event_unavailable" if target_id is not None else {"score": "score_zero", "red_card": "red_cards_zero", "yellow_card": "yellow_cards_zero"}.get(kind, "event_unavailable"))
                    else:
                        target = next((e for e in available if e.id == body.data.get("event_id") and e.payload.get("team") == body.data.get("team")
                                       and (e.payload["type"] == "personal_foul" if body.action == "assign_foul_player" else e.payload["type"] in ("score", "red_card", "yellow_card") + FOOTBALL_EVENTS)), None)
                        if not target:
                            raise HTTPException(422, "event_unavailable")
                if body.action == "overtime_start":
                    current = state(db, b)
                    if current["home"]["score"] != current["away"]["score"]:
                        raise HTTPException(422, "invalid_transition")
                data = dict(body.data)
                if correcting and body.action == "score_correction":
                    if "points" in data and (isinstance(data["points"], bool) or data["points"] != -target.payload["points"]):
                        raise HTTPException(422, "invalid_score")
                    data["points"] = -target.payload["points"]
                try:
                    updated, payload, before = apply(m.state, body.action, data, round(time.time() * 1000))
                except RuleError as exc:
                    raise HTTPException(422, str(exc)) from exc
                if correcting:
                    payload.update(corrects=target.id, player=target.payload.get("player"))
                elif body.action in ("assign_player", "assign_foul_player"):
                    before["player"] = target.payload.get("player")
                    target.payload = {**target.payload, "player": payload["player"]}
                m.state = updated
                payload["command_id"] = str(body.command_id)
                db.add(MatchEvent(match_id=m.id, admin_id=admin.id, payload=payload, before=before))
                # Ending the last basketball period ends the match unless tied
                # (then overtime is offered). Undo reverts the game end first.
                if body.action == "period_end" and m.state["sport"] == "basketball" and m.state["period"] >= m.state["period_count"]:
                    db.flush()
                    current = state(db, b, m.id)
                    if current["home"]["score"] != current["away"]["score"]:
                        finished, final, before_end = apply(m.state, "game_end", {}, round(time.time() * 1000))
                        m.state = finished
                        final["command_id"] = str(body.command_id)
                        final["automatic"] = True
                        db.add(MatchEvent(match_id=m.id, admin_id=admin.id, payload=final, before=before_end))
            m.revision += 1
            db.add(Receipt(id=key, fingerprint=fingerprint))
            db.commit()
            return state(db, b, private=True)

    @app.websocket("/ws/s/{slug}")
    async def live(ws: WebSocket, slug: str):
        key = ws.query_params.get("k")
        with app.state.sessions() as db:
            b = db.get(Board, slug)
            if not b or not viewer_allowed(db, b, ws.cookies, key):
                await ws.close(code=1008)
                return
        await ws.accept()
        signature = None
        try:
            while True:
                with lock, app.state.sessions() as db:
                    b = board(db, slug)
                    allowed = viewer_allowed(db, b, ws.cookies, key)
                    m = db.get(Match, b.active_match) if b.active_match else None
                    current = (m.id, m.revision) if m else (None, 0)
                    if current != signature:
                        s = state(db, b)
                if not allowed:
                    await ws.close(code=1008)  # Made private while watching.
                    return
                if current != signature:
                    await ws.send_json(s)
                    signature = current
                try:
                    message = await asyncio.wait_for(ws.receive_text(), timeout=0.25)
                    if message == "ping":
                        with lock, app.state.sessions() as db:
                            s = state(db, board(db, slug))
                        await ws.send_json(s)
                except asyncio.TimeoutError:
                    pass
        except (WebSocketDisconnect, RuntimeError):
            pass

    # --- Anzeigetafeln (Score67 LED panels) --------------------------------
    # A panel registers itself with a device key and shows a code; the browser
    # that enters the code gets a management cookie for it. The panel follows
    # the assigned board's current game with its own bearer token.

    def display_cookie(display_id):
        return f"score67d_{display_id}"

    def managed_display(db, display_id, cookies):
        token = cookies.get(display_cookie(display_id), "")
        d = db.get(Display, display_id)
        if not d or not token or not db.scalar(select(DisplayAdmin).where(
                DisplayAdmin.display_id == display_id, DisplayAdmin.token_hash == digest(token))):
            raise HTTPException(404, "not_found")
        return d

    def pairing_code(db):
        while True:
            code = "".join(secrets.choice(DISPLAY_CODE_ALPHABET) for _ in range(6))
            if not db.scalar(select(Display).where(Display.pairing_code == code)):
                return code

    def display_info(db, d):
        now = time.time()
        b = db.get(Board, d.board_slug) if d.board_slug else None
        m = db.get(Match, b.active_match) if b and b.active_match else None
        pending = bool(d.pairing_code and (d.pairing_expires_at or 0) > now and d.device_key_hash is None)
        return {"id": d.id, "name": d.name, "paired": d.token_hash is not None,
                "online": bool(d.last_seen_at and d.last_seen_at > now - 30),
                "last_seen_at": round(d.last_seen_at * 1000) if d.last_seen_at else None,
                "code": d.pairing_code if pending else None,
                "code_expires_at": round(d.pairing_expires_at * 1000) if pending else None,
                "board": b.slug if b else None, "board_description": b.description if b else None,
                "match_id": m.id if m else None,
                "match_label": f'{m.state["home"]["name"]} – {m.state["away"]["name"]}' if m else None,
                "device": d.device_key_hash is not None, "brightness": d.brightness or 60,
                "fw_version": d.fw_version, "rssi": d.rssi, "beta": d.fw_channel == "test", "follow": bool(d.follow),
                "ota_status": d.ota_status, "update": (firmware.offer(db, d) or {}).get("version")}

    def device_display(db, token):
        d = db.scalar(select(Display).where(Display.token_hash == digest(token or "")))
        if not token or not d:
            raise HTTPException(401, "display_unpaired")
        return d

    def device_payload(db, d):
        b = db.get(Board, d.board_slug) if d.board_slug else None
        return {"display": {"id": d.id, "name": d.name}, "board": b.slug if b else None,
                "state": state(db, b) if b else None, "server_now": round(time.time() * 1000)}

    def claimed(db, d):
        return db.scalar(select(DisplayAdmin.id).where(DisplayAdmin.display_id == d.id).limit(1)) is not None

    def claim_code(db, d, now):
        """The code a self-registered panel shows: to claim it while nobody owns it,
        afterwards to connect a game from that game's Sharing tab. Renewed once it
        expires and after every use."""
        if not d.pairing_code or (d.pairing_expires_at or 0) <= now:
            d.pairing_code, d.pairing_expires_at = pairing_code(db), now + CLAIM_CODE_SECONDS
        return d.pairing_code

    def compact_payload(db, d):
        """The small feed for LED firmware (display_feed): pairing code, idle or the game."""
        now = time.time()
        common = {"now_ms": round(now * 1000), "name": d.name, "brightness": d.brightness or 60,
                  "identify": bool(d.identify_until and d.identify_until > now)}
        common["firmware"] = firmware.offer(db, d)
        if d.device_key_hash and not claimed(db, d):
            return display_feed.payload(mode="pairing", code=claim_code(db, d, now), **common)
        b = db.get(Board, d.board_slug) if d.board_slug else None
        if d.device_key_hash:
            common["code"] = claim_code(db, d, now)
        if not b:
            return display_feed.payload(mode="idle", **common)
        return display_feed.payload(mode="game", s=state(db, b), msg=led_messages.feed_part(b.slug), lang=b.language, **common)

    def device_status(db, d, message):
        """Status a device reports over its socket: {"fw": "0.1.0", "rssi": -61, "uptime": 3600}."""
        try:
            data = json.loads(message)
        except ValueError:
            return
        if not isinstance(data, dict):
            return
        if isinstance(data.get("fw"), str):
            d.fw_version = data["fw"][:20]
        if isinstance(data.get("rssi"), int) and -127 <= data["rssi"] <= 0:
            d.rssi = data["rssi"]
        if isinstance(data.get("ota"), str):
            d.ota_status = data["ota"][:60]   # e.g. "downloading 0.2.0", "failed: sha256"
        d.last_seen_at = time.time()

    @app.post("/api/display/register")
    def register_display(body: DisplayRegister, request: Request):
        """Firmware's first contact (and after losing its token): the same device
        key gets a fresh token and keeps owner and scoreboard; a new key is a new,
        unclaimed display that shows a code on its panel."""
        with lock, app.state.sessions() as db:
            now = time.time()
            if limited(db, "register:" + digest(request.client.host if request.client else "unknown"), 30, 3600, now):
                db.commit()
                raise HTTPException(429, "rate_limited")
            d = db.scalar(select(Display).where(Display.device_key_hash == digest(body.device_key)))
            if not d:
                display_id = "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(12))
                d = Display(id=display_id, name=(body.name or "Anzeigetafel").strip(), created_at=now,
                            device_key_hash=digest(body.device_key), paired_at=now)
                db.add(d)
                db.flush()
            token = secrets.token_urlsafe(32)
            d.token_hash, d.last_seen_at = digest(token), now
            if body.fw:
                d.fw_version = body.fw[:20]
            code = None if claimed(db, d) else claim_code(db, d, now)
            if code is None:
                d.pairing_code = d.pairing_expires_at = None
            db.commit()
            return {"display_id": d.id, "name": d.name, "token": token, "code": code}

    @app.post("/api/displays/claim")
    def claim_display(body: DisplayClaim, request: Request, response: Response):
        """The app takes over a self-registered display by the code on its panel."""
        with lock, app.state.sessions() as db:
            now = time.time()
            if limited(db, "claim:" + digest(request.client.host if request.client else "unknown"), 30, 3600, now):
                db.commit()
                raise HTTPException(429, "rate_limited")
            code = body.code.strip().upper().replace("-", "").replace(" ", "")
            d = db.scalar(select(Display).where(Display.pairing_code == code, Display.device_key_hash.is_not(None)))
            if not d or (d.pairing_expires_at or 0) <= now:
                db.commit()
                raise HTTPException(404, "pairing_code_invalid")
            # The code on the panel is the key: whoever reads it (idle, or DOWN
            # pressed during a game) becomes an owner too, so a panel in a shared
            # hall never waits for someone who went home. The code is renewed.
            if body.name:
                d.name = body.name.strip()
            if d.id not in managed_ids(db, request.cookies):
                token = secrets.token_urlsafe(32)
                db.add(DisplayAdmin(id=str(uuid4()), display_id=d.id, token_hash=digest(token), created_at=now))
                response.set_cookie(display_cookie(d.id), token, httponly=True, secure=secure,
                                    samesite="lax", max_age=365 * 86400, path="/")
            d.pairing_code, d.pairing_expires_at = pairing_code(db), now + CLAIM_CODE_SECONDS
            db.commit()
            return display_info(db, d)

    firmware.register(app, lock=lock, device_display=device_display)

    # --- LED panels per game (LED tab) -------------------------------------
    # Whoever controls a game and can read the code on a panel connects that
    # panel to the game; the browser then also manages the panel. The code is
    # renewed after each use, so a code seen once does not work later.

    def managed_ids(db, cookies):
        ids = set()
        for cookie in cookies:
            if cookie.startswith("score67d_"):
                try:
                    ids.add(managed_display(db, cookie[9:], cookies).id)
                except HTTPException:
                    continue
        return ids

    def board_displays(db, slug, cookies):
        mine = managed_ids(db, cookies)
        result = []
        for d in db.scalars(select(Display).where(
                (Display.board_slug == slug) | Display.id.in_(mine or {""}))).all():
            info = display_info(db, d)
            result.append({key: info[key] for key in ("id", "name", "online", "board", "fw_version", "follow", "match_id", "match_label")}
                          | {"managed": d.id in mine})
        return {"displays": sorted(result, key=lambda d: d["name"].lower())}

    @app.get("/api/s/{slug}/displays")
    def list_board_displays(slug: str, request: Request):
        """Panels showing this game, and the panels this browser manages."""
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            return board_displays(db, slug, request.cookies)

    @app.post("/api/s/{slug}/displays")
    def connect_board_display(slug: str, body: DisplayConnect, request: Request, response: Response):
        """Show this game on the LED panel whose code was typed in."""
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            now = time.time()
            if limited(db, "claim:" + digest(request.client.host if request.client else "unknown"), 30, 3600, now):
                db.commit()
                raise HTTPException(429, "rate_limited")
            code = body.code.strip().upper().replace("-", "").replace(" ", "")
            d = db.scalar(select(Display).where(Display.pairing_code == code, Display.device_key_hash.is_not(None)))
            if not d or (d.pairing_expires_at or 0) <= now:
                db.commit()
                raise HTTPException(404, "pairing_code_invalid")
            if d.id not in managed_ids(db, request.cookies):
                token = secrets.token_urlsafe(32)
                db.add(DisplayAdmin(id=str(uuid4()), display_id=d.id, token_hash=digest(token), created_at=now))
                response.set_cookie(display_cookie(d.id), token, httponly=True, secure=secure,
                                    samesite="lax", max_age=365 * 86400, path="/")
            d.board_slug = slug
            d.pairing_code, d.pairing_expires_at = pairing_code(db), now + CLAIM_CODE_SECONDS
            db.commit()
            return display_info(db, d)

    @app.post("/api/s/{slug}/displays/follow")
    def follow_board_displays(slug: str, request: Request):
        """The control center was opened: the owner's panels that follow switch to this game."""
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            b = board(db, slug)
            m = db.get(Match, b.active_match) if b.active_match else None
            # Looking at an old game must not pull the panel away from a live one.
            if m and m.state.get("phase") != "finished":
                for display_id in managed_ids(db, request.cookies):
                    d = db.get(Display, display_id)
                    if d and d.follow and d.board_slug != slug:
                        d.board_slug = slug
            db.commit()
            return board_displays(db, slug, request.cookies)

    @app.put("/api/s/{slug}/displays/{display_id}")
    def show_on_board_display(slug: str, display_id: str, request: Request):
        """A panel this browser manages switches to this game."""
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            d = managed_display(db, display_id, request.cookies)
            d.board_slug = slug
            db.commit()
            return display_info(db, d)

    @app.delete("/api/s/{slug}/displays/{display_id}")
    def disconnect_board_display(slug: str, display_id: str, request: Request):
        """The panel stops showing this game (it stays registered and shows its code)."""
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            d = db.get(Display, display_id)
            if not d or d.board_slug != slug:
                raise HTTPException(404, "not_found")
            d.board_slug = None
            d.follow = False
            db.commit()
            return {"ok": True}

    @app.post("/api/displays/{display_id}/disconnect")
    def confirmed_display_disconnect(display_id: str, body: DisplayDisconnect, request: Request):
        with lock, app.state.sessions() as db:
            # Panel managers and controllers of the displayed game may disconnect.
            if display_id not in managed_ids(db, request.cookies):
                authorize(db, body.expected_board, request)
            d = db.get(Display, display_id)
            b = db.get(Board, d.board_slug) if d and d.board_slug else None
            if not d or d.board_slug != body.expected_board or not b or b.active_match != body.expected_match:
                raise HTTPException(409, "display_connection_changed")
            d.board_slug = None
            d.follow = False  # A reload must not silently reconnect the panel.
            db.commit()
            return {"ok": True}

    @app.post("/api/displays/{display_id}/identify")
    def identify_display(display_id: str, request: Request):
        """The panel flashes for a few seconds, to tell several displays apart."""
        with lock, app.state.sessions() as db:
            d = managed_display(db, display_id, request.cookies)
            d.identify_until = time.time() + IDENTIFY_SECONDS
            db.commit()
            return display_info(db, d)

    def bearer(request):
        header = request.headers.get("authorization", "")
        return header[7:].strip() if header.lower().startswith("bearer ") else ""

    @app.get("/api/displays")
    def list_displays(request: Request):
        with lock, app.state.sessions() as db:
            result = []
            for cookie in request.cookies:
                if cookie.startswith("score67d_"):
                    try:
                        result.append(display_info(db, managed_display(db, cookie[9:], request.cookies)))
                    except HTTPException:
                        continue
            return {"displays": sorted(result, key=lambda d: d["name"].lower())}

    @app.put("/api/displays/{display_id}")
    def update_display(display_id: str, body: DisplayUpdate, request: Request):
        with lock, app.state.sessions() as db:
            d = managed_display(db, display_id, request.cookies)
            if body.name is not None:
                d.name = body.name.strip()
            if body.brightness is not None:
                d.brightness = body.brightness
            if body.beta is not None:
                d.fw_channel = "test" if body.beta else None
            if body.follow is not None:
                d.follow = body.follow
            if "board" in body.model_fields_set:
                if body.board is not None:
                    authorize(db, body.board, request)  # Only boards this browser controls.
                d.board_slug = body.board
            db.commit()
            return display_info(db, d)

    @app.delete("/api/displays/{display_id}")
    def delete_display(display_id: str, request: Request, response: Response):
        with lock, app.state.sessions() as db:
            d = managed_display(db, display_id, request.cookies)
            for admin in db.scalars(select(DisplayAdmin).where(DisplayAdmin.display_id == d.id)).all():
                db.delete(admin)
            db.flush()  # Admin rows first; the database cascade would otherwise race the ORM.
            db.delete(d)
            db.commit()
            response.delete_cookie(display_cookie(display_id), path="/")
            return {"ok": True}

    @app.get("/api/display/state")
    def display_state(request: Request):
        with lock, app.state.sessions() as db:
            d = device_display(db, bearer(request))
            d.last_seen_at = time.time()
            compact = request.query_params.get("format") == "compact"
            payload = compact_payload(db, d) if compact else device_payload(db, d)
            db.commit()
            return payload

    @app.websocket("/ws/display")
    async def display_live(ws: WebSocket):
        token = ws.query_params.get("token", "")
        compact = ws.query_params.get("format") == "compact"
        with lock, app.state.sessions() as db:
            try:
                device_display(db, token)
            except HTTPException:
                await ws.close(code=1008)
                return
        await ws.accept()
        signature, seen = None, 0.0
        try:
            while True:
                with lock, app.state.sessions() as db:
                    d = db.scalar(select(Display).where(Display.token_hash == digest(token)))
                    if not d:
                        await ws.close(code=1008)  # Removed or re-paired.
                        return
                    b = db.get(Board, d.board_slug) if d.board_slug else None
                    m = db.get(Match, b.active_match) if b and b.active_match else None
                    current = (d.board_slug, d.name, m.id if m else None, m.revision if m else 0,
                               d.brightness, bool(d.identify_until and d.identify_until > time.time()),
                               d.pairing_code, (d.pairing_expires_at or 0) <= time.time(),  # expired → renewed code
                               claimed(db, d) if compact else None,
                               led_messages.signature(d.board_slug) if compact and d.board_slug else None,
                               (firmware.offer(db, d) or {}).get("version") if compact else None)
                    if current != signature:
                        payload = compact_payload(db, d) if compact else device_payload(db, d)
                        db.commit()  # a renewed claim code is stored
                    else:
                        payload = None
                    if time.time() - seen > 10:
                        d.last_seen_at = seen = time.time()
                        db.commit()
                if payload is not None:
                    await ws.send_json(payload)
                    signature = current
                try:
                    message = await asyncio.wait_for(ws.receive_text(), timeout=0.25)
                    with lock, app.state.sessions() as db:
                        d = db.scalar(select(Display).where(Display.token_hash == digest(token)))
                        if d:
                            device_status(db, d, message)
                            db.commit()
                except asyncio.TimeoutError:
                    pass
        except (WebSocketDisconnect, RuntimeError):
            pass

    def page(request, name, context=None, *, language=None, index=True, title=None):
        """A server-rendered page with all texts filled in for crawlers (seo.fill).
        Site pages take their title/description from seo.<page>.* unless given."""
        language = language or seo.language(request)
        words = seo.words(language)
        context = {"request": request, "lang": language, "index": index, **(context or {})}
        key = context.get("page")
        if key and not context.get("og") and words.get(f"seo.{key}.title"):
            context["og"] = {"title": words[f"seo.{key}.title"], "description": words.get(f"seo.{key}.description"),
                             "language": language}
        title = title or (context.get("og") or {}).get("title")
        response = HTMLResponse(seo.fill(templates.get_template(name).render(context), language, title))
        if not index:
            response.headers["X-Robots-Tag"] = "noindex"
        return response

    @app.get("/", response_class=HTMLResponse)
    def landing(request: Request):
        return page(request, "landing.html", {"page": "landing"})

    @app.get("/live", response_class=HTMLResponse)
    def live_page(request: Request):
        return page(request, "live.html", {"page": "live"})

    forum.register(app, lock=lock, current_account=current_account, limited=limited, sign_in=sign_in)

    @app.get("/impressum", response_class=HTMLResponse)
    @app.get("/datenschutz", response_class=HTMLResponse)
    def legal_page(request: Request):
        # Operator details live in shared/legal.json (one place for both pages).
        legal = json.loads((ROOT / "shared/legal.json").read_text())
        name = request.url.path.strip("/")
        return page(request, f"{name}.html", {"page": name, "legal": legal}, index=name == "datenschutz")

    @app.get("/about", response_class=HTMLResponse)
    @app.get("/features", response_class=HTMLResponse)
    def info_page(request: Request):
        name = request.url.path.strip("/")
        return page(request, f"{name}.html", {"page": name})

    @app.get("/forum", response_class=HTMLResponse)
    @app.get("/forum/{thread_id:int}", response_class=HTMLResponse)
    def forum_page(request: Request, thread_id: int | None = None):
        # Topics and posts are rendered on the server too, so they can be found.
        with lock, app.state.sessions() as db:
            topic = forum.thread_page(db, thread_id) if thread_id else None
            topics = None if thread_id else forum.thread_list(db)
        context = {"page": "forum", "thread_id": thread_id, "topic": topic, "topics": topics}
        if topic:
            context["og"] = {"title": f"{topic['thread']['title']} · Forum · Score67",
                             "description": topic["thread"]["body"][:200], "language": seo.language(request)}
        return page(request, "forum.html", context, index=thread_id is None or topic is not None)

    @app.get("/forum/moderate/{post_id:int}", response_class=HTMLResponse)
    def forum_moderation_page(request: Request, post_id: int):
        return page(request, "forum-moderate.html", {"page": "moderate", "post_id": post_id}, index=False)

    @app.get("/location-picker", response_class=HTMLResponse)
    def location_picker(request: Request):
        return page(request, "location-picker.html", index=False)

    def guide_route(path, key):
        def guide(request: Request):
            language = seo.language(request)
            return page(request, f"guides/{key}.{language}.html", {"page": f"guide.{key}"}, language=language)
        app.add_api_route(path, guide, methods=["GET"], response_class=HTMLResponse, name=f"guide_{key}")

    for path, key in guides.GUIDES.items():
        guide_route(path, key)

    @app.get("/robots.txt")
    def robots_txt(request: Request):
        return Response(seo.robots(origin(request)), media_type="text/plain")

    @app.get("/sitemap.xml")
    def sitemap_xml(request: Request):
        with lock, app.state.sessions() as db:
            threads = [(t["id"], datetime.fromtimestamp(t["last_at"] / 1000, timezone.utc).strftime("%Y-%m-%d"))
                       for t in forum.thread_list(db)]
        pages = ["/", "/features", "/about", *guides.GUIDES, "/live", "/forum", "/datenschutz"]
        return Response(seo.sitemap(origin(request), pages, threads), media_type="application/xml")

    @app.get("/s/{slug}/led", response_class=HTMLResponse)
    def led_page(request: Request, slug: str):
        with app.state.sessions() as db:
            b = board(db, slug)
            language = seo.language(request, b.language if b.language in seo.LANGUAGES else "de")
        return page(request, "led.html", {"slug": slug, "page": "led"}, language=language, index=False)

    @app.get("/s/{slug}", response_class=HTMLResponse)
    @app.get("/s/{slug}/overlay", response_class=HTMLResponse)
    def display(request: Request, slug: str):
        overlay = request.url.path.endswith("/overlay")
        og = None
        with app.state.sessions() as db:
            b = board(db, slug)
            hidden = not viewer_allowed(db, b, request.cookies, request.query_params.get("k"))
            controller = False
            if not overlay:
                og = link_preview(db, b, request, hidden)
                # This browser already controls the board: offer "Controller", not "take over".
                try:
                    authorize(db, slug, request)
                    controller = True
                except HTTPException:
                    pass
            language = seo.language(request, b.language if b.language in seo.LANGUAGES else "de")
        # Single games are short-lived and thin: shared, but not indexed.
        return page(request, "display.html", {"slug": slug, "overlay": overlay, "private": hidden, "og": og,
                                              "controller": controller}, language=language, index=False)

    def origin(request):
        return os.getenv("PUBLIC_ORIGIN", str(request.base_url).rstrip("/"))

    def preview_state(db, b, request):
        """The game a shared link shows: ?match=<id> (an upcoming game) or the active one."""
        match = request.query_params.get("match")
        if match:
            try:
                return state(db, b, match)
            except HTTPException:
                pass
        return state(db, b)

    def link_preview(db, b, request, hidden):
        """Open Graph texts and image for a shared ticker link (WhatsApp, Facebook)."""
        language = request.query_params.get("lang") if request.query_params.get("lang") in ("de", "en") else b.language
        url = f"{origin(request)}{request.url.path}" + (f"?{request.url.query}" if request.url.query else "")
        if hidden:
            w = preview.words(language)
            return {"title": f"{w['private']} · Score67", "description": w["private_text"], "url": url,
                    "image": f"{origin(request)}/preview.png?lang={language}", "language": language}
        s = preview_state(db, b, request)
        title, description = preview.summary(s, language)
        query = f"lang={language}&r={s['revision']}" + (f"&match={s['match_id']}" if s.get("match_id") else "")
        return {"title": title, "description": description, "url": url, "language": language,
                "image": f"{origin(request)}/s/{b.slug}/preview.png?{query}"}

    @app.get("/s/{slug}/preview.png")
    def scoreboard_preview(request: Request, slug: str):
        language = request.query_params.get("lang") if request.query_params.get("lang") in ("de", "en") else None
        with app.state.sessions() as db:
            b = board(db, slug)
            language = language or b.language
            if not viewer_allowed(db, b, request.cookies, request.query_params.get("k")):
                data = preview.render(None, language)
            else:
                s = preview_state(db, b, request)
                def logo(path):
                    asset = db.get(Asset, path.removeprefix("/media/").removesuffix(".png"))
                    return asset.data if asset and asset.slug == b.slug else None
                data = preview.render(s, language, logo)
        # Short cache: the URL carries the revision, so a new score is a new image.
        return Response(data, media_type="image/png", headers={"Cache-Control": "public, max-age=300"})

    @app.get("/preview.png")
    def site_preview(request: Request):
        language = request.query_params.get("lang") if request.query_params.get("lang") in ("de", "en") else "de"
        return Response(preview.render(None, language), media_type="image/png",
                        headers={"Cache-Control": "public, max-age=86400"})

    @app.get("/new")
    @app.get("/login")
    @app.get("/dashboard")
    @app.get("/settings")
    @app.get("/s/{slug}/control")
    def control(slug: str | None = None):
        if not (build / "index.html").exists():
            raise HTTPException(503, "control_build_missing")
        # The Flutter app (create, My scoreboards, Controller) is not for search results.
        return FileResponse(build / "index.html", headers={"X-Robots-Tag": "noindex"})

    return app


app = create_app()
