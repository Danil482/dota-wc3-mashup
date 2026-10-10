"""Extract Dota 2 KeyValues and list asset paths for the mashup's hero roster.

Reads the player's own Dota 2 install (pak01_dir.vpk). Output is dev reference
only and is never shipped: it goes to research/dota_data/ (gitignored).
"""
import os
import sys

import vpk

HEROES = [
    "pudge", "meepo", "tinker", "rubick", "morphling", "furion",
    "chen", "antimage", "techies", "ogre_magi", "nevermore",
]

TEXT_FILES = [
    "scripts/npc/npc_heroes.txt",
    "scripts/npc/npc_abilities.txt",
    "scripts/npc/items.txt",
    "scripts/npc/npc_units.txt",
    "resource/localization/abilities_english.txt",
    "resource/localization/dota_english.txt",
]


def main(dota_dir: str, out_dir: str) -> None:
    pak = vpk.open(os.path.join(dota_dir, "game", "dota", "pak01_dir.vpk"))
    os.makedirs(out_dir, exist_ok=True)

    wanted = set(TEXT_FILES)
    wanted.update(f"scripts/npc/heroes/npc_dota_hero_{h}.txt" for h in HEROES)
    for path in sorted(wanted):
        try:
            data = pak[path].read()
        except KeyError:
            print(f"MISSING {path}")
            continue
        dest = os.path.join(out_dir, path.replace("/", os.sep))
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "wb") as f:
            f.write(data)
        print(f"OK {path} ({len(data)} bytes)")

    # Asset path inventory per hero: icons, ability icons, voice lines, models
    counts = {h: {"spellicons": 0, "vo": 0, "models": 0, "heroimg": 0} for h in HEROES}
    samples = {h: [] for h in HEROES}
    for path in pak:
        for h in HEROES:
            vo_name = {"nevermore": "nevermore", "furion": "furion"}.get(h, h)
            if path.startswith(f"panorama/images/spellicons/{h}_"):
                counts[h]["spellicons"] += 1
            elif path.startswith(f"sounds/vo/{vo_name}/"):
                counts[h]["vo"] += 1
            elif path.startswith(f"models/heroes/{h}/") and path.endswith(".vmdl_c"):
                counts[h]["models"] += 1
                if len(samples[h]) < 3:
                    samples[h].append(path)
            elif path.startswith("panorama/images/heroes/") and f"npc_dota_hero_{h}" in path:
                counts[h]["heroimg"] += 1
    for h in HEROES:
        print(h, counts[h], samples[h])


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
