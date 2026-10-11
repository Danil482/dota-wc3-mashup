---
tags: [decision, terrain, launcher]
date: 2026-10-11
---

# Blocked ground rises into cliffs only over Dota-blocked cells

## Decision

The launcher's terrain port (`launcher/dvw_launcher/terrain/convert.py`) raises a corner only
when all four tiles around it are fully unwalkable in Dota. Every cliff tile it creates sits on
blocked cells only, so the pathing stays byte for byte the same.

- The first ring of raised corners goes one level above the nearest walkable ground; the corners
  further in go two levels above. The tops get rough heights and rocky tiles.
- Strips too narrow for a cliff get non-solid Lordaeron rocks (`LRrk`), sized to the strip.
- Large raised areas get decorative Dota trees as doodads (`LPcr`/`LPcw` in `war3map.w3d`), with
  no pathing.
- Kept clear:
  - Radiant structures and the fountain;
  - shops, camps, runes, Roshan;
  - lotus pools, ramps and the Warcraft base.

## Result (2026-10-11)

- Blocked cells that look blocked went from 32.8% to 98.7% (89,916 of 91,104).
- 92/92 key points stay reachable, 91 ramps remain, and no tile spans more than two cliff
  levels.
- The cold terrain step takes 36–42 s, up from 17 s.

## Why

Dota blocks ground behind the fountains, along the edges and in the Dire corner with no visible
reason in WC3's look. Raising only fully blocked cells fixes the look without risking a path.

Related: [[Dota's map layout is ported 1 to 1 by the launcher]],
[[Trees stay WC3 destructables with Dota models swapped in]]
