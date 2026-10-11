---
tags: [decision, world, alliances]
date: 2026-10-10
---

# Towers, buildings and lane waves ignore neutrals

> **Partly superseded (2026-10-11):** the buildings moved to slot 10, outside the lobby, and
> only that slot is passive with neutrals now. Towers and buildings still ignore the camps, but
> lane creeps on both sides fight them, so creep pulls work. See
> [[Dota buildings live in slot 10 outside the lobby so creeps can be pulled]].

## Decision (2026-10-10)

`roles.lua` sets `ALLIANCE_PASSIVE` both ways between Neutral Hostile and:
- `SLOT_ANCIENTS` (Dota towers, buildings, shops, lane creeps);
- `SLOT_HORDE` (the commander's waves).

Heroes and the commander's own army still fight neutrals.

## Why

In Dota, towers don't attack neutrals. The user saw towers shooting the camps.

## Trade-off

Creep pulls (dragging a camp into a lane wave) don't work until the passivity is narrowed to
towers only.
