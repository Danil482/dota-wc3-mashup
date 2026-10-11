---
tags: [decision, game-design, scope]
date: 2026-10-11
---

# The Dota side aims at full parity with Dota 2

## Decision

The user's goal, set on 2026-10-11: a Dota player who joins the Dota side must not notice any
difference from regular Dota 2. That covers the look, the sound, the controls and the rules.
The Warcraft commander side stays as it is.

Work is ranked by what a Dota player notices first:
- the ground, trees, music and HUD in the first minute;
- the controls in the first fight;
- talents from level 10.

## What it changes

The v1 exclusions are back on the roadmap:
- talents;
- Aghanim's Scepter and Shard;
- the stash, backpack and courier;
- neutral items;
- facets.

See [[Up to five Dota heroes fight one Warcraft commander]].

## Limits

- Numbers still come from the player's Dota files.
- Rules that live only in Dota's game code are taken from the Dota 2 wiki, cited in a code
  comment.
- Where the engine can't do what Dota does, the closest WC3 behaviour is used and written down
  in a decision note.
