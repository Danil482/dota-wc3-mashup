---
tags: [atlas, lua, framework]
date: 2026-10-10
---

# The map script is split into define and use modules

Every `src/**/*.lua` file declares a module with `define(name, fn)`. The module is created on
its first `use(name)`, and `defined(name)` checks whether a module exists. That is how
`game.lua` loads the hero modules. The API reference for agents is `docs/FRAMEWORK.md`.

## Layers

- `core/`
  - `events`: unit events (casts, deaths, orders, damage)
  - `timer`: `after`, `every` and `onFrame`, each guarded by `safe.call`
  - `mods`: modifiers with numeric properties and status flags (stun, silence, root, hex, ...)
  - `stats`: bonuses summed from modifiers, see
    [[Health and mana bonuses are applied as deltas with BlzSetUnitMaxHP]]
  - `damage`: magical, physical and pure damage, and heals
  - `abilities`: the ability registry over Channel objects, with `onCast`, `onChannel`,
    `onEndCast` and `onLearn`
  - `sound`: sounds and hero voice lines
  - `log`: the log in `CustomMapData\DotaVsCommander\log.txt`
- `game/`
  - `game`: the init order
  - match setup: `roles`, `commander`, `structures`, `heroes`, `creeps`, `economy`, `victory`
  - items: `items`, `item_actives`, `item_passives`
  - `voice`, plus Dota's `music`, `announcer` and `gamesounds` for Dota players (see
    [[Dota music plays as 2D sounds mixed per player by volume]])
  - `commander_base`: the AI commander's starter structures
  - `inventory`: backpack, stash, TP slot and courier storage (not wired yet, 2026-10-11)
  - `world*`: camps, runes, Roshan, towers
  - test-only: `cheats`, `dummy`, `autotest`
- `ui/`: the Dota players' HUD, shop, item use and settings (`hud_kit`, `dota_hud`,
  `dota_shop`, `dota_items`, `dota_settings`), plus the test-only `controls_probe`; see
  [[Dota players get a frame-based HUD with their own item buttons]].
- `heroes/<key>.lua`: one module per hero. Their numbers come from `data.heroes` (Dota KV).
  `A.level(u, name)` also counts Rubick's stolen copies; see
  [[Stolen spells use D-cell copies of their objects]].
- `ai/`: bots. They pick lanes, skill builds and item builds from Valve's bot data, and use
  per-ability hints to cast.
- `data/`: JSON that the build turns into `data.<name>` modules (`heroes`, `items`, `world`,
  `sounds`, `audio`, `ids`, `mapdata`).

## Rules

- Nothing runs while the map loads: all code starts from a 0 s timer after `main()` (see
  [[print or Preload during map load keeps the map from opening]]).
- Each Channel-based ability needs its own order string; otherwise casts trigger each other.
  The order comes from a pool that matches its target type. Quick cast and bots issue it by
  string from `data.ids.orders` ([[Channel orders come from pools that match the target type]]).

Related: [[The map is built from source with one build.py command]]
