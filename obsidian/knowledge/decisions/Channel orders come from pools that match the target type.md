---
tags: [decision, abilities, orders]
date: 2026-10-11
---

# Channel orders come from pools that match the target type

## Decision

`tools/gen_objects.py` picks a Channel ability's base order (`Ncl6`) from a pool for its target
type:
- none: stomp, fanofknives, …
- unit: thunderbolt, holybolt, …
- point: blizzard, rainoffire, …
- unit or point: carrionswarm, shockwave, impale

How `pool_order` picks:
- it takes the first order the hero doesn't use yet and no spec names;
- orders stay unique per unit and are exported in `data.ids.orders`, together with
  `ability_targets` and `ability_cells`;
- an `order` set in a hero spec still wins.

Quick cast (`dota_settings.lua`) and the bots (`hero_bot.lua`) issue orders by string from this
data. They never read `Ncl6` or `Ncl2` at run time.

## Why

Before, one pool was used whatever the target type. Pudge's Meat Hook (a point Channel) got
`acidbomb`, and the engine refused every trigger point order for it, by string and by id. The
user's cast through the command card worked. See
[[Point quick casts failed on Channel orders the engine refuses]].

## Known gaps

- Spec orders the engine refuses as point orders stay until fixed by hand:
  - Meepo's Poof (`blink`);
  - Techies' Sticky Bomb (`acidbomb`).
- Item actives still have orders that ignore the target type, such as Blink's `ambush`. They are
  cast with `UnitUseItemPoint`, not with orders.

Related: [[Channels never lock the command card]], [[Ability hotkeys come from the command card cell]]
