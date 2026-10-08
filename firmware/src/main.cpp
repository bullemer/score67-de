// Score67 LED panel: Wi-Fi → register at score67.de → live feed over WSS →
// the scoreboard (render.cpp). Buttons: DOWN short = show the connection
// code for 10 s during a game; UP held 5 s = Wi-Fi setup hotspot; UP + DOWN
// held 10 s = factory reset (new display, new code).
// Serial (115200): ? status, c code, w portal, r factory reset.
#include <Arduino.h>
#include <Adafruit_Protomatter.h>
#include "config.h"
#include "feed.h"
#include "net.h"
#include "render.h"
#include "tables.h"

uint8_t rgbPins[] = {PIN_R1, PIN_G1, PIN_B1, PIN_R2, PIN_G2, PIN_B2};
uint8_t addrPins[] = {PIN_A, PIN_B, PIN_C, PIN_D};
Adafruit_Protomatter panel(PANEL_W, 6, 1, rgbPins, 4, addrPins, PIN_CLK, PIN_LAT, PIN_OE, true);

// Draws into the Protomatter canvas; the feed's brightness scales every colour.
struct PanelCanvas : Canvas {
  int brightness = 60;
  void set(int x, int y, uint32_t rgb) override {
    uint8_t r = (rgb >> 16) * brightness / 100, g = ((rgb >> 8) & 255) * brightness / 100, b = (rgb & 255) * brightness / 100;
    panel.drawPixel(x, y, panel.color565(r, g, b));
  }
} canvas;

Feed feed;
uint32_t received = 0;        // millis() when the current feed arrived (clock, scrolling)
uint32_t showCodeUntil = 0;   // DOWN pressed during a game: the code instead of the score
uint32_t bothSince = 0;

void onFeed(const Feed &f) {
  bool first = !feed.valid;
  feed = f;
  received = millis();
  if (first || f.identify) Serial.printf("[feed] mode %s seq %ld\n", f.mode, f.seq);
}

// 3x5 text centred on a row (status screens).
void centred(const char *s, int y, uint32_t color) {
  int n = strlen(s), w = n ? n * 4 - 1 : 0, x = (PANEL_W - w) / 2;
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
  pinMode(PIN_BUTTON_UP, INPUT_PULLUP);
  pinMode(PIN_BUTTON_DOWN, INPUT_PULLUP);
  ProtomatterStatus status = panel.begin();
  // Past the bootloader's double-tap window; the panel shows the version meanwhile.
  centred("SCORE67", 9, COLOR_SCORE);
  centred("V" FW_VERSION, 18, COLOR_DIM);
  panel.show();
  for (int i = 0; i < 4; i++) { Serial.printf("score67 boot %d\n", i); delay(500); }
  Serial.printf("score67 panel fw %s, protomatter status %d (0 = ok), server %s:%d tls %d\n",
                FW_VERSION, (int)status, SCORE67_HOST, SCORE67_PORT, SCORE67_TLS);
  net.onFeed = onFeed;
  net.begin();
}

void loop() {
  uint32_t now = millis();
  net.loop();
  buttons(now);
  static String line;
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\n' || ch == '\r') {
      const NetStatus &st = net.status();
      if (line == "?") Serial.printf("state %d wifi %s rssi %d id %s token %d feed %s code %s heap %u\n", (int)st.state, st.ssid, st.rssi,
                                     st.displayId, st.haveToken, feed.valid ? feed.mode : "-", feed.code, ESP.getFreeHeap());
      else if (line == "c") showCodeUntil = now + 10000;
      else if (line == "w") { net.startPortal(); feed = Feed(); }
      else if (line == "r") { net.forgetDevice(); feed = Feed(); }
      line = "";
    } else line += ch;
  }
  // 10 frames per second: tenths of a second, scrolling, blinking, dots.
  static uint32_t last = 0;
  if (now - last < 100) { delay(2); return; }
  last = now;
  const NetStatus &st = net.status();
  canvas.brightness = feed.valid ? feed.brightness : 60;
  panel.fillScreen(0);
  if (!feed.valid) statusScreen(st, now);
  else if (now < showCodeUntil) codeScreen();
  else renderFeed(canvas, feed, now - received);
  // Red dot top right while the server connection is down (the last state stays).
  if (feed.valid && st.state != NetState::ONLINE) canvas.set(PANEL_W - 1, 0, COLOR_RED);
  panel.show();
}
