---
tags: [decision, commander, ai]
date: 2026-10-11
---

# The AI commander starts with a starter base of stock WC3 structures

## Decision

`src/game/commander_base.lua` gives the AI commander finished stock structures around its hall
at game start:

| Race | Towers | Production | Supply |
|---|---|---|---|
| Human | 2 Guard Tower | Barracks | 3 Farm |
| Orc | 2 Watch Tower | Barracks | 2 Burrow |
| Undead | 2 Spirit Tower | Crypt | Ziggurat |
| Night Elf | 2 Ancient Protector | Ancient of War | 2 Moon Well |

How the spots are found:
- they are searched on an integer grid around the hall, so every client gets the same result;
- a spot must be buildable and walkable, off the path between the hall and the mine, off the
  exits, and apart from other structures;
- towers face the Dota side, production stands to the sides, supply behind.

`B.FOR = "ai"` is the default; `"all"` gives the base to a human commander too, `"none"` turns
it off.

## Why

- The user asked that the bot not start from a bare town hall.
- Stock units keep WC3's own numbers.
- The melee AI counts existing structures by type and carries on with its build order.

## Notes

- Undead start with 40 food, the others with 30: Spirit Towers count as supply.
- Each destroyed commander structure pays 150 gold to the Dota hero who last hit it
  (`economy.lua`).
- Since 2026-10-11 the AI commander takes a playing computer slot, slot 1 in single player, and
  its start location moves to the base. Whether the melee AI then plays isn't confirmed in game
  yet; see [[The AI commander idles because its computer slot is empty in single player]].

Related: [[Up to five Dota heroes fight one Warcraft commander]]
