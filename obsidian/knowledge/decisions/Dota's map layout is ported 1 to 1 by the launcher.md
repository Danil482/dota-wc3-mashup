---
tags: [decision, terrain, launcher]
date: 2026-10-10
---

# Dota's map layout is ported 1 to 1 by the launcher

## Decision

The personalized map gets Dota 2's own layout, read from the player's `game\dota\maps\dota.vpk`
by `launcher\dvw_launcher\terrain\`. It replaces these files in the base map:
- `w3e`, `wpm`, `doo`, units doo, `w3i`;
- the minimap;
- the `data.mapdata` module in `war3map.lua`, between `-- @dvw-data-begin/end` markers
  written by `tools\build_lua.py`.

The base map keeps the hand-made layout as a fallback.

## How

- **What VRF reads:** the entity lumps (trees, towers, barracks, forts, fountains, shops,
  spawners, path corners, camps, runes, Roshan), the gridnav (`maps/dota.gnv`, 64-unit
  cells), and the physics and ground meshes exported as glb.
- **Coordinates:** 1:1. The cliff layer is `2 + round(z/128)`: the river is 2, lanes 3, high
  ground 4, fountains 5.
- **Converted:** 91 of 93 ramps, shallow water, 1957 trees, Lordaeron tiles, pathing from the
  gridnav plus WC3 cliff rules.
- **The Dire base is flattened and buildable** for the Warcraft player:
  - their town hall stands at the Dire Ancient's spot;
  - their mine is 700 units away;
  - two expansions sit near the Dire T2 towers.
- **Reachability:** 94.4% of Dota's walkable area is walkable in WC3. All 92 key points can
  be reached from the fountain.

## Why

Dota's level is Valve content, so it can't ship in the repo or the release (see
[[Dota content reaches the map only through the launcher]]). Building it on the player's PC
from their own install keeps both the look and the rule.

## Known gaps

- Fixed on 2026-10-11: blocked ground rises into cliffs
  ([[Blocked ground rises into cliffs only over Dota-blocked cells]]), and the map has Dota trees
  and ground tiles ([[Trees stay WC3 destructables with Dota models swapped in]]).
- Classic graphics show broken ground textures (2026-10-11; details pending). Cliff faces still
  use WC3 textures.
- The world mock asserts the base layout's counts.
