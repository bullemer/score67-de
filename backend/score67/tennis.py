"""Tennis score state. A point/game and any resulting set or match are atomic.

This lets the existing event undo restore the entire score, including service.
"""
from copy import deepcopy


def initial(category="women", best_of=3, mode="detailed", final_tiebreak=7):
    return {"category": category, "best_of": best_of, "mode": mode,
            "final_tiebreak": final_tiebreak, "points": [0, 0], "games": [0, 0],
            "sets": [0, 0], "set_scores": [], "server": 0, "tiebreak": False,
            "tiebreak_first": 0, "winner": None}


def point_labels(t):
    points = t["points"]
    if t["tiebreak"]:
        return [str(p) for p in points]
    if min(points) >= 3:
        if points[0] == points[1]:
            return ["40", "40"]
        return ["AD" if p == max(points) else "40" for p in points]
    return [str((0, 15, 30, 40)[min(p, 3)]) for p in points]


def target(t):
    return t["final_tiebreak"] if sum(t["sets"]) == t["best_of"] - 1 else 7


def finish_set(s, winner, tiebreak=None):
    t = s["tennis"]
    result = {"games": list(t["games"])}
    if tiebreak is not None:
        result["tiebreak"] = list(tiebreak)
    t["set_scores"].append(result)
    t["sets"][winner] += 1
    t.update(games=[0, 0], points=[0, 0], tiebreak=False)
    if t["sets"][winner] == t["best_of"] // 2 + 1:
        t["winner"] = winner
        s["phase"] = "finished"
    else:
        s["period"] = len(t["set_scores"]) + 1


def game(s, winner):
    t = s["tennis"]
    t["games"][winner] += 1
    t["points"] = [0, 0]
    t["server"] = 1 - t["server"]
    if t["games"][winner] >= 6 and t["games"][winner] - t["games"][1 - winner] >= 2:
        finish_set(s, winner)
    elif t["games"] == [6, 6]:
        t["tiebreak"] = True
        t["tiebreak_first"] = t["server"]


def apply(s, action, data, error):
    t = s["tennis"]
    if action == "period_start":
        if s["phase"] != "pre_game":
            raise error("invalid_transition")
        s.update(phase="period_running", period=1)
        return {}
    if action == "game_end":
        if s["phase"] == "finished":
            raise error("invalid_transition")
        s["phase"] = "finished"
        return {}
    if action == "tennis_server":
        if s["phase"] != "pre_game" or data.get("team") not in ("home", "away"):
            raise error("invalid_transition")
        t["server"] = 0 if data["team"] == "home" else 1
        return {"team": data["team"]}
    if action not in ("tennis_point", "tennis_game", "tennis_set"):
        raise error("unsupported_action")
    if s["phase"] != "period_running":
        raise error("invalid_transition")
    if action == "tennis_set":
        if t["mode"] != "simple" or t["games"] != [0, 0]:
            raise error("invalid_transition")
        scores = data.get("games")
        if not isinstance(scores, list) or len(scores) != 2 or any(type(v) is not int or not 0 <= v <= 7 for v in scores):
            raise error("invalid_value")
        high, low = max(scores), min(scores)
        if not ((high == 6 and low <= 4) or (high == 7 and low in (5, 6))):
            raise error("invalid_value")
        winner = 0 if scores[0] > scores[1] else 1
        tb = data.get("tiebreak")
        if tb is not None:
            if low != 6 or not isinstance(tb, list) or len(tb) != 2 or any(type(v) is not int or v < 0 for v in tb):
                raise error("invalid_value")
            if tb[winner] < target(t) or tb[winner] - tb[1 - winner] < 2 or (tb[winner] > target(t) and tb[winner] - tb[1 - winner] != 2):
                raise error("invalid_value")
        t["games"] = list(scores)
        t["server"] = (t["server"] + sum(scores)) % 2
        finish_set(s, winner, tb)
        return {"team": ("home", "away")[winner], "set_score": deepcopy(t["set_scores"][-1])}
    if data.get("team") not in ("home", "away"):
        raise error("invalid_value")
    winner = 0 if data["team"] == "home" else 1
    if action == "tennis_game":
        if t["mode"] != "simple" or t["tiebreak"]:
            raise error("invalid_transition")
        game(s, winner)
    else:
        if t["mode"] != "detailed" and not t["tiebreak"]:
            raise error("invalid_transition")
        t["points"][winner] += 1
        if t["tiebreak"]:
            if t["points"][winner] >= target(t) and t["points"][winner] - t["points"][1 - winner] >= 2:
                tb = list(t["points"])
                t["games"][winner] += 1
                t["server"] = 1 - t["tiebreak_first"]
                finish_set(s, winner, tb)
            else:
                total = sum(t["points"])
                t["server"] = (t["tiebreak_first"] + (total + 1) // 2) % 2
        elif t["points"][winner] >= 4 and t["points"][winner] - t["points"][1 - winner] >= 2:
            game(s, winner)
    return {"team": data["team"], "tennis_score": {"points": point_labels(t), "games": list(t["games"]), "sets": list(t["sets"])}}
