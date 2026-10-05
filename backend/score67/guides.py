"""Guide pages for search: what people look for (basketball/football live
ticker, OBS overlay, scoreboard on a TV, sharing via WhatsApp). One Jinja
template per page and language (templates/guides/<key>.<lang>.html);
title and description in shared/i18n as seo.guide.<key>.*."""
GUIDES = {
    "/basketball-liveticker": "basketball",
    "/fussball-liveticker": "football",
    "/obs-scoreboard-overlay": "obs",
    "/anzeigetafel": "display",
    "/anleitung/spielstand-whatsapp-teilen": "whatsapp",
}
