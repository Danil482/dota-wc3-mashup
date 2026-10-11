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
state local. A holder-only effect, such as the right-click-hold move marker, is created on every
client with an empty model path for the other players:

```lua
local fx = AddSpecialEffect(GetLocalPlayer() == p and path or "", x, y)
Timer.after(0.6, function() DestroyEffect(fx) end)
```

Sounds nobody can hear, such as a bot's last-hit coin, are not created at all. That check uses
synced state only.
