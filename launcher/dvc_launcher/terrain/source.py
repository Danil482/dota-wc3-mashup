"""Dota 2's map from the player's install: export with VRF, parse, describe.

Everything here reads game\\dota\\maps\\dota.vpk, Valve's level data. It runs on
the player's PC only; nothing it reads or writes goes into the repo or the
shipped base map.

  maps/dota/entities/default_ents.vents_c       entity lump (VRF decompiles it to text)
  maps/dota/entities/world_layer_*_base.vents_c  trees of the two base layers
  maps/dota.gnv                                  gridnav: 64-unit cells, bit 0 = walkable
  maps/dota/world_physics.vmdl_c                 collision mesh: ground heights and water
  maps/dota/worldnodes/*agg_merge_mod_*.vmdl_c   ground meshes per material: tile textures

describe() turns them into one JSON-able dict, the "description". Dota and the
Warcraft III map share one frame at 1:1 scale: a point keeps its x, y and z
(the map's centre is Dota's origin, one Dota unit is one WC3 unit).
"""
import array
import base64
import json
import math
import os
import re
import shutil
import struct
import subprocess
from pathlib import Path

from .. import vpkdir, vrf

# The description's raster grid: 32-unit cells (WC3 pathing cells) over the
# whole 160 x 160 tile map, [-10240, 10240) on both axes.
ORIGIN = -10240.0
CELL = 32
SIZE = 640
NO_Z = -32768                      # int16 marker: no surface in this cell
MAT_CELL = 128                     # material bins are WC3 tiles
MAT_SIZE = SIZE * CELL // MAT_CELL
GLTF_UNITS = 1 / 0.0254            # VRF writes model glTF in metres, Y up

ENTITY_FILES = ("maps/dota/entities/default_ents.vents_c",
                "maps/dota/entities/world_layer_radiant_base.vents_c",
                "maps/dota/entities/world_layer_dire_base.vents_c")
GRIDNAV = "maps/dota.gnv"
PHYSICS = "maps/dota/world_physics.vmdl_c"
GROUND_MESHES = re.compile(r"^maps/dota/worldnodes/[^/]*agg_merge_mod_[a-z_]+?_\d+_\d+\.vmdl_c$")
GNV_MAGIC = 0xFADEBEAD


class SourceError(Exception):
    pass


# ------------------------------------------------------------------ export

def _run_vrf(vrf_exe, args, work_dir, what):
    env = dict(os.environ)
    env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
    Path(work_dir).mkdir(parents=True, exist_ok=True)
    try:
        proc = subprocess.run([str(vrf_exe)] + args, cwd=str(work_dir), env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              creationflags=vrf.CREATE_NO_WINDOW, timeout=900)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise SourceError(f"VRF could not run ({what}): {e}") from e
    if proc.returncode != 0:
        tail = "\n".join(proc.stdout.decode("utf-8", "replace").splitlines()[-15:])
        raise SourceError(f"VRF failed ({what}), exit code {proc.returncode}:\n{tail}")


def plan(listing):
    """VPK paths to export, from the listing of maps/dota.vpk."""
    missing = [p for p in ENTITY_FILES[:1] + (GRIDNAV, PHYSICS) if p not in listing]
    if missing:
        raise SourceError(f"not in dota.vpk: {', '.join(missing)}")
    meshes = sorted(p for p in listing if GROUND_MESHES.match(p))
    return {"entities": [p for p in ENTITY_FILES if p in listing], "gridnav": GRIDNAV,
            "physics": PHYSICS, "meshes": meshes}


def export(vrf_exe, maps_vpk, out_dir, work_dir, log):
    """Export what describe() reads into out_dir. Returns the plan."""
    try:
        listing = vpkdir.read_tree(maps_vpk, ("maps/dota",))
    except (OSError, vpkdir.VpkError) as e:
        raise SourceError(f"dota.vpk could not be read: {e}") from e
    p = plan(listing)
    out_dir = Path(out_dir).resolve()
    shutil.rmtree(out_dir, ignore_errors=True)
    vpk = str(Path(maps_vpk).resolve())
    _run_vrf(vrf_exe, ["-i", vpk, "-d", "-o", str(out_dir), "-f", ",".join(p["entities"] + [p["gridnav"]])],
             work_dir, "map entities")
    # Several files per call: -o is then always a folder (one file would make it a file name).
    _run_vrf(vrf_exe, ["-i", vpk, "-d", "-o", str(out_dir), "--gltf_export_format", "glb",
                       "-f", ",".join([p["physics"]] + p["meshes"])], work_dir, "map meshes")
    log(f"terrain: VRF exported {len(p['entities'])} entity lumps, the gridnav, the physics mesh and "
        f"{len(p['meshes'])} ground meshes")
    return p


def exported_paths(out_dir, p):
    out_dir = Path(out_dir)
    entities = [out_dir / (e[:-len(".vents_c")] + ".vents") for e in p["entities"]]
    physics = out_dir / (p["physics"][:-len(".vmdl_c")] + "_physics.glb")
    meshes = [out_dir / (m[:-len(".vmdl_c")] + ".glb") for m in p["meshes"]]
    return {"entities": entities, "gridnav": out_dir / p["gridnav"], "physics": physics, "meshes": meshes}


# ------------------------------------------------------------------ entity lump

_ENTITY_START = re.compile(r"^====\d+====$")
_NUMBER = re.compile(r"^-?\d+(\.\d+)?(e[-+]?\d+)?$")


def _value(text):
    if text.startswith('"') and text.endswith('"'):
        return text[1:-1]
    if text.startswith("resource_name:"):
        return text[len("resource_name:"):].strip('"')
    if text.startswith("[") and text.endswith("]"):
        try:
            return [float(v) for v in text[1:-1].split(",") if v.strip()]
        except ValueError:
            return text
    if text in ("true", "false"):
        return text == "true"
    if _NUMBER.match(text):
        return float(text)
    return text


def parse_entities(text):
    """VRF's decompiled entity lump ("====N====" headers, "key  value" lines)
    -> list of {key: value}. Output connections (lines starting "@") are skipped."""
    entities = []
    cur = None
    for line in text.splitlines():
        if _ENTITY_START.match(line):
            cur = {}
            entities.append(cur)
            continue
        if cur is None or not line or line[0] in " @\t":
            continue
        key, _, value = line.partition(" ")
        cur[key] = _value(value.strip())
    return entities


def _name(e):
    return str(e.get("targetname", "")).replace("[PR#]", "")


def _xy(e):
    o = e.get("origin")
    if not isinstance(o, list) or len(o) < 3:
        raise SourceError(f"entity {e.get('classname')} {_name(e)} has no origin")
    return [round(o[0], 1), round(o[1], 1), round(o[2], 1)]


def _team(e):
    t = e.get("teamnumber")
    try:
        return int(float(t))
    except (TypeError, ValueError):
        return 0


def entity_points(entities):
    """Gameplay positions from the entity lump, keyed by side: "good" is the
    Radiant (bottom left), "bad" the Dire (top right)."""
    by_class = {}
    for e in entities:
        by_class.setdefault(e.get("classname", ""), []).append(e)
    side_of = {2: "good", 3: "bad"}

    def side_by_position(p):
        return "good" if p[0] + p[1] < 0 else "bad"

    towers = {"good": {}, "bad": {}}
    for e in by_class.get("npc_dota_tower", []):
        m = re.match(r"^dota_(goodguys|badguys)_tower(\d)_(top|mid|bot)$", _name(e))
        if not m:
            continue
        side = "good" if m.group(1) == "goodguys" else "bad"
        lane = "base" if m.group(2) == "4" else m.group(3)
        towers[side].setdefault(lane, []).append({"tier": int(m.group(2)), "lane": m.group(3), "pos": _xy(e)})
    for side in towers:
        for lane in towers[side]:
            towers[side][lane].sort(key=lambda t: (t["tier"], t["lane"]))
    barracks = {"good": {}, "bad": {}}
    for e in by_class.get("npc_dota_barracks", []):
        m = re.match(r"^(good|bad)_rax_(melee|range)_(top|mid|bot)$", _name(e))
        if m:
            barracks[m.group(1)].setdefault(m.group(3), {})[m.group(2)] = _xy(e)
    def single(cls, pattern=None):
        out = {}
        for e in by_class.get(cls, []):
            if pattern and not re.search(pattern, _name(e)):
                continue
            p = _xy(e)
            out[side_of.get(_team(e)) or side_by_position(p)] = p
        return out
    forts = single("npc_dota_fort")
    fountains = single("ent_dota_fountain")
    shops = sorted(({"type": int(e.get("shoptype", 0) or 0), "pos": _xy(e)}
                    for e in by_class.get("ent_dota_shop", [])), key=lambda s: (s["type"], s["pos"]))
    spawners = {"good": {}, "bad": {}}
    for cls, es in by_class.items():
        m = re.match(r"^npc_dota_spawner_(good|bad)_(top|mid|bot)$", cls)
        if m and es:
            spawners[m.group(1)][m.group(2)] = _xy(es[0])
    corners = {}
    for e in by_class.get("path_corner", []):
        corners[_name(e)] = {"pos": _xy(e), "next": str(e.get("target", "")).replace("[PR#]", "")}
    lanes = {"good": {}, "bad": {}}
    for name in corners:
        m = re.match(r"^lane_(top|mid|bot)_pathcorner_(goodguys|badguys)_1$", name)
        if not m:
            continue
        chain, seen, cur = [], set(), name
        while cur in corners and cur not in seen:
            seen.add(cur)
            chain.append(corners[cur]["pos"])
            cur = corners[cur]["next"]
        lanes["good" if m.group(2) == "goodguys" else "bad"][m.group(1)] = chain
    camps = []
    for e in by_class.get("npc_dota_neutral_spawner", []):
        volume = str(e.get("volumename", "")).replace("[PR#]", "")
        p = _xy(e)
        side = "good" if "_good_" in volume else "bad" if "_evil_" in volume else side_by_position(p)
        camps.append({"side": side, "type": int(e.get("neutraltype", 1) or 0), "volume": volume, "pos": p})
    camps.sort(key=lambda c: (c["side"], c["type"], c["pos"]))
    def points(cls):
        return sorted(_xy(e) for e in by_class.get(cls, []))
    tree_entities = [e for e in by_class.get("ent_dota_tree", [])]
    trees = sorted({(int(round(o[0])), int(round(o[1]))) for o in (_xy(e) for e in tree_entities)})
    bounds = by_class.get("world_bounds", [{}])[0]
    def vec(s):
        try:
            return [float(v) for v in str(s).split()]
        except ValueError:
            return None
    return {
        "towers": towers, "barracks": barracks, "forts": forts, "fountains": fountains, "shops": shops,
        "spawners": spawners, "lanes": lanes, "camps": camps,
        "runes": {"power": points("dota_item_rune_spawner_powerup"), "bounty": points("dota_item_rune_spawner_bounty")},
        "roshan": points("npc_dota_roshan_spawner"),
        "outposts": points("npc_dota_watch_tower"),
        "lotus_pools": points("npc_dota_lotus_pool"),
        "twin_gates": points("npc_dota_unit_twin_gate"),
        "tormentors": points("npc_dota_miniboss_spawner"),
        "wisdom_shrines": points("npc_dota_xp_fountain"),
        "player_starts": {"good": points("info_player_start_goodguys"), "bad": points("info_player_start_badguys")},
        "world_bounds": {"min": vec(bounds.get("min")), "max": vec(bounds.get("max"))},
        "trees": [list(t) for t in trees],
    }


# ------------------------------------------------------------------ gridnav

class Gridnav:
    """maps/dota.gnv: a header (magic, cell size, offsets, width, height,
    first cell x/y) and one flag byte per cell. Bit 0 set = walkable."""

    def __init__(self, data):
        if len(data) < 32:
            raise SourceError("dota.gnv is too small")
        magic, edge, _ox, _oy, w, h, x0, y0 = struct.unpack_from("<Ifffiiii", data, 0)
        if magic != GNV_MAGIC or edge != 64.0 or w <= 0 or h <= 0 or len(data) != 32 + w * h:
            raise SourceError(f"unexpected dota.gnv header (magic {magic:#x}, cell {edge}, {w}x{h})")
        self.width, self.height, self.x0, self.y0 = w, h, x0, y0
        self.cells = data[32:]

    def flags(self, x, y):
        i = int(math.floor(x / 64)) - self.x0
        j = int(math.floor(y / 64)) - self.y0
        if 0 <= i < self.width and 0 <= j < self.height:
            return self.cells[j * self.width + i]
        return 0

    def walkable(self, x, y):
        return bool(self.flags(x, y) & 1)


# ------------------------------------------------------------------ glTF

def read_glb(path):
    data = Path(path).read_bytes()
    if len(data) < 20 or data[:4] != b"glTF":
        raise SourceError(f"{Path(path).name} is not a glTF binary")
    json_len = struct.unpack_from("<I", data, 12)[0]
    doc = json.loads(data[20:20 + json_len])
    bin_start = 20 + json_len + 8
    return doc, data, bin_start


def _accessor(doc, data, bin_start, index, step=1):
    a = doc["accessors"][index]
    view = doc["bufferViews"][a["bufferView"]]
    comps = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
    code = {5126: "f", 5125: "I", 5123: "H", 5121: "B"}[a["componentType"]]
    size = array.array(code).itemsize
    stride = view.get("byteStride", comps * size)
    if stride != comps * size:
        raise SourceError("interleaved glTF buffers are not supported")
    start = bin_start + view.get("byteOffset", 0) + a.get("byteOffset", 0)
    out = array.array(code)
    out.frombytes(data[start:start + a["count"] * comps * size])
    return out


def mesh_triangles(glb, name_filter):
    """[(positions, indices)] of the meshes whose name passes name_filter."""
    doc, data, bin_start = glb
    out = []
    for mesh in doc.get("meshes", []):
        if not name_filter(mesh.get("name", "")):
            continue
        for prim in mesh["primitives"]:
            if prim.get("mode", 4) != 4 or "indices" not in prim:
                continue
            out.append((_accessor(doc, data, bin_start, prim["attributes"]["POSITION"]),
                        _accessor(doc, data, bin_start, prim["indices"])))
    return out


def raster_top(parts, up_only):
    """Highest z of the triangles over each 32-unit cell centre (list, None = no
    triangle). up_only keeps faces less than 60 degrees from horizontal, so
    walls do not count; the physics mesh is in Dota units with z up."""
    top = [None] * (SIZE * SIZE)
    inv = 1.0 / CELL
    for pos, idx in parts:
        for t in range(0, len(idx) - 2, 3):
            a, b, c = 3 * idx[t], 3 * idx[t + 1], 3 * idx[t + 2]
            ax, ay, az = pos[a], pos[a + 1], pos[a + 2]
            ux, uy, uz = pos[b] - ax, pos[b + 1] - ay, pos[b + 2] - az
            vx, vy, vz = pos[c] - ax, pos[c + 1] - ay, pos[c + 2] - az
            det = ux * vy - uy * vx
            if det == 0:
                continue
            if up_only:
                nx, ny = uy * vz - uz * vy, uz * vx - ux * vz
                if det * det < 0.25 * (nx * nx + ny * ny + det * det):
                    continue
            xs = (ax, ax + ux, ax + vx)
            ys = (ay, ay + uy, ay + vy)
            i0 = max(0, math.ceil((min(xs) - ORIGIN) * inv - 0.5))
            i1 = min(SIZE - 1, math.floor((max(xs) - ORIGIN) * inv - 0.5))
            if i0 > i1:
                continue
            j0 = max(0, math.ceil((min(ys) - ORIGIN) * inv - 0.5))
            j1 = min(SIZE - 1, math.floor((max(ys) - ORIGIN) * inv - 0.5))
            for j in range(j0, j1 + 1):
                py = ORIGIN + (j + 0.5) * CELL - ay
                row = j * SIZE
                for i in range(i0, i1 + 1):
                    px = ORIGIN + (i + 0.5) * CELL - ax
                    s = (px * vy - py * vx) / det
                    if s < -1e-6:
                        continue
                    r = (ux * py - uy * px) / det
                    if r < -1e-6 or s + r > 1 + 1e-6:
                        continue
                    z = az + s * uz + r * vz
                    k = row + i
                    if top[k] is None or z > top[k]:
                        top[k] = z
    return top


def material_of(mesh_path):
    """Material class of a ground mesh from its name."""
    name = Path(mesh_path).stem
    m = re.search(r"agg_merge_mod_([a-z_]+?)_\d+_\d+$", name)
    key = m.group(1) if m else name
    side = "dire" if key.startswith("dire") else "radiant"
    if "riverbed" in key:
        kind = "river"
    elif "cracked" in key:
        kind = "cracked"
    elif "base" in key:
        kind = "base"
    elif "path" in key:
        kind = "path"
    else:
        kind = "ground"
    if key.startswith("radiant_dire"):
        side = "mixed"
    return f"{side}_{kind}"


def material_bins(mesh_paths, step=4):
    """Per 128-unit tile: the material whose mesh has the most vertices there.
    Every step-th vertex is sampled; the meshes are dense, so that is plenty."""
    names = sorted({material_of(p) for p in mesh_paths})
    counts = {n: array.array("i", [0]) * (MAT_SIZE * MAT_SIZE) for n in names}
    for p in sorted(mesh_paths, key=str):
        doc, data, bin_start = read_glb(p)
        c = counts[material_of(p)]
        for mesh in doc.get("meshes", []):
            for prim in mesh["primitives"]:
                pos = _accessor(doc, data, bin_start, prim["attributes"]["POSITION"])
                xs = pos[0::3 * step]
                zs = pos[2::3 * step]
                for x, z in zip(xs, zs):
                    # VRF's model glTF: x stays x, Dota y is glTF z, metres
                    i = int((x * GLTF_UNITS - ORIGIN) // MAT_CELL)
                    j = int((z * GLTF_UNITS - ORIGIN) // MAT_CELL)
                    if 0 <= i < MAT_SIZE and 0 <= j < MAT_SIZE:
                        c[j * MAT_SIZE + i] += 1
    out = bytearray(MAT_SIZE * MAT_SIZE)
    for k in range(MAT_SIZE * MAT_SIZE):
        best, pick = 0, 255
        for n_i, n in enumerate(names):
            v = counts[n][k]
            if v > best:
                best, pick = v, n_i
        out[k] = pick
    return names, bytes(out)


# ------------------------------------------------------------------ slopes

def find_ramps(height, walk):
    """Walkable slopes between two height levels (multiples of 128): Dota's
    ramps. Returns [{"low", "high", "cells", "center", "grad", "bbox", "width"}]."""
    def level(k):
        z = height[k]
        if z is None:
            return None
        lv = z / 128.0
        r = round(lv)
        return r if abs(lv - r) <= 0.125 else "S"
    kinds = [level(k) if walk[k] else None for k in range(SIZE * SIZE)]
    seen = bytearray(SIZE * SIZE)
    ramps = []
    for start in range(SIZE * SIZE):
        if kinds[start] != "S" or seen[start]:
            continue
        stack, cells = [start], []
        seen[start] = 1
        while stack:
            k = stack.pop()
            cells.append(k)
            i, j = k % SIZE, k // SIZE
            for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                a, b = i + di, j + dj
                if 0 <= a < SIZE and 0 <= b < SIZE:
                    n = b * SIZE + a
                    if not seen[n] and kinds[n] == "S":
                        seen[n] = 1
                        stack.append(n)
        contact = {}
        gx = gy = 0.0
        for k in cells:
            i, j = k % SIZE, k // SIZE
            for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                a, b = i + di, j + dj
                if 0 <= a < SIZE and 0 <= b < SIZE:
                    lv = kinds[b * SIZE + a]
                    if isinstance(lv, int):
                        contact[lv] = contact.get(lv, 0) + 1
            if 0 < i < SIZE - 1 and 0 < j < SIZE - 1:
                zl, zr = height[k - 1], height[k + 1]
                zd, zu = height[k - SIZE], height[k + SIZE]
                if None not in (zl, zr, zd, zu) and abs(zr - zl) < 400 and abs(zu - zd) < 400:
                    gx += zr - zl
                    gy += zu - zd
        levels = sorted(lv for lv, n in contact.items() if n >= 6)
        if len(cells) < 12 or len(levels) < 2:
            continue
        low, high = levels[0], levels[-1]
        xs = [ORIGIN + (k % SIZE + 0.5) * CELL for k in cells]
        ys = [ORIGIN + (k // SIZE + 0.5) * CELL for k in cells]
        cx, cy = sum(xs) / len(xs), sum(ys) / len(ys)
        ang = math.atan2(gy, gx)
        # extent across the slope direction
        ex, ey = -math.sin(ang), math.cos(ang)
        across = [(x - cx) * ex + (y - cy) * ey for x, y in zip(xs, ys)]
        ramps.append({"low": low, "high": high, "cells": len(cells), "center": [round(cx, 1), round(cy, 1)],
                      "grad": round(math.degrees(ang), 1),
                      "bbox": [min(xs) - CELL / 2, min(ys) - CELL / 2, max(xs) + CELL / 2, max(ys) + CELL / 2],
                      "width": round(max(across) - min(across) + CELL, 1)})
    ramps.sort(key=lambda r: (r["center"][1], r["center"][0]))
    return ramps


# ------------------------------------------------------------------ description

def _pack_z(values):
    out = array.array("h", (NO_Z if v is None else max(-32767, min(32767, int(round(v)))) for v in values))
    if out.itemsize != 2:
        raise SourceError("int16 arrays are not 2 bytes here")
    return base64.b64encode(out.tobytes()).decode("ascii")


def unpack_z(text):
    out = array.array("h")
    out.frombytes(base64.b64decode(text))
    return [None if v == NO_Z else v for v in out]


def describe(paths, log):
    """The description dict (see the module docstring) from exported files."""
    entities = []
    for p in paths["entities"]:
        entities += parse_entities(Path(p).read_text(encoding="utf-8", errors="replace"))
    points = entity_points(entities)
    log(f"terrain: {len(entities)} entities, {len(points['trees'])} trees, {len(points['camps'])} camps")
    gnv = Gridnav(Path(paths["gridnav"]).read_bytes())
    walk = bytearray(SIZE * SIZE)
    for j in range(SIZE):
        y = ORIGIN + (j + 0.5) * CELL
        for i in range(SIZE):
            walk[j * SIZE + i] = 1 if gnv.walkable(ORIGIN + (i + 0.5) * CELL, y) else 0
    glb = read_glb(paths["physics"])
    names = [m.get("name", "") for m in glb[0].get("meshes", [])]
    water_names = [n for n in names if "water" in n]
    ground = [n for n in names if n not in water_names and "clip" not in n and "window" not in n]
    if not ground:
        raise SourceError(f"no ground mesh in the physics export ({names})")
    height = raster_top(mesh_triangles(glb, lambda n: n in ground), up_only=True)
    water = raster_top(mesh_triangles(glb, lambda n: n in water_names), up_only=False)
    del glb
    if sum(1 for v in height if v is not None) < SIZE * SIZE // 4:
        raise SourceError("the physics mesh covers too little of the map")
    mat_names, mat = material_bins(paths["meshes"]) if paths["meshes"] else ([], bytes([255]) * MAT_SIZE ** 2)
    ramps = find_ramps(height, walk)
    log(f"terrain: {len(ramps)} ramps, {len(mat_names)} ground materials, "
        f"{sum(walk)} walkable cells of {SIZE * SIZE}")
    xs = [ORIGIN + (k % SIZE + 0.5) * CELL for k in range(SIZE * SIZE) if walk[k]]
    ys = [ORIGIN + (k // SIZE + 0.5) * CELL for k in range(SIZE * SIZE) if walk[k]]
    return {
        "format": 1,
        "frame": "WC3 x, y, z = Dota x, y, z (1:1, same origin); WC3 cliff layer = 2 + round(z / 128)",
        "grid": {"origin": ORIGIN, "cell": CELL, "size": SIZE},
        "walkable_bounds": [min(xs) - CELL / 2, min(ys) - CELL / 2, max(xs) + CELL / 2, max(ys) + CELL / 2],
        "height": _pack_z(height),
        "water": _pack_z(water),
        "walkable": base64.b64encode(bytes(walk)).decode("ascii"),
        "material": {"cell": MAT_CELL, "size": MAT_SIZE, "names": mat_names,
                     "data": base64.b64encode(mat).decode("ascii")},
        "ramps": ramps,
        "entities": points,
    }
