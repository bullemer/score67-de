"""Pure match rules. Milliseconds and UTC epochs are language-neutral."""
from copy import deepcopy
import json
import re
from math import isfinite
from pathlib import Path
from uuid import UUID, uuid4

FOOTBALL = json.loads((Path(__file__).parent / "profiles/football.json").read_text())


BASKETBALL = json.loads((Path(__file__).parent / "profiles/basketball.json").read_text())


BASKETBALL_STATS = ("rebound", "assist", "steal", "block", "turnover", "free_throw_missed")
FOOTBALL_EVENTS = ("foul", "free_kick", "penalty")
LINEUP_MAX = {"basketball": 5, "football": 11}
STAT_COLUMNS = {"score": "pts", "rebound": "reb", "assist": "ast",
                "steal": "stl", "block": "blk", "turnover": "to", "personal_foul": "pf", "technical_foul": "pf",
                "free_throw_missed": "ftx"}
# ftm = free throws made (scores marked free_throw), ftx = free throws missed.
COLUMNS = tuple(dict.fromkeys([*STAT_COLUMNS.values(), "ftm"]))
SHORT_MAX = 3


def player_statistics(team_state, events):
    """Project active events; retain historical players after squad edits."""
    def row(player=None):
        return {**(player or {"id": None, "number": "", "name": ""}),
                **dict.fromkeys(COLUMNS, 0)}
    rows = {None: row()}
    # Squad by shirt number for fast scanning, then number-only foul entries.
    squad = sorted(team_state.get("squad", []), key=lambda p: (not p["number"], int(p["number"] or 0), p["name"]))
    for player in squad + team_state.get("foul_players", []):
        rows.setdefault(player["id"], row(player))
    for event in events:
        column = STAT_COLUMNS.get(event["type"])
        if column is None:
            continue
        player = event.get("player")
        if event["type"] == "technical_foul" and not player:
            continue  # Coach/bench technicals belong to no player.
        identifier = player["id"] if player else None
        stats = rows.setdefault(identifier, row(player))
        stats[column] += event.get("points", 0) if column == "pts" else 1
        if event.get("detail") == "free_throw":
            stats["ftm"] += 1
    active_ids = {p["id"] for p in team_state.get("squad", [])}
    foul_ids = {p["id"] for p in team_state.get("foul_players", [])}
    for identifier, stats in rows.items():
        stats["in_squad"] = identifier in active_ids
        stats["foul_player"] = identifier in foul_ids
    totals = {column: sum(r[column] for r in rows.values()) for column in COLUMNS}
    return {"players": list(rows.values()), "totals": totals}


class RuleError(Exception):
    pass


def initial_state(period_count=None, period_length_min=None, sport="football"):
    basketball = sport == "basketball"
    period_count = period_count if period_count is not None else (4 if basketball else 2)
    period_length_min = period_length_min if period_length_min is not None else (10 if basketball else 45)
    return {
        "sport": sport, "foul_mode": ("personal" if period_count == 8 else "team") if basketball else "off", "team_fouls_enabled": basketball and period_count != 8, "overtime_length_min": 5, "phase": "pre_game", "period": 0,
        "period_count": period_count, "period_length_min": period_length_min,
        "clock": {"enabled": True, "direction": "down" if basketball else "up", "running": False,
                  "started_at": None, "elapsed_ms": 0},
        "home": {"name": "Home", "short": "HOM", "color": "#c8102e"},
        "away": {"name": "Guest", "short": "GUE", "color": "#1d4ed8"},
        "overlay": {"view": "scoreboard", "position": "top_left", "auto_big": True, "delay_ms": 0},
    }


def period_ms(state):
    return (state.get("overtime_length_min", 5) if state["period"] > state["period_count"] else state["period_length_min"]) * 60000


def elapsed(state, now_ms):
    c = state["clock"]
    value = c["elapsed_ms"] + (max(0, now_ms - c["started_at"]) if c["running"] else 0)
    return min(period_ms(state), value) if state["sport"] == "basketball" else value


def normalize_clock(state, now_ms):
    c = state["clock"]
    if state["sport"] == "basketball" and elapsed(state, now_ms) >= period_ms(state):
        c.update(elapsed_ms=period_ms(state), running=False, started_at=None)


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


def player_snapshot(state, team, player_id):
    if player_id is None:
        return None
    for player in state[team].get("squad", []):
        if player["id"] == player_id:
            return deepcopy(player)
    raise RuleError("player_not_found")


def foul_mode(state):
    return state.get("foul_mode", "team" if state.get("team_fouls_enabled") else "off")


def foul_player(state, team, data):
    """Resolve a squad member or a private number-only foul entry."""
    if data.get("player_id") is not None and data.get("player_number") is not None:
        raise RuleError("invalid_value")
    players = state[team].get("squad", []) + state[team].get("foul_players", [])
    def remember(player):
        if not any(p["id"] == player["id"] for p in state[team].get("foul_players", [])):
            state[team].setdefault("foul_players", []).append(deepcopy(player))
        return deepcopy(player)
    if data.get("player_id") is not None:
        for player in players:
            if player["id"] == data["player_id"]:
                return remember(player)
        raise RuleError("player_not_found")
    if data.get("player_number") is not None:
        number = data["player_number"]
        if not isinstance(number, str) or not re.fullmatch(r"[0-9]{1,3}", number.strip()):
            raise RuleError("invalid_value")
        number = str(int(number))
        for player in players:
            if player["number"] == number:
                return remember(player)
        player = {"id": str(uuid4()), "number": number, "name": ""}
        state[team].setdefault("foul_players", []).append(player)
        return remember(player)
    return None


def apply(state, action, data, now_ms):
    s = deepcopy(state)
    c = s["clock"]
    normalize_clock(s, now_ms)
    basketball = s["sport"] == "basketball"
    phase = s["phase"]
    event = {"type": action, "period": s["period"],
             "clock_ms": round(elapsed(s, now_ms)) if c["enabled"] else None,
             "period_length_min": s["period_length_min"], "period_count": s["period_count"],
             "occurred_at": now_ms, "sport": s["sport"], "period_duration_ms": period_ms(s)}
    if action in ("score", "score_correction"):
        points = data.get("points")
        values = (1, 2, 3) if basketball else (1,)
        if action == "score_correction":
            values = tuple(-v for v in values)
        if data.get("team") not in ("home", "away") or points not in values or isinstance(points, bool):
            raise RuleError("invalid_score")
        event.update(team=data["team"], points=int(points))
        if data.get("detail") is not None:
            # Football: converted penalty. Basketball: made free throw (1 point).
            allowed = "free_throw" if basketball else "penalty"
            if action != "score" or data["detail"] != allowed or (basketball and points != 1):
                raise RuleError("invalid_value")
            event["detail"] = allowed
    elif action.removesuffix("_correction") in BASKETBALL_STATS:
        if not basketball or data.get("team") not in ("home", "away"):
            raise RuleError("invalid_value")
        event.update(team=data["team"])
        if not action.endswith("_correction"):
            event["player"] = player_snapshot(s, data["team"], data.get("player_id"))
    elif action == "score_adjust":
        # Admin correction of a wrong score: any non-zero change, team level.
        delta = integer(data.get("delta"), -500, 500)
        if data.get("team") not in ("home", "away") or delta == 0:
            raise RuleError("invalid_value")
        event.update(team=data["team"], points=delta)
    elif action.removesuffix("_correction") in FOOTBALL_EVENTS:
        if basketball or data.get("team") not in ("home", "away"):
            raise RuleError("invalid_value")
        event.update(team=data["team"])
        if not action.endswith("_correction"):
            event["player"] = player_snapshot(s, data["team"], data.get("player_id"))
    elif action in ("red_card", "red_card_correction", "yellow_card", "yellow_card_correction"):
        if basketball or data.get("team") not in ("home", "away"):
            raise RuleError("invalid_value")
        event.update(team=data["team"], cards=-1 if action.endswith("_correction") else 1)
    elif action in ("team_foul", "team_foul_correction", "timeout", "timeout_correction"):
        if not basketball or data.get("team") not in ("home", "away"):
            raise RuleError("invalid_value")
        if action == "team_foul" and foul_mode(s) not in ("team", "both"):
            raise RuleError("invalid_value")
        event.update(team=data["team"], count=-1 if action.endswith("_correction") else 1)
        if action == "timeout" and phase == "period_running":
            c.update(elapsed_ms=round(elapsed(s, now_ms)), running=False, started_at=None)
    elif action in ("technical_foul", "technical_foul_correction"):
        team = data.get("team")
        if not basketball or team not in ("home", "away"):
            raise RuleError("invalid_value")
        event.update(team=team, technical=True)
        if action == "technical_foul":
            player = foul_player(s, team, data)
            # A player's technical is a personal and team foul (FIBA); a coach/bench one is neither.
            event.update(player=player, counts_team=player is not None and foul_mode(s) in ("team", "both"))
    elif action == "possession":
        if not basketball or data.get("team") not in ("home", "away", None):
            raise RuleError("invalid_value")
        s["possession"] = data.get("team")
        event.update(team=data.get("team"))
    elif action == "lineup":
        team, ids = data.get("team"), data.get("player_ids")
        if team not in ("home", "away") or not isinstance(ids, list) or len(ids) > LINEUP_MAX[s["sport"]] or len(set(map(str, ids))) != len(ids):
            raise RuleError("invalid_value")
        squad = {p["id"]: p for p in s[team].get("squad", [])}
        if any(i not in squad for i in ids):
            raise RuleError("player_not_found")
        before_ids = s[team].get("on_court", [])
        s[team]["on_court"] = list(ids)
        event.update(team=team, entered=[deepcopy(squad[i]) for i in ids if i not in before_ids],
                     left=[deepcopy(squad[i]) for i in before_ids if i not in ids and i in squad])
    elif action in ("personal_foul", "personal_foul_correction", "assign_foul_player"):
        team = data.get("team")
        if not basketball or team not in ("home", "away"):
            raise RuleError("invalid_value")
        if action == "personal_foul" and foul_mode(s) not in ("personal", "both"):
            raise RuleError("invalid_value")
        event.update(team=team)
        if action == "personal_foul":
            event.update(player=foul_player(s, team, data), counts_team=foul_mode(s) == "both")
        elif action == "assign_foul_player":
            event.update(player=foul_player(s, team, data), target=data.get("event_id"))
    elif action == "squad":
        team, players = data.get("team"), data.get("players")
        if team not in ("home", "away") or not isinstance(players, list) or len(players) > 40:
            raise RuleError("invalid_squad")
        cleaned, ids, numbers = [], set(), set()
        for player in players:
            if not isinstance(player, dict) or set(player) != {"id", "number", "name"}:
                raise RuleError("invalid_squad")
            try:
                identifier = str(UUID(player["id"]))
            except (ValueError, TypeError, AttributeError):
                raise RuleError("invalid_squad")
            jersey, name = player["number"], player["name"]
            if not isinstance(jersey, str) or not isinstance(name, str):
                raise RuleError("invalid_squad")
            jersey, name = jersey.strip(), name.strip()
            if (jersey and not re.fullmatch(r"[0-9]{1,3}", jersey)) or len(name) > 60 or not (jersey or name):
                raise RuleError("invalid_squad")
            if basketball and not jersey:
                raise RuleError("player_number_required")
            jersey = str(int(jersey)) if jersey else ""
            if identifier in ids or (jersey and jersey in numbers):
                raise RuleError("duplicate_player")
            ids.add(identifier)
            if jersey:
                numbers.add(jersey)
            cleaned.append({"id": identifier, "number": jersey, "name": name})
        private = s[team].get("foul_players", [])
        for player in cleaned:
            match = next((p for p in private if player["number"] and p["number"] == player["number"]), None)
            if match:
                known = {p["id"] for p in s[team].get("squad", []) + private}
                if player["id"] in known and player["id"] != match["id"]:
                    raise RuleError("duplicate_player")
                player["id"] = match["id"]
        if len({p["id"] for p in cleaned}) != len(cleaned):
            raise RuleError("duplicate_player")
        s[team]["squad"] = cleaned
        if s[team].get("on_court"):
            s[team]["on_court"] = [i for i in s[team]["on_court"] if any(p["id"] == i for p in cleaned)]
        if private:
            by_id = {p["id"]: p for p in cleaned}
            s[team]["foul_players"] = [deepcopy(by_id.get(p["id"], p)) for p in private]
        event.update(team=team)
    elif action == "assign_player":
        if data.get("team") not in ("home", "away"):
            raise RuleError("invalid_value")
        event.update(team=data["team"], player=player_snapshot(s, data["team"], data.get("player_id")), target=data.get("event_id"))
    elif action in ("period_start", "overtime_start"):
        overtime = action == "overtime_start"
        if overtime and (not basketball or phase != "break" or s["period"] < s["period_count"]):
            raise RuleError("invalid_transition")
        if not overtime and (phase not in ("pre_game", "break") or s["period"] >= s["period_count"]):
            raise RuleError("invalid_transition")
        s.update(phase="period_running", period=s["period"] + 1)
        c.update(elapsed_ms=0, running=c["enabled"] and not basketball, started_at=now_ms if c["enabled"] and not basketball else None)
        event["period"] = s["period"]
        event["clock_ms"] = 0 if c["enabled"] else None
        event["period_duration_ms"] = period_ms(s)
    elif action in ("period_end", "game_end"):
        if action == "period_end" and (phase != "period_running" or (not basketball and s["period"] >= s["period_count"])):
            raise RuleError("invalid_transition")
        if action == "game_end" and phase == "finished":
            raise RuleError("invalid_transition")
        c.update(elapsed_ms=round(elapsed(s, now_ms)), running=False, started_at=None)
        s["phase"] = "finished" if action == "game_end" else "break"
    elif action in ("clock_start", "clock_stop", "clock_set"):
        if not basketball or not c["enabled"] or phase == "finished":
            raise RuleError("invalid_transition")
        if action == "clock_set":
            remaining = integer(data.get("remaining_ms"), 0, period_ms(s))
            c.update(elapsed_ms=period_ms(s) - remaining, started_at=now_ms if c["running"] else None)
        else:
            if phase != "period_running":
                raise RuleError("invalid_transition")
            value = round(elapsed(s, now_ms))
            running = action == "clock_start" and value < period_ms(s)
            c.update(elapsed_ms=value, running=running, started_at=now_ms if running else None)
    elif action == "clock_adjust":
        if not c["enabled"]:
            raise RuleError("clock_disabled")
        seconds = number(data.get("seconds"), -3600, 3600)
        c.update(elapsed_ms=max(0, round(elapsed(s, now_ms) + seconds * 1000 * (-1 if basketball else 1))),
                 started_at=now_ms if c["running"] else None)
    elif action == "settings":
        allowed = {"period_count", "period_length_min", "clock_enabled", "clock_elapsed_ms", "home", "away", "team_fouls_enabled", "foul_mode"}
        if set(data) - allowed:
            raise RuleError("invalid_value")
        if "foul_mode" in data:
            if not basketball or data["foul_mode"] not in ("team", "personal", "both", "off") or "team_fouls_enabled" in data:
                raise RuleError("invalid_value")
            s["foul_mode"] = data["foul_mode"]
            s["team_fouls_enabled"] = data["foul_mode"] in ("team", "both")
        if "team_fouls_enabled" in data:
            if not basketball:
                raise RuleError("invalid_value")
            s["team_fouls_enabled"] = boolean(data["team_fouls_enabled"])
            personal = foul_mode(s) in ("personal", "both")
            s["foul_mode"] = ("both" if personal else "team") if s["team_fouls_enabled"] else ("personal" if personal else "off")
        if "period_count" in data:
            s["period_count"] = integer(data["period_count"], max(1, min(s["period"], s["period_count"]) if basketball else s["period"]), 12)
        if "period_length_min" in data:
            s["period_length_min"] = integer(data["period_length_min"], 1, 120)
        for team in ("home", "away"):
            if team in data:
                t = data[team]
                if not isinstance(t, dict) or set(t) - {"name", "short", "color"}:
                    raise RuleError("invalid_value")
                if "name" in t:
                    s[team]["name"] = text(t["name"], 60)
                if "short" in t:
                    s[team]["short"] = text(t["short"], SHORT_MAX).upper()
                if "color" in t:
                    if not isinstance(t["color"], str) or not re.fullmatch(r"#[0-9a-fA-F]{6}", t["color"]):
                        raise RuleError("invalid_value")
                    s[team]["color"] = t["color"].lower()
        if "clock_enabled" in data:
            enabled = boolean(data["clock_enabled"])
            c["elapsed_ms"] = round(elapsed(s, now_ms))
            if enabled and not c["enabled"] and phase == "period_running" and "clock_elapsed_ms" not in data:
                raise RuleError("clock_value_required")
            c.update(enabled=enabled, running=enabled and phase == "period_running" and not basketball,
                     started_at=now_ms if enabled and phase == "period_running" and not basketball else None)
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
    if action in ("score", "red_card", "yellow_card"):
        event["player"] = player_snapshot(s, data["team"], data.get("player_id"))
        if basketball and action == "score" and event["player"]:
            if not event["player"].get("number"):
                raise RuleError("player_number_required")
    normalize_clock(s, now_ms)
    # Store only changed fields: undoing a goal must never rewind a running clock.
    # Fields added by this action (e.g. possession) are restored to None.
    before = {key: deepcopy(state.get(key)) for key in s if state.get(key) != s[key]}
    return s, event, before
