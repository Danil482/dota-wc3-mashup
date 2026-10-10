---
tags: [home, navigation]
date: 2026-10-10
---

# Dota vs Commander – a Dota 2 × Warcraft III mashup

A Warcraft III Reforged Lua map: up to five Dota heroes fight one commander who plays a full
Warcraft race. The Dota models, icons and voice lines come from the player's own Dota 2
install, and the launcher puts them into the map. Published on Melty under MIT.

Status and next tasks: [[Current priorities for October 2026]]

## How it is built

- [[Up to five Dota heroes fight one Warcraft commander]]
- [[The map is built from source with one build.py command]]
- [[The map script is split into define and use modules]]
- [[Dota content reaches the map only through the launcher]]
- [[Testing runs offline on a mock and in game with user clicks]]
- [[Dota players get a frame-based HUD with their own item buttons]]

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
- [[Towers, buildings and lane waves ignore neutrals]]

## Debugging

- [[print or Preload during map load keeps the map from opening]]
- [[A map without a minimap crashes with Game data is unable to load]]
- [[Invisible units mean the map points to Dota models without the launcher]]
- [[Melty cannot check the token while a VPN is on]]
- [[Text labels on custom buttons swallow the mouse even when disabled]]
- [[Native inventory buttons die under the Dota HUD]]
- [[Selecting some Dota neutrals hung the game]]

## Patterns

- [[Parallel agents split the repo by file ownership]]
- [[A sound for one player is created for all and muted by volume]]
- [[Dota sub-abilities share the main ability cell via BlzUnitHideAbility]]
- [[UI probe logs show which frames get the mouse]]

## Integrations and publishing

- [[Melty publishes the mashup and checks one-click play]]
- [[VRF CLI extracts Dota resources from VPKs]]
- [[The mashup is published on Melty under MIT with remixes allowed]]

## Session log

`sessions/` holds one note per working session, named `YYYY-MM-DD <slug>.md`.

- [[2026-10-10 Dota terrain, working HUD and imported Dota settings]]
- [[2026-10-10 Mashup skeleton from an empty folder to Dota models in game]]
