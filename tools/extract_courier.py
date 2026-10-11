"""Extract Dota's courier into src/data/courier.json.

Input is the dev-reference KV from the player's patch (research/dota_data, see
extract_dota_data.py): the npc_dota_courier unit (npc_units.txt) and the six
abilities on its command card (npc_abilities.txt). Only numbers are kept.

courier.json (read by tools/gen_objects.py and by Lua as use("data.courier")):
  unit       hp, move_speed, turn_rate, vision {day, night}, gold (bounty)
  abilities  {name: {cooldown, values {key: number}}}, Dota's card order:
             retrieve, Secret Shop, return, speed burst, transfer, shield
The rules that live in Dota's game code (levels, respawn, flying, attacks to
kill) are constants in src/game/courier.lua, cited there.

Usage: extract_courier.py [research/dota_data] [src/data/courier.json]
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CARD = ["courier_take_stash_items", "courier_go_to_secretshop", "courier_return_stash_items", "courier_burst",
        "courier_transfer_items", "courier_shield"]


def num(v):
    f = float(v)
    return int(f) if f.is_integer() else f


def first(raw, default=0):
    if raw is None:
        return default
    parts = str(raw).split()
    return num(parts[0]) if parts else default


def values(block):
    out = {}
    for k, v in ((block or {}).get("AbilityValues") or {}).items():
        raw = v.get("value") if isinstance(v, dict) else v
        if raw not in (None, ""):
            out[k] = first(raw)
    return out


def main(data_dir, out_path):
    npc = os.path.join(data_dir, "scripts", "npc")
    unit = kv.load(os.path.join(npc, "npc_units.txt"))["DOTAUnits"]["npc_dota_courier"]
    abilities = kv.load(os.path.join(npc, "npc_abilities.txt"))["DOTAAbilities"]
    out = {
        "unit": {
            "hp": first(unit.get("StatusHealth")),
            "move_speed": first(unit.get("MovementSpeed")),
            "turn_rate": first(unit.get("MovementTurnRate")),
            "vision": {"day": first(unit.get("VisionDaytimeRange")), "night": first(unit.get("VisionNighttimeRange"))},
            "gold": first(unit.get("BountyGoldMin")),
        },
        "abilities": {},
    }
    for name in CARD:
        a = abilities[name]
        out["abilities"][name] = {"cooldown": first(a.get("AbilityCooldown")), "values": values(a)}
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(out, f, indent=1, sort_keys=True)
        f.write("\n")
    print(f"courier: {len(out['abilities'])} abilities -> {out_path}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "research", "dota_data"),
         sys.argv[2] if len(sys.argv) > 2 else os.path.join(ROOT, "src", "data", "courier.json"))
