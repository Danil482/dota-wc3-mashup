"""Dota 2's map layout for the personalized map.

The base map carries a hand-made, Dota-like layout (tools/layout.py). On the
player's PC the launcher replaces it with Dota's own: terrain, cliffs, ramps,
river, trees and every gameplay spot, read from the player's
game/dota/maps/dota.vpk. Valve's level data never leaves that PC.

Steps (source -> convert -> w3x):
  1. VRF exports the entity lumps, the gridnav, the physics mesh and the ground
     meshes (source.export).
  2. They become a normalized description in WC3 coordinates
     (source.describe; description.json, preview dota.png).
  3. The description becomes WC3 terrain (convert), written as the map's
     w3e, wpm, doo and minimap (w3x; preview wc3.png).
  4. The base map's war3map.w3i and war3mapUnits.doo get the new start
     locations, and its war3map.lua the new data.mapdata module (the block
     between the "-- @dvw-data-begin/end data.mapdata" markers).
  5. Dota's tree models replace the WC3 tree models (trees.py): MDX files,
     war3map.w3b, and war3map.w3d for the decorative trees on raised ground.
     If that fails, the trees stay WC3 summer trees, without decoration.
  6. Dota's ground textures replace the textures of the tiles the terrain
     uses (ground.py). If that fails, the tiles keep Warcraft III's look.

Steps 1-3 are cached per dota.vpk content and CONVERTER_VERSION in
%LOCALAPPDATA%\\DotaVsWarcraft\\cache\\<Dota build>\\terrain-<version>-<hash>,
step 5 per tree plan and TREES_VERSION in ...\\<Dota build>\\trees-<version>-<hash>,
step 6 per tile set and GROUND_VERSION in ...\\<Dota build>\\ground-<version>-<hash>.
The output is deterministic, so players with the same Dota 2 build and mod
version get identical maps.
"""
import hashlib
import json
import os
import shutil
import struct
import time
from pathlib import Path

from .. import installs, stormlib

# Bump whenever the output changes for the same dota.vpk (cached files are
# keyed by it, and players must all get the same map).
CONVERTER_VERSION = 9
CACHE_PREFIX = "terrain-"
TERRAIN_FILES = ("war3map.w3e", "war3map.wpm", "war3map.doo", "war3mapMap.blp")
PATCHED_FILES = ("war3map.w3i", "war3mapUnits.doo", "war3map.lua")
MAP_FILES = TERRAIN_FILES + PATCHED_FILES
# Cached beside the map files: the gameplay data, the tree plan (trees.py)
# and war3map.doo with plain WC3 trees, used when the tree models fail.
CACHE_ONLY = ("mapdata.json", "trees.json", "war3map_wc3trees.doo")
# Slots as in tools/build_map.js: 0-4 Dota, 5 Warcraft, 6 the Ancients,
# 7 Warcraft AI, 8 Horde.
DOTA_SLOTS, WARCRAFT_SLOTS, ANCIENTS_SLOT = (0, 1, 2, 3, 4), (5, 7, 8), 6


class TerrainError(Exception):
    pass


def maps_vpk(dota_root):
    return Path(dota_root) / "game" / "dota" / "maps" / "dota.vpk"


def _sha(data):
    return hashlib.sha256(data).hexdigest()


def _file_digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def read_cache(folder):
    try:
        manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if manifest.get("converter") != CONVERTER_VERSION:
        return None
    files = {}
    for name, digest in manifest.get("files", {}).items():
        try:
            data = (folder / "files" / name).read_bytes()
        except OSError:
            return None
        if _sha(data) != digest:
            return None
        files[name] = data
    if set(files) != set(TERRAIN_FILES) | set(CACHE_ONLY):
        return None
    return files


def build_terrain(vpk, vrf_exe, folder, log):
    """Export, describe and convert; write the cache folder. Returns its files."""
    from . import convert, render, source, w3x
    tmp = folder.with_name(folder.name + f".tmp{os.getpid()}")
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir(parents=True)
    try:
        t0 = time.perf_counter()
        plan = source.export(vrf_exe, vpk, tmp / "export", tmp / "vrf", log)
        t1 = time.perf_counter()
        desc = source.describe(source.exported_paths(tmp / "export", plan), log)
        desc["source"] = {"dota_vpk_sha256": _file_digest(vpk), "converter": CONVERTER_VERSION}
        t2 = time.perf_counter()
        terrain = convert.convert(desc, log)
        files = {
            "war3map.w3e": w3x.write_w3e(terrain),
            "war3map.wpm": w3x.write_wpm(terrain),
            "war3map.doo": w3x.write_doo(terrain),
            "war3mapMap.blp": w3x.minimap_blp(terrain),
            "mapdata.json": json.dumps(terrain.mapdata, indent=1, sort_keys=True).encode("utf-8"),
            "trees.json": json.dumps(terrain.tree_plan, indent=1, sort_keys=True).encode("utf-8"),
            "war3map_wc3trees.doo": w3x.write_doo(terrain, dota_trees=False),
        }
        t3 = time.perf_counter()
        (tmp / "description.json").write_text(json.dumps(desc), encoding="utf-8")
        report = {"ramps": terrain.ramps, "notes": terrain.notes, "trees": len(terrain.trees),
                  "rocks": len(terrain.rocks), "decorative_trees": len(terrain.decor),
                  "raised_corners": sum(terrain.raised)}
        (tmp / "report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
        render.preview_dota(desc, tmp / "dota.png", mapdata=terrain.mapdata)
        render.render_wc3(terrain, tmp / "wc3.png")
        for name, data in files.items():
            p = tmp / "files" / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data)
        manifest = {"converter": CONVERTER_VERSION, "files": {n: _sha(d) for n, d in sorted(files.items())}}
        (tmp / "manifest.json").write_text(json.dumps(manifest, indent=1), encoding="utf-8")
        shutil.rmtree(tmp / "export", ignore_errors=True)
        shutil.rmtree(tmp / "vrf", ignore_errors=True)
        shutil.rmtree(folder, ignore_errors=True)
        os.replace(tmp, folder)
        log(f"terrain: export {t1 - t0:.1f} s, describe {t2 - t1:.1f} s, convert {t3 - t2:.1f} s")
        return files
    except (source.SourceError, convert.ConvertError, w3x.W3xError, KeyError, ValueError, IndexError,
            TypeError, struct.error) as e:
        raise TerrainError(f"{type(e).__name__}: {e}") from e
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def start_locations(mapdata):
    f, s, a = mapdata["dota"]["fountain"], mapdata["warcraft"]["start"], mapdata["dota"]["ancient"]
    starts = {slot: (f["x"], f["y"]) for slot in DOTA_SLOTS}
    starts.update({slot: (s["x"], s["y"]) for slot in WARCRAFT_SLOTS})
    starts[ANCIENTS_SLOT] = (a["x"], a["y"])
    return starts


def patch_base(base, terrain_files):
    """The replaced and patched map files, from the base map's files and the
    cached terrain files."""
    from . import convert, w3x
    w3e = base["war3map.w3e"]
    try:
        if w3e[:4] != b"W3E!" or w3e[8:9] != b"L":
            raise TerrainError("the base map's terrain is not a Lordaeron Summer w3e")
        pos = 13
        pos += 4 + 4 * struct.unpack_from("<i", w3e, pos)[0]          # ground tilesets
        pos += 4 + 4 * struct.unpack_from("<i", w3e, pos)[0]          # cliff tilesets
        width, height, ox, oy = struct.unpack_from("<iiff", w3e, pos)
    except struct.error as e:
        raise TerrainError(f"the base map's w3e is damaged: {e}") from e
    if (width, height, ox, oy) != (convert.N, convert.N, convert.ORIGIN, convert.ORIGIN):
        raise TerrainError(f"the base map is {width - 1} x {height - 1} tiles at {ox}, {oy}; "
                           f"the converter writes {convert.TILES} x {convert.TILES} at {convert.ORIGIN}")
    mapdata = json.loads(terrain_files["mapdata.json"].decode("utf-8"))
    starts = start_locations(mapdata)
    try:
        w3i = w3x.patch_w3i(base["war3map.w3i"], starts)
        units, moved = w3x.patch_units(base["war3mapUnits.doo"], starts)
        script = w3x.patch_lua(base["war3map.lua"].decode("utf-8"), mapdata)
    except (w3x.W3xError, struct.error, ValueError, UnicodeDecodeError) as e:
        raise TerrainError(str(e)) from e
    if moved != len(starts):
        raise TerrainError(f"war3mapUnits.doo: moved {moved} start locations, expected {len(starts)}")
    out = {n: terrain_files[n] for n in TERRAIN_FILES}
    out.update({"war3map.w3i": w3i, "war3mapUnits.doo": units, "war3map.lua": script.encode("utf-8")})
    return out


def read_base_files(base_map, stormlib_dll):
    """The base map files the terrain step reads; war3map.w3b and w3d
    (destructable and doodad object data) only if the map has them."""
    try:
        storm = stormlib.StormLib(stormlib_dll)
        h = storm.open_archive(base_map)
        try:
            files = {n: storm.read_file(h, n.encode("ascii")) for n in ("war3map.w3e",) + PATCHED_FILES}
            for name in ("war3map.w3b", "war3map.w3d"):
                try:
                    files[name] = storm.read_file(h, name.encode("ascii"))
                except stormlib.StormError:
                    pass
            return files
        finally:
            storm.SFileCloseArchive(h)
    except stormlib.StormError as e:
        raise TerrainError(f"could not read the base map: {e}") from e


def is_terrain_asset(name):
    """True for the files the terrain step adds beside MAP_FILES: Dota's tree
    models and textures, the tile textures, war3map.w3b and war3map.w3d."""
    from . import ground, trees
    if name in ("war3map.w3b", "war3map.w3d") or name.startswith(trees.MAP_DIR):
        return True
    return any(name in (ground.classic_path(t), ground.classic_dds_path(t), ground.hd_path(t))
               for t in ground.TILE_FILES)


def used_tiles(w3e):
    """Tile type ids the corners of a w3e (v11) use."""
    pos = 13
    count = struct.unpack_from("<i", w3e, pos)[0]
    ids = [w3e[pos + 4 + 4 * n:pos + 8 + 4 * n].decode("ascii") for n in range(count)]
    pos += 4 + 4 * count
    pos += 4 + 4 * struct.unpack_from("<i", w3e, pos)[0]
    width, height = struct.unpack_from("<ii", w3e, pos)
    pos += 16
    used = {w3e[pos + 7 * k + 4] & 0x0F for k in range(width * height)}
    return sorted(ids[n] for n in used if n < len(ids))


def dota_ground(dota_root, vrf_exe, build_dir, w3e, log):
    """Dota's ground textures for the tiles the terrain uses ({map path:
    bytes}), or {} (with a warning): the tiles then keep Warcraft III's look."""
    from . import ground
    try:
        return ground.prepare(dota_root, vrf_exe, build_dir, used_tiles(w3e), log)
    except Exception as e:  # noqa: BLE001 - optional look; never lose Dota's layout over it
        log(f"terrain: the map keeps Warcraft III ground textures, Dota's failed: {type(e).__name__}: {e}")
        return {}


def dota_trees(dota_root, vrf_exe, build_dir, cached, base, log):
    """Dota's tree models and the war3map.w3b and w3d that point the map's
    tree types and decorative tree doodads at them ({map path: bytes}), or {}
    (with a warning) when they cannot be made: the map then keeps Warcraft
    III's trees."""
    from . import trees
    try:
        plan = json.loads(cached["trees.json"].decode("utf-8"))
        return trees.prepare(dota_root, vrf_exe, build_dir, plan, base.get("war3map.w3b"), log,
                             base_w3d=base.get("war3map.w3d"))
    except Exception as e:  # noqa: BLE001 - optional look; never lose Dota's layout over it
        log(f"terrain: the map keeps Warcraft III trees, Dota's tree models failed: {type(e).__name__}: {e}")
        return {}


def cache_folder(dota_root, vpk, cache_root):
    build, _source = installs.dota_build_id(dota_root)
    if not build:
        st = vpk.stat()
        build = "vpk-" + _sha(f"{st.st_size}:{st.st_mtime_ns}".encode())[:16]
    digest = _file_digest(vpk)
    return Path(cache_root) / build / f"{CACHE_PREFIX}{CONVERTER_VERSION}-{digest[:16]}"


def prepare(dota_root, base_map, vrf_exe, stormlib_dll, cache_root, log):
    """{map path: bytes} replacing the base map's layout with Dota's.
    Raises TerrainError; the caller then keeps the base map's layout."""
    dota_root = Path(dota_root)
    vpk = maps_vpk(dota_root)
    if not vpk.is_file():
        raise TerrainError(f"Dota 2's map is missing: {vpk}")
    base = read_base_files(base_map, stormlib_dll)
    folder = cache_folder(dota_root, vpk, cache_root)
    cached = read_cache(folder)
    if cached is not None:
        log(f"terrain: cache complete ({folder.name})")
    else:
        for old in folder.parent.glob(CACHE_PREFIX + "*"):
            if old.is_dir() and old.name != folder.name:
                shutil.rmtree(old, ignore_errors=True)
        cached = build_terrain(vpk, Path(vrf_exe).resolve(), folder, log)
    out = patch_base(base, cached)
    tree_files = dota_trees(dota_root, Path(vrf_exe).resolve(), folder.parent, cached, base, log)
    if tree_files:
        out.update(tree_files)
    else:
        out["war3map.doo"] = cached["war3map_wc3trees.doo"]
    out.update(dota_ground(dota_root, Path(vrf_exe).resolve(), folder.parent, cached["war3map.w3e"], log))
    return out
