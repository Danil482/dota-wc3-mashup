"""Model textures: Dota PNG exports -> Warcraft III BLP1.

JPEG content (BLP1 compression 0) as the Hive BLP specification describes it:
every mip level is a baseline JPEG whose four components hold B, G, R, A
directly (no colour transform, no chroma subsampling); the bytes all levels
share (SOI + quantization table) are stored once as the JPEG header, at most
624 bytes. Pillow writes CMYK JPEGs inverted ("CMYK;I"), so the channels are
inverted before encoding and the stored samples come out as plain BGRA; the
Adobe APP14 segment is dropped so readers see raw components. A full mip
chain down to 1x1 is written, as models need it.

Determinism: Pillow is pinned in requirements.txt; its libjpeg-turbo uses the
accurate integer DCT and fixed Huffman tables, so the bytes do not depend on
the CPU.
"""
import io
import struct

from PIL import Image

from .. import blp

JPEG_QUALITY = 80
JPEG_HEADER_LIMIT = 624
MAX_SIZE = 512
ALPHA_CUTOFF = 128          # Dota alpha test reference 0.5; WC3 cuts at 0.75


def _segments(data):
    """[(marker, start, length)] of a baseline JPEG up to SOS."""
    out = []
    pos = 2
    while pos + 4 <= len(data):
        if data[pos] != 0xFF:
            raise ValueError("bad JPEG marker")
        marker = data[pos + 1]
        length = struct.unpack(">H", data[pos + 2:pos + 4])[0]
        out.append((marker, pos, length + 2))
        if marker == 0xDA:
            break
        pos += length + 2
    return out


def _jpeg_bgra(image, quality):
    r, g, b, a = image.split()
    inverted = [ch.point(lambda v: 255 - v) for ch in (b, g, r, a)]
    buf = io.BytesIO()
    Image.merge("CMYK", inverted).save(buf, "JPEG", quality=quality, optimize=False, progressive=False)
    data = buf.getvalue()
    for marker, start, length in reversed(_segments(data)):
        if marker == 0xEE:      # APP14 (Adobe)
            data = data[:start] + data[start + length:]
    return data


def fit_size(width, height, limit=MAX_SIZE):
    """Power-of-two size no larger than limit, keeping the aspect ratio."""
    def pot(v):
        p = 1
        while p * 2 <= v:
            p *= 2
        return p
    w, h = pot(max(1, width)), pot(max(1, height))
    while w > limit or h > limit:
        w, h = max(1, w // 2), max(1, h // 2)
    return w, h


def mip_levels(image, alpha_test):
    """Full mip chain; alpha-tested textures get a hard 0/255 alpha per level."""
    levels = []
    for w, h in blp.mip_sizes(*image.size):
        level = image if (w, h) == image.size else image.resize((w, h), Image.Resampling.BOX)
        if alpha_test:
            rgb = level.convert("RGB")
            alpha = level.getchannel("A").point(lambda v: 255 if v >= ALPHA_CUTOFF else 0)
            level = Image.merge("RGBA", (*rgb.split(), alpha))
        levels.append(level)
    return levels


def encode_jpeg(levels, has_alpha, quality=JPEG_QUALITY):
    streams = [_jpeg_bgra(level, quality) for level in levels]
    # Shared header: everything before the first SOF (SOI, DQT), identical in all levels.
    first_sof = next(start for marker, start, _len in _segments(streams[0]) if marker in (0xC0, 0xC1))
    header = streams[0][:first_sof]
    for s in streams:
        if not s.startswith(header):
            raise ValueError("JPEG levels do not share a header")
    if len(header) > JPEG_HEADER_LIMIT:
        raise ValueError(f"JPEG header too long ({len(header)} bytes)")
    chunks = [s[len(header):] for s in streams]
    width, height = levels[0].size
    head = struct.pack("<4sIIIIII", b"BLP1", 0, 8 if has_alpha else 0, width, height, 5, 1)
    pos = len(head) + 128 + 4 + len(header)
    offsets, sizes = [], []
    for c in chunks:
        offsets.append(pos)
        sizes.append(len(c))
        pos += len(c)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))
    return (head + struct.pack("<16I", *offsets) + struct.pack("<16I", *sizes)
            + struct.pack("<I", len(header)) + header + b"".join(chunks))


def convert(png_path, alpha_mode, limit=MAX_SIZE, encoding="jpeg"):
    """PNG file -> BLP1 bytes. alpha_mode: OPAQUE, MASK or BLEND (glTF)."""
    image = Image.open(png_path)
    image.load()
    image = image.convert("RGBA")
    size = fit_size(*image.size, limit=limit)
    if size != image.size:
        image = image.resize(size, Image.Resampling.LANCZOS)
    has_alpha = alpha_mode in ("MASK", "BLEND")
    if not has_alpha:
        image.putalpha(255)
    levels = mip_levels(image, alpha_mode == "MASK")
    if encoding == "palette":
        return blp.encode(levels[0])
    return encode_jpeg(levels, has_alpha)


def placeholder(color=(128, 128, 128)):
    image = Image.new("RGBA", (8, 8), color + (255,))
    return encode_jpeg(mip_levels(image, False), False)
