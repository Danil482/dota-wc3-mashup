"""Particle textures: Dota vtex files (exported by VRF) -> palette BLP1 for
effect models.

VRF exports a plain texture as <stem>.png. A sprite sheet comes out as one
PNG per frame (<stem>_seq<s>.png, or <stem>_seq<s>_<f>.png for sequences of
several frames) plus <stem>.mks, the sheet description. WC3 particles read a
uniform grid, so the frames of the sequence a system uses are repacked into
rows x columns cells; a one-frame sequence becomes a plain texture.
"""
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageStat

from .. import blp
from . import textures

SPRITE_LIMIT = 64
SHEET_LIMIT = 128
MAX_FRAMES = 16


def parse_mks(text):
    """A .mks sheet description -> {sequence: [frame file names]}."""
    seqs, current = {}, None
    for line in (text or "").splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0].startswith("sequence"):      # sequence, sequence-a, sequence-rgb
            try:
                current = int(parts[1])
            except ValueError:
                current = None
            if current is not None and seqs.get(current):
                current = None                                       # the rgb and alpha halves of one sequence
            if current is not None:
                seqs.setdefault(current, [])
        elif len(parts) >= 2 and parts[0] == "frame" and current is not None:
            seqs[current].append(parts[1])
    return {s: f for s, f in seqs.items() if f}


def source(folder, vtex, sequence):
    """The exported PNG files of `vtex` (VPK path) for `sequence`: [one file]
    for a plain texture, the frames (at most MAX_FRAMES, evenly picked) of a
    sheet sequence, or [] when VRF wrote nothing."""
    stem = Path(folder) / vtex[:-len(".vtex_c")] if vtex.endswith(".vtex_c") else Path(folder) / vtex
    plain = stem.with_name(stem.name + ".png")
    if plain.is_file():
        return [plain]
    mks = stem.with_name(stem.name + ".mks")
    try:
        sheet = parse_mks(mks.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return []
    if not sheet:
        return []
    frames = sheet[sequence] if sequence in sheet else sheet[min(sheet)]
    if len(frames) > MAX_FRAMES:
        step = len(frames) / MAX_FRAMES
        frames = [frames[int(i * step)] for i in range(MAX_FRAMES)]
    files = [mks.with_name(f) for f in frames]
    return [f for f in files if f.is_file()]


def _pot_floor(v):
    p = 1
    while p * 2 <= v:
        p *= 2
    return p


def _pot_ceil(v):
    p = 1
    while p < v:
        p *= 2
    return p


def _open(path):
    image = Image.open(path)
    image.load()
    image = image.convert("RGBA")
    # Alpha-only sheets (packmode rgb+a) export black colour: the particle's
    # own colour should show, so such a frame turns white under its alpha.
    alpha = image.getchannel("A")
    weight = ImageStat.Stat(alpha).mean[0]
    lum = ImageStat.Stat(ImageChops.multiply(image.convert("L"), alpha)).mean[0] / weight if weight else 255
    if lum < 20 and weight < 230:      # dark colour under a shaped alpha (opaque glows keep theirs)
        image = Image.merge("RGBA", (Image.new("L", image.size, 255),) * 3 + (alpha,))
    return image


def _feather(image):
    """Soft ends and sides for a stretched texture (tails, ribbons): VRF crops
    sheet frames tightly, which would draw hard-edged boxes."""
    w, h = image.size
    ramp_x, ramp_y = max(1, w // 5), max(1, h // 4)
    mask = Image.new("L", (w, h))
    px = mask.load()
    for y in range(h):
        fy = min(1.0, min(y + 0.5, h - y - 0.5) / ramp_y)
        for x in range(w):
            fx = min(1.0, min(x + 0.5, w - x - 0.5) / ramp_x)
            px[x, y] = int(255 * fx * fy)
    r, g, b, a = image.split()
    return Image.merge("RGBA", (r, g, b, Image.composite(a, Image.new("L", (w, h), 0), mask).point(lambda v: v)))


def _square(image):
    """The image centred on a square canvas: WC3 particle quads are square."""
    w, h = image.size
    if w == h:
        return image
    side = max(w, h)
    canvas = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    canvas.paste(image, ((side - w) // 2, (side - h) // 2))
    return canvas


def convert(files, stretched=False):
    """(BLP1 bytes, rows, columns, frame count) from source()'s files.
    stretched: for tails and ribbons, whose texture runs along their length
    in WC3 (left = front) but along V in Dota: turned a quarter, not padded."""
    if len(files) == 1:
        image = _open(files[0])
        image = _feather(image.transpose(Image.Transpose.ROTATE_90)) if stretched else _square(image)
        size = textures.fit_size(*image.size, limit=SPRITE_LIMIT)
        if size != image.size:
            image = image.resize(size, Image.Resampling.LANCZOS)
        return blp.encode_levels(textures.mip_levels(image, False)), 1, 1, 1
    frames = [_open(f) for f in files]
    if stretched:
        frames = [_feather(f.transpose(Image.Transpose.ROTATE_90)) for f in frames]
    n = len(frames)
    cols = _pot_ceil(math.ceil(math.sqrt(n)))
    rows = _pot_ceil(math.ceil(n / cols))
    biggest = max(max(f.size) for f in frames)
    cell = max(16, min(_pot_floor(SHEET_LIMIT // max(cols, rows)), _pot_ceil(biggest)))
    sheet = Image.new("RGBA", (cols * cell, rows * cell), (0, 0, 0, 0))
    for i, frame in enumerate(frames):
        # Keep each frame's aspect inside its cell, centred, like the sprite's quad.
        w, h = frame.size
        k = cell / max(w, h)
        tile = frame.resize((max(1, round(w * k)), max(1, round(h * k))), Image.Resampling.LANCZOS)
        sheet.paste(tile, ((i % cols) * cell + (cell - tile.size[0]) // 2,
                           (i // cols) * cell + (cell - tile.size[1]) // 2))
    return blp.encode_levels(textures.mip_levels(sheet, False)), rows, cols, n


def glow(rgb=(255, 255, 255), size=64):
    """A soft round glow drawn here (no game file): the texture of a fallback
    effect when a particle system could not be converted."""
    image = Image.new("RGBA", (size, size))
    px = image.load()
    c = (size - 1) / 2
    for y in range(size):
        for x in range(size):
            d = math.hypot(x - c, y - c) / c
            a = max(0.0, 1.0 - d) ** 2
            px[x, y] = (rgb[0], rgb[1], rgb[2], int(255 * a))
    return blp.encode_levels(textures.mip_levels(image, False))
