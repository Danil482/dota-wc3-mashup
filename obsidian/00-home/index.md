---
tags: [home, navigation]
date: 2026-10-12
---

# Dota vs Warcraft – a Dota 2 × Warcraft III mashup

A Warcraft III Reforged Lua map: up to five Dota heroes fight one Warcraft player who plays a
full WC3 race. The Dota models, icons and voice lines come from the player's own Dota 2
install, and the launcher puts them into the map. Published on Melty under MIT.

Status and next tasks: [[Current priorities for October 2026]]

## How it is built

- [[Up to five Dota heroes fight one Warcraft player]]
- [[The map is built from source with one build.py command]]
- [[The map script is split into define and use modules]]
- [[Dota content reaches the map only through the launcher]]
- [[Testing runs offline on a mock and in game with user clicks]]
- [[Dota players get a frame-based HUD with their own item buttons]]
- [[Lane rules run in lane.lua on top of WC3 combat]]
- [[Items live in Lua slots – main, backpack, TP, stash and courier]]
- [[Talents, Scepter and Shard reach abilities through one value lookup]]

## Decisions

- [[Warcraft III is the host game, not Dota 2]]
- [[Map archives are packed with StormLib, not mdx-m3-viewer]]
- [[Test builds use WC3 stand-in models]]
- [[Dota models are converted to MDX 800 for both graphics modes]]
- [[Ability hotkeys come from the command card cell]]
- [[Health and mana bonuses are applied as deltas with BlzSetUnitMaxHP]]
- [[Channels never lock the command card]]
- [[Hero responses are Dota voice lines played from Lua]]
- [[Dota's map layout is ported 1 to 1 by the launcher]]
- [[Items are used through HUD buttons, not the WC3 inventory]]
- [[Dota settings reach the game through a local file, never the map]]
- [[Neutral portraits are static palette models]]
- [[Stolen spells use D-cell copies of their objects]]
- [[Towers, buildings and lane waves ignore neutrals]] (partly superseded)
- [[Dota buildings live in slot 10 outside the lobby so creeps can be pulled]]
- [[The Dota side aims at full parity with Dota 2]]
- [[Channel orders come from pools that match the target type]]
- [[Auto-attack is held off with the worker unit type]]
- [[Dota music plays as 2D sounds mixed per player by volume]]
- [[Blocked ground rises into cliffs only over Dota-blocked cells]]
- [[Trees stay WC3 destructables with Dota models swapped in]]
- [[The Warcraft AI starts with a starter base of stock WC3 structures]]
- [[Player-facing strings are keyed by Dota localization tokens]]
- [[The WC3 side is called Warcraft, never commander]]
- [[Test builds end the game like release builds]]
- [[Dota spell effects reach the map through data.effects, missiles through object data]]
- [[The Warcraft base has a grove of 51 Dire trees with triple lumber]]
- [[Each Dota ability plays its own cast animation through Spell tags]]

## Debugging

- [[print or Preload during map load keeps the map from opening]]
- [[A map without a minimap crashes with Game data is unable to load]]
- [[Invisible units mean the map points to Dota models without the launcher]]
- [[Melty cannot check the token while a VPN is on]]
- [[Text labels on custom buttons swallow the mouse even when disabled]]
- [[Native inventory buttons die under the Dota HUD]]
- [[Selecting some Dota neutrals hung the game]]
- [[Point quick casts failed on Channel orders the engine refuses]]
- [[SetUnitAcquireRange ignores 0, so a zero range can't stop auto-attacks]]
- [[The Warcraft AI idles because its computer slot is empty in single player]]
- [[HUD art detection broke when one voice line was missing]]
- [[Quick cast sent no order for native abilities without a Channel target kind]]
- [[The mock missed ERROR lines that left the log's 600-line window]]
- [[A freeze is suspected from own lane creeps with animated portraits and WC3 voices]] (open)

## Patterns

- [[Parallel agents split the repo by file ownership]]
- [[A sound for one player is created for all and muted by volume]]
- [[Dota sub-abilities share the main ability cell via BlzUnitHideAbility]]
- [[UI probe logs show which frames get the mouse]]
- [[Test-build engine probes answer what the mock can't]]

## Integrations and publishing

- [[Melty publishes the mashup and checks one-click play]]
- [[VRF CLI extracts Dota resources from VPKs]]
- [[The mashup is published on Melty under MIT with remixes allowed]]
- [[HyperFrames renders the launch video through the pinned hf.sh wrapper]]
- [[The launch video uses Dota's own sound and stays out of git]]

## Session log

`sessions/` holds one note per working session, named `YYYY-MM-DD <slug>.md`.

- [[2026-10-12 Launch video rebuilt on HyperFrames with Dota's own sound]]
- [[2026-10-11 Night wave – effects, cast animations, sounds, grove and the Dota vs Warcraft rename]]
- [[2026-10-11 Lane rules, inventory with courier, talents and the Warcraft AI slot]]
- [[2026-10-11 Dota parity wave – terrain, audio, controls and the Warcraft AI]]
- [[2026-10-10 Dota terrain, working HUD and imported Dota settings]]
- [[2026-10-10 Mashup skeleton from an empty folder to Dota models in game]]
