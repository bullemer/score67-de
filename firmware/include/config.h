#pragma once

// Panel
constexpr int PANEL_W = 64;
constexpr int PANEL_H = 32;
// Low default: the panel may be powered from a laptop USB port while testing.
constexpr uint8_t DEFAULT_BRIGHTNESS = 140;  // 0-255; panel has its own 5 V supply

// HUB75 pins of the Matrix Portal S3 (Adafruit Protomatter examples).
constexpr int8_t PIN_R1 = 42, PIN_G1 = 41, PIN_B1 = 40;
constexpr int8_t PIN_R2 = 38, PIN_G2 = 39, PIN_B2 = 37;
constexpr int8_t PIN_A = 45, PIN_B = 36, PIN_C = 48, PIN_D = 35, PIN_E = 21;
constexpr int8_t PIN_LAT = 47, PIN_OE = 14, PIN_CLK = 2;

// Buttons: PIN_BUTTON_UP (6) and PIN_BUTTON_DOWN (7) come from the board's
// pins_arduino.h, active low.
