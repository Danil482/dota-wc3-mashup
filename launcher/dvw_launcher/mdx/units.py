"""Which Dota 2 model feeds which map unit, and how its animations map onto
Warcraft III sequence names.

Each unit names its Dota model, the default cosmetic items merged into it
(the default_item entries of scripts/items/items_game.txt, persona items
excluded) and a per-unit clip table. When a listed clip is missing (renamed by
a Dota update) the converter falls back to the Dota activity of the sequence
(from the model's ASEQ block), then to a name pattern; see SEQUENCES.

Scales are the Dota "ModelScale" values (scripts/npc); the converter keeps
geometry in Dota units, which match Warcraft III units closely, so the Dota
scale goes into the unit's scaling value (usca) in specs/models.json.
"""

HERO = "hero"
CREEP = "creep"
STRUCTURE = "structure"

# Cast animations of heroes: each Dota cast activity an ability names
# (AbilityCastAnimation, src/data/heroes.json) gets a sequence of its own,
# "Spell" plus a sub-animation tag the game knows (common.j SUBANIM_TYPE_*).
# tools/gen_objects.py gives the ability Art - Animation Names (aani) from
# cast_anim() below. The game plays the sequence whose name shares the most
# tags with the request, then the one with the fewest others (jassdoc,
# SetUnitAnimation), so a model without the tagged sequence plays "Spell": a
# WC3 stand-in, a Dota model without that clip, or one whose clip is the
# "Spell" clip and is left out. Stock WC3 relies on this too: Cluster Rockets
# asks for "spell,one" and the Goblin Tinker model has "Spell One".."Spell
# Three" and no "Spell". OVERRIDE_ABILITY_n and RAZE_n stand in for a missing
# CAST_ABILITY_n (Pudge's Meat Hook clip is OVERRIDE_ABILITY_1, Shadowraze is
# RAZE_1..3); no hero has abilities with both. Tags left: Fourth, Fifth.
CAST_SEQUENCES = [
    ("Spell One", ["ACT_DOTA_CAST_ABILITY_1", "ACT_DOTA_OVERRIDE_ABILITY_1", "ACT_DOTA_RAZE_1"]),
    ("Spell Two", ["ACT_DOTA_CAST_ABILITY_2", "ACT_DOTA_OVERRIDE_ABILITY_2", "ACT_DOTA_RAZE_2"]),
    ("Spell Three", ["ACT_DOTA_CAST_ABILITY_3", "ACT_DOTA_OVERRIDE_ABILITY_3", "ACT_DOTA_RAZE_3"]),
    ("Spell Four", ["ACT_DOTA_CAST_ABILITY_4"]),
    ("Spell Five", ["ACT_DOTA_CAST_ABILITY_5"]),
    ("Spell First", ["ACT_DOTA_CAST_ABILITY_6"]),
    ("Spell Second", ["ACT_DOTA_CAST_ABILITY_7"]),
    ("Spell Third", ["ACT_DOTA_OVERRIDE_ABILITY_4"]),
]
CAST_NAMES = {name for name, _acts in CAST_SEQUENCES}
CAST_TAGS = {act: name.split()[1].lower() for name, acts in CAST_SEQUENCES for act in acts}
CHANNEL_ACTIVITIES = ("ACT_DOTA_CHANNEL_ABILITY_", "ACT_DOTA_GENERIC_CHANNEL_")


def cast_anim(activity):
    """Art - Animation Names (aani) of an ability whose Dota cast activity is
    `activity` (None when Dota's data names none)."""
    if activity == "ACT_INVALID":
        return ""                          # Dota plays nothing
    if activity in CAST_TAGS:
        return "spell," + CAST_TAGS[activity]
    if activity and activity.startswith(CHANNEL_ACTIVITIES):
        return "spell,channel"
    return "spell"


# (WC3 sequence, Dota activities in preference order, name patterns, looping, rarity)
# Activities ending in "*" match any suffix. "Attack - 2" must differ from "Attack".
SEQUENCES = [
    ("Stand", ["ACT_DOTA_IDLE"], [r"^idle", r"idle", r"stand"], True, 0.0),
    ("Stand - 2", ["ACT_DOTA_IDLE_RARE"], [r"idle.*(alt|rare)", r"(alt|rare).*idle"], True, 4.0),
    ("Stand Ready", ["ACT_DOTA_IDLE"], [r"^idle", r"idle"], True, 0.0),
    ("Walk", ["ACT_DOTA_RUN"], [r"^run", r"run", r"walk"], True, 0.0),
    ("Attack", ["ACT_DOTA_ATTACK"], [r"^attack", r"attack"], False, 0.0),
    ("Attack - 2", ["ACT_DOTA_ATTACK2", "ACT_DOTA_ATTACK"], [r"attack"], False, 0.0),
    ("Spell", ["ACT_DOTA_CAST_ABILITY_1", "ACT_DOTA_CAST_ABILITY_2", "ACT_DOTA_CAST_ABILITY_3",
               "ACT_DOTA_OVERRIDE_ABILITY_1", "ACT_DOTA_CAST_ABILITY_4", "ACT_DOTA_CAST_ABILITY_5",
               "ACT_DOTA_CAST_ABILITY_6", "ACT_DOTA_CAST_ABILITY_*"], [r"^cast", r"cast"], False, 0.0),
    ("Spell Channel", ["ACT_DOTA_CHANNEL_ABILITY_*", "ACT_DOTA_GENERIC_CHANNEL_1", "ACT_DOTA_TELEPORT"],
     [r"channel", r"teleport"], True, 0.0),
] + [(name, acts, [], False, 0.0) for name, acts in CAST_SEQUENCES] + [
    # Dota's teleport channel, for the TP scroll (aani "stand,channel" in
    # tools/gen_objects.py item_active_fields; WC3's Archmage channels Blizzard so)
    ("Stand Channel", ["ACT_DOTA_TELEPORT"], [], True, 0.0),
    ("Death", ["ACT_DOTA_DIE"], [r"^death", r"^die", r"death|die"], False, 0.0),
    ("Birth", ["ACT_DOTA_SPAWN"], [r"^spawn", r"spawn"], False, 0.0),
    ("Stand Victory", ["ACT_DOTA_VICTORY"], [r"victory"], True, 0.0),
]
# Converted only for heroes, and only when a clip is found.
HERO_SEQUENCES = CAST_NAMES | {"Stand Channel"}
OPTIONAL = {"Stand - 2", "Attack - 2"} | HERO_SEQUENCES
SEQUENCE_NAMES = [s[0] for s in SEQUENCES]

# What a missing sequence becomes when neither the table, the activities nor
# the name patterns find a clip: another sequence's clip, or a synthesized
# motion ("rise" = come up out of the ground, "sink" = sink into it,
# "topple" = tip over and sink, "static" = the bind pose).
FALLBACKS = {
    "Stand": "static",
    "Stand Ready": "Stand",
    "Walk": "Stand",
    "Attack": "Stand",
    "Spell": "Attack",
    "Spell Channel": "Stand",
    "Death": "topple",
    "Birth": "rise",
    "Stand Victory": "Stand",
}


def _hero(model, items, scale, anims):
    return {"kind": HERO, "model": model, "items": items, "scale": scale, "anims": anims}


UNITS = {
    "hero_pudge": _hero(
        "models/heroes/pudge/pudge.vmdl",
        ["models/heroes/pudge/righthook.vmdl", "models/heroes/pudge/back.vmdl",
         "models/heroes/pudge/leftweapon.vmdl", "models/heroes/pudge/leftarm.vmdl",
         "models/heroes/pudge/bracer.vmdl", "models/heroes/pudge/hair.vmdl", "models/heroes/pudge/belt.vmdl"],
        0.98,
        {"Stand": "pudge_idle_anim", "Stand - 2": "pudge_idle_alt_anim", "Stand Ready": "pudge_idle_anim",
         "Walk": "pudge_walkN_anim", "Attack": "pudge_attack1_anim", "Attack - 2": "pudge_attack2_anim",
         "Spell": "pudge_meathook_start_anim", "Spell Channel": "pudge_dismember_mid_anim",
         "Death": "pudge_death", "Birth": "pudge_spawn_anim", "Stand Victory": "victory"}),
    "hero_meepo": _hero(
        "models/heroes/meepo/meepo.vmdl",
        ["models/heroes/meepo/meepo_weapon.vmdl", "models/heroes/meepo/hood.vmdl", "models/heroes/meepo/pack.vmdl",
         "models/heroes/meepo/shoulders.vmdl", "models/heroes/meepo/bracers.vmdl", "models/heroes/meepo/tail.vmdl"],
        0.93,
        {"Stand": "idle_anim", "Stand - 2": "idle1_anim", "Stand Ready": "idle_anim", "Walk": "run_anim",
         "Attack": "attack_anim", "Attack - 2": "attack1_anim", "Spell": "earthbind_anim",
         "Spell Channel": "generic_channel", "Death": "death", "Birth": "spawn_anim",
         "Stand Victory": "victory_anim"}),
    "hero_tinker": _hero(
        "models/heroes/tinker/tinker.vmdl",
        ["models/heroes/tinker/tinker_right_arm.vmdl", "models/heroes/tinker/tinker_left_arm.vmdl",
         "models/heroes/tinker/tinker_shoulders.vmdl", "models/heroes/tinker/tinker_helmet.vmdl",
         "models/heroes/tinker/tinker_body_head.vmdl", "models/heroes/tinker/tinker_cape.vmdl"],
        0.8,
        # Spell Channel: Rearm, Tinker's only "spell,channel" (Dota plays rearm1..3 by level)
        {"Stand": "idle_anim", "Stand Ready": "idle_anim", "Walk": "run_anim", "Attack": "attack_anim",
         "Spell": "laser_anim", "Spell Channel": "rearm1_anim", "Death": "death", "Birth": "spawn_anim",
         "Stand Victory": "victory"}),
    "hero_rubick": _hero(
        "models/heroes/rubick/rubick.vmdl",
        ["models/heroes/rubick/rubick_staff.vmdl", "models/heroes/rubick/cape.vmdl",
         "models/heroes/rubick/shoulder.vmdl", "models/heroes/rubick/rubick_head.vmdl"],
        0.7,
        # Spell: the cast of a stolen spell (ACT_DOTA_CAST_ABILITY_5, Dota's first
        # stolen slot), which plain "spell" asks for; his own spells have theirs.
        {"Stand": "rubick_idle", "Stand - 2": "rubick_idle_alt", "Stand Ready": "rubick_idle",
         "Walk": "rubick_run", "Attack": "rubick_attack_anim", "Attack - 2": "rubick_attackb",
         "Spell": "rubick_generic_casta", "Spell Channel": "rubick_channel", "Death": "rubick_die",
         "Birth": "rubick_spawn", "Stand Victory": "rubick_victory_anim"}),
    "hero_morphling": _hero(
        "models/heroes/morphling/morphling.vmdl", [], 0.88,
        {"Stand": "idle_anim", "Stand - 2": "idle_alt_anim", "Stand Ready": "idle_anim", "Walk": "run_new_anim",
         "Attack": "attack1_anim", "Attack - 2": "attack_alt_anim", "Spell": "adaptive_strike_anim",
         "Spell Channel": "generic_channel", "Death": "death", "Birth": "spawn_temp", "Stand Victory": "victory"}),
    "hero_furion": _hero(
        "models/heroes/furion/furion.vmdl",
        ["models/heroes/furion/furion_staff.vmdl", "models/heroes/furion/furion_horns.vmdl",
         "models/heroes/furion/furion_beard.vmdl", "models/heroes/furion/furion_cape.vmdl",
         "models/heroes/furion/furion_necklace.vmdl", "models/heroes/furion/furion_bracer.vmdl"],
        0.79,
        {"Stand": "idle_anim", "Stand - 2": "idleAlt_anim", "Stand Ready": "idle_anim", "Walk": "run_anim",
         "Attack": "attack_anim", "Spell": "cast_sprout", "Spell Channel": "generic_channel", "Death": "death",
         "Birth": "spawn_anim", "Stand Victory": "victory"}),
    "hero_chen": _hero(
        "models/heroes/chen/chen.vmdl",
        ["models/heroes/chen/weapon.vmdl", "models/heroes/chen/mount.vmdl", "models/heroes/chen/helmet.vmdl",
         "models/heroes/chen/bracers.vmdl", "models/heroes/chen/shoulders.vmdl"],
        0.93,
        {"Stand": "idle_anim", "Stand - 2": "idle_rare", "Stand Ready": "idle_anim", "Walk": "run_anim",
         "Attack": "attack_anim", "Attack - 2": "attack_alt1_anim", "Spell": "cast1_penitence_anim",
         "Spell Channel": "hand_of_god_channel", "Death": "death", "Birth": "spawn", "Stand Victory": "victory"}),
    "hero_antimage": _hero(
        "models/heroes/antimage/antimage.vmdl",
        ["models/heroes/antimage/antimage_weapon.vmdl", "models/heroes/antimage/antimage_head.vmdl",
         "models/heroes/antimage/antimage_chest.vmdl", "models/heroes/antimage/antimage_arms.vmdl",
         "models/heroes/antimage/antimage_belt.vmdl", "models/heroes/antimage/antimage_offhand_weapon.vmdl"],
        0.9,
        {"Stand": "idle_anim", "Stand Ready": "idle_anim", "Walk": "run_anim", "Attack": "attack1_anim",
         "Attack - 2": "attack2_anim", "Spell": "blink_anim", "Spell Channel": "generic_channel",
         "Death": "die", "Birth": "spawn", "Stand Victory": "victory_versus"}),
    "hero_techies": _hero(
        "models/heroes/techies/techies.vmdl",
        ["models/heroes/techies/techies_barrel.vmdl", "models/heroes/techies/techies_spleen_weapon.vmdl",
         "models/heroes/techies/techies_cart.vmdl", "models/heroes/techies/techies_squee_costume.vmdl",
         "models/heroes/techies/techies_spleen_costume.vmdl"],
        0.6,
        {"Stand": "idle_anim", "Stand Ready": "idle_anim", "Walk": "run_anim", "Attack": "attack_anim",
         "Spell": "landmines_anim", "Spell Channel": "generic_channel", "Death": "die", "Birth": "spawn_ingame",
         "Stand Victory": "victory"}),
    "hero_ogre_magi": _hero(
        "models/heroes/ogre_magi/ogre_magi.vmdl",
        ["models/heroes/ogre_magi/ogre_magi_weapon.vmdl", "models/heroes/ogre_magi/ogre_magi_cape.vmdl",
         "models/heroes/ogre_magi/ogre_magi_bracers.vmdl", "models/heroes/ogre_magi/ogre_magi_hats.vmdl",
         "models/heroes/ogre_magi/ogre_magi_belt.vmdl"],
        0.93,
        {"Stand": "idle_anim", "Stand - 2": "idle_bellyScratch_anim", "Stand Ready": "idle_anim",
         "Walk": "run_anim", "Attack": "attack1_anim", "Attack - 2": "attack3_anim",
         "Spell": "cast1_fireblast_anim", "Spell Channel": "generic_channel", "Death": "dieBack",
         "Birth": "spawn_anim", "Stand Victory": "victory_loop_anim"}),
    "hero_nevermore": _hero(
        "models/heroes/shadow_fiend/shadow_fiend.vmdl",
        ["models/heroes/shadow_fiend/shadow_fiend_head.vmdl", "models/heroes/shadow_fiend/shadow_fiend_shoulders.vmdl",
         "models/heroes/shadow_fiend/shadow_fiend_arms.vmdl"],
        0.98,
        {"Stand": "idle_anim", "Stand - 2": "idle_rare_anim", "Stand Ready": "idle_anim", "Walk": "run_anim",
         "Attack": "attack01_anim", "Attack - 2": "attack02_anim", "Spell": "cast1_shadowraze_a_anim",
         "Spell Channel": "generic_channel", "Death": "death", "Birth": "spawn", "Stand Victory": "victory_anim"}),

    # Radiant lane creeps (npc_dota_creep_goodguys_melee/_ranged, npc_dota_goodguys_siege)
    "dota_melee": {"kind": CREEP, "model": "models/creeps/lane_creeps/creep_radiant_melee/radiant_melee.vmdl",
                   "items": [], "scale": 0.93,
                   "anims": {"Stand": "idle", "Stand Ready": "idle", "Walk": "run", "Attack": "attack",
                             "Attack - 2": "attack2", "Death": "death", "Stand Victory": "victory_idle"}},
    "dota_ranged": {"kind": CREEP, "model": "models/creeps/lane_creeps/creep_radiant_ranged/radiant_ranged.vmdl",
                    "items": [], "scale": 0.88,
                    "anims": {"Stand": "idle", "Stand Ready": "idle", "Walk": "run", "Attack": "attack",
                              "Attack - 2": "attack2", "Death": "death", "Stand Victory": "victory_idle"}},
    "dota_siege": {"kind": CREEP, "model": "models/creeps/lane_creeps/creep_good_siege/creep_good_siege.vmdl",
                   "items": [], "scale": 0.65,
                   "anims": {"Stand": "creep_good_siege_idle", "Stand Ready": "creep_good_siege_idle",
                             "Walk": "creep_good_siege_run", "Attack": "creep_good_siege_attack"}},

    # Radiant structures (npc_dota_goodguys_tower*, *_melee_rax_*, *_range_rax_*, _fort; the
    # Radiant fountain is the map prop radiant_fountain002)
    "tower1": {"kind": STRUCTURE, "model": "models/props_structures/tower_good.vmdl", "items": [], "scale": 1.0,
               # tower_good_attack is a one-frame additive pose: the idle reads better.
               "anims": {"Stand": "tower_good_idle", "Attack": "tower_good_idle"}},
    "tower2": {"same_as": "tower1"},
    "tower3": {"same_as": "tower1"},
    "tower4": {"same_as": "tower1"},
    "rax_melee": {"kind": STRUCTURE, "model": "models/props_structures/radiant_melee_barracks001.vmdl",
                  "items": [], "scale": 1.0, "anims": {}},
    "rax_ranged": {"kind": STRUCTURE, "model": "models/props_structures/radiant_ranged_barracks001.vmdl",
                   "items": [], "scale": 1.0, "anims": {}},
    "ancient": {"kind": STRUCTURE, "model": "models/props_structures/radiant_ancient001.vmdl", "items": [],
                "scale": 1.0, "anims": {}},
    # The fountain's basins float above a separate rock base prop; both are merged
    # and the base's underground part (below z = -10) is cut off.
    "fountain": {"kind": STRUCTURE, "model": "models/props_structures/radiant_fountain002.vmdl",
                 "items": ["models/props_structures/structure_fountain_radiant_basic.vmdl"],
                 "scale": 1.0, "anims": {}, "clip_below": -10.0},
}


def _creep(model, scale, anims=None, **extra):
    """A unit whose clips are found by Dota activity (anims lists overrides)."""
    return dict({"kind": CREEP, "model": model, "items": [], "scale": scale, "anims": anims or {}}, **extra)


# "portrait": True gives a unit a second, static model for its portrait
# (<key>_portrait.mdx, convert.build_portrait; specs/models.json "portrait"
# points the unit's upor at it). Clicking neutrals with their animated model as
# the portrait hung the game now and then (2026-10-10).
# Neutral creeps (world.json "neutrals", gen_objects key "neutral_<name>") and
# Roshan: npc_dota_neutral_<name> / npc_dota_roshan models and ModelScale.
_NEUTRAL = "models/creeps/neutral_creeps/"
UNITS.update({
    # 256-pixel textures: small creeps, about 3 MB less in the map.
    "neutral_" + name: _creep(_NEUTRAL + path, scale, max_texture=256, portrait=True) for name, (path, scale) in {
        "kobold": ("n_creep_kobold/kobold_c/n_creep_kobold_c.vmdl", 0.9),
        "kobold_tunneler": ("n_creep_kobold/kobold_b/n_creep_kobold_b.vmdl", 1.0),
        "kobold_taskmaster": ("n_creep_kobold/kobold_a/n_creep_kobold_a.vmdl", 1.0),
        "forest_troll_berserker": ("n_creep_forest_trolls/n_creep_forest_troll_berserker.vmdl", 0.9),
        "forest_troll_high_priest": ("n_creep_forest_trolls/n_creep_forest_troll_high_priest.vmdl", 0.9),
        "gnoll_assassin": ("n_creep_gnoll/n_creep_gnoll.vmdl", 0.9),
        "harpy_scout": ("n_creep_harpy_a/n_creep_harpy_a.vmdl", 0.85),
        "harpy_storm": ("n_creep_harpy_b/n_creep_harpy_b.vmdl", 0.925),
        "ghost": ("n_creep_ghost_a/n_creep_ghost_a.vmdl", 0.9),
        "fel_beast": ("n_creep_ghost_b/n_creep_ghost_b.vmdl", 0.9),
        "giant_wolf": ("n_creep_worg_small/n_creep_worg_small.vmdl", 0.9),
        "alpha_wolf": ("n_creep_worg_large/n_creep_worg_large.vmdl", 0.9),
        "ogre_mauler": ("n_creep_ogre_med/n_creep_ogre_med.vmdl", 0.9),
        "ogre_magi": ("n_creep_ogre_lrg/n_creep_ogre_lrg.vmdl", 0.9),
        "satyr_trickster": ("n_creep_satyr_b/n_creep_satyr_b.vmdl", 0.7),
        "satyr_soulstealer": ("n_creep_satyr_c/n_creep_satyr_c.vmdl", 0.8),
        "satyr_hellcaller": ("n_creep_satyr_a/n_creep_satyr_a.vmdl", 0.95),
        "mud_golem": ("n_creep_golem_b/n_creep_golem_b.vmdl", 1.1),
        "centaur_outrunner": ("n_creep_centaur_med/n_creep_centaur_med.vmdl", 0.8),
        "centaur_khan": ("n_creep_centaur_lrg/n_creep_centaur_lrg.vmdl", 1.0),
        "polar_furbolg_champion": ("n_creep_beast/n_creep_beast.vmdl", 0.8),
        "polar_furbolg_ursa_warrior": ("n_creep_furbolg/n_creep_furbolg_disrupter.vmdl", 0.95),
        "wildkin": ("n_creep_vulture_b/n_creep_vulture_b.vmdl", 0.8),
        "enraged_wildkin": ("n_creep_vulture_a/n_creep_vulture_a.vmdl", 1.1),
        "dark_troll": ("n_creep_troll_dark_a/n_creep_troll_dark_a.vmdl", 0.7),
        "dark_troll_warlord": ("n_creep_troll_dark_b/n_creep_troll_dark_b.vmdl", 0.9),
        "black_drake": ("n_creep_black_drake/n_creep_black_drake.vmdl", 0.6),
        "black_dragon": ("n_creep_black_dragon/n_creep_black_dragon.vmdl", 1.0),
        "rock_golem": ("n_creep_golem_a/neutral_creep_golem_a.vmdl", 1.0),
        "granite_golem": ("n_creep_golem_a/neutral_creep_golem_a.vmdl", 1.3),
        "small_thunder_lizard": ("n_creep_thunder_lizard/n_creep_thunder_lizard_small.vmdl", 0.65),
        "big_thunder_lizard": ("n_creep_thunder_lizard/n_creep_thunder_lizard_big.vmdl", 0.8),
    }.items()
})
UNITS.update({
    # Spell is Slam (ACT_DOTA_CAST_ABILITY_3): src/game/world_roshan.lua plays "spell" for it.
    "roshan": _creep("models/creeps/roshan/roshan.vmdl", 1.0, {
        "Stand": "roshan_idle", "Stand Ready": "roshan_idle", "Walk": "roshan_run", "Attack": "roshan_attack",
        "Attack - 2": "roshan_attack2", "Spell": "roshan_slam", "Spell Channel": "roshan_generic_channel",
        "Death": "roshan_die"}, portrait=True),
    # Hero summons (specs/heroes/*.json "units"): npc_dota_chen_zealot,
    # npc_dota_furion_treant, npc_dota_techies_land_mine, npc_dota_tinker_turret1.
    "chen_zealot": _creep("models/creeps/lane_creeps/creep_radiant_melee/radiant_melee_mega.vmdl", 1.1,
                          portrait=True),
    "furion_treant": _creep("models/heroes/furion/treant.vmdl", 0.8, portrait=True),
    "techies_mine": _creep("models/heroes/techies/fx_techiesfx_mine.vmdl", 1.0, portrait=True),
    "tinker_turret": _creep("models/heroes/tinker/tinker_turret.vmdl", 0.65, portrait=True),
    # March of the Machines robot: a special effect in src/heroes/tinker.lua, not a unit.
    # Scale: particles/units/heroes/hero_tinker/tinker_machine.vpcf draws it at its radius, 0.25.
    "tinker_robot": _creep("models/heroes/tinker/mom.vmdl", 0.25, max_texture=256),
    # Every Dota shop of the map (gen_objects key "shop"): the Radiant secret shop stall.
    "shop": {"kind": STRUCTURE, "model": "models/props_structures/secretshop_radiant001.vmdl", "items": [],
             "scale": 0.6, "anims": {}},
})

# Rune power-ups (src/game/world_runes.lua; gen_objects item keys "rune_<kind>"):
# the item model (ifil). Props with one looping idle clip, converted like
# structures: Stand plays it, the collision box keeps the rune clickable. Dota
# draws their glow with particles, which are not converted. The bounty rune is
# rune_goldxp; the wisdom rune (rune_xp) is not in the map.
UNITS.update({
    "rune_" + kind: {"kind": STRUCTURE, "model": f"models/props_gameplay/{name}.vmdl", "items": [], "scale": 1.0,
                     "anims": {"Stand": clip}}
    for kind, (name, clip) in {
        "bounty": ("rune_goldxp", "rune_goldxp_anim"),
        "water": ("rune_water", "rune_arcane_idle"),
        "doubledamage": ("rune_doubledamage01", "rune_doubledamage_anim"),
        "haste": ("rune_haste01", "rune_haste_idle"),
        "illusion": ("rune_illusion01", "rune_illusion_idle"),
        "invisibility": ("rune_invisibility01", "rune_invisibility_idle"),
        "regeneration": ("rune_regeneration01", "rune_regeneration_anim"),
        "arcane": ("rune_arcane", "rune_arcane_idle"),
        "shield": ("rune_shield01", "rune_invisibility_idle"),
    }.items()
})

# Observer and Sentry Wards (gen_objects units "wardobserver"/"wardsentry",
# placed by the ward items): npc_dota_observer_wards / npc_dota_sentry_wards.
# Both are default_ward.vmdl; the sentry wears its material group "1"
# (sentry_ward.vmat), whose colour texture replaces the observer's.
UNITS.update({
    "ward_observer": {"kind": STRUCTURE, "model": "models/props_gameplay/default_ward.vmdl", "items": [],
                      "scale": 1.0, "portrait": True,
                      "anims": {"Stand": "default_ward_idle", "Death": "default_ward_die",
                                "Birth": "default_ward_spawn"}},
    "ward_sentry": {"same_as": "ward_observer", "textures": {
        "observer_ward": ("materials/models/props_gameplay/sentry_ward_color_psd_e5e79182.vtex", "OPAQUE")}},
})

# Structure fallbacks differ: they have no Dota clips for most sequences.
STRUCTURE_SEQUENCES = ["Stand", "Attack", "Death", "Birth"]
STRUCTURE_FALLBACKS = {"Stand": "static", "Attack": "Stand", "Death": "sink", "Birth": "rise"}


def resolve(key):
    """Unit entry with 'same_as' followed."""
    unit = UNITS[key]
    while "same_as" in unit:
        unit = UNITS[unit["same_as"]]
    return unit


def compiled(vmdl):
    return vmdl + "_c"
