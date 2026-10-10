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

Related: [[The map script is split into define and use modules]]
