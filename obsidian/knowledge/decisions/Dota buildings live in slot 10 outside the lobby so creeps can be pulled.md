---
tags: [decision, slots, lane, neutrals]
date: 2026-10-11
---

# Dota buildings live in slot 10 outside the lobby so creeps can be pulled

## Decision

The Dota buildings (towers, barracks, the Ancient, the fountain, shops) belong to
`SLOT_BUILDINGS = 10`, a player outside the lobby (`src/main.lua`, `src/game/roles.lua`):
- the lane creeps stay in `SLOT_ANCIENTS` (6);
- only slot 10 is passive with Neutral Hostile both ways, so lane creeps on both sides fight
  the camps again;
- slot 10 counts as the Dota side (`Roles.side`) and joins the alliance loop through
  `Roles.slots()`;
- it takes the Ancients' colour and name, and stays passive with the other players outside the
  lobby, such as the test dummies.

## Why

In Dota, towers ignore neutrals but lane creeps fight them, which is what makes creep pulls
work. The earlier rule made the Ancients' whole slot passive, buildings and creeps alike, so
pulls were impossible ([[Towers, buildings and lane waves ignore neutrals]]). WC3 alliances are
set per player, so the buildings needed a player of their own. A slot outside the lobby takes
no seat from anyone.

## Risks

- **Not seen in game yet:** do towers owned by a player outside the lobby attack? Empty lobby
  slots (6 and 8) fought fine in earlier tests, so slot 10 likely does too.
- Code that walked `0 .. PLAYER_COUNT - 1` misses slot 10. Use `Roles.slots()`.
- The camp leash (`world_camps` `C.LEASH`, 800) is still too short for real pulls.

Related: [[Lane rules run in lane.lua on top of WC3 combat]],
[[Up to five Dota heroes fight one Warcraft player]]
