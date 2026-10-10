"""Copy research/heroes.json into src/data/heroes.json (numbers and names only),
taking hero display names from src/data/hero_specs.json."""
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TITLES = {"pudge": "Pudge", "meepo": "Meepo", "tinker": "Tinker", "rubick": "Rubick",
          "morphling": "Morphling", "furion": "Nature's Prophet", "chen": "Chen",
          "antimage": "Anti-Mage", "techies": "Techies", "ogre_magi": "Ogre Magi",
          "nevermore": "Shadow Fiend"}


def main():
    with open(os.path.join(ROOT, "research", "heroes.json"), encoding="utf-8") as f:
        src = json.load(f)
    out = {h: {"id": v["id"], "title": TITLES[h], "stats": v["stats"], "abilities": v["abilities"],
               "bot": v.get("bot", {})}
           for h, v in src.items()}
    with open(os.path.join(ROOT, "src", "data", "heroes.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    missing = [a["name"] for v in out.values() for a in v["abilities"] if not a.get("title")]
    print(f"heroes.json: {len(out)} heroes; abilities without a title: {missing}")


if __name__ == "__main__":
    main()
