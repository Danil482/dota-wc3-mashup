---
tags: [debugging, commander, ai, lobby]
date: 2026-10-11
---

# The AI commander idles because its computer slot is empty in single player

## Symptom

The AI commander did nothing for the whole game. Its workers stood idle and nothing was built or
trained.

## Finding

The commander agent's test-build diagnostics showed this in game (2026-10-11, single player
started with `-loadfile`):

```
commander AI 7: computer, slot empty, ... start location 7 at 5536,4992 (0 from the base)
slots 0 user/playing, 1 computer/playing, 6 computer/empty, 7 computer/empty, 8 computer/empty
WARN commander AI: slot 7 is not a playing computer, the melee AI cannot run
```

A game started straight from a map creates one computer player, in slot 1. The "Commander AI"
slot (7) stays an empty computer slot, and `StartMeleeAI` does nothing for a player who isn't in
the game.

The first guess, unforced start locations, was wrong: the start location was already right. The
`ForcePlayerStartLocation` call added in `main.lua` stays; it is harmless.

## Fix (next session)

In `roles.lua`, give the AI commander a computer slot that is actually playing:
- slot 5 if it is a computer;
- otherwise any playing computer among the user slots, such as slot 1 here;
- slot 7 only as a last resort, with a warning.

The role swap already handles alliances, because any user slot can end up commanding.

Related: [[The AI commander starts with a starter base of stock WC3 structures]]
