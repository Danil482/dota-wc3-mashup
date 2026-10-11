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

The evening session of 2026-10-11 added more, all green on the mock but not yet seen in game:
- Dota's lane rules: denies, aggro, Glyph, Scan, buyback, kill gold, a 600 s day and creep pulls
  ([[Lane rules run in lane.lua on top of WC3 combat]]);
- the backpack, stash, TP slot, drag and drop and a courier
  ([[Items live in Lua slots – main, backpack, TP, stash and courier]]);
- talents with Aghanim's Scepter and Shard, with unique effects for 8 of the 11 heroes
  ([[Talents, Scepter and Shard reach abilities through one value lookup]]).

The AI commander now takes a playing computer slot (slot 1 in single player), with its start
location moved to the base. Whether the melee AI plays is not confirmed yet
([[The AI commander idles because its computer slot is empty in single player]]). Melty
publishing hasn't started; the last attempt was blocked by the VPN (see
[[Melty cannot check the token while a VPN is on]]). Design:
[[Up to five Dota heroes fight one Warcraft commander]].

## North star (2026-10-11)

[[The Dota side aims at full parity with Dota 2]]: a Dota player must not notice any difference
from regular Dota 2. The WC3 commander side is fine as it is.

## Check in game first

Build `tools\build.py --test --dota-models --work build\work_play<N>`. Rebuild the launcher dist
first (`launcher\build.ps1`), because the courier keys changed on 2026-10-11. Then run
`dist\DotaVsCommander\DotaVsCommander.exe ... --prepare-only` (from PowerShell with
`Start-Process -Wait`).

Earlier in-game tests (2026-10-11):
- [x] Quick cast at the ground (Pudge's hook), and at a unit (Dismember)
- [x] Auto-attack after a move or a stop: the hero stays idle in Standard mode
- [x] Right-click hold with the move marker; denies; failed-cast "not yet" line
- [x] Ward and rune models; runes spin and are picked up
- [x] Aegis, runes, Roshan's spell block, camp leash, backdoor
- [x] Dota trees and ground tiles in Reforged graphics; Dota HUD art; music plays

Still to check:
- [ ] Classic graphics: the ground textures are broken; ask the user what exactly shows
- [ ] Clicking neutrals: static portraits, no hang ([[Selecting some Dota neutrals hung the game]]);
      still not tested
- [ ] The announcer, battle music, last-hit coin and rune sounds: not yet confirmed by ear
- [ ] Item cooldown sweep and HUD click blocking
- [ ] The AI commander plays from slot 1; the log says "start location N moved to the base"
- [ ] Bots cast abilities: zero casts in two runs
- [ ] Quick cast of Poof and Sticky Bomb at a point; Stop interrupts the TP scroll
- [ ] Rubick's quick cast of stolen spells (D): their slots have no `ability_targets` entry
- [ ] Lane:
  - towers on slot 10 shoot;
  - the log says "a full day takes 600 s";
  - denies show "!";
  - the Glyph, Scan and buyback buttons take clicks;
  - Scan works from a minimap click
- [ ] Inventory:
  - drag and drop;
  - the hidden TP ability;
  - the item block at 4:3, 16:9 and 21:9;
  - the courier with F2 and F3, and its swap to the flying unit
- [ ] Talents: the tree opens and picks; a Shard purchase; Aghanim's sign

## Next – small fixes (no agent needed)

- [x] `roles.lua`: the AI commander takes a playing computer slot (2026-10-11)
- [x] Kind-matched orders for Poof (`massteleport`) and Sticky Bomb (pool `blizzard`) (2026-10-11)
- [x] The day starts with the horn, on a 600 s cycle (lane agent, 2026-10-11)
- [x] `Ncl5 = 0` for channelled items such as the TP scroll (2026-10-11)
- [x] The 18 probe Channels removed from `gen_objects.py` (2026-10-11)
- [ ] Classic tile format, once the user describes the bug
- [ ] Find out why the AI's base vanished at 4:00 in the Reforged run without "game over"
- [ ] The `-respawn` cheat should call `heroes.revive`
- [ ] Bounty runes and Midas should earn through `economy.earn`, so the buyback penalty applies
- [ ] Widen `world_camps` `C.LEASH` (800) so creep pulls work
- [ ] Dota's Glyph and Scan hotkeys in `dota_settings`
- [ ] The HUD clock runs 30 s ahead of Dota time; dawn and the Glyph follow the horn
- [ ] Inventory gaps:
  - picking an item up into the backpack when the main slots are full;
  - selling stash items from the UI;
  - the 40 s sellback at game start;
  - its error lines into `data.strings`
- [ ] Dota art for the courier, stash, TP slot and backpack in `specs/hud_assets.json`; courier
      models under `courier` and `courier_flying` in `specs/models.json`
- [ ] `docs/FRAMEWORK.md`: lane, talents, inventory, courier, `data.strings`, `data.courier`
      (Technical Writer)
- [ ] Lane gaps: streak and assist gold, Dota's hero-kill XP, illusion bounties, bounties for
      the commander's buildings
- [ ] Watch the inventory exercise check "at a Secret Shop: in hand": the lane agent saw it fail
      once on an identical run

## Next – agents, at most three at a time

- [ ] **talents 2** (fresh brief, at most four heroes per agent):
  - Techies, Ogre Magi and Shadow Fiend need their unique talents, Scepter and Shard;
  - their values must be read with the unit;
  - check Anti-Mage, where the first agent died.
- [x] **lane**: all seven items (2026-10-11)
- [x] **inventory**, tasks 3–6 (2026-10-11)
- [ ] **vfx**: Dota attack projectiles and 1–2 signature spell effects per hero
      (`build\work_vfx\x_attacks` holds decompiled attack particles from a failed run)
- [ ] **bootstrap**: `tools/fetch_research.py`, so a clean clone can build (`tools/casc.py`
      already reads the WC3 CASC storage)
- [ ] **strings** (launcher): fill `data.strings` from the player's Dota localization, once the
      user decides ([[Player-facing strings are keyed by Dota localization tokens]])

## Next – wave 2

- [ ] Current Dota map features: Tormentors, Lotus Pools, Twin Gates, Watchers, Wisdom Shrines
- [ ] Neutral items and their slot
- [ ] Facets
- [ ] Aghanim's Blessing from Roshan
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

## Done (2026-10-11, evening)

- [x] AI commander slot choice and start location; Poof and Sticky Bomb orders; TP `Ncl5 = 0`;
      probe Channels removed
- [x] Lane rules ([[Lane rules run in lane.lua on top of WC3 combat]]); the buildings moved to
      slot 10 ([[Dota buildings live in slot 10 outside the lobby so creeps can be pulled]])
- [x] Player-facing strings keyed by Dota tokens
      ([[Player-facing strings are keyed by Dota localization tokens]])
- [x] Backpack, stash, TP slot, drag and drop, courier
      ([[Items live in Lua slots – main, backpack, TP, stash and courier]])
- [x] Talents, Scepter and Shard: data for all 11 heroes, unique effects for 8
      ([[Talents, Scepter and Shard reach abilities through one value lookup]])

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
