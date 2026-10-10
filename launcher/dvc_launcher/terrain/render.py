"""Top-down pictures: the Dota description (preview), the converted WC3
terrain (for comparison) and the minimap image the map carries."""
import base64

from PIL import Image, ImageDraw

from . import convert, source

LEVEL_COLORS = {-2: (20, 30, 80), -1: (30, 50, 120), 0: (40, 90, 200), 1: (60, 150, 60), 2: (170, 150, 90),
                3: (205, 205, 205), 4: (125, 85, 160), 5: (95, 60, 125), 6: (70, 40, 100)}
TILE_COLORS = {"Ldrt": (150, 124, 82), "Ldro": (110, 100, 80), "Ldrg": (126, 120, 74), "Lrok": (120, 120, 120),
               "Lgrs": (60, 112, 48), "Lgrd": (44, 86, 40), "Yrtl": (170, 165, 150), "Bdrt": (150, 96, 60),
               "Bdrr": (120, 84, 60), "Bdsd": (96, 72, 52), "Adrd": (80, 62, 46)}
WATER = (40, 80, 170)
TREE = (18, 52, 22)


def _scale_point(x, y, size, half=10240.0):
    return ((x + half) / (2 * half) * size, (half - y) / (2 * half) * size)


def _markers(draw, md, size):
    def dot(p, color, r=3):
        x, y = _scale_point(p["x"], p["y"], size)
        draw.ellipse([x - r, y - r, x + r, y + r], fill=color, outline=(0, 0, 0))
    for lane in md["lanes"].values():
        pts = [_scale_point(p["x"], p["y"], size) for p in lane]
        draw.line(pts, fill=(255, 255, 255), width=1)
    d = md["dota"]
    for lane in d["towers"].values():
        for p in lane:
            dot(p, (60, 220, 60))
    for lane in d["barracks"].values():
        for p in lane:
            dot(p, (30, 160, 30))
    dot(d["ancient"], (0, 255, 0), 6)
    dot(d["fountain"], (0, 255, 255), 5)
    dot(d["shop"], (255, 255, 0))
    c = md["commander"]
    dot(c["start"], (255, 40, 40), 7)
    for p in c["mines"] + c["expansions"]:
        dot(p, (255, 215, 0), 5)
    for p in c["spawns"].values():
        dot(p, (255, 120, 0))
    for p in md["camps"].values():
        dot(p, (255, 0, 255))
    for p in md["runes"] + md.get("bounty_runes", []):
        dot(p, (0, 200, 255))
    dot(md["roshan"], (160, 0, 0), 6)


def preview_dota(desc, path, size=1280, mapdata=None):
    """Dota's layout as described: levels, slopes, blocked ground, water, trees."""
    n = source.SIZE
    height = source.unpack_z(desc["height"])
    water = source.unpack_z(desc["water"])
    walk = base64.b64decode(desc["walkable"])
    img = Image.new("RGB", (n, n))
    pix = img.load()
    for j in range(n):
        for i in range(n):
            k = j * n + i
            z = height[k]
            if water[k] is not None and (z is None or water[k] > z):
                c = WATER
            elif z is None:
                c = (255, 0, 255)
            else:
                lv = z / 128.0
                r = round(lv)
                c = LEVEL_COLORS.get(max(-2, min(6, r)), (0, 0, 0)) if abs(lv - r) <= 0.125 else (255, int(255 * (lv % 1)), 0)
            if not walk[k]:
                c = (c[0] // 3, c[1] // 3, c[2] // 3)
            pix[i, n - 1 - j] = c
    img = img.resize((size, size), Image.NEAREST)
    draw = ImageDraw.Draw(img)
    half = 64 * size / 20480.0
    for x, y in desc["entities"]["trees"]:
        px, py = _scale_point(x, y, size)
        draw.rectangle([px - half, py - half, px + half - 1, py + half - 1], fill=TREE)
    if mapdata:
        _markers(draw, mapdata, size)
    img.save(path)


def render_wc3(t, path, size=1280, pathing=True):
    """The converted WC3 terrain: tile colours shaded by height, cliffs dark,
    ramps orange, water blue, unwalkable cells dimmed, trees, gameplay spots."""
    cells = convert.CELLS
    img = Image.new("RGB", (cells, cells))
    pix = img.load()
    for pj in range(cells):
        tj = pj // 4
        for pi in range(cells):
            ti = pi // 4
            c0 = convert.ci(int(round(pi / 4.0)), int(round(pj / 4.0)))
            base = TILE_COLORS[convert.TILE_IDS[t.tex[c0]]]
            k = tj * convert.TILES + ti
            if t.cliff[k] and not t.all_ramp(ti, tj):
                lv = max(t.tile_levels(ti, tj))
                base = (70 + 12 * lv, 60 + 12 * lv, 55 + 12 * lv)
            else:
                lv = t.level[c0]
                shade = 0.75 + 0.1 * lv
                base = tuple(max(0, min(255, int(v * shade))) for v in base)
            if (ti, tj) in t.ramp_tiles:
                base = (230, 140, 30)
            v = t.pathing[pj * cells + pi]
            if v == convert.WATER:
                base = WATER
            if pathing and v in (convert.BLOCKED, convert.BOUNDARY):
                base = (base[0] // 2, base[1] // 2, base[2] // 2)
            pix[pi, cells - 1 - pj] = base
    img = img.resize((size, size), Image.NEAREST)
    draw = ImageDraw.Draw(img)
    half = 64 * size / 20480.0
    for x, y, _z, _v, _s in t.trees:
        px, py = _scale_point(x, y, size)
        draw.rectangle([px - half, py - half, px + half - 1, py + half - 1], fill=TREE)
    if t.mapdata:
        _markers(draw, t.mapdata, size)
    img.save(path)


def minimap(t, size=256):
    """The minimap picture (war3mapMap.blp): ground colours, cliffs, water and
    trees; black outside the playable area."""
    img = Image.new("RGB", (size, size), (0, 0, 0))
    pix = img.load()
    step = 2 * 10240.0 / size
    trees = set()
    for x, y, _z, _v, _s in t.trees:
        trees.add((int((x + 10240) / step), int((10240 - y) / step)))
    for j in range(size):
        for i in range(size):
            x, y = -10240 + (i + 0.5) * step, 10240 - (j + 0.5) * step
            if abs(x) > convert.PLAY or abs(y) > convert.PLAY:
                continue
            ti, tj = int((x + 10240) // 128), int((y + 10240) // 128)
            c0 = convert.ci(int(round((x + 10240) / 128)), int(round((y + 10240) / 128)))
            pc = t.pathing[int((y + 10240) // 32) * convert.CELLS + int((x + 10240) // 32)]
            if pc == convert.WATER:
                c = WATER
            elif (i, j) in trees:
                c = TREE
            elif t.cliff[tj * convert.TILES + ti] and not t.all_ramp(ti, tj):
                c = (96, 90, 84)
            else:
                base = TILE_COLORS[convert.TILE_IDS[t.tex[c0]]]
                shade = 0.8 + 0.08 * t.level[c0]
                c = tuple(max(0, min(255, int(v * shade))) for v in base)
            pix[i, j] = c
    return img
