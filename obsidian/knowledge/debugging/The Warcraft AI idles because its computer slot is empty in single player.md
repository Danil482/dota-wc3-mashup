---
tags: [debugging, warcraft, ai, lobby]
date: 2026-10-11
---

# The Warcraft AI idles because its computer slot is empty in single player

## Symptom

The Warcraft AI did nothing for the whole game. Its workers stood idle and nothing was built or
trained.

## Finding

The Warcraft AI's test-build diagnostics showed this in game (2026-10-11, single player
started with `-loadfile`):

```
Warcraft AI 7: computer, slot empty, ... start location 7 at 5536,4992 (0 from the base)
slots 0 user/playing, 1 computer/playing, 6 computer/empty, 7 computer/empty, 8 computer/empty
WARN Warcraft AI: slot 7 is not a playing computer, the melee AI cannot run
```

A game started straight from a map creates one computer player, in slot 1. The "Warcraft AI"
slot (7) stays an empty computer slot, and `StartMeleeAI` does nothing for a player who isn't in
the game.

The first guess, unforced start locations, was wrong: the start location was already right. The
`ForcePlayerStartLocation` call added in `main.lua` stays; it is harmless.

## Fix (2026-10-11, not yet confirmed in game)

`roles.lua` `aiSlot()` gives the Warcraft AI a computer slot that is actually playing:
- slot 5 if it is a playing computer;
- then slot 7 if it is one (a lobby with that slot filled);
- then any playing computer among the user slots, such as slot 1 here;
- slot 7 only as a last resort, with a warning.

The role swap already handles alliances, because any user slot can end up on the Warcraft side.

A user slot starts at the Dota fountain, and the melee AI builds around its start location. So
`Cmd.setup` moves the Warcraft player's start location to the base with `DefineStartLocation` (logged
as "start location N moved to the base"). Whether the engine honours that at run time shows in
the next test's diagnostics.

The mock can mark computers as playing (`__mock.computers`), and `tools/mock/warcraft.lua` checks
the slot choice.

Related: [[The Warcraft AI starts with a starter base of stock WC3 structures]]
