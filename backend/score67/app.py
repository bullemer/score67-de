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

from .db import Admin, Asset, Board, Display, DisplayAdmin, Match, MatchEvent, RateLimit, Receipt, database
from .domain import FOOTBALL, BASKETBALL, RuleError, apply, period_ms, initial_state, normalize_clock, foul_mode, BASKETBALL_STATS, player_statistics, SHORT_MAX, FOOTBALL_EVENTS

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


DISPLAY_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I
PAIRING_SECONDS = 600


class DisplayCreate(StrictModel):
    name: str = Field(default="Anzeigetafel", min_length=1, max_length=60)


class DisplayUpdate(StrictModel):
    name: str | None = Field(default=None, min_length=1, max_length=60)
    board: str | None = Field(default=None, max_length=10)


class DisplayPair(StrictModel):
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
    import io
    from PIL import Image
    match = re.fullmatch(r"data:image/(png|jpeg|webp);base64,([A-Za-z0-9+/=]+)", data_url or "")
    if not match:
        raise HTTPException(422, "logo_invalid")
    try:
        raw = base64.b64decode(match[2], validate=True)
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
    sport: Literal["football", "basketball"] = "football"
    language: Literal["de", "en"] = "de"
    description: str | None = Field(default=None, max_length=300)
    stream_url: str | None = Field(default=None, max_length=300)
    scheduled_at: int | None = Field(default=None, ge=0)
    period_count: int | None = Field(default=None, ge=1, le=12)
    period_length_min: int | None = Field(default=None, ge=1, le=120)
    location: Location | None = None


class CreateMatch(StrictModel):
    sport: Literal["football", "basketball"] = "football"
    command_id: UUID
    home: str = Field(default="Home", min_length=1, max_length=60)
    away: str = Field(default="Guest", min_length=1, max_length=60)
    scheduled_at: int | None = Field(default=None, ge=0)
    period_count: int | None = Field(default=None, ge=1, le=12)
    period_length_min: int | None = Field(default=None, ge=1, le=120)


class Claim(StrictModel):
    pin: str = Field(pattern=r"^\d{6}$")
    label: str = Field(default="Browser", min_length=1, max_length=60)


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

    Finished games are never touched. Returns (trashed, purged)."""
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
        if m.state.get("phase") in ("pre_game", "finished"):
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
    templates = Jinja2Templates(directory=ROOT / "backend/score67/templates")
    templates.env.globals["release_label"] = RELEASE["label"]
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
            limit = LOGO_MAX_REQUEST if LOGO_PATH.match(request.url.path) else 16384
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
        if request.url.path.startswith("/api/") or request.url.path.endswith("/control") or request.url.path in ("/new", "/dashboard"):
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

    def authorize(db, slug, request):
        token = request.cookies.get(f"score67_{slug}", "")
        admin = db.scalar(select(Admin).where(Admin.slug == slug, Admin.token_hash == digest(token)))
        if not admin or admin.revoked or admin.last_seen_at < time.time() - 180 * 86400:
            raise HTTPException(401, "admin_required")
        admin.last_seen_at = time.time()
        return admin

    def viewer_allowed(db, b, cookies, key):
        """Public boards are open; private ones only to controllers and OBS (overlay key)."""
        if not b.private or (key and b.overlay_key and hmac.compare_digest(key, b.overlay_key)):
            return True
        token = cookies.get(f"score67_{b.slug}", "")
        admin = db.scalar(select(Admin).where(Admin.slug == b.slug, Admin.token_hash == digest(token)))
        return bool(admin and not admin.revoked)

    def public_board(db, slug, request):
        b = board(db, slug)
        if not viewer_allowed(db, b, request.cookies, request.query_params.get("k")):
            raise HTTPException(403, "private")
        return b

    def grant(db, slug, response, label):
        token = secrets.token_urlsafe(32)
        db.add(Admin(id=str(uuid4()), slug=slug, token_hash=digest(token), label=label, last_seen_at=time.time()))
        response.set_cookie(f"score67_{slug}", token, httponly=True, secure=secure,
                            samesite="lax", max_age=180 * 86400, path="/")

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
        available_ids = {e.id for e in available}
        s["events"] = [{**e.payload, "id": e.id, "cancelled": e.cancelled,
            "corrected": e.payload["type"] in COUNTED_EVENTS and not e.cancelled and e.id not in available_ids} for e in events]
        if private:
            s.update(description=b.description, board_created_at=round(b.created_at * 1000),
                     private=bool(b.private), overlay_key=b.overlay_key)
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
        return [FOOTBALL, BASKETBALL]

    @app.get("/api/templates")
    def available_templates():
        return [{"id": "standard", "kind": "stream", "views": ["scoreboard", "score_big", "hidden"]},
                {"id": "board", "kind": "screen", "views": ["score_big"]}]

    @app.post("/api/scoreboards", status_code=201)
    def create(body: CreateBoard, request: Request, response: Response):
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
            db.add(b)
            db.flush()
            db.add(Match(id=match_id, slug=slug, state=initial_state(body.period_count, body.period_length_min, body.sport),
                         created_at=now, scheduled_at=body.scheduled_at / 1000 if body.scheduled_at else None))
            grant(db, slug, response, "Browser")
            db.commit()
            return {"slug": slug, "pin": pin, "links": {"public": f"/s/{slug}",
                    "overlay": f"/s/{slug}/overlay", "control": f"/s/{slug}/control"}}

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
            url = None
            if png is not None:
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
                url = f"/media/{asset.id}.png"
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
    def claim(slug: str, body: Claim, response: Response):
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
            grant(db, slug, response, body.label.strip() or "Browser")
            db.commit()
            return {"ok": True}

    @app.get("/api/s/{slug}/admins")
    def admins(slug: str, request: Request, response: Response):
        with lock, app.state.sessions() as db:
            a = authorize(db, slug, request)
            result = [{"id": x.id, "label": x.label, "last_seen_at": x.last_seen_at,
                       "current": x.id == a.id} for x in db.scalars(select(Admin).where(Admin.slug == slug, Admin.revoked == False))]
            db.commit()
            response.set_cookie(f"score67_{slug}", request.cookies[f"score67_{slug}"], httponly=True,
                                secure=secure, samesite="lax", max_age=180 * 86400, path="/")
            return result

    @app.delete("/api/s/{slug}/admins/{admin_id}")
    def revoke(slug: str, admin_id: str, request: Request):
        with lock, app.state.sessions() as db:
            authorize(db, slug, request)
            target = db.get(Admin, admin_id)
            if not target or target.slug != slug:
                raise HTTPException(404, "not_found")
            target.revoked = True
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

    @app.get("/api/s/{slug}/state")
    def current_state(slug: str, request: Request):
        with lock, app.state.sessions() as db:
            return state(db, public_board(db, slug, request))

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
            for cookie, token in request.cookies.items():
                if not cookie.startswith("score67_") or len(cookie) != 18:
                    continue
                slug = cookie[8:]
                try:
                    authorize(db, slug, request)
                except HTTPException:
                    continue
                b = board(db, slug)
                games = []
                for m in db.scalars(select(Match).where(Match.slug == slug, Match.deleted_at.is_(None))
                                    .order_by(Match.created_at.desc())):
                    s = state(db, b, m.id)
                    games.append({k: s[k] for k in ("sport", "team_fouls_enabled", "match_id", "revision", "phase", "home", "away", "period_count",
                        "period_length_min", "created_at", "scheduled_at", "archived", "active", "trashed", "trash_reason", "trashed_at")})
                boards.append({"slug": b.slug, "name": b.name, "active_match": b.active_match, "description": b.description, "stream_url": b.stream_url,
                               "created_at": round(b.created_at * 1000), "matches": games})
                response.set_cookie(cookie, token, httponly=True, secure=secure,
                                    samesite="lax", max_age=180 * 86400, path="/")
            db.commit()
            return {"boards": sorted(boards, key=lambda b: b["created_at"], reverse=True)}

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
                    "home": {**{k: m.state["home"][k] for k in ("name", "color")}, "logo": m.state["home"].get("logo")},
                    "away": {**{k: m.state["away"][k] for k in ("name", "color")}, "logo": m.state["away"].get("logo")},
                    "location": {k: location[k] for k in ("lat", "lng", "label")} if location else None,
                    "description": b.description, "stream_url": b.stream_url})
            return {"games": games, "upcoming": upcoming, "server_now": round(now * 1000)}

    @app.post("/api/s/{slug}/matches", status_code=201)
    def create_match(slug: str, body: CreateMatch, request: Request):
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
            s = initial_state(body.period_count, body.period_length_min, body.sport)
            for team in ("home", "away"):
                name = getattr(body, team).strip()
                s[team].update(name=name, short="".join(name.split())[:SHORT_MAX].upper())
            m = Match(id=str(uuid4()), slug=slug, state=s,
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
            if (not management and b.active_match != m.id) or m.revision != body.expected_revision:
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
                new = Match(id=str(uuid4()), slug=slug,
                            state=initial_state(m.state["period_count"], m.state["period_length_min"], m.state["sport"]))
                new.state["team_fouls_enabled"] = m.state.get("team_fouls_enabled", False)
                new.state["foul_mode"] = foul_mode(m.state)
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

    # --- Anzeigetafeln (physical displays) -------------------------------
    # A browser that creates a display gets a management cookie for it. The
    # device (e.g. a Raspberry Pi) pairs once with a short code and then uses
    # its own bearer token to follow the assigned board's current game.

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
        pending = bool(d.pairing_code and (d.pairing_expires_at or 0) > now)
        return {"id": d.id, "name": d.name, "paired": d.token_hash is not None,
                "online": bool(d.last_seen_at and d.last_seen_at > now - 30),
                "last_seen_at": round(d.last_seen_at * 1000) if d.last_seen_at else None,
                "code": d.pairing_code if pending else None,
                "code_expires_at": round(d.pairing_expires_at * 1000) if pending else None,
                "board": b.slug if b else None, "board_description": b.description if b else None}

    def device_display(db, token):
        d = db.scalar(select(Display).where(Display.token_hash == digest(token or "")))
        if not token or not d:
            raise HTTPException(401, "display_unpaired")
        return d

    def device_payload(db, d):
        b = db.get(Board, d.board_slug) if d.board_slug else None
        return {"display": {"id": d.id, "name": d.name}, "board": b.slug if b else None,
                "state": state(db, b) if b else None, "server_now": round(time.time() * 1000)}

    def bearer(request):
        header = request.headers.get("authorization", "")
        return header[7:].strip() if header.lower().startswith("bearer ") else ""

    @app.post("/api/displays", status_code=201)
    def create_display(body: DisplayCreate, response: Response):
        with lock, app.state.sessions() as db:
            now = time.time()
            display_id = "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(12))
            d = Display(id=display_id, name=body.name.strip(), created_at=now,
                        pairing_code=pairing_code(db), pairing_expires_at=now + PAIRING_SECONDS)
            db.add(d)
            db.flush()
            token = secrets.token_urlsafe(32)
            db.add(DisplayAdmin(id=str(uuid4()), display_id=d.id, token_hash=digest(token), created_at=now))
            response.set_cookie(display_cookie(d.id), token, httponly=True, secure=secure,
                                samesite="lax", max_age=365 * 86400, path="/")
            db.commit()
            return display_info(db, d)

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
            if "board" in body.model_fields_set:
                if body.board is not None:
                    authorize(db, body.board, request)  # Only boards this browser controls.
                d.board_slug = body.board
            db.commit()
            return display_info(db, d)

    @app.post("/api/displays/{display_id}/code")
    def renew_display_code(display_id: str, request: Request):
        with lock, app.state.sessions() as db:
            d = managed_display(db, display_id, request.cookies)
            d.pairing_code, d.pairing_expires_at = pairing_code(db), time.time() + PAIRING_SECONDS
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

    @app.post("/api/display/pair")
    def pair_display(body: DisplayPair, request: Request):
        with lock, app.state.sessions() as db:
            now = time.time()
            key = "pair:" + digest(request.client.host if request.client else "unknown")
            limit = db.get(RateLimit, key)
            if not limit:
                limit = RateLimit(key=key, count=0, reset_at=now + 3600)
                db.add(limit)
            if limit.reset_at <= now:
                limit.count, limit.reset_at = 0, now + 3600
            limit.count += 1
            if limit.count > 30:
                db.commit()
                raise HTTPException(429, "rate_limited")
            code = body.code.strip().upper().replace("-", "").replace(" ", "")
            d = db.scalar(select(Display).where(Display.pairing_code == code))
            if not d or (d.pairing_expires_at or 0) <= now:
                db.commit()
                raise HTTPException(404, "pairing_code_invalid")
            token = secrets.token_urlsafe(32)
            d.token_hash, d.pairing_code, d.pairing_expires_at = digest(token), None, None
            d.paired_at = d.last_seen_at = now
            db.commit()
            return {"display_id": d.id, "name": d.name, "token": token}

    @app.get("/api/display/state")
    def display_state(request: Request):
        with lock, app.state.sessions() as db:
            d = device_display(db, bearer(request))
            d.last_seen_at = time.time()
            payload = device_payload(db, d)
            db.commit()
            return payload

    @app.websocket("/ws/display")
    async def display_live(ws: WebSocket):
        token = ws.query_params.get("token", "")
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
                    current = (d.board_slug, d.name, m.id if m else None, m.revision if m else 0)
                    payload = device_payload(db, d) if current != signature else None
                    if time.time() - seen > 10:
                        d.last_seen_at = seen = time.time()
                        db.commit()
                if payload is not None:
                    await ws.send_json(payload)
                    signature = current
                try:
                    await asyncio.wait_for(ws.receive_text(), timeout=0.25)
                except asyncio.TimeoutError:
                    pass
        except (WebSocketDisconnect, RuntimeError):
            pass

    @app.get("/", response_class=HTMLResponse)
    def landing(request: Request):
        return templates.TemplateResponse(request=request, name="landing.html")

    @app.get("/live", response_class=HTMLResponse)
    def live_page(request: Request):
        return templates.TemplateResponse(request=request, name="live.html")

    @app.get("/location-picker", response_class=HTMLResponse)
    def location_picker(request: Request):
        return templates.TemplateResponse(request=request, name="location-picker.html")

    @app.get("/s/{slug}", response_class=HTMLResponse)
    @app.get("/s/{slug}/overlay", response_class=HTMLResponse)
    def display(request: Request, slug: str):
        overlay = request.url.path.endswith("/overlay")
        with app.state.sessions() as db:
            b = board(db, slug)
            hidden = not viewer_allowed(db, b, request.cookies, request.query_params.get("k"))
        return templates.TemplateResponse(request=request, name="display.html",
                                          context={"slug": slug, "overlay": overlay, "private": hidden})

    @app.get("/new")
    @app.get("/dashboard")
    @app.get("/s/{slug}/control")
    def control(slug: str | None = None):
        if not (build / "index.html").exists():
            raise HTTPException(503, "control_build_missing")
        return FileResponse(build / "index.html")

    return app


app = create_app()
