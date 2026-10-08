// Phase 2: the scoreboard layout on the panel with sample games, drawn by
// render.cpp (the same layout as the browser preview). Serial (115200):
//   n next sample, 0-9 pick a sample, b<n> brightness 10-100, ? status
#include <Arduino.h>
#include <Adafruit_Protomatter.h>
#include "config.h"
#include "feed.h"
#include "render.h"
#include "samples.h"

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
int sample = 0;
uint32_t received = 0;   // millis() when the current feed "arrived"
int brightnessOverride = 0;

void loadSample(int index) {
  sample = (index + SAMPLE_COUNT) % SAMPLE_COUNT;
  parseFeed(SAMPLES[sample].json, feed);
  received = millis();
  Serial.printf("sample %d: %s (valid=%d mode=%s)\n", sample, SAMPLES[sample].name, feed.valid, feed.mode);
}

void setup() {
  Serial.begin(115200);
  for (int i = 0; i < 6; i++) { Serial.printf("score67 boot %d\n", i); delay(500); }
  ProtomatterStatus status = panel.begin();
  Serial.printf("score67 panel fw %s, protomatter status %d (0 = ok)\n", FW_VERSION, (int)status);
  loadSample(0);
}

void loop() {
  static String line;
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\n' || ch == '\r') {
      if (line == "n") loadSample(sample + 1);
      else if (line.length() == 1 && isDigit(line[0])) loadSample(line[0] - '0');
      else if (line.length() > 1 && line[0] == 'b') brightnessOverride = constrain(line.substring(1).toInt(), 0, 100);
      else if (line == "?") Serial.printf("sample %d %s, brightness %d, heap %u\n", sample, SAMPLES[sample].name, canvas.brightness, ESP.getFreeHeap());
      line = "";
    } else line += ch;
  }
  // 10 frames per second: tenths of a second under one minute, scrolling, blinking.
  static uint32_t last = 0;
  uint32_t now = millis();
  if (now - last >= 100) {
    last = now;
    canvas.brightness = brightnessOverride ? brightnessOverride : feed.brightness;
    panel.fillScreen(0);
    renderFeed(canvas, feed, now - received);
    panel.show();
  }
  delay(2);
}
