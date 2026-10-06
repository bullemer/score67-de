"""Game facts from league websites, to prefill a new game: teams, kickoff, venue,
league, game number. German sites only for now (fussball.de, basketball-bund.net);
other countries can add a parser to SOURCES.

Only IDs are taken from the pasted link; the request URL is always built here,
so a user can never make the server fetch an arbitrary address."""
from datetime import datetime
import hashlib
import html
import io
import json
import re
import threading
import time
import unicodedata
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

BERLIN = ZoneInfo("Europe/Berlin")
USER_AGENT = "Mozilla/5.0 (compatible; Score67/1.0; +https://score67.de)"
TIMEOUT = 10


class FixtureError(Exception):
    """code: fixture_url (not a supported game link), fixture_not_found, fixture_unavailable."""
    def __init__(self, code):
        super().__init__(code)
        self.code = code


def fetch(url, accept="text/html"):
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept": accept, "Accept-Language": "de"})
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return response.read(3_000_000)
    except urllib.error.HTTPError as e:
        raise FixtureError("fixture_not_found" if e.code == 404 else "fixture_unavailable") from e
    except (OSError, ValueError) as e:
        raise FixtureError("fixture_unavailable") from e


def clean(value):
    return re.sub(r"\s+", " ", html.unescape(value or "")).strip()


# --- Short names -----------------------------------------------------------

# Club-type words that say nothing about the club ("SV Groß Borstel" → GRO).
GENERIC = {"sv", "fc", "tsv", "sc", "vfl", "vfb", "tus", "sg", "spvgg", "bc", "tv", "mtv", "ssv", "fsv", "tsg",
           "ev", "e.v.", "e.v", "eV", "bsc", "fv", "sv.", "sportverein", "club", "verein", "von", "der", "die", "das",
           "1.", "fk", "djk", "esv", "psv", "tura", "ttv", "bv", "jsg", "jfv", "tbv", "post", "turnerschaft"}
TEAM_SUFFIX = re.compile(r"\s+(\d+\.\s?\S.*|\(\d+\)|[IVX]+)$")


def team_parts(name):
    """'Urania 3.C-Jun. (J1) 7er' → ('Urania', '3.C-Jun. (J1) 7er'); 'BC Hamburg e.V. (1)' → ('BC Hamburg e.V.', '(1)')."""
    match = TEAM_SUFFIX.search(name)
    return (name[:match.start()].strip(), match.group(1).strip()) if match else (name.strip(), "")


def ascii_upper(value):
    value = value.replace("ß", "SS").replace("ẞ", "SS")
    return "".join(c for c in unicodedata.normalize("NFKD", value) if c.isascii() and c.isalnum()).upper()


def guess_short(name, limit=3):
    """Three letters for the scoreboard. Acronyms are kept (HSV, DSC, UH-Adler → UHA);
    otherwise the first letters of the first word that is not a club-type word."""
    club = team_parts(name)[0]
    club = re.sub(r"\b(von|v\.)\s+\d{2,4}\b|\b\d{2,4}\b|\be\.\s?V\.?", " ", club)
    words = [w for w in re.split(r"[\s\-/]+", club) if w and any(c.isalpha() for c in w)]
    distinctive = [w for w in words if w.lower().strip(".") not in GENERIC and w.lower() not in GENERIC] or words
    if not distinctive:
        return ascii_upper(name)[:limit] or "?"
    first = distinctive[0]
    letters = ascii_upper(first)
    if first.isupper() and len(letters) <= 4:
        letters += "".join(ascii_upper(w)[:1] for w in distinctive[1:])
    # Too short ("Al-Huda" → AL): fill up from the next words.
    for word in distinctive[1:]:
        if len(letters) >= limit:
            break
        letters += ascii_upper(word)
    return letters[:limit]


def distinct_shorts(home, away):
    """Two teams of the same club (or town) must not get the same short name."""
    if home["short"] != away["short"]:
        return
    for team in (home, away):
        number = re.search(r"\d+", team.get("team") or "")
        if number:
            team["short"] = (team["short"][:2] + number.group(0))[:3]
    if home["short"] == away["short"]:
        away["short"] = away["short"][:2] + "2"


# --- fussball.de -------------------------------------------------------------

FUSSBALL_ID = re.compile(r"fussball\.de/.*?/spiel/([0-9A-Z]{32})")
# Glyph outline → character for the obfuscation web font fussball.de uses for date
# and time (Fortuna bold; the code points change, the outlines do not). Built from
# the plain date in the page title; see tests for the check against a live page.
GLYPHS = {
    "0c5231417dd44245": ".", "6cae51636d184279": "0", "26081db18a20f7bf": "1", "98765e0ebadb2111": "2",
    "6996ae85de53f430": "3", "9767cc4ad474d8d5": "4", "6cdc2c186691a588": "5", "03538b67298683a7": "6",
    "12936536e0cb8afd": "7", "e7f2135cea8c7327": "8", "01bd0da233ad0476": "9", "8d52cbfed674b580": ":",
}
_fonts, _fonts_lock = {}, threading.Lock()


def glyph_key(glyph):
    if glyph.numberOfContours <= 0:
        return None
    return hashlib.sha1(json.dumps([list(glyph.endPtsOfContours), [list(p) for p in glyph.coordinates],
                                    [int(f) & 1 for f in glyph.flags]]).encode()).hexdigest()[:16]


def font_map(font_id):
    """Code point → glyph key for one obfuscation font (cached; the font for an ID never changes)."""
    with _fonts_lock:
        if font_id in _fonts:
            return _fonts[font_id]
    from fontTools.ttLib import TTFont
    font = TTFont(io.BytesIO(fetch(f"https://www.fussball.de/export.fontface/-/format/ttf/id/{font_id}/type/font", "*/*")))
    glyf = font["glyf"]
    mapping = {cp: glyph_key(glyf[name]) for cp, name in font.getBestCmap().items()}
    with _fonts_lock:
        if len(_fonts) > 200:
            _fonts.clear()
        _fonts[font_id] = mapping
    return mapping


def deobfuscate(font_id, value, learned):
    mapping = font_map(font_id)
    out = []
    for char in html.unescape(value):
        if ord(char) < 0xE000:
            out.append(char)
        else:
            key = mapping.get(ord(char))
            out.append(GLYPHS.get(key) or learned.get(key) or "?")
    return "".join(out)


def football_format(age_group, competition, team_names):
    """Suggested playing time and players on the pitch (DFB youth defaults); the user can change them."""
    if "futsal" in competition.lower() or "halle" in competition.lower():
        return None
    youth = re.match(r"([A-G])-Jun", age_group)
    minutes = {"A": 45, "B": 40, "C": 35, "D": 30, "E": 25, "F": 20, "G": 15}.get(youth.group(1)) if youth else (
        40 if re.search(r"Ü\s?\d|Alte Herren|Senioren", age_group) else 45)
    lineup = {"D": 9, "E": 7, "F": 5, "G": 5}.get(youth.group(1), 11) if youth else 11
    players = re.search(r"\b(\d{1,2})er\b", " ".join(team_names))
    if players and 3 <= int(players.group(1)) <= 11:
        lineup = int(players.group(1))
    return {"period_count": 2, "period_length_min": minutes, "lineup_size": lineup}


def football(game_id):
    url = f"https://www.fussball.de/spiel/-/spiel/{game_id}"
    page = fetch(url).decode("utf-8", "replace")
    title = re.search(r'property="og:title" content="([^"]*)"', page)
    names = [clean(n) for n in re.findall(r'class="team-name">\s*<a[^>]*>([^<]*)</a>', page)]
    if not title or len(names) < 2:
        raise FixtureError("fixture_not_found")
    canonical = re.search(r'property="og:url" content="([^"]+)"', page)
    # spiel.<season>.<association>.<competition>.<age group>.<league>.<area>.<id>
    tracking = re.search(r"trackingcountername='spiel\.([^']*)'", page)
    parts = tracking.group(1).split(".") if tracking else []
    season, association, competition, age_group, league, area = (parts + [""] * 6)[:6]
    stage = page[page.find('class="stage-header"'):page.find('class="stage-body"')]
    group = re.search(r'class="competition">([^<]*)', stage)
    venue = re.search(r'class="location"[^>]*>([^<]*)', stage)
    number = re.search(r"<span>Spiel:</span><span>([^<]*)</span>", page)
    game_number, _, matchday = clean(number.group(1) if number else "").partition(" / ")

    # Date and time are drawn with a scrambled font. The plain date in the title
    # teaches the digits it contains, the fixed table covers the rest.
    date_plain = re.search(r"(\d\d)\.(\d\d)\.(\d{4})\s*$", clean(title.group(1)))
    learned, date_text, time_text = {}, "", ""
    date_block = re.search(r'<div class="date">(.*?)</div>', stage, re.S)
    if date_block:
        spans = re.findall(r'data-obfuscation="(\w+)"[^>]*>([^<]*)', date_block.group(1))
        try:
            decoded = [deobfuscate(font_id, value, learned) for font_id, value in spans]
            if date_plain:
                font_id, value = spans[0]
                mapping = font_map(font_id)
                glyphs = [mapping.get(ord(c)) for c in html.unescape(value) if ord(c) >= 0xE000]
                for key, char in zip(glyphs[-10:], ".".join(date_plain.groups())):
                    learned.setdefault(key, char)
                decoded = [deobfuscate(font_id, value, learned) for font_id, value in spans]
            text = " ".join(decoded)
            date_text = (re.search(r"\d\d\.\d\d\.\d{4}", text) or [""])[0]
            time_text = (re.search(r"\b\d\d:\d\d\b", text) or [""])[0]
        except FixtureError:
            pass  # Font unavailable: keep the date from the title, leave the time empty.
    if not date_text and date_plain:
        date_text = ".".join(date_plain.groups())

    # Title: "<home> - <away> Ergebnis: Bezirksliga - Herren - 11.10.2026"
    heading = clean(title.group(1)).partition("Ergebnis:")[2].strip()
    tier = heading.split(" - ")[0].strip() if heading else league
    league_name = tier if not age_group or age_group in tier else f"{tier} {age_group}"
    home, away = ({"name": n, "club": team_parts(n)[0], "team": team_parts(n)[1], "short": guess_short(n)} for n in names[:2])
    address = clean(venue.group(1)) if venue else ""
    return {
        "source": "fussball.de", "sport": "football", "external_id": game_id,
        "url": canonical.group(1) if canonical else url,
        "game_number": game_number, "matchday": matchday.replace("Spielklasse: ", ""),
        "league": league_name,
        "group": clean(group.group(1)) if group else "", "competition": competition,
        "age_group": age_group, "season": re.sub(r"^(\d\d)/(\d\d)$", r"20\1/20\2", season),
        "association": association, "area": area,
        "date": date_text, "time": time_text,
        "venue": venue_parts(address),
        "home": home, "away": away,
        "cancelled": bool(re.search(r"(abgesagt|annulliert|Spielausfall)", stage, re.I)),
        "format": football_format(age_group, f"{competition} {league}", names[:2]),
    }


# --- basketball-bund.net -----------------------------------------------------

BASKETBALL_ID = re.compile(r"basketball-bund\.net/.*?spiel(?:/|plan_id=|id=)(\d{4,10})\b")


def basketball(game_id):
    raw = fetch(f"https://www.basketball-bund.net/rest/match/id/{game_id}/matchInfo", "application/json")
    try:
        data = json.loads(raw)["data"]
    except (ValueError, KeyError, TypeError) as e:
        raise FixtureError("fixture_unavailable") from e
    if not data or not data.get("homeTeam"):
        raise FixtureError("fixture_not_found")
    league = data.get("ligaData") or {}
    field = (data.get("matchInfo") or {}).get("spielfeld") or {}
    teams = []
    for side in ("homeTeam", "guestTeam"):
        t = data.get(side) or {}
        name = clean(t.get("teamname")) or "?"
        club, team = team_parts(name)
        small = re.sub(r"\d+$", "", ascii_upper(t.get("teamnameSmall") or ""))
        teams.append({"name": name, "club": club, "team": team, "short": small[:3] or guess_short(name)})
    age = league.get("akName") or ""
    young = re.fullmatch(r"U(\d+)", age)
    day = data.get("kickoffDate") or ""
    return {
        "source": "basketball-bund.net", "sport": "basketball", "external_id": str(data.get("matchId") or game_id),
        "url": f"https://www.basketball-bund.net/static/#/spiel/{game_id}",
        "game_number": str(data.get("matchNo") or ""), "matchday": f"{data['matchDay']}. Spieltag" if data.get("matchDay") else "",
        "league": clean(league.get("liganame")), "group": clean(league.get("skName")),
        "competition": clean(league.get("skEbeneName")), "age_group": age,
        "season": clean(league.get("seasonName")), "association": clean(league.get("verbandName")), "area": clean(league.get("bezirkName")),
        "date": ".".join(reversed(day.split("-"))) if re.fullmatch(r"\d{4}-\d\d-\d\d", day) else "",
        "time": data.get("kickoffTime") or "",
        "venue": {"name": clean(field.get("bezeichnung")), "street": clean(field.get("strasse")),
                  "zip": clean(field.get("plz")), "city": clean(field.get("ort")),
                  "address": ", ".join(x for x in (clean(field.get("bezeichnung")), clean(field.get("strasse")),
                                                   " ".join(filter(None, (clean(field.get("plz")), clean(field.get("ort")))))) if x)},
        "home": teams[0], "away": teams[1],
        "cancelled": bool(data.get("abgesagt") or data.get("verzicht")),
        # Mini basketball (U12 and younger) usually plays 8 × 5 minutes.
        "format": {"period_count": 8, "period_length_min": 5} if young and int(young.group(1)) <= 12 else {"period_count": 4, "period_length_min": 10},
    }


# --- shared ------------------------------------------------------------------

STREET = re.compile(r"(stra(ss|ß)e|str\.|weg|platz|allee|ring|damm|chaussee|gasse|ufer|kamp|stieg|twiete)\b", re.I)


def venue_parts(address):
    """'Kunstrasenplatz, Finkenau, Finkenau 38, 22081 Hamburg' → name, street, zip, city."""
    parts = [p.strip() for p in address.split(",") if p.strip()]
    result = {"name": "", "street": "", "zip": "", "city": "", "address": address}
    if parts and (m := re.fullmatch(r"(\d{5})\s+(.+)", parts[-1])):
        result.update(zip=m.group(1), city=m.group(2))
        parts.pop()
    if len(parts) > 1 and (re.search(r"\d", parts[-1]) or STREET.search(parts[-1])):
        result["street"] = parts.pop()
    result["name"] = ", ".join(parts)
    return result


_geo_lock, _geo_last, _geo_cache = threading.Lock(), [0.0], {}


def geocode(venue):
    """Street-level coordinates from OpenStreetMap Nominatim (max. 1 request per second,
    per its usage policy). None when the address is not found precisely."""
    if not venue.get("street") or not (venue.get("zip") or venue.get("city")):
        return None
    query = {"street": venue["street"], "postalcode": venue.get("zip", ""), "city": venue.get("city", ""),
             "country": "Deutschland", "format": "json", "limit": "1"}
    key = json.dumps(query, sort_keys=True)
    with _geo_lock:
        if key in _geo_cache:
            return _geo_cache[key]
        time.sleep(max(0.0, _geo_last[0] + 1.1 - time.time()))
        _geo_last[0] = time.time()
        try:
            found = json.loads(fetch("https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(query), "application/json"))
        except (FixtureError, ValueError):
            return None
        result = None
        if found:
            label = venue.get("name") or venue["street"]
            result = {"lat": round(float(found[0]["lat"]), 6), "lng": round(float(found[0]["lon"]), 6),
                      "label": label[:120], "visible": False}
        if len(_geo_cache) > 500:
            _geo_cache.clear()
        _geo_cache[key] = result
        return result


def kickoff_ms(date_text, time_text):
    """Local German date/time → epoch milliseconds (None without a time)."""
    if not re.fullmatch(r"\d\d\.\d\d\.\d{4}", date_text or "") or not re.fullmatch(r"\d\d:\d\d", time_text or ""):
        return None
    moment = datetime.strptime(f"{date_text} {time_text}", "%d.%m.%Y %H:%M").replace(tzinfo=BERLIN)
    return round(moment.timestamp() * 1000)


SOURCES = ((FUSSBALL_ID, football), (BASKETBALL_ID, basketball))


def parse_link(link):
    for pattern, reader in SOURCES:
        match = pattern.search(link or "")
        if match:
            return reader, match.group(1)
    raise FixtureError("fixture_url")


def lookup(link, locate=True):
    reader, game_id = parse_link(link)
    fixture = reader(game_id)
    distinct_shorts(fixture["home"], fixture["away"])
    fixture["kickoff"] = kickoff_ms(fixture["date"], fixture["time"])
    fixture["location"] = geocode(fixture["venue"]) if locate else None
    fixture["description"] = " · ".join(x for x in (fixture["league"], fixture["matchday"]) if x)[:300]
    return fixture


SOURCE_URLS = {"fussball.de": "https://www.fussball.de/", "basketball-bund.net": "https://www.basketball-bund.net/"}


def stored(data):
    """The facts kept with a game, from a lookup result the client sends back:
    known keys only, plain text, a link only to the source site. None if unusable."""
    if not isinstance(data, dict) or data.get("source") not in SOURCE_URLS:
        return None

    def text(value, limit=120):
        return clean(value)[:limit] if isinstance(value, str) else ""
    url = text(data.get("url"), 300)
    if not url.startswith(SOURCE_URLS[data["source"]]):
        url = ""
    result = {"source": data["source"], "url": url}
    for key in ("external_id", "game_number", "matchday", "league", "group", "competition", "age_group",
                "season", "association", "area", "date", "time"):
        result[key] = text(data.get(key))
    venue = data.get("venue") if isinstance(data.get("venue"), dict) else {}
    result["venue"] = {k: text(venue.get(k), 200 if k == "address" else 120) for k in ("name", "street", "zip", "city", "address")}
    for side in ("home", "away"):
        team = data.get(side) if isinstance(data.get(side), dict) else {}
        result[side] = {k: text(team.get(k), 80) for k in ("name", "club", "team")}
    return result
