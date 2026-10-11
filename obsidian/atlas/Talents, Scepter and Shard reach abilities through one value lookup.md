---
tags: [atlas, talents, abilities, heroes, hud]
date: 2026-10-11
---

# Talents, Scepter and Shard reach abilities through one value lookup

Hero code reads ability values through `A.value(name, key, level, unit)` or `ctx.v(key)`. With
the unit given, the lookup adds every bonus that unit has: picked talents, Aghanim's Scepter
and Aghanim's Shard. No hero module applies talent bonuses on its own. `T.sync` writes the
results into the unit's abilities, covering cooldowns, mana costs, channel times and cast
ranges. Built on 2026-10-11 by the talents agent; not yet seen in game.

## Data

- `tools/summarize_heroes.py` and `tools/refresh_herodata.py` write two fields per hero into
  `src/data/heroes.json`:
  - `talents`: name, tier, side, and a generic `stat` or a label;
  - `upgrades`: the Scepter and Shard texts, in our own words.
- All 11 heroes have their 8 talents and both upgrade texts.

## Rules (`src/game/talents.lua`)

These follow Liquipedia for patch 7.41, cited in the module.
- **Talents**: four tiers open at levels 10, 15, 20 and 25, with one of two picks each. The other
  pick of a tier opens at 27, 28, 29 and 30. Picks don't cost an ability point.
- **Generic stat talents** go through `mods` and `stats`.
- **Attribute Bonus**: +2 to all attributes per level, paid with ability points.
- **Aghanim's Scepter** works while it is in the main inventory.
- **Aghanim's Shard** is consumed when bought (`T.buyShard`), once per hero.
- **Abilities granted** by a Scepter or Shard get their own objects in `gen_objects.py`
  (`is_granted`, `_granted` specs); `T.grant` adds and removes them.
- **Copies**: Meepo clones get the main Meepo's talents but not his Attribute Bonus. Rubick's
  stolen and Morphling's morphed spells get the caster's Scepter and Shard, never the original
  hero's talents.
- **Events**: `talent`, `attribute_bonus`, `scepter`, `shard`.

## HUD (`src/ui/dota_talents.lua`)

The talent tree button sits left of the ability row and glows while a pick is open. Hovering
shows the tree; a click pins it for picking. Aghanim's sign sits right of the row, lit for a
Scepter or Shard, and its hover lists the hero's upgrades. Art comes from `specs/hud_assets.json`
(`talent_*` and `aghs_*` entries).

## Bots

`T.botPick` takes talents from Valve's bot builds where they list them, otherwise by a fixed
rule. Bots buy the Scepter and Shard where their item builds have them.

## Status (2026-10-11)

- Unique talents and upgrades are coded for Pudge, Meepo, Tinker, Rubick, Morphling, Nature's
  Prophet, Chen and Anti-Mage.
- Techies, Ogre Magi and Shadow Fiend still read values without the unit. Their linked talents,
  Scepter and Shard don't work yet.
- Aghanim's Blessing (from Roshan) is out of scope.

Related: [[The map script is split into define and use modules]],
[[Up to five Dota heroes fight one Warcraft commander]],
[[Dota players get a frame-based HUD with their own item buttons]]
