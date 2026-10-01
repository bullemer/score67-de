"""Pure match rules. Milliseconds and UTC epochs are language-neutral."""
from copy import deepcopy
import json
import re
from math import isfinite
from pathlib import Path

FOOTBALL = json.loads((Path(__file__).parent / "profiles/football.json").read_text())


class RuleError(Exception):
    pass


def initial_state(period_count=2, period_length_min=45):
    return {
        "sport": "football", "phase": "pre_game", "period": 0,
        "period_count": period_count, "period_length_min": period_length_min,
        "clock": {"enabled": True, "direction": "up", "running": False,
                  "started_at": None, "elapsed_ms": 0},
        "home": {"name": "Home", "short": "HOME", "color": "#c8102e"},
        "away": {"name": "Guest", "short": "GUEST", "color": "#1d4ed8"},
        "overlay": {"view": "scoreboard", "position": "top_left", "auto_big": True, "delay_ms": 0},
    }


def elapsed(state, now_ms):
    c = state["clock"]
    return c["elapsed_ms"] + (max(0, now_ms - c["started_at"]) if c["running"] else 0)


def number(value, low, high):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not isfinite(value) or not low <= value <= high:
        raise RuleError("invalid_value")
    return value


def integer(value, low, high):
    value = number(value, low, high)
    if int(value) != value:
        raise RuleError("invalid_value")
    return int(value)


def boolean(value):
    if not isinstance(value, bool):
        raise RuleError("invalid_value")
    return value


def text(value, limit):
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > limit:
        raise RuleError("invalid_value")
    return value.strip()


def apply(state, action, data, now_ms):
    s = deepcopy(state)
    c = s["clock"]
    phase = s["phase"]
    event = {"type": action, "period": s["period"],
             "clock_ms": round(elapsed(s, now_ms)) if c["enabled"] else None,
             "period_length_min": s["period_length_min"], "period_count": s["period_count"],
             "occurred_at": now_ms}
    if action in ("score", "score_correction"):
        points = 1 if action == "score" else -1
        if data.get("team") not in ("home", "away") or data.get("points") != points or isinstance(data.get("points"), bool):
            raise RuleError("invalid_score")
        event.update(team=data["team"], points=points)
    elif action == "period_start":
        if phase not in ("pre_game", "break") or s["period"] >= s["period_count"]:
            raise RuleError("invalid_transition")
        s.update(phase="period_running", period=s["period"] + 1)
        c.update(elapsed_ms=0, running=c["enabled"], started_at=now_ms if c["enabled"] else None)
        event["period"] = s["period"]
        event["clock_ms"] = 0 if c["enabled"] else None
    elif action in ("period_end", "game_end"):
        if action == "period_end" and (phase != "period_running" or s["period"] >= s["period_count"]):
            raise RuleError("invalid_transition")
        if action == "game_end" and phase == "finished":
            raise RuleError("invalid_transition")
        c.update(elapsed_ms=round(elapsed(s, now_ms)), running=False, started_at=None)
        s["phase"] = "finished" if action == "game_end" else "break"
    elif action == "clock_adjust":
        if not c["enabled"]:
            raise RuleError("clock_disabled")
        seconds = number(data.get("seconds"), -3600, 3600)
        c.update(elapsed_ms=max(0, round(elapsed(s, now_ms) + seconds * 1000)),
                 started_at=now_ms if c["running"] else None)
    elif action == "settings":
        allowed = {"period_count", "period_length_min", "clock_enabled", "clock_elapsed_ms", "home", "away"}
        if set(data) - allowed:
            raise RuleError("invalid_value")
        if "period_count" in data:
            s["period_count"] = integer(data["period_count"], max(1, s["period"]), 12)
        if "period_length_min" in data:
            s["period_length_min"] = integer(data["period_length_min"], 1, 60)
        for team in ("home", "away"):
            if team in data:
                t = data[team]
                if not isinstance(t, dict) or set(t) - {"name", "short", "color"}:
                    raise RuleError("invalid_value")
                if "name" in t:
                    s[team]["name"] = text(t["name"], 60)
                if "short" in t:
                    s[team]["short"] = text(t["short"], 5)
                if "color" in t:
                    if not isinstance(t["color"], str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", t["color"]):
                        raise RuleError("invalid_value")
                    s[team]["color"] = t["color"].lower()
        if "clock_enabled" in data:
            enabled = boolean(data["clock_enabled"])
            c["elapsed_ms"] = round(elapsed(s, now_ms))
            if enabled and not c["enabled"] and phase == "period_running" and "clock_elapsed_ms" not in data:
                raise RuleError("clock_value_required")
            c.update(enabled=enabled, running=enabled and phase == "period_running",
                     started_at=now_ms if enabled and phase == "period_running" else None)
        if "clock_elapsed_ms" in data:
            c.update(elapsed_ms=integer(data["clock_elapsed_ms"], 0, 86400000),
                     started_at=now_ms if c["running"] else None)
    elif action == "overlay":
        o = s["overlay"]
        if set(data) - {"view", "position", "auto_big", "delay_ms"}:
            raise RuleError("invalid_value")
        for key, choices in (("view", ("scoreboard", "score_big", "hidden")),
                             ("position", ("top_left", "top_right"))):
            if key in data:
                if data[key] not in choices:
                    raise RuleError("invalid_value")
                o[key] = data[key]
        if "auto_big" in data:
            o["auto_big"] = boolean(data["auto_big"])
        if "delay_ms" in data:
            o["delay_ms"] = integer(data["delay_ms"], 0, 30000)
    else:
        raise RuleError("unsupported_action")
    # Store only changed fields: undoing a goal must never rewind a running clock.
    before = {key: deepcopy(value) for key, value in state.items() if s[key] != value}
    return s, event, before
