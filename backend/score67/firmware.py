"""Over-the-air updates for LED panel firmware (docs/DISPLAY-FIRMWARE.md).

Releases are uploaded by the operator (bearer FIRMWARE_ADMIN_TOKEN) and stored
in the database. A panel is *offered* the newest release of its channel that
is newer than the version it reports — as a ``firmware`` field in its compact
feed; the panel decides when to install (never during a game), downloads
``/fw/<version>.bin`` with its own token, checks the SHA-256 and reports its
progress as ``ota`` status. Channels: "stable" for everyone, "test" only for
panels switched to beta in the app, "off" withdrawn."""
import base64
import hashlib
import hmac
import os
import re
import time

from fastapi import HTTPException, Request, Response
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select

from .db import FirmwareRelease

VERSION = re.compile(r"^(\d{1,3})\.(\d{1,3})\.(\d{1,3})$")
CHANNELS = ("test", "stable", "off")
MAX_FIRMWARE = 4 * 1024 * 1024          # the Matrix Portal S3 app slot is ~3 MB
MAX_REQUEST = 6 * 1024 * 1024           # base64 JSON around it


def version_key(value):
    match = VERSION.match(value or "")
    return tuple(int(part) for part in match.groups()) if match else None


class Strict(BaseModel):
    model_config = ConfigDict(extra="forbid")


class ReleaseUpload(Strict):
    version: str = Field(max_length=20)
    channel: str = "test"
    notes: str | None = Field(default=None, max_length=300)
    sha256: str = Field(min_length=64, max_length=64)
    data: str = Field(max_length=MAX_REQUEST)


class ReleaseUpdate(Strict):
    channel: str | None = None
    notes: str | None = Field(default=None, max_length=300)


def offer(db, display):
    """The update a panel should install, or None: the newest release of its
    channel(s) above the version it runs. Only self-registered panels that
    report a plain x.y.z version are offered anything."""
    current = version_key(display.fw_version)
    if not display.device_key_hash or current is None:
        return None
    channels = ("stable", "test") if display.fw_channel == "test" else ("stable",)
    rows = db.execute(select(FirmwareRelease.version, FirmwareRelease.sha256, FirmwareRelease.size)
                      .where(FirmwareRelease.channel.in_(channels))).all()
    newer = [r for r in rows if (version_key(r.version) or (0,)) > current]
    if not newer:
        return None
    best = max(newer, key=lambda r: version_key(r.version))
    return {"version": best.version, "url": f"/fw/{best.version}.bin", "sha256": best.sha256, "size": best.size}


def register(app, *, lock, device_display):

    def operator(request):
        expected = os.getenv("FIRMWARE_ADMIN_TOKEN", "")
        header = request.headers.get("authorization", "")
        given = header[7:].strip() if header.lower().startswith("bearer ") else ""
        if not expected or not given or not hmac.compare_digest(given, expected):
            raise HTTPException(401, "firmware_admin_required")

    def info(r):
        return {"version": r.version, "channel": r.channel, "sha256": r.sha256, "size": r.size,
                "notes": r.notes, "created_at": round(r.created_at * 1000)}

    @app.get("/api/firmware")
    def releases(request: Request):
        operator(request)
        with lock, app.state.sessions() as db:
            rows = db.scalars(select(FirmwareRelease)).all()
            return {"releases": sorted((info(r) for r in rows), key=lambda r: version_key(r["version"]), reverse=True)}

    @app.post("/api/firmware", status_code=201)
    def upload(body: ReleaseUpload, request: Request):
        operator(request)
        if version_key(body.version) is None:
            raise HTTPException(422, "version_invalid")
        if body.channel not in CHANNELS:
            raise HTTPException(422, "channel_invalid")
        try:
            data = base64.b64decode(body.data, validate=True)
        except ValueError:
            raise HTTPException(422, "data_invalid")
        if not data or len(data) > MAX_FIRMWARE:
            raise HTTPException(422, "data_invalid")
        digest = hashlib.sha256(data).hexdigest()
        if digest != body.sha256.lower():
            raise HTTPException(422, "sha256_mismatch")   # the upload was damaged on the way
        with lock, app.state.sessions() as db:
            if db.get(FirmwareRelease, body.version):
                raise HTTPException(409, "version_exists")
            release = FirmwareRelease(version=body.version, data=data, sha256=digest, size=len(data),
                                      channel=body.channel, notes=body.notes, created_at=time.time())
            db.add(release)
            db.commit()
            return info(release)

    @app.put("/api/firmware/{version}")
    def change(version: str, body: ReleaseUpdate, request: Request):
        operator(request)
        with lock, app.state.sessions() as db:
            release = db.get(FirmwareRelease, version)
            if not release:
                raise HTTPException(404, "not_found")
            if body.channel is not None:
                if body.channel not in CHANNELS:
                    raise HTTPException(422, "channel_invalid")
                release.channel = body.channel
            if "notes" in body.model_fields_set:
                release.notes = body.notes
            db.commit()
            return info(release)

    @app.get("/fw/{name}")
    def download(name: str, request: Request):
        """The firmware image for a panel (its own bearer token) or the operator."""
        match = re.fullmatch(r"(\d{1,3}\.\d{1,3}\.\d{1,3})\.bin", name)
        if not match:
            raise HTTPException(404, "not_found")
        header = request.headers.get("authorization", "")
        token = header[7:].strip() if header.lower().startswith("bearer ") else ""
        with lock, app.state.sessions() as db:
            try:
                operator(request)
            except HTTPException:
                device_display(db, token)   # 401 unless a registered panel asks
            release = db.get(FirmwareRelease, match[1])
            if not release or release.channel == "off":
                raise HTTPException(404, "not_found")
            return Response(release.data, media_type="application/octet-stream",
                            headers={"Content-Length": str(release.size), "X-Checksum-SHA256": release.sha256,
                                     "ETag": f'"{release.sha256}"', "Cache-Control": "private, no-store"})
