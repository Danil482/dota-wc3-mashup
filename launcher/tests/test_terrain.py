"""Tests of Dota's map layout in the personalized map (launcher/dvc_launcher/terrain).

Offline part (no Dota 2 needed):
  - the w3e writer gives the bytes of tools/build_map.js writeW3e (node);
  - a straight cliff gets a ramp of the World Editor's shape, asking only for
    the ramp side models Blizzard's ladder maps use;
  - the data.mapdata block of war3map.lua is swapped between the build's
    markers, keeps build_lua.py's syntax and still compiles (lupa);
  - start locations in war3map.w3i and war3mapUnits.doo are patched in place.

With --dota, on a base map from tools/build.py: the real pipeline runs cold
twice into a scratch cache and must give byte-identical files, then warm from
the cache. The personalized map is written with StormLib and checked: the
archive opens, file versions, the minimap, every structure, camp, rune and
lane point on walkable ground and reachable from the fountain, the commander
reaching the Ancient, only known ramp models, and the map script running on
the mock WC3 API with the new layout. Pictures: <work>/dota.png, <work>/wc3.png.

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

from dvc_launcher import stormlib, terrain  # noqa: E402
from dvc_launcher.terrain import convert, w3x  # noqa: E402

DLL = next((p for p in (ROOT / "launcher" / "vendor" / "stormlib" / "x64" / "StormLib.dll",
                        ROOT / "dist" / "DotaVsCommander" / "StormLib.dll") if p.is_file()), None)
VRF = next((p for p in (ROOT / "launcher" / "vendor" / "vrf" / "Source2Viewer-CLI.exe",
                        ROOT / "dist" / "DotaVsCommander" / "vrf" / "Source2Viewer-CLI.exe") if p.is_file()), None)
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
    script = ("before\n-- @dvc-data-begin data.heroes\ndefine(\"data.heroes\", function()\n    return {}\nend)\n"
              "-- @dvc-data-end data.heroes\n\n-- @dvc-data-begin data.mapdata\ndefine(\"data.mapdata\", function()\n"
              "    return {\n     old = 1\n    }\nend)\n-- @dvc-data-end data.mapdata\nafter\n")
    md = {"bounds": {"min": -9216, "max": 9216}, "camps": {"d_small1": {"x": 10, "y": -20}},
          "lanes": {"mid": [{"x": 1, "y": 2}, {"x": 3, "y": 4}]}, "runes": []}
    out = w3x.patch_lua(script, md)
    again = w3x.patch_lua(out, md)
    kept = out.startswith("before\n-- @dvc-data-begin data.heroes") and out.endswith("-- @dvc-data-end data.mapdata\nafter\n")
    check("data.mapdata block replaced between the markers, the rest kept, repeatable",
          kept and "old = 1" not in out and out.count("@dvc-data-begin data.mapdata") == 1 and again == out)
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
        return ok, tostring(err), __mock.files["DotaVsCommander\\\\log.txt"] or ""
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
    check("terrain replaces exactly the layout files", sorted(files) == sorted(terrain.MAP_FILES), sorted(files))
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
    check("doo v8.11, trees only", doo[:4] == b"W3do" and struct.unpack_from("<i", doo, 4)[0] == 8 and doo[8] == 11,
          f"{struct.unpack_from('<I', doo, 12)[0]} trees")
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
               ("commander start", md["commander"]["start"])]
    points += [(f"tower {lane} {i + 1}", p) for lane, ps in md["dota"]["towers"].items() for i, p in enumerate(ps)]
    points += [(f"barracks {lane} {i}", p) for lane, ps in md["dota"]["barracks"].items() for i, p in enumerate(ps)]
    points += [(f"lane {lane} point {i}", p) for lane, ps in md["lanes"].items() for i, p in enumerate(ps)]
    points += [(f"spawn {lane}", p) for lane, p in md["commander"]["spawns"].items()]
    points += [(f"camp {n}", p) for n, p in md["camps"].items()]
    points += [("rune", p) for p in md["runes"] + md.get("bounty_runes", [])]
    points += [("gold mine", p) for p in md["commander"]["mines"] + md["commander"]["expansions"]]
    off = [n for n, p in points if not near(seen, 640, p)]
    check("every structure, camp, rune, mine and lane point is reachable on foot from the fountain", not off,
          f"{len(points)} points, {sum(seen)} reachable cells" + (f", not reachable {off[:6]}" if off else ""))
    check("the commander's base exists: town hall, a gold mine and two expansions",
          len(md["commander"]["mines"]) == 1 and len(md["commander"]["expansions"]) == 2)
    check("Dota's layout: 3 lanes, 11 towers, 6 barracks, 28 camps, 2 power and 2 bounty runes",
          sorted(md["lanes"]) == ["bot", "mid", "top"] and sum(len(v) for v in md["dota"]["towers"].values()) == 11
          and sum(len(v) for v in md["dota"]["barracks"].values()) == 6 and len(md["camps"]) == 28
          and len(md["runes"]) == 2 and len(md.get("bounty_runes", [])) == 2)
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
    ap.add_argument("--base", help="base map built by tools/build.py (default: build/test/DotaVsCommander_test.w3x)")
    ap.add_argument("--work")
    args = ap.parse_args()
    work = (Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="dvc_terrain_"))).resolve()
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    base = (Path(args.base) if args.base else ROOT / "build" / "test" / "DotaVsCommander_test.w3x").resolve()
    if not base.is_file():
        base = None
    test_ramp_shape()
    test_lua_patch()
    test_w3e_parity(work)
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
