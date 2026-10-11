"""Warcraft III map files for the converted terrain, in the formats the base
build writes (tools/build_map.js): w3e v11 (the same hand-written layout,
corner by corner), wpm v0, doo v8 with skins, plus in-place patches of the
base map's w3i, war3mapUnits.doo and war3map.lua."""
import io
import json
import math
import re
import struct

from . import convert

W3E_VERSION = 11
TREE_DOO_BUILD = 132          # build_map.js saves doo with buildVersion 132 (with skins)
MAPDATA_BEGIN = "-- @dvc-data-begin data.mapdata"
MAPDATA_END = "-- @dvc-data-end data.mapdata"


class W3xError(Exception):
    pass


def _js_round(v):
    """Math.round as build_map.js uses it (halves round up)."""
    return int(math.floor(v + 0.5))


def write_w3e(t, tileset="L"):
    """war3map.w3e v11, byte for byte the layout of build_map.js writeW3e."""
    out = bytearray()
    out += b"W3E!" + struct.pack("<i", W3E_VERSION) + tileset.encode("ascii") + struct.pack("<i", 0)
    out += struct.pack("<i", len(convert.TILE_IDS)) + "".join(convert.TILE_IDS).encode("ascii")
    out += struct.pack("<i", len(convert.CLIFF_IDS)) + "".join(convert.CLIFF_IDS).encode("ascii")
    out += struct.pack("<iiff", convert.N, convert.N, float(convert.ORIGIN), float(convert.ORIGIN))
    n = convert.N
    for j in range(n):
        for i in range(n):
            k = j * n + i
            edge = abs(convert.ORIGIN + 128 * i) > convert.PLAY or abs(convert.ORIGIN + 128 * j) > convert.PLAY
            ground = _js_round(t.height[k] * 512 + 8192)
            water_raw = _js_round((t.water_z[k] + 89.6) / 128.0 * 512 + 8192)
            layer = convert.LAYER0 + t.level[k]
            if not (0 <= layer <= 15 and 0 <= ground < 32768 and 0 <= water_raw < 0x4000):
                raise W3xError(f"corner {i},{j} out of range: layer {layer}, height {ground}, water {water_raw}")
            flags = (0x10 if t.ramp[k] else 0) | (0x40 if t.water[k] else 0) | (t.tex[k] & 0x0F)
            out += struct.pack("<hhBBB", ground, (water_raw & 0x3FFF) | (0x4000 if edge else 0), flags,
                               ((0 & 7) << 5) | (t.var[k] & 0x1F), ((t.cliff_tex[k] & 0x0F) << 4) | (layer & 0x0F))
    return bytes(out)


def write_wpm(t):
    size = convert.CELLS
    return b"MP3W" + struct.pack("<iii", 0, size, size) + bytes(t.pathing)


def write_doo(t, dota_trees=True):
    """war3map.doo v8 (subversion 11): the trees (destructables), then the
    rocks and the decorative trees on raised ground (doodads; the pathing map
    already holds Dota's pathing). With dota_trees the trees use the types,
    variations, facings and scales that carry Dota's tree models (trees.py);
    without, they are plain WC3 summer trees and the decorative trees are
    left out (the map's look when the tree models could not be made)."""
    # flags: 2 = visible and solid (trees: their pathing applies in game),
    # 1 = visible, not solid (the doodads add no pathing of their own).
    entries = []
    for x, y, z, v, s, kind, angle in t.trees:
        if dota_trees:
            entries.append((kind, v, x, y, z, angle, s, 2))
        else:
            h = convert._hash(x, y, 13)
            entries.append((convert.TREE_ID, h % 10, x, y, z, 4.712389, round(0.85 + (h >> 8) % 26 / 100.0, 2), 2))
    entries += [(convert.ROCK_ID, v, x, y, z, a, s, 1) for x, y, z, v, s, a in getattr(t, "rocks", ())]
    if dota_trees:                     # decorative Dota trees (doodads whose models trees.py replaces)
        entries += [(kind, v, x, y, z, a, s, 1) for x, y, z, v, s, kind, a in getattr(t, "decor", ())]
    out = bytearray(b"W3do" + struct.pack("<i", 8) + bytes([11, 0, 0, 0]) + struct.pack("<I", len(entries)))
    for n, (kind, variation, x, y, z, angle, scale, flags) in enumerate(entries):
        tid = kind.encode("ascii")
        out += tid + struct.pack("<i", variation) + struct.pack("<3f", x, y, z) + struct.pack("<f", angle)
        out += struct.pack("<3f", scale, scale, scale) + tid + struct.pack("<BB", flags, 100)
        out += struct.pack("<Ii", 0xFFFFFFFF, 0) + struct.pack("<i", n)
    out += bytes(4) + struct.pack("<I", 0)
    return bytes(out)


def minimap_blp(t):
    from . import render
    img = render.minimap(t).quantize(colors=256)
    buf = io.BytesIO()
    img.save(buf, format="BLP", blp_version="BLP1")
    return buf.getvalue()


# ------------------------------------------------------------------ w3i

class _Reader:
    def __init__(self, data):
        self.data, self.pos = data, 0

    def take(self, fmt):
        v = struct.unpack_from("<" + fmt, self.data, self.pos)
        self.pos += struct.calcsize("<" + fmt)
        return v

    def cstring(self):
        end = self.data.index(b"\0", self.pos)
        s = self.data[self.pos:end]
        self.pos = end + 1
        return s


def w3i_start_offsets(data):
    """{player id: byte offset of its start location (2 floats)} in a w3i of
    version 28 or later, plus the offsets of the camera bounds."""
    r = _Reader(data)
    version, = r.take("i")
    if version < 28:
        raise W3xError(f"w3i version {version} not supported")
    r.take("ii")
    r.take("4I")
    for _ in range(4):
        r.cstring()
    r.take("8f")
    r.take("4i")
    r.take("2i")
    r.take("I")
    r.take("c")
    r.take("i")
    r.cstring()                    # loading screen model
    for _ in range(3):
        r.cstring()
    r.take("i")
    r.cstring()                    # prologue model
    for _ in range(3):
        r.cstring()
    r.take("i")
    r.take("2f")
    r.take("f")
    r.take("4B")
    r.take("i")
    r.cstring()
    r.take("c")
    r.take("4B")
    r.take("I")
    if version > 30:
        r.take("II")
    count, = r.take("i")
    out = {}
    for _ in range(count):
        pid, _type, _race, _fixed = r.take("4i")
        r.cstring()
        out[pid] = r.pos
        r.take("2f")
        r.take("II")
        if version > 30:
            r.take("8B")
    return out


def patch_w3i(data, starts):
    """The base w3i with new start locations {player id: (x, y)}."""
    offsets = w3i_start_offsets(data)
    out = bytearray(data)
    for pid, (x, y) in starts.items():
        if pid not in offsets:
            raise W3xError(f"w3i has no player {pid}")
        struct.pack_into("<2f", out, offsets[pid], float(x), float(y))
    return bytes(out)


def w3i_starts(data):
    offsets = w3i_start_offsets(data)
    return {pid: struct.unpack_from("<2f", data, off) for pid, off in offsets.items()}


# ------------------------------------------------------------------ war3mapUnits.doo

def patch_units(data, starts):
    """The base war3mapUnits.doo (v8, subversion 11, with skins) with each
    start location unit ('sloc') moved to its player's start (x, y)."""
    if data[:4] != b"W3do":
        raise W3xError("war3mapUnits.doo: bad header")
    version, sub, count = struct.unpack_from("<iIi", data, 4)
    if version != 8 or sub != 11:
        raise W3xError(f"war3mapUnits.doo version {version}.{sub} not supported")
    out = bytearray(data)
    pos = 16
    moved = 0
    for _ in range(count):
        uid = data[pos:pos + 4]
        loc = pos + 8
        pos += 4 + 4 + 12 + 4 + 12 + 4          # id, variation, location, angle, scale, skin
        _flags, player = struct.unpack_from("<Bi", data, pos)
        pos += 1 + 4 + 2 + 4 + 4 + 4               # flags, player, unknown, hp, mana, item table
        sets, = struct.unpack_from("<i", data, pos)
        pos += 4
        for _s in range(sets):
            n, = struct.unpack_from("<i", data, pos)
            pos += 4 + 8 * n
        pos += 4 + 4 + 4 + 12                      # gold, acquisition, hero level, str/agi/int
        items, = struct.unpack_from("<i", data, pos)
        pos += 4 + 8 * items
        abilities, = struct.unpack_from("<i", data, pos)
        pos += 4 + 12 * abilities
        random_flag, = struct.unpack_from("<i", data, pos)
        pos += 4
        if random_flag == 0:
            pos += 4
        elif random_flag == 1:
            pos += 8
        elif random_flag == 2:
            n, = struct.unpack_from("<i", data, pos)
            pos += 4 + 8 * n
        pos += 12                                  # team colour, waygate, creation number
        if uid == b"sloc" and player in starts:
            x, y = starts[player]
            struct.pack_into("<2f", out, loc, float(x), float(y))
            moved += 1
    if pos != len(data):
        raise W3xError("war3mapUnits.doo: unexpected layout")
    return bytes(out), moved


# ------------------------------------------------------------------ war3map.lua

def lua_literal(v, indent=0):
    """The Lua table syntax of tools/build_lua.py lua_literal (same output)."""
    pad = " " * indent
    if isinstance(v, dict):
        items = []
        for k in sorted(v):
            key = k if k.isidentifier() else "[" + json.dumps(k) + "]"
            items.append(f"{pad} {key} = {lua_literal(v[k], indent + 1)}")
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(v, list):
        return "{" + ", ".join(lua_literal(x, indent + 1) for x in v) + "}"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    return json.dumps("" if v is None else str(v), ensure_ascii=False)


def mapdata_chunk(mapdata):
    """The data.mapdata module exactly as build_lua.py emits a data module."""
    return f"define({json.dumps('data.mapdata')}, function()\n    return {lua_literal(mapdata, 4)}\nend)\n"


def patch_lua(script, mapdata):
    """war3map.lua with the data.mapdata block between the build's markers
    replaced. The markers stay, so the result can be patched again."""
    pattern = re.compile(re.escape(MAPDATA_BEGIN) + r"\n.*?" + re.escape(MAPDATA_END), re.S)
    found = pattern.findall(script)
    if len(found) != 1:
        raise W3xError(f"war3map.lua has {len(found)} marked data.mapdata blocks, expected 1 "
                       "(base map built before the marker contract?)")
    block = f"{MAPDATA_BEGIN}\n{mapdata_chunk(mapdata)}{MAPDATA_END}"
    return pattern.sub(lambda _m: block, script)
