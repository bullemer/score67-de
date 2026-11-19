"""Search engines and link previews read the server's HTML, not the browser.

The site pages used to ship empty elements (``<h1 data-i18n="…"></h1>``)
that JavaScript filled from shared/i18n: Google saw them only after
rendering, other crawlers never. ``fill`` writes every translatable text
into the HTML on the server; the page scripts still switch languages in
place. The URL decides the language (German by default, ``?lang=en``),
so each version can be indexed with hreflang alternates."""
import html
import json
import re
from functools import lru_cache
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = ("de", "en")
# An element with data-i18n whose content is plain text (no child elements).
TEXT = re.compile(r'(<(?P<tag>[a-zA-Z][a-zA-Z0-9]*)\b(?P<attrs>[^<>]*?\sdata-i18n="(?P<key>[^"]+)"[^<>]*)>)(?P<inner>[^<]*)(</(?P=tag)>)')


@lru_cache(maxsize=None)
def words(language):
    return json.loads((ROOT / f"shared/i18n/{language}.json").read_text())


def language(request, fallback="de"):
    asked = request.query_params.get("lang")
    return asked if asked in LANGUAGES else fallback


def fill(page, language, title=None):
    """The page with every data-i18n text, <html lang> and (optionally) <title> filled in."""
    texts = words(language)

    def replace(match):
        text = texts.get(match["key"])
        if not isinstance(text, str):
            return match[0]
        return f"{match[1]}{html.escape(text, quote=False)}{match[6]}"

    page = TEXT.sub(replace, page)
    page = re.sub(r"<html lang=\"[a-z]{2}\"", f'<html lang="{language}" data-server-lang="{language}"', page, count=1)
    if title:
        # A function, not a template: titles are user text and may hold backslashes.
        page = re.sub(r"<title>.*?</title>", lambda _: f"<title>{html.escape(title, quote=False)}</title>", page, count=1, flags=re.S)
    return page


def sitemap(origin, pages, threads):
    """sitemap.xml: site pages in both languages (hreflang alternates) and forum topics."""
    def url(path, language):
        return f"{origin}{path}" + ("?lang=en" if language == "en" else "")

    entries = []
    for path, lastmod in [(p, None) for p in pages] + [(f"/forum/{t}", m) for t, m in threads]:
        for language in LANGUAGES:
            alternates = "".join(
                f'<xhtml:link rel="alternate" hreflang="{other}" href="{html.escape(url(path, other))}"/>'
                for other in LANGUAGES) + f'<xhtml:link rel="alternate" hreflang="x-default" href="{html.escape(url(path, "de"))}"/>'
            modified = f"<lastmod>{lastmod}</lastmod>" if lastmod else ""
            entries.append(f"<url><loc>{html.escape(url(path, language))}</loc>{modified}{alternates}</url>")
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9" xmlns:xhtml="http://www.w3.org/1999/xhtml">\n'
            + "\n".join(entries) + "\n</urlset>\n")


def robots(origin):
    return ("User-agent: *\n"
            "Disallow: /api/\n"
            "Disallow: /dashboard\n"
            "Disallow: /login\n"
            "Disallow: /new\n"
            "Disallow: /app/\n"
            "Disallow: /forum/moderate/\n"
            "Disallow: /*/control\n"
            "Disallow: /*/overlay\n"
            f"\nSitemap: {origin}/sitemap.xml\n")
