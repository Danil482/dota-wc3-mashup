"""Summarize the roster's Dota 2 hero stats and abilities into research/heroes.json.

Input is the dev-reference KV extracted by extract_dota_data.py. Only numbers and
short names are kept; tooltip text is not copied. A talent's label is its short
name in the talent tree (Dota's own talent title, with the numbers filled in).

Per hero, besides stats and abilities:
  talents          the 8 talents in Dota's order (AbilityTalentStart): name, tier
                   (1..4 for levels 10/15/20/25), side ("right" is the first of a
                   pair), label, and for a generic talent its modifier props
                   (src/core/mods.lua names, percentages as fractions)
  attribute_bonus  Dota's Attribute Bonus (special_bonus_attributes): per-level
                   values, max level, first hero level and levels between
Per ability:
  bonus            {value key: {source: Dota operation}} where a source is a
                   talent name, "scepter" or "shard" ("+150", "x1.5", "=1",
                   "-40%", per-level lists such as "1 2 3")
  HasScepterUpgrade / HasShardUpgrade / IsGrantedByScepter / IsGrantedByShard
  AbilityCastAnimation  the activity of the cast animation, which picks the
                   ability's sequence (tools/gen_objects.py aani, mdx/units.py)
"""
import json
import os
import re
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
    "HasScepterUpgrade", "HasShardUpgrade", "AbilityCastAnimation",
]

PCT = 0.01
# Generic talents by name family -> modifier props and scale. Props Mods does
# not sum (cast_range, attack_range, mana_reduction, cooldown_reduction) are
# applied by src/game/talents.lua.
TALENT_STATS = {
    "all_stats": (("str", 1), ("agi", 1), ("int", 1)),
    "strength": (("str", 1),),
    "agility": (("agi", 1),),
    "intelligence": (("int", 1),),
    "attack_damage": (("damage", 1),),
    "attack_speed": (("attack_speed", 1),),
    "armor": (("armor", 1),),
    "hp_regen": (("hp_regen", 1),),
    "mp_regen": (("mana_regen", 1),),
    "hp": (("max_hp", 1),),
    "mp": (("max_mana", 1),),
    "movement_speed": (("move_flat", 1),),
    "evasion": (("evasion", PCT),),
    "magic_resistance": (("magic_resist", PCT),),
    "spell_lifesteal": (("spell_lifesteal", PCT),),
    "lifesteal": (("lifesteal", PCT),),
    "spell_amplify": (("spell_amp", PCT),),
    "cast_range": (("cast_range", 1),),
    "attack_range": (("attack_range", 1),),
    "mana_reduction": (("mana_reduction", PCT),),
    "cooldown_reduction": (("cooldown_reduction", PCT),),
}
GENERIC = re.compile(r"^special_bonus_(" + "|".join(sorted(TALENT_STATS, key=len, reverse=True)) + r")_\d+$")
UPGRADE_SOURCES = {"special_bonus_scepter": "scepter", "special_bonus_shard": "shard"}


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


def bonus_of(block, talents):
    """{value key: {source: operation}} for talents, Scepter and Shard."""
    out = {}
    for k, v in (block or {}).items():
        if not isinstance(v, dict):
            continue
        for sub, raw in v.items():
            source = UPGRADE_SOURCES.get(sub) or (sub if sub in talents else None)
            if source:
                out.setdefault(k, {})[source] = raw
    return out


def amount(raw):
    """The level-1 size of an operation as shown in a label: "+-10" -> "10"."""
    tok = str(raw).split()[0] if str(raw).split() else "0"
    tok = tok.lstrip("+x=").lstrip("-").rstrip("%")
    try:
        return f"{float(tok):g}"
    except ValueError:
        return tok


def talent_label(template, own, links, name):
    def fill(m):
        key = m.group(1)
        if key == "value" and own is not None:
            return amount(own)
        if key.startswith("bonus_") and key[6:] in links:
            return amount(links[key[6:]])
        raise SystemExit(f"talent {name}: label refers to {key}, which is not in the data")
    text = re.sub(r"\{s:([A-Za-z0-9_]+)\}", fill, template or name)
    return re.sub(r"<[^>]+>", "", text).strip()


def own_value(d):
    v = (d.get("AbilityValues") or {}).get("value")
    if isinstance(v, dict):
        v = v.get("value")
    return v


def talents_of(root, defs, abilities_kv, tokens, name_of):
    start = int(root.get("AbilityTalentStart", "10"))
    names = [root.get(f"Ability{i}") for i in range(start, start + 8)]
    if not all(names) or not all(n.startswith("special_bonus") for n in names):
        raise SystemExit(f"{name_of}: unexpected talent slots {names}")
    out = []
    for i, n in enumerate(names):
        d = defs.get(n) or abilities_kv.get(n) or {}
        links = {}
        for ad in defs.values():
            if isinstance(ad, dict):
                for k, v in (ad.get("AbilityValues") or {}).items():
                    if isinstance(v, dict) and n in v:
                        links.setdefault(k, v[n])
        t = {"name": n, "tier": i // 2 + 1, "side": "right" if i % 2 == 0 else "left"}
        own = own_value(d)
        m = GENERIC.match(n)
        if m and own is not None:
            t["stat"] = {prop: round(float(str(own).split()[0]) * scale, 4)
                         for prop, scale in TALENT_STATS[m.group(1)]}
        elif not links:
            raise SystemExit(f"{name_of}: talent {n} is neither a known stat nor linked to an ability value")
        template = tokens.get(f"DOTA_Tooltip_ability_{n}", tokens.get(f"DOTA_Tooltip_Ability_{n}"))
        t["label"] = talent_label(template, own, links, n)
        out.append(t)
    return out


def attribute_bonus(abilities_kv):
    d = abilities_kv.get("special_bonus_attributes") or {}
    value = own_value(d) or (d.get("AbilityValues") or {}).get("value")
    if not value:
        raise SystemExit("special_bonus_attributes has no values")
    return {"value": value, "max": int(d.get("MaxLevel", "1")), "required": int(d.get("RequiredLevel", "1")),
            "between": int(d.get("LevelsBetweenUpgrades", "2"))}


def main(data_dir, out_path):
    npc = os.path.join(data_dir, "scripts", "npc")
    base = kv.load(os.path.join(npc, "npc_heroes.txt"))["DOTAHeroes"].get("npc_dota_hero_base", {})
    abilities_kv = kv.load(os.path.join(npc, "npc_abilities.txt"))["DOTAAbilities"]
    names = kv.load(os.path.join(data_dir, "resource", "localization", "abilities_english.txt"))
    tokens = names.get("lang", {}).get("Tokens", {})
    hero_names = kv.load(os.path.join(data_dir, "resource", "localization", "dota_english.txt"))
    hero_tokens = hero_names.get("lang", {}).get("Tokens", {})
    attrs = attribute_bonus(abilities_kv)

    result = {}
    for h in HEROES:
        full = f"npc_dota_hero_{h}"
        root = kv.load(os.path.join(npc, "heroes", f"{full}.txt"))["DOTAHeroes"][full]
        defs = root.get("AbilityDefinitions", {})
        stats = {k: root.get(k, base.get(k)) for k in STAT_KEYS}
        talents = talents_of(root, defs, abilities_kv, tokens, h)
        talent_names = {t["name"] for t in talents}
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
            bonus = bonus_of(d.get("AbilityValues"), talent_names)
            if bonus:
                ab["bonus"] = bonus
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
                     "abilities": abilities, "unslotted": extra, "bot": bot,
                     "talents": talents, "attribute_bonus": attrs}

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
            tag += "SCEPTER " if a.get("IsGrantedByScepter") == "1" else ""
            tag += "SHARD " if a.get("IsGrantedByShard") == "1" else ""
            print(f"  [{a['slot']}] {tag}{a['title'] or a['name']} <{a['name']}> {beh}")
        for t in info["talents"]:
            print(f"  talent {t['tier']} {t['side']:5} {t['label']} <{t['name']}>")
        if info["unslotted"]:
            print("  unslotted:", ", ".join(info["unslotted"]))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
