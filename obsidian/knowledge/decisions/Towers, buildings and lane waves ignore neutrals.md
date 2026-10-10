---
tags: [decision, world, alliances]
date: 2026-10-10
---

# Towers, buildings and lane waves ignore neutrals

## Decision

`roles.lua` sets `ALLIANCE_PASSIVE` both ways between Neutral Hostile and:
- `SLOT_ANCIENTS` (Dota towers, buildings, shops, lane creeps);
- `SLOT_HORDE` (the commander's waves).

Heroes and the commander's own army still fight neutrals.

## Why

In Dota, towers don't attack neutrals. The user saw towers shooting the camps.

## Trade-off

Creep pulls (dragging a camp into a lane wave) don't work until the passivity is narrowed to
towers only.
