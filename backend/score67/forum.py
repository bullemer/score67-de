"""A small public forum: threads and replies.

Posting needs a confirmed email address. Signed-in users (email account)
publish at once; everybody else gets a six-digit code by email, and entering
it publishes the post and signs the browser in, so the next post needs no
code. Addresses are never shown. With FORUM_MODERATOR_EMAIL set, every
published post is mailed there with a one-click hide link."""
import asyncio
import hashlib
import json
import os
import re
import secrets
import time
from pathlib import Path
from typing import Literal

from fastapi import HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import func, select

from . import mail
from .db import ForumPost

ROOT = Path(__file__).resolve().parents[2]
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
CODE_SECONDS = 1800
CODE_ATTEMPTS = 5
PENDING_SECONDS = 86400


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def texts(language):
    return json.loads((ROOT / f"shared/i18n/{language}.json").read_text())


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ForumWrite(Strict):
    thread_id: int | None = None
    title: str | None = Field(default=None, max_length=120)
    body: str = Field(min_length=1, max_length=4000)
    name: str = Field(min_length=1, max_length=60)
    email: str | None = Field(default=None, max_length=254)
    language: Literal["de", "en"] = "de"
    website: str = Field(default="", max_length=200)  # honeypot: people leave it empty


class ForumCode(Strict):
    code: str = Field(min_length=6, max_length=6)


class ForumModeration(Strict):
    key: str = Field(min_length=10, max_length=100)
    hidden: bool = True


def ms(value):
    return round(value * 1000) if value else None


def public(post):
    return {"id": post.id, "thread_id": post.thread_id, "title": post.title, "body": post.body,
            "author": post.author_name, "published_at": ms(post.published_at)}


def visible():
    return (ForumPost.published_at.is_not(None), ForumPost.hidden_at.is_(None))


def register(app, *, lock, current_account, limited, sign_in):
    """Adds the forum API. ``sign_in(db, email, response)`` starts an account
    session for a confirmed address (the same as an email sign-in link)."""

    def origin(request):
        return os.getenv("PUBLIC_ORIGIN", str(request.base_url).rstrip("/"))

    async def notify(request, post_id):
        """Mail a published post to the moderator, with a hide link."""
        to = os.getenv("FORUM_MODERATOR_EMAIL")
        if not to or not mail.enabled():
            return
        key = secrets.token_urlsafe(24)
        with lock, app.state.sessions() as db:
            post = db.get(ForumPost, post_id)
            post.moderation_hash = digest(key)
            thread = post.thread_id or post.id
            title = post.title or db.get(ForumPost, thread).title
            body = (f"{post.author_name} <{post.email}>\n{title}\n\n{post.body}\n\n"
                    f"{origin(request)}/forum/{thread}\n"
                    f"Ausblenden / hide: {origin(request)}/forum/moderate/{post.id}#k={key}\n")
            db.commit()
        try:
            await asyncio.to_thread(app.state.send_mail, to, f"Score67 Forum: {title}", body)
        except Exception:  # noqa: BLE001 - a missing notification must not fail the post
            pass

    @app.get("/api/forum")
    def threads():
        with lock, app.state.sessions() as db:
            rows = db.scalars(select(ForumPost).where(ForumPost.thread_id.is_(None), *visible())).all()
            stats = dict(((t, (n, last)) for t, n, last in db.execute(
                select(ForumPost.thread_id, func.count(), func.max(ForumPost.published_at))
                .where(ForumPost.thread_id.is_not(None), *visible()).group_by(ForumPost.thread_id))))
            result = []
            for post in rows:
                replies, last = stats.get(post.id, (0, None))
                result.append({**public(post), "body": post.body[:240], "replies": replies,
                               "last_at": ms(max(post.published_at, last or 0))})
            result.sort(key=lambda r: r["last_at"], reverse=True)
            return {"threads": result[:200]}

    @app.get("/api/forum/me")
    def forum_me(request: Request):
        with lock, app.state.sessions() as db:
            account = current_account(db, request.cookies)
            db.commit()
            return {"mail_enabled": mail.enabled(), "email": account.email if account else None}

    @app.get("/api/forum/{thread_id}")
    def thread(thread_id: int):
        with lock, app.state.sessions() as db:
            post = db.get(ForumPost, thread_id)
            if not post or post.thread_id is not None or not post.published_at or post.hidden_at:
                raise HTTPException(404, "thread_not_found")
            replies = db.scalars(select(ForumPost).where(ForumPost.thread_id == thread_id, *visible())
                                 .order_by(ForumPost.published_at)).all()
            return {"thread": public(post), "replies": [public(r) for r in replies]}

    @app.post("/api/forum/posts")
    async def write(body: ForumWrite, request: Request):
        now = time.time()
        title = (body.title or "").strip() or None
        text_, name = body.body.strip(), body.name.strip()
        if not text_ or not name or (body.thread_id is None and not title):
            raise HTTPException(422, "forum_incomplete")
        if body.website:
            return {"pending": True, "post_id": 0}  # a bot filled the hidden field: pretend
        code = f"{secrets.randbelow(1000000):06d}"
        with lock, app.state.sessions() as db:
            if body.thread_id is not None:
                parent = db.get(ForumPost, body.thread_id)
                if not parent or parent.thread_id is not None or not parent.published_at or parent.hidden_at:
                    raise HTTPException(404, "thread_not_found")
            account = current_account(db, request.cookies)
            email = account.email if account else (body.email or "").strip().lower()
            if not account and not EMAIL.match(email):
                raise HTTPException(422, "email_invalid")
            if not account and not mail.enabled():
                raise HTTPException(503, "mail_disabled")
            ip = request.client.host if request.client else "unknown"
            blocked = limited(db, "forum-ip:" + digest(ip), 20, 3600, now)
            if not account:
                blocked |= limited(db, "forum-mail:" + digest(email), 5, 3600, now)
            if blocked:
                db.commit()
                raise HTTPException(429, "forum_rate_limited")
            # Codes nobody entered within a day are dropped.
            for stale in db.scalars(select(ForumPost).where(ForumPost.published_at.is_(None),
                                                            ForumPost.created_at < now - PENDING_SECONDS)):
                db.delete(stale)
            post = ForumPost(thread_id=body.thread_id, title=title if body.thread_id is None else None, body=text_,
                             author_name=name, email=email, language=body.language, created_at=now, code_attempts=0)
            if account:
                post.account_id, post.published_at = account.id, now
            db.add(post)
            db.flush()
            if not account:
                post.code_hash, post.code_expires_at = digest(f"{post.id}:{code}"), now + CODE_SECONDS
            post_id, thread = post.id, post.thread_id or post.id
            db.commit()
        if account:
            await notify(request, post_id)
            return {"published": True, "id": post_id, "thread_id": thread}
        words = texts(body.language)
        try:
            await asyncio.to_thread(app.state.send_mail, email, words["email.forum_code.subject"],
                                    words["email.forum_code.body"].replace("{code}", code))
        except Exception:  # noqa: BLE001 - report a delivery problem without details
            raise HTTPException(502, "mail_failed")
        return {"pending": True, "post_id": post_id}

    @app.post("/api/forum/posts/{post_id}/verify")
    async def verify(post_id: int, body: ForumCode, request: Request, response: Response):
        now = time.time()
        with lock, app.state.sessions() as db:
            post = db.get(ForumPost, post_id)
            if not post or post.published_at or not post.code_hash:
                raise HTTPException(404, "post_not_found")
            if post.code_attempts >= CODE_ATTEMPTS:
                raise HTTPException(429, "code_locked")
            if post.code_expires_at < now:
                raise HTTPException(410, "code_expired")
            if not secrets.compare_digest(post.code_hash, digest(f"{post.id}:{body.code.strip()}")):
                post.code_attempts += 1
                db.commit()
                raise HTTPException(401, "code_invalid")
            post.published_at, post.code_hash, post.code_expires_at = now, None, None
            post.account_id = sign_in(db, post.email, response)
            thread = post.thread_id or post.id
            db.commit()
        await notify(request, post_id)
        return {"published": True, "id": post_id, "thread_id": thread}

    @app.post("/api/forum/posts/{post_id}/moderate")
    def moderate(post_id: int, body: ForumModeration):
        with lock, app.state.sessions() as db:
            post = db.get(ForumPost, post_id)
            if not post or not post.moderation_hash or not secrets.compare_digest(post.moderation_hash, digest(body.key)):
                raise HTTPException(403, "moderation_denied")
            post.hidden_at = time.time() if body.hidden else None
            db.commit()
            return {"id": post.id, "hidden": post.hidden_at is not None, "thread_id": post.thread_id or post.id}
