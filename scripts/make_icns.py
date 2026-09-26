#!/usr/bin/env python3
"""Turn the generated icon into a Tiger-readable .icns.

Tiger's Finder displays the classic icon elements (is32, il32, ih32, it32)
and their 8-bit masks. Modern PNG-based icns files stay blank on 10.4.
"""

import struct
import sys
import zlib


def read_png(path):
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit("not a png: %s" % path)
    pos = 8
    width = height = color = None
    idat = []
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, bit, color, comp, filt, interlace = struct.unpack(">IIBBBBB", chunk)
            if bit != 8 or interlace != 0 or color not in (2, 6):
                raise SystemExit("need 8-bit RGB or RGBA png")
        elif kind == b"IDAT":
            idat.append(chunk)
        elif kind == b"IEND":
            break
    raw = zlib.decompress(b"".join(idat))
    bpp = 4 if color == 6 else 3
    stride = width * bpp
    rows = []
    i = 0
    prev = bytearray(stride)
    for _y in range(height):
        filt = raw[i]
        i += 1
        row = bytearray(raw[i:i + stride])
        i += stride
        if filt == 1:
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + left) & 255
        elif filt == 2:
            for x in range(stride):
                row[x] = (row[x] + prev[x]) & 255
        elif filt == 3:
            for x in range(stride):
                left = row[x - bpp] if x >= bpp else 0
                row[x] = (row[x] + ((left + prev[x]) // 2)) & 255
        elif filt == 4:
            for x in range(stride):
                a = row[x - bpp] if x >= bpp else 0
                b = prev[x]
                c = prev[x - bpp] if x >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                row[x] = (row[x] + pr) & 255
        elif filt != 0:
            raise SystemExit("bad png filter %s" % filt)
        rows.append(row)
        prev = row
    pixels = []
    for row in rows:
        for x in range(width):
            o = x * bpp
            r, g, b = row[o], row[o + 1], row[o + 2]
            a = row[o + 3] if bpp == 4 else 255
            pixels.append((r, g, b, a))
    return width, height, pixels


def write_png(path, width, height, pixels):
    raw = bytearray()
    for y in range(height):
        raw.append(0)
        for x in range(width):
            r, g, b, a = pixels[y * width + x]
            raw.extend((r, g, b, a))
    comp = zlib.compress(bytes(raw), 9)

    def chunk(tag, payload):
        return struct.pack(">I", len(payload)) + tag + payload + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", comp) + chunk(b"IEND", b"")
    open(path, "wb").write(png)


def key_magenta(width, height, pixels):
    # The source is a JPEG, so the backdrop is a crushed magenta rather than #ff00ff.
    bg = pixels[0][:3]

    def dist(rgb):
        return abs(rgb[0] - bg[0]) + abs(rgb[1] - bg[1]) + abs(rgb[2] - bg[2])

    transparent = [False] * (width * height)
    stack = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
    while stack:
        x, y = stack.pop()
        i = y * width + x
        if transparent[i] or dist(pixels[i]) > 48:
            continue
        transparent[i] = True
        if x > 0:
            stack.append((x - 1, y))
        if x + 1 < width:
            stack.append((x + 1, y))
        if y > 0:
            stack.append((x, y - 1))
        if y + 1 < height:
            stack.append((x, y + 1))
    out = []
    for i, (r, g, b, a) in enumerate(pixels):
        # JPEG fringes stay close to the backdrop color. Drop them entirely
        # so the rounded tile does not keep a magenta halo.
        if transparent[i] or dist((r, g, b)) < 100:
            out.append((0, 0, 0, 0))
        else:
            out.append((r, g, b, 255))
    return out


def resize(width, height, pixels, size):
    out = []
    for y in range(size):
        for x in range(size):
            x0 = int(x * width / size)
            x1 = int((x + 1) * width / size)
            y0 = int(y * height / size)
            y1 = int((y + 1) * height / size)
            if x1 <= x0:
                x1 = x0 + 1
            if y1 <= y0:
                y1 = y0 + 1
            sr = sg = sb = sa = 0
            count = 0
            for yy in range(y0, y1):
                row = yy * width
                for xx in range(x0, x1):
                    r, g, b, a = pixels[row + xx]
                    sr += r
                    sg += g
                    sb += b
                    sa += a
                    count += 1
            out.append((sr // count, sg // count, sb // count, sa // count))
    return out


def pack_channel(data):
    # Whole-channel PackBits, matching the icns rgb layout (not per scanline).
    ret = bytearray()
    buf = bytearray()
    i = 0
    end = len(data)

    def flush_buf():
        if buf:
            ret.append(len(buf) - 1)
            ret.extend(buf)
            del buf[:]

    while i < end:
        if i + 2 < end and data[i] == data[i + 1] == data[i + 2]:
            flush_buf()
            count = 3
            while i + count < end and data[i + count] == data[i] and count < 130:
                count += 1
            i += count
            while count > 130:
                ret.append(0xFF)
                ret.append(data[i - count])
                count -= 130
            if count > 2:
                ret.append(count + 0x7D)
                ret.append(data[i - count])
            else:
                i -= count
        else:
            buf.append(data[i])
            if len(buf) > 127:
                flush_buf()
            i += 1
    flush_buf()
    return bytes(ret)


def rgb_element(size, pixels):
    planes = []
    for channel in range(3):
        plane = bytes(pixels[i][channel] for i in range(size * size))
        planes.append(pack_channel(plane))
    body = b"".join(planes)
    if size == 128:
        body = b"\x00\x00\x00\x00" + body
    return body


def mask_element(size, pixels):
    return bytes(pixels[i][3] for i in range(size * size))


def write_icns(path, sizes):
    # sizes: list of (ostype_rgb, ostype_mask, size, pixels)
    parts = []
    for rgb_type, mask_type, size, pixels in sizes:
        rgb = rgb_element(size, pixels)
        mask = mask_element(size, pixels)
        parts.append(rgb_type + struct.pack(">I", 8 + len(rgb)) + rgb)
        parts.append(mask_type + struct.pack(">I", 8 + len(mask)) + mask)
    blob = b"".join(parts)
    data = b"icns" + struct.pack(">I", 8 + len(blob)) + blob
    open(path, "wb").write(data)


def main(argv):
    src = argv[1]
    out_dir = argv[2]
    width, height, pixels = read_png(src)
    keyed = key_magenta(width, height, pixels)
    write_png(out_dir + "/icon-1024.png", width, height, keyed)
    wanted = [
        (b"is32", b"s8mk", 16),
        (b"il32", b"l8mk", 32),
        (b"ih32", b"h8mk", 48),
        (b"it32", b"t8mk", 128),
    ]
    packed = []
    for rgb_type, mask_type, size in wanted:
        small = resize(width, height, keyed, size)
        write_png("%s/icon-%d.png" % (out_dir, size), size, size, small)
        packed.append((rgb_type, mask_type, size, small))
    preview = resize(width, height, keyed, 512)
    write_png(out_dir + "/icon-512.png", 512, 512, preview)
    write_icns(out_dir + "/TigerBuild.icns", packed)
    print("wrote", out_dir + "/TigerBuild.icns")


if __name__ == "__main__":
    main(sys.argv)
