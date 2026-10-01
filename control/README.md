# Score67 controller

Flutter Web controller for the self-hosted FastAPI service. See the project README for running the complete application.

Build with `flutter build web --release --base-href /app/ --no-web-resources-cdn`. FastAPI serves static assets at `/app/` and the entry document at `/new` and `/s/{slug}/control`. The server owns routing; Flutter's URL strategy is disabled to preserve those public links.

Translations are fetched from `/i18n/de.json` and `/i18n/en.json`, shared with the HTML displays. All API calls are same-origin and rely on the HttpOnly device cookie.

This first controller targets Web. Extract the `package:web` browser interactions into platform adapters before building native mobile apps.
