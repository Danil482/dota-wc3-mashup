---
tags: [decision, sound]
date: 2026-10-10
---

# Hero responses are Dota voice lines played from Lua

## Decision

In personalized maps heroes have no WC3 sound set (`usnd` = ""). `src/game/voice.lua` plays
Dota lines instead:

| Event | How it plays |
|---|---|
| Move and attack orders | Owner only, 5 s cooldown per hero, 70% chance |
| Kills, deaths | Always |
| Level-ups | 60% chance |
| Respawns | Always |

Spawn lines play in `heroes.lua`, and cast lines in `abilities.lua`. Test builds with
stand-ins keep the WC3 sound sets.

## Why

The user heard Warcraft responses on Dota heroes ("the voice acting isn't Dota"). The lines
were already in the map, but only spawn and cast events played them.

## Notes

- `src/data/sounds.json` lists the lines per hero and event, and the launcher extracts them.
- Lines don't overlap per unit (2.5 s).
- Owner-only playback must stay multiplayer-safe; see
  [[A sound for one player is created for all and muted by volume]].
