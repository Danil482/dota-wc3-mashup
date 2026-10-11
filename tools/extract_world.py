"""Extract the Dota 2 world numbers (neutral creeps, Roshan, lane creep
bounties, backdoor protection, tower ranges, Aegis and Cheese) into
src/data/world.json.

Input is the dev-reference KV from the player's patch (research/dota_data,
see extract_dota_data.py). Only numbers and English unit names are kept.

world.json (read by tools/gen_objects.py world() and by Lua as use("data.world")):
  neutrals[name]   title, hp, hp_regen, mana, mana_regen, armor, magic_resist,
                   dmg_min, dmg_max, attack_rate, range, ranged, projectile_speed,
                   gold_min, gold_max, xp, level, ancient, move_speed
                   (name = npc_dota_neutral_<name>)
  neutral_upgrade  neutral_upgrade ability: interval and per-step bonuses
  lane[kind]       melee/ranged/siege lane creep bounty: gold_min, gold_max, xp;
                   day and night vision
  roshan           unit numbers plus bash, slam and spell_block values
  backdoor         backdoor_protection: radius, activation_time, regen
  towers[tier]     attack range per tier (true sight radius); day and night vision
  buildings[key]   rax_melee, rax_ranged, fort (the Ancient): day and night vision
  aegis, cheese    item values
  notes            what is not in the KV files and lives in Lua instead

Usage: extract_world.py [research/dota_data] [src/data/world.json]
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Dota neutrals the camp pools use (src/game/world_camps.lua).
NEUTRALS = [
    "kobold", "kobold_tunneler", "kobold_taskmaster", "forest_troll_berserker", "forest_troll_high_priest",
    "gnoll_assassin", "harpy_scout", "harpy_storm", "ghost", "fel_beast",
    "giant_wolf", "alpha_wolf", "ogre_mauler", "ogre_magi", "satyr_trickster", "satyr_soulstealer",
    "mud_golem", "centaur_outrunner", "centaur_khan", "satyr_hellcaller", "polar_furbolg_champion",
    "polar_furbolg_ursa_warrior", "wildkin", "enraged_wildkin", "dark_troll", "dark_troll_warlord",
    "black_drake", "black_dragon", "rock_golem", "granite_golem", "small_thunder_lizard", "big_thunder_lizard",
]

NOTES = {
    "roshan_growth": "Roshan's per-minute growth (health, armor, attack damage) is hardcoded in Dota's game "
                     "code, not in npc_units; src/game/world_roshan.lua keeps it as constants.",
    "lane_upgrades": "Lane creep upgrades every 7.5 minutes are hardcoded in Dota's game code; "
                     "src/game/world.lua keeps them as constants.",
    "runes": "Rune effects are hardcoded in Dota's game code; src/game/world_runes.lua keeps the numbers "
             "from the patch's own rune tooltips.",
}


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
        out[k] = first(v["value"] if isinstance(v, dict) else v)
    return out


def vision(u):
    return {"day": first(u.get("VisionDaytimeRange")), "night": first(u.get("VisionNighttimeRange"))}


def unit(u, title):
    return {
        "title": title,
        "hp": first(u.get("StatusHealth")), "hp_regen": first(u.get("StatusHealthRegen")),
        "mana": first(u.get("StatusMana")), "mana_regen": first(u.get("StatusManaRegen")),
        "armor": first(u.get("ArmorPhysical")), "magic_resist": first(u.get("MagicalResistance")),
        "dmg_min": first(u.get("AttackDamageMin")), "dmg_max": first(u.get("AttackDamageMax")),
        "attack_rate": first(u.get("AttackRate"), 2), "range": first(u.get("AttackRange"), 100),
        "acquire": first(u.get("AttackAcquisitionRange"), 0),
        "ranged": u.get("AttackCapabilities") == "DOTA_UNIT_CAP_RANGED_ATTACK",
        "projectile_speed": first(u.get("ProjectileSpeed"), 0),
        "gold_min": first(u.get("BountyGoldMin")), "gold_max": first(u.get("BountyGoldMax")),
        "xp": first(u.get("BountyXP")), "level": first(u.get("Level"), 1),
        "ancient": u.get("IsAncient") == "1", "move_speed": first(u.get("MovementSpeed"), 300),
    }


def main(data_dir, out_path):
    npc = os.path.join(data_dir, "scripts", "npc")
    units = kv.load(os.path.join(npc, "npc_units.txt"))["DOTAUnits"]
    abilities = kv.load(os.path.join(npc, "npc_abilities.txt"))["DOTAAbilities"]
    items = kv.load(os.path.join(npc, "items.txt"))["DOTAAbilities"]
    tokens = kv.load(os.path.join(data_dir, "resource", "localization", "abilities_english.txt"))["lang"]["Tokens"]

    def title(name):
        t = tokens.get(name)
        if not t:
            raise SystemExit(f"no English name for {name}")
        return t

    neutrals = {}
    for n in NEUTRALS:
        key = "npc_dota_neutral_" + n
        if key not in units:
            raise SystemExit(f"{key} is not in this patch")
        neutrals[n] = unit(units[key], title(key))

    lane = {}
    for kind, key in (("melee", "npc_dota_creep_goodguys_melee"), ("ranged", "npc_dota_creep_goodguys_ranged"),
                      ("siege", "npc_dota_goodguys_siege")):
        u = units[key]
        lane[kind] = dict(vision(u), gold_min=first(u.get("BountyGoldMin")), gold_max=first(u.get("BountyGoldMax")),
                          xp=first(u.get("BountyXP")))

    r = units["npc_dota_roshan"]
    roshan = unit(r, title("npc_dota_roshan"))
    roshan["vision"] = first(r.get("VisionDaytimeRange"), 1400)
    roshan["bash"] = values(abilities["roshan_bash"])
    slam = abilities["roshan_slam"]
    roshan["slam"] = dict(values(slam), cooldown=first(slam.get("AbilityCooldown")),
                          cast_point=first(slam.get("AbilityCastPoint")))
    block = abilities["roshan_spell_block"]
    roshan["spell_block"] = dict(values(block), cooldown=first(block.get("AbilityCooldown")))

    backdoor = values(abilities["backdoor_protection"])
    towers = {}
    for tier, key in ((1, "npc_dota_goodguys_tower1_top"), (2, "npc_dota_goodguys_tower2_top"),
                      (3, "npc_dota_goodguys_tower3_top"), (4, "npc_dota_goodguys_tower4")):
        towers[str(tier)] = dict(vision(units[key]), range=first(units[key].get("AttackRange"), 700))
    buildings = {key: vision(units[name]) for key, name in (
        ("rax_melee", "npc_dota_goodguys_melee_rax_top"), ("rax_ranged", "npc_dota_goodguys_range_rax_top"),
        ("fort", "npc_dota_goodguys_fort"))}

    cheese = items["item_cheese"]
    out = {
        "neutrals": neutrals,
        "neutral_upgrade": values(abilities["neutral_upgrade"]),
        "lane": lane,
        "roshan": roshan,
        "backdoor": backdoor,
        "towers": towers,
        "buildings": buildings,
        "aegis": values(items["item_aegis"]),
        "cheese": dict(values(cheese), cooldown=first(cheese.get("AbilityCooldown"))),
        "notes": NOTES,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
    print(f"world.json: {len(neutrals)} neutral creeps, Roshan, lane bounties, backdoor, towers, Aegis, Cheese")


if __name__ == "__main__":
    args = sys.argv[1:]
    main(args[0] if args else os.path.join(ROOT, "research", "dota_data"),
         args[1] if len(args) > 1 else os.path.join(ROOT, "src", "data", "world.json"))
