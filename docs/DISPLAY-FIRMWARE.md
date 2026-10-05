# score67 Display-Firmware: Konzept & Doku

Stand: 5. Oktober 2026 · überarbeitete Fassung (ohne MQTT, über die bestehende Display-Schnittstelle)

## Überblick

Eine eigene Firmware für den ESP32-S3 (Adafruit Matrix Portal S3) betreibt ein 64 × 32 LED-Panel als Spielstand-Anzeige für score67. Sie zeichnet genau ein Scoreboard-Layout und bekommt ihre Daten über eine **ausgehende, verschlüsselte WebSocket-Verbindung auf Port 443** von score67.de – dieselbe Display-Schnittstelle, die score67 bereits für Anzeigetafeln hat (`docs/DISPLAY-API.md`).

Grundprinzipien:

- **Das Layout lebt im Controller.** Der Server schickt nur Daten (Kürzel, Spielstand, Periode als fertiger Kurztext, Uhrstand), nie Bilder – ein paar hundert Byte pro Änderung.
- **Der Controller verbindet sich von sich aus**, über HTTPS/WSS auf Port 443. Das funktioniert in jedem Netz, in dem ein Browser funktioniert – auch in Hallen-, Schul- und Gäste-WLANs, die andere Ports (MQTT 8883, NTP 123) sperren. Keine Portfreigaben, kein Gerät vor Ort außer der Tafel.
- **Immer der vollständige Stand**, nie einzelne Änderungen; `seq` steigt, ältere Nachrichten werden verworfen.
- **Die Uhr läuft lokal.** Jede Nachricht trägt `server_now`; die Tafel rechnet die Zeit ab Empfang mit ihrem eigenen Takt weiter. Kein NTP nötig.
- **Die Tafel zeigt ihren Kopplungscode selbst**, der Admin tippt ihn in der App ein. Danach gehört die Tafel dem Nutzer und kann **jederzeit einem anderen Scoreboard zugewiesen** werden (eine Tafel in der Halle für verschiedene Teams).
- **Updates zuerst per Web-Flasher (USB)**, OTA erst nach dem Feldtest.

Warum kein MQTT: score67 hat Kopplung, Geräte-Token, Live-Verbindung, Online-Status und Zuweisung bereits. Ein Broker brächte Port 8883 (oft gesperrt), einen zweiten Dienst samt Zertifikats-Reload, ein zweites Rechtesystem und eine weitere Fehlerquelle – ohne Mehrwert.

## Hardware

| Teil | Daten | Hinweis |
|---|---|---|
| Waveshare RGB-Matrix P5 64×32 | 64 × 32 Pixel, 5 mm Pitch, 320 × 160 mm, 1/16 Scan, HUB75 | 5 V / 4 A, max. 20 W, VH4-Stromanschluss |
| Adafruit Matrix Portal S3 | ESP32-S3, WLAN (nur 2,4 GHz), 8 MB Flash, 2 MB PSRAM, USB-C, 2 Taster, 1 NeoPixel | direkt auf HUB75 „In“ gesteckt |
| Netzteil | 5 V, mindestens 4 A (empfohlen 6 A) | versorgt das Panel direkt, nicht über USB-C |
| USB-C-Datenkabel | | erstes Flashen und Debugging |

HUB75-Pinbelegung des Matrix Portal S3 (aus Adafruits Arduino-Beispielen; **vor dem ersten Build gegen das aktuelle Adafruit-Pinout prüfen**):

| Signal | GPIO |
|---|---|
| R1, G1, B1 | 42, 41, 40 |
| R2, G2, B2 | 38, 39, 37 |
| A, B, C, D, E | 45, 36, 48, 35, 21 |
| CLK, LAT, OE | 2, 47, 14 |

Die Adressleitung E wird bei 64 × 32 nicht gebraucht, die Lötbrücke bleibt offen. Taster UP/DOWN für WLAN-Einrichtung und Helligkeit, NeoPixel als Status-LED.

## Firmware

Ein kleiner Zustandsautomat: WLAN → Registrieren → (Code zeigen) → Verbinden → Anzeigen.

### Bildschirme

| Zustand | Anzeige | Wann |
|---|---|---|
| Boot | score67-Logo, Firmware-Version | nach dem Einschalten, ca. 2 s |
| WLAN-Einrichtung | „WLAN: score67-XXXX“ | keine Zugangsdaten gespeichert, oder UP 5 s gehalten |
| Verbinden | Laufpunkte + Netzname | WLAN bzw. Server wird gesucht |
| Kopplung | „CODE“ + 6 Zeichen, z. B. 4F7K2Q | `mode: "pairing"` |
| Bereit | Name der Tafel, „kein Scoreboard“ | `mode: "idle"` |
| Spiel | Kürzel, Spielstand, Periode, Uhr | `mode: "game"` |
| Offline-Hinweis | roter Punkt oben rechts, letzter Stand bleibt | Verbindung weg |
| Identifizieren | Rahmen blinkt | `identify: true` |

### WLAN

- WiFiManager-Portal (Hotspot „score67-XXXX“, XXXX = Ende der MAC) **nur**, wenn keine Zugangsdaten gespeichert sind oder UP 5 s gehalten wird.
- **Bis zu 3 Netze** speichern (z. B. Vereins-WLAN und Handy-Hotspot) und reihum versuchen. Kein automatischer Wechsel ins Portal, wenn ein Netz fehlt – der Hotspot wird oft erst später eingeschaltet; die Tafel versucht es im Hintergrund weiter.
- **Nur 2,4 GHz:** Beim iPhone-Hotspot „Maximale Kompatibilität“ einschalten.

### Registrierung und Kopplung

1. Beim allerersten Start erzeugt die Tafel einen zufälligen **Geräteschlüssel** (mind. 32 Zeichen) und speichert ihn im NVS.
2. `POST /api/display/register` mit `{"device_key", "fw"}` liefert `{"display_id", "token", "code"}`. Das Token kommt ins NVS.
3. Die Tafel verbindet sich: `wss://score67.de/ws/display?token=…&format=compact`.
4. Solange sie niemandem gehört, schickt der Server `mode: "pairing"` mit dem Code (24 h gültig, wird danach automatisch erneuert); die Tafel zeigt ihn.
5. Der Admin gibt den Code in der App ein (Einstellungen → Anzeigetafeln → „Code von der LED-Tafel“). Die Tafel gehört nun diesem Browser; dort wählt er das Scoreboard, die Helligkeit, und kann „Identifizieren“ drücken.
6. Ab jetzt schickt der Server bei jeder Änderung den vollständigen Stand.

Erneute Registrierung mit **demselben** Schlüssel (z. B. Token verloren): neues Token, Besitzer und Scoreboard bleiben. Ein **neuer** Schlüssel (Werksreset: beide Taster 10 s) ist eine neue Tafel mit neuem Code – niemand kann mit einer fremden Display-ID eine laufende Tafel übernehmen. Wird die Tafel in der App entfernt, schließt der Server die Verbindung mit Code 1008; die Tafel registriert sich neu und zeigt wieder einen Code.

### Layout (64 × 32, wie in der Vorschau)

- Oben (y 1–5): Heim-Kürzel links, Gast-Kürzel rechts, 3×5-Schrift, max. 3 Zeichen (Teamfarbe).
- Mitte (y 9–22): Spielstand in 10×14-Ziffern mit Doppelpunkt; ab 100 Punkten 8×14-Ziffern.
- Unten (y 26–30): Uhr mittig, links die Periode (`period`, z. B. Q3, H2, 5/8, OT1), rechts optional Teamfouls.
- Farben: Kürzel in Teamfarbe (zu dunkle Farben aufhellen), Spielstand amber, Uhr grün, gestoppt gelb.
- Doppelpuffer der DMA-Bibliothek; neu zeichnen bei jeder Nachricht, jede Sekunde für die Uhr, **unter einer Minute (Basketball) zehnmal pro Sekunde** für Zehntel.

### Uhr

Beim Empfang merkt sich die Tafel `received = millis()`. Läuft die Uhr:

```
angezeigt = clock.ms − (millis() − received)   (abwärts, nie unter 0)
angezeigt = clock.ms + (millis() − received)   (aufwärts)
```

Gestoppt wird `clock.ms` direkt angezeigt. Bei 0:00 bleibt sie stehen und blinkt 3 s. Laufzeit der Nachricht (typisch < 300 ms) spielt für eine Spieluhr keine Rolle.

### Zuverlässigkeit

- **Wiederverbinden** mit wachsender Wartezeit (1 s, 2 s, 4 s … max. 30 s), WebSocket-Ping alle 15 s.
- **Hardware-Watchdog**: hängt die Hauptschleife > 10 s, startet die Tafel neu und zeigt danach den letzten Stand wieder an, sobald verbunden.
- **Heap prüfen**, ArduinoJson mit festem Puffer (eine Nachricht ist < 1 KB).
- **Zertifikate**: ISRG Root X1 **und** X2 einbauen (oder das Zertifikats-Bundle des ESP32-Cores), damit ein Kettenwechsel von Let's Encrypt die Tafeln nicht trennt.
- Offline: letzter Stand bleibt, Uhr läuft lokal weiter, roter Punkt.

### Status an den Server

Über dieselbe Verbindung, nach dem Verbinden und dann alle 30 s:

```json
{"fw": "0.1.0", "rssi": -61, "uptime": 3600}
```

Die App zeigt Firmware-Version, WLAN-Stärke und Online-Status.

## Server-Seite (umgesetzt in Phase 3)

| Methode + Pfad | Wer | Zweck |
|---|---|---|
| `POST /api/display/register` | Tafel | Registrierung mit Geräteschlüssel → Token + Code |
| `wss://…/ws/display?token=…&format=compact` | Tafel | Live-Feed im kompakten Format, empfängt Status |
| `GET /api/display/state?format=compact` | Tafel | Polling-Fallback |
| `POST /api/displays/claim` | App | Tafel per Code übernehmen |
| `PUT /api/displays/{id}` | App | Name, Scoreboard, Helligkeit (10–100) |
| `POST /api/displays/{id}/identify` | App | Tafel blinkt 10 s |
| `DELETE /api/displays/{id}` | App | Tafel entfernen (Tafel zeigt danach wieder einen Code) |

Kompaktes Format: siehe `docs/DISPLAY-API.md`, erzeugt in `backend/score67/display_feed.py`. Zum Testen ohne Hardware simuliert `tools/display_sim.py` eine Tafel (Registrieren, Code, Live-Feed, lokale Uhr, Status).

## Projektstruktur (Firmware)

```
score67-display/
├── platformio.ini
├── partitions.csv          # 2 App-Partitionen (für spätere OTA) + NVS
├── include/
│   ├── config.h            # Server, Defaults, Pins
│   └── certs.h             # ISRG Root X1 + X2
├── src/
│   ├── main.cpp            # setup(), loop(), Zustandsautomat, Watchdog
│   ├── panel.cpp/.h        # HUB75-Init, Doppelpuffer, Helligkeit
│   ├── render.cpp/.h       # Bildschirme und Scoreboard-Layout
│   ├── fonts.h             # 3×5-, 8×14- und 10×14-Pixelschriften
│   ├── net.cpp/.h          # WLAN (mehrere Netze), Registrierung, WebSocket
│   ├── feed.cpp/.h         # JSON parsen, seq prüfen, Uhr rechnen
│   └── buttons.cpp/.h      # UP/DOWN, lange Drücke
└── tools/
    └── preview.py          # rendert das Layout als PNG (gleiche Schriftdaten)
```

Bibliotheken: ESP32-HUB75-MatrixPanel-DMA (mrfaptastic), Adafruit GFX, WiFiManager (tzapu), **arduinoWebSockets (Links2004; TLS, Reconnect, Ping)**, ArduinoJson 7, Adafruit NeoPixel; aus dem ESP32-Core WiFiClientSecure, HTTPClient, Preferences. *Entfällt gegenüber dem ersten Entwurf: PubSubClient, NTP.*

```ini
[env:matrixportal_s3]
platform = espressif32
board = adafruit_matrixportal_esp32s3
framework = arduino
monitor_speed = 115200
board_build.partitions = partitions.csv
build_flags =
  -DFW_VERSION=\"0.1.0\"
  -DARDUINO_USB_CDC_ON_BOOT=1
lib_deps =
  mrfaptastic/ESP32 HUB75 LED MATRIX PANEL DMA Display
  adafruit/Adafruit GFX Library
  tzapu/WiFiManager
  links2004/WebSockets
  bblanchon/ArduinoJson@^7
  adafruit/Adafruit NeoPixel
```

(Board-ID und Versionen beim Anlegen prüfen.)

## Deployment

- **Erstes Flashen:** `pio run -t upload` per USB-C; ohne Port: BOOT halten, RESET kurz, BOOT los.
- **Web-Flasher** (für Vereine, ohne Entwicklungsumgebung): Seite auf score67.de mit ESP Web Tools; Manifest + zusammengeführtes Image (`esptool.py merge_bin`).
- **OTA (später):** Befehl über den WebSocket, Download per HTTPS von score67.de/fw, Prüfsumme beim Download mitrechnen (`HTTPUpdate` prüft keine SHA-256 von selbst), nie während die Uhr läuft. Rollback über einen **Boot-Zähler im NVS** – der Bootloader-Rollback ist im Standard-Arduino-Build abgeschaltet.

## Betrieb vor Ort

- Handy-Hotspot bzw. LTE-Router einschalten (2,4 GHz; iPhone: „Maximale Kompatibilität“).
- Tafel einschalten: Sie verbindet sich selbst und zeigt das zugewiesene Scoreboard.
- Roter Punkt = keine Verbindung zum Server; Hotspot prüfen.
- Neues WLAN: UP 5 s halten, mit dem Handy das Portal öffnen.

## Umsetzungsplan

Jede Phase endet mit etwas, das sichtbar funktioniert.

1. **Panel läuft:** Testmuster und Farbbalken, Pinbelegung bestätigt.
2. **Layout steht:** Schriften und Layout mit festen Testdaten, lokale Uhr inkl. Zehntel, dreistellige Spielstände; `preview.py`.
3. **Server-Seite** ✅ (5. Oktober 2026): Registrierung, Code auf der Tafel, Übernahme in der App, kompakter Feed, Helligkeit, Identifizieren, Status; Simulator `tools/display_sim.py`.
4. **Firmware verbindet sich:** WLAN (mehrere Netze), Registrierung, WSS zu score67.de, Code-Anzeige, Live-Daten, roter Punkt, Watchdog.
5. **Feldtest:** ein echtes Spiel über Handy-Hotspot, mit absichtlichen Verbindungsabbrüchen.
6. **Web-Flasher, danach OTA** mit Boot-Zähler und Prüfsumme.
