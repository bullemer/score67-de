# Score67 LED panel firmware

Adafruit Matrix Portal S3 on a Waveshare RGB-Matrix-P5-64x32 (RUL6024 driver
chips, 1/16 scan). Concept, protocol and layout: `../docs/DISPLAY-FIRMWARE.md`;
layout reference `../backend/score67/static/led.mjs`.

## Hardware notes (verified 2026-10-08)

- Panel driver: **Adafruit Protomatter** (pins from Adafruit's examples, see
  `include/config.h`). Its FM6126A reset at start is what this panel needs; a
  hand-written HUB75 driver and the ESP32-HUB75-MatrixPanel-DMA library both
  showed only noise.
- The board goes on the panel's **right** socket seen from the back (the
  printed arrows pointed the other way). On the wrong socket the panel stays
  black or shows random dots.
- Power the panel from its own 5 V supply; the board runs from USB.

## Build and flash

```bash
uv tool install platformio          # once
pio run                             # build
tools/flash.sh                      # then BOOT + RESET on the board, RESET again after "written"
```

`pio run -t upload` and the UF2 drive do not work reliably with this board on
Linux (see `tools/flash.sh`). Serial monitor: `pio device monitor` or any
terminal at 115200 on /dev/ttyACM0.

## Status

1. Panel test pattern — done (colours, orientation, text verified).
2. Scoreboard layout — done: `src/render.cpp` is a port of led.mjs `render()`,
   `include/tables.h` is generated from led.mjs (`node tools/gen_tables.mjs`),
   and `node tools/compare.mjs` (after `pio run -e native`) checks both pixel
   for pixel over 25 feeds. Verified on the panel with the samples in
   `include/samples.h` (serial: `n`, `0`-`9`).
3. Server side — done (`../backend`).
4. Wi-Fi, registration, WSS live feed, code display — next.
