#!/usr/bin/env python3
"""Simulates a Score67 LED panel (what the ESP32 firmware will do), for
testing the server side without hardware:

    cd backend && uv run python ../tools/display_sim.py [https://score67.de]

1. Registers with a device key (kept in ~/.score67-display-sim.json, like the
   firmware keeps it in NVS) and prints the pairing code the panel would show.
2. Follows wss://…/ws/display?format=compact and prints what the panel would
   draw; the clock runs locally from server_now (no NTP), once per second.
3. Reports a status message (fw, rssi, uptime) like the firmware.
Enter the code in the app: Einstellungen → Anzeigetafeln → Code von der LED-Tafel."""
import asyncio
import json
import secrets
import sys
import time
import urllib.request
from pathlib import Path

import websockets

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8067").rstrip("/")
STORE = Path.home() / ".score67-display-sim.json"
FW = "sim-0.1.0"


def register():
    saved = json.loads(STORE.read_text()) if STORE.exists() else {}
    key = saved.get("device_key") or secrets.token_urlsafe(32)
    request = urllib.request.Request(f"{BASE}/api/display/register", method="POST",
                                     data=json.dumps({"device_key": key, "fw": FW}).encode(),
                                     headers={"Content-Type": "application/json"})
    answer = json.load(urllib.request.urlopen(request, timeout=10))
    STORE.write_text(json.dumps({"device_key": key, "token": answer["token"]}))
    return answer


def mmss(ms, tenths):
    if tenths and ms < 60_000:
        return f"{ms // 1000}.{ms % 1000 // 100}"
    seconds = ms // 1000
    return f"{seconds // 60:02d}:{seconds % 60:02d}"


def frame(feed, received):
    if feed["mode"] == "pairing":
        return f"CODE {feed['code']}"
    if feed["mode"] == "idle":
        return f"{feed['name']}: kein Scoreboard zugewiesen"
    c, line = feed.get("clock") or {}, ""
    if c.get("visible"):
        ms = c["ms"]
        if c.get("running"):
            passed = round((time.monotonic() - received) * 1000)   # local time since the message
            ms = max(0, ms - passed) if c["direction"] == "down" else ms + passed
        line = f"  {feed['period']} {mmss(ms, c['direction'] == 'down')}"
    h, g = feed["home"], feed["guest"]
    flag = " [IDENTIFY]" if feed.get("identify") else ""
    return f"{h['short']:>3} {h['score']:>3} : {g['score']:<3} {g['short']:<3}{line}  ({feed['brightness']} %){flag}"


async def follow(token):
    url = BASE.replace("http", "ws", 1) + f"/ws/display?token={token}&format=compact"
    started, feed, received, last_seq = time.monotonic(), None, 0.0, 0
    async with websockets.connect(url) as ws:
        await ws.send(json.dumps({"fw": FW, "rssi": -55, "uptime": 0}))
        while True:
            try:
                message = await asyncio.wait_for(ws.recv(), timeout=1)
                data = json.loads(message)
                if data["seq"] >= last_seq:             # drop stale messages
                    feed, received, last_seq = data, time.monotonic(), data["seq"]
            except asyncio.TimeoutError:
                pass
            if feed:
                print(time.strftime("%H:%M:%S"), frame(feed, received), flush=True)
            if int(time.monotonic() - started) % 30 == 0:
                await ws.send(json.dumps({"fw": FW, "rssi": -55, "uptime": int(time.monotonic() - started)}))


def main():
    answer = register()
    print(f"Display {answer['display_id']} registriert." + (f" Code auf der Tafel: {answer['code']}" if answer["code"] else ""))
    while True:
        try:
            asyncio.run(follow(answer["token"]))
        except (OSError, websockets.ConnectionClosed) as error:
            if getattr(error, "code", None) == 1008:            # removed in the app: register again
                answer = register()
                print("Neu registriert, Code:", answer["code"])
            else:
                print("Verbindung weg, neuer Versuch in 3 s:", error)
                time.sleep(3)


if __name__ == "__main__":
    main()
