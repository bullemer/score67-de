"""Link previews (Open Graph) for shared scoreboards.

WhatsApp, Facebook & co. read only the server-rendered <head>: without
og:title/og:description/og:image a shared ticker link showed a bare
"Score67". ``summary`` builds the texts from the public game state and
``render`` draws the 1200 × 630 card (teams, colours, logos, score, status)
those apps show. Fonts are bundled (the container has none)."""
import io
from datetime import datetime, timezone
from pathlib import Path

FONTS = Path(__file__).parent / "fonts"
WIDTH, HEIGHT = 1200, 630
BACKGROUND, MUTED, ACCENT = "#0b1018", "#9fb0c4", "#b6f36e"
TEXTS = {
    "de": {"live": "LIVE", "break": "PAUSE", "finished": "ENDSTAND", "pre_game": "VORSCHAU",
           "football": "Fußball", "basketball": "Basketball", "half": "{n}. Halbzeit", "quarter": "{n}. Viertel",
           "period": "Periode {n}/{count}", "ot": "Verlängerung {n}", "kickoff": "Anpfiff",
           "tagline": "Live-Spielstand – ohne App, ohne Anmeldung.", "private": "Privates Spiel",
           "private_text": "Dieses Spiel ist privat.", "site": "Live-Scoreboard für Fußball und Basketball",
           "site_text": "Vom Handy steuern, per Link teilen, im Stream zeigen."},
    "en": {"live": "LIVE", "break": "BREAK", "finished": "FULL TIME", "pre_game": "UPCOMING",
           "football": "Football", "basketball": "Basketball", "half": "Half {n}", "quarter": "Quarter {n}",
           "period": "Period {n}/{count}", "ot": "Overtime {n}", "kickoff": "Kick-off",
           "tagline": "Live score – no app, no sign-up.", "private": "Private game",
           "private_text": "This game is private.", "site": "Live scoreboard for football and basketball",
           "site_text": "Control from your phone, share a link, show it in your stream."},
}


def words(language):
    return TEXTS.get(language, TEXTS["de"])


def berlin(ms):
    when = datetime.fromtimestamp(ms / 1000, timezone.utc)
    try:
        from zoneinfo import ZoneInfo
        when = when.astimezone(ZoneInfo("Europe/Berlin"))
    except Exception:  # noqa: BLE001 - no tz database: UTC is still a correct time
        pass
    return when.strftime("%d.%m.%Y %H:%M")


def period_name(s, w):
    period, count = s.get("period") or 0, s.get("period_count") or 1
    if not period or count == 1:
        return ""
    if s.get("sport") == "basketball" and period > count:
        return w["ot"].format(n=period - count)
    key = "half" if count == 2 else "quarter" if count == 4 else "period"
    return w[key].format(n=period, count=count)


def status(s, w):
    phase = s.get("phase")
    if phase == "finished":
        return w["finished"]
    if phase == "break":
        return w["break"]
    if phase == "period_running":
        return w["live"]
    return w["pre_game"]


def summary(s, language):
    """(title, description) for a public game."""
    w = words(language)
    home, away = s["home"], s["away"]
    if s.get("phase") in ("pre_game", "no_match"):
        title = f"{home['name']} – {away['name']}"
        if s.get("scheduled_at"):
            title += f" · {berlin(s['scheduled_at'])}"
    else:
        title = f"{home['name']} {home.get('score', 0)} : {away.get('score', 0)} {away['name']} · {status(s, w)}"
    facts = [w.get(s.get("sport"), ""), period_name(s, w) if s.get("phase") != "finished" else ""]
    if s.get("location"):
        facts.append(s["location"].get("label") or "")
    lead = " · ".join(f for f in facts if f)
    def sentence(text):
        text = (text or "").strip()
        return text if not text or text[-1] in ".!?" else text + "."
    description = " ".join(part for part in (sentence(lead), sentence(s.get("description")), w["tagline"]) if part)
    return title, description[:300]


def font(size, bold=True):
    from PIL import ImageFont
    return ImageFont.truetype(str(FONTS / ("DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf")), size)


def fitted(draw, text, width, size, bold=True, low=26):
    """The largest font (down to ``low``) in which ``text`` fits ``width``; long names are shortened."""
    while size > low and draw.textlength(text, font=font(size, bold)) > width:
        size -= 2
    f = font(size, bold)
    while draw.textlength(text, font=f) > width and len(text) > 4:
        text = text[:-2].rstrip() + "…"
    return text, f


def brand(draw, x, y, size=44):
    f = font(size)
    draw.text((x, y), "SCORE", font=f, fill="#f7fafc")
    draw.text((x + draw.textlength("SCORE", font=f), y), "67", font=f, fill=ACCENT)


def render(s=None, language="de", logo=None):
    """PNG bytes of the preview card; ``s`` None draws the generic site card.
    ``logo(path)`` returns a stored team logo's bytes or None."""
    from PIL import Image, ImageDraw
    w = words(language)
    image = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    draw = ImageDraw.Draw(image)
    brand(draw, 60, 44)
    if s is None:
        draw.rectangle((0, HEIGHT - 12, WIDTH, HEIGHT), fill=ACCENT)
        text, f = fitted(draw, w["site"], WIDTH - 120, 64)
        draw.text((60, 230), text, font=f, fill="#f7fafc")
        draw.text((60, 340), w["site_text"], font=font(34, False), fill=MUTED)
        draw.text((60, HEIGHT - 90), "score67.de", font=font(34), fill=ACCENT)
        return png(image)
    label = status(s, w)
    pill = font(30)
    tw = draw.textlength(label, font=pill)
    fill = "#dc2626" if label == w["live"] else "#d97706" if label == w["break"] else "#1f2937"
    draw.rounded_rectangle((WIDTH - 60 - tw - 40, 44, WIDTH - 60, 96), radius=12, fill=fill)
    draw.text((WIDTH - 60 - tw - 20, 52), label, font=pill, fill="#ffffff")
    column = (WIDTH - 120 - 80) // 2
    for index, team in enumerate(("home", "away")):
        t = s[team]
        x = 60 if index == 0 else WIDTH - 60 - column
        color = t.get("color") or "#c8102e"
        draw.rectangle((x, 150, x + column, 162), fill=color)
        name_x, name_width = x, column
        if t.get("logo") and logo:
            data = logo(t["logo"])
            if data:
                try:
                    with Image.open(io.BytesIO(data)) as mark:
                        mark = mark.convert("RGBA")
                        mark.thumbnail((84, 84))
                        image.paste(mark, (x, 186), mark)
                        name_x, name_width = x + 100, column - 100
                except Exception:  # noqa: BLE001 - a broken logo must not break the preview
                    pass
        text, f = fitted(draw, t["name"], name_width, 52)
        draw.text((name_x, 196), text, font=f, fill="#f7fafc")
        if s.get("phase") not in ("pre_game", "no_match"):
            score = str(t.get("score", 0))
            big = font(190)
            sw = draw.textlength(score, font=big)
            draw.text((x + (column - sw) / 2, 290), score, font=big, fill="#f7fafc")
    if s.get("phase") not in ("pre_game", "no_match"):
        colon = font(120)
        draw.text(((WIDTH - draw.textlength(":", font=colon)) / 2, 330), ":", font=colon, fill="#5c6b7d")
    elif s.get("scheduled_at"):
        when = f"{w['kickoff']}: {berlin(s['scheduled_at'])}"
        f = font(50)
        draw.text(((WIDTH - draw.textlength(when, font=f)) / 2, 370), when, font=f, fill=ACCENT)
    facts = " · ".join(f for f in (w.get(s.get("sport"), ""), period_name(s, w)) if f)
    draw.text((60, HEIGHT - 82), facts, font=font(32, False), fill=MUTED)
    site = font(32)
    draw.text((WIDTH - 60 - draw.textlength("score67.de", font=site), HEIGHT - 82), "score67.de", font=site, fill=ACCENT)
    return png(image)


def png(image):
    out = io.BytesIO()
    image.save(out, "PNG", optimize=True)
    return out.getvalue()
