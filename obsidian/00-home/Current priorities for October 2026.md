---
tags: [priorities, status]
date: 2026-10-10
---

# Current priorities – October 2026

The project started on 2026-10-10. By the end of the day:
- the personalized map runs on Dota 2's own layout, with Dota models, icons, voice lines, HUD
  art, wards and runes;
- Dota players get a working Dota-style HUD and shop, items used from the HUD, a
  selected-units bar with Tab, and their own Dota keys and settings.

Neutral hangs got a universal mitigation that is not yet tested in game. Melty publishing is
still blocked by the VPN (see [[Melty cannot check the token while a VPN is on]]). Design:
[[Up to five Dota heroes fight one Warcraft commander]].

## Check in game first

Build `tools\build.py --test --dota-models --work build\work_play`, then run the launcher with
`--prepare-only`. Then check:

- [ ] Clicking neutrals: static portraits, no hang ([[Selecting some Dota neutrals hung the game]])
- [ ] Classic graphics: models, textures, HUD
- [ ] Quick cast at the ground (Pudge's hook), and that the targeting cursor closes
- [ ] Auto-attack after a move: the hero stays idle; the log may show "took a new target ... stopped"
- [ ] Right-click hold to move, while dragging
- [ ] Ward and rune models; runes spin and are picked up
- [ ] Aegis, runes, Roshan's spell block, camp leash, backdoor

## Next work

- [ ] **Blocked ground** that looks walkable: raise about 52k gridnav cells into cliffs and add
      rocks for the strips. The plan is in the Level Designer's report (2026-10-10).
- [ ] **Dota music:** laning layers, battle loops, win/lose stingers, about 15–17 MB.
      PlayMusic is risky in Reforged.
- [ ] **Item UX:** cooldown sweep on item buttons, drag and drop, dropping items.
- [ ] **World clicks on HUD gaps:** clicks on empty HUD space reach the world. Block them
      without blocking our buttons.
- [ ] **Creep pulls:** neutrals vs lane waves; the passivity covers towers too.
- [ ] **Ability effects:** Dota-like approximations from Dota meshes and textures, 1–2 per
      hero.
- [ ] **`research/`** is not in git: add a script that downloads jassdoc and the SLK metadata.

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
