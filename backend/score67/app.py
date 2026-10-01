import asyncio
from contextlib import asynccontextmanager
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import hmac
import json
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
from sqlalchemy import select

from .db import Admin, Board, Match, MatchEvent, RateLimit, Receipt, database
from .domain import FOOTBALL, RuleError, apply, initial_state

ROOT = Path(__file__).resolve().parents[2]


def digest(token):
    return hashlib.sha256(token.encode()).hexdigest()


def hash_pin(pin, salt=None):
    salt = salt or secrets.token_hex(16)
    return salt + ":" + hashlib.pbkdf2_hmac("sha256", pin.encode(), salt.encode(), 300000).hex()


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CreateBoard(StrictModel):
    sport: Literal["football"] = "football"
    language: Literal["de", "en"] = "de"


class Claim(StrictModel):
    pin: str = Field(pattern=r"^\d{6}$")
    label: str = Field(default="Browser", min_length=1, max_length=60)


class Command(StrictModel):
    command_id: UUID
    expected_revision: int = Field(ge=0)
    action: str = Field(max_length=30)
    data: dict = Field(default_factory=dict)


def create_app(db_url=None, secure_cookies=None):
    secure = secure_cookies if secure_cookies is not None else os.getenv("COOKIE_SECURE", "true").lower() == "true"
    lock = threading.RLock()

    @asynccontextmanager
    async def lifespan(app):
        engine, sessions = database(db_url)
        app.state.sessions = sessions
        yield
        engine.dispose()

    app = FastAPI(title="Score67", version="0.1.0", lifespan=lifespan)
    templates = Jinja2Templates(directory=ROOT / "backend/score67/templates")
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
            length = request.headers.get("content-length", "0")
            if not length.isdigit() or int(length) > 16384:
                return JSONResponse({"error": "request_too_large"}, status_code=413)
            # Also bound chunked requests, for which Content-Length can be absent.
            size = 0
            chunks = []
            async for chunk in request.stream():
                size += len(chunk)
                if size > 16384:
                    return JSONResponse({"error": "request_too_large"}, status_code=413)
                chunks.append(chunk)
            request._body = b"".join(chunks)
        response = await call_next(request)
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["Referrer-Policy"] = "no-referrer"
        if request.url.path.startswith("/api/") or request.url.path.endswith("/control") or request.url.path == "/new":
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

    def grant(db, slug, response, label):
        token = secrets.token_urlsafe(32)
        db.add(Admin(id=str(uuid4()), slug=slug, token_hash=digest(token), label=label, last_seen_at=time.time()))
        response.set_cookie(f"score67_{slug}", token, httponly=True, secure=secure,
                            samesite="lax", max_age=180 * 86400, path="/")

    def state(db, b, match_id=None):
        m = db.get(Match, match_id or b.active_match)
        if not m or m.slug != b.slug:
            raise HTTPException(404, "not_found")
        s = deepcopy(m.state)
        events = db.scalars(select(MatchEvent).where(MatchEvent.match_id == m.id).order_by(MatchEvent.id)).all()
        s.update(scoreboard=b.slug, name=b.name, language=b.language, match_id=m.id,
                 revision=m.revision, server_now=round(time.time() * 1000))
        for team in ("home", "away"):
            s[team]["score"] = sum(e.payload.get("points", 0) for e in events
                                   if not e.cancelled and e.payload.get("team") == team and e.payload["type"] in ("score", "score_correction"))
            s[team]["counters"] = {}
        s["events"] = [{**e.payload, "id": e.id, "cancelled": e.cancelled} for e in events]
        return s

    @app.get("/health")
    def health():
        with app.state.sessions() as db:
            db.execute(select(1))
        return {"status": "ok", "release": os.getenv("RELEASE_SHA", "development")}

    @app.get("/api/sports")
    def sports():
        return [FOOTBALL]

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
            limit.count += 1
            slug = "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(10))
            while db.get(Board, slug):
                slug = "".join(secrets.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(10))
            pin, match_id = f"{secrets.randbelow(1000000):06d}", str(uuid4())
            label = datetime.fromtimestamp(now, timezone.utc).isoformat(sep=" ", timespec="milliseconds").replace("+00:00", " UTC")
            b = Board(slug=slug, name=label, language=body.language, pin_hash=hash_pin(pin),
                      active_match=match_id, created_at=now)
            db.add(b)
            db.flush()
            db.add(Match(id=match_id, slug=slug, state=initial_state()))
            grant(db, slug, response, "Browser")
            db.commit()
            return {"slug": slug, "pin": pin, "links": {"public": f"/s/{slug}",
                    "overlay": f"/s/{slug}/overlay", "control": f"/s/{slug}/control"}}

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
    def current_state(slug: str):
        with lock, app.state.sessions() as db:
            return state(db, board(db, slug))

    @app.get("/api/s/{slug}/matches/{match_id}/state")
    def archived_state(slug: str, match_id: str):
        with lock, app.state.sessions() as db:
            return state(db, board(db, slug), match_id)

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
                return state(db, b)
            if b.active_match != m.id or m.revision != body.expected_revision:
                raise HTTPException(409, "state_changed")
            if body.action == "new_match":
                if m.state["phase"] != "finished":
                    raise HTTPException(409, "finish_first")
                new = Match(id=str(uuid4()), slug=slug,
                            state=initial_state(m.state["period_count"], m.state["period_length_min"]))
                db.add(new)
                b.active_match = new.id
            elif body.action == "undo":
                last = db.scalar(select(MatchEvent).where(MatchEvent.match_id == m.id, MatchEvent.cancelled == False)
                                 .order_by(MatchEvent.id.desc()).limit(1))
                if not last or body.data.get("event_id") != last.id:
                    raise HTTPException(409, "undo_changed")
                updated = deepcopy(m.state)
                updated.update(last.before)
                m.state = updated
                last.cancelled = True
            else:
                if body.action == "score_correction" and body.data.get("team") in ("home", "away"):
                    if state(db, b)[body.data["team"]]["score"] <= 0:
                        raise HTTPException(422, "score_zero")
                try:
                    updated, payload, before = apply(m.state, body.action, body.data, round(time.time() * 1000))
                except RuleError as exc:
                    raise HTTPException(422, str(exc)) from exc
                m.state = updated
                db.add(MatchEvent(match_id=m.id, admin_id=admin.id, payload=payload, before=before))
            m.revision += 1
            db.add(Receipt(id=key, fingerprint=fingerprint))
            db.commit()
            return state(db, b)

    @app.websocket("/ws/s/{slug}")
    async def live(ws: WebSocket, slug: str):
        with app.state.sessions() as db:
            if not db.get(Board, slug):
                await ws.close(code=1008)
                return
        await ws.accept()
        signature = None
        try:
            while True:
                with lock, app.state.sessions() as db:
                    b = board(db, slug)
                    m = db.get(Match, b.active_match)
                    current = (m.id, m.revision)
                    if current != signature:
                        s = state(db, b)
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

    @app.get("/", response_class=HTMLResponse)
    def landing(request: Request):
        return templates.TemplateResponse(request=request, name="landing.html")

    @app.get("/s/{slug}", response_class=HTMLResponse)
    @app.get("/s/{slug}/overlay", response_class=HTMLResponse)
    def display(request: Request, slug: str):
        with app.state.sessions() as db:
            board(db, slug)
        return templates.TemplateResponse(request=request, name="display.html",
                                          context={"slug": slug, "overlay": request.url.path.endswith("/overlay")})

    @app.get("/new")
    @app.get("/s/{slug}/control")
    def control(slug: str | None = None):
        if not (build / "index.html").exists():
            raise HTTPException(503, "control_build_missing")
        return FileResponse(build / "index.html")

    return app


app = create_app()
