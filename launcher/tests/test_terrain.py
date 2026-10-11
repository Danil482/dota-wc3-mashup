"""Tests of Dota's map layout in the personalized map (launcher/dvw_launcher/terrain).

Offline part (no Dota 2 needed):
  - the w3e writer gives the bytes of tools/build_map.js writeW3e (node);
  - a straight cliff gets a ramp of the World Editor's shape, asking only for
    the ramp side models Blizzard's ladder maps use;
  - the data.mapdata block of war3map.lua is swapped between the build's
    markers, keeps build_lua.py's syntax and still compiles (lupa);
  - start locations in war3map.w3i and war3mapUnits.doo are patched in place;
  - the Warcraft grove on the base layout and on open ground shaped like
    the Dire base: 40-70 trees, a band 4 deep from 640 past the hall's side,
    off the mine, spawn and expansion discs and the walks to them, nearest
    the hall, cut by a walkway, every path open, the front row in reach.

With --dota, on a base map from tools/build.py: the real pipeline runs cold
twice into a scratch cache and must give byte-identical files, then warm from
the cache. The personalized map is written with StormLib and checked: the
archive opens, file versions, the minimap, every structure, camp, rune and
lane point on walkable ground and reachable from the fountain, the Warcraft
player reaching the Ancient, only known ramp models, and the map script running
on the mock WC3 API with the new layout. Blocked ground: the raised cliffs and
rocks leave the pathing byte for byte as without them, at least 97% of the
blocked cells look blocked, the Warcraft base is flat with its town hall, mine
and expansions in place, and its grove of Dire dead trees passes the grove
checks with Dota's trees standing. Pictures: <work>/dota.png, <work>/wc3.png.

Usage: python -I launcher/tests/test_terrain.py [--dota "<Dota 2 root>"] [--base <map.w3x>] [--work <folder>]
Never starts Warcraft III, Dota 2 or Steam.
"""
import argparse
import hashlib
import io
import json
import random
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "launcher"))
sys.path.insert(0, str(ROOT / "tools"))

from PIL import Image  # noqa: E402

from dvw_launcher import stormlib, terrain  # noqa: E402
from dvw_launcher.blp import decode as blp_decode  # noqa: E402
from dvw_launcher.terrain import convert, ground, trees, w3x  # noqa: E402

DLL = next((p for p in (ROOT / "launcher" / "vendor" / "stormlib" / "x64" / "StormLib.dll",
                        ROOT / "dist" / "DotaVsWarcraft" / "StormLib.dll") if p.is_file()), None)
VRF = next((p for p in (ROOT / "launcher" / "vendor" / "vrf" / "Source2Viewer-CLI.exe",
                        ROOT / "dist" / "DotaVsWarcraft" / "vrf" / "Source2Viewer-CLI.exe") if p.is_file()), None)
# Ramp side models: the canonical ones of a straight ramp, and the flat ones
# that every Blizzard ladder map asks for (no model; the game skips them).
RAMP_SIDES = {"HLHBA", "HABHL", "HHLAB", "HBALH", "VBHLA", "VHBAL", "VALHB", "VLABH"}
FLAT_SIDES = {"HLLAA", "HAALL", "VALLA", "VLAAL"}

failures = []


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(name)


def transition_names(width, height, layer, ramp):
    """The ramp side model names (V/H + 4 letters) a corner grid asks for: a 1 x 2
    or 2 x 1 tile window whose two long sides differ in ramp flags and whose
    middle line sits on the lower layer of its ends (WC3 terrain rule)."""
    def L(i, j):
        return layer[j * width + i]

    def R(i, j):
        return ramp[j * width + i]

    def letter(c, base):
        return chr((ord("L") if R(*c) else ord("A")) + (L(*c) - base) * (-4 if R(*c) else 1))
    out = {}
    for i in range(width - 1):
        for j in range(height - 1):
            if j < height - 2:
                bl, br, tl, tr, ttl, ttr = (i, j), (i + 1, j), (i, j + 1), (i + 1, j + 1), (i, j + 2), (i + 1, j + 2)
                ae, cf = min(L(*bl), L(*ttl)), min(L(*br), L(*ttr))
                if L(*tl) == ae and L(*tr) == cf and R(*bl) == R(*tl) == R(*ttl) and R(*br) == R(*tr) == R(*ttr) \
                        and R(*bl) != R(*br):
                    base = min(ae, cf)
                    n = "V" + letter(ttl, base) + letter(ttr, base) + letter(br, base) + letter(bl, base)
                    out[n] = out.get(n, 0) + 1
            if i < width - 2:
                bl, br, brr, tl, tr, trr = (i, j), (i + 1, j), (i + 2, j), (i, j + 1), (i + 1, j + 1), (i + 2, j + 1)
                ae, bf = min(L(*bl), L(*brr)), min(L(*tl), L(*trr))
                if L(*br) == ae and L(*tr) == bf and R(*bl) == R(*br) == R(*brr) and R(*tl) == R(*tr) == R(*trr) \
                        and R(*bl) != R(*tl):
                    base = min(ae, bf)
                    n = "H" + letter(tl, base) + letter(trr, base) + letter(brr, base) + letter(bl, base)
                    out[n] = out.get(n, 0) + 1
    return out


# ------------------------------------------------------------------ offline

def random_terrain(seed=5):
    rng = random.Random(seed)
    t = convert.Terrain()
    for k in range(convert.N * convert.N):
        t.level[k] = rng.randint(0, 3)
        t.height[k] = rng.randint(-8, 8) / 16.0
        t.ramp[k] = rng.random() < 0.05
        t.water[k] = rng.random() < 0.2
        t.water_z[k] = rng.choice([16.0, 144.0, 272.0, -40.0])
        t.tex[k] = rng.randint(0, len(convert.TILE_IDS) - 1)
        t.var[k] = rng.randint(0, 17)
        t.cliff_tex[k] = rng.randint(0, 1)
    return t


def test_w3e_parity(work):
    """The terrain w3e and build_map.js writeW3e agree byte for byte."""
    if not (ROOT / "build" / "terrain.json").is_file() or shutil.which("node") is None:
        print("[SKIP] w3e parity: needs node and a base build (build/terrain.json)")
        return
    t = random_terrain()
    ours = w3x.write_w3e(t)
    corners = []
    for j in range(convert.N):
        for i in range(convert.N):
            k = j * convert.N + i
            raw = int((t.water_z[k] + 89.6) / 128.0 * 512 + 8192 + 0.5)
            corners.append({"groundHeight": t.height[k], "waterHeight": (raw - 8192) / 512,
                            "mapEdge": abs(convert.ORIGIN + 128 * i) > convert.PLAY
                            or abs(convert.ORIGIN + 128 * j) > convert.PLAY,
                            "ramp": bool(t.ramp[k]), "blight": False, "water": bool(t.water[k]), "boundary": False,
                            "groundTexture": t.tex[k], "cliffVariation": 0, "groundVariation": t.var[k],
                            "cliffTexture": t.cliff_tex[k], "layerHeight": convert.LAYER0 + t.level[k]})
    spec = {"tileset": "L", "groundTilesets": convert.TILE_IDS, "cliffTilesets": convert.CLIFF_IDS,
            "width": convert.N, "height": convert.N, "offsetX": convert.ORIGIN, "offsetY": convert.ORIGIN,
            "corners": corners}
    spec_path = work / "w3e_spec.json"
    spec_path.write_text(json.dumps(spec), encoding="utf-8")
    js = ("const fs = require('fs'); const { writeW3e } = require(process.argv[1]);"
          "const s = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));"
          "fs.writeFileSync(process.argv[3], Buffer.from(writeW3e(s)));")
    out = work / "w3e_js.bin"
    p = subprocess.run(["node", "-e", js, str(ROOT / "tools" / "build_map.js"), str(spec_path), str(out)],
                       capture_output=True, text=True, cwd=str(ROOT / "tools"))
    theirs = out.read_bytes() if p.returncode == 0 and out.is_file() else b""
    first = next((i for i in range(min(len(ours), len(theirs))) if ours[i] != theirs[i]), None)
    check("w3e writer matches build_map.js writeW3e byte for byte", ours == theirs,
          f"{len(ours)} bytes" + (f", first difference at {first}" if first is not None else "")
          + (f", node: {p.stderr.strip()[:200]}" if p.returncode else ""))


def test_ramp_shape():
    """A Dota ramp on a straight cliff becomes the World Editor's ramp."""
    n = convert.N
    for grad, low_side in ((0.0, "left"), (180.0, "right"), (90.0, "bottom"), (-90.0, "top")):
        t = convert.Terrain()
        axis = "x" if grad in (0.0, 180.0) else "y"
        for j in range(n):
            for i in range(n):
                s = i if axis == "x" else j
                low = s <= 79 if low_side in ("left", "bottom") else s >= 81
                t.level[j * n + i] = 1 if low else 2
        centre = [16.0, 0.0] if axis == "x" else [0.0, 16.0]
        desc = {"ramps": [{"low": 1, "high": 2, "center": centre, "grad": grad, "cells": 120, "width": 512.0,
                           "bbox": [centre[0] - 300, centre[1] - 300, centre[0] + 300, centre[1] + 300]}]}
        convert.place_ramps(t, desc, bytearray([16]) * (n * n))
        ok = len(t.ramps) == 1
        r = t.ramps[0] if ok else {}
        names = transition_names(n, n, [convert.LAYER0 + v for v in t.level], list(t.ramp))
        sides = {k for k in names if k not in FLAT_SIDES}
        flags = sum(t.ramp)
        if ok:
            m, (r0, r1) = r["mid"], r["across"]
            expect = (r1 - r0 + 1) * 3
            ok = flags == expect and len(sides) == 2 and sides <= RAMP_SIDES and len(t.ramp_tiles) == 2 * (r1 - r0) \
                and len(t.romp_tiles) == 4
            prof = [t.level[(q * n + s) if axis == "x" else (s * n + q)] for s in range(m - 1, m + 2) for q in (r0 - 1,)]
            ok = ok and min(prof) == prof[1] == 1 and max(prof) == 2
        check(f"ramp up toward the {('right', 'left', 'top', 'bottom')[('left', 'right', 'bottom', 'top').index(low_side)]}"
              " has the World Editor's shape", ok, f"{flags} ramp corners, side models {sorted(sides)}")


def test_lua_patch():
    script = ("before\n-- @dvw-data-begin data.heroes\ndefine(\"data.heroes\", function()\n    return {}\nend)\n"
              "-- @dvw-data-end data.heroes\n\n-- @dvw-data-begin data.mapdata\ndefine(\"data.mapdata\", function()\n"
              "    return {\n     old = 1\n    }\nend)\n-- @dvw-data-end data.mapdata\nafter\n")
    md = {"bounds": {"min": -9216, "max": 9216}, "camps": {"d_small1": {"x": 10, "y": -20}},
          "lanes": {"mid": [{"x": 1, "y": 2}, {"x": 3, "y": 4}]}, "runes": []}
    out = w3x.patch_lua(script, md)
    again = w3x.patch_lua(out, md)
    kept = out.startswith("before\n-- @dvw-data-begin data.heroes") and out.endswith("-- @dvw-data-end data.mapdata\nafter\n")
    check("data.mapdata block replaced between the markers, the rest kept, repeatable",
          kept and "old = 1" not in out and out.count("@dvw-data-begin data.mapdata") == 1 and again == out)
    try:
        import build_lua
        same = build_lua.lua_literal(md, 4) == w3x.lua_literal(md, 4)
    except ImportError:
        same = None
    check("launcher Lua literal = tools/build_lua.py lua_literal", same is not False,
          "build_lua not importable" if same is None else "")
    try:
        from lupa import lua53
        lua = lua53.LuaRuntime()
        lua.execute("mods = {}; function define(name, fn) mods[name] = fn end")
        lua.execute(out.replace("before\n", "").replace("after\n", ""))
        v = lua.eval("mods['data.mapdata']()")
        ok = v.camps.d_small1.x == 10 and v.lanes.mid[2].y == 4 and v.bounds.min == -9216
    except ImportError:
        ok = None
    check("patched script compiles and returns the new mapdata (Lua 5.3)", ok is not False,
          "lupa not installed" if ok is None else "")
    try:
        w3x.patch_lua("no markers here", md)
        check("a script without markers is refused", False)
    except w3x.W3xError:
        check("a script without markers is refused", True)


def test_tree_plan():
    """Dota tree kinds -> WC3 tree types: dire_* to BTtw, default skins to
    LTlt (always 10 variations, for Sprout), other skins to FTtw; a kind past
    the 10 slots of its type borrows a variation of the same skin."""
    kinds = [["models/props_tree/tree_pine_01.vmdl", "0"], ["models/props_tree/dire_tree004.vmdl", "0"],
             ["models/props_tree/tree_oak_01.vmdl", "12"]]
    kinds += [[f"models/props_tree/tree_oak_{n:02d}.vmdl", "3"] for n in range(11)]
    rows = [[0, 0, k, 0.0, 1.0] for k in range(len(kinds)) for _ in range(20 - k)]
    plan = trees.plan_trees({"entities": {"tree_kinds": kinds, "trees": rows}})
    types = plan["types"]
    rare = plan["kinds"][len(kinds) - 1]
    check("tree plan: Dire trees to BTtw, default skins to LTlt (10 variations), other skins to FTtw",
          len(types["LTlt"]) == trees.SLOTS and types["BTtw"] == [kinds[1]] and len(types["FTtw"]) == trees.SLOTS
          and plan["kinds"][0] == ["LTlt", 0] and plan["kinds"][1] == ["BTtw", 0] and rare[0] == "FTtw"
          and types["FTtw"][rare[1]][1] == "3", str(plan["kinds"]))


def test_object_merge():
    """war3map.w3b and w3d merged into a base map's: our fields replace the
    same fields, other fields and custom objects stay."""
    plan = {"types": {"LTlt": [["m", "0"]] * 10, "BTtw": [["d", "0"]] * 4}, "kinds": []}
    base_b = trees.write_object_file(2, [("LTlt", "\0\0\0\0", [(0, [("bnam", 3, "Tree"), ("bvar", 0, 3)])])],
                                     [("ATtr", "B000", [(0, [("bnam", 3, "Custom")])])])
    _v, originals, customs = trees.read_object_file(trees.object_file(plan, base_b))
    mods = {b: {m[0]: m[2] for _f, ms in g for m in ms} for b, _n, g in originals}
    ok_b = mods["LTlt"]["bnam"] == "Tree" and mods["LTlt"]["bvar"] == 10 and mods["BTtw"]["bvar"] == 4         and mods["LTlt"]["bfil"] == trees.MAP_DIR + "LTlt" and customs[0][1] == "B000"
    base_d = trees.write_level_file(2, [("LPcr", "\0\0\0\0", [(0, [("dnam", 3, 0, 0, "Corn")])])], [])
    _v, originals, _c = trees.read_level_file(trees.doodad_file(plan, base_d))
    mods = {b: {m[0]: m[4] for _f, ms in g for m in ms} for b, _n, g in originals}
    ok_d = mods["LPcr"]["dnam"] == "Corn" and mods["LPcr"]["dfil"] == trees.MAP_DIR + "LTlt"         and mods["LPcr"]["dvar"] == 10 and mods["LPcw"]["dfil"] == trees.MAP_DIR + "BTtw"
    check("war3map.w3b and w3d merge into the base map's object data", ok_b and ok_d)


def test_tile_shapes():
    """The 16 transition shapes of a tile meet seamlessly: where two cells
    share a tile edge with the same corners, their alpha along it matches."""
    masks = ground.transition_masks()
    size = ground.CELL
    seam = inside = 0
    for c in range(1, 15):
        for x in range(size - 1):
            for y in range(size):
                inside = max(inside, abs(masks[c].getpixel((x, y)) - masks[c].getpixel((x + 1, y))))
        for d in range(1, 15):
            # c's right edge (corners TR, BR) beside d's left edge (TL, BL)
            if ((c >> 2) & 1, c & 1) == ((d >> 3) & 1, (d >> 1) & 1):
                for y in range(size):
                    seam = max(seam, abs(masks[c].getpixel((size - 1, y)) - masks[d].getpixel((0, y))))
    full = all(masks[c].getextrema() == (255, 255) for c in (0, 15))
    check("tile transition shapes meet at tile edges as smoothly as inside a cell; cells 0 and 15 whole",
          full and seam <= inside, f"largest alpha step across a seam {seam}, inside a cell {inside}")


def read_base(base):
    s = stormlib.StormLib(DLL)
    h = s.open_archive(base)
    try:
        return {n.decode(): s.read_file(h, n, loc) for n, loc, _ in s.list_files(h)}
    finally:
        s.SFileCloseArchive(h)


def test_start_patches(base):
    files = read_base(base)
    starts = {i: (100.0 * i - 333.0, -50.0 * i + 77.0) for i in range(9)}
    w3i = w3x.patch_w3i(files["war3map.w3i"], starts)
    got = w3x.w3i_starts(w3i)
    diff = sum(1 for a, b in zip(w3i, files["war3map.w3i"]) if a != b)
    check("w3i start locations patched in place", len(w3i) == len(files["war3map.w3i"])
          and all(abs(got[i][0] - starts[i][0]) < 1e-3 and abs(got[i][1] - starts[i][1]) < 1e-3 for i in starts)
          and diff <= 8 * 9, f"{diff} bytes changed")
    units, moved = w3x.patch_units(files["war3mapUnits.doo"], starts)
    units2, _ = w3x.patch_units(units, starts)
    check("war3mapUnits.doo start locations patched in place", moved == 9 and units2 == units
          and len(units) == len(files["war3mapUnits.doo"]), f"{moved} moved")


# ------------------------------------------------------------------ with Dota 2

def parse_w3e(data):
    pos = 13
    ng = struct.unpack_from("<i", data, pos)[0]
    pos += 4 + 4 * ng
    nc = struct.unpack_from("<i", data, pos)[0]
    pos += 4 + 4 * nc
    w, h, ox, oy = struct.unpack_from("<iiff", data, pos)
    pos += 16
    layers, ramps = [], []
    for k in range(w * h):
        _g, _wtr, flags, _var, misc = struct.unpack_from("<hhBBB", data, pos + 7 * k)
        layers.append(misc & 0x0F)
        ramps.append(1 if flags & 0x10 else 0)
    return w, h, ox, oy, layers, ramps, pos + 7 * w * h


def doo_entries(doo):
    """[(id, variation)] of the war3map.doo entries (v8, subversion 11)."""
    count = struct.unpack_from("<I", doo, 12)[0]
    out, pos = [], 16
    for _ in range(count):
        out.append((doo[pos:pos + 4].decode("ascii"), struct.unpack_from("<i", doo, pos + 4)[0]))
        pos += 4 + 4 + 12 + 4 + 12 + 4 + 2 + 4
        sets = struct.unpack_from("<i", doo, pos)[0]
        pos += 4
        for _s in range(sets):
            pos += 4 + 8 * struct.unpack_from("<i", doo, pos)[0]
        pos += 4
    return out


def doo_kinds(doo):
    """{id: count} of the war3map.doo entries (v8, subversion 11, no item sets)."""
    count = struct.unpack_from("<I", doo, 12)[0]
    out, pos = {}, 16
    for _ in range(count):
        kind = doo[pos:pos + 4].decode("ascii")
        out[kind] = out.get(kind, 0) + 1
        pos += 4 + 4 + 12 + 4 + 12 + 4 + 2 + 4
        sets = struct.unpack_from("<i", doo, pos)[0]
        pos += 4
        for _s in range(sets):
            pos += 4 + 8 * struct.unpack_from("<i", doo, pos)[0]
        pos += 4
    return out


def flood(wpm, size, start):
    open_ = (0x40, 0x08)
    i, j = int((start[0] + 10240) // 32), int((start[1] + 10240) // 32)
    seen = bytearray(size * size)
    best = None
    for rad in range(12):
        for a in range(i - rad, i + rad + 1):
            for b in range(j - rad, j + rad + 1):
                if best is None and 0 <= a < size and 0 <= b < size and wpm[b * size + a] in open_:
                    best = b * size + a
    if best is None:
        return seen
    stack = [best]
    seen[best] = 1
    while stack:
        k = stack.pop()
        a, b = k % size, k // size
        for n in ((k - 1) if a else -1, (k + 1) if a < size - 1 else -1, (k - size) if b else -1,
                  (k + size) if b < size - 1 else -1):
            if n >= 0 and not seen[n] and wpm[n] in open_:
                seen[n] = 1
                stack.append(n)
    return seen


def near(seen, size, p, radius=192):
    i0, j0 = int((p["x"] + 10240) // 32), int((p["y"] + 10240) // 32)
    r = radius // 32
    return any(seen[b * size + a] for a in range(i0 - r, i0 + r + 1) for b in range(j0 - r, j0 + r + 1)
               if 0 <= a < size and 0 <= b < size)


def test_ground_textures(files):
    """Every tile the terrain uses has Dota's texture in all three forms: a
    512 x 256 BLP1 and DDS for classic graphics, a DDS diffuse for HD, both
    with the transition shapes in the alpha of the left half."""
    used = terrain.used_tiles(files["war3map.w3e"])
    bad = []
    for tile in used:
        try:
            image = blp_decode(files[ground.classic_path(tile)])
            alpha = image.getchannel("A")
            left, right = alpha.crop((0, 0, 256, 256)), alpha.crop((256, 0, 512, 256))
            ok = image.size == (512, 256) and left.getextrema()[0] < 32 and right.getextrema() == (255, 255)
            for dds in (files[ground.classic_dds_path(tile)], files[ground.hd_path(tile)]):
                height, width, _pitch, _depth, mips = struct.unpack_from("<IIIII", dds, 12)
                ok = ok and dds[:4] == b"DDS " and dds[84:88] == b"DXT5" and (width, height) == (512, 256)                     and mips == 10 and len(dds) == 174928
            if not ok:
                bad.append(tile)
        except (KeyError, ValueError, struct.error) as e:
            bad.append(f"{tile} ({e})")
    check("Dota ground textures for every tile the terrain uses (classic BLP and DDS, HD DDS)",
          used and not bad, f"{len(used)} tiles" + (f", bad {bad}" if bad else ""))


def test_tree_models(written, doo, work):
    """Dota's tree models: war3map.w3b points each replaced tree type at
    war3mapImported/DotaTrees/<type> with as many variations as there are
    model files, every tree of war3map.doo uses one of them, and each model
    reads back cleanly (tools/check_mdx.js)."""
    w3b = written.get("war3map.w3b")
    if not w3b:
        check("war3map.w3b with the tree types", False, "missing")
        return
    _version, originals, customs = trees.read_object_file(w3b)
    counts = {}
    ok = not customs
    for base, _new, groups in originals:
        mods = {m[0]: m[2] for _flag, ms in groups for m in ms}
        files = [n for n in written if n.startswith(trees.MAP_DIR + base) and n.endswith(".mdx")]
        counts[base] = mods.get("bvar", 0)
        ok = ok and mods.get("bfil") == trees.MAP_DIR + base and mods.get("bvar") == len(files) and             all(trees.model_path(base, v) in written for v in range(len(files))) and mods.get("bfxr") == -1.0
    check("war3map.w3b points LTlt, FTtw and BTtw at Dota's tree models", ok and counts.get("LTlt") == trees.SLOTS,
          str(counts))
    bad = [(k, v) for k, v in doo_entries(doo) if k in trees.TYPES and not 0 <= v < counts.get(k, 0)]
    check("every tree in war3map.doo is a replaced type with an existing variation", not bad, str(bad[:5]))
    w3d = written.get("war3map.w3d")
    decor = {}
    ok = bool(w3d)
    if w3d:
        _version, originals, customs = trees.read_level_file(w3d)
        for base, _new, groups in originals:
            mods = {m[0]: m[4] for _flag, ms in groups for m in ms}
            tid = next((t for d, t in trees.DECOR.values() if d == base), None)
            decor[base] = mods.get("dvar")
            ok = ok and tid is not None and mods.get("dfil") == trees.MAP_DIR + tid and mods.get("dvar") == counts.get(tid)
        ok = ok and not customs
    entries = [(k, v) for k, v in doo_entries(doo) if k in decor]
    check("war3map.w3d points the decorative tree doodads at the tree models, every one placed has a variation",
          ok and entries and all(0 <= v < decor[k] for k, v in entries), f"{len(entries)} decorative trees, {decor}")
    folder = work / "tree_models"
    shutil.rmtree(folder, ignore_errors=True)
    folder.mkdir(parents=True)
    models = []
    for name, data in written.items():
        if name.startswith(trees.MAP_DIR):
            (folder / name.split("\\")[-1]).write_bytes(data)
            if name.endswith(".mdx"):
                models.append(str(folder / name.split("\\")[-1]))
    if shutil.which("node") is None:
        print("[SKIP] tree models through check_mdx.js: needs node")
        return
    p = subprocess.run(["node", str(ROOT / "tools" / "check_mdx.js")] + sorted(models), capture_output=True,
                       text=True, cwd=str(ROOT / "tools"))
    try:
        report = json.loads(p.stdout)
    except ValueError:
        report = {}
    failed = sorted(Path(f).name for f, r in report.items() if not r.get("ok"))
    check("tree models pass tools/check_mdx.js", report and len(report) == len(models) and not failed,
          f"{len(report)} models" + (f", failed {failed[:5]}" if failed else "") + (p.stderr[:200] if p.returncode else ""))


def looks_blocked(t, r):
    """(blocked cells in the playable area, those that look blocked): under a
    cliff tile, on raised ground, under a tree's pathing or a rock."""
    cells, tiles = convert.CELLS, convert.TILES
    cover = bytearray(cells * cells)
    for x, y, *_rest in t.trees:
        i0, j0 = int((x - 64 + 10240) // 32), int((y - 64 + 10240) // 32)
        for b in range(max(0, j0), min(cells, j0 + 4)):
            for a in range(max(0, i0), min(cells, i0 + 4)):
                cover[b * cells + a] = 1
    for x, y, _z, _v, s, _a in t.rocks:
        rad = convert.ROCK_RADIUS * s
        for b in range(int((y - rad + 10240) // 32), int((y + rad + 10240) // 32) + 1):
            for a in range(int((x - rad + 10240) // 32), int((x + rad + 10240) // 32) + 1):
                if 0 <= a < cells and 0 <= b < cells and \
                        (32 * a + 16 - 10240 - x) ** 2 + (32 * b + 16 - 10240 - y) ** 2 <= rad * rad:
                    cover[b * cells + a] = 1
    total = seen = 0
    for pj in range(cells):
        for pi in range(cells):
            k = pj * cells + pi
            if r.walk[k] or t.pathing[k] != convert.BLOCKED or max(abs(32 * pi + 16 - 10240),
                                                                   abs(32 * pj + 16 - 10240)) > convert.PLAY:
                continue
            total += 1
            ti, tj = pi // 4, pj // 4
            top = all(t.raised[convert.ci(ti + a, tj + b)] for a in (0, 1) for b in (0, 1))
            seen += 1 if t.blocked[tj * tiles + ti] or top or cover[k] else 0
    return total, seen


def test_blocked_ground(folder, wpm_cells, w3e):
    """Raised blocked ground and rocks, on the cached description: the
    pathing is exactly the one without them, blocked ground looks blocked,
    the Warcraft base stays flat and complete."""
    desc = json.loads((folder / "description.json").read_text(encoding="utf-8"))
    r = convert.Rasters(desc)
    t = convert.convert(desc)
    check("converter output = the map's pathing", bytes(t.pathing) == bytes(wpm_cells))
    saved = convert.raise_blocked, convert.place_rocks
    convert.raise_blocked = lambda *a, **k: 0
    convert.place_rocks = lambda *a, **k: 0
    try:
        flat = convert.convert(desc)
    finally:
        convert.raise_blocked, convert.place_rocks = saved
    check("raised ground and rocks leave the pathing exactly as without them",
          bytes(flat.pathing) == bytes(t.pathing) and sum(t.raised) > 0 and not flat.rocks,
          f"{sum(t.raised)} raised corners, {len(t.rocks)} rocks")
    share = convert.walkable_share(t, r)
    check("at least 93.5% of Dota's walkable ground is walkable", share >= 0.935, f"{share:.2%}")
    total, seen = looks_blocked(t, r)
    before = looks_blocked(flat, r)[1]
    check("blocked ground looks blocked (cliff, raised ground, tree or rock) on 97% of its cells",
          seen >= 0.97 * total, f"{seen} of {total} ({seen / max(1, total):.1%}); without raising {before}")
    w, h, _ox, _oy, layers, _ramps, end = parse_w3e(w3e)
    heights = [struct.unpack_from("<h", w3e, end - 7 * w * h + 7 * k)[0] for k in range(w * h)]
    base = [k for k in range(w * h) if t.base[k] and not t.frozen[k]]       # frozen: its entrance ramps
    check("the Warcraft base is flat: one cliff level, no height offsets",
          base and len({layers[k] for k in base}) == 1 and all(heights[k] == 8192 for k in base),
          f"{len(base)} corners, {sum(t.base) - len(base)} on its entrance ramps")
    md = t.mapdata
    start, fort = md["warcraft"]["start"], desc["entities"]["forts"]["bad"]
    mine = md["warcraft"]["mines"][0]
    t2 = [tw["pos"] for lane in ("top", "bot") for tw in desc["entities"]["towers"]["bad"].get(lane, [])
          if tw["tier"] == 2]
    exp = md["warcraft"]["expansions"]
    near = all(min(((p["x"] - q[0]) ** 2 + (p["y"] - q[1]) ** 2) ** 0.5 for q in t2) <= 1800 for p in exp)
    check("town hall at the Dire Ancient, gold mine 700 away, expansions by the Dire tier-2 towers",
          abs(start["x"] - fort[0]) <= 32 and abs(start["y"] - fort[1]) <= 32
          and 600 <= ((mine["x"] - start["x"]) ** 2 + (mine["y"] - start["y"]) ** 2) ** 0.5 <= 800
          and len(exp) == 2 and near, f"start {start}, mine {mine}, expansions {exp}")
    test_grove(t)


def seg_dist(p, a, b):
    dx, dy = b[0] - a[0], b[1] - a[1]
    u = max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (dx * dx + dy * dy)))
    return ((a[0] + u * dx - p[0]) ** 2 + (a[1] + u * dy - p[1]) ** 2) ** 0.5


def with_trees(wpm, points):
    """A copy of 640 x 640 pathing cells with a tree's 4 x 4 cells blocked at each point."""
    cells = bytearray(wpm)
    for x, y in points:
        i0, j0 = int((x - 64 + 10240) // 32), int((y - 64 + 10240) // 32)
        for b in range(4):
            for a in range(4):
                if 0 <= i0 + a < 640 and 0 <= j0 + b < 640:
                    cells[(j0 + b) * 640 + i0 + a] = 0xCA
    return cells


def grove_checks(tag, start, mines, spawns, expansions, front, grove, others, wpm, keys):
    """The Warcraft grove as placed on a map: its size and distance, clear
    of the mines, spawns, expansions and the walks from the hall to them, the
    trees nearest the hall, cut by a walkway, every path from the hall still
    open and the front row in the workers' reach. wpm: the map's 640 x 640
    pathing cells without trees; others: every other tree; keys [(name,
    (x, y))] must stay reachable from the hall."""
    sx, sy = start
    dist = [((x - sx) ** 2 + (y - sy) ** 2) ** 0.5 for x, y in grove]
    within = sum(1 for x, y in list(grove) + list(others) if (x - sx) ** 2 + (y - sy) ** 2 <= 1500 ** 2)
    check(f"{tag}: the Warcraft grove holds 40-70 trees", 40 <= len(grove) <= 70,
          f"{len(grove)} trees; {within} trees within 1500 of the Warcraft start")
    if not grove:
        return
    r0, r1 = convert.GROVE_FRONT, convert.GROVE_FRONT + 128 * convert.GROVE_ROWS
    gap = min(dist) - 64 - 256
    check(f"{tag}: grove {convert.GROVE_ROWS} trees deep, its front 450-700 past the hall's side",
          all(r0 <= d < r1 for d in dist) and 450 <= gap <= 700,
          f"{min(dist):.0f}-{max(dist):.0f} from the hall's centre, {gap:.0f} past its side")
    fx, fy = front[0] - sx, front[1] - sy

    def off(p, points, radius):
        return all(((p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2) ** 0.5 >= radius for q in points)

    def fits(p):
        return (off(p, mines, convert.GROVE_MINE) and off(p, spawns, convert.GROVE_SPAWN)
                and off(p, expansions, convert.GROVE_EXPANSION)
                and (not convert.GROVE_BACK_HALF or (p[0] - sx) * fx + (p[1] - sy) * fy <= 0)
                and all(seg_dist(p, start, q) >= convert.GROVE_PATH for q in list(mines) + list(spawns)))
    bad = [p for p in grove if not fits(p)]
    check(f"{tag}: grove off the mine, spawn and expansion discs and the walks to them", not bad,
          f"{len(bad)} trees" if bad else "")
    nearest = min((((x - sx) ** 2 + (y - sy) ** 2) ** 0.5 for x, y in others), default=float("inf"))
    check(f"{tag}: the grove is the tree group nearest the hall", nearest > max(dist), f"next tree {nearest:.0f} away")
    tiles = {(int((x + 10240) // 128), int((y + 10240) // 128)) for x, y in grove}
    clumps, seen_tiles = 0, set()
    for tile in sorted(tiles):
        if tile in seen_tiles:
            continue
        clumps += 1
        stack = [tile]
        seen_tiles.add(tile)
        while stack:
            i, j = stack.pop()
            for n in ((i + a, j + b) for a in (-1, 0, 1) for b in (-1, 0, 1)):
                if n in tiles and n not in seen_tiles:
                    seen_tiles.add(n)
                    stack.append(n)
    check(f"{tag}: a walkway cuts the grove", clumps >= 2, f"{clumps} clumps")
    cells = with_trees(wpm, list(others) + list(grove))
    seen = flood(cells, 640, start)
    seen_before = flood(with_trees(wpm, others), 640, start)
    cut = sum(1 for k in range(640 * 640) if seen_before[k] and not seen[k] and cells[k] != 0xCA)
    lost = [n for n, p in keys if not near(seen, 640, {"x": p[0], "y": p[1]})]
    check(f"{tag}: with every tree standing the hall reaches the spawns, mines, expansions and the Dota base, and "
          f"the grove cuts off at most {convert.GROVE_POCKET} cells", not lost and cut <= convert.GROVE_POCKET,
          f"{cut} cells cut off" + (f", not reachable {lost}" if lost else ""))
    reach = front_row = hidden = 0
    for (x, y), d in zip(grove, dist):
        i0, j0 = int((x - 64 + 10240) // 32), int((y - 64 + 10240) // 32)
        ring = [(i0 + a, j0 + b) for a in range(-1, 5) for b in (-1, 4)]     # a worker cuts from beside or a corner
        ring += [(i0 + a, j0 + b) for a in (-1, 4) for b in range(4)]
        ok = any(seen[j * 640 + i] for i, j in ring)
        reach += ok
        if d < r0 + 128:
            front_row += 1
            hidden += not ok
    check(f"{tag}: workers reach every front-row tree and a third of the grove", not hidden and 3 * reach >= len(grove),
          f"{reach} of {len(grove)} trees in reach, front row {front_row - hidden} of {front_row}")


def open_cells(play):
    """640 x 640 pathing cells: open land in the playable area."""
    cells = bytearray([0xCE]) * (640 * 640)
    lo, hi = int((10240 - play) // 32), int((10240 + play) // 32)
    for j in range(lo, hi):
        cells[j * 640 + lo:j * 640 + hi] = bytes([0x40]) * (hi - lo)
    return cells


def test_grove_rule():
    """The Warcraft grove on the base layout (tools/layout.py places it by
    the personalized map's rule) and on open ground shaped like Dota's Dire
    base: hall, mine 700 away towards the corner, three exits."""
    import layout
    c = layout.WARCRAFT
    grove = layout.warcraft_grove()
    taken = set(grove)
    others = [p for p in layout.trees() if p not in taken]
    keys = [(f"spawn {lane}", p) for lane, p in c["spawns"].items()]
    keys += [("gold mine", p) for p in c["mines"] + c["expansions"]]
    keys += [("Dota fountain", layout.DOTA["fountain"]), ("Dota Ancient", layout.DOTA["ancient"])]
    grove_checks("base layout", c["start"], c["mines"], list(c["spawns"].values()), c["expansions"],
                 layout.DOTA["ancient"], grove, others, open_cells(layout.PLAY), keys)
    hall, mines, spawns = (5536, 4992), [(6048, 5472)], [(3168, 5792), (4096, 3584), (6272, 3648)]

    def inside(x, y):
        return max(abs(x), abs(y)) + 64 <= convert.PLAY
    spots = convert.grove(hall, mines, spawns, (-6300, -6300), inside)
    check("Dire-shaped open ground: the grove is the same on every run",
          spots == convert.grove(hall, mines, spawns, (-6300, -6300), inside))
    keys = [("spawn", p) for p in spawns] + [("gold mine", p) for p in mines]
    grove_checks("Dire-shaped open ground", hall, mines, spawns, [], (-6300, -6300), spots, [],
                 open_cells(convert.PLAY), keys)


def test_grove(t):
    """The Warcraft grove on the converted map: Dire dead trees, by the
    rule's checks (grove_checks) with Dota's trees standing."""
    md = t.mapdata
    c = md["warcraft"]

    def xy(p):
        return p["x"], p["y"]
    taken = set(t.grove)
    rows = [r for r in t.trees if (r[0], r[1]) in taken]
    types = t.tree_plan["types"]
    kind = convert.GROVE_TYPE if types.get(convert.GROVE_TYPE) else convert.TREE_ID
    count = len(types[kind]) if types.get(kind) else 10
    check("the grove is the Dire's dead trees, one tree per spot",
          len(rows) == len(t.grove) and all(r[5] == kind and 0 <= r[3] < count for r in rows),
          f"{len(rows)} {kind} trees")
    f = md["dota"]["fountain"]
    keys = [(f"spawn {lane}", xy(p)) for lane, p in c["spawns"].items()]
    keys += [("gold mine", xy(p)) for p in c["mines"] + c["expansions"]]
    keys += [("Radiant fountain", (f["x"] + 350, f["y"] + 350)), ("Radiant Ancient", xy(md["dota"]["ancient"]))]
    grove_checks("personalized map", xy(c["start"]), [xy(p) for p in c["mines"]],
                 [xy(p) for p in c["spawns"].values()], [xy(p) for p in c["expansions"]], xy(md["dota"]["ancient"]),
                 list(t.grove), [(r[0], r[1]) for r in t.trees if (r[0], r[1]) not in taken], bytes(t.pathing), keys)


def mock_run(script, work):
    """The map script on the mock WC3 API, without the base layout's
    exercises: (ok, log)."""
    try:
        from lupa import lua53
    except ImportError:
        return None, "lupa not installed"
    natives = next((p for p in (ROOT / "build" / "mock_natives.lua",
                                *sorted((ROOT / "build").glob("work_*/mock_natives.lua"))) if p.is_file()), None)
    if natives is None:
        return None, "no mock_natives.lua (run tools/build.py first)"
    lua = lua53.LuaRuntime(unpack_returned_tuples=True)
    for path in (natives, ROOT / "tools" / "mock_runtime.lua"):
        lua.execute(Path(path).read_text(encoding="utf-8"))
    lua.execute(script)
    run = lua.eval("""function(seconds)
        local ok, err = pcall(function() config() main() __mock.advance(seconds) end)
        return ok, tostring(err), __mock.files["DotaVsWarcraft\\\\log.txt"] or ""
    end""")
    ok, err, log = run(75)
    (work / "mock_log.txt").write_text(log + ("\n" + err if not ok else ""), encoding="utf-8")
    return ok and "ERROR" not in log, log if ok else err


def test_dota(dota, base, work):
    cache = work / "cache"
    runs = []
    for label in ("cold", "cold again", "warm"):
        if label != "warm":
            shutil.rmtree(cache, ignore_errors=True)
        t = time.perf_counter()
        try:
            files = terrain.prepare(dota, base, VRF, DLL, cache, lambda s: print("   ", s))
        except terrain.TerrainError as e:
            check(f"terrain step ({label})", False, str(e))
            return
        runs.append((files, time.perf_counter() - t))
    files = runs[0][0]
    check("terrain files identical across cold runs and from the cache",
          runs[0][0] == runs[1][0] == runs[2][0],
          ", ".join(f"{len(r[0])} files in {r[1]:.1f} s" for r in runs))
    extra = sorted(set(files) - set(terrain.MAP_FILES))
    ground_files = {p for t in ground.TILE_FILES for p in (ground.classic_path(t), ground.classic_dds_path(t),
                                                            ground.hd_path(t))}
    check("terrain replaces the layout files and adds only tree models, war3map.w3b and w3d, tile textures",
          set(terrain.MAP_FILES) <= set(files) and "war3map.w3b" in extra
          and all(n in ("war3map.w3b", "war3map.w3d") or n.startswith(trees.MAP_DIR) or n in ground_files
                  for n in extra),
          f"{len(extra)} added")
    test_ground_textures(files)
    data, copied = stormlib.build_archive(DLL, base, files, work / "pack", lambda s: None)
    out = work / "personal.w3x"
    out.write_bytes(data)
    print(f"    personalized map: {out} ({len(data)} bytes, sha256 {hashlib.sha256(data).hexdigest()[:16]})")
    written = read_base(out)
    check("archive opens and holds every replaced file unchanged",
          all(written.get(n) == d for n, d in files.items()), f"{len(written)} files")
    w3e, wpm, doo = written["war3map.w3e"], written["war3map.wpm"], written["war3map.doo"]
    w, h, ox, oy, layers, ramps, end = parse_w3e(w3e)
    check("w3e v11, 161 x 161 corners at -10240, size consistent",
          w3e[:4] == b"W3E!" and struct.unpack_from("<i", w3e, 4)[0] == 11 and (w, h, ox, oy) == (161, 161, -10240, -10240)
          and end == len(w3e))
    size = struct.unpack_from("<iii", wpm, 4)
    check("wpm v0, 640 x 640 cells", wpm[:4] == b"MP3W" and size == (0, 640, 640) and len(wpm) == 16 + 640 * 640)
    kinds = doo_kinds(doo)
    check("doo v8.11: trees and rocks only", doo[:4] == b"W3do" and struct.unpack_from("<i", doo, 4)[0] == 8
          and doo[8] == 11 and set(kinds) <= set(trees.TYPES) | {convert.ROCK_ID} | {d for d, _t in trees.DECOR.values()},
          str(kinds))
    test_tree_models(written, doo, work)
    check("w3i v31 and war3mapUnits.doo v8.11",
          struct.unpack_from("<i", written["war3map.w3i"], 0)[0] == 31
          and struct.unpack_from("<iI", written["war3mapUnits.doo"], 4) == (8, 11))
    mm = Image.open(io.BytesIO(written["war3mapMap.blp"]))
    mm.load()
    check("minimap present: war3mapMap.blp (BLP1, 256 x 256) and war3map.mmp",
          mm.size == (256, 256) and written["war3mapMap.blp"][:4] == b"BLP1" and "war3map.mmp" in written)
    spans = [max(layers[j * w + i], layers[j * w + i + 1], layers[(j + 1) * w + i], layers[(j + 1) * w + i + 1])
             - min(layers[j * w + i], layers[j * w + i + 1], layers[(j + 1) * w + i], layers[(j + 1) * w + i + 1])
             for j in range(h - 1) for i in range(w - 1)]
    check("no tile spans more than two cliff levels", max(spans) <= 2, f"{sum(1 for s in spans if s)} cliff tiles")
    names = transition_names(w, h, layers, ramps)
    unknown = sorted(n for n in names if n not in RAMP_SIDES | FLAT_SIDES)
    sides = sum(c for n, c in names.items() if n in RAMP_SIDES)
    check("ramps ask only for the World Editor's ramp side models", not unknown and sides % 2 == 0,
          f"{sides // 2} ramps" + (f", unknown {unknown[:5]}" if unknown else ""))
    md = json.loads((next(cache.glob("*/terrain-*")) / "files" / "mapdata.json").read_text(encoding="utf-8"))
    cells = wpm[16:]
    seen = flood(cells, 640, (md["dota"]["fountain"]["x"] + 350, md["dota"]["fountain"]["y"] + 350))
    points = [("fountain spawn", {"x": md["dota"]["fountain"]["x"] + 350, "y": md["dota"]["fountain"]["y"] + 350})]
    points += [("ancient", md["dota"]["ancient"]), ("shop", md["dota"]["shop"]), ("roshan", md["roshan"]),
               ("Warcraft start", md["warcraft"]["start"])]
    points += [(f"tower {lane} {i + 1}", p) for lane, ps in md["dota"]["towers"].items() for i, p in enumerate(ps)]
    points += [(f"barracks {lane} {i}", p) for lane, ps in md["dota"]["barracks"].items() for i, p in enumerate(ps)]
    points += [(f"lane {lane} point {i}", p) for lane, ps in md["lanes"].items() for i, p in enumerate(ps)]
    points += [(f"spawn {lane}", p) for lane, p in md["warcraft"]["spawns"].items()]
    points += [(f"camp {n}", p) for n, p in md["camps"].items()]
    points += [("rune", p) for p in md["runes"] + md.get("bounty_runes", [])]
    points += [("gold mine", p) for p in md["warcraft"]["mines"] + md["warcraft"]["expansions"]]
    off = [n for n, p in points if not near(seen, 640, p)]
    check("every structure, camp, rune, mine and lane point is reachable on foot from the fountain", not off,
          f"{len(points)} points, {sum(seen)} reachable cells" + (f", not reachable {off[:6]}" if off else ""))
    check("the Warcraft base exists: town hall, a gold mine and two expansions",
          len(md["warcraft"]["mines"]) == 1 and len(md["warcraft"]["expansions"]) == 2)
    check("Dota's layout: 3 lanes, 11 towers, 6 barracks, 28 camps, 2 power and 2 bounty runes",
          sorted(md["lanes"]) == ["bot", "mid", "top"] and sum(len(v) for v in md["dota"]["towers"].values()) == 11
          and sum(len(v) for v in md["dota"]["barracks"].values()) == 6 and len(md["camps"]) == 28
          and len(md["runes"]) == 2 and len(md.get("bounty_runes", [])) == 2)
    test_blocked_ground(next(cache.glob("*/terrain-*")), cells, w3e)
    ok, log = mock_run(files["war3map.lua"].decode("utf-8"), work)
    want = ["structures created", "world: 28 neutral camps", "world: runes at 2 river and 2 bounty spots",
            "world: Roshan spawned"]
    missing = [s for s in want if s not in (log or "")]
    check("map script runs on the mock API with Dota's layout (no Lua errors, world set up)",
          ok is not False and not missing, (log if ok is None else f"missing {missing}" if missing else ""))
    folder = next(cache.glob("*/terrain-*"))
    for name in ("dota.png", "wc3.png"):
        shutil.copyfile(folder / name, work / name)
    print(f"    pictures: {work / 'dota.png'}, {work / 'wc3.png'}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dota")
    ap.add_argument("--base", help="base map built by tools/build.py (default: build/test/DotaVsWarcraft_test.w3x)")
    ap.add_argument("--work")
    args = ap.parse_args()
    work = (Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="dvw_terrain_"))).resolve()
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    base = (Path(args.base) if args.base else ROOT / "build" / "test" / "DotaVsWarcraft_test.w3x").resolve()
    if not base.is_file():
        base = None
    test_ramp_shape()
    test_lua_patch()
    test_w3e_parity(work)
    test_tree_plan()
    test_object_merge()
    test_tile_shapes()
    test_grove_rule()
    if base and DLL:
        test_start_patches(base)
    else:
        print("[SKIP] start patches: needs a base map and StormLib")
    if args.dota:
        if not (base and DLL and VRF):
            check("Dota test prerequisites (base map, StormLib, VRF)", False)
        else:
            print(f"    base map: {base}")
            test_dota(args.dota, base, work)
    print(f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
