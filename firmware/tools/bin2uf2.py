#!/usr/bin/env python3
"""firmware.bin -> firmware.uf2 for the Matrix Portal S3's UF2 bootloader
(double-tap RESET, drive MATRXS3BOOT, copy the file). Addresses are offsets in
the app partition; family ESP32-S3."""
import struct
import sys

FAMILY_ESP32S3 = 0xC47E5767


def convert(data, family=FAMILY_ESP32S3, base=0):
    blocks = [data[i:i + 256] for i in range(0, len(data), 256)]
    out = bytearray()
    for number, chunk in enumerate(blocks):
        header = struct.pack("<8I", 0x0A324655, 0x9E5D5157, 0x00002000, base + number * 256,
                             len(chunk), number, len(blocks), family)
        out += header + chunk.ljust(476, b"\0") + struct.pack("<I", 0x0AB16F30)
    return bytes(out)


if __name__ == "__main__":
    source, target = sys.argv[1], sys.argv[2]
    data = open(source, "rb").read()
    open(target, "wb").write(convert(data))
    print(f"{target}: {len(data)} bytes in {(len(data) + 255) // 256} blocks")
