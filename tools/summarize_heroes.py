"""Summarize the roster's Dota 2 hero stats and abilities into research/heroes.json.

Input is the dev-reference KV extracted by extract_dota_data.py. Only numbers and
short names are kept; tooltip text is not copied.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv  # noqa: E402

HEROES = [
    "pudge", "meepo", "tinker", "rubick", "morphling", "furion",
    "chen", "antimage", "techies", "ogre_magi", "nevermore",
]

STAT_KEYS = [
    "AttributePrimary", "AttributeBaseStrength", "AttributeStrengthGain",
    "AttributeBaseAgility", "AttributeAgilityGain", "AttributeBaseIntelligence",
    "AttributeIntelligenceGain", "AttackCapabilities", "AttackDamageMin",
    "AttackDamageMax", "AttackRate", "BaseAttackSpeed", "AttackAnimationPoint",
    "AttackRange", "ProjectileSpeed", "MovementSpeed", "MovementTurnRate",
    "ArmorPhysical", "MagicalResistance", "StatusHealth", "StatusHealthRegen",
    "StatusMana", "StatusManaRegen", "VisionDaytimeRange", "VisionNighttimeRange",
]

ABILITY_KEYS = [
    "AbilityBehavior", "AbilityType", "AbilityUnitDamageType", "AbilityUnitTargetTeam",
    "AbilityUnitTargetType", "SpellImmunityType", "MaxLevel", "AbilityCastPoint",
    "AbilityCooldown", "AbilityManaCost", "AbilityCastRange", "AbilityChannelTime",
    "Innate", "IsGrantedByShard", "IsGrantedByScepter", "LinkedAbility",
]


def values_of(block):
    out = {}
    for k, v in (block or {}).items():
        if isinstance(v, dict):
            if "value" in v:
                out[k] = v["value"]
            if v.get("RequiresScepter") == "1" or v.get("RequiresShard") == "1":
                out[k + "@upgrade_only"] = "1"
        else:
            out[k] = v
    return out


def main(data_dir, out_path):
    npc = os.path.join(data_dir, "scripts", "npc")
    base = kv.load(os.path.join(npc, "npc_heroes.txt"))["DOTAHeroes"].get("npc_dota_hero_base", {})
    names = kv.load(os.path.join(data_dir, "resource", "localization", "abilities_english.txt"))
    tokens = names.get("lang", {}).get("Tokens", {})
    hero_names = kv.load(os.path.join(data_dir, "resource", "localization", "dota_english.txt"))
    hero_tokens = hero_names.get("lang", {}).get("Tokens", {})

    result = {}
    for h in HEROES:
        full = f"npc_dota_hero_{h}"
        root = kv.load(os.path.join(npc, "heroes", f"{full}.txt"))["DOTAHeroes"][full]
        defs = root.get("AbilityDefinitions", {})
        stats = {k: root.get(k, base.get(k)) for k in STAT_KEYS}
        abilities = []
        for slot in range(1, 10):
            name = root.get(f"Ability{slot}")
            if not name or name.startswith(("generic_hidden", "special_bonus")):
                continue
            d = defs.get(name, {})
            ab = {"slot": slot, "name": name,
                  "title": tokens.get(f"DOTA_Tooltip_ability_{name}", tokens.get(f"DOTA_Tooltip_Ability_{name}", ""))}
            ab.update({k: d[k] for k in ABILITY_KEYS if k in d})
            ab["values"] = values_of(d.get("AbilityValues"))
            abilities.append(ab)
        # Abilities defined in the file but not slotted (sub-abilities, shard/scepter grants)
        extra = sorted(k for k in defs if k not in {a["name"] for a in abilities})
        # Valve's own bot data: skill order, item loadout, role and laning
        botkv = root.get("Bot", {})
        build = [botkv.get("Build", {}).get(str(i), "") for i in range(1, 31)]
        loadout = [k for k in botkv.get("Loadout", {}) if isinstance(k, str)]
        bot = {"build": build, "loadout": loadout, "heroType": botkv.get("HeroType", ""),
               "laning": botkv.get("LaningInfo", {})}
        result[h] = {"id": full, "title": hero_tokens.get(full, h), "stats": stats,
                     "abilities": abilities, "unslotted": extra, "bot": bot}

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False, indent=1)

    for h, info in result.items():
        s = info["stats"]
        print(f"== {info['title']} ({h}) {s['AttributePrimary']} "
              f"STR {s['AttributeBaseStrength']}+{s['AttributeStrengthGain']} "
              f"AGI {s['AttributeBaseAgility']}+{s['AttributeAgilityGain']} "
              f"INT {s['AttributeBaseIntelligence']}+{s['AttributeIntelligenceGain']} "
              f"dmg {s['AttackDamageMin']}-{s['AttackDamageMax']} BAT {s['AttackRate']} "
              f"range {s['AttackRange']} ms {s['MovementSpeed']} armor {s['ArmorPhysical']}")
        for a in info["abilities"]:
            beh = (a.get("AbilityBehavior") or "").replace("DOTA_ABILITY_BEHAVIOR_", "").replace(" ", "")
            tag = "ULT " if "ULTIMATE" in (a.get("AbilityType") or "") else ""
            tag += "INNATE " if a.get("Innate") == "1" or "innate" in a["name"] else ""
            print(f"  [{a['slot']}] {tag}{a['title'] or a['name']} <{a['name']}> {beh}")
        if info["unslotted"]:
            print("  unslotted:", ", ".join(info["unslotted"]))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
