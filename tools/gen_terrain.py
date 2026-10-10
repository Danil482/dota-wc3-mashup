"""Generate build/terrain.json (w3e corners, pathing cells, trees) from layout.py.

Heights use mdx-m3-viewer's corner units: groundHeight is (raw - 8192) / 512,
so world z = groundHeight * 128 at layer 2, and water at waterHeight 0 sits at
z = -89.6. Pathing cells are 32x32 units: 0x40 land, 0x48 unbuildable land,
0x08 shallow water, 0xCE map boundary (values taken from a 2.0 ladder map).
"""
import base64
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout as L  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TILES = ["Ldrt", "Ldro", "Ldrg", "Lrok", "Lgrs", "Lgrd"]
WATER_Z = -89.6


def ground_height(x, y):
    f = L.water_depth(x, y)
    if f <= 0:
        return 0.0
    return -0.3 - 0.85 * f          # center ~57 units under the water line


def main():
    rng = random.Random(11)
    n = L.TILES + 1
    off = -L.HALF
    corners = []
    for j in range(n):
        y = off + j * 128
        for i in range(n):
            x = off + i * 128
            h = ground_height(x, y)
            edge = abs(x) > L.PLAY or abs(y) > L.PLAY
            tile = L.ground_tile(x, y)
            var = rng.randint(0, 3) if rng.random() < 0.8 else rng.randint(4, 15)
            corners.append({
                "h": round(h, 4),
                "water": L.water_depth(x, y) > 0 or L.in_river(x, y, 64),
                "edge": edge,
                "tex": TILES.index(tile),
                "var": var,
            })

    cells = L.TILES * 4
    path = bytearray(cells * cells)
    for j in range(cells):
        y = off + (j + 0.5) * 32
        for i in range(cells):
            x = off + (i + 0.5) * 32
            if abs(x) > L.PLAY or abs(y) > L.PLAY:
                v = 0xCE
            elif ground_height(x, y) * 128 < WATER_Z:
                v = 0x08
            elif L.in_river(x, y, 96):
                v = 0x48
            else:
                v = 0x40
            path[j * cells + i] = v

    data = {
        "tiles": L.TILES, "offset": off, "tilePalette": TILES,
        "corners": corners,
        "pathing": base64.b64encode(bytes(path)).decode("ascii"),
        "trees": L.trees(),
        "playable": L.PLAY,
    }
    out = os.path.join(ROOT, "build", "terrain.json")
    tmp = out + f".{os.getpid()}.tmp"     # atomic: parallel builds may read it
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f)
    os.replace(tmp, out)
    print(f"terrain: {n}x{n} corners, {cells}x{cells} cells, {len(data['trees'])} trees")


if __name__ == "__main__":
    main()
