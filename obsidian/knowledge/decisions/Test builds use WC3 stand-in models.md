---
tags: [decision, build, models]
date: 2026-10-10
---

# Test builds use WC3 stand-in models

## Decision

- `build.py --test` passes `--standins` to `gen_objects.py`, so every unit keeps the WC3 model
  and sound set from its spec.
- Release builds and `--test --dota-models` apply the paths from `specs/models.json`
  (`war3mapImported\Dota\<key>.mdx`). Those files exist only after the launcher personalizes
  the map.

## Why

The models agent switched `specs/models.json` to Dota paths. After that, every unit in an
unpersonalized test map was invisible, and the user saw heroes "disappear" (2026-10-10).

## Trade-offs

- Gameplay and Dota visuals are tested on two kinds of maps.
- Testing visuals needs the launcher step; see [[Dota content reaches the map only through the launcher]].

Related: [[Invisible units mean the map points to Dota models without the launcher]]
