"""Write src/data/mapdata.json (consumed by the map script) from tools/layout.py."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import layout as L  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def pts(seq):
    return [{"x": x, "y": y} for x, y in seq]


def main():
    data = {
        "bounds": {"min": -L.PLAY, "max": L.PLAY},
        "lanes": {name: pts(p) for name, p in L.LANES.items()},
        "dota": {
            "fountain": pts([L.DOTA["fountain"]])[0],
            "ancient": pts([L.DOTA["ancient"]])[0],
            "shop": pts([L.DOTA["shop"]])[0],
            "towers": {lane: pts(p) for lane, p in L.DOTA["towers"].items()},
            "barracks": {lane: pts(p) for lane, p in L.DOTA["barracks"].items()},
        },
        "warcraft": {
            "start": pts([L.WARCRAFT["start"]])[0],
            "mines": pts(L.WARCRAFT["mines"]),
            "expansions": pts(L.WARCRAFT["expansions"]),
            "spawns": {lane: pts([p])[0] for lane, p in L.WARCRAFT["spawns"].items()},
        },
        "roshan": pts([L.ROSHAN])[0],
        "runes": pts(L.RUNES),
        "side_shops": pts(L.SIDE_SHOPS),
        "camps": {name: pts([p])[0] for name, p in L.CAMPS.items()},
    }
    out = os.path.join(ROOT, "src", "data", "mapdata.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + f".{os.getpid()}.tmp"     # atomic: parallel builds may read it
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=1)
    os.replace(tmp, out)
    print("wrote", out)


if __name__ == "__main__":
    main()
