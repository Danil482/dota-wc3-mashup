"""Render the layout to a PNG for a quick visual sanity check."""
import os
import sys

from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout as L  # noqa: E402

COLORS = {"Ldro": (90, 120, 160), "Lrok": (130, 130, 130), "Ldrg": (140, 120, 80),
          "Ldrt": (170, 140, 90), "Lgrd": (40, 90, 40), "Lgrs": (60, 120, 50)}


def main(out):
    size = 640
    scale = size / (2 * L.HALF)

    def px(x, y):
        return (x + L.HALF) * scale, size - (y + L.HALF) * scale

    img = Image.new("RGB", (size, size), (0, 0, 0))
    d = ImageDraw.Draw(img)
    step = 2 * L.HALF / size
    for j in range(size):
        for i in range(size):
            x, y = -L.HALF + (i + 0.5) * step, L.HALF - (j + 0.5) * step
            if abs(x) > L.PLAY or abs(y) > L.PLAY:
                continue
            c = COLORS[L.ground_tile(x, y)]
            if L.water_depth(x, y) > 0:
                c = (50, 90, 200)
            img.putpixel((i, j), c)
    for tx, ty in L.trees():
        x, y = px(tx, ty)
        d.point((x, y), fill=(10, 50, 10))
    for pts in L.DOTA["towers"].values():
        for p in pts:
            x, y = px(*p)
            d.rectangle((x - 3, y - 3, x + 3, y + 3), fill=(0, 255, 0))
    for name, p in L.CAMPS.items():
        x, y = px(*p)
        d.ellipse((x - 3, y - 3, x + 3, y + 3), fill=(255, 200, 0))
    for p in [L.DOTA["ancient"], L.WARCRAFT["start"], L.ROSHAN] + L.RUNES:
        x, y = px(*p)
        d.ellipse((x - 5, y - 5, x + 5, y + 5), outline=(255, 0, 0))
    img.save(out)
    print("trees:", len(L.trees()))


if __name__ == "__main__":
    main(sys.argv[1])
