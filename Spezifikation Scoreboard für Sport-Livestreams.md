# Spezifikation: Scoreboard für Sport-Livestreams

Oct 1, 2026 · @Carsten

## Ziel und Umfang

Das Scoreboard ist eine kleine Web-Anwendung auf dem eigenen Server für mehrere Sportarten, zum Start Fußball und Basketball. Jeder kann darin eigene Scoreboards anlegen und bekommt dafür einen Deeplink und eine Admin-PIN. Sie liefert Spielstand, Spielzeit, Aufstellung und Treffer-Einblendungen als transparente Seite, die OBS als Browserquelle über das Kamerabild legt. Gesteuert wird sie per Handy am Spielfeldrand. Die Bedienung orientiert sich an der App InGame von NBN23, ist aber bewusst viel einfacher.

**Im Umfang**

- Beliebig viele Scoreboards, die jeder ohne Konto anlegen kann, jedes mit eigenem Deeplink und eigener Admin-PIN
- Weitere Admins und Wiederherstellung des Admin-Rechts über die PIN, bei vergessener PIN über eine freiwillige E-Mail-Adresse
- Mehrere Sportarten über Sportprofile, zum Start Fußball und Basketball
- Spielstand mit Teamnamen, Kürzeln und Vereinsfarben
- Spielzeit je Sportart: durchlaufende Uhr im Fußball, gestoppte Countdown-Uhr im Basketball
- Aufstellung als große Einblendung, per Knopfdruck ein- und ausblendbar
- Treffer-Einblendung im Fußball mit Spielminute und Torschütze
- Teamfouls oder persönliche Fouls sowie Auszeiten im Basketball
- Steuer-Seite für das Handy, nutzbar über Mobilfunk
- Spielprotokoll nach dem Spielende und ein öffentlicher Spielstand für die Homepage
- Betrieb mit wenig Information: ohne Spielernamen, ohne Rückennummern und notfalls ohne Zeitmessung
- Frei wählbare Spielformate: Anzahl und Länge der Abschnitte je Spiel, mit Schnellwahl für gängige Formate
- Spielstand als Einblendung in zwei Größen: klein in einer oberen Ecke und groß in der Bildmitte, etwa zur Halbzeit
- Mehrsprachige Oberfläche, zum Start Deutsch und Englisch
- Designs: ein Standard-Design, ein eigenes Design mit Farben und Logos und mehrere Vorlagen, getrennt für den Stream in OBS und für die Anzeige auf dem Handy

**Nicht im Umfang der ersten Version**

- Benutzerkonten mit E-Mail und Passwort
- Automatische Treffer-Erkennung aus dem Kamerabild
- Statistiken über mehrere Spiele hinweg
- Spielerstatistiken im Basketball wie Punkte, Rebounds und Assists je Spieler
- Wurfuhr im Basketball
- Verlängerung und Elfmeterschießen im Fußball
- Mehrere gleichzeitig aktive Spiele in einem Scoreboard (wer zwei Spiele parallel zeigt, legt zwei Scoreboards an)

## Bedienkonzept

Vorbild für die Bedienung ist [InGame von NBN23](https://nbn23.com/ingame/), der [digitale Spielbericht im deutschen Basketball](https://ingamebynbn23.com/dss-info). Das Scoreboard übernimmt dessen Grundidee und lässt fast alles andere weg: weniger Funktionen, kaum Einstellungen, sofort startklar.

**Leitlinien**

- **Sofort startklar:** Ein neues Scoreboard enthält bereits ein Spiel mit den Teams „Home“ und „Guest“. Ohne weitere Eingabe lässt sich die Uhr starten und der Spielstand zählen.
- **Vorgabe „Home“ – „Guest“:** Jedes neue Spiel beginnt mit diesen beiden Namen und den Kürzeln „HOME“ und „GUEST“. Namen, Kürzel, Farben und Logos zu ändern ist freiwillig.
- **Team vor Spieler:** Erfasst wird je Team, mit einer Ausnahme: persönliche Fouls im Basketball. Kader, Aufstellung und Schützen sind freiwillige Zusätze. Wer sie nicht pflegt, sieht davon nichts.
- **Ein Bildschirm:** Im Spiel liegt alles auf einem Bildschirm: Home links, Guest rechts, Uhr und Abschnitt in der Mitte, darunter das Protokoll.
- **Wenige Einstellungen:** Sichtbar sind nur Sportart, Teamnamen und Spielformat. Alles andere hat eine Vorgabe und liegt unter „Erweitert“.
- **Ohne Schulung:** Wer die Steuer-Seite zum ersten Mal öffnet, kann ein Spiel ohne Anleitung begleiten.
- **Wenig Information genügt:** Pflicht ist nur der Spielstand. Fehlen Spielernamen, Rückennummern oder die Aufstellung, arbeitet das Scoreboard auf Team-Ebene weiter. Ein Spieler kann auch nur aus einer Nummer oder nur aus einem Namen bestehen.
- **Auch ohne Zeitmessung:** Die Uhr lässt sich pro Spiel abschalten, auch mitten im Spiel. Dann zeigt das Scoreboard nur Spielstand und Abschnitt.
- **Nachtragen statt aufhalten:** Was im Spiel fehlt, lässt sich danach im Protokoll ergänzen. Keine fehlende Angabe blockiert die Bedienung.

**Von InGame übernommen**

- Spielkopf mit Spielstand, Uhr und Abschnitt, der immer sichtbar bleibt
- Erfassen per Tipp: Treffer, Fouls und Auszeiten
- Laufendes Spielprotokoll, in dem sich Einträge zurücknehmen lassen
- Teamfarben zur Unterscheidung auf einen Blick
- Live-Spielstand für Zuschauer
- Testspiel zum Ausprobieren

**Bewusst weggelassen**

- Spielerlizenzen, Check-in vor dem Spiel und digitale Unterschriften
- Offizieller Spielbericht als PDF und Anbindung an Verbandssysteme
- Scouting-Statistiken wie Rebounds, Assists und Wurfquoten
- Auswechslungen und Einsatzzeiten
- Sanktionen und Sperren
- Betrieb ohne Internetverbindung

## Sprachen

Die Oberfläche ist mehrsprachig angelegt. Zum Start gibt es Deutsch und Englisch, jede weitere Sprache ist nur eine zusätzliche Sprachdatei.

| Bereich | Die Sprache richtet sich nach |
| --- | --- |
| Landing-Page, Flutter-App, Zuschauer-Seite | Sprache des Browsers. Jede Seite hat einen Umschalter, die Wahl bleibt auf dem Gerät gespeichert. |
| Anzeige im Stream | Einstellung des Scoreboards, weil OBS keine Sprache mitbringt |
| E-Mails zur Wiederherstellung | Einstellung des Scoreboards |

**Regeln**

- **Sprachdateien:** Alle Texte liegen in einer Datei je Sprache, zum Start `de` und `en`. In Code und Templates stehen nur Schlüssel, keine festen Texte. Die Flutter-App und die HTML-Seiten nutzen dieselben Dateien.
- **Rückfall:** Fehlt eine Übersetzung oder gibt es die Browsersprache nicht, gilt Englisch.
- **Sprache des Scoreboards:** Beim Anlegen übernimmt das Scoreboard die Sprache der Seite. Sie gilt für die Anzeige im Stream und für E-Mails und ist in den Einstellungen änderbar.
- **Sprachneutrale Daten:** Datenbank und Schnittstellen enthalten keine übersetzten Texte. Abschnitts-Kürzel, Zeitangaben und Überschriften wie „Halbzeit“ entstehen erst bei der Anzeige.
- **Feste Teamnamen:** „Home“ und „Guest“ sind Teamnamen, keine Oberflächentexte. Sie lauten in jeder Sprache gleich, bis jemand sie ändert.
- **Fehlermeldungen:** Die Schnittstelle liefert Fehlercodes, die Seite zeigt den Text in ihrer Sprache.
- **Per Link:** `?lang=de` oder `?lang=en` legt die Sprache einer Seite fest, auch für eine einzelne Browserquelle in OBS.
- **Bezeichner:** Alle internen Bezeichner in Code, Datenbank und Schnittstelle sind englisch, zum Beispiel die Spielphasen und die Namen der Sportprofile.

**Beispiele für Texte im Stream**

| Schlüssel | Deutsch | Englisch |
| --- | --- | --- |
| `overlay.halftime` | Halbzeit | Half-time |
| `overlay.break` | Pause | Break |
| `overlay.final` | Endstand | Final |
| `overlay.goal` | TOR | GOAL |
| `period.half` | 1. HZ, 2. HZ | H1, H2 |
| `lineup.bench` | Bank | Bench |
| `player.unknown` | Unbekannt | Unknown |

## Architektur

Der Server hält den Spielzustand, das Handy ändert ihn, und OBS zeigt ihn an. Die Kameras laufen davon getrennt über MediaMTX.

&#91;embedded content: Architektur · 6 Bausteine\]

Eingaben vom Handy gehen an den Server, der jede Änderung sofort an die Anzeige in OBS weitergibt. OBS legt sie über das Kamerabild und sendet beides zu YouTube.

| Baustein | Technik | Aufgabe |
| --- | --- | --- |
| Backend | FastAPI, Postgres, WebSocket | Speichert Scoreboards, Spiele, Kader und Ereignisse und verteilt den Zustand |
| App | Flutter Web | Scoreboard anlegen, Steuer-Seite, Einstellungen und Wiederherstellung |
| Ergebnisseiten | HTML vom Server (Jinja-Template) mit CSS und wenig JavaScript | Landing-Page, Anzeige für OBS und Zuschauer-Seite mit Live-Spielstand |

**Warum diese Aufteilung**

- **Flutter Web für die App:** Alles, was bedient wird, ist eine Flutter-Web-App. Aus derselben Codebasis können später Apps für Android und iOS entstehen.
- **Einfaches HTML für die Ergebnisseiten:** Die Anzeige läuft im Browser von OBS. Sie muss sofort laden, einen transparenten Hintergrund haben und flüssig laufen. Flutter Web zeichnet auf eine Canvas-Fläche und ist dafür zu schwer.
- **Kein HTMX:** Die Ergebnisseiten bekommen den Zustand als JSON über den WebSocket und rechnen die Uhr im Browser. Dafür genügt wenig eigenes JavaScript, HTMX brächte hier keinen Vorteil.
- **Eine Schnittstelle:** App und Ergebnisseiten nutzen dieselbe REST-Schnittstelle und denselben WebSocket.
- **Erster Aufruf:** Die Flutter-App lädt beim ersten Öffnen einige Megabyte und liegt danach im Cache des Geräts. Die Ergebnisseiten bleiben klein.
- **Landing-Page in HTML:** Die Start-Seite lädt sofort, ist für Suchmaschinen lesbar und erklärt in wenigen Sätzen, was das Scoreboard kann. Der Knopf „Scoreboard anlegen“ startet die Flutter-App. Während jemand die Seite liest, lädt der Browser die App schon im Hintergrund vor.
- **Direkte Links:** Wer einen Link zur Steuer-Seite öffnet, landet ohne Umweg über die Landing-Page in der Flutter-App.

**Betrieb**

- **Domain:** Der Dienst läuft unter `score67.de`. `www.score67.de` leitet dorthin weiter, damit die Deeplinks kurz bleiben.
- **Server:** ein eigener Server mit der IP-Adresse `116.203.233.103`.
- **DNS:** je ein A-Eintrag für `score67.de` und `www.score67.de` auf diese IP-Adresse.
- **HTTPS:** ein Zertifikat für beide Namen, zum Beispiel von Let's Encrypt. Aufrufe über HTTP werden auf HTTPS umgeleitet.

## Scoreboards und Zugriff

Der Dienst verwaltet beliebig viele Scoreboards. Jeder kann eines anlegen und bekommt dabei einen Deeplink und eine Admin-PIN. Benutzerkonten gibt es nicht.

**Anlegen**

1. Auf der Landing-Page „Scoreboard anlegen“ wählen. Die Flutter-App öffnet sich und fragt nach der Sportart. Ein Name für das Scoreboard und eine E-Mail-Adresse für die Wiederherstellung sind freiwillig.
2. Der Server erzeugt einen zufälligen Slug für den Deeplink, eine PIN und ein erstes Spiel mit den Teams „Home“ und „Guest“.
3. Die Seite zeigt die Links und die PIN genau einmal, mit Knöpfen zum Kopieren und einem QR-Code.
4. Das Gerät, das das Scoreboard angelegt hat, ist sofort Admin. Ein Knopf führt direkt zur Steuer-Seite, auf der das Spiel startbereit ist.

**Links je Scoreboard**

| Link | Adresse | Zugriff | Zweck |
| --- | --- | --- | --- |
| Deeplink | `/s/{slug}` | öffentlich | Live-Spielstand für Zuschauer und Einstieg zur Steuerung |
| Anzeige | `/s/{slug}/overlay` | öffentlich | Browserquelle für OBS |
| Steuerung | `/s/{slug}/control` | Admin | Steuer-Seite für das Handy |

**Admin-Rechte**

- **Admin-Gerät:** Admin ist ein Gerät, kein Konto. Der Server erzeugt je Gerät ein zufälliges Token und setzt es als Cookie. Gespeichert wird nur dessen Hash.
- **Weitere Admins:** Wer die Steuer-Seite ohne Admin-Recht öffnet, gibt die PIN ein und wird damit selbst Admin-Gerät. Ein Admin gibt die Steuerung also weiter, indem er Link und PIN verschickt.
- **Wiederherstellung:** Ist das Cookie weg, etwa nach einem Handywechsel oder gelöschten Browserdaten, stellt die PIN das Admin-Recht wieder her.
- **Verwaltung:** Jeder Admin sieht die Liste der Admin-Geräte mit Namen und letzter Nutzung und kann einzelnen Geräten das Recht entziehen.
- **Neue PIN:** Jeder Admin kann eine neue PIN erzeugen. Die alte gilt dann nicht mehr, bestehende Admin-Geräte bleiben berechtigt.
- **Trennung:** Admin-Rechte gelten nur für das eine Scoreboard. Teams, Kader und Spiele gehören immer zu genau einem Scoreboard.

**Wiederherstellung per E-Mail**

Die E-Mail-Adresse ist freiwillig. Sie dient nur dazu, ein Scoreboard zurückzubekommen, wenn die PIN vergessen und kein Admin-Gerät mehr vorhanden ist.

1. Auf der PIN-Abfrage „PIN vergessen“ wählen.
2. Der Server schickt einen Link an die hinterlegte Adresse. Der Link gilt 30 Minuten und nur einmal.
3. Wer den Link öffnet, wird Admin-Gerät und bekommt eine neue PIN angezeigt. Die alte PIN gilt nicht mehr.

- Die Seite antwortet immer mit derselben Meldung. Sie verrät nicht, ob eine Adresse hinterlegt ist.
- Admins können die Adresse in den Einstellungen eintragen, ändern und entfernen. Bei einer Änderung bekommt die bisherige Adresse eine Nachricht.
- Ohne hinterlegte Adresse gilt weiter: Sind PIN und alle Admin-Geräte verloren, lässt sich das Scoreboard nicht mehr steuern.

**Format**

- **Slug:** 10 zufällige Zeichen aus Kleinbuchstaben und Ziffern, zum Beispiel `k7m2xq9dfp`. Es gibt keine Liste aller Scoreboards, wer den Slug nicht kennt, findet es nicht.
- **PIN:** 6 Ziffern, vom Server erzeugt.

## Sportarten

Jede Sportart ist ein Sportprofil: eine Konfiguration, die Abschnitte, Uhr, Treffer und Zusatzzähler festlegt. Dienst, Datenmodell und Seiten sind für alle Sportarten gleich. Eine neue Sportart braucht nur ein weiteres Profil und ein eigenes Layout für das kleine Scoreboard.

| Einstellung | Feld im Profil | Fußball | Basketball |
| --- | --- | --- | --- |
| Spielformate | `formats` | 2 Halbzeiten, Minispiel, eigenes Format | 4 × 10, 4 × 12, 8 × 5, 2 Halbzeiten, eigenes Format |
| Vorgabe für das erste Spiel | `default_format` | 2 Halbzeiten à 45 Minuten | 4 Viertel à 10 Minuten |
| Laufrichtung der Uhr | `clock_direction` | `up`, zählt über die Abschnitte weiter | `down`, beginnt in jedem Abschnitt neu |
| Uhr anhalten | `clock_stoppable` | nein, läuft durch | ja, Start und Stopp per Knopf |
| Punkte je Treffer | `score_values` | 1 | 1, 2 oder 3 |
| Zusatzzähler | `counters` | keine | Fouls (Teamfouls, persönliche Fouls, beides oder aus), Auszeiten |
| Verlängerung | `overtime_length_min` | nicht in der ersten Version | 5 Minuten, so oft wie nötig |
| Startaufstellung | `lineup_size` | 11 | 5 |
| Treffer-Einblendung | `score_overlay` | groß, 8 Sekunden | keine, der Spielstand pulsiert kurz |
| Zeitangabe im Protokoll | `time_label` | Spielminute, z. B. „23.“ | Abschnitt und Restzeit, z. B. „Q2 04:31“ |

**Spielformate**

Spielzeiten unterscheiden sich stark nach Altersklasse und Wettbewerb. Deshalb sind Anzahl und Länge der Abschnitte bei jedem Spiel frei wählbar, und die gängigen Formate gibt es als Schnellwahl.

| Sportart | Format | Abschnitte | Länge je Abschnitt |
| --- | --- | --- | --- |
| Fußball | 2 Halbzeiten | 2 | frei, vorbelegt mit 45 Minuten |
| Fußball | Minispiel | 1 | frei, vorbelegt mit 10 Minuten |
| Basketball | 4 Viertel à 10 | 4 | 10 Minuten |
| Basketball | 4 Viertel à 12 | 4 | 12 Minuten |
| Basketball | 8 Achtel à 5 | 8 | 5 Minuten |
| Basketball | 2 Halbzeiten | 2 | frei, vorbelegt mit 20 Minuten |
| beide | Eigenes Format | 1 bis 12 | 1 bis 60 Minuten |

- **Schnellwahl:** Ein Tipp auf ein Format setzt Anzahl und Länge. Beide Werte bleiben danach einzeln änderbar.
- **Merken:** Das Format des letzten Spiels ist die Vorgabe für das nächste Spiel desselben Scoreboards. Wer immer 8 × 5 spielt, stellt es nur einmal ein.
- **Ändern im Spiel:** Anzahl und Länge lassen sich auch während des Spiels ändern. Die Uhr rechnet sofort mit dem neuen Wert.
- **Kürzel nach Anzahl:** Bei 1 Abschnitt gibt es kein Kürzel, bei 2 Abschnitten „1. HZ“ und „2. HZ“, bei 4 Abschnitten „Q1“ bis „Q4“, sonst „1/8“ bis „8/8“. Eine Verlängerung heißt „OT“. Die Kürzel kommen aus der Sprachdatei, im Englischen heißen die Halbzeiten „H1“ und „H2“.
- **Mehrere Minispiele:** Jedes Minispiel ist ein eigenes Spiel. „Neues Spiel“ startet mit demselben Format bei 0:0.
- **Fouls je Format:** Das Format belegt auch die Foul-Zählung vor. „8 Achtel à 5“ zählt nur persönliche Fouls, die anderen Basketball-Formate zählen Teamfouls. Die Einstellung bleibt pro Spiel änderbar.

**Regeln**

- **Ablage:** Die Profile liegen als Konfiguration im Code, eine Datei je Sportart, nicht in der Datenbank.
- **Vorgaben:** Anzahl und Länge der Abschnitte sind Vorgaben. Jedes Spiel kann sie überschreiben, etwa für Jugendspiele.
- **Zuordnung:** Ein Team gehört zu genau einer Sportart. Ein Spiel verbindet nur Teams derselben Sportart.
- **Eine Adresse:** Die Anzeige-Seite ist für alle Sportarten dieselbe. Sie zeigt das aktive Spiel im Layout seiner Sportart.
- **Teamfouls:** Sie werden zu Beginn jedes Abschnitts zurückgesetzt. In der Verlängerung zählen die Fouls des letzten Abschnitts weiter. Beides gilt nur, wenn das Spiel Teamfouls zählt.
- **Foul-Zählung:** Jedes Basketballspiel hat eine von vier Einstellungen: Teamfouls, persönliche Fouls, beides oder aus. In den kleinen Altersklassen gibt es keine Teamfouls, dort zählen nur persönliche Fouls.
- **Persönliche Fouls:** Ein persönliches Foul gehört zu einem Spieler. Dafür genügt eine Rückennummer. Die Steuer-Seite zeigt je Spieler die Zahl der Fouls und hebt das vierte und fünfte hervor.

## Spielablauf und Zeitlogik

Der Server speichert nur die Zeitpunkte der Ereignisse, die Uhr rechnet jede Anzeige selbst. So läuft die Zeit auch bei Netzaussetzern ruhig weiter, und es gibt nur eine Quelle der Wahrheit.

| Phase | Ausgelöst durch | Uhr | Anzeige |
| --- | --- | --- | --- |
| `pre_game` | Spiel anlegen | steht auf dem Startwert | Teamnamen, 0:0 |
| `period_running` | Start eines Abschnitts: Anpfiff, Wiederanpfiff, Beginn eines Viertels | läuft, im Basketball mit Stopps | Scoreboard mit Abschnitts-Kürzel |
| `break` | Ende eines Abschnitts | steht | „Halbzeit“ oder „Ende Q1“ mit Spielstand |
| `finished` | Spielende | steht | „Endstand“ mit Spielstand |

Zur Phase gehört die Nummer des Abschnitts in `period`. Eine Verlängerung im Basketball ist ein weiterer Abschnitt nach dem letzten regulären.

**Regeln**

- **Uhrzustand:** Drei Werte beschreiben die Uhr: `clock_running`, `clock_started_at` und `clock_elapsed_ms`, die gelaufene Zeit im Abschnitt vor dem letzten Start.
- **Berechnung:** gelaufene Zeit = `clock_elapsed_ms` + (jetzt − `clock_started_at`), solange die Uhr läuft. Zählt die Uhr hoch, zeigt sie Startwert des Abschnitts + gelaufene Zeit. Zählt sie herunter, zeigt sie Abschnittslänge − gelaufene Zeit.
- **Abschnittslänge und Anzahl:** kommen aus dem gewählten Spielformat und sind pro Spiel frei einstellbar, auch während des Spiels.
- **Fußball:** Die Uhr läuft durch. Jeder weitere Abschnitt beginnt beim Ende des vorigen, die zweite Halbzeit also z. B. bei 45:00. Läuft die Uhr über das Ende des Abschnitts hinaus, zeigt sie „45+2“ statt „47:00“.
- **Basketball:** Die Uhr wird per Knopf gestartet und gestoppt. Bei 00:00 hält sie von selbst an. Der Abschnitt endet erst, wenn er auf der Steuer-Seite beendet wird.
- **Verlängerung im Basketball:** Steht es nach dem letzten Abschnitt unentschieden, bietet die Steuer-Seite „Verlängerung starten“ an.
- **Serverzeit:** Jede Nachricht enthält die aktuelle Serverzeit. Die Anzeige gleicht damit falsch gehende Geräteuhren aus.
- **Zeitangabe eines Treffers:** im Fußball die angefangene Minute, also 22:10 ergibt „23.“, in der Nachspielzeit „45+2“. Im Basketball Abschnitt und Restzeit, z. B. „Q2 04:31“.
- **Korrektur:** Die Steuer-Seite kann die Uhr verschieben und im Basketball direkt auf eine Restzeit setzen, um sie an die Hallenuhr anzugleichen.
- **Rückgängig:** Das letzte Ereignis lässt sich zurücknehmen, auch ein versehentliches Spielende.
- **Ohne Zeitmessung:** Steht `clock_enabled` am Spiel auf falsch, gibt es keine Uhr. Die Abschnitte lassen sich weiter per Knopf wechseln, das ist aber freiwillig. Treffer tragen als Zeitangabe nur den Abschnitt, z. B. „1. HZ“ oder „Q2“, oder gar keine.
- **Uhr nachträglich:** Die Zeitmessung lässt sich jederzeit ein- und ausschalten. Beim Einschalten mitten im Spiel wird die Uhr auf einen Wert gesetzt und läuft von dort weiter.
- **Treffer in jeder Phase:** Treffer, Fouls und Auszeiten lassen sich immer erfassen, auch wenn kein Abschnitt gestartet wurde.

## Datenmodell

Sieben Tabellen in Postgres reichen aus. Der Spielstand wird nicht gespeichert, sondern aus den Treffer-Ereignissen summiert, damit „Rückgängig“ nur ein Ereignis streichen muss.

| Tabelle | Wichtigste Felder | Zweck |
| --- | --- | --- |
| `scoreboard` | `id`, `slug`, `name`, `default_sport`, `language`, `stream_template`, `screen_template`, `design_mode`, `design`, `pin_hash`, `pin_failed_count`, `pin_locked_until`, `recovery_email`, `recovery_token_hash`, `recovery_token_expires_at`, `created_at`, `last_used_at` | Ein Scoreboard mit Deeplink, PIN und freiwilliger E-Mail-Adresse |
| `scoreboard_admin` | `id`, `scoreboard_id`, `token_hash`, `label`, `created_at`, `last_seen_at`, `revoked` | Ein Admin-Gerät eines Scoreboards |
| `team` | `id`, `scoreboard_id`, `sport`, `name`, `short_name` (bis 5 Zeichen), `color_primary`, `color_secondary`, `logo_url` | Eigene Mannschaften und Gegner, je Sportart |
| `player` | `id`, `team_id`, `first_name`, `last_name`, `shirt_number`, `name_public` (ja/nein), `active`. Name und Nummer sind einzeln freiwillig. | Kader, bleibt über Spiele hinweg erhalten |
| `match` | `id`, `scoreboard_id`, `sport`, `home_team_id`, `away_team_id`, `competition`, `scheduled_at`, `period_count`, `period_length_min`, `foul_mode`, `phase`, `period`, `clock_enabled`, `clock_running`, `clock_started_at`, `clock_elapsed_ms`, `is_active`, `overlay_view`, `overlay_position`, `overlay_auto_big`, `overlay_delay_ms`, `name_mode` | Ein Spiel mit Uhrzustand und Anzeige-Einstellungen |
| `lineup_entry` | `id`, `match_id`, `team_id`, `player_id`, `role` (`start`, `bench`), `sort_order` | Aufstellung für genau dieses Spiel |
| `match_event` | `id`, `match_id`, `type`, `team_id`, `player_id`, `points`, `detail`, `period`, `clock_ms`, `occurred_at`, `cancelled`, `admin_id` | Protokoll aller Ereignisse |

**Ereignistypen in `match_event.type`:** `period_start`, `period_end`, `game_end`, `score`, `clock_start`, `clock_stop`, `clock_set`, `foul`, `timeout`. Später kommen `substitution` und `card` dazu. Ein Tor im Fußball ist ein `score` mit `points` 1, ein Eigentor trägt `detail` `own_goal`.

**Hinweise**

- Alle Zeitpunkte liegen in UTC.
- `scoreboard_id` an Team und Spiel trennt die Scoreboards. Jede Abfrage filtert danach.
- `slug` ist eindeutig und ändert sich nie, weil er in den Links steckt.
- `label` ist der Name eines Admin-Geräts, zum Beispiel „Handy Trainer“. Das Gerät vergibt ihn bei der PIN-Eingabe.
- `admin_id` am Ereignis hält fest, welches Admin-Gerät es eingetragen hat.
- `sport` an Team und Spiel nennt das Sportprofil, zum Start `football` oder `basketball`.
- `period_count` und `period_length_min` werden beim Anlegen aus dem letzten Spiel des Scoreboards vorbelegt, beim ersten Spiel aus der Vorgabe des Sportprofils. Erlaubt sind 1 bis 12 Abschnitte von 1 bis 60 Minuten.
- Zusatzzähler wie Teamfouls und Auszeiten werden wie der Spielstand aus den Ereignissen gezählt.
- `is_active` markiert das Spiel, das die Anzeige-Seite des Scoreboards gerade zeigt. Je Scoreboard ist höchstens eines aktiv.
- `name_mode` legt fest, wie Spielernamen erscheinen: `full`, `first_name` oder `number`.
- Für den Gegner genügt ein `team` ohne Spieler.
- `recovery_email` ist freiwillig und kann leer sein. Sie erscheint in keiner öffentlichen Antwort.
- `recovery_token_hash` und `recovery_token_expires_at` halten den zuletzt verschickten Wiederherstellungs-Link. Nach der Einlösung werden beide geleert.
- Mit jedem Scoreboard entstehen automatisch die Teams „Home“ und „Guest“ mit den Kürzeln „HOME“ und „GUEST“ sowie ein erstes, aktives Spiel zwischen beiden.
- Jedes weitere neue Spiel ist mit „Home“ und „Guest“ vorbelegt. Andere Teams wählt oder legt man nur bei Bedarf an.
- `clock_enabled` schaltet die Zeitmessung eines Spiels ein und aus. Die Vorgabe ist ein.
- Ein Spieler braucht mindestens eine Rückennummer oder einen Namen, nicht beides.
- `player_id` und `clock_ms` sind an jedem Ereignis freiwillig. Ein Treffer ohne Spieler und ohne Zeitangabe ist ein gültiges Ereignis.
- `competition` und `scheduled_at` sind freiwillig.
- `foul_mode` am Spiel ist `team`, `personal`, `both` oder `off`. Im Fußball ist es immer `off`.
- Ein persönliches Foul ist ein `foul`-Ereignis mit `player_id`. Auch hier darf der Spieler zunächst fehlen. Das Foul zählt dann für niemanden, bis er nachgetragen ist. Die Fouls je Spieler werden aus den Ereignissen gezählt.
- `overlay_position` ist `top_left` oder `top_right` und gilt für den kleinen Spielstand. `overlay_auto_big` schaltet den großen Spielstand in Pausen und nach Spielende von selbst ein. Die Vorgaben sind `top_left` und ein.
- `language` am Scoreboard ist `de` oder `en` und gilt für die Anzeige im Stream und für E-Mails.
- `clock_ms` am Ereignis ist die gelaufene Zeit im Abschnitt. Die Zeitangabe im Protokoll entsteht daraus erst bei der Anzeige, in der Sprache des Betrachters.
- „Unbekannt“ ist kein Spieler in der Datenbank. Ein Ereignis ohne `player_id` wird in der App und im Protokoll als „Unbekannt“ angezeigt, in der Sprache des Betrachters. So entsteht kein Platzhalter im Kader, und kein Phantomspieler sammelt Treffer oder Fouls.
- `stream_template` und `screen_template` nennen die gewählten Vorlagen. `design_mode` ist `standard` oder `custom`. `design` hält als JSON die Akzentfarbe, die Schrift und das Logo des Scoreboards.
- Teamfarben und Teamlogos stehen am `team`. Im Modus `standard` werden sie nicht verwendet.

## Schnittstellen

Die Steuer-Seite schreibt über REST, alle Anzeigen lesen über einen WebSocket. Der Dienst belegt die ganze Domain `score67.de`, die Pfade haben keinen Vorsatz.

Jedes Scoreboard hat seinen eigenen Adressraum unter `/s/{slug}`. Zugriff „Admin“ heißt: Die Anfrage trägt das Cookie eines gültigen Admin-Geräts dieses Scoreboards.

**Seiten**

| Pfad | Zugriff | Technik | Inhalt |
| --- | --- | --- | --- |
| `/` | öffentlich | HTML | Landing-Page: kurze Erklärung und der Knopf „Scoreboard anlegen“ |
| `/new` | öffentlich | Flutter | Scoreboard anlegen |
| `/s/{slug}` | öffentlich | HTML | Deeplink: Live-Spielstand für Zuschauer |
| `/s/{slug}/overlay` | öffentlich | HTML | Anzeige-Seite für OBS, zeigt immer das aktive Spiel des Scoreboards |
| `/s/{slug}/control` | Admin, sonst PIN-Abfrage | Flutter | Steuer-Seite für das Handy |
| `/s/{slug}/recover` | Token aus der E-Mail | Flutter | Wiederherstellung abschließen und neue PIN anzeigen |
| `/imprint`, `/privacy` | öffentlich | HTML | Impressum und Datenschutzerklärung |

Die Adresse der Anzeige-Seite eines Scoreboards ändert sich nie. In OBS muss deshalb vor einem neuen Spiel nichts umgestellt werden.

**REST unter `/api`**

| Methode und Pfad | Zugriff | Wirkung |
| --- | --- | --- |
| `POST /scoreboards` | öffentlich, begrenzt | Scoreboard anlegen, wahlweise mit `recovery_email`. Die Antwort enthält Slug, Links und die PIN im Klartext, nur dieses eine Mal, und setzt das Admin-Cookie. |
| `PATCH /s/{slug}` | Admin | Name, Sprache, Vorlagen und Design des Scoreboards ändern |
| `GET /templates` | öffentlich | Liste der Vorlagen mit ihrer Art (Stream oder Bildschirm) und den unterstützten Ansichten |
| `POST /s/{slug}/assets` | Admin | Logo hochladen. Die Antwort enthält die Adresse des gespeicherten Bildes. |
| `DELETE /s/{slug}/assets/{id}` | Admin | Logo entfernen |
| `POST /s/{slug}/admin/claim` | PIN | PIN prüfen, Admin-Gerät mit `label` anlegen, Cookie setzen |
| `GET /s/{slug}/admins` | Admin | Admin-Geräte auflisten |
| `DELETE /s/{slug}/admins/{id}` | Admin | Einem Gerät das Admin-Recht entziehen |
| `POST /s/{slug}/pin` | Admin | Neue PIN erzeugen und einmalig anzeigen, die alte gilt nicht mehr |
| `PUT /s/{slug}/recovery-email` | Admin | E-Mail-Adresse setzen, ändern oder entfernen |
| `POST /s/{slug}/recovery` | öffentlich, begrenzt | Wiederherstellungs-Link an die hinterlegte Adresse schicken. Die Antwort ist immer gleich, ob eine Adresse hinterlegt ist oder nicht. |
| `POST /s/{slug}/recovery/confirm` | Token aus der E-Mail | Token prüfen, Admin-Gerät anlegen, neue PIN erzeugen und einmalig anzeigen |
| `GET /sports` | öffentlich | Liste der Sportprofile mit ihren Einstellungen |
| `GET /s/{slug}/state` | öffentlich | Vollständiger Zustand des aktiven Spiels |
| `GET /s/{slug}/matches/{id}/state` | öffentlich | Zustand eines bestimmten Spiels |
| `POST /s/{slug}/matches` | Admin | Spiel anlegen, mit Sportart |
| `PATCH /s/{slug}/matches/{id}` | Admin | Stammdaten ändern, Spiel aktiv setzen |
| `PUT /s/{slug}/matches/{id}/lineup` | Admin | Aufstellung komplett setzen |
| `POST /s/{slug}/matches/{id}/events` | Admin | Ereignis eintragen: Abschnitt starten oder beenden, Treffer mit Punkten, Foul, Auszeit |
| `DELETE /s/{slug}/matches/{id}/events/{event_id}` | Admin | Ereignis zurücknehmen (setzt `cancelled`) |
| `POST /s/{slug}/matches/{id}/clock` | Admin | Uhr steuern mit `action`: `start`, `stop`, `adjust` (±n Sekunden) oder `set` (Zeit direkt setzen) |
| `POST /s/{slug}/matches/{id}/overlay` | Admin | Ansicht wählen: `scoreboard` (klein), `score_big` (groß), `lineup_home`, `lineup_away`, `hidden`. Dazu `position` (`top_left`, `top_right`) und `auto_big` (ja/nein) |
| `GET`, `POST`, `PATCH` auf `/s/{slug}/teams` und `/s/{slug}/players` | Admin | Teams und Kader des Scoreboards pflegen |

Der Server prüft jedes Ereignis gegen das Sportprofil. Ein Treffer mit 3 Punkten im Fußball oder ein `clock_stop` bei durchlaufender Uhr wird abgelehnt. Fehler kommen als Code zurück, etwa für eine gesperrte PIN, und die Seite zeigt den passenden Text in ihrer Sprache.

**WebSocket `/ws/s/{slug}`**

- Der Server schickt beim Verbinden und nach jeder Änderung den vollständigen Zustand des Scoreboards. Es gibt keine Teil-Updates.
- Clients senden nichts außer Pings. Geschrieben wird nur über REST.
- Der Client verbindet sich nach einem Abbruch selbst neu, mit wachsender Wartezeit bis höchstens 5 Sekunden.
- Fällt der WebSocket länger aus, fragt der Client alle 2 Sekunden `GET /s/{slug}/state` ab.

**Zustand als JSON, Beispiel Basketball**

```json
{
  "server_now": "2026-10-03T17:53:12Z",
  "scoreboard": "k7m2xq9dfp",
  "language": "de",
  "match_id": 12,
  "sport": "basketball",
  "phase": "period_running",
  "period": 2,
  "period_count": 4,
  "period_length_min": 10,
  "foul_mode": "team",
  "clock": {
    "enabled": true,
    "direction": "down",
    "running": true,
    "started_at": "2026-10-03T17:52:40Z",
    "elapsed_ms": 296000
  },
  "home": {
    "name": "Home", "short": "HOME", "color": "#c8102e", "score": 31,
    "counters": {"team_fouls": 3, "timeouts": 1}
  },
  "away": {
    "name": "Guest", "short": "GUEST", "color": "#1d4ed8", "score": 28,
    "counters": {"team_fouls": 4, "timeouts": 0}
  },
  "overlay": {"view": "scoreboard", "position": "top_left", "auto_big": true, "delay_ms": 2000},
  "last_score": {"event_id": 87, "team": "home", "points": 3, "period": 2, "clock_ms": 329000, "player": {"number": 9, "name": "Max"}},
  "lineup": {
    "home": {"start": [{"number": 4, "name": "Jonas"}], "bench": []},
    "away": {"start": [], "bench": []}
  },
  "events": [{"id": 87, "type": "score", "team": "home", "points": 3, "period": 2, "clock_ms": 329000, "player": {"number": 9, "name": "Max"}}]
}
```

Im Fußball hat der Zustand dieselbe Form: `clock.direction` ist `up`, `counters` ist leer und `points` ist immer 1.

Der Zustand enthält keine übersetzten Texte. Kürzel wie „Q2“ und Zeitangaben wie „Q2 04:31“ oder „23.“ bildet die Seite selbst aus `period`, `period_count` und `clock_ms`, in ihrer Sprache.

Zählt ein Spiel persönliche Fouls, trägt jeder Spieler in `lineup` zusätzlich das Feld `fouls`, und `counters.team_fouls` entfällt.

Die Namen im Zustand sind bereits nach `name_mode` gekürzt. Die öffentliche Schnittstelle gibt nie mehr preis, als im Stream zu sehen ist.

## Anzeige-Seite

Die Anzeige-Seite ist eine einzelne HTML-Seite in 1920×1080 mit transparentem Hintergrund. Sie kommt als Jinja-Template mit einfachem CSS und JavaScript aus, ohne Build-Schritt und ohne Flutter.

| Ansicht | Inhalt | Wann |
| --- | --- | --- |
| Scoreboard klein | Kürzel Heim, Spielstand, Kürzel Gast, Uhr und Abschnitts-Kürzel; im Basketball zusätzlich die Teamfouls, wenn das Spiel sie zählt; in einer oberen Ecke, links oder rechts | Während des Spiels, Standardansicht |
| Aufstellung groß | Teamname, Logo, Startaufstellung mit Nummer und Name, Bank, Trainer | Per Knopf, meist vor Spielbeginn und in den Pausen |
| Treffer-Einblendung | Fußball: „TOR“, Spielminute, Torschütze und neuer Stand für 8 Sekunden. Basketball: keine Einblendung, der Spielstand pulsiert kurz | Automatisch bei jedem Treffer |
| Spielstand groß | Großer Spielstand mit Teamnamen in der Bildmitte, auf Wunsch mit der Überschrift „Halbzeit“, „Pause“ oder „Endstand“. Soweit vorhanden, stehen darunter im Fußball die Torschützen und im Basketball die Ergebnisse der Abschnitte | Jederzeit per Knopf „Groß“. Zusätzlich automatisch in den Phasen `break` und `finished`, die Automatik ist abschaltbar |
| Ausgeblendet | Nichts | Per Knopf, etwa für Wiederholungen |

Die beiden Größen des Spielstands sind die wichtigsten Ansichten. Beide funktionieren auch ohne Uhr, ohne Abschnitt und ohne Spielerdaten und zeigen dann nur Teamnamen und Spielstand.

**Verhalten**

- **Sportart:** Die Seite wählt das Layout nach `sport` im Zustand. Jede Sportart hat ein eigenes Template-Fragment für das kleine Scoreboard, alle anderen Ansichten sind gemeinsam.
- **Verzögerung:** Jede Änderung wird erst nach `overlay.delay_ms` sichtbar. Damit erscheint ein Treffer auf der Tafel nicht, bevor er im verzögerten Kamerabild fällt.
- **Uhr:** läuft lokal aus dem Uhrzustand und wird zehnmal pro Sekunde neu gezeichnet. Steht `clock.running` auf falsch, bleibt sie stehen.
- **Verbindungsabbruch:** Die Seite zeigt den letzten Stand weiter und lässt eine laufende Uhr weiterlaufen. Im Stream erscheint nie eine Fehlermeldung.
- **Lesbarkeit:** Schrift im kleinen Scoreboard mindestens 28 px, damit sie auch bei 720p lesbar bleibt. Abstand zum Bildrand 48 px.
- **Übergänge:** Ein- und Ausblenden in höchstens 400 ms.
- **Farben:** Die Teamfarben kommen aus `team.color_primary`. Text steht immer auf dunklem, halbtransparentem Grund, damit er auf Rasen und Hallenboden lesbar ist.
- **Ohne Uhr:** Ist die Zeitmessung aus, zeigt das kleine Scoreboard nur Kürzel, Spielstand und Abschnitt und wird entsprechend schmaler. Ist auch kein Abschnitt gestartet, zeigt es nur Kürzel und Spielstand.
- **Fehlende Angaben:** Jede Ansicht zeigt nur, was vorhanden ist. Die Tor-Einblendung kommt ohne Schütze und ohne Minute aus. Bei einem unbekannten Schützen zeigt der Stream keinen Namen statt des Wortes „Unbekannt“. Die Aufstellung zeigt je Spieler Nummer, Name oder beides.
- **Persönliche Fouls:** Sie erscheinen nur auf der Steuer-Seite, nicht im Stream.

**URL-Parameter**

- `?delay=3000` überschreibt die Verzögerung für diese eine Quelle.
- `?preview=1` legt einen dunklen Hintergrund unter die Seite, zum Testen im normalen Browser.
- `?view=small` oder `?view=big` legt diese Quelle fest auf den kleinen oder den großen Spielstand, unabhängig von der Steuer-Seite.
- `?pos=tl` oder `?pos=tr` setzt den kleinen Spielstand für diese Quelle in die linke oder rechte obere Ecke.
- `?lang=de` oder `?lang=en` legt die Sprache dieser Quelle fest und übersteuert die Einstellung des Scoreboards.
- `?template=bar` zeigt diese Quelle in einer bestimmten Vorlage, unabhängig von der Einstellung des Scoreboards.

## Designs

Das Aussehen kommt aus Vorlagen. Jedes Scoreboard startet mit einem Standard-Design, das ohne jede Eingabe funktioniert, und lässt sich auf ein eigenes Design mit Farben und Logos umstellen.

**Vorlagen**

Eine Vorlage ist entweder für den Stream oder für den Bildschirm gebaut. Beide werden getrennt gewählt.

| Art | Wo sie erscheint | Eigenschaften | Vorlagen zum Start |
| --- | --- | --- | --- |
| Stream | Anzeige-Seite in OBS | Transparenter Hintergrund, 1920×1080, Spielstand klein und groß, lesbar über bewegtem Bild | „Standard“ und „Balken“ |
| Bildschirm | Zuschauer-Seite auf dem Handy | Füllt den ganzen Bildschirm, passt sich Hoch- und Querformat an, große Ziffern | „Tafel“ und „Hell“ |

- **Aufbau:** Jede Vorlage ist ein eigener Ordner mit einem HTML-Fragment und einer CSS-Datei. Alle Vorlagen lesen denselben Zustand, eine neue Vorlage braucht keine Änderung am Backend.
- **Ansichten:** Jede Vorlage gibt an, welche Ansichten sie beherrscht: Spielstand klein, Spielstand groß, Aufstellung, Tor-Einblendung. Fehlt eine Ansicht, springt dafür die Vorlage „Standard“ ein.
- **Trennung:** Bildschirm-Vorlagen haben keinen transparenten Hintergrund und werden für OBS nicht angeboten. Stream-Vorlagen werden auf dem Handy nicht angeboten.
- **Vorschau:** Die App zeigt beim Auswählen eine Live-Vorschau mit dem aktuellen Spielstand.
- **Namen:** Die Vorlagen haben englische Schlüssel: `standard`, `bar`, `board` und `light`. Die angezeigten Namen kommen aus den Sprachdateien.

**Standard und eigenes Design**

- **Standard:** Es sind keine Eingaben nötig. „Home“ und „Guest“ bekommen zwei feste, gut unterscheidbare Farben.
- **Eigenes Design:** Je Team eine Haupt- und eine Zweitfarbe und ein Logo. Dazu ein Logo des Scoreboards, etwa vom Verein oder der Liga, eine Akzentfarbe und eine von drei Schriften.
- **Gilt für jede Vorlage:** Farben, Logos und Schrift werden einmal eingestellt und von jeder Vorlage übernommen. Ein Wechsel der Vorlage verliert nichts.
- **Zurück auf Standard:** Jederzeit mit einem Schalter. Die eigenen Eingaben bleiben gespeichert.

**Logos**

- Erlaubt sind PNG, JPEG und WebP bis 1 MB. Der Server verkleinert jedes Bild und speichert es neu.
- SVG ist nicht erlaubt, weil SVG-Dateien Skripte enthalten können.
- Nur Admins eines Scoreboards können Logos hochladen und entfernen.

## Steuer-Seite

Die Steuer-Seite ist Teil der Flutter-Web-App und für ein Handy im Hochformat gebaut und mit einer Hand bedienbar. Alle Knöpfe sind mindestens 56 px hoch. Welche Knöpfe erscheinen, bestimmt das Sportprofil des aktiven Spiels.

**Zugang und Verwaltung**

- Hat das Gerät kein Admin-Recht, fragt die Seite nach der PIN und einem Namen für das Gerät. Darunter steht der Link „PIN vergessen“.
- Der Bereich „Einstellungen“ zeigt die drei Links mit QR-Code, die Liste der Admin-Geräte, die E-Mail-Adresse für die Wiederherstellung und die Knöpfe „Gerät entziehen“ und „Neue PIN“.
- Die PIN ist nach dem Anlegen nie wieder sichtbar. Wer sie vergessen hat, erzeugt als Admin eine neue oder nutzt die Wiederherstellung per E-Mail.
- Jede Seite hat einen Sprachumschalter. Die Sprache der Anzeige im Stream steht in den Einstellungen des Scoreboards.
- Der Bereich „Design“ bietet die Wahl der Vorlage für Stream und Handy mit Vorschau, den Schalter zwischen Standard und eigenem Design sowie Farben, Schrift und Logos.

**Vor dem Spiel**

1. Nichts ist Pflicht. Das Spiel „Home“ gegen „Guest“ steht bereit und kann sofort beginnen.
2. Freiwillig: Teamnamen, Kürzel und Farben ändern und das Spielformat wählen, zum Beispiel „8 Achtel à 5“ oder ein eigenes Format.
3. Freiwillig: Kader und Aufstellung pflegen. Der Kader erscheint als Liste, ein Tipp setzt einen Spieler in die Startaufstellung, ein zweiter auf die Bank.
4. Für ein weiteres Spiel „Neues Spiel“ wählen. Es ist wieder mit „Home“ und „Guest“ vorbelegt und wird sofort das aktive Spiel.

**Während des Spiels**

Alles liegt auf einem Bildschirm. Oben steht der Spielkopf mit Home links, Guest rechts und Uhr und Abschnitt in der Mitte. Darunter liegen je Team die Aktionsknöpfe, ganz unten das Protokoll der letzten Ereignisse.

| Bereich | Fußball | Basketball |
| --- | --- | --- |
| Spielabschnitt | Ein Knopf mit wechselnder Aufschrift: Anpfiff, Pause, Wiederanpfiff, Abpfiff, je nach Zahl der Abschnitte. Ein Minispiel kennt nur Anpfiff und Abpfiff. Auslösen durch Halten für eine Sekunde. | Ein Knopf mit wechselnder Aufschrift: Abschnitt starten, Abschnitt beenden, nach dem letzten Abschnitt bei Gleichstand „Verlängerung starten“, sonst Spielende. Auslösen durch Halten. |
| Uhr | Läuft durch. Korrektur mit −10 s, +10 s, −1 min, +1 min. | Großer Knopf für Start und Stopp. Korrektur mit −1 s, +1 s, −10 s, +10 s und Restzeit direkt setzen. |
| Treffer | „Tor Home“ und „Tor Guest“. Das Tor zählt sofort. Ist eine Aufstellung gepflegt, lässt sich danach der Torschütze wählen. | Je Team die Knöpfe „+1“, „+2“ und „+3“. Der Schütze ist freiwillig. |
| Zusatzzähler | Keine. | Je Team ein Knopf „Foul“ und ein Knopf „Auszeit“. Zählt das Spiel persönliche Fouls, fragt „Foul“ nach dem Spieler: aus der Liste wählen, die Rückennummer eintippen oder „Unbekannt“ wählen. Die Liste zeigt je Spieler die Zahl der Fouls. Ist die Foul-Zählung aus, fehlt der Knopf. |
| Rückgängig | Nimmt das letzte Ereignis zurück und zeigt vorher, welches. | Wie Fußball. |
| Einblendungen | Drei Knöpfe für den Spielstand: „Klein“ in der Ecke, „Groß“ in der Bildmitte und „Aus“. Die Knöpfe für die Aufstellungen erscheinen nur, wenn eine Aufstellung gepflegt ist. | Wie Fußball. |
| Vorschau | Oben auf der Seite steht der aktuelle Stand mit Uhr, so wie ihn die Anzeige zeigt. | Wie Fußball, zusätzlich mit Teamfouls oder der Foul-Liste der Spieler. |

**Mit wenig Information arbeiten**

- **Ohne Kader:** Treffer und Auszeiten gehören nur zum Team, die Auswahl eines Spielers erscheint gar nicht erst. Bei persönlichen Fouls lässt sich die Rückennummer direkt eintippen oder „Unbekannt“ wählen.
- **Nur Nummern:** Bei der Spielerauswahl lässt sich statt eines Namens einfach eine Rückennummer eintippen. Daraus entsteht ein Spieler ohne Namen, der später ergänzt werden kann.
- **Unbekannt:** In jeder Spielerauswahl steht „Unbekannt“ als erster Eintrag. Der Treffer zählt sofort für das Team, und im Protokoll steht „Unbekannt“, bis der Spieler mit einem Tipp nachgetragen wird.
- **Ohne Zeitmessung:** Im Uhr-Bereich liegt der Schalter „Zeitmessung“. Ist er aus, verschwinden die Uhr-Knöpfe. Der Knopf für den Spielabschnitt bleibt, muss aber nicht benutzt werden.
- **Nachtragen:** Namen, Nummern, Schützen und Zeitangaben lassen sich nach dem Spiel im Protokoll ergänzen.

**Nach dem Spiel**

- Protokoll ansehen und korrigieren: Zeitangabe, Punkte und Schütze. Einträge mit „Unbekannt“ sind markiert und lassen sich gezielt nachtragen.
- Export als Text für die YouTube-Beschreibung und die Homepage.

**Absicherung der Bedienung**

- Das Spielende verlangt eine zusätzliche Bestätigung.
- Jede Aktion bestätigt sich mit einer kurzen Meldung.
- Ohne Verbindung sind die Knöpfe gesperrt, und die Seite sagt das deutlich.
- Zwei Personen können gleichzeitig steuern. Beide sehen Änderungen sofort über den WebSocket.

## Einbindung in OBS

In OBS ist das Scoreboard eine einzige Browserquelle, die in einer eigenen Szene liegt und in jede Kamera-Szene eingehängt wird. So bleibt es beim Umschalten der Kameras unverändert stehen.

1. Eine Szene „Overlay“ anlegen.
2. Darin eine **Browserquelle** hinzufügen: URL `https://score67.de/s/<slug>/overlay`, Breite 1920, Höhe 1080.
3. Die Optionen „Quelle herunterfahren, wenn nicht sichtbar“ und „Browser aktualisieren, wenn Szene aktiv wird“ ausgeschaltet lassen. Sonst lädt die Seite bei jedem Kamerawechsel neu.
4. In jeder Kamera-Szene über **+ → Szene** die Szene „Overlay“ als oberste Quelle einfügen.
5. Auf der Steuer-Seite ein Testspiel aktiv setzen und einen Treffer drücken. Er muss in der OBS-Vorschau erscheinen.

**Groß und klein in OBS**

Für den Wechsel zwischen kleinem und großem Spielstand gibt es zwei Wege.

- **Vom Handy:** Eine einzige Browserquelle zeigt, was auf der Steuer-Seite gewählt ist. „Groß“ blendet den Spielstand mittig ein, „Klein“ setzt ihn zurück in die Ecke.
- **Fest in OBS:** Zwei Browserquellen mit `?view=small` und `?view=big` liegen in verschiedenen Szenen, zum Beispiel der große Spielstand in einer Szene „Halbzeit“. Umgeschaltet wird dann mit dem Szenenwechsel in OBS, und die Steuer-Seite ändert an diesen Quellen nichts.

**Verzögerung einstellen**

Das Kamerabild kommt über MediaMTX ein bis drei Sekunden verspätet an. Einmal messen genügt: vor der Kamera gut sichtbar einen Treffer-Knopf drücken und in OBS zählen, wie viel früher die Tafel reagiert als das Bild. Diesen Wert als `overlay_delay_ms` eintragen.

**Voraussetzungen**

- OBS als Flatpak, weil nur diese Variante unter Linux Mint die Browserquelle mitbringt.
- Internet am Laptop. Das ist für YouTube ohnehin nötig.
- HTTPS auf dem Server, damit der WebSocket als `wss://` läuft.

**Homepage**

Die Homepage kann denselben Zustand über `GET /api/s/{slug}/state` abrufen und als Live-Spielstand anzeigen. Dafür ist keine weitere Entwicklung am Dienst nötig.

## Sicherheit und Datenschutz

Lesen darf jeder, schreiben nur ein Admin-Gerät des jeweiligen Scoreboards. Die öffentliche Seite zeigt nichts, was nicht ohnehin im Stream zu sehen ist.

**Zugriff**

- Die Steuer-Seite und alle schreibenden Endpunkte verlangen das Cookie eines gültigen Admin-Geräts dieses Scoreboards.
- Das Admin-Token ist zufällig und mindestens 32 Byte lang. Es liegt als Cookie mit `HttpOnly`, `Secure` und `SameSite=Lax` im Browser, der Server speichert nur den Hash.
- Die PIN wird nur als Hash gespeichert. Nach 5 falschen Eingaben ist die PIN-Abfrage für dieses Scoreboard 15 Minuten gesperrt.
- Das Anlegen ist begrenzt, je IP-Adresse auf höchstens 5 neue Scoreboards pro Stunde.
- Ein entzogenes Gerät verliert den Zugriff sofort, auch auf einer schon geöffneten Steuer-Seite.
- Der Dienst läuft nur über HTTPS.
- Deeplink, Anzeige-Seite und Zustand sind öffentlich lesbar. Der Slug ist nicht erratbar, aber kein Geheimnis: Wer den Link kennt, kann mitlesen und nichts ändern.
- Die Wiederherstellung per E-Mail ist begrenzt auf höchstens 3 Anfragen pro Stunde je Scoreboard. Der Link gilt 30 Minuten und nur einmal, der Server speichert nur den Hash des Tokens.
- Die E-Mail-Adresse wird nur für die Wiederherstellung verwendet, nie angezeigt und nie weitergegeben. Admins können sie jederzeit entfernen.
- Die Flutter-App läuft unter derselben Domain wie das Backend. Das Admin-Cookie gilt deshalb auch für ihre Anfragen, und sie speichert kein Token selbst.
- Hochgeladene Logos prüft der Server auf Dateityp und Größe und speichert sie neu kodiert. Je Scoreboard sind höchstens 10 Bilder erlaubt.

**Spielernamen**

- `name_mode` am Spiel bestimmt die Darstellung: voller Name, nur Vorname oder nur Rückennummer.
- `name_public` am Spieler hält fest, ob eine Freigabe für den Namen vorliegt. Ohne Freigabe erscheint nur die Nummer, egal was `name_mode` sagt.
- Bei Jugendmannschaften ist die Vorgabe `first_name`, bis alle Eltern zugestimmt haben.
- Über Spieler speichert der Dienst keine weiteren persönlichen Daten, insbesondere keine Geburtsdaten.

**Nachvollziehbarkeit**

`match_event` ist zugleich das Protokoll. Zurückgenommene Ereignisse bleiben mit `cancelled` erhalten.

## Ausbaustufen und Abnahmekriterien

Gebaut wird in sechs Stufen. Nach der ersten ist das Scoreboard für Fußball im Stream einsetzbar, nach der zweiten auch für Basketball.

| Stufe | Inhalt | Fertig, wenn |
| --- | --- | --- |
| 1. Grundgerüst mit Fußball | FastAPI-Backend mit Zustand und WebSocket, Flutter-Web-App für Anlegen und Steuerung, HTML-Landing-Page und HTML-Ergebnisseiten, Scoreboards anlegen mit Deeplink und PIN, Admin-Geräte, Wiederherstellung per E-Mail, Sportprofile als Konfiguration, Sprachdateien für Deutsch und Englisch, Fußball-Profil, kleiner Spielstand in der Ecke und großer Spielstand in der Bildmitte, Zuschauer-Seite mit Live-Spielstand, die Vorlagen „Standard“ für den Stream und „Tafel“ für das Handy, Steuer-Seite mit Abschnitten, Toren, Rückgängig, Uhr-Korrektur und Schalter für die Zeitmessung | Ein neues Scoreboard liefert Deeplink und PIN, und das Spiel „Home“ gegen „Guest“ lässt sich ohne weitere Eingabe starten. Ein Spiel lässt sich vollständig ohne Uhr und ohne Spielerdaten begleiten. Ein Minispiel mit einem Abschnitt und ein Spiel mit zwei Halbzeiten frei gewählter Länge laufen durch. Ein zweites Gerät wird mit der PIN Admin. Ein entzogenes Gerät kann nichts mehr ändern. Der Link aus der Wiederherstellungs-E-Mail macht ein Gerät ohne PIN zum Admin und funktioniert kein zweites Mal. Zwei Scoreboards laufen gleichzeitig, ohne sich zu beeinflussen. Der Spielstand lässt sich vom Handy zwischen klein in der Ecke und groß in der Bildmitte umschalten, und beide Größen sind bei 720p lesbar. Alle Seiten und die Anzeige im Stream lassen sich zwischen Deutsch und Englisch umschalten, ohne dass ein fester Text stehen bleibt. Ein Tor vom Handy erscheint in OBS nach der eingestellten Verzögerung plus höchstens 1 Sekunde. Die Uhr weicht nach 45 Minuten um weniger als 1 Sekunde ab. Nach 30 Sekunden ohne Netz zeigt die Anzeige von selbst wieder den richtigen Stand. Die Uhr ist schon mit Start, Stopp und Laufrichtung gebaut, auch wenn Fußball nur das Hochzählen nutzt. |
| 2. Basketball | Basketball-Profil mit Countdown-Uhr, Start, Stopp und Setzen der Restzeit, Treffer mit 1, 2 und 3 Punkten, Teamfouls und persönliche Fouls, Auszeiten, Verlängerung, eigenes Layout für das kleine Scoreboard | Nach zehn Stopps und Starts stimmt die Restzeit auf 1 Sekunde genau mit der Summe der Laufzeiten überein. Ein neuer Abschnitt setzt Uhr und Teamfouls zurück. Ein Spiel mit persönlichen Fouls zeigt keine Teamfouls und zählt die Fouls je Rückennummer über das ganze Spiel. Die Formate 4 × 10, 4 × 12, 8 × 5 und 2 Halbzeiten laufen jeweils vollständig durch. Ein Fußballspiel läuft danach unverändert. |
| 3. Aufstellung | Teams und Kader je Sportart pflegen, Aufstellung je Spiel, große Einblendung | Eine Aufstellung mit 11 Spielern und 7 auf der Bank ist bei 720p lesbar, ebenso eine mit 5 und 7. Ein- und Ausblenden geht mit je einem Knopf. |
| 4. Treffer und Protokoll | Schütze beim Treffer wählen, Tor-Einblendung im Fußball, Torschützen und Abschnitts-Ergebnisse im großen Spielstand, Protokoll mit Export | Die Tor-Einblendung zeigt Minute und Schütze und verschwindet nach 8 Sekunden. Das Protokoll lässt sich für beide Sportarten als Text kopieren. |
| 5. Designs | Eigenes Design mit Farben, Schrift und Logos, Logo-Upload, die weiteren Vorlagen „Balken“ für den Stream und „Hell“ für das Handy, Vorschau in der App | Ein hochgeladenes Logo erscheint im Stream und auf dem Handy. Ein Wechsel der Vorlage ändert das Aussehen ohne neue Eingaben. Beide Stream-Vorlagen sind bei 720p über einem Spielbild lesbar. |
| 6. Erweiterungen | Auswechslungen, Karten, Sponsor-Banner, Live-Spielstand auf der Homepage, weitere Sportarten | Wird festgelegt, wenn Stufe 5 im Einsatz ist. |

**Test vor dem ersten Spiel**

- [ ] Je Sportart ein komplettes Testspiel mit auf 2 Minuten verkürzten Abschnitten durchspielen
- [ ] Verzögerung gegen das Kamerabild messen und eintragen
- [ ] Steuer-Seite über Mobilfunk bedienen, nicht über das WLAN am Platz
- [ ] WLAN am Laptop für 30 Sekunden trennen und prüfen, dass die Anzeige sich erholt

## Offene Entscheidungen

Zwölf Punkte sind vor dem Bau zu klären. Wo die Spezifikation schon eine Annahme trifft, steht sie dabei.

- [ ] **Eigenständig oder Modul:** eigener FastAPI-Dienst oder Router in einer bestehenden Anwendung? Annahme: eigenständiger Dienst unter `score67.de`, so geschrieben, dass er sich als Router einhängen lässt.
- [x] **Domain:** Entschieden. Der Dienst läuft unter score67.de auf einem eigenen Server.
- [ ] **PIN:** sechs Ziffern mit Sperre nach Fehlversuchen oder ein längerer Code? Annahme: sechs Ziffern.
- [ ] **Gegner:** nur Name und Kürzel oder auch dessen Aufstellung? Annahme: nur Name und Kürzel.
- [ ] **Namen:** voller Name, Vorname oder nur Rückennummer? Annahme: Vorname.
- [x] **Gestaltung:** Entschieden. Es gibt ein Standard-Design, ein eigenes Design mit Farben und Logos und mehrere Vorlagen, getrennt für Stream und Handy.
- [ ] **Spielzeiten:** Welche Längen sollen bei „2 Halbzeiten“ und „Minispiel“ vorbelegt sein, und fehlt ein gängiges Format in der Schnellwahl? Annahme: Fußball 45 und 10 Minuten, Basketball 20 Minuten je Halbzeit.
- [ ] **Basketball-Uhr:** gestoppte Uhr wie in der Halle oder durchlaufende Uhr, falls niemand die Uhr mitbedienen kann? Annahme: gestoppte Uhr, pro Spiel umschaltbar.
- [ ] **Basketball-Anzeige:** Teamfouls und Auszeiten im Scoreboard zeigen oder nur Spielstand und Uhr? Annahme: Teamfouls ja, Auszeiten nur im Protokoll.
- [x] **Verlorene PIN:** Entschieden. Beim Anlegen kann eine freiwillige E-Mail-Adresse zur Wiederherstellung hinterlegt werden.
- [ ] **Gültigkeit des Admin-Rechts:** unbegrenzt oder mit Ablauf? Annahme: 180 Tage nach der letzten Nutzung.
- [ ] **Aufräumen:** Sollen ungenutzte Scoreboards gelöscht werden? Annahme: nach 12 Monaten ohne Nutzung.
- [ ] **E-Mail-Versand:** Über welchen SMTP-Zugang und von welcher Absenderadresse verschickt der Server die Wiederherstellungs-Links?
- [x] **Sprache:** Entschieden. Die Oberfläche ist mehrsprachig, zum Start Deutsch und Englisch.
- [x] **Teamfouls bei 8 Achteln:** Entfällt. In den kleinen Altersklassen gibt es keine Teamfouls, das Format „8 Achtel à 5“ zählt nur persönliche Fouls.
- [ ] **Impressum und Datenschutz:** Wer steht als Betreiber im Impressum, und wer liefert den Text der Datenschutzerklärung?
- [ ] **Vorlagen zum Start:** Wie sollen die vier Vorlagen aussehen? Annahme: „Standard“ und „Balken“ für den Stream, „Tafel“ und „Hell“ für das Handy. Die Entwürfe dafür fehlen noch.
