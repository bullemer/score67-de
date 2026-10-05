#!/usr/bin/env python3
"""Manage LED panel firmware releases on score67.de (OTA, docs/DISPLAY-FIRMWARE.md).

    python tools/fw_release.py upload firmware.bin 0.2.0 [--channel test] [--notes "…"]
    python tools/fw_release.py channel 0.2.0 stable        # test | stable | off
    python tools/fw_release.py list

The operator token comes from $SCORE67_FW_TOKEN or ~/.score67-fw-token (the
value of FIRMWARE_ADMIN_TOKEN on the server). --server defaults to
https://score67.de. New releases start in "test": only panels with
"Beta-Firmware erhalten" get them; switch to "stable" once a test panel ran it."""
import argparse
import base64
import hashlib
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def token():
    value = os.getenv("SCORE67_FW_TOKEN") or (Path.home() / ".score67-fw-token").read_text().strip()
    if not value:
        sys.exit("no operator token: set SCORE67_FW_TOKEN or write ~/.score67-fw-token")
    return value


def call(server, method, path, body=None):
    request = urllib.request.Request(f"{server}{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        sys.exit(f"{error.code}: {error.read().decode()[:300]}")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--server", default="https://score67.de")
    sub = parser.add_subparsers(dest="cmd", required=True)
    up = sub.add_parser("upload")
    up.add_argument("file")
    up.add_argument("version")
    up.add_argument("--channel", default="test", choices=["test", "stable", "off"])
    up.add_argument("--notes")
    ch = sub.add_parser("channel")
    ch.add_argument("version")
    ch.add_argument("channel", choices=["test", "stable", "off"])
    sub.add_parser("list")
    a = parser.parse_args()
    server = a.server.rstrip("/")
    if a.cmd == "upload":
        data = Path(a.file).read_bytes()
        result = call(server, "POST", "/api/firmware", {
            "version": a.version, "channel": a.channel, "notes": a.notes,
            "sha256": hashlib.sha256(data).hexdigest(), "data": base64.b64encode(data).decode()})
    elif a.cmd == "channel":
        result = call(server, "PUT", f"/api/firmware/{a.version}", {"channel": a.channel})
    else:
        result = call(server, "GET", "/api/firmware")
    print(json.dumps(result, indent=1))


if __name__ == "__main__":
    main()
