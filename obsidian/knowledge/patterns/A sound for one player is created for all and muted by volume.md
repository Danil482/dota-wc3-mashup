---
tags: [pattern, multiplayer, sound]
date: 2026-10-10
---

# A sound for one player is created for all and muted by volume

## Problem

Creating a handle inside an `if GetLocalPlayer() == p then` block gives one client a handle
the others don't have. That desyncs multiplayer games.

## Pattern

```lua
local s = CreateSound(path, false, true, true, 10, 10, "DefaultEAXON")
SetSoundVolume(s, GetLocalPlayer() == player and volume or 0)
StartSound(s)
KillSoundWhenDone(s)
```

Every client creates, starts and frees the sound; only the volume differs. `S.at(..., player)`
and `S.local2d` in `src/core/sound.lua` work this way.

The same rule holds for any handle: create it everywhere, and keep only the visible or audible
state local.
