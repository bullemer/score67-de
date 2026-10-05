"""The compact feed for LED scoreboard firmware (ESP32, 64 × 32 panel).

The public game state carries the whole game log and grows to tens of KB;
a display needs a few hundred bytes. The server also formats everything
language- or rule-dependent (short period labels, which fouls to show,
the clock value), so the firmware only draws. Always the complete state,
never a diff; ``seq`` increases so the device can drop stale messages.
See docs/DISPLAY-API.md."""
from .domain import elapsed, period_ms

FORMAT_VERSION = 1


def period_label(s):
    """ASCII and short for a 3×5 pixel font: Q3, H2, 5/8, OT1 (empty before kickoff)."""
    period, count = s.get("period") or 0, s.get("period_count") or 1
    if not period or count == 1:
        return ""
    if s.get("sport") == "basketball" and period > count:
        return f"OT{period - count}"
    if count == 4:
        return f"Q{period}"
    if count == 2:
        return f"H{period}"
    return f"{period}/{count}"


def clock(s, now_ms):
    """The clock as shown at ``now_ms`` (ms, server time): basketball counts
    down the period, football up across halves (start of the 2nd half = 45:00)."""
    c = s.get("clock") or {}
    if not c.get("enabled") or s.get("phase") in ("pre_game", "no_match", None):
        return {"visible": False}
    spent = round(elapsed(s, now_ms))
    if s.get("sport") == "basketball":
        return {"visible": True, "running": bool(c.get("running")), "direction": "down",
                "ms": max(0, period_ms(s) - spent), "at": now_ms}
    start = max(0, (s.get("period") or 1) - 1) * s.get("period_length_min", 45) * 60000
    return {"visible": True, "running": bool(c.get("running")), "direction": "up",
            "ms": start + spent, "at": now_ms}


def team(s, side):
    t = s.get(side) or {}
    counters = t.get("counters") or {}
    fouls = None
    if s.get("sport") == "basketball" and s.get("foul_mode") in ("team", "both"):
        fouls = counters.get("team_fouls")
    return {"short": (t.get("short") or "")[:3].upper(), "score": t.get("score", 0),
            "color": t.get("color") or "#ffffff", "fouls": fouls,
            "red_cards": counters.get("red_cards", 0) if s.get("sport") != "basketball" else None}


def payload(*, now_ms, name, brightness, identify, mode, code=None, s=None):
    """mode: "pairing" (not claimed: show ``code``), "idle" (no scoreboard
    assigned) or "game" (``s`` = public state of the assigned board)."""
    out = {"v": FORMAT_VERSION, "seq": now_ms, "server_now": now_ms, "mode": mode, "name": name,
           "brightness": brightness, "identify": identify}
    if mode == "pairing":
        out["code"] = code
    if mode == "game" and s is not None:
        out.update(sport=s.get("sport"), phase=s.get("phase"), period=period_label(s),
                   home=team(s, "home"), guest=team(s, "away"), possession=s.get("possession"),
                   clock=clock(s, now_ms))
    return out
