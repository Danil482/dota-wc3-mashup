"""Extract the mashup's Dota 2 items into src/data/items.json.

Input is the dev-reference KV from the player's patch (research/dota_data,
see extract_dota_data.py). Only numbers, recipes and English item names are
kept; the descriptions below are our own short wording, never Valve text.

items.json (read by tools/gen_objects.py and by Lua as use("data.items")):
  items[name]  title, cost, shop, stats (summed passive props, fractions for
               percentages), values (raw Dota AbilityValues, "a b c" per
               level), cooldown, mana, range, channel, charges, stack,
               consumable, stock, available_at (game clock seconds it is sold
               from), recipe {cost, scroll, parts[[...]]}, desc,
               secret (sold only at a Secret Shop), shareable (allies may use
               it: Dota's ITEM_FULLY_SHAREABLE)
  items["item_recipe_<x>"]  the recipe scroll: title, cost, shop, result
  shops[]      {key, title, items[]}: one WC3 shop unit each, 11 entries max
               (button 0,0 is the shop's select-hero button)
  icons[]      {key, kind, sources}: launcher icon plan, BTNDota_<key>.blp
  notes        patch differences and simplifications

Usage: extract_items.py [research/dota_data] [src/data/items.json]
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kv  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOP_SIZE = 11

# One shop unit per entry, mirroring Dota's shop tabs. Recipe scrolls sit
# next to the item they complete.
SHOPS = [
    ("consumables", "Consumables", [
        "item_tpscroll", "item_ward_observer", "item_ward_sentry", "item_tango", "item_flask",
        "item_clarity", "item_faerie_fire", "item_enchanted_mango", "item_dust", "item_branches",
        "item_magic_stick"]),
    ("attributes", "Attributes", [
        "item_gauntlets", "item_slippers", "item_mantle", "item_circlet", "item_crown",
        "item_belt_of_strength", "item_boots_of_elves", "item_robe", "item_ogre_axe",
        "item_blade_of_alacrity", "item_staff_of_wizardry"]),
    ("equipment", "Equipment", [
        "item_quelling_blade", "item_ring_of_protection", "item_blight_stone", "item_blades_of_attack",
        "item_gloves", "item_chainmail", "item_splintmail", "item_broadsword", "item_claymore",
        "item_javelin", "item_mithril_hammer"]),
    ("misc", "Miscellaneous", [
        "item_ring_of_regen", "item_sobi_mask", "item_wind_lace", "item_fluffy_hat", "item_wizard_hat",
        "item_boots", "item_cloak", "item_lifesteal", "item_chasm_stone", "item_blitz_knuckles",
        "item_blink"]),
    ("secret", "Secret Shop", [
        "item_ring_of_health", "item_void_stone", "item_energy_booster", "item_vitality_booster",
        "item_point_booster", "item_platemail", "item_talisman_of_evasion", "item_hyperstone",
        "item_ring_of_tarrasque", "item_tiara_of_selemene", "item_diadem"]),
    ("relics", "Relics", [
        "item_ultimate_orb", "item_demon_edge", "item_mystic_staff", "item_reaver", "item_eagle",
        "item_relic", "item_refresher", "item_recipe_refresher", "item_sheepstick",
        "item_recipe_sheepstick", "item_aghanims_shard"]),
    ("accessories", "Accessories", [
        "item_magic_wand", "item_recipe_magic_wand", "item_bracer", "item_recipe_bracer",
        "item_wraith_band", "item_recipe_wraith_band", "item_null_talisman",
        "item_recipe_null_talisman", "item_power_treads", "item_phase_boots", "item_pers"]),
    ("support", "Support", [
        "item_ring_of_basilius", "item_recipe_ring_of_basilius", "item_headdress",
        "item_recipe_headdress", "item_buckler", "item_recipe_buckler", "item_arcane_boots",
        "item_recipe_arcane_boots", "item_mekansm", "item_recipe_mekansm"]),
    ("magical", "Magical", [
        "item_force_staff", "item_recipe_force_staff", "item_cyclone", "item_recipe_cyclone",
        "item_aether_lens", "item_recipe_aether_lens", "item_dagon", "item_recipe_dagon",
        "item_kaya", "item_recipe_kaya", "item_ultimate_scepter"]),
    ("armor", "Armor", [
        "item_hand_of_midas", "item_recipe_hand_of_midas", "item_black_king_bar",
        "item_recipe_black_king_bar", "item_heart", "item_recipe_heart", "item_assault",
        "item_recipe_assault", "item_shivas_guard", "item_recipe_shivas_guard"]),
    ("weapons", "Weapons", [
        "item_lesser_crit", "item_recipe_lesser_crit", "item_greater_crit", "item_recipe_greater_crit",
        "item_basher", "item_recipe_basher", "item_monkey_king_bar", "item_recipe_monkey_king_bar",
        "item_bfury", "item_recipe_bfury", "item_desolator"]),
    ("artifacts", "Artifacts", [
        "item_sange", "item_recipe_sange", "item_yasha", "item_recipe_yasha", "item_sange_and_yasha",
        "item_manta", "item_recipe_manta", "item_butterfly", "item_radiance", "item_satanic"]),
]


def all3(key):
    return {"str": key, "agi": key, "int": key}


PCT = 0.01
# Passive props each item adds (Lua sums them into one "items" modifier).
# A value key, or (key, scale) for percentages. Special keys handled in Lua:
# boots_ms (boots: highest pair counts), lace_ms (Wind Lace family, highest),
# yasha_pct (Yasha family movement %, highest), evasion (multiplicative),
# attack_speed_pct, max_mana_pct, hp_regen_amp, mana_regen_amp, cast_range,
# damage_melee / damage_ranged, boots_ms_melee.
STATS = {
    "item_faerie_fire": {"damage": "bonus_damage"},
    "item_enchanted_mango": {"hp_regen": "hp_regen"},
    "item_branches": all3("bonus_all_stats"),
    "item_gauntlets": {"str": "bonus_strength"},
    "item_slippers": {"agi": "bonus_agility"},
    "item_mantle": {"int": "bonus_intellect"},
    "item_circlet": all3("bonus_all_stats"),
    "item_crown": all3("bonus_all_stats"),
    "item_diadem": all3("bonus_all_stats"),
    "item_belt_of_strength": {"str": "bonus_strength"},
    "item_boots_of_elves": {"agi": "bonus_agility"},
    "item_robe": {"int": "bonus_intellect"},
    "item_ogre_axe": {"str": "bonus_strength"},
    "item_blade_of_alacrity": {"agi": "bonus_agility"},
    "item_staff_of_wizardry": {"int": "bonus_intellect"},
    "item_ring_of_protection": {"armor": "bonus_armor"},
    "item_blades_of_attack": {"damage": "bonus_damage"},
    "item_broadsword": {"damage": "bonus_damage"},
    "item_claymore": {"damage": "bonus_damage"},
    "item_mithril_hammer": {"damage": "bonus_damage"},
    "item_chainmail": {"armor": "bonus_armor"},
    "item_splintmail": {"armor": "bonus_armor"},
    "item_platemail": {"armor": "bonus_armor"},
    "item_gloves": {"attack_speed": "bonus_attack_speed"},
    "item_blitz_knuckles": {"attack_speed": "bonus_attack_speed"},
    "item_boots": {"boots_ms": "bonus_movement_speed"},
    "item_ring_of_regen": {"hp_regen": "bonus_health_regen"},
    "item_sobi_mask": {"mana_regen": "bonus_mana_regen"},
    "item_void_stone": {"mana_regen": "bonus_mana_regen"},
    "item_tiara_of_selemene": {"mana_regen": "bonus_mana_regen"},
    "item_energy_booster": {"max_mana": "bonus_mana"},
    "item_wizard_hat": {"max_mana": "bonus_mana"},
    "item_vitality_booster": {"max_hp": "bonus_health"},
    "item_fluffy_hat": {"max_hp": "bonus_health"},
    "item_point_booster": {"max_hp": "bonus_health", "max_mana": "bonus_mana"},
    "item_ultimate_orb": all3("bonus_all_stats"),
    "item_demon_edge": {"damage": "bonus_damage"},
    "item_eagle": {"agi": "bonus_agility"},
    "item_reaver": {"str": "bonus_strength"},
    "item_mystic_staff": {"int": "bonus_intellect"},
    "item_hyperstone": {"attack_speed": "bonus_attack_speed"},
    "item_cloak": {"magic_resist": ("bonus_magical_armor", PCT)},
    "item_relic": {"damage": "bonus_damage"},
    "item_ring_of_health": {"hp_regen": "bonus_health_regen"},
    "item_ring_of_tarrasque": {"hp_regen": "bonus_health_regen"},
    "item_wind_lace": {"lace_ms": "movement_speed"},
    "item_talisman_of_evasion": {"evasion": ("bonus_evasion", PCT)},
    "item_lifesteal": {"lifesteal": ("lifesteal_percent", PCT)},
    "item_chasm_stone": {"max_hp": "bonus_health"},
    "item_magic_wand": all3("bonus_all_stats"),
    "item_bracer": {"str": "bonus_strength", "agi": "bonus_agility", "int": "bonus_intellect",
                    "damage": "bonus_damage", "hp_regen": "bonus_health_regen", "max_hp": "bonus_health"},
    "item_wraith_band": {"agi": "bonus_agility", "str": "bonus_strength", "int": "bonus_intellect",
                         "attack_speed": "bonus_attack_speed", "armor": "bonus_armor"},
    "item_null_talisman": {"int": "bonus_intellect", "str": "bonus_strength", "agi": "bonus_agility",
                           "mana_regen": "bonus_mana_regen",
                           "max_mana_pct": ("bonus_max_mana_percentage", PCT)},
    "item_power_treads": {"attack_speed": "bonus_attack_speed", "damage": "bonus_damage",
                          "boots_ms": "bonus_movement_speed_ranged",
                          "boots_ms_melee": "bonus_movement_speed_melee"},
    "item_phase_boots": {"boots_ms": "bonus_movement_speed", "armor": "bonus_armor",
                         "attack_speed": "bonus_attack_speed", "damage_melee": "bonus_damage_melee",
                         "damage_ranged": "bonus_damage_range"},
    "item_arcane_boots": {"boots_ms": "bonus_movement", "max_mana": "bonus_mana", "mana_regen": "mana_regen"},
    "item_ring_of_basilius": {"mana_regen": "mana_regen"},
    "item_headdress": {"hp_regen": "health_regen"},
    "item_buckler": {"armor": "armor"},
    "item_mekansm": {"armor": "bonus_armor"},
    "item_pers": {"hp_regen": "bonus_health_regen", "mana_regen": "bonus_mana_regen"},
    "item_lesser_crit": {"damage": "bonus_damage"},
    "item_greater_crit": {"damage": "bonus_damage"},
    "item_sange": {"str": "bonus_strength", "hp_regen_amp": ("hp_regen_amp", PCT)},
    "item_yasha": {"agi": "bonus_agility", "attack_speed": "bonus_attack_speed",
                   "yasha_pct": ("movement_speed_percent_bonus", PCT)},
    "item_sange_and_yasha": {"str": "bonus_strength", "agi": "bonus_agility",
                             "attack_speed": "bonus_attack_speed",
                             "yasha_pct": ("movement_speed_percent_bonus", PCT),
                             "hp_regen_amp": ("hp_regen_amp", PCT)},
    "item_manta": {"str": "bonus_strength", "agi": "bonus_agility", "int": "bonus_intellect",
                   "attack_speed": "bonus_attack_speed", "yasha_pct": ("bonus_movement_speed", PCT)},
    "item_kaya": {"int": "bonus_intellect", "spell_amp": ("spell_amp", PCT),
                  "mana_regen_amp": ("mana_regen_multiplier", PCT)},
    "item_aether_lens": {"max_mana": "bonus_mana", "mana_regen": "bonus_mana_regen",
                         "cast_range": "cast_range_bonus"},
    "item_black_king_bar": {"str": "bonus_strength", "damage": "bonus_damage"},
    "item_force_staff": {"int": "bonus_intellect", "max_hp": "bonus_health"},
    "item_cyclone": {"int": "bonus_intellect", "mana_regen": "bonus_mana_regen", "lace_ms": "bonus_movement_speed"},
    "item_desolator": {"damage": "bonus_damage"},
    "item_butterfly": {"agi": "bonus_agility", "damage": "bonus_damage", "evasion": ("bonus_evasion", PCT),
                       "attack_speed_pct": ("bonus_attack_speed_pct", PCT)},
    "item_heart": {"str": "bonus_strength"},
    "item_assault": {"attack_speed": "bonus_attack_speed", "armor": "bonus_armor"},
    "item_bfury": {"damage": "bonus_damage", "hp_regen": "bonus_health_regen", "mana_regen": "bonus_mana_regen"},
    "item_basher": {"damage": "bonus_damage", "str": "bonus_strength"},
    "item_monkey_king_bar": {"damage": "bonus_damage", "attack_speed": "bonus_attack_speed"},
    "item_dagon": dict(all3("bonus_all_stats"), max_hp="bonus_health", max_mana="bonus_mana",
                       cast_range="cast_range_bonus"),
    "item_hand_of_midas": {"attack_speed": "bonus_attack_speed"},
    "item_refresher": {"hp_regen": "bonus_health_regen", "mana_regen": "bonus_mana_regen", "damage": "bonus_damage"},
    "item_sheepstick": {"int": "bonus_intellect", "mana_regen": "bonus_mana_regen"},
    "item_shivas_guard": {"armor": "bonus_armor", "hp_regen": "bonus_hp_regen"},
    "item_radiance": {"damage": "bonus_damage", "evasion": ("evasion", PCT)},
    "item_satanic": {"str": "bonus_strength", "damage": "bonus_damage", "lifesteal": ("lifesteal_percent", PCT)},
    "item_ultimate_scepter": dict(all3("bonus_all_stats"), max_hp="bonus_health", max_mana="bonus_mana"),
}

# Our own short descriptions. {key} is the level-1 Dota value, {-key} its
# negation (for armor and slow values stored as negatives).
DESC = {
    "item_tpscroll": "Channel for {AbilityChannelTime} seconds, then teleport next to the friendly building "
                     "nearest to the target point.",
    "item_ward_observer": "Plants an invisible ward that watches a {vision_range_tooltip} radius for {lifetime} seconds.",
    "item_ward_sentry": "Plants an invisible ward that exposes invisible enemies within {true_sight_range} for "
                        "{lifetime} seconds. It gives no vision by itself.",
    "item_tango": "Eat a tree to regenerate {health_regen} health per second for {buff_duration} seconds.",
    "item_flask": "Regenerates {health_regen} health per second for {buff_duration} seconds (half on an ally). "
                  "Damage from an enemy hero ends it.",
    "item_clarity": "Regenerates {mana_regen} mana per second for {buff_duration} seconds. Damage from an enemy "
                    "hero ends it.",
    "item_faerie_fire": "Use to heal {hp_restore} health at once.",
    "item_enchanted_mango": "Use to restore {replenish_amount} mana at once.",
    "item_dust": "Exposes and slows ({-movespeed}%) invisible enemy heroes within {radius} of where you stand for "
                 "{duration} seconds.",
    "item_branches": "A cheap twig with a little of every attribute.",
    "item_magic_stick": "Gains a charge (up to {max_charges}) when a visible enemy hero within {charge_radius} casts "
                        "a spell. Use to restore {restore_per_charge} health and mana per charge.",
    "item_magic_wand": "Gains a charge (up to {max_charges}) when a visible enemy hero within {charge_radius} casts "
                       "a spell. Use to restore {restore_per_charge} health and mana per charge.",
    "item_quelling_blade": "+{damage_bonus} attack damage against non-hero units ({damage_bonus_ranged} for ranged "
                           "heroes). Use on a tree to cut it down.",
    "item_blight_stone": "Attacks strip {-corruption_armor} armor from the target for {corruption_duration} seconds.",
    "item_javelin": "Attacks have a {bonus_chance}% chance to deal {bonus_chance_damage} extra magic damage and "
                    "cannot be evaded when that happens.",
    "item_boots": "Pairs of boots do not add up: only the fastest counts.",
    "item_wind_lace": "Light shoes that stack with boots but not with Eul's Scepter.",
    "item_cloak": "Shrugs off part of all magic damage.",
    "item_talisman_of_evasion": "Gives a chance to dodge attacks.",
    "item_lifesteal": "Attacks heal you for part of the damage they deal.",
    "item_chasm_stone": "Component of Shiva's Guard. Its area bonus is not modelled in this map.",
    "item_blink": "Teleports you up to {blink_range} away; farther targets land you {blink_range_clamp} away. Locked "
                  "for {blink_damage_cooldown} seconds after an enemy hero damages you.",
    "item_ring_of_basilius": "Allies within {aura_radius} regenerate {aura_mana_regen} extra mana per second.",
    "item_headdress": "Allies within {aura_radius} regenerate {aura_health_regen} extra health per second.",
    "item_buckler": "Allies within {bonus_aoe_radius} gain {bonus_aoe_armor} armor.",
    "item_null_talisman": "Also raises maximum mana by {bonus_max_mana_percentage}%.",
    "item_power_treads": "Use to move the +{bonus_stat} attribute between Strength, Intelligence and Agility. "
                         "Pairs of boots do not add up.",
    "item_phase_boots": "Use for {phase_movement_speed}% more speed ({phase_movement_speed_range}% ranged) and to "
                        "walk through units for {phase_duration} seconds. Pairs of boots do not add up.",
    "item_arcane_boots": "Use to restore {replenish_amount} mana to allies within {replenish_radius}. Allies nearby "
                         "regenerate {aura_mana_regen} extra mana per second.",
    "item_mekansm": "Use to heal allied units within {heal_radius} for {heal_amount}. Allies nearby regenerate "
                    "{aura_health_regen} extra health per second.",
    "item_lesser_crit": "Attacks have a {crit_chance}% chance to hit for {crit_multiplier}% damage.",
    "item_greater_crit": "Attacks have a {crit_chance}% chance to hit for {crit_multiplier}% damage.",
    "item_sange": "Strength and {hp_regen_amp}% stronger health regeneration.",
    "item_yasha": "Agility, attack speed and {movement_speed_percent_bonus}% movement speed (Yasha items do not "
                  "add up).",
    "item_sange_and_yasha": "Strength, agility, attack speed, {movement_speed_percent_bonus}% movement speed and "
                            "{hp_regen_amp}% stronger health regeneration.",
    "item_manta": "Use to split into {images_count} illusions for {illusion_duration} seconds and drop most "
                  "debuffs. Illusions deal {tooltip_damage_outgoing_melee}% damage ({tooltip_damage_outgoing_ranged}% "
                  "ranged) and take {tooltip_damage_incoming_total_pct}% damage.",
    "item_kaya": "{spell_amp}% more spell damage and {mana_regen_multiplier}% stronger mana regeneration.",
    "item_aether_lens": "+{cast_range_bonus} cast range for your hero spells.",
    "item_black_king_bar": "Use to become immune to magic and drop most debuffs for {duration} seconds; each use "
                           "lasts one second less, down to 7.",
    "item_force_staff": "Use to shove any unit {push_length} units in the direction it faces.",
    "item_cyclone": "Use on an enemy or yourself: the target is lifted for {cyclone_duration} seconds and can neither "
                    "act nor be hurt. Enemies take {tooltip_drop_damage} magic damage on landing.",
    "item_desolator": "Attacks strip {-corruption_armor} armor for {corruption_duration} seconds. Gains "
                      "{bonus_damage_per_kill} damage per hero kill, up to {max_damage}.",
    "item_butterfly": "{bonus_evasion}% evasion and {bonus_attack_speed_pct}% more attack speed.",
    "item_heart": "Regenerates {hp_regen}% of maximum health plus {missing_health_regen}% of missing health every "
                  "second.",
    "item_assault": "Allies and buildings within {aura_radius} gain {aura_attack_speed} attack speed and "
                    "{aura_positive_armor} armor; enemies there lose {-aura_negative_armor} armor.",
    "item_bfury": "Melee attacks cleave {cleave_damage_percent}% damage ({cleave_damage_percent_creep}% to creeps) in a "
                  "cone behind the target. +{quelling_bonus} damage against non-heroes. Use on a tree to cut it.",
    "item_basher": "Attacks have a {bash_chance_melee}% chance ({bash_chance_ranged}% ranged) to stun for "
                   "{bash_duration} seconds and deal {bonus_chance_damage} extra damage. Once per {bash_cooldown} "
                   "seconds.",
    "item_monkey_king_bar": "Attacks have an {bonus_chance}% chance to deal {bonus_chance_damage} extra magic damage "
                            "and cannot be evaded when that happens.",
    "item_dagon": "Use to blast an enemy for {damage} magic damage.",
    "item_hand_of_midas": "Use on a non-hero, non-ancient enemy to turn it into {bonus_gold} gold. Holds up to "
                          "{charges_max} charges; one returns every {charge_restore} seconds.",
    "item_refresher": "Use to reset the cooldowns of your hero abilities. Items keep their cooldowns.",
    "item_sheepstick": "Use to turn an enemy into a harmless critter for {sheep_duration} seconds.",
    "item_shivas_guard": "Use to send out a frost wave ({blast_radius} radius) that deals {blast_damage} magic damage "
                         "and slows by {-blast_movement_speed}% for {blast_debuff_duration} seconds. Enemies within "
                         "{aura_radius} lose {-aura_attack_speed} attack speed.",
    "item_radiance": "Burns enemies within {aura_radius} for {aura_damage} magic damage per second (always on).",
    "item_satanic": "Use to raise lifesteal to {unholy_lifesteal_total_tooltip}% for {unholy_duration} seconds and "
                    "drop most debuffs.",
    "item_ultimate_scepter": "Upgrades your hero's abilities while you carry it in the main inventory (the Aghanim's "
                             "sign next to the ability row shows how).",
    "item_aghanims_shard": "Consumed at once: upgrades your hero's abilities for the rest of the game, once per hero "
                           "(the Aghanim's sign next to the ability row shows how).",
}

# Dota's ItemInitialStockTime counts from the start of the 90 s before the
# horn: Aghanim's Shard has 990 there and arrives at 15:00 on the game clock
# (https://liquipedia.net/dota2/Aghanim%27s_Shard, "availability 900").
PRE_HORN = 90

NOTES = {
    "patch": "All 78 requested items exist in the installed patch. Recipes follow it: Arcane Boots use Ring of "
             "Basilius + Wizard Hat, Shiva's Guard uses Splintmail + Chasm Stone, Refresher Orb uses Ring of "
             "Tarrasque + Tiara of Selemene, Manta uses Diadem, Dagon uses Crown + Wizard Hat. Their components "
             "are sold too.",
    "simplified": "Radiance burns permanently (no toggle). BKB gives full magic immunity (the patch gives 60% magic "
                  "resistance plus debuff immunity). Status resistance, slow resistance, Chasm Stone area bonus, "
                  "Monkey King Bar melee range and Iron Branch tree planting are not modelled.",
    "storage": "As in Dota: 6 main slots, a 3-slot backpack, a 6-slot stash, the TP scroll slot and a courier per "
               "player (src/game/inventory.lua, courier.lua). Secret items are sold only at the Secret Shops "
               "(mapdata.side_shops).",
}


def flat_values(block):
    out = {}
    for k, v in (block or {}).items():
        out[k] = v["value"] if isinstance(v, dict) and "value" in v else v
    return out


def first(raw):
    """Level-1 number of a Dota value string such as "9 8 7"; None if absent."""
    if raw is None:
        return None
    parts = str(raw).split()
    if not parts:
        return None
    try:
        return float(parts[0])
    except ValueError:
        return None


def num(v):
    return int(v) if v is not None and float(v).is_integer() else v


def title_of(tokens, name):
    for key in (f"DOTA_Tooltip_ability_{name}", f"DOTA_Tooltip_Ability_{name}", f"DOTA_Tooltip_ability_{name}:n"):
        if tokens.get(key):
            return tokens[key]
    raise SystemExit(f"no English name for {name}")


def fmt_desc(template, values):
    out, i = [], 0
    while i < len(template):
        j = template.find("{", i)
        if j < 0:
            out.append(template[i:])
            break
        k = template.find("}", j)
        out.append(template[i:j])
        key = template[j + 1:k]
        neg = key.startswith("-")
        v = first(values.get(key.lstrip("-")))
        if v is None:
            raise SystemExit(f"description refers to missing value {key}")
        out.append(f"{-v if neg else v:g}")
        i = k + 1
    return "".join(out)


def main(data_dir, out_path):
    raw = kv.load(os.path.join(data_dir, "scripts", "npc", "items.txt"))["DOTAAbilities"]
    tokens = kv.load(os.path.join(data_dir, "resource", "localization", "abilities_english.txt"))["lang"]["Tokens"]
    recipes = {v["ItemResult"]: (k, v) for k, v in raw.items()
               if isinstance(v, dict) and v.get("ItemRecipe") == "1" and v.get("ItemResult")}

    shop_of, order = {}, []
    for key, _, names in SHOPS:
        if len(names) > SHOP_SIZE:
            raise SystemExit(f"shop {key} has {len(names)} entries (max {SHOP_SIZE})")
        for n in names:
            if n in shop_of:
                raise SystemExit(f"{n} is in two shops")
            shop_of[n] = key
            order.append(n)
    chosen = [n for n in order if not n.startswith("item_recipe_")]
    scrolls = [n for n in order if n.startswith("item_recipe_")]

    items = {}
    for name in chosen:
        d = raw.get(name)
        if d is None:
            raise SystemExit(f"{name} is not in this patch")
        values = flat_values(d.get("AbilityValues"))
        if d.get("AbilityCharges"):
            values["charges_max"] = d["AbilityCharges"]
            values["charge_restore"] = d.get("AbilityChargeRestoreTime", "0")
        if d.get("AbilityChannelTime"):
            values["AbilityChannelTime"] = d["AbilityChannelTime"]
        e = {"title": title_of(tokens, name), "cost": int(d.get("ItemCost", "0")), "shop": shop_of[name],
             "values": values}
        for field, key in (("cooldown", "AbilityCooldown"), ("mana", "AbilityManaCost"),
                           ("range", "AbilityCastRange"), ("channel", "AbilityChannelTime")):
            v = first(d.get(key))
            if v:
                e[field] = num(v)
        if d.get("ItemPermanent") == "0":
            e["consumable"] = True
            e["charges"] = int(d.get("ItemInitialCharges", "1"))
            e["stack"] = d.get("ItemStackable") == "1"
        if d.get("SecretShop") == "1":
            e["secret"] = True
        if d.get("ItemShareability") == "ITEM_FULLY_SHAREABLE":
            e["shareable"] = True
        if d.get("ItemInitialStockTime"):
            # sold from this game time on; its 1 s restock never runs out
            e["available_at"] = num(float(d["ItemInitialStockTime"]) - PRE_HORN)
        elif d.get("ItemStockMax"):
            e["stock"] = {"max": int(d["ItemStockMax"]), "initial": int(d.get("ItemStockInitial", d["ItemStockMax"])),
                          "time": num(float(d.get("ItemStockTime", "0")))}
        stats = {}
        for prop, spec in STATS.get(name, {}).items():
            key, scale = spec if isinstance(spec, tuple) else (spec, 1)
            v = first(values.get(key))
            if v is None:
                raise SystemExit(f"{name}: stat {prop} needs missing value {key}")
            if v:
                stats[prop] = num(round(v * scale, 4))
        if stats:
            e["stats"] = stats
        if name in DESC:
            e["desc"] = fmt_desc(DESC[name], values)
        r = recipes.get(name)
        if r:
            rkey, rv = r
            alts = []
            for _, req in sorted((rv.get("ItemRequirements") or {}).items()):
                alts.append([p.strip().rstrip("*") for p in req.split(";") if p.strip()])
            rc = {"cost": int(rv.get("ItemCost", "0")), "parts": alts}
            if rc["cost"] > 0:
                rc["scroll"] = rkey
                if rkey not in scrolls:
                    raise SystemExit(f"recipe scroll {rkey} is not in any shop")
            e["recipe"] = rc
        items[name] = e

    for scroll in scrolls:
        result = scroll.replace("item_recipe_", "item_", 1)
        if scroll != items.get(result, {}).get("recipe", {}).get("scroll"):
            raise SystemExit(f"{scroll} does not match a chosen item")
        items[scroll] = {"title": "Recipe: " + items[result]["title"], "cost": items[result]["recipe"]["cost"],
                         "shop": shop_of[scroll], "result": result}

    # every component is sold, and every recipe adds up to the item's cost
    def full_cost(n):
        r = items[n].get("recipe")
        if not r:
            return items[n]["cost"]
        return sum(full_cost(p) for p in r["parts"][0]) + r["cost"]

    for n in chosen:
        r = items[n].get("recipe")
        if not r:
            continue
        for alt in r["parts"]:
            for p in alt:
                if p not in items:
                    raise SystemExit(f"{n} needs {p}, which no shop sells")
        if full_cost(n) != items[n]["cost"]:
            raise SystemExit(f"{n}: parts add up to {full_cost(n)}, item costs {items[n]['cost']}")

    icons = [{"key": n, "kind": "item", "sources": [f"panorama/images/items/{n[5:]}_png.vtex_c"]} for n in chosen]
    icons.append({"key": "item_recipe", "kind": "item", "sources": ["panorama/images/items/recipe_png.vtex_c"]})
    for attr in ("str", "agi", "int"):
        icons.append({"key": f"item_power_treads_{attr}", "kind": "item",
                      "sources": [f"panorama/images/items/power_treads_{attr}_png.vtex_c"]})

    out = {"items": items, "shops": [{"key": k, "title": t, "items": n} for k, t, n in SHOPS],
           "icons": icons, "notes": NOTES}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
    upgrades = sum(1 for n in chosen if items[n].get("recipe"))
    print(f"items.json: {len(chosen)} items ({upgrades} with recipes), {len(scrolls)} recipe scrolls, "
          f"{len(SHOPS)} shops, {len(icons)} icons")


if __name__ == "__main__":
    args = sys.argv[1:]
    main(args[0] if args else os.path.join(ROOT, "research", "dota_data"),
         args[1] if len(args) > 1 else os.path.join(ROOT, "src", "data", "items.json"))
