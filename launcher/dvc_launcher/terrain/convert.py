"""Dota description (source.describe) -> Warcraft III terrain.

The map keeps the base map's size: 160 x 160 tiles, centre at the origin,
playable area [-9216, 9216]. Dota's walkable area ([-8768, 8832] on x) fits
inside it at 1:1, so every Dota coordinate is used as is.

Heights: Dota's ground sits on levels 128 units apart (river 0, lanes 128, high
ground 256, fountain platforms 384), exactly the WC3 cliff step. A corner's
cliff layer is 2 + its Dota level, so a Dota step becomes a WC3 cliff.

Ramps: every walkable Dota slope between two levels becomes a WC3 ramp of the
shape the World Editor's ramp tool makes (checked against Blizzard's ladder
maps): three corner lines along the slope (low, low, high, the middle one on
the lower layer), ramp-flagged over the ramp's width, with one unflagged line
of the same profile on each side. WC3 ramps run along x or y, so a diagonal
Dota ramp gets the axis nearest its slope.

Pathing follows the game's rules: a cliff tile is unwalkable unless all four
corners are ramp corners, the two side pieces of a ramp are unwalkable, and
everything else is walkable where Dota's gridnav is.

Blocked ground looks blocked: Dota's unwalkable areas (map edges, behind the
fountains, rock formations) rise into WC3 cliffs wherever they are wide enough
for a cliff tile to sit wholly on unwalkable cells, so no walkable cell is
lost; the strips too narrow for that get rocks (doodads, visual only: the
pathing map stays Dota's).

The commander replaces the Dire: the Dire high ground (with the fountain
platform) becomes one flat, buildable level without trees or props, and the
commander's town hall stands where the Dire Ancient stood.
"""
import base64
import math

from . import source, trees

TILES = 160
N = TILES + 1                      # corners per side
ORIGIN = -10240
PLAY = 9216                        # playable half size, as in the base map
LAYER0 = 2                         # WC3 layer of Dota level 0 (z 0)
CELLS = TILES * 4                  # pathing cells per side (32 units)

# Ground tiles. Each stands for one layer of Dota's ground materials, and
# ground.py gives it that layer's texture (on the personalized map; without
# it they keep the nearest Warcraft III look). Later tiles draw over earlier
# ones, so grass overlaps paths and paths overlap rock, as in Dota.
TILE_IDS = ["Lrok", "Adrd", "Ldro", "Bdrr", "Bflr", "Yrtl", "Bdrt", "Bdsd", "Bdsr", "Ldrt", "Ldrg", "Lgrd", "Lgrs"]
CLIFF_IDS = ["CLdi", "CLgr"]
T = {name: i for i, name in enumerate(TILE_IDS)}
UNBUILDABLE = {"Lrok", "Bdrr", "Bflr", "Yrtl"}     # TerrainArt\Terrain.slk buildable = 0
# Dota ground material (the worldnode mesh name) -> the tile of each of its
# four multiblend layers (source.layer_bins). The layers, from the
# materials' colour textures: radiant: sand path, long grass, grass, rock;
# *_path: + flagstones on top; riverbed: sand, river rocks, river rocks,
# rock; dire: rock, cracked earth, pale cracked sand, rock; dire_path: stone
# path, cracked earth, pale sand, dark sand; dire_path_cracked: + molten cracks.
LAYER_TILES = {
    "radiant": ("Ldrt", "Lgrd", "Lgrs", "Lrok"),
    "radiant_path": ("Ldrt", "Ldrg", "Lgrs", "Yrtl"),
    "radiant_base_angled": ("Ldrt", "Lgrd", "Lgrs", "Yrtl"),
    "radiant_riverbed_path": ("Ldrt", "Ldro", "Ldro", "Lrok"),
    "radiant_dire": ("Adrd", "Bdsr", "Lgrs", "Lrok"),
    "radiant_dire_path": ("Ldrt", "Bdsr", "Lgrs", "Bdrt"),
    "radiant_path_destruction": ("Lrok", "Lrok", "Lrok", "Lrok"),
    "dire": ("Adrd", "Bdsd", "Bdsr", "Adrd"),
    "dire_path": ("Bdrt", "Bdsd", "Bdsr", "Bdsd"),
    "dire_path_cracked": ("Bdrt", "Bdsd", "Bdsr", "Bflr"),
    "dire_riverbed_path": ("Bdrt", "Bdrr", "Bdrr", "Bdrt"),
}
BASE_TILES = ("Bdrt", "Bdsd")                     # the commander's flattened Dire base (buildable)
RAISED_TILES = {"radiant": ("Lrok", "Lgrd"), "dire": ("Adrd", "Bdsd")}     # tops of raised blocked ground
# Pathing cell values as the World Editor writes them (Blizzard maps).
LAND, WATER, BLOCKED, BOUNDARY = 0x40, 0x08, 0xCA, 0xCE
RIVER_BED = -0.1875                # layers: 24 units under the bed, water 40 deep (shallow < 51.2)
TREE_ID = "LTlt"
ROCK_ID = "LRrk"                   # Lordaeron Summer rocks (doodad, 10 variations, about 170 units wide)
# Raised blocked ground: the first ring of corners rises this many levels
# above the ground beside it, the corners further in RAISE_INNER.
RAISE_RING, RAISE_INNER = 1, 2
# No raised ground (KEEP_RAISE) or rocks (KEEP_ROCKS) this close to the
# entities the game puts units or structures at. The Dota fountains, their
# shops, the secret shops and the lotus pools stand on gridnav-blocked ground.
KEEP_RAISE = {"fountains": 500, "forts": 600, "barracks": 400, "towers": 300, "shops": 350, "camps": 250,
              "outposts": 300, "lotus_pools": 200, "twin_gates": 300, "tormentors": 300, "wisdom_shrines": 300,
              "roshan": 300, "runes": 250}
KEEP_ROCKS = dict(KEEP_RAISE, fountains=450, shops=250)

CAMP_KINDS = {0: "small", 1: "medium", 2: "large", 3: "ancient"}
LANES = ("top", "mid", "bot")


class ConvertError(Exception):
    pass


def ci(i, j):
    return j * N + i


def corner_xy(i, j):
    return ORIGIN + 128 * i, ORIGIN + 128 * j


def _hash(*values):
    """Deterministic 32-bit hash with good mixing (variations, tree scales)."""
    h = 0x9E3779B9
    for v in values:
        h ^= v & 0xFFFFFFFF
        h = (h * 0x85EBCA6B) & 0xFFFFFFFF
        h ^= h >> 13
        h = (h * 0xC2B2AE35) & 0xFFFFFFFF
        h ^= h >> 16
    return h


class Terrain:
    """The WC3 side: per-corner arrays, pathing cells, trees, mapdata."""

    def __init__(self):
        self.level = [0] * (N * N)         # Dota level; WC3 layer = LAYER0 + level
        self.height = [0.0] * (N * N)      # ground height in layers, on top of the layer
        self.ramp = bytearray(N * N)
        self.water = bytearray(N * N)
        self.water_z = [16.0] * (N * N)    # world z of the water surface
        self.tex = bytearray(N * N)
        self.var = bytearray(N * N)
        self.cliff_tex = bytearray(N * N)
        self.frozen = bytearray(N * N)     # set by ramps, pads and the commander base
        self.base = bytearray(N * N)       # commander base corners
        self.raised = bytearray(N * N)     # corners of blocked ground raised into cliffs
        self.ramp_tiles = set()            # (i, j) tiles walkable as ramp interiors
        self.romp_tiles = set()            # (i, j) ramp side pieces (unwalkable)
        self.ramps = []
        self.pathing = bytearray(CELLS * CELLS)
        self.trees = []                    # (x, y, z, variation, scale, tree type, facing in radians)
        self.tree_plan = {"types": {}, "kinds": []}    # trees.plan_trees
        self.rocks = []                    # (x, y, z, variation, scale, angle)
        self.decor = []                    # (x, y, z, variation, scale, doodad id, angle)
        self.mapdata = None
        self.notes = []

    # ------------------------------------------------------------ heights

    def corner_z(self, i, j):
        """Final ground z of a corner, with the half-layer lift WC3 gives the
        lower corners of a ramp entrance tile."""
        k = ci(i, j)
        z = (self.level[k] + self.height[k]) * 128
        if self.ramp[k] and self._lifted(i, j):
            z += 64
        return z

    def _lifted(self, i, j):
        k = ci(i, j)
        for ti in (i - 1, i):
            for tj in (j - 1, j):
                if 0 <= ti < TILES and 0 <= tj < TILES and self.is_ramp_entrance(ti, tj):
                    lv = [self.level[ci(a, b)] for a in (ti, ti + 1) for b in (tj, tj + 1)]
                    if self.level[k] == min(lv):
                        return True
        return False

    def tile_levels(self, i, j):
        return (self.level[ci(i, j)], self.level[ci(i + 1, j)], self.level[ci(i, j + 1)], self.level[ci(i + 1, j + 1)])

    def is_cliff(self, i, j):
        bl, br, tl, tr = self.tile_levels(i, j)
        return not (bl == br == tl == tr)

    def all_ramp(self, i, j):
        return all(self.ramp[ci(a, b)] for a in (i, i + 1) for b in (j, j + 1))

    def is_ramp_entrance(self, i, j):
        bl, br, tl, tr = self.tile_levels(i, j)
        return self.all_ramp(i, j) and not (bl == tr and tl == br)

    def tile_blocked(self, i, j):
        if (i, j) in self.romp_tiles:
            return True
        return self.is_cliff(i, j) and not self.all_ramp(i, j)

    def finalize_tiles(self):
        """Per-tile cliff and blocked flags, once levels and ramps are final."""
        self.cliff = bytearray(TILES * TILES)
        self.blocked = bytearray(TILES * TILES)
        for j in range(TILES):
            for i in range(TILES):
                c = self.is_cliff(i, j)
                self.cliff[j * TILES + i] = c
                self.blocked[j * TILES + i] = (i, j) in self.romp_tiles or (c and not self.all_ramp(i, j))

    def ground_z(self, x, y):
        """Terrain z at a world point (bilinear over the tile's corners)."""
        fx, fy = (x - ORIGIN) / 128.0, (y - ORIGIN) / 128.0
        i = max(0, min(TILES - 1, int(math.floor(fx))))
        j = max(0, min(TILES - 1, int(math.floor(fy))))
        u, v = fx - i, fy - j
        z00, z10 = self.corner_z(i, j), self.corner_z(i + 1, j)
        z01, z11 = self.corner_z(i, j + 1), self.corner_z(i + 1, j + 1)
        return (z00 * (1 - u) + z10 * u) * (1 - v) + (z01 * (1 - u) + z11 * u) * v


# ------------------------------------------------------------------ inputs

class Rasters:
    def __init__(self, desc):
        g = desc["grid"]
        if (g["origin"], g["cell"], g["size"]) != (ORIGIN, 32, CELLS):
            raise ConvertError(f"unexpected description grid {g}")
        self.height = source.unpack_z(desc["height"])
        self.water = source.unpack_z(desc["water"])
        self.walk = base64.b64decode(desc["walkable"])
        m = desc["material"]
        self.mat_names = m["names"]
        self.mat = base64.b64decode(m["data"])
        self.mat_size = m["size"]

    def cell_of(self, x, y):
        i, j = int(math.floor((x - ORIGIN) / 32)), int(math.floor((y - ORIGIN) / 32))
        if 0 <= i < CELLS and 0 <= j < CELLS:
            return j * CELLS + i
        return None


# ------------------------------------------------------------------ levels

def corner_votes(t, r):
    """Level of each corner from the 4 x 4 cells around it; walkable flat
    ground outvotes walls, props and slopes. Returns walkable-cell counts."""
    walk_count = bytearray(N * N)
    for j in range(N):
        for i in range(N):
            votes = {}
            wc = 0
            for b in range(4 * j - 2, 4 * j + 2):
                if not 0 <= b < CELLS:
                    continue
                for a in range(4 * i - 2, 4 * i + 2):
                    if not 0 <= a < CELLS:
                        continue
                    k = b * CELLS + a
                    z = r.height[k]
                    w = r.walk[k]
                    wc += w
                    if z is None:
                        continue
                    lv = int(math.floor(z / 128.0 + 0.5))
                    flat = abs(z - 128 * lv) <= 24
                    votes[lv] = votes.get(lv, 0) + (4 if w and flat else 2 if flat else 1)
            k = ci(i, j)
            walk_count[k] = wc
            if votes:
                best = max(votes.values())
                t.level[k] = min(lv for lv, v in votes.items() if v == best)
            else:
                t.level[k] = None
    # Corners without any surface take their neighbours' level.
    todo = [k for k in range(N * N) if t.level[k] is None]
    while todo:
        rest = []
        for k in todo:
            i, j = k % N, k // N
            known = [t.level[ci(a, b)] for a, b in ((i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1))
                     if 0 <= a < N and 0 <= b < N and t.level[ci(a, b)] is not None]
            if known:
                t.level[k] = min(known)
            else:
                rest.append(k)
        if len(rest) == len(todo):
            for k in rest:
                t.level[k] = 1
            break
        todo = rest
    return walk_count


def limit_blocked_levels(t, walk_count):
    """Unwalkable corners (Dota's outer forest, rocks, cliff bands) stay within
    one level of the nearest walkable ground, so the map edge is a single
    cliff, not a tower of them."""
    ref = [None] * (N * N)
    frontier = [k for k in range(N * N) if walk_count[k] >= 8]
    for k in frontier:
        ref[k] = t.level[k]
    while frontier:
        nxt = []
        for k in frontier:
            i, j = k % N, k // N
            for a, b in ((i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)):
                if 0 <= a < N and 0 <= b < N:
                    n = ci(a, b)
                    if ref[n] is None:
                        ref[n] = ref[k]
                        nxt.append(n)
        frontier = nxt
    for k in range(N * N):
        if walk_count[k] < 8 and not t.frozen[k] and ref[k] is not None:
            t.level[k] = max(ref[k] - 1, min(ref[k] + 1, t.level[k]))


def limit_steps(t, walk_count, max_step=2):
    """No tile may span more than max_step layers (WC3 has cliff models up to
    two levels). Unwalkable, unfrozen corners give way first."""
    for _ in range(64):
        changed = False
        for j in range(N):
            for i in range(N):
                k = ci(i, j)
                lv = t.level[k]
                for a in (i - 1, i, i + 1):
                    for b in (j - 1, j, j + 1):
                        if (a, b) == (i, j) or not (0 <= a < N and 0 <= b < N):
                            continue
                        n = ci(a, b)
                        if lv - t.level[n] > max_step:
                            # lower k or raise n, whichever is not walkable ground
                            if not t.frozen[k] and walk_count[k] <= walk_count[n]:
                                t.level[k] = lv = t.level[n] + max_step
                            elif not t.frozen[n]:
                                t.level[n] = lv - max_step
                            else:
                                t.level[k] = lv = t.level[n] + max_step
                            changed = True
        if not changed:
            return
    raise ConvertError("cliff levels did not settle")


# ------------------------------------------------------------------ ramps

# Ramp side models a corner grid may ask for: those of straight ramps (as the
# World Editor's ramp tool makes them) and the flat ones every Blizzard ladder
# map asks for, which have no model and are skipped by the game.
RAMP_SIDES = frozenset({"HLHBA", "HABHL", "HHLAB", "HBALH", "VBHLA", "VHBAL", "VALHB", "VLABH"})
FLAT_SIDES = frozenset({"HLLAA", "HAALL", "VALLA", "VLAAL"})


def transition_names(level, ramp, box=(0, 0, N - 1, N - 1)):
    """{name: count} of the ramp side models (V or H + 4 letters) the tiles
    in box (i0, j0, i1, j1 corners) ask for: a 1 x 2 or 2 x 1 tile window whose
    two long sides differ in ramp flags, whose middle line sits on the lower
    layer of its ends. Letters: A, B, C plain corners 0-2 layers above the
    window's base, L, H ramp corners on the base or one above."""
    def letter(c, base):
        k = c[1] * N + c[0]
        return chr((76 if ramp[k] else 65) + (level[k] - base) * (-4 if ramp[k] else 1))
    out = {}
    i0, j0, i1, j1 = box
    for i in range(max(0, i0), min(N - 1, i1)):
        for j in range(max(0, j0), min(N - 1, j1)):
            k = j * N + i
            if j < N - 2:
                bl, br, tl, tr, ttl, ttr = k, k + 1, k + N, k + N + 1, k + 2 * N, k + 2 * N + 1
                ae, cf = min(level[bl], level[ttl]), min(level[br], level[ttr])
                if (level[tl] == ae and level[tr] == cf and ramp[bl] == ramp[tl] == ramp[ttl]
                        and ramp[br] == ramp[tr] == ramp[ttr] and ramp[bl] != ramp[br]):
                    base = min(ae, cf)
                    name = "V" + "".join(letter(c, base) for c in ((i, j + 2), (i + 1, j + 2), (i + 1, j), (i, j)))
                    out[name] = out.get(name, 0) + 1
            if i < N - 2:
                bl, br, brr, tl, tr, trr = k, k + 1, k + 2, k + N, k + N + 1, k + N + 2
                ae, bf = min(level[bl], level[brr]), min(level[tl], level[trr])
                if (level[br] == ae and level[tr] == bf and ramp[bl] == ramp[br] == ramp[brr]
                        and ramp[tl] == ramp[tr] == ramp[trr] and ramp[bl] != ramp[tl]):
                    base = min(ae, bf)
                    name = "H" + "".join(letter(c, base) for c in ((i, j + 1), (i + 2, j + 1), (i + 2, j), (i, j)))
                    out[name] = out.get(name, 0) + 1
    return out


def _ramp_shape(rp, axis):
    """Placement parameters of a Dota ramp as a WC3 ramp along axis."""
    low, high = rp["low"], rp["high"]
    ang = math.radians(rp["grad"])
    up = (math.cos(ang) if axis == "x" else math.sin(ang)) > 0     # high side toward +axis
    cx, cy = rp["center"]
    along, across = (cx, cy) if axis == "x" else (cy, cx)
    bx0, by0, bx1, by1 = rp["bbox"]
    extent = (by1 - by0) if axis == "x" else (bx1 - bx0)
    width = max(2, min(6, int(round(min(extent, rp["width"]) / 128.0))))
    profile = [low, low, low, high, high] if up else [high, high, low, low, low]
    return up, along, across, width, profile


def _placements(claimed, along, across, width, axis):
    """(mid line, first and last across line) of each free placement, best
    first: full width in place, then shifted along the slope or across it,
    then narrower. Dota stacks ramps (river -> lane -> high ground) closer
    than two WC3 ramps fit, hence the shifts."""
    def corner(s, q):
        return (s, q) if axis == "x" else (q, s)
    m0 = int(round((along - ORIGIN) / 128.0))
    tries = sorted(((w, d, s) for w in range(width, 1, -1) for d in range(-3, 4) for s in range(-2, 3)),
                   key=lambda c: (c[0] < min(3, width), abs(c[1]), abs(c[2]), -c[0], c[1], c[2]))
    for w, d, shift in tries:
        m = m0 + d
        r0 = int(round((across - ORIGIN) / 128.0 - w / 2.0)) + shift
        r1 = r0 + w
        ring = [corner(s, q) for s in range(m - 2, m + 3) for q in range(r0 - 2, r1 + 3)]
        if all(1 <= c[0] < N - 1 and 1 <= c[1] < N - 1 for c in ring) and not any(claimed[ci(*c)] for c in ring):
            yield m, r0, r1


def place_ramps(t, desc, walk_count):
    """WC3 ramps at Dota's ramps (see the module docstring). A ramp claims its
    three ramp lines plus the flanking line on each side; claims never touch.
    A diagonal Dota ramp that does not fit on its nearer axis tries the other.
    A placement is kept only if the tiles around it ask for no ramp side model
    outside RAMP_SIDES and FLAT_SIDES."""
    claimed = bytearray(N * N)
    allowed = RAMP_SIDES | FLAT_SIDES
    for rp in desc["ramps"]:
        low, high = rp["low"], rp["high"]
        if high - low != 1:
            t.notes.append(f"ramp at {rp['center']} spans levels {low}-{high}: left as a cliff")
            continue
        ang = math.radians(rp["grad"])
        ca, sa = abs(math.cos(ang)), abs(math.sin(ang))
        axes = ["x", "y"] if ca >= sa else ["y", "x"]
        if min(ca, sa) < 0.5:
            axes = axes[:1]                            # clearly along one axis
        placed = inside_base = False
        for axis in axes:
            up, along, across, width, profile = _ramp_shape(rp, axis)

            def corner(s, q, axis=axis):               # along s, across q -> (i, j)
                return (s, q) if axis == "x" else (q, s)

            for m, r0, r1 in _placements(claimed, along, across, width, axis):
                cells = [(s, q) for s in range(m - 1, m + 2) for q in range(r0 - 1, r1 + 2)]
                if low >= 2 and any(t.base[ci(*corner(s, q))] for s, q in cells):
                    inside_base = True                 # inside the flattened commander base
                    break
                approach = [(s, q) for s in (m - 2, m + 2) for q in range(r0 - 1, r1 + 2)
                            if not claimed[ci(*corner(s, q))]]
                saved = [(k, t.level[k], t.height[k], t.frozen[k], t.ramp[k])
                         for k in (ci(*corner(s, q)) for s, q in cells + approach)]
                for s, q in cells + approach:
                    k = ci(*corner(s, q))
                    t.level[k] = profile[s - (m - 2)]
                    t.height[k] = 0.0
                    t.frozen[k] = 1
                    t.ramp[k] = 1 if m - 1 <= s <= m + 1 and r0 <= q <= r1 else 0
                a, b = corner(m - 4, r0 - 4), corner(m + 4, r1 + 4)
                box = (min(a[0], b[0]), min(a[1], b[1]), max(a[0], b[0]), max(a[1], b[1]))
                if set(transition_names(t.level, t.ramp, box)) - allowed:
                    for k, lv, h, fr, rf in saved:
                        t.level[k], t.height[k], t.frozen[k], t.ramp[k] = lv, h, fr, rf
                    continue
                for s, q in cells:
                    claimed[ci(*corner(s, q))] = 1
                for s in (m - 1, m):
                    for q in range(r0, r1):
                        t.ramp_tiles.add(corner(s, q))
                    for q in (r0 - 1, r1):
                        t.romp_tiles.add(corner(s, q))
                t.ramps.append({"center": rp["center"], "axis": axis, "up": "+" if up else "-",
                                "levels": [low, high], "mid": m, "across": [r0, r1]})
                placed = True
                break
            if placed or inside_base:
                break
        if not placed and not inside_base:
            t.notes.append(f"ramp at {rp['center']} does not fit between other ramps: left as a cliff")


# ------------------------------------------------------------------ commander base and pads

def commander_base(t, desc, walk_count):
    """Corners of the Dire high ground (levels 2 and 3, mostly walkable)
    connected to the Dire Ancient, plus one ring into unwalkable corners of the
    same levels (props), flattened to level 2."""
    fort = desc["entities"]["forts"].get("bad")
    if not fort:
        raise ConvertError("no Dire Ancient in the entity lump")
    start = ci(int(round((fort[0] - ORIGIN) / 128)), int(round((fort[1] - ORIGIN) / 128)))
    region = {start}
    stack = [start]
    while stack:
        k = stack.pop()
        i, j = k % N, k // N
        for a, b in ((i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)):
            if not (0 <= a < N and 0 <= b < N):
                continue
            n = ci(a, b)
            x, y = corner_xy(a, b)
            if n in region or x < 1500 or y < 1500:
                continue
            if t.level[n] in (2, 3) and walk_count[n] >= 8:
                region.add(n)
                stack.append(n)
    ring = set()
    for k in region:
        i, j = k % N, k // N
        for a in (i - 1, i, i + 1):
            for b in (j - 1, j, j + 1):
                n = ci(a, b)
                if n not in region and t.level[n] in (2, 3) and walk_count[n] < 8:
                    ring.add(n)
    region |= ring
    for k in region:
        t.level[k] = 2
        t.height[k] = 0.0
        t.base[k] = 1
    return region


def fountain_pad(t, pos, walk_count, radius):
    """The Radiant fountain stands in Dota's blocked corner: give the unwalkable
    ground around it the fountain platform's level, so the fountain and the
    shops on their arc stand on flat ground."""
    i0, j0 = int(round((pos[0] - ORIGIN) / 128)), int(round((pos[1] - ORIGIN) / 128))
    platform = None
    for rad in range(1, 8):
        lv = [t.level[ci(a, b)] for a in range(i0 - rad, i0 + rad + 1) for b in range(j0 - rad, j0 + rad + 1)
              if walk_count[ci(a, b)] >= 12]
        if lv:
            platform = max(lv)
            break
    if platform is None:
        return
    r = int(radius / 128) + 1
    for a in range(i0 - r, i0 + r + 1):
        for b in range(j0 - r, j0 + r + 1):
            x, y = corner_xy(a, b)
            k = ci(a, b)
            if (math.hypot(x - pos[0], y - pos[1]) <= radius and walk_count[k] < 4 and t.level[k] > platform
                    and not t.frozen[k]):
                t.level[k] = platform
                t.height[k] = 0.0


# ------------------------------------------------------------------ blocked ground

def keep_points(desc, radii):
    """(x, y, radius) around every entity of the kinds in radii (KEEP_RAISE,
    KEEP_ROCKS). Dire structures, the Dire fountain and its shop are left
    out: the commander's base replaces them."""
    e = desc["entities"]
    out = []

    def add(kind, p):
        if p and radii.get(kind):
            out.append((p[0], p[1], radii[kind]))
    for towers in e["towers"].get("good", {}).values():
        for tw in towers:
            add("towers", tw["pos"])
    for rax in e["barracks"].get("good", {}).values():
        for p in rax.values():
            add("barracks", p)
    for kind in ("forts", "fountains"):
        add(kind, e[kind].get("good"))
    for s in e["shops"]:
        if s["type"] != 0 or s["pos"][0] + s["pos"][1] < 0:
            add("shops", s["pos"])
    for c in e["camps"]:
        add("camps", c["pos"])
    for kind in ("outposts", "lotus_pools", "twin_gates", "tormentors", "wisdom_shrines", "roshan"):
        for p in e.get(kind, []):
            add(kind, p)
    for p in e["runes"]["power"] + e["runes"]["bounty"]:
        add("runes", p)
    return out


def _disc_mask(points, size, step, origin=ORIGIN, centred=False):
    """bytearray(size * size) of the grid points (corners, or cell centres
    with centred) within any (x, y, radius) of points."""
    mask = bytearray(size * size)
    off = step / 2.0 if centred else 0.0
    for x, y, rad in points:
        i0, i1 = int((x - rad - origin) // step) - 1, int((x + rad - origin) // step) + 2
        j0, j1 = int((y - rad - origin) // step) - 1, int((y + rad - origin) // step) + 2
        for j in range(max(0, j0), min(size, j1)):
            py = origin + step * j + off - y
            for i in range(max(0, i0), min(size, i1)):
                px = origin + step * i + off - x
                if px * px + py * py <= rad * rad:
                    mask[j * size + i] = 1
    return mask


NEIGHBOURS = [(a, b) for a in (-1, 0, 1) for b in (-1, 0, 1) if a or b]      # the 8 neighbours


def raise_blocked(t, r, desc, walk_count):
    """Dota's unwalkable areas become WC3 cliffs where a cliff fits: a corner
    rises when the four tiles around it are wholly unwalkable in Dota, so every
    cliff tile it makes covers blocked cells only and the pathing does not
    change. Ramps (and two corners around them), the commander base and the
    ground by structures (KEEP_RAISE) stay as they are. The first ring of
    raised corners stands RAISE_RING levels above the highest ground beside
    it, the corners further in RAISE_INNER (limit_steps settles the rest).
    Returns the number of raised corners."""
    walk = r.walk
    full = bytearray(TILES * TILES)
    for tj in range(TILES):
        for ti in range(TILES):
            k0 = 4 * tj * CELLS + 4 * ti
            full[tj * TILES + ti] = not any(walk[k0 + b * CELLS + a] for b in range(4) for a in range(4))
    busy = bytearray(N * N)
    for k in range(N * N):
        if t.ramp[k] or t.frozen[k]:
            i, j = k % N, k // N
            for b in range(max(0, j - 2), min(N, j + 3)):
                for a in range(max(0, i - 2), min(N, i + 3)):
                    busy[b * N + a] = 1
    keep = _disc_mask(keep_points(desc, KEEP_RAISE), N, 128)
    up = bytearray(N * N)
    for j in range(N):
        for i in range(N):
            k = j * N + i
            if busy[k] or keep[k] or t.base[k]:
                continue
            if all(full[b * TILES + a] for a in (i - 1, i) for b in (j - 1, j) if 0 <= a < TILES and 0 <= b < TILES):
                up[k] = 1
    # The level of the walkable ground nearest to each corner (corners mostly
    # on walkable cells, ramps and the commander base are ground): the blocked
    # corners beside raised ground may sit a level above it (corner_votes).
    steps = NEIGHBOURS
    gref = [None] * (N * N)
    front = [k for k in range(N * N) if walk_count[k] >= 8 or t.base[k] or t.frozen[k]]
    for k in front:
        gref[k] = t.level[k]
    while front:
        nxt = {}
        for k in front:
            i, j = k % N, k // N
            for a, b in steps:
                if 0 <= i + a < N and 0 <= j + b < N:
                    n = (j + b) * N + i + a
                    if gref[n] is None:
                        nxt[n] = max(nxt.get(n, gref[k]), gref[k])
        for n, lv in nxt.items():
            gref[n] = lv
        front = sorted(nxt)
    # Distance (8-neighbour rings) from the ground, and the highest ground level
    # beside each ring, carried inward.
    dist = [0] * (N * N)
    ref = [0] * (N * N)
    front = []
    for k in range(N * N):
        if not up[k]:
            continue
        i, j = k % N, k // N
        beside = [gref[(j + b) * N + i + a] for a, b in steps
                  if 0 <= i + a < N and 0 <= j + b < N and not up[(j + b) * N + i + a]]
        beside = [lv for lv in beside if lv is not None]
        if beside:
            dist[k], ref[k] = 1, max(beside)
            front.append(k)
    d = 1
    while front:
        nxt = {}
        for k in front:
            i, j = k % N, k // N
            for a, b in steps:
                if 0 <= i + a < N and 0 <= j + b < N:
                    n = (j + b) * N + i + a
                    if up[n] and not dist[n]:
                        nxt[n] = max(nxt.get(n, ref[k]), ref[k])
        d += 1
        for n, lv in nxt.items():
            dist[n], ref[n] = d, lv
        front = sorted(nxt)
    count = 0
    for k in range(N * N):
        if up[k] and dist[k]:
            lv = ref[k] + (RAISE_RING if dist[k] == 1 else RAISE_INNER)
            t.level[k] = lv
            t.height[k] = 0.0
            t.raised[k] = 1
            count += 1
    return count


def roughen_raised(t):
    """Uneven tops on raised ground: small height offsets on raised corners
    whose eight neighbours share their level (never next to a cliff, where
    an offset would tear the cliff model from the ground)."""
    for j in range(1, N - 1):
        for i in range(1, N - 1):
            k = ci(i, j)
            if not t.raised[k]:
                continue
            lv = t.level[k]
            if any(t.level[ci(i + a, j + b)] != lv or not t.raised[ci(i + a, j + b)] for a, b in NEIGHBOURS):
                continue
            t.height[k] = (_hash(i, j, 29) % 9) / 16.0          # 0 .. 0.5 layers


# Decorative trees on raised ground: Dota's border is forest on cliffs. They
# are doodads (no pathing, vision blocking or targeting) whose models are the
# Dota tree models (trees.DECOR maps each doodad type to a tree type).
DECOR_SPACING = 176                # units between grid points (jittered)
DECOR_MIN_CORNERS = 40             # raised areas smaller than this stay bare (rock formations)


def place_decor(t, kinds):
    """Decorative trees on the tops of raised blocked ground (all four tile
    corners raised) of large raised areas, inside the playable area plus a
    margin: a jittered grid, the Radiant's trees on the Radiant half, the
    Dire's on the Dire half. kinds: {"radiant"|"dire": (doodad id,
    variations)}; a side without a kind gets none."""
    size = [0] * (N * N)
    seen = bytearray(N * N)
    for s in range(N * N):
        if not t.raised[s] or seen[s]:
            continue
        stack, comp = [s], []
        seen[s] = 1
        while stack:
            k = stack.pop()
            comp.append(k)
            i, j = k % N, k // N
            for a, b in NEIGHBOURS:
                if 0 <= i + a < N and 0 <= j + b < N:
                    n = (j + b) * N + i + a
                    if t.raised[n] and not seen[n]:
                        seen[n] = 1
                        stack.append(n)
        for k in comp:
            size[k] = len(comp)
    out = []
    reach = PLAY + 384
    n = int(reach // DECOR_SPACING)
    for gj in range(-n, n + 1):
        for gi in range(-n, n + 1):
            h = _hash(gi, gj, 53)
            x = gi * DECOR_SPACING + (h % 121) - 60
            y = gj * DECOR_SPACING + ((h >> 8) % 121) - 60
            if abs(x) > reach or abs(y) > reach:
                continue
            ti, tj = int((x - ORIGIN) // 128), int((y - ORIGIN) // 128)
            if t.cliff[tj * TILES + ti]:
                continue                               # a step inside the raised ground
            corners = [ci(ti + a, tj + b) for a in (0, 1) for b in (0, 1)]
            if not all(t.raised[c] and size[c] >= DECOR_MIN_CORNERS for c in corners):
                continue
            kind = kinds.get("radiant" if x + y < 0 else "dire")
            if not kind:
                continue
            doodad, variations = kind
            out.append((x, y, round(t.ground_z(x, y), 3), (h >> 16) % variations,
                        round(0.85 + (h >> 20) % 31 / 100.0, 2), doodad, round((h >> 4) % 628 / 100.0, 2)))
    t.decor = out
    return len(out)


# Rocks: a rock may reach this far over open ground (units have a collision
# radius of 16 to 32, so they never seem to walk into it).
ROCK_OVERHANG = 24
ROCK_RADIUS = 85.0                 # LRrk half width at scale 1


def place_rocks(t, r, desc):
    """Rocks on the blocked ground that stayed level with the walkable ground
    around it (strips narrower than a cliff, small obstacles): cells blocked
    in Dota and in the WC3 pathing (the commander base is open), not under a
    cliff tile, raised ground or a tree, and away from structures
    (KEEP_ROCKS). Deepest cells first (distance to open ground); a rock's
    size follows that distance, so it barely reaches over walkable ground.
    Pathing is not touched: doodads are visual, the pathing map is Dota's."""
    p = t.pathing
    keep = _disc_mask(keep_points(desc, KEEP_ROCKS), CELLS, 32, centred=True)
    covered = bytearray(CELLS * CELLS)
    for x, y, *_rest in t.trees:
        i0, j0 = int((x - 64 - ORIGIN) // 32), int((y - 64 - ORIGIN) // 32)
        for b in range(max(0, j0), min(CELLS, j0 + 4)):
            for a in range(max(0, i0), min(CELLS, i0 + 4)):
                covered[b * CELLS + a] = 1
    left = bytearray(CELLS * CELLS)
    for pj in range(CELLS):
        tj = pj // 4
        for pi in range(CELLS):
            k = pj * CELLS + pi
            if p[k] != BLOCKED or r.walk[k] or covered[k] or keep[k]:
                continue
            ti = pi // 4
            if t.blocked[tj * TILES + ti]:
                continue
            corners = [ci(ti + a, tj + b) for a in (0, 1) for b in (0, 1)]
            if all(t.raised[c] for c in corners):
                continue
            left[k] = 1
    # Distance (8-neighbour rings) to the nearest open cell.
    INF = 1 << 20
    dist = [INF] * (CELLS * CELLS)
    front = [k for k in range(CELLS * CELLS) if p[k] in (LAND, WATER)]
    for k in front:
        dist[k] = 0
    steps = NEIGHBOURS
    d = 0
    while front:
        d += 1
        nxt = []
        for k in front:
            a, b = k % CELLS, k // CELLS
            for da, db in steps:
                if 0 <= a + da < CELLS and 0 <= b + db < CELLS:
                    n = (b + db) * CELLS + a + da
                    if dist[n] == INF:
                        dist[n] = d
                        nxt.append(n)
        front = nxt
        if d > 8:
            break
    cands = sorted((k for k in range(CELLS * CELLS) if left[k]),
                   key=lambda k: (-min(dist[k], 8), _hash(k, 41)))
    rocks = []
    grid = {}
    for k in cands:
        a, b = k % CELLS, k // CELLS
        x, y = ORIGIN + 32 * a + 16, ORIGIN + 32 * b + 16
        rad = min(1.2 * ROCK_RADIUS, (min(dist[k], 8) - 0.5) * 32 + ROCK_OVERHANG)
        g = (a // 8, b // 8)
        clash = False
        for ga in (g[0] - 1, g[0], g[0] + 1):
            for gb in (g[1] - 1, g[1], g[1] + 1):
                for qx, qy, qr in grid.get((ga, gb), ()):
                    if (x - qx) ** 2 + (y - qy) ** 2 < (0.8 * (rad + qr)) ** 2:
                        clash = True
                        break
                if clash:
                    break
            if clash:
                break
        if clash:
            continue
        grid.setdefault(g, []).append((x, y, rad))
        h = _hash(a, b, 43)
        scale = round(rad / ROCK_RADIUS, 2)
        rocks.append((x, y, round(t.ground_z(x, y), 3), h % 10, scale, round((h >> 8) % 628 / 100.0, 2)))
    t.rocks = sorted(rocks, key=lambda q: (q[1], q[0]))
    return sum(left)


# ------------------------------------------------------------------ water and heights

def water_and_heights(t, r, walk_count):
    has = [False] * (N * N)
    wz = [None] * (N * N)
    for j in range(N):
        for i in range(N):
            best = None
            for b in range(4 * j - 2, 4 * j + 2):
                if not 0 <= b < CELLS:
                    continue
                for a in range(4 * i - 2, 4 * i + 2):
                    if 0 <= a < CELLS:
                        z = r.water[b * CELLS + a]
                        if z is not None and (best is None or z > best):
                            best = z
            k = ci(i, j)
            if best is not None:
                has[k] = True
                wz[k] = float(best)
    # every corner gets the nearest water surface (tiles interpolate it)
    frontier = [k for k in range(N * N) if wz[k] is not None]
    while frontier:
        nxt = []
        for k in frontier:
            i, j = k % N, k // N
            for a, b in ((i - 1, j), (i + 1, j), (i, j - 1), (i, j + 1)):
                if 0 <= a < N and 0 <= b < N and wz[ci(a, b)] is None:
                    wz[ci(a, b)] = wz[k]
                    nxt.append(ci(a, b))
        frontier = nxt
    for k in range(N * N):
        t.water_z[k] = wz[k] if wz[k] is not None else 16.0
        if has[k] and not t.base[k]:
            t.water[k] = 1
            if t.level[k] * 128 <= t.water_z[k] and not t.frozen[k]:
                t.height[k] = RIVER_BED
    # Gentle bumps of fully walkable ground (lanes and jungle are not dead flat).
    for j in range(1, N - 1):
        for i in range(1, N - 1):
            k = ci(i, j)
            if t.frozen[k] or t.base[k] or t.water[k] or walk_count[k] < 16:
                continue
            zs = [r.height[b * CELLS + a] for b in range(4 * j - 2, 4 * j + 2) for a in range(4 * i - 2, 4 * i + 2)]
            zs = sorted(z for z in zs if z is not None)
            if len(zs) < 12:
                continue
            dz = zs[len(zs) // 2] - 128 * t.level[k]
            # never lean on a neighbouring cliff: bumps only away from level changes
            if any(t.level[ci(a, b)] != t.level[k] for a in (i - 1, i, i + 1) for b in (j - 1, j, j + 1)):
                continue
            t.height[k] = max(-0.25, min(0.375, round(dz / 128.0 * 16) / 16))


# ------------------------------------------------------------------ textures

def textures(t, r, desc):
    names = r.mat_names
    size = r.mat_size
    for j in range(N):
        for i in range(N):
            k = ci(i, j)
            x, y = corner_xy(i, j)
            counts = {}
            for a in (i - 1, i):
                for b in (j - 1, j):
                    if 0 <= a < size and 0 <= b < size:
                        m = r.mat[b * size + a]
                        if m != 255:
                            counts[names[m]] = counts.get(names[m], 0) + 1
            h = _hash(i, j, 7)
            if t.base[k]:
                pair = BASE_TILES
            elif t.raised[k]:
                pair = RAISED_TILES["radiant" if x + y < 0 else "dire"]
            elif counts:
                best = max(counts.values())
                name = min(n for n, c in counts.items() if c == best)
                material, _, layer = name.rpartition(":")
                tiles = LAYER_TILES.get(material)
                tile = tiles[int(layer)] if tiles and layer.isdigit() and int(layer) < 4 else (
                    "Lgrs" if x + y < 0 else "Bdsd")
                pair = (tile, tile)
            elif x + y < 0 and t.level[k] >= 2:
                pair = ("Yrtl", "Lrok") if t.level[k] == 2 else ("Lrok", "Lrok")
            else:
                pair = ("Lrok", "Ldrg") if x + y < 0 else ("Bdrr", "Bdsd")
            t.tex[k] = T[pair[0] if h % 4 else pair[1]]
            g = (h >> 8) % 100
            t.var[k] = (h >> 12) % 4 if g < 80 else 4 + (h >> 12) % 12
            t.cliff_tex[k] = 1 if x + y < 0 else 0


def buildable_ground(t, spots, radius):
    """Corners within radius of the spots (the commander's mines and
    expansions) on a tile WC3 builds on: unbuildable tiles there (rock,
    river stones, flagstones) become the base's ground."""
    for x0, y0 in spots:
        i0, j0 = int(round((x0 - ORIGIN) / 128)), int(round((y0 - ORIGIN) / 128))
        r = int(radius // 128) + 1
        for j in range(max(0, j0 - r), min(N, j0 + r + 1)):
            for i in range(max(0, i0 - r), min(N, i0 + r + 1)):
                x, y = corner_xy(i, j)
                k = ci(i, j)
                if (x - x0) ** 2 + (y - y0) ** 2 <= radius * radius and TILE_IDS[t.tex[k]] in UNBUILDABLE:
                    t.tex[k] = T[BASE_TILES[_hash(i, j, 7) % 2]]


# ------------------------------------------------------------------ pathing

def pathing(t, r, base_tiles):
    p = t.pathing
    blocked = t.blocked
    for pj in range(CELLS):
        y = ORIGIN + (pj + 0.5) * 32
        tj = pj // 4
        for pi in range(CELLS):
            x = ORIGIN + (pi + 0.5) * 32
            k = pj * CELLS + pi
            if abs(x) > PLAY or abs(y) > PLAY:
                p[k] = BOUNDARY
                continue
            ti = pi // 4
            if blocked[tj * TILES + ti]:
                p[k] = BLOCKED
                continue
            open_ = r.walk[k] == 1 or (ti, tj) in t.ramp_tiles or (ti, tj) in base_tiles
            if not open_:
                p[k] = BLOCKED
                continue
            c = ci(int(round(pi / 4.0)), int(round(pj / 4.0)))
            under = t.water[c] and t.water_z[c] > (t.level[c] + t.height[c]) * 128
            p[k] = WATER if under else LAND


def walkable_share(t, r):
    """Share of Dota's walkable cells inside the playable area that are
    open (land or shallow water) in the WC3 pathing."""
    total = opened = 0
    for pj in range(CELLS):
        y = ORIGIN + (pj + 0.5) * 32
        if abs(y) > PLAY:
            continue
        for pi in range(CELLS):
            k = pj * CELLS + pi
            if r.walk[k] and abs(ORIGIN + (pi + 0.5) * 32) <= PLAY:
                total += 1
                opened += t.pathing[k] in (LAND, WATER)
    return opened / max(1, total)


def check_reachable(t):
    """Everything the game script walks to must be reachable on foot from the
    Radiant fountain: lanes, structures and the commander's base, or the
    conversion fails (and the launcher keeps the base layout). Camps, runes
    and the expansions only get a note."""
    md = t.mapdata
    f = md["dota"]["fountain"]
    seen = reachable(t, (f["x"] + 350, f["y"] + 350))
    must = [(f"lane {lane} point {i}", p) for lane, ps in md["lanes"].items() for i, p in enumerate(ps)]
    must += [(f"tower {lane} {i + 1}", p) for lane, ps in md["dota"]["towers"].items() for i, p in enumerate(ps)]
    must += [(f"barracks {lane}", p) for lane, ps in md["dota"]["barracks"].items() for p in ps]
    must += [("ancient", md["dota"]["ancient"]), ("commander start", md["commander"]["start"])]
    must += [("gold mine", p) for p in md["commander"]["mines"]]
    nice = [(f"camp {n}", p) for n, p in md["camps"].items()] + [("roshan", md["roshan"])]
    nice += [("rune", p) for p in md["runes"] + md.get("bounty_runes", [])]
    nice += [("expansion", p) for p in md["commander"]["expansions"]]
    bad = [n for n, p in must if not near_reachable(seen, p["x"], p["y"], 192)]
    if bad:
        raise ConvertError(f"not reachable from the fountain: {', '.join(bad[:6])}")
    for n, p in nice:
        if not near_reachable(seen, p["x"], p["y"], 192):
            t.notes.append(f"{n} at {p['x']}, {p['y']} is not reachable from the fountain")
    return sum(seen)


def reachable(t, start):
    """Pathing cells reachable on foot from start (4-neighbour flood)."""
    seen = bytearray(CELLS * CELLS)
    i, j = int((start[0] - ORIGIN) // 32), int((start[1] - ORIGIN) // 32)
    best = None
    for rad in range(0, 12):
        for a in range(i - rad, i + rad + 1):
            for b in range(j - rad, j + rad + 1):
                if 0 <= a < CELLS and 0 <= b < CELLS and t.pathing[b * CELLS + a] in (LAND, WATER):
                    best = b * CELLS + a
                    break
            if best is not None:
                break
        if best is not None:
            break
    if best is None:
        return seen
    stack = [best]
    seen[best] = 1
    p = t.pathing
    while stack:
        k = stack.pop()
        a, b = k % CELLS, k // CELLS
        for n in (k - 1 if a > 0 else -1, k + 1 if a < CELLS - 1 else -1,
                  k - CELLS if b > 0 else -1, k + CELLS if b < CELLS - 1 else -1):
            if n >= 0 and not seen[n] and p[n] in (LAND, WATER):
                seen[n] = 1
                stack.append(n)
    return seen


def near_reachable(seen, x, y, radius=160):
    i0, j0 = int((x - ORIGIN) // 32), int((y - ORIGIN) // 32)
    r = int(radius // 32)
    for a in range(i0 - r, i0 + r + 1):
        for b in range(j0 - r, j0 + r + 1):
            if 0 <= a < CELLS and 0 <= b < CELLS and seen[b * CELLS + a]:
                return True
    return False


# ------------------------------------------------------------------ gameplay data

def _pt(p):
    return {"x": int(round(p[0])), "y": int(round(p[1]))}


def _project(path, p):
    """Arc length along path of the point nearest p."""
    best, best_s, s = None, 0.0, 0.0
    for a, b in zip(path, path[1:]):
        dx, dy = b[0] - a[0], b[1] - a[1]
        ln = math.hypot(dx, dy)
        u = 0.0 if ln == 0 else max(0.0, min(1.0, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / (ln * ln)))
        d = math.hypot(a[0] + u * dx - p[0], a[1] + u * dy - p[1])
        if best is None or d < best:
            best, best_s = d, s + u * ln
        s += ln
    return best_s


def lane_path(chain, start, end):
    """Dota's Radiant lane from its spawner to the Dire spawner: the path
    corners strictly between the two, with the spawners as the ends."""
    pts = [c[:2] for c in chain]
    lens = [0.0]
    for a, b in zip(pts, pts[1:]):
        lens.append(lens[-1] + math.hypot(b[0] - a[0], b[1] - a[1]))
    s0, s1 = _project(pts, start), _project(pts, end)
    inner = [p for p, s in zip(pts, lens) if s0 + 150 < s < s1 - 150]
    return [start[:2]] + inner + [end[:2]]


def _open_disc(t, pos, radius):
    """True when every pathing cell within radius of pos is open ground."""
    i0, j0 = int((pos[0] - ORIGIN) // 32), int((pos[1] - ORIGIN) // 32)
    r = radius // 32
    for b in range(-r, r + 1):
        for a in range(-r, r + 1):
            if a * a + b * b <= r * r:
                i, j = i0 + a, j0 + b
                if not (0 <= i < CELLS and 0 <= j < CELLS) or t.pathing[j * CELLS + i] not in (LAND, WATER):
                    return False
    return True


def _nearest_open(t, pos, radius=320):
    """pos, or the nearest pathing cell centre within radius that is open."""
    if _open_disc(t, pos, 0):
        return pos[:2]
    i0, j0 = int((pos[0] - ORIGIN) // 32), int((pos[1] - ORIGIN) // 32)
    centre = (ORIGIN + 32 * i0 + 16, ORIGIN + 32 * j0 + 16)
    return next((p for p in _spiral(centre, 32, radius) if _open_disc(t, p, 0)), pos[:2])


def _spiral(pos, step, radius):
    """Grid points around pos, nearest first (ties in a fixed order)."""
    n = radius // step
    pts = [(pos[0] + step * a, pos[1] + step * b) for b in range(-n, n + 1) for a in range(-n, n + 1)
           if 0 < a * a + b * b <= n * n]
    return sorted(pts, key=lambda p: ((p[0] - pos[0]) ** 2 + (p[1] - pos[1]) ** 2, p[1], p[0]))


def open_spot(t, anchor, avoid, radius=448, search=1792, side=None):
    """The spot nearest anchor (on a 64-unit grid) whose disc of `radius` is
    dry, walkable, flat land without ramps, and that keeps the distances in
    `avoid` [(x, y, distance)]. Trees there are cleared afterwards."""
    rr = radius // 32
    disc = [(a, b) for b in range(-rr, rr + 1) for a in range(-rr, rr + 1) if a * a + b * b <= rr * rr]
    ax, ay = anchor
    steps = search // 64
    order = sorted(((di, dj) for dj in range(-steps, steps + 1) for di in range(-steps, steps + 1)),
                   key=lambda d: (d[0] * d[0] + d[1] * d[1], d[1], d[0]))
    for di, dj in order:
        x, y = 64 * round(ax / 64) + 64 * di, 64 * round(ay / 64) + 64 * dj
        if side and not side(x, y):
            continue
        if any(math.hypot(x - qx, y - qy) < d for qx, qy, d in avoid):
            continue
        i0, j0 = int((x - ORIGIN) // 32), int((y - ORIGIN) // 32)
        if not (rr <= i0 < CELLS - rr and rr <= j0 < CELLS - rr):
            continue
        ok = True
        for a, b in disc:
            i, j = i0 + a, j0 + b
            if t.pathing[j * CELLS + i] != LAND or (i // 4, j // 4) in t.ramp_tiles:
                ok = False
                break
        if ok:
            return (x, y)
    return None


def gameplay(t, r, desc, base_region):
    e = desc["entities"]
    good_towers, good_rax = e["towers"]["good"], e["barracks"]["good"]
    missing = [lane for lane in LANES if len(good_towers.get(lane, [])) != 3 or set(good_rax.get(lane, {})) != {"melee", "range"}]
    if missing or len(good_towers.get("base", [])) != 2:
        raise ConvertError(f"Radiant towers or barracks incomplete: lanes {missing}")
    for side in ("good", "bad"):
        for lane in LANES:
            if lane not in e["spawners"][side] or lane not in e["lanes"]["good"]:
                raise ConvertError(f"lane {lane}: spawner or path corners missing")
    fountain = e["fountains"]["good"]
    home = [s["pos"] for s in e["shops"] if s["type"] == 0]
    shop = min(home, key=lambda p: math.hypot(p[0] - fountain[0], p[1] - fountain[1])) if home else fountain
    # Waypoints (and the spawners at both ends) on open ground: a Dota path
    # corner may sit on a cell WC3 blocks (a cliff tile, a rock in the river).
    lanes = {lane: [_pt(_nearest_open(t, p)) for p in lane_path(e["lanes"]["good"][lane], e["spawners"]["good"][lane],
                                                                e["spawners"]["bad"][lane])] for lane in LANES}
    fort = e["forts"]["bad"]
    start = (32 * round(fort[0] / 32), 32 * round(fort[1] / 32))
    dire_fountain = e["fountains"].get("bad", (fort[0] + 1500, fort[1] + 1500))
    dx, dy = dire_fountain[0] - start[0], dire_fountain[1] - start[1]
    ln = math.hypot(dx, dy) or 1.0
    mine = (32 * round((start[0] + 704 * dx / ln) / 32), 32 * round((start[1] + 704 * dy / ln) / 32))
    camps = {}
    counters = {}
    for c in sorted(e["camps"], key=lambda c: (c["side"], c["type"], c["pos"][1], c["pos"][0])):
        prefix = "d" if c["side"] == "good" else "c"
        kind = CAMP_KINDS.get(c["type"], "medium")
        counters[(prefix, kind)] = counters.get((prefix, kind), 0) + 1
        name = f"{prefix}_{kind}{counters[(prefix, kind)]}"
        # Creeps spawn on a 140-unit circle and walk home to their spawn point:
        # WC3's cliffs take more room than Dota's, so a camp by a cliff moves
        # to the nearest spot whose whole spawn circle is open ground.
        pos = c["pos"][:2]
        if not _open_disc(t, pos, 192):
            spot = next((p for p in _spiral(pos, 64, 448) if _open_disc(t, p, 192)), None)
            if spot:
                t.notes.append(f"camp {name} moved {math.hypot(spot[0] - pos[0], spot[1] - pos[1]):.0f} units "
                               "away from blocked ground")
                pos = spot
            else:
                t.notes.append(f"camp {name} at {pos} has blocked ground in its spawn circle")
        camps[name] = _pt(pos)
    # expansions: open ground by the Dire's top and bottom tier-2 towers,
    # off the lanes and away from camps, runes, Roshan and the outposts
    avoid = [(p["x"], p["y"], 900) for p in camps.values()]
    avoid += [(p[0], p[1], 900) for p in e["runes"]["power"] + e["runes"]["bounty"] + e["roshan"] + e["outposts"]]
    for lane in lanes.values():
        for a, b in zip(lane, lane[1:]):
            n = max(1, int(math.hypot(b["x"] - a["x"], b["y"] - a["y"]) // 200))
            avoid += [(a["x"] + (b["x"] - a["x"]) * s / n, a["y"] + (b["y"] - a["y"]) * s / n, 640) for s in range(n + 1)]
    avoid.append((start[0], start[1], 2600))
    expansions = []
    bad_towers = e["towers"]["bad"]
    for lane in ("top", "bot"):
        anchor = next((tw["pos"] for tw in bad_towers.get(lane, []) if tw["tier"] == 2), None)
        if anchor is None:
            continue
        spot = open_spot(t, anchor[:2], avoid, side=lambda x, y: x + y > 1500)
        if spot:
            expansions.append(spot)
            avoid.append((spot[0], spot[1], 2000))
        else:
            t.notes.append(f"no open ground for an expansion near the Dire {lane} tier-2 tower")
    roshan = e["roshan"][0] if e["roshan"] else (2800, -2700)
    secret = [s["pos"] for s in e["shops"] if s["type"] == 2]
    md = {
        "bounds": {"min": -PLAY, "max": PLAY},
        "lanes": lanes,
        "dota": {
            "fountain": _pt(fountain),
            "ancient": _pt(e["forts"]["good"]),
            "shop": _pt(shop),
            "towers": {lane: [_pt(tw["pos"]) for tw in good_towers[lane]] for lane in LANES},
            "barracks": {lane: [_pt(good_rax[lane]["melee"]), _pt(good_rax[lane]["range"])] for lane in LANES},
        },
        "commander": {
            "start": _pt(start),
            "mines": [_pt(mine)],
            "expansions": [_pt(p) for p in expansions],
            "spawns": {lane: dict(lanes[lane][-1]) for lane in LANES},     # the Dire spawners
        },
        "roshan": _pt(roshan),
        "runes": [_pt(p) for p in e["runes"]["power"]],
        "bounty_runes": [_pt(p) for p in e["runes"]["bounty"]],
        "side_shops": [_pt(p) for p in secret],
        "camps": camps,
    }
    md["dota"]["towers"]["base"] = [_pt(tw["pos"]) for tw in good_towers["base"]]
    return md


# ------------------------------------------------------------------ trees

DEGREES = 0.017453292519943295       # pi / 180


def place_trees(t, desc, clear):
    """Dota's trees as WC3 tree destructables, minus those on cliffs, ramps,
    the commander base and the cleared spots (list of (x, y, radius)). Each
    keeps Dota's facing and scale, and gets the WC3 tree type and variation
    that carries its Dota model (trees.plan_trees)."""
    plan = trees.plan_trees(desc)
    kinds = plan["kinds"]
    out = []
    for row in desc["entities"]["trees"]:
        x, y = row[0], row[1]
        if abs(x) > PLAY - 64 or abs(y) > PLAY - 64:
            continue
        i, j = int((x - ORIGIN) // 128), int((y - ORIGIN) // 128)
        if t.cliff[j * TILES + i]:
            continue                                   # would stand half up a cliff
        touched = [(a, b) for a in range(int((x - 64 - ORIGIN) // 128), int((x + 63 - ORIGIN) // 128) + 1)
                   for b in range(int((y - 64 - ORIGIN) // 128), int((y + 63 - ORIGIN) // 128) + 1)]
        if any(c in t.ramp_tiles or c in t.romp_tiles for c in touched):
            continue                                   # would block a ramp
        if t.base[ci(int(round((x - ORIGIN) / 128)), int(round((y - ORIGIN) / 128)))]:
            continue
        if any(math.hypot(x - cx, y - cy) < rad for cx, cy, rad in clear):
            continue
        pick = kinds[row[2]] if len(row) > 2 and row[2] < len(kinds) else None
        kind, variation = pick if pick else (TREE_ID, _hash(x, y, 13) % 10)
        yaw = row[3] if len(row) > 3 else 270.0
        scale = row[4] if len(row) > 4 else 1.0
        out.append((x, y, round(t.ground_z(x, y), 3), variation, round(scale, 3), kind, round(yaw * DEGREES, 4)))
    t.trees = out
    t.tree_plan = plan


# ------------------------------------------------------------------ all of it

def convert(desc, log=lambda s: None):
    t = Terrain()
    r = Rasters(desc)
    walk_count = corner_votes(t, r)
    limit_blocked_levels(t, walk_count)
    base_region = commander_base(t, desc, walk_count)
    fountain_pad(t, desc["entities"]["fountains"]["good"], walk_count, radius=1050)
    place_ramps(t, desc, walk_count)
    raised = raise_blocked(t, r, desc, walk_count)
    limit_steps(t, walk_count)
    roughen_raised(t)
    water_and_heights(t, r, walk_count)
    textures(t, r, desc)
    t.finalize_tiles()
    base_tiles = {(k % N, k // N) for k in base_region
                  if all(t.base[ci(k % N + a, k // N + b)] for a in (0, 1) for b in (0, 1) if k % N + a < N and k // N + b < N)}
    pathing(t, r, base_tiles)
    t.mapdata = gameplay(t, r, desc, base_region)
    md = t.mapdata
    clear = [(md["commander"]["start"]["x"], md["commander"]["start"]["y"], 900)]
    clear += [(p["x"], p["y"], 640) for p in md["commander"]["mines"] + md["commander"]["expansions"]]
    place_trees(t, desc, clear)
    decor = place_decor(t, trees.decor_kinds(t.tree_plan))
    buildable_ground(t, [(p["x"], p["y"]) for p in md["commander"]["mines"] + md["commander"]["expansions"]], 900)
    # The expansions' ground: open and buildable around the mine and the hall.
    for p in md["commander"]["expansions"]:
        for b in range(-20, 21):
            for a in range(-20, 21):
                x, y = p["x"] + 32 * a, p["y"] + 32 * b
                k = r.cell_of(x, y)
                if k is not None and a * a + b * b <= 400 and t.pathing[k] == BLOCKED and not t.tile_blocked(
                        int((x - ORIGIN) // 128), int((y - ORIGIN) // 128)):
                    t.pathing[k] = LAND
    strips = place_rocks(t, r, desc)
    cells = check_reachable(t)
    odd = sorted(set(transition_names(t.level, t.ramp)) - RAMP_SIDES - FLAT_SIDES)
    if odd:
        raise ConvertError(f"cliffs ask for ramp models WC3 may not have: {', '.join(odd[:5])}")
    log(f"terrain: {len(t.ramps)} WC3 ramps, {len(t.trees)} trees, {len(base_region)} commander base corners, "
        f"{cells} pathing cells reachable from the fountain")
    log(f"terrain: {raised} corners of blocked ground raised, {decor} decorative trees on them, {len(t.rocks)} "
        f"rocks on {strips} blocked cells too narrow for a cliff, {walkable_share(t, r):.2%} of Dota's walkable "
        "ground walkable")
    for n in t.notes:
        log(f"terrain: {n}")
    return t
