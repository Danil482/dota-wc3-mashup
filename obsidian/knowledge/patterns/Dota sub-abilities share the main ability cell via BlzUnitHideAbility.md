---
tags: [pattern, abilities]
date: 2026-10-10
---

# Dota sub-abilities share the main ability cell via BlzUnitHideAbility

Dota swaps some abilities in place: pressing the same key again does the second action. In
WC3, both abilities get the same cell and hotkey, and only one of them shows at a time.

## Examples

- **Techies' Reactive Tazer → Detonate.** Detonate has the same cell (1,2) and hotkey W.
  - After a Tazer cast, Detonate is added and Tazer is hidden, deferred by one tick:
    hiding an ability inside its own cast event is unsafe.
  - When the last charge ends, Detonate is removed and Tazer is shown again.
- **Shadow Fiend's razes.** Razes 2 and 3 are innate actives on W and E. `syncRazes` keeps
  their level equal to raze 1 and disables them until raze 1 is learned. That leaves the
  learnable slots for Feast of Souls, Presence of the Dark Lord and Requiem.
- **Morphling's morph swap** hides behind Replicate with `BlzUnitDisableAbility(..., true, true)`.

Related: [[Ability hotkeys come from the command card cell]]
