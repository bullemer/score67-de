// Score67 LED panel: Wi-Fi → register at score67.de → live feed over WSS →
// the scoreboard (render.cpp). Buttons: DOWN short = show the connection
// code for 10 s during a game; UP held 5 s = Wi-Fi setup hotspot; UP + DOWN
// held 10 s = factory reset (new display, new code).
// Serial (115200): ? status, c code, w portal, r factory reset, panel32/panel64/panel128, t1..t8 (t0 off).
#include <Arduino.h>
#include <Adafruit_Protomatter.h>
#include <Preferences.h>
#include <esp_ota_ops.h>
#include "config.h"
#include "feed.h"
#include "net.h"
#include "intro.h"
#include "ble_test.h"
#include "breakout.h"
#include "galaga.h"
#include "render.h"
#include "tables.h"

uint8_t rgbPins[] = {PIN_R1, PIN_G1, PIN_B1, PIN_R2, PIN_G2, PIN_B2};
uint8_t addrPins[] = {PIN_A, PIN_B, PIN_C, PIN_D, PIN_E};
int panelWidth = PANEL_W, panelHeight = PANEL_H;
Adafruit_Protomatter *panel = nullptr;

// Draws into the Protomatter canvas; the feed's brightness scales every colour.
struct PanelCanvas : Canvas {
  int brightness = 60;
  int width() const override { return panelWidth; }
  int height() const override { return panelHeight; }
  void set(int x, int y, uint32_t rgb) override {
    uint8_t r = (rgb >> 16) * brightness / 100, g = ((rgb >> 8) & 255) * brightness / 100, b = (rgb & 255) * brightness / 100;
    panel->drawPixel(x, y, panel->color565(r, g, b));
  }
} canvas;

Breakout breakout;
Galaga galaga;
enum class ArcadeScreen { MENU, GAME };
ArcadeScreen arcadeScreen = ArcadeScreen::MENU;
int arcadeSelection = 0;
int arcadeGame = 0;
Feed feed;
uint32_t received = 0;        // millis() when the current feed arrived (clock, scrolling)
uint32_t showCodeUntil = 0;   // DOWN pressed during a game: the code instead of the score
uint32_t bothSince = 0;
int testPattern = 0;          // serial t1..t8: panel test instead of the feed (t0 = back)
bool otaTrial = false;

void otaBootCheck() {
  Preferences p;
  if (!p.begin("s67-ota", false)) return;
  uint32_t target = p.getUInt("target", 0), previous = p.getUInt("previous", 0);
  const esp_partition_t *running = esp_ota_get_running_partition();
  if (target && running && running->address == target) {
    unsigned boots = p.getUInt("boots", 0) + 1;
    p.putUInt("boots", boots);
    if (boots >= 3) {
      const esp_partition_t *old = nullptr;
      esp_partition_iterator_t it = esp_partition_find(ESP_PARTITION_TYPE_APP, ESP_PARTITION_SUBTYPE_ANY, nullptr);
      while (it) { const esp_partition_t *candidate = esp_partition_get(it); if (candidate->address == previous) { old = candidate; esp_partition_iterator_release(it); break; } it = esp_partition_next(it); }
      if (old && esp_ota_set_boot_partition(old) == ESP_OK) { p.clear(); p.end(); ESP.restart(); }
    }
    otaTrial = true;
  } else if (target) p.clear();
  p.end();
}

// Full-brightness test patterns to tell panel faults from controller faults:
// a pixel dark in t1-t4 is a dead LED (or channel), lit in t5 is stuck on.
void drawTest(uint32_t now) {
  static const uint16_t solid[] = {0xffff, 0xf800, 0x07e0, 0x001f, 0x0000};
  if (testPattern <= 5) { panel->fillScreen(solid[testPattern - 1]); return; }
  if (testPattern == 6) {   // checkerboard, swaps every second
    int phase = (now / 1000) & 1;
    for (int y = 0; y < panelHeight; y++)
      for (int x = 0; x < panelWidth; x++) panel->drawPixel(x, y, ((x + y + phase) & 1) ? 0xffff : 0);
    return;
  }
  if (testPattern == 7) {   // one white pixel walking row by row, position on serial
    static int i = -1;
    static uint32_t last = 0;
    if (now - last >= 150) { i = (i + 1) % (panelWidth * panelHeight); last = now; Serial.printf("[test] x %d y %d\n", i % panelWidth, i / panelWidth); }
    panel->drawPixel(i % panelWidth, i / panelWidth, 0xffff);
    return;
  }
  // t8: grid lines every 8 pixels, labelled corners
  for (int x = 0; x < panelWidth; x += 8) panel->drawFastVLine(x, 0, panelHeight, 0x07e0);
  for (int y = 0; y < panelHeight; y += 8) panel->drawFastHLine(0, y, panelWidth, 0x07e0);
  panel->drawFastVLine(panelWidth - 1, 0, panelHeight, 0x07e0);
  panel->drawFastHLine(0, panelHeight - 1, panelWidth, 0x07e0);
  panel->drawPixel(0, 0, 0xf800);
  panel->drawPixel(panelWidth - 1, panelHeight - 1, 0x001f);
}

void onFeed(const Feed &f) {
  bool first = !feed.valid;
  feed = f;
  received = millis();
  if (otaTrial) { Preferences p; if (p.begin("s67-ota", false)) { p.clear(); p.end(); otaTrial = false; } }
  if (first || f.identify) Serial.printf("[feed] mode %s seq %ld\n", f.mode, f.seq);
}

// 3x5 text centred on a row (status screens).
void centred(const char *s, int y, uint32_t color, uint32_t now = 0) {
  int n = strlen(s), w = n ? n * 4 - 1 : 0;
  int x = w > panelWidth ? panelWidth - (now / 80) % (w + panelWidth) : (panelWidth - w) / 2;
  for (const char *p = s; *p; p++, x += 4) {
    char ch = *p >= 'a' && *p <= 'z' ? *p - 32 : *p;
    const uint8_t *g = FONT_SMALL[(ch >= 32 && ch <= 90) ? ch - 32 : 0];
    for (int row = 0; row < 5; row++)
      for (int col = 0; col < 3; col++)
        if (g[row] & (4 >> col)) canvas.set(x + col, y + row, color);
  }
}

void statusScreen(const NetStatus &st, uint32_t now) {
  centred("SCORE67", 3, COLOR_DIM);
  char dots[4] = "";
  for (int i = 0; i < (int)((now / 500) % 4); i++) strcat(dots, ".");
  char line[20];
  if (st.state == NetState::PORTAL) {
    // Setup: connect the phone to this hotspot; the page opens by itself.
    centred("HOTSPOT", 10, COLOR_TEXT);
    centred(st.apName, 18, COLOR_SCORE);
    centred(st.apIp, 26, COLOR_DIM);
  } else if (st.state == NetState::WIFI_CONNECTING) {
    snprintf(line, sizeof line, "WLAN%s", dots);
    centred(line, 13, COLOR_TEXT);
    char ssid[16];
    snprintf(ssid, sizeof ssid, "%.15s", st.ssid[0] ? st.ssid : "(KEIN WLAN)");
    centred(ssid, 23, COLOR_DIM);
  } else {
    snprintf(line, sizeof line, "VERBINDE%s", dots);
    centred(line, 13, COLOR_TEXT);
    centred(st.state == NetState::REGISTERING ? "ANMELDUNG" : "SERVER", 23, COLOR_DIM);
  }
}

void codeScreen() {
  Feed pairing = feed;
  strcpy(pairing.mode, "pairing");
  renderFeed(canvas, pairing, 0);
}

void logoScreen() {
  renderPolonia(canvas);
}

void buttons(uint32_t now) {
  static bool downWas = false, upWas = false, upUsed = false;
  static uint32_t downSince = 0, upSince = 0;
  bool up = digitalRead(PIN_BUTTON_UP) == LOW, down = digitalRead(PIN_BUTTON_DOWN) == LOW;
  // UP held 5 s: Wi-Fi setup hotspot (a short DOWN press in the portal leaves it again).
  if (up && !upWas) { upSince = now; upUsed = false; }
  if (up && !upUsed && now - upSince > 5000 && !down) { upUsed = true; net.startPortal(); feed = Feed(); }
  upWas = up;
  if (up && down) {
    if (!bothSince) bothSince = now;
    if (now - bothSince > 10000) {
      Serial.println("[btn] factory reset");
      net.forgetDevice();
      feed = Feed();
      bothSince = now + 60000;   // once
    }
    return;
  }
  bothSince = 0;
  if (down && !downWas) downSince = now;
  if (!down && downWas && now - downSince < 1000) {
    if (net.status().state == NetState::PORTAL && net.status().networks) net.stopPortal();
    else if (feed.code[0]) showCodeUntil = now + 10000;
  }
  downWas = down;
}

void setup() {
  Serial.begin(115200);
  otaBootCheck();
  pinMode(PIN_BUTTON_UP, INPUT_PULLUP);
  pinMode(PIN_BUTTON_DOWN, INPUT_PULLUP);
  Preferences displayPrefs;
  if (displayPrefs.begin("s67-display", true)) {
    int savedHeight = displayPrefs.getInt("height", PANEL_H);
    int savedWidth = displayPrefs.getInt("width", PANEL_W);
    if ((savedWidth == 64 && (savedHeight == 32 || savedHeight == 64)) || (savedWidth == 128 && savedHeight == 64)) panelWidth = savedWidth;
    if (savedHeight == 32 || savedHeight == 64) panelHeight = savedHeight;
    displayPrefs.end();
  }
  panel = new Adafruit_Protomatter(panelWidth, panelHeight == 64 ? 4 : 6, 1, rgbPins, panelHeight == 64 ? 5 : 4,
                                    addrPins, PIN_CLK, PIN_LAT, PIN_OE, true);
  ProtomatterStatus status = panel->begin();
  // Past the bootloader's double-tap window; the panel shows the version meanwhile.
  centred("SCORE67", 9, COLOR_SCORE);
  centred("V" FW_VERSION, 18, COLOR_DIM);
  panel->show();
  for (int i = 0; i < 4; i++) { Serial.printf("score67 boot %d\n", i); delay(500); }
  Serial.printf("score67 panel fw %s, protomatter status %d (0 = ok), server %s:%d tls %d\n",
                FW_VERSION, (int)status, SCORE67_HOST, SCORE67_PORT, SCORE67_TLS);
  Intro::begin();
  net.onFeed = onFeed;
  net.begin();
  BleTest::start();
}

void loop() {
  uint32_t now = millis();
  net.loop();
  if (otaTrial && millis() > 120000) ESP.restart();
  BleTest::loop(now);
  buttons(now);
  static String line;
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\n' || ch == '\r') {
      const NetStatus &st = net.status();
      if (line == "?") Serial.printf("state %d wifi %s rssi %d id %s token %d feed %s code %s heap %u\n", (int)st.state, st.ssid, st.rssi,
                                     st.displayId, st.haveToken, feed.valid ? feed.mode : "-", feed.code, ESP.getFreeHeap());
      else if (line == "c") showCodeUntil = now + 10000;
      else if (line == "ble" || line == "breakout") { breakout.reset(panelWidth, panelHeight, now); BleTest::start(); }
      else if (line == "ble0" && BleTest::active()) BleTest::stop();
      else if (line == "w") { net.startPortal(); feed = Feed(); }
      else if (line == "panel64" || line == "panel32" || line == "panel128") {
        const int width = line == "panel128" ? 128 : 64;
        const int height = line == "panel32" ? 32 : 64;
        Preferences displayPrefs;
        if (!displayPrefs.begin("s67-display", false)) {
          Serial.println("[panel] Could not open settings");
        } else {
          bool ok = displayPrefs.putInt("width", width) && displayPrefs.putInt("height", height);
          displayPrefs.end();
          if (ok) {
            Serial.printf("[panel] Saved %dx%d; restarting\n", width, height);
            Serial.flush(); delay(300); ESP.restart();
          } else Serial.println("[panel] Could not save settings");
        }
      }
      else if (line.startsWith("admin ")) {
        if (Intro::setPassword(line.substring(6))) Serial.println("[admin] Password saved");
        else Serial.println("[admin] Password must be 8 to 80 characters");
      }
      else if (line == "r") { net.forgetDevice(); feed = Feed(); }
      else if (line.length() == 2 && line[0] == 't' && line[1] >= '0' && line[1] <= '8') {
        testPattern = line[1] - '0';
        Serial.printf("[test] pattern %d\n", testPattern);
      }
      line = "";
    } else line += ch;
  }
  // 10 frames per second: tenths of a second, scrolling, blinking, dots.
  static uint32_t last = 0;
  if (now - last < (BleTest::active() ? 30u : 100u)) { delay(2); return; }
  last = now;
  const NetStatus &st = net.status();
  if (feed.valid && !strcmp(feed.mode, "idle") && !BleTest::connected()) net.checkUpdate(feed.firmware);
  canvas.brightness = feed.valid ? feed.brightness : 60;
  panel->fillScreen(0);
  if (testPattern) { drawTest(now); panel->show(); return; }
  static bool gameWasConnected = false;
  bool gameConnected = BleTest::connected();
  if (gameConnected && !gameWasConnected) { arcadeScreen = ArcadeScreen::MENU; arcadeSelection = 0; }
  gameWasConnected = gameConnected;
  if (gameConnected) {
    char command = BleTest::takeCommand();
    if (arcadeScreen == ArcadeScreen::MENU) {
      if (command == 'A') arcadeSelection = (arcadeSelection + 2) % 3;
      if (command == 'C') arcadeSelection = (arcadeSelection + 1) % 3;
      if (command == 'E') {
        if (arcadeSelection == 2) { BleTest::disconnectAll(); panel->show(); return; }
        arcadeGame = arcadeSelection;
        if (arcadeGame == 0) breakout.reset(panelWidth, panelHeight, now);
        else galaga.reset(panelWidth, panelHeight, now);
        arcadeScreen = ArcadeScreen::GAME;
      }
      if (arcadeScreen == ArcadeScreen::MENU) {
        char countLine[24]; snprintf(countLine, sizeof countLine, "PADS %d P1", BleTest::controllers());
        centred(countLine, 1, COLOR_DIM);
        centred(arcadeSelection == 0 ? "> BREAKOUT" : "  BREAKOUT", 9, COLOR_TEXT);
        centred(arcadeSelection == 1 ? "> GALAGA" : "  GALAGA", 17, COLOR_TEXT);
        centred(arcadeSelection == 2 ? "> EXIT" : "  EXIT", 25, COLOR_TEXT);
        panel->show(); return;
      }
    } else if (command == 'F') { arcadeScreen = ArcadeScreen::MENU; panel->show(); return; }
    if (arcadeGame == 0) {
      breakout.update(now, BleTest::position(), true); breakout.draw(canvas);
      if (!breakout.remaining()) centred("YOU WIN", panelHeight / 2, COLOR_TEXT);
      else if (!breakout.lives()) centred("GAME OVER", panelHeight / 2, COLOR_TEXT);
    } else {
      galaga.update(now, BleTest::position(), command == 'E' || command == 'e'); galaga.draw(canvas);
      if (!galaga.remaining()) centred("YOU WIN", panelHeight / 2, COLOR_TEXT);
      else if (!galaga.lives()) centred("GAME OVER", panelHeight / 2, COLOR_TEXT);
    }
    panel->show(); return;
  }
  if (st.state == NetState::PORTAL) {
    centred(Intro::text(), panelHeight > 32 ? 15 : 3, Intro::color(), now);
    centred("CONNECT WIFI", panelHeight > 32 ? 35 : 14, COLOR_TEXT);
    centred(st.apName, panelHeight > 32 ? 45 : 24, COLOR_DIM);
  }
  else if (!feed.valid) statusScreen(st, now);
  else if (now < showCodeUntil) codeScreen();
  else if (st.state != NetState::ONLINE || !strcmp(feed.mode, "idle") || !strcmp(feed.mode, "pairing")) {
    // Alternate the welcome with the current server-issued takeover code.
    if (st.state == NetState::ONLINE && feed.code[0] && (now / 10000) % 2) codeScreen();
    else if ((now / 5000) % 2) logoScreen();
    else {
      centred(Intro::text(), panelHeight > 32 ? 22 : 8, Intro::color(), now);
      centred(st.state == NetState::ONLINE ? "SCORE67 ONLINE" : "SCORE67 OFFLINE", panelHeight > 32 ? 42 : 22, COLOR_DIM);
    }
  }
  else renderFeed(canvas, feed, now - received);
  // Red dot top right while the server connection is down (the last state stays).
  if (feed.valid && st.state != NetState::ONLINE) canvas.set(panelWidth - 1, 0, COLOR_RED);
  panel->show();
}
