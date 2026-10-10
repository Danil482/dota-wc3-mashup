"""Write the map's minimap image (war3mapMap.blp) and an empty minimap-icon
file (war3map.mmp). Every editor-made map has both; without them the game
reported "Game data is unable to load" while loading our map.

Usage: gen_minimap.py <out folder>
"""
import os
import struct
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout as L  # noqa: E402

COLORS = {"Ldro": (96, 120, 150), "Lrok": (120, 120, 120), "Ldrg": (126, 110, 74),
          "Ldrt": (150, 124, 82), "Lgrd": (44, 86, 40), "Lgrs": (60, 112, 48)}
SIZE = 256


def render():
    img = Image.new("RGB", (SIZE, SIZE), (0, 0, 0))
    step = 2 * L.HALF / SIZE
    trees = set()
    for tx, ty in L.trees():
        trees.add((int((tx + L.HALF) / step), int((L.HALF - ty) / step)))
    for j in range(SIZE):
        for i in range(SIZE):
            x, y = -L.HALF + (i + 0.5) * step, L.HALF - (j + 0.5) * step
            if abs(x) > L.PLAY or abs(y) > L.PLAY:
                continue
            if L.water_depth(x, y) > 0.45:
                c = (40, 80, 170)
            elif (i, j) in trees:
                c = (18, 52, 22)
            else:
                c = COLORS[L.ground_tile(x, y)]
            img.putpixel((i, j), c)
    return img


def main(out_dir):
    os.makedirs(out_dir, exist_ok=True)
    img = render().quantize(colors=256)
    img.save(os.path.join(out_dir, "war3mapMap.blp"), format="BLP", blp_version="BLP1")
    with open(os.path.join(out_dir, "war3map.mmp"), "wb") as f:
        f.write(struct.pack("<ii", 0, 0))   # version 0, no icons
    print("minimap written")


if __name__ == "__main__":
    main(sys.argv[1])
