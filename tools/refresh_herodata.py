"""Copy research/heroes.json into src/data/heroes.json (numbers and names only),
with the hero display names below and our own short descriptions of each hero's
Aghanim's Scepter and Shard upgrades ("upgrades"; Valve's tooltips are not
copied). In a description, {ability:key:source} is the size of that value's
upgrade from the data (source "scepter" or "shard"), {ability:key} its base."""
import json
import os
import re

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TITLES = {"pudge": "Pudge", "meepo": "Meepo", "tinker": "Tinker", "rubick": "Rubick",
          "morphling": "Morphling", "furion": "Nature's Prophet", "chen": "Chen",
          "antimage": "Anti-Mage", "techies": "Techies", "ogre_magi": "Ogre Magi",
          "nevermore": "Shadow Fiend"}

UPGRADES = {
    "pudge": {
        "scepter": "Rot: +{pudge_rot:rot_radius:scepter} radius, +{pudge_rot:rot_damage:scepter} damage per second, "
                   "and enemies in it get {pudge_rot:scepter_rot_regen_reduction_pct:scepter}% less health "
                   "restoration.",
        "shard": "Meat Hook deals extra damage the farther away it catches an enemy. Hooking an ally cuts its "
                 "cooldown by {pudge_meat_hook:cooldown_reduction_pct_allied_hook:shard}%.",
    },
    "meepo": {
        "scepter": "Grants MegaMeepo: Meepo lifts the clones around him onto his shoulders, gains part of their "
                   "attributes and flings them at enemies.",
        "shard": "Grants Dig: a Meepo burrows into the ground, invulnerable and out of sight, and heals while it "
                 "stays there.",
    },
    "tinker": {
        "scepter": "Laser also strips {tinker_laser:scepter_reduction_pct:scepter}% of the target's current and "
                   "maximum health (stacking). March of the Machines heals the allied heroes it passes. The time "
                   "between turret missiles drops by {tinker_deploy_turrets:missile_spawn_interval:scepter}s.",
        "shard": "Grants Warp Flare: a flare that hurts an enemy and warps it away from Tinker.",
    },
    "rubick": {
        "scepter": "Spell Steal reaches farther, and stolen spells come with their Aghanim's Scepter upgrade.",
        "shard": "Telekinesis can lift Rubick himself or an ally and throw them farther. Stolen spells come with "
                 "their Aghanim's Shard upgrade.",
    },
    "morphling": {
        "scepter": "Morph creates a strong illusion of the target hero instead, which casts its basic abilities; "
                   "Morph Replicate swaps Morphling into its place.",
        "shard": "Attribute Shift costs {morphling_morph_agi:mana_cost:shard}% less mana and can be switched while "
                 "disabled.",
    },
    "furion": {
        "scepter": "Wrath of Nature roots every enemy it hits, longer the more it has bounced.",
        "shard": "Grants Curse of the Oldgrowth.",
    },
    "chen": {
        "scepter": "Hand of God: -{chen_hand_of_god:AbilityCooldown:scepter}s cooldown, and Chen channels it: allies "
                   "around him shed debuffs, resist magic and heal faster.",
        "shard": "Holy Persuasion can take Ancient creeps and raises the abilities of the creeps it takes.",
    },
    "antimage": {
        "scepter": "Mana Break burns +{antimage_mana_break:mana_per_hit_pct:scepter}% maximum mana. After Blink, the "
                   "next Mana Break burns +{antimage_mana_break:empowered_max_burn_pct:scepter}% more and stops the "
                   "target's mana gain for {antimage_mana_break:empowered_mana_break_debuff_duration:scepter}s.",
        "shard": "Counterspell sends an image of Anti-Mage at the caster of each spell it reflects.",
    },
    "techies": {
        "scepter": "Grants Minefield Sign, which hurts enemies that walk near it. Proximity Mines get "
                   "+{techies_land_mines:cast_range_scepter_bonus:scepter} cast range.",
        "shard": "M.A.D. becomes a spell: Techies plants a charge that he sets off by hand, worth "
                 "+{techies_mutually_assured_destruction:max_mana_pct_as_damage:shard}% more of his maximum mana.",
    },
    "ogre_magi": {
        "scepter": "Grants Unrefined Fireblast, which costs a share of Ogre's current mana. Fireblast cooldown "
                   "-{ogre_magi_fireblast:AbilityCooldown:scepter}s and {ogre_magi_fireblast:bonus_cast_speed:scepter}% "
                   "faster cast.",
        "shard": "Grants Fire Shield: an ally absorbs most of the damage of the next attacks from enemy heroes, and "
                 "each absorbed attack throws a fireball back.",
    },
    "nevermore": {
        "scepter": "Requiem of Souls: -{nevermore_requiem:AbilityCooldown:scepter}s cooldown, and its souls fly back "
                   "to Shadow Fiend, healing him for the damage they dealt.",
        "shard": "Shadowraze slows (stacking), and every enemy hero it hits cuts its cooldown by "
                 "{nevermore_shadowraze1:cooldown_reduction_on_hero_hit:shard}s.",
    },
}


def amount(raw):
    tok = str(raw).split()[0] if str(raw).split() else "0"
    tok = tok.lstrip("+x=").lstrip("-").rstrip("%")
    return f"{float(tok):g}"


def describe(hero, text, abilities):
    def fill(m):
        ab = abilities.get(m.group(1))
        if ab is None:
            raise SystemExit(f"{hero}: upgrade text refers to unknown ability {m.group(1)}")
        key, source = m.group(2), m.group(3)
        if source:
            raw = (ab.get("bonus") or {}).get(key, {}).get(source)
        else:
            raw = (ab.get("values") or {}).get(key, ab.get(key))
        if raw is None:
            raise SystemExit(f"{hero}: upgrade text refers to {m.group(0)}, which is not in the data")
        return amount(raw)
    return re.sub(r"\{(\w+):(\w+)(?::(\w+))?\}", fill, text)


def main():
    with open(os.path.join(ROOT, "research", "heroes.json"), encoding="utf-8") as f:
        src = json.load(f)
    out = {}
    for h, v in src.items():
        abilities = {a["name"]: a for a in v["abilities"]}
        out[h] = {"id": v["id"], "title": TITLES[h], "stats": v["stats"], "abilities": v["abilities"],
                  "bot": v.get("bot", {}), "talents": v["talents"], "attribute_bonus": v["attribute_bonus"],
                  "upgrades": {kind: describe(h, text, abilities) for kind, text in UPGRADES[h].items()}}
    with open(os.path.join(ROOT, "src", "data", "heroes.json"), "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    missing = [a["name"] for v in out.values() for a in v["abilities"] if not a.get("title")]
    print(f"heroes.json: {len(out)} heroes; abilities without a title: {missing}")


if __name__ == "__main__":
    main()
