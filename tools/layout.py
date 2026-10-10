"""Map layout: one source of truth for terrain generation and the map script.

Coordinates are WC3 world units. The Dota team (Radiant) sits bottom-left, the
Commander's open half top-right, mirroring Dota 2's three-lane map at roughly
the same scale (heroes move ~300 u/s in both games).
"""
import math
import random

TILES = 160                      # map width/height in tiles (128 units each)
HALF = TILES * 128 // 2          # world spans [-HALF, HALF]
MARGIN = 8 * 128                 # unplayable border
PLAY = HALF - MARGIN             # playable area is [-PLAY, PLAY]

LANE_WIDTH = 720
RIVER_WIDTH = 900
PATH_WIDTH = 380

# Lanes run from the Dota base to the Commander's base.
LANES = {
    "bot": [(-5300, -7000), (6900, -7000), (7000, -6900), (7000, 3300)],
    "mid": [(-5100, -5100), (4300, 4300)],
    "top": [(-7000, -5300), (-7000, 6900), (-6900, 7000), (3300, 7000)],
}

RIVER = [(-9300, 5300), (-7000, 4500), (-4000, 2400), (0, 0), (2400, -4000), (4500, -7000), (5300, -9300)]

DOTA = {
    "fountain": (-7600, -7600),
    "ancient": (-6300, -6300),
    "shop": (-7000, -8000),
    "towers": {
        "top": [(-7000, 2800), (-7000, -1200), (-7000, -4700)],
        "mid": [(-1300, -1300), (-3000, -3000), (-4700, -4700)],
        "bot": [(2800, -7000), (-1200, -7000), (-4700, -7000)],
        "base": [(-5900, -6550), (-6550, -5900)],
    },
    # melee + ranged barracks behind each tier-3 tower
    "barracks": {
        "top": [(-7550, -5300), (-6450, -5300)],
        "mid": [(-5100, -5700), (-5700, -5100)],
        "bot": [(-5300, -7550), (-5300, -6450)],
    },
}

COMMANDER = {
    "start": (6300, 6300),          # town hall position
    "mines": [(6050, 7550)],
    "expansions": [(1900, 6250), (6250, 1900)],
    "spawns": {"top": (3600, 7000), "mid": (4200, 4200), "bot": (7000, 3600)},
}

ROSHAN = (3100, -2700)
RUNES = [(-2700, 1620), (1620, -2700)]
SIDE_SHOPS = [(-7700, 4400), (4400, -7700)]

CAMPS = {
    # Dota-side jungle (between top/mid/bot lanes, below the river)
    "d_small": (-3300, -5600), "d_medium1": (-1700, -4900), "d_medium2": (-4900, -1700),
    "d_large": (-2600, -3700), "d_ancient": (-3700, -2500),
    # Commander-side jungle
    "c_small": (5600, 3300), "c_medium1": (4900, 1700), "c_medium2": (1700, 4900),
    "c_large": (3700, 2600), "c_ancient": (2500, 3700),
    # outer jungles beyond the river, by the long lanes
    "o_top1": (-5400, 6000), "o_top2": (-3300, 5600), "o_bot1": (6000, -5400), "o_bot2": (5600, -3300),
}

JUNGLE_PATHS = [
    [(-7000, -3000), (-4900, -1700), (-3700, -2500), (-2600, -3700), (-1700, -4900), (-3300, -5600), (-4300, -7000)],
    [(-4900, -1700), (-4200, 0), (-2700, 1620)],
    [(-1700, -4900), (0, -4300), (1620, -2700)],
    [(-2600, -3700), (-1400, -1600)],
    [(-7000, 5200), (-5400, 6000), (-3300, 5600), (-2700, 1620)],
    [(-3300, 5600), (-2000, 7000)],
    [(7000, 3000), (4900, 1700), (3700, 2600), (2500, 3700), (1700, 4900), (3300, 5600), (4300, 7000)],
    [(4900, 1700), (4300, 0), (1620, -2700)],
    [(1700, 4900), (0, 4300), (-2700, 1620)],
    [(3700, 2600), (1600, 1400)],
    [(5200, -7000), (6000, -5400), (5600, -3300), (1620, -2700)],
    [(5600, -3300), (7000, -2000)],
    [(1620, -2700), (3100, -2700), (4500, -2200)],
]


def _seg_dist(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    t = 0.0 if dx == dy == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy)


def polyline_dist(px, py, pts):
    return min(_seg_dist(px, py, *pts[i], *pts[i + 1]) for i in range(len(pts) - 1))


def in_lane(x, y, pad=0):
    return any(polyline_dist(x, y, p) < LANE_WIDTH / 2 + pad for p in LANES.values())


def in_river(x, y, pad=0):
    return polyline_dist(x, y, RIVER) < RIVER_WIDTH / 2 + pad


DOTA_BASE_EDGE = -4300          # Dota base: x < edge and y < edge
COMMANDER_BASE_EDGE = 3900      # Commander base: x > edge and y > edge


def in_base(x, y, pad=0):
    return ((x < DOTA_BASE_EDGE + pad and y < DOTA_BASE_EDGE + pad)
            or (x > COMMANDER_BASE_EDGE - pad and y > COMMANDER_BASE_EDGE - pad))


def is_clear(x, y):
    """True where no tree may stand: lanes, river, bases, camps, paths, landmarks."""
    if in_lane(x, y, 60) or in_river(x, y, 120) or in_base(x, y, 0):
        return True
    for cx, cy in list(CAMPS.values()) + [ROSHAN] + RUNES + SIDE_SHOPS + COMMANDER["expansions"]:
        if math.hypot(x - cx, y - cy) < 520:
            return True
    return any(polyline_dist(x, y, p) < PATH_WIDTH / 2 for p in JUNGLE_PATHS)


def trees(seed=7, step=128, band=5):
    """Tree positions: a dense band (band cells deep) along every clear area,
    sparser deep forest behind it so the tree count stays manageable."""
    rng = random.Random(seed)
    n = int(2 * PLAY // step)
    clear = [[is_clear(-PLAY + (i + 0.5) * step, -PLAY + (j + 0.5) * step) for i in range(n)] for j in range(n)]
    dist = [[0 if clear[j][i] else 10 ** 6 for i in range(n)] for j in range(n)]
    frontier = [(i, j) for j in range(n) for i in range(n) if clear[j][i]]
    while frontier:
        nxt = []
        for i, j in frontier:
            for di, dj in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                a, b = i + di, j + dj
                if 0 <= a < n and 0 <= b < n and dist[b][a] > dist[j][i] + 1:
                    dist[b][a] = dist[j][i] + 1
                    nxt.append((a, b))
        frontier = nxt
    out = []
    for j in range(n):
        for i in range(n):
            d = dist[j][i]
            if d == 0 or (d > band and (i % 2 or j % 2)):
                continue
            x = -PLAY + (i + 0.5) * step + rng.uniform(-20, 20)
            y = -PLAY + (j + 0.5) * step + rng.uniform(-20, 20)
            out.append((round(x), round(y)))
    return out


def ground_tile(x, y):
    """Tile code for a world point (Lordaeron Summer tileset)."""
    if in_river(x, y, 160):
        return "Ldro"           # rough dirt under/near the water
    if in_base(x, y, 0):
        return "Lrok" if x < 0 else "Ldrg"
    if in_lane(x, y):
        return "Ldrt"
    if any(polyline_dist(x, y, p) < PATH_WIDTH / 2 for p in JUNGLE_PATHS):
        return "Ldrg"
    return "Lgrd" if (int(x // 512) + int(y // 512)) % 3 == 0 else "Lgrs"


def water_depth(x, y):
    """How far below the water line the ground sits at (x, y); 0 outside the river."""
    d = polyline_dist(x, y, RIVER)
    half = RIVER_WIDTH / 2
    if d >= half:
        return 0.0
    return 1.0 - d / half          # 1 at the center line, 0 at the bank
