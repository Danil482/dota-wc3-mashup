---
tags: [priorities, status]
date: 2026-10-10
---

# Current priorities – October 2026

The project started on 2026-10-10 and reached a playable map the same day. It has:
- a build pipeline;
- 11 heroes with their current Dota kits;
- items and shops;
- bots;
- a launcher that brings Dota models, icons and voice lines from the player's Dota 2;
- world systems: neutral camps, runes, Roshan and backdoor protection.

The user tested the map in game. Dota models and textures render, and the hero fixes were
confirmed. The mashup is not on Melty yet: the service cannot check the token while the
user's VPN is on (see [[Melty cannot check the token while a VPN is on]]). The overall design
is in [[Up to five Dota heroes fight one Warcraft commander]].

## In progress with agents (started 2026-10-10)

- [ ] Building portraits: clicking a tower, barracks, the Ancient or the fountain shows the
      WC3 model, not the Dota one
- [ ] Dota models for neutral creeps, Roshan, Chen's Zealot, Techies' mines, Nature's Prophet's
      treants, and Tinker's robots and turrets
- [ ] Hero walk animation speed (`uwal`) from the measured Dota walk speeds
- [ ] Dota item icons and HUD textures through the launcher (`specs/hud_assets.json`), plus
      more voice lines per event
- [ ] A Dota-style HUD and shop instead of the Warcraft ones (HUD agent)

## Check in game

- [ ] Voice lines: order responses are heard by the hero's owner only, and heroes give no
      WC3 responses
- [ ] Aegis: revive in place after 5 s, with no second revive at the fountain
- [ ] Runes:
  - [ ] pickup by walking over and by right-click;
  - [ ] the Illusion rune gives two illusions;
  - [ ] the Shield rune absorbs damage.
- [ ] Roshan's spell block stops a targeted cast and still spends its cooldown
- [ ] Camps: leash and heal past 800 range, and stacking. Backdoor on T2 with and without
      Horde creeps nearby
- [ ] Hotkeys on every hero; Tinker's Keen Conveyance is on D

## Publishing on Melty

- [ ] With the VPN off: `list_my_mods`, `search_games`, `game_info`
- [ ] Recipe:
  - primary game warcraft-iii, companion dota-2;
  - the launcher in `{managed}`;
  - `multiplayer.maxPlayers` 6 without `connect`, since players join through the WC3 lobby by hand.
- [ ] Release steps, in order:
  1. `inspect_package`
  2. `validate_recipe`
  3. `one_click_check`
  4. `create_mod` (MIT, remixes allowed)
  5. uploads
  6. a real gameplay screenshot
  7. `submit_release`
  8. publish only after the user agrees
- [ ] State honestly that multiplayer was not tested with two clients

## Done

- [x] Build pipeline; the map loads in Reforged 2.0.1 (2026-10-10)
- [x] 11 heroes, items and shops, bots driven by Valve's bot data (2026-10-10)
- [x] Launcher: ability icons, voice lines, and models of heroes, lane creeps and buildings
      (2026-10-10)
- [x] World: 14 camps, runes, Roshan, lane creep upgrades, backdoor. Verified on the mock only
      (2026-10-10)
- [x] Test helpers: level 30 heroes, immortal dummies, the `-spells` caster (2026-10-10)
- [x] Fixes from the user's tests (2026-10-10):
  - [x] channel cancel;
  - [x] Shadow Fiend's ultimate and razes;
  - [x] Ogre's innate;
  - [x] the Counterspell test;
  - [x] Techies' Detonate on W and Blast Off;
  - [x] hotkeys.
- [x] Dota voice responses for heroes (2026-10-10)
- [x] Public GitHub repo, this vault, CLAUDE.md (2026-10-10)

## Later

- [ ] `research/` is not in git. A fresh clone needs a script that downloads jassdoc
      (`common.j`, `Blizzard.j`) and the WC3 SLK metadata
- [ ] A release build without test cheats and dummies, tested in a two-client lobby
- [ ] Out of v1: talents, Aghanim's, facets, neutral items
