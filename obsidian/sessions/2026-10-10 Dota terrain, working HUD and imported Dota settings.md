---
tags: [session, hud, launcher, terrain, settings]
date: 2026-10-10
---

# Dota terrain, working HUD and imported Dota settings

Continues [[2026-10-10 Mashup skeleton from an empty folder to Dota models in game]]. This
was the evening session after the repo went public.

## What was done

- **World**: neutral camps, runes, Roshan and backdoor are hooked into `game.lua`,
  `economy.lua` and `creeps.lua`. Towers, buildings and lane waves ignore neutrals
  ([[Towers, buildings and lane waves ignore neutrals]]).
- **Rubick**:
  - stolen spells always land on D ([[Stolen spells use D-cell copies of their objects]]);
  - Telekinesis Land takes Q, like Techies' Detonate.
- **Dota HUD and shop** ([[Dota players get a frame-based HUD with their own item buttons]]):
  - the shop buys and sells;
  - the SHOP button, tabs, item icons, the selected-units bar and Dota-style Tab all work.

  The bugs found on the way are in [[Text labels on custom buttons swallow the mouse even when disabled]]
  and [[Native inventory buttons die under the Dota HUD]].
- **Items** are used through the HUD: click a slot, or press Z X C V B N or the player's Dota
  keys ([[Items are used through HUD buttons, not the WC3 inventory]]). Wards are placed
  correctly.
- **The launcher now adds:**
  - item icons;
  - HUD art;
  - more voice lines (496);
  - 71 Dota models: neutrals, Roshan, summons, wards, runes;
  - static portraits ([[Neutral portraits are static palette models]]);
  - Dota's own map layout ([[Dota's map layout is ported 1 to 1 by the launcher]]).
- **Dota settings import** ([[Dota settings reach the game through a local file, never the map]]):
  - keys;
  - quick cast at the cursor;
  - double-tap self cast;
  - auto-attack modes researched from Dota's own settings panel;
  - camera distance and zoom lock;
  - right-click hold to move;
  - the Steam account actually signed in.
- **Confirmed by the user in game:**
  - the Dota terrain loads;
  - Tab works;
  - item icons and the selected-units bar work;
  - buying works;
  - a ward was placed;
  - the portraits of buildings and heroes work.
- **Agents**:
  - CLAUDE.md now maps library agents to kinds of work;
  - agents get fresh briefs rather than being resumed ([[Parallel agents split the repo by file ownership]]).

## What was not done

- **Untested in game** (built at 22:40, launch cancelled by the user):
  - the static neutral portraits;
  - classic graphics;
  - quick cast and auto-attack after the rewrite;
  - right-click hold.
- **Music**: plan only. Tracks chosen from `valve_dota_001` (about 15–17 MB). No code;
  PlayMusic is unreliable in Reforged.
- **Blocked-terrain look**: analysis only. 59,470 gridnav-blocked cells look walkable (behind
  the fountains, edges, the Dire corner). The plan: raise about 52k of them into cliffs and use
  rocks for the strips.
- **Ability effects from Dota**: approximations only, nothing started.
- **Melty publishing**: still blocked by the VPN.

## Key decisions

- [[Dota's map layout is ported 1 to 1 by the launcher]]
- [[Items are used through HUD buttons, not the WC3 inventory]]
- [[Dota settings reach the game through a local file, never the map]]
- [[Neutral portraits are static palette models]]
- [[Stolen spells use D-cell copies of their objects]]
- [[Towers, buildings and lane waves ignore neutrals]]
- **The user's D/F swap isn't applied.** WC3 can't drop native ability hotkeys, and routing
  every key through synced events would add network lag in multiplayer.

## Open questions

- **The neutral hang's root cause.** Is it FaceFX lip-sync from creep sound sets? Their
  `usnd` is now cleared on neutrals; see [[Selecting some Dota neutrals hung the game]].
- **The auto-attack "rushing"**: the user's mode is Standard (1). Does the new acquisition
  guard fix it? Its log line "took a new target ... stopped" will tell.
- **Creep pulls**: they no longer work, because neutrals and lane waves are passive to each
  other.
- **`research/`** is still not in git, so a clean clone can't build.

## Next session – entry points

1. Build and launch `build\work_play\personal\DotaVsCommander_test.w3x`:
   - `tools\build.py --test --dota-models --work build\work_play`;
   - then the launcher with `--prepare-only`.
2. Check, in classic and HD graphics:
   - neutral clicks;
   - quick cast at the ground;
   - auto-attack after a move;
   - right-click hold;
   - ward and rune models.
3. Then:
   - music (the plan is in the audio agent's report);
   - the blocked-terrain cliffs (the Level Designer's plan);
   - Melty publishing with the VPN off.
