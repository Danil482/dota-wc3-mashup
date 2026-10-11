---
tags: [decision, level-design, warcraft, launcher]
date: 2026-10-11
---

# The Warcraft base has a grove of 51 Dire trees with triple lumber

## Decision

The launcher flattens the Dire high ground into the Warcraft base without trees, so the Warcraft player
had nothing to harvest (the AI's lumber never rose). Since 2026-10-11 both maps get a grove:
- `grove()` in `launcher/dvw_launcher/terrain/convert.py`, also used by `tools/layout.py`: a band 4
  trees deep, 960–1472 from the hall's centre, on the side farthest in angle from the mine and the three
  creep spawns, off the mine (512), spawn (768) and expansion (640) discs and the walks to them, split
  by a one-tile walkway. Whole tiles, no trigonometry: deterministic.
- Personalized map: 51 Dire dead trees (`BTtw`); the next tree stands 2585 away. Test layout: 52.
- The user chose the bigger grove (`GROVE_BACK_HALF = False`, mine disc 512) and triple lumber:
  `Cmd.richGrove` in `src/game/warcraft.lua` triples the life (= lumber) of trees within 1600 of the
  start at game start. A WC3 tree gives as much lumber as it has life; wisps don't damage trees.
- `place_grove` floods the pathing with and without the grove and drops it if it cuts more than 16
  cells off the hall. Starter structures keep off trees (`clearOfTrees` in `warcraft_base.lua`).

Confirmed in game (2026-10-11): the log said "grove: 51 trees by the hall hold 3x lumber", and the AI
harvested.

Related: [[Dota's map layout is ported 1 to 1 by the launcher]],
[[The Warcraft AI starts with a starter base of stock WC3 structures]]
