"""Messages on LED panels: a greeting, a cheer or a small graphic that
interrupts the score for a few seconds (docs/DISPLAY-FIRMWARE.md, "Nachrichten").

The server only sends data; the panel draws it (reference: static/led.mjs).
One message per scoreboard at a time, kept in memory: they last seconds, so a
restart losing one does not matter."""
import re
import secrets
import time

ICONS = ("heart", "star", "basketball", "football", "trophy", "flame")
EFFECTS = ("static", "blink", "rainbow")
KINDS = ("text", "periods", "lead")
MIN_SECONDS, MAX_SECONDS = 3, 60
MAX_TEXT = 60
LEAD_COLUMNS = 62   # one column per pixel inside a 1 px border on 64 px
# Characters the panel font has (3×5, static/led.mjs SMALL); umlauts spelled out.
_SPELL = {"Ä": "AE", "Ö": "OE", "Ü": "UE", "ß": "SS", "’": "'", "–": "-", "—": "-"}
_ALLOWED = re.compile(r"[^A-Z0-9 !?.,:'/<>+\-=#()*]")

_current: dict[str, dict] = {}


def clean_text(text):
    """Upper case, umlauts spelled out, characters the panel cannot draw dropped."""
    out = "".join(_SPELL.get(ch, ch) for ch in (text or "").upper())
    return re.sub(r"\s+", " ", _ALLOWED.sub("", out)).strip()[:MAX_TEXT]


def team(s, side):
    t = s.get(side) or {}
    return {"short": (t.get("short") or "")[:3].upper(), "color": t.get("color") or "#ffffff"}


SCORING = ("score", "score_correction", "score_adjust")


def score_timeline(events):
    """(period, home, away) after every scoring entry: the game's score history,
    summed from the entries (undone ones are left out by the caller)."""
    home = away = 0
    points = [(1, 0, 0)]
    for e in events:
        p = e.payload or {}
        if p.get("type") not in SCORING or p.get("team") not in ("home", "away"):
            continue
        if p["team"] == "home":
            home += int(p.get("points") or 0)
        else:
            away += int(p.get("points") or 0)
        points.append((int(p.get("period") or 1), home, away))
    return points


def period_points(s, events):
    """Points per period [[home, guest], …] from the score history."""
    count = max(int(s.get("period") or 0), 1)
    timeline = score_timeline(events)
    result, before = [], (0, 0)
    for p in range(1, count + 1):
        upto = [(h, g) for period, h, g in timeline if period <= p]
        end = upto[-1] if upto else before
        result.append([max(0, end[0] - before[0]), max(0, end[1] - before[1])])
        before = end
    return result


def lead_curve(s, events, columns=LEAD_COLUMNS):
    """Home lead (negative: guest leads) over the game, resampled to ``columns``."""
    leads = [h - g for _, h, g in score_timeline(events)]
    if len(leads) < 2:
        return [leads[0] if leads else 0] * columns
    return [leads[round(i * (len(leads) - 1) / (columns - 1))] for i in range(columns)]


def create(slug, s, events, *, kind, text=None, icon=None, effect=None, color=None, seconds=8):
    """Validated message for the board, replacing the one shown. Raises ValueError."""
    if kind not in KINDS:
        raise ValueError("kind")
    seconds = max(MIN_SECONDS, min(MAX_SECONDS, int(seconds)))
    msg = {"id": secrets.token_hex(4), "kind": kind}
    if kind == "text":
        text = clean_text(text)
        if icon is not None and icon not in ICONS:
            raise ValueError("icon")
        if not text and not icon:
            raise ValueError("text")
        if effect not in (None, *EFFECTS):
            raise ValueError("effect")
        if color is not None and not re.fullmatch(r"#[0-9a-fA-F]{6}", color):
            raise ValueError("color")
        msg.update(text=text, icon=icon, effect=effect or "static", color=color or "#ffa31a")
    else:
        msg.update(home=team(s, "home"), guest=team(s, "away"))
        if kind == "periods":
            msg["periods"] = period_points(s, events)
        else:
            msg["lead"] = lead_curve(s, events)
    msg["until"] = time.time() + seconds
    _current[slug] = msg
    return feed_part(slug)


def clear(slug):
    _current.pop(slug, None)


def active(slug, now=None):
    msg = _current.get(slug)
    if msg and msg["until"] <= (now or time.time()):
        _current.pop(slug, None)
        return None
    return msg


def feed_part(slug, now=None):
    """The ``msg`` of the compact feed: like the clock, ``ms`` left at server_now."""
    now = now or time.time()
    msg = active(slug, now)
    if not msg:
        return None
    out = {k: v for k, v in msg.items() if k != "until" and v is not None}
    out["ms"] = max(0, round((msg["until"] - now) * 1000))
    return out


def signature(slug):
    """Changes when a message starts, is replaced or ends (display sockets)."""
    msg = active(slug)
    return msg["id"] if msg else None
