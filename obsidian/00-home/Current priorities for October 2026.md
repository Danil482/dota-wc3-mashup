---
tags: [priorities, status]
date: 2026-10-11
---

# Current priorities – October 2026

The project started on 2026-10-10. By the end of 2026-10-11 the personalized map has:
- Dota 2's own layout, with cliffs where Dota blocks the ground;
- Dota trees and ground tiles; they show in Reforged graphics, and classic graphics are broken;
- Dota models, icons and voice lines, plus Dota's music, announcer and gameplay sounds;
- a Dota HUD and shop with item cooldown sweeps;
- quick cast and Dota auto-attack, both confirmed in game.

The AI commander starts with a base but still idles in single player: its computer slot is empty
([[The AI commander idles because its computer slot is empty in single player]]). Melty
publishing hasn't started; the last attempt was blocked by the VPN (see
[[Melty cannot check the token while a VPN is on]]). Design:
[[Up to five Dota heroes fight one Warcraft commander]].

## North star (2026-10-11)

[[The Dota side aims at full parity with Dota 2]]: a Dota player must not notice any difference
from regular Dota 2. The WC3 commander side is fine as it is.

## Check in game first

Build `tools\build.py --test --dota-models --work build\work_play<N>`, then run
`dist\DotaVsCommander\DotaVsCommander.exe ... --prepare-only` (from PowerShell with
`Start-Process -Wait`). In-game tests on 2026-10-11:

- [x] Quick cast at the ground (Pudge's hook), and at a unit (Dismember)
- [x] Auto-attack after a move or a stop: the hero stays idle in Standard mode
- [x] Right-click hold with the move marker; denies; failed-cast "not yet" line
- [x] Ward and rune models; runes spin and are picked up
- [x] Aegis, runes, Roshan's spell block, camp leash, backdoor
- [x] Dota trees and ground tiles in Reforged graphics; Dota HUD art; music plays
- [ ] Classic graphics: the ground textures are broken; ask the user what exactly shows
- [ ] Clicking neutrals: static portraits, no hang ([[Selecting some Dota neutrals hung the game]]);
      still not tested
- [ ] The announcer, battle music, last-hit coin and rune sounds: not yet confirmed by ear
- [ ] Item cooldown sweep and HUD click blocking: not yet confirmed in game
- [ ] The AI commander plays once its slot is fixed
- [ ] Bots cast abilities: zero casts in two runs

## Next – small fixes (no agent needed)

- [ ] `roles.lua`: give the AI commander a playing computer slot (slot 5, then any playing
      computer user slot, then slot 7 with a warning)
- [ ] Kind-matched orders for Meepo's Poof (`blink`) and Techies' Sticky Bomb (`acidbomb`)
      ([[Point quick casts failed on Channel orders the engine refuses]])
- [ ] Start the day at 6:00 with a 600 s cycle (the moon shows at 1:57)
- [ ] `Ncl5 = 0` for channelled items such as the TP scroll ([[Channels never lock the command card]])
- [ ] Remove the 18 inert probe Channels from `gen_objects.py` now that the probe has answered
- [ ] Classic tile format, once the user describes the bug
- [ ] Find out why the AI's base vanished at 4:00 in the Reforged run without "game over"

## Next – agents, at most three at a time (paused on 2026-10-11: usage limits)

- [ ] **talents**: the talent tree, Aghanim's Scepter and Shard for all 11 heroes
- [ ] **lane**: denies, creep pulls, aggro, Glyph and Scan, day/night, buyback, kill gold. Its
      plan is in [[2026-10-11 Dota parity wave – terrain, audio, controls and the AI commander]]
- [ ] **inventory**, tasks 3–6: stash and buying anywhere, backpack and TP slot, drag and drop,
      courier (`src/game/inventory.lua` exists but is not wired; plan in the same session note)
- [ ] **vfx**: Dota attack projectiles and 1–2 signature spell effects per hero
      (`build\work_vfx\x_attacks` holds decompiled attack particles from a failed run)
- [ ] **bootstrap**: `tools/fetch_research.py`, so a clean clone can build (`tools/casc.py`
      already reads the WC3 CASC storage)

## Next – wave 2

- [ ] Current Dota map features: Tormentors, Lotus Pools, Twin Gates, Watchers, Wisdom Shrines
- [ ] Neutral items and their slot
- [ ] Facets
- [ ] Dota polish: cursor, fonts, health bars, minimap hero icons, cliff textures
- [ ] Multiplayer test with two clients

## Publishing on Melty

- [ ] With the VPN off: `list_my_mods`, `search_games`, `game_info`
- [ ] Recipe: warcraft-iii + dota-2, the launcher in `{managed}`, `maxPlayers` 6, no `connect`
- [ ] Release steps, in order:
  1. `inspect_package`
  2. `validate_recipe`
  3. `one_click_check`
  4. `create_mod` (MIT, remixes allowed)
  5. uploads
  6. a real screenshot
  7. `submit_release`
  8. publish with the user's go-ahead
- [ ] Say honestly that multiplayer was not tested with two clients
- [ ] The personalized map is about 69 MB; the 128 MB limit is from patch 1.29's notes and
      untested on 2.0.1

## Done (2026-10-11)

- [x] Blocked ground rises into cliffs over Dota-blocked cells
      ([[Blocked ground rises into cliffs only over Dota-blocked cells]])
- [x] Dota trees and ground tiles ([[Trees stay WC3 destructables with Dota models swapped in]])
- [x] Dota music, announcer and gameplay sounds
      ([[Dota music plays as 2D sounds mixed per player by volume]])
- [x] Quick cast from build data; Channel orders from pools that match the target type
      ([[Channel orders come from pools that match the target type]])
- [x] Auto-attack held off with the worker unit type ([[Auto-attack is held off with the worker unit type]])
- [x] Right-click hold marker; failed-cast lines; sturdier HUD art detection
- [x] The AI commander's starter base ([[The AI commander starts with a starter base of stock WC3 structures]])
- [x] Item cooldown sweep and charges; HUD click blockers
- [x] Launcher dist rebuilt; `DVC_USER_DIR` for parallel source runs
- [x] CLAUDE.md: at most three agents at the same time

## Done (2026-10-10)

- [x] Build pipeline; 11 heroes; items and shops; bots; voice responses
- [x] The launcher brings from the player's Dota install:
  - [x] 71 models with static neutral portraits and palette textures;
  - [x] item icons and HUD art;
  - [x] 496 voice lines;
  - [x] Dota's map layout ([[Dota's map layout is ported 1 to 1 by the launcher]]).
- [x] World systems hooked in; towers and lane waves ignore neutrals
- [x] Dota HUD and shop working in game; items used from the HUD
      ([[Items are used through HUD buttons, not the WC3 inventory]])
- [x] Rubick: stolen spells on D; Telekinesis Land on Q
- [x] Dota settings import ([[Dota settings reach the game through a local file, never the map]])
- [x] Public GitHub repo, this vault, CLAUDE.md with the agent table
