// Phase 1: panel test pattern with Adafruit Protomatter (the driver for the
// Matrix Portal S3; verified 2026-10-08 on the Waveshare P5 64x32, RUL6024).
// Serial (115200): p<n> pattern (1 bars, 2 frame, 3 line, 4 white)
#include <Arduino.h>
#include <Adafruit_Protomatter.h>
#include "config.h"

uint8_t rgbPins[] = {PIN_R1, PIN_G1, PIN_B1, PIN_R2, PIN_G2, PIN_B2};
uint8_t addrPins[] = {PIN_A, PIN_B, PIN_C, PIN_D};
Adafruit_Protomatter panel(PANEL_W, 4, 1, rgbPins, 4, addrPins, PIN_CLK, PIN_LAT, PIN_OE, true);
ProtomatterStatus status;
uint8_t pattern = 4;

uint16_t rgb(uint8_t r, uint8_t g, uint8_t b) {
  return panel.color565(r * DEFAULT_BRIGHTNESS / 255, g * DEFAULT_BRIGHTNESS / 255, b * DEFAULT_BRIGHTNESS / 255);
}

void draw() {
  switch (pattern) {
    case 1: {
      const uint16_t colours[] = {rgb(255, 0, 0),   rgb(0, 255, 0),   rgb(0, 0, 255),     rgb(255, 255, 0),
                                  rgb(0, 255, 255), rgb(255, 0, 255), rgb(255, 255, 255), rgb(255, 120, 0)};
      for (int i = 0; i < 8; i++) panel.fillRect(i * 8, 0, 8, PANEL_H, colours[i]);
      break;
    }
    case 2:
      panel.fillScreen(0);
      panel.drawRect(0, 0, PANEL_W, PANEL_H, rgb(0, 255, 0));
      panel.fillRect(1, 1, 3, 3, rgb(255, 0, 0));
      panel.fillRect(PANEL_W - 4, PANEL_H - 4, 3, 3, rgb(0, 0, 255));
      panel.setTextColor(rgb(255, 163, 26));
      panel.setCursor(11, 12);
      panel.print("SCORE67");
      break;
    case 3: {
      static int y = 0;
      panel.fillScreen(0);
      panel.drawFastHLine(0, y, PANEL_W, rgb(255, 255, 255));
      y = (y + 1) % PANEL_H;
      break;
    }
    default: panel.fillScreen(rgb(255, 255, 255));
  }
  panel.show();
}

void setup() {
  Serial.begin(115200);
  for (int i = 0; i < 6; i++) { Serial.printf("protomatter boot %d\n", i); delay(500); }
  status = panel.begin();
  Serial.printf("protomatter reference test, status %d (0 = ok)\n", (int)status);
  draw();
}

void loop() {
  static String line;
  while (Serial.available()) {
    char ch = Serial.read();
    if (ch == '\n' || ch == '\r') {
      if (line.length() && line[0] == 'p') pattern = constrain(line.substring(1).toInt(), 1, 4);
      line = "";
    } else line += ch;
  }
  static uint32_t last = 0, lastLog = 0;
  uint32_t now = millis();
  if (now - last > (pattern == 3 ? 60 : 500)) { draw(); last = now; }
  if (now - lastLog > 5000) { Serial.printf("protomatter status %d pattern %u\n", (int)status, pattern); lastLog = now; }
  delay(5);
}
