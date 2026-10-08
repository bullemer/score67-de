#!/usr/bin/env bash
# Flashes the firmware over USB via the ESP32-S3 ROM download mode.
# Run it, then on the board: hold BOOT, press RESET once, keep BOOT 1 s, release.
# Afterwards press RESET once to start the firmware.
#
# Why not `pio run -t upload` or the UF2 drive: the Matrix Portal S3's USB
# stack rejects the DTR/RTS reset (Errno 71), and on this laptop the UF2
# drive produced transfer errors (error -71) mid-copy. The ROM download mode
# plus esptool was reliable every time. The otadata image selects ota_0,
# otherwise the TinyUF2 bootloader keeps booting itself after a write.
set -e
cd "$(dirname "$0")/.."
ENV=${1:-matrixportal_s3}
BIN=.pio/build/$ENV/firmware.bin
[ -f "$BIN" ] || { echo "build first: pio run -e $ENV"; exit 1; }
ESPTOOL=$(ls ~/.platformio/packages/tool-esptoolpy/esptool.py)
echo "waiting for ROM download mode (BOOT + RESET) ..."
for i in $(seq 1200); do lsusb | grep -q "303a:1001" && { sleep 0.7; break; }; sleep 0.3; done
lsusb | grep -q "303a:1001" || { echo "timeout"; exit 1; }
PORT=$(ls /dev/ttyACM* | head -1)
python3 "$ESPTOOL" --chip esp32s3 --port "$PORT" --before no_reset --after no_reset \
  write_flash 0xe000 tools/otadata-ota0.bin 0x10000 "$BIN"
echo "written: press RESET once"
