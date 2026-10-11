---
tags: [decision, abilities]
date: 2026-10-10
---

# Channels never lock the command card

## Decision

Every Channel-based ability gets `Ncl5` (Disable Other Abilities) = 0 unless its spec sets
`lockAbilities`. When a cast is interrupted before it completes, Lua refunds it in
`onEndCast`.

## Why

As in Dota, Stop or a move order must interrupt a channel. With `Ncl5` = 1 the user could
not cancel Nature's Prophet's Teleportation or the windup of Techies' Blast Off.

## Channelled items (fixed on 2026-10-11)

`gen_objects.item_active_fields` used to set `Ncl5 = 1` for channelled items, so Stop or a move
might not interrupt the TP scroll. It is 0 now. The TP handler in `item_actives.lua` teleports only
after a full channel, so an interrupted scroll doesn't move the hero. Not yet confirmed in game.

Related: [[The map script is split into define and use modules]],
[[Channel orders come from pools that match the target type]]
