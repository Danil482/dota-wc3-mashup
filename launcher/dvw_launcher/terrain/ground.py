"""Dota's ground textures on the WC3 tiles of the personalized map.

The converter (convert.textures) paints each corner with one of the map's
tile types, picked from Dota's ground material there (Radiant grass, lane
paths, river bed, base floors, the Dire's cracked earth). Here every one of
those tile types gets a texture made from the Dota material layer it stands
for: the layer's colour texture from the player's pak01_dir.vpk, tinted as
Dota's multiblend material tints it (g_vColorTint<n> where the material's
tint mask channel <n> is set, g_vColorTintB<n> where it is not). The files
replace the tile textures at the game's own paths, inside the map only:

  classic (SD)  TerrainArt\\<tileset>\\<file>.blp and .dds           512 x 256
  HD            _hd.w3mod\\TerrainArt\\<tileset>\\<file>_diffuse.dds    512 x 256, DXT5

Reforged keeps its classic tiles as DDS (512 x 256, DXT5, full mip chain: the
size this writer produces, byte for byte) and its HD tiles as _diffuse,
_normal and _orm DDS under _hd.w3mod; classic maps imported BLP tiles. Which
name each mode asks a map for is not documented, hence both classic files.

Layout of both (Warcraft III's tile atlas, 8 x 4 cells): the left 4 x 4
cells are the 16 transition shapes, cell 8*TL + 4*TR + 2*BL + 1*BR holding the
texture where those corners carry it (alpha), cell 0 the whole tile; the
right 4 x 4 are the variations. One Dota texture repeat fills one cell, so
cells join seamlessly; the shapes' ragged edges come from periodic noise, so
neighbouring transitions meet too. HD keeps Blizzard's normal and ORM maps of
the tile (only the diffuse is replaced). Everything is deterministic.
"""
import hashlib
import io
import json
import os
import re
import shutil
import struct
import time
from pathlib import Path

from PIL import Image

from .. import blp, vpkdir, vrf
from . import trees

GROUND_VERSION = 1
CACHE_PREFIX = "ground-"
CELL = 64                          # pixels per tile cell (both modes)
# Brighten the tinted layers a little: Dota's renderer adds sunlight and
# bloom the WC3 terrain lighting lacks.
GAIN = 1.25

# Where Warcraft III loads each tile type's texture (TerrainArt\\Terrain.slk:
# dir + file), for the tile types convert.TILE_IDS may use.
TILE_FILES = {
    "Ldrt": ("TerrainArt\\LordaeronSummer", "Lords_Dirt"),
    "Ldro": ("TerrainArt\\LordaeronSummer", "Lords_DirtRough"),
    "Ldrg": ("TerrainArt\\LordaeronSummer", "Lords_DirtGrass"),
    "Lrok": ("TerrainArt\\LordaeronSummer", "Lords_Rock"),
    "Lgrs": ("TerrainArt\\LordaeronSummer", "Lords_Grass"),
    "Lgrd": ("TerrainArt\\LordaeronSummer", "Lords_GrassDark"),
    "Yrtl": ("TerrainArt\\Cityscape", "City_RoundTiles"),
    "Bdrt": ("TerrainArt\\Barrens", "Barrens_Dirt"),
    "Bdrr": ("TerrainArt\\Barrens", "Barrens_Pebbles"),
    "Bdsd": ("TerrainArt\\Barrens", "Barrens_DesertDark"),
    "Bdsr": ("TerrainArt\\Barrens", "Barrens_Desert"),
    "Bflr": ("TerrainArt\\Barrens", "Barrens_Rock"),
    "Adrd": ("TerrainArt\\Ashenvale", "Ashen_DirtRough"),
}
# The Dota material layer each tile type shows: (material, layer 0-3); the
# same pairs as convert.LAYER_TILES, one source per tile.
_BLENDS = "materials/blends/"
TILE_SOURCES = {
    "Lrok": (_BLENDS + "mod_radiant_000.vmat_c", 3),                # Radiant rock
    "Adrd": (_BLENDS + "mod_dire_000.vmat_c", 0),                   # Dire rock
    "Ldro": (_BLENDS + "mod_radiant_riverbed_path_000.vmat_c", 1),  # river bed stones (Radiant)
    "Bdrr": (_BLENDS + "mod_dire_riverbed_path_000.vmat_c", 1),     # river bed stones (Dire)
    "Bflr": (_BLENDS + "mod_dire_path_cracked_000.vmat_c", 3),      # the Dire's molten cracks
    "Yrtl": (_BLENDS + "mod_radiant_base_angled_000.vmat_c", 3),    # Radiant flagstones
    "Bdrt": (_BLENDS + "mod_dire_path_000.vmat_c", 0),              # Dire stone path
    "Bdsd": (_BLENDS + "mod_dire_000.vmat_c", 1),                   # Dire cracked earth
    "Bdsr": (_BLENDS + "mod_dire_000.vmat_c", 2),                   # Dire pale cracked sand
    "Ldrt": (_BLENDS + "mod_radiant_path_000.vmat_c", 0),           # Radiant sand path
    "Ldrg": (_BLENDS + "mod_radiant_path_000.vmat_c", 1),           # grass along the paths
    "Lgrd": (_BLENDS + "mod_radiant_000.vmat_c", 1),                # Radiant long grass
    "Lgrs": (_BLENDS + "mod_radiant_000.vmat_c", 2),                # Radiant grass
}


class GroundError(Exception):
    pass


def classic_path(tile):
    d, f = TILE_FILES[tile]
    return f"{d}\\{f}.blp"


def classic_dds_path(tile):
    d, f = TILE_FILES[tile]
    return f"{d}\\{f}.dds"


def hd_path(tile):
    d, f = TILE_FILES[tile]
    return f"_hd.w3mod\\{d}\\{f}_diffuse.dds"


# ------------------------------------------------------------------ materials

def layer_info(mat_data, layer):
    """Colour texture, tints and tint mask of one multiblend layer."""
    tex = {str(p.get("m_name")): trees._resource(p.get("m_pValue")) for p in mat_data.get("m_textureParams") or []}
    vec = {str(p.get("m_name")): p.get("m_value") for p in mat_data.get("m_vectorParams") or []}
    ints = {str(p.get("m_name")): p.get("m_nValue") for p in mat_data.get("m_intParams") or []}

    def tint(name):
        v = vec.get(name)
        if isinstance(v, list) and len(v) >= 3:
            return tuple(float(c) for c in v[:3]), (float(v[3]) if len(v) > 3 else 1.0)
        return (1.0, 1.0, 1.0), 0.0
    a, _ = tint(f"g_vColorTint{layer}")
    b, b_on = tint(f"g_vColorTintB{layer}")
    mask = tex.get("g_tTintMasks") if ints.get("F_TINT_MASK") else None
    return {"color": tex.get(f"g_tColor{layer}"), "tint": a, "tint_b": b if b_on > 0.0 else None,
            "mask": mask if b_on > 0.0 else None, "channel": layer}


# ------------------------------------------------------------------ images

def _hash(*values):
    h = 0x9E3779B9
    for v in values:
        h ^= v & 0xFFFFFFFF
        h = (h * 0x85EBCA6B) & 0xFFFFFFFF
        h ^= h >> 13
        h = (h * 0xC2B2AE35) & 0xFFFFFFFF
        h ^= h >> 16
    return h


def _noise(size, seed):
    """Periodic value noise in [0, 1) on a size x size grid (two octaves of a
    smoothstep-interpolated lattice; integer hashes, no trigonometry)."""
    out = [0.0] * (size * size)
    for period, amp in ((8, 0.65), (16, 0.35)):
        step = size // period
        lattice = [(_hash(seed, period, i, j) & 0xFFFF) / 65536.0 for j in range(period) for i in range(period)]
        for y in range(size):
            gy, fy = divmod(y, step)
            ty = fy / step
            ty = ty * ty * (3 - 2 * ty)
            for x in range(size):
                gx, fx = divmod(x, step)
                tx = fx / step
                tx = tx * tx * (3 - 2 * tx)
                a = lattice[gy * period + gx]
                b = lattice[gy * period + (gx + 1) % period]
                c = lattice[((gy + 1) % period) * period + gx]
                d = lattice[((gy + 1) % period) * period + (gx + 1) % period]
                top = a + (b - a) * tx
                bot = c + (d - c) * tx
                out[y * size + x] += amp * (top + (bot - top) * ty)
    return out


_SHAPES = {}


def transition_masks(size=CELL):
    """{cell 0-15: L-mode alpha image} of the transition shapes (see the
    module docstring); computed once."""
    if size in _SHAPES:
        return _SHAPES[size]
    noise = _noise(size, 77)
    out = {}
    for c in range(16):
        tl, tr, bl, br = (c >> 3) & 1, (c >> 2) & 1, (c >> 1) & 1, c & 1
        if c in (0, 15):
            out[c] = Image.new("L", (size, size), 255)
            continue
        data = bytearray(size * size)
        for y in range(size):
            v = y / (size - 1)
            for x in range(size):
                u = x / (size - 1)
                base = (tl * (1 - u) + tr * u) * (1 - v) + (bl * (1 - u) + br * u) * v
                s = base + (noise[y * size + x] - 0.5) * 0.55
                a = (s - 0.42) / 0.16                 # soft edge around 0.5
                a = 0.0 if a < 0 else 1.0 if a > 1 else a * a * (3 - 2 * a)
                data[y * size + x] = int(a * 255 + 0.5)
        out[c] = Image.frombytes("L", (size, size), bytes(data))
    _SHAPES[size] = out
    return out


def layer_cell(color_png, info, mask_png=None, size=CELL):
    """One seamless cell (size x size, RGB) of a tinted Dota layer texture:
    the whole texture repeat scaled into the cell."""
    image = Image.open(color_png)
    image.load()
    rgb = image.convert("RGB").resize((size, size), Image.Resampling.LANCZOS)
    a = tuple(min(4.0, t * GAIN) for t in info["tint"])
    tinted = [band.point(lambda v, f=f: min(255, int(v * f + 0.5))) for band, f in zip(rgb.split(), a)]
    if info.get("tint_b") is not None and mask_png is not None:
        mask = Image.open(mask_png)
        mask.load()
        bands = mask.convert("RGBA").split()
        m = bands[min(3, info["channel"])].resize((size, size), Image.Resampling.BILINEAR)
        b = tuple(min(4.0, t * GAIN) for t in info["tint_b"])
        other = [band.point(lambda v, f=f: min(255, int(v * f + 0.5))) for band, f in zip(rgb.split(), b)]
        tinted = [Image.composite(t, o, m) for t, o in zip(tinted, other)]     # tint A where the mask is set
    return Image.merge("RGB", tinted)


def tile_atlas(cell):
    """The 8 x 4 tile atlas (RGBA) from one seamless cell."""
    size = cell.size[0]
    atlas = Image.new("RGBA", (8 * size, 4 * size), (0, 0, 0, 0))
    masks = transition_masks(size)
    full = cell.convert("RGBA")
    for c in range(16):
        col, row = c % 4, c // 4
        piece = cell.copy()
        piece.putalpha(masks[c])
        atlas.paste(piece, (col * size, row * size))
        atlas.paste(full, ((4 + col) * size, row * size))
    return atlas


def dds_dxt5(image):
    """DDS (DXT5, full mip chain) bytes of an RGBA image whose sides are
    powers of two. Pillow encodes each level; the levels are joined under one
    header with the mipmap count set."""
    levels = []
    for w, h in blp.mip_sizes(*image.size):
        level = image if (w, h) == image.size else image.resize((w, h), Image.Resampling.BOX)
        if w < 4 or h < 4:                         # DXT blocks are 4 x 4: pad the tail levels
            padded = Image.new("RGBA", (max(4, w), max(4, h)), (0, 0, 0, 0))
            padded.paste(level, (0, 0))
            level = padded
        buf = io.BytesIO()
        level.save(buf, "DDS", pixel_format="DXT5")
        data = buf.getvalue()
        if data[:4] != b"DDS " or len(data) < 128:
            raise GroundError("Pillow did not write a DDS file")
        if data[84:88] != b"DXT5":
            raise GroundError("Pillow wrote a DDS header this writer does not expect")
        levels.append(data[128:])
    buf = io.BytesIO()
    image.resize((4, 4)).save(buf, "DDS", pixel_format="DXT5")
    head = bytearray(buf.getvalue()[:128])
    width, height = image.size
    flags = struct.unpack_from("<I", head, 8)[0] | 0x20000                      # DDSD_MIPMAPCOUNT
    struct.pack_into("<IIII", head, 8, flags, height, width, len(levels[0]))     # flags, height, width, linear size
    struct.pack_into("<I", head, 28, len(levels))                               # mipmap count
    caps = struct.unpack_from("<I", head, 108)[0] | 0x400008                    # COMPLEX | MIPMAP
    struct.pack_into("<I", head, 108, caps)
    return bytes(head) + b"".join(levels)


# ------------------------------------------------------------------ cache and all of it

def _sha(data):
    return hashlib.sha256(data).hexdigest()


def sources_digest():
    blob = json.dumps({"version": GROUND_VERSION, "sources": TILE_SOURCES, "files": TILE_FILES, "cell": CELL,
                       "gain": GAIN}, sort_keys=True)
    return _sha(blob.encode("utf-8"))


def expected_files(tiles):
    return {p for t in tiles for p in (classic_path(t), classic_dds_path(t), hd_path(t))}


def build(pak, vrf_exe, tiles, work, log):
    """{map path: bytes} of the tile textures of `tiles`."""
    try:
        listing = vpkdir.read_tree(pak, ("materials/blends/", "materials/nature/", "materials/rock/",
                                         "materials/stone/", "materials/ground/"))
    except (OSError, vpkdir.VpkError) as e:
        raise GroundError(f"Dota 2 game data could not be read: {e}") from e
    vmats = sorted({TILE_SOURCES[t][0] for t in tiles if TILE_SOURCES[t][0] in listing})
    if not vmats:
        raise GroundError("none of Dota's ground materials is in this Dota build")
    try:
        mat_data = trees._blocks(vrf_exe, pak, vmats, work / "vrf", "ground materials")
    except trees.TreeError as e:
        raise GroundError(str(e)) from e
    infos = {}
    for t in tiles:
        vmat, layer = TILE_SOURCES[t]
        if vmat in mat_data:
            infos[t] = layer_info(mat_data[vmat], layer)
    vtex = sorted({x for i in infos.values() for x in (i["color"], i["mask"]) if x and x in listing})
    out_dir = work / "export"
    try:
        vrf.extract(vrf_exe, pak, vtex, out_dir, work / "vrf", lambda s: None, threads=2)
    except vrf.VrfError as e:
        raise GroundError(f"ground textures: {e}") from e
    files = {}
    for t in tiles:
        i = infos.get(t)
        png = trees._exported(out_dir, i["color"]) if i and i["color"] else None
        if png is None:
            log(f"ground: no Dota texture for tile {t}, it keeps Warcraft III's")
            continue
        mask = trees._exported(out_dir, i["mask"]) if i["mask"] else None
        atlas = tile_atlas(layer_cell(png, i, mask))
        files[classic_path(t)] = blp.encode(atlas)
        files[hd_path(t)] = files[classic_dds_path(t)] = dds_dxt5(atlas)
    return files


def prepare(dota_root, vrf_exe, build_dir, tiles, log):
    """Map files of Dota's ground textures for the tile types in `tiles`,
    cached per Dota build. Raises GroundError; the caller then keeps the WC3
    tile textures."""
    tiles = sorted(t for t in set(tiles) if t in TILE_SOURCES)
    if not tiles:
        return {}
    pak = Path(dota_root) / "game" / "dota" / "pak01_dir.vpk"
    if not pak.is_file():
        raise GroundError(f"Dota 2's game data is missing: {pak}")
    build_dir = Path(build_dir).resolve()
    digest = _sha((sources_digest() + ",".join(tiles)).encode("utf-8"))
    folder = build_dir / f"{CACHE_PREFIX}{GROUND_VERSION}-{digest[:16]}"
    files = trees.read_cache(folder, expected_files(tiles))
    if files is not None:
        log(f"ground: cache complete ({len(files)} files, {folder.name})")
        return files
    work = build_dir / f"ground-work-{os.getpid()}"
    shutil.rmtree(work, ignore_errors=True)
    t = time.perf_counter()
    try:
        files = build(pak.resolve(), Path(vrf_exe).resolve(), tiles, work, log)
    finally:
        shutil.rmtree(work, ignore_errors=True)
    log(f"ground: {len(files) // 3} Dota ground textures for the map's tiles, "
        f"{sum(len(d) for d in files.values()) / 1048576:.1f} MB in {time.perf_counter() - t:.1f} s")
    try:
        trees.write_cache(folder, files, {"tiles": tiles})
    except OSError as e:
        log(f"ground: could not write the cache {folder}: {e}")
    for old in build_dir.glob(CACHE_PREFIX + "*"):
        if old.is_dir() and old.name != folder.name and re.fullmatch(r"ground-\d+-[0-9a-f]{16}", old.name):
            shutil.rmtree(old, ignore_errors=True)
    return files
