#!/usr/bin/env python3
"""Packs Twemoji's 72x72 PNGs into the one file Tiger Build reads: tiger-build/Emoji.pack.

    git clone --depth 1 --filter=blob:none --sparse https://github.com/jdecked/twemoji
    git -C twemoji sparse-checkout set --no-cone assets/72x72
    python3 scripts/pack-emoji.py twemoji/assets/72x72 tiger-build/Emoji.pack

Layout, all numbers big-endian: "TBEM", count, then per picture: name length (1 byte), name (the file name
without .png), offset (4), length (4); then the PNGs. Offsets count from the end of the index.
"""
import os
import struct
import sys


def main(folder, out):
    names = sorted(n[:-4] for n in os.listdir(folder) if n.endswith(".png"))
    blobs = [open(os.path.join(folder, n + ".png"), "rb").read() for n in names]
    index = b""
    offset = 0
    for name, blob in zip(names, blobs):
        index += struct.pack(">B", len(name)) + name.encode() + struct.pack(">II", offset, len(blob))
        offset += len(blob)
    with open(out, "wb") as handle:
        handle.write(b"TBEM" + struct.pack(">I", len(names)) + index + b"".join(blobs))
    print("%d pictures, %d bytes" % (len(names), 8 + len(index) + offset))


if __name__ == "__main__":
    main(*sys.argv[1:3])
