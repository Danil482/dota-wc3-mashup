"""BLP1 encoder for Warcraft III: uncompressed, 256-colour palette plus an
8-bit alpha plane, full mipmap chain.

File layout (little endian):
    "BLP1", compression=1 (palette), alphaBits=8, width, height,
    extra=4 (index list + alpha list), hasMipmaps=1,
    mipmapOffsets[16], mipmapSizes[16],
    palette[256] as BGRA,
    per mip level: width*height palette indices, then width*height alpha bytes.

The output is deterministic: octree palette from the top level, nearest
colour mapping without dithering, box-filtered mip levels.
"""
import struct

from PIL import Image

HEADER_SIZE = 28 + 16 * 4 * 2
PALETTE_SIZE = 256 * 4


def mip_sizes(width, height):
    sizes = [(width, height)]
    while width > 1 or height > 1:
        width, height = max(1, width // 2), max(1, height // 2)
        sizes.append((width, height))
    return sizes[:16]


def encode(image):
    """Encode a PIL image (any mode) as BLP1 bytes. Width and height must be
    powers of two, as Warcraft III expects."""
    rgba = image.convert("RGBA")
    width, height = rgba.size
    for v in (width, height):
        if v < 1 or v & (v - 1) or v > 65536:
            raise ValueError(f"BLP size must be a power of two, got {rgba.size}")

    levels = []
    for w, h in mip_sizes(width, height):
        level = rgba if (w, h) == (width, height) else rgba.resize((w, h), Image.Resampling.BOX)
        levels.append(level)

    # One palette for all levels, built from the top level's colours.
    palette_image = levels[0].convert("RGB").quantize(
        colors=256, method=Image.Quantize.FASTOCTREE, dither=Image.Dither.NONE)
    palette = list(palette_image.getpalette()[:768])
    palette += [0] * (768 - len(palette))

    chunks = []
    for level in levels:
        indices = level.convert("RGB").quantize(palette=palette_image, dither=Image.Dither.NONE)
        chunks.append(indices.tobytes() + level.getchannel("A").tobytes())

    offsets, sizes = [], []
    pos = HEADER_SIZE + PALETTE_SIZE
    for chunk in chunks:
        offsets.append(pos)
        sizes.append(len(chunk))
        pos += len(chunk)
    offsets += [0] * (16 - len(offsets))
    sizes += [0] * (16 - len(sizes))

    header = struct.pack("<4sIIIIII", b"BLP1", 1, 8, width, height, 4, 1)
    header += struct.pack("<16I", *offsets) + struct.pack("<16I", *sizes)
    # Palette entries are BGRA. Warcraft III takes alpha from the alpha plane;
    # the palette's alpha byte is set opaque so simpler readers show the image.
    pal = bytearray()
    for i in range(256):
        r, g, b = palette[i * 3:i * 3 + 3]
        pal += bytes((b, g, r, 255))
    return header + bytes(pal) + b"".join(chunks)


def decode(data, level=0):
    """Decode one mip level of a paletted BLP1 written by encode() (or any
    paletted BLP1 with 0/1/4/8 alpha bits) into an RGBA image."""
    magic, compression, alpha_bits, width, height, _extra, _mips = struct.unpack_from("<4sIIIIII", data)
    if magic != b"BLP1" or compression != 1:
        raise ValueError("not a paletted BLP1 file")
    offsets = struct.unpack_from("<16I", data, 28)
    sizes = struct.unpack_from("<16I", data, 28 + 64)
    w, h = max(1, width >> level), max(1, height >> level)
    n = w * h
    start = offsets[level]
    if sizes[level] < n:
        raise ValueError("truncated mip level")
    palette = data[HEADER_SIZE:HEADER_SIZE + PALETTE_SIZE]
    rgb = bytearray(n * 3)
    for i, index in enumerate(data[start:start + n]):
        b, g, r = palette[index * 4:index * 4 + 3]
        rgb[i * 3:i * 3 + 3] = bytes((r, g, b))
    if alpha_bits == 8:
        alpha = data[start + n:start + 2 * n]
    elif alpha_bits in (1, 4):
        bits = data[start + n:]
        per = 8 // alpha_bits
        mask = (1 << alpha_bits) - 1
        alpha = bytes(((bits[i // per] >> ((i % per) * alpha_bits)) & mask) * 255 // mask for i in range(n))
    else:
        alpha = b"\xff" * n
    image = Image.frombytes("RGB", (w, h), bytes(rgb)).convert("RGBA")
    image.putalpha(Image.frombytes("L", (w, h), bytes(alpha)))
    return image
