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
pio run                             # production build (score67.de)
tools/flash.sh                      # then BOOT + RESET on the board, RESET again after "written"
# development against the server on this laptop:
SCORE67_DEV_HOST=192.168.x.y pio run -e matrixportal_s3_dev && tools/flash.sh matrixportal_s3_dev
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
4. Live connection — done and verified against the dev server on this laptop
   (`src/net.cpp`): Wi-Fi, `POST /api/display/register` with a device key kept
   in NVS, the compact feed over the WebSocket, status every 30 s, re-register
   after 3 failed connections (removed in the app), DOWN = code for 10 s,
   UP + DOWN 10 s = factory reset. Development build `matrixportal_s3_dev`
   talks to `SCORE67_DEV_HOST:8067` without TLS and uses the network from
   `~/.score67-wifi` (`tools/gen_secrets.py`); the production build talks to
   score67.de over TLS (Let's Encrypt roots in `include/certs.h`).
5. Wi-Fi setup portal — implemented (hotspot, up to 3 networks); still needs a
   field test over a phone hotspot. Open: production TLS field test and public web
   flasher. The firmware is not yet a
   self-installable public beta.

## Firmware updates

Firmware 0.2.0 adds an experimental OTA client. Install that version over USB
first. When a newer release is offered by the server, the board downloads it
while the scoreboard is idle and no BLE controller is connected. It checks the
image size and SHA-256 before switching partitions. The new firmware must receive
a server feed within two minutes; after three unsuccessful boots it attempts to
return to the previous partition. The first OTA update and rollback still need
to be tested on the physical board; keep USB recovery available during testing.

For a subsequent release, increase `FW_VERSION` in `platformio.ini`, build the
production environment, and use `../tools/fw_release.py upload` with the matching
version and built binary. Releases default to the test channel. The operator can
promote a verified release to stable with the same tool. This does not publish a
release automatically.

## Testing a 64×64 panel

The firmware defaults to the existing 64×32 panel. To select a single 64×64,
1/32-scan panel, open the setup hotspot (hold UP for five seconds), connect a
phone to the displayed `score67-…` network, and open `http://192.168.4.1/`.
Choose **64 × 64** under LED panel and save; the board restarts and remembers
the choice. Switch back there for a 64×32 panel. The 64×64 setting uses the
MatrixPortal's E address pin; check the board's E jumper against the panel
pinout before connecting. The 64×64 panel and its driver IC have not yet been
verified with this firmware; Protomatter is retained from the working 64×32
setup. A 128×64 preset supports two 64×64 modules connected horizontally from OUT to IN; this chain has not yet been hardware-tested. Other multi-module arrangements and custom pin mappings are not yet configurable.

The square panel uses a separate game-score layout. Pairing and temporary
messages use the existing 64×32 layout centred vertically. The browser LED
preview still represents the 64×32 layout.

Host layout check (from this directory):

```sh
g++ -std=c++17 -fsanitize=address,undefined -Iinclude test/square_render.cpp src/render.cpp -o /tmp/score67-square-test
/tmp/score67-square-test
pio run -e native && node tools/compare.mjs
```

If the setup hotspot is unavailable, the updated firmware can also select the
panel over USB. Open `pio device monitor -b 115200`, type `panel64` followed
by Enter, and wait for the board to restart. `panel32` selects 64×32 and
`panel128` selects two side-by-side 64×64 modules. These settings persist.

## Breakout over BLE

The board advertises the BLE game automatically. Open `/static/breakout.html` on score67.de in a browser with
Web Bluetooth support and connect to **Score67 BLE Test**. Hold the left or
right button (or use the arrow keys) to move the paddle. Clear all bricks;
you have three lives. The game restarts after a win or loss, pauses when the
controller disconnects, returning the display to the scoreboard or idle screen.
The idle screen alternates the welcome message with the pairing code every ten
seconds. Web Bluetooth
requires HTTPS (or localhost) and a supported browser/device. BLE operation and
performance alongside Wi-Fi still need testing on the physical panel.
