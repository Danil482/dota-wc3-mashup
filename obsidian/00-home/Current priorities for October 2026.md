---
tags: [priorities, status]
date: 2026-10-11
---

# Current priorities – October 2026

The project started on 2026-10-10 and is now called **Dota vs Warcraft**
([[The WC3 side is called Warcraft, never commander]]). By the night of 2026-10-11 the personalized map
has Dota's layout, trees, ground, models, icons, voice lines, music, announcer and gameplay sounds; a
Dota HUD and shop; quick cast and Dota auto-attack; Dota's lane rules; the backpack, stash, TP slot and
courier; talents, Scepter and Shard for all 11 heroes; 39 converted Dota effects; per-ability cast
animations; and a lumber grove for the Warcraft base. Test builds end the game like release builds.

In-game test 2 (2026-10-11 night): every autotest check passed, item cooldowns and drag and drop work,
the Warcraft AI harvests its grove, but the game **froze** at about 230 s
([[A freeze is suspected from own lane creeps with animated portraits and WC3 voices]]). Session:
[[2026-10-11 Night wave – effects, cast animations, sounds, grove and the Dota vs Warcraft rename]].

## North star

[[The Dota side aims at full parity with Dota 2]]: a Dota player must not notice any difference from
regular Dota 2. The Warcraft side keeps Warcraft's look and sound.

## Next – first thing

- [ ] Main build to refresh `src/data/ids.json` (new granted objects and extras), rebuild dist
      (`dist\DotaVsWarcraft`), personalize a `--test --dota-models` map
- [ ] In game, first click own lane creeps 10–20 times (the suspected freeze); on a freeze note the CPU in
      Task Manager and create a dump before closing
- [ ] Calibrate the two start-dialog clicks for `run_test.ps1 -AutoStart` from early game-window
      screenshots (allowed only when the user says so in that session; CLAUDE.md rule 3)
- [ ] Ask: delete the old `DotaVsCommander` folders (`dist`, `%LOCALAPPDATA%`, CustomMapData)?

## Next – agents, at most three at a time (fresh briefs; notes in `build\work_<name>\progress.md`)

- [ ] **hangfix**: static portraits and empty sound sets for `dota_melee`, `dota_ranged`, `dota_siege`
      (maybe `chen_zealot`, `ancient`); black box `blackbox.txt` with a 1 s heartbeat and a watchdog;
      guards (`Timer.every` minimum period, per-frame cap, Dismember ticks, log flush throttle)
- [ ] **warbase**: 11 Warcraft towers at the Dire spots with Dota's numbers from `npc_units.txt` (add them
      to `extract_world.py`), race looks `hgtw`/`owtw`/`uzg1`/`etrp`, Dota tier protection (decide: every
      Warcraft structure or only those inside the base), neutral buildings (Tavern, Fountain of Health
      and of Mana, Goblin Merchant, Goblin Laboratory, Mercenary Camp, Marketplace) closed to Dota players;
      also fix the Dota towers' hand-set damage
- [ ] **vfx2**: why converted missiles are invisible in game (only Techies' showed, WC3-like); an effects
      gallery cheat; Dota visuals for Glyph, Mana Break and mana burn; Techies' Minefield Sign model
- [ ] **audio2**: Dota attack and impact sounds per hero, creep and tower; item pickup, drop and ping sounds;
      rune flash models still play WC3 sounds
- [ ] **talentui**: restart the spec (Dota's talent tree and Aghanim's sign art), then implement; the user
      called the rectangles disgusting
- [ ] **strings** (launcher): fill `data.strings` from the player's Dota localization, once the user decides
      ([[Player-facing strings are keyed by Dota localization tokens]])

## Still to check in game

- [ ] Quick cast of Poof and Sticky Bomb at a point; Stop interrupts the TP scroll; Techies' M.A.D. on D
- [ ] Rubick's stolen spells on D (stolen Warcraft spells have no quick cast yet)
- [ ] Glyph, Scan and buyback buttons; Scan from a minimap click; denies show "!"
- [ ] The item block at 4:3, 16:9 and 21:9; the courier with F2 and F3 and its flying form
- [ ] Shard and Scepter effects (`-item shard`, `-item scepter`); the talent tree picks
- [ ] Buy, sell and rune sounds; no Warcraft warning voices for Dota players (`-wc3ui` compares)
- [ ] Per-ability cast animations (Mana Void "Spell Four", three different razes)
- [ ] Classic graphics: the ground textures are broken; ask the user what exactly shows

## Small fixes (no agent needed)

- [ ] Hover highlight flickers on HUD buttons (minor)
- [ ] `dota_settings` `pressItem` direct item uses need the cooldown pre-check; the right-click hold may
      walk toward the ground under the HUD (mouse events over UI report ground coordinates)
- [ ] Blink Dagger: delay the move one tick so WC3's own cooldown starts by itself
- [ ] Meepo's Dig and MegaMeepo cast clips look swapped; Keen Teleport could use `stand,channel`;
      code-played animations for Blast Off, Dismember's start and TP arrival
- [ ] Retry around `os.replace` in the launcher's model cache (WinError 5 once)
- [ ] The `-respawn` cheat should call `heroes.revive`; bounty runes and Midas through `economy.earn`
- [ ] Widen `world_camps` `C.LEASH` (800) for creep pulls; Dota's Glyph and Scan hotkeys
- [ ] The HUD clock runs 30 s ahead of Dota time
- [ ] Inventory gaps: pick up into the backpack when the main slots are full (also avoids Warcraft's
      "inventory is full"); sell stash items from the UI; the 40 s sellback at game start; error lines
      into `data.strings`
- [ ] Dota art for the courier, stash, TP slot and backpack; courier models in `specs/models.json`
- [ ] `docs/FRAMEWORK.md`: lane, talents, inventory, courier, effects (`Fx.model`), sound warm-up, cheats
- [ ] Lane gaps: streak and assist gold, Dota's hero-kill XP, illusion bounties, Warcraft building bounties
- [ ] Mock check counts vary between runs (174/175)

## Publishing on Melty

- [ ] With the VPN off: `list_my_mods`, `search_games`, `game_info`
- [ ] Recipe: warcraft-iii + dota-2, the launcher in `{managed}`, `maxPlayers` 6, no `connect`
- [ ] Release steps, in order: `inspect_package`, `validate_recipe`, `one_click_check`, `create_mod` (MIT,
      remixes allowed), uploads, a real screenshot, `submit_release`, publish with the user's go-ahead
- [ ] Say honestly that multiplayer was not tested with two clients
- [ ] The personalized map is about 70 MB; the 128 MB limit is from patch 1.29's notes, untested on 2.0.1
- [ ] A 21 s launch video exists in `build\brag-output\` (not in git)

## Done (2026-10-11, night)

- [x] Native-ability quick cast (Blink); swing guard against denying at full health and hitting allies
- [x] Test builds end the game; `-noend`, `-item`, `-log`; log lines off the screen
- [x] Talents, Scepter and Shard for all 11 heroes
      ([[Talents, Scepter and Shard reach abilities through one value lookup]])
- [x] 39 Dota effects ([[Dota spell effects reach the map through data.effects, missiles through object data]])
- [x] Item cooldowns enforced; drag and drop through synced hovers plus a click mode
- [x] HUD: foreign units' abilities, clickable top-bar portraits, blocker glare faded
- [x] Grove of 51 trees with triple lumber ([[The Warcraft base has a grove of 51 Dire trees with triple lumber]])
- [x] Sounds warmed up and freed by timers; Warcraft UI voices muted for Dota players
- [x] Per-ability cast animations ([[Each Dota ability plays its own cast animation through Spell tags]])
- [x] Rename to Dota vs Warcraft; `tools/fetch_research.py` for clean clones; stricter mock error check

## Done (2026-10-11)

- [x] Lane rules ([[Lane rules run in lane.lua on top of WC3 combat]]); Dota buildings in slot 10
      ([[Dota buildings live in slot 10 outside the lobby so creeps can be pulled]])
- [x] Backpack, stash, TP slot, courier ([[Items live in Lua slots – main, backpack, TP, stash and courier]])
- [x] Dota trees, ground tiles, cliffs, music, announcer and gameplay sounds; quick cast; auto-attack
- [x] The Warcraft AI takes a playing computer slot and gets a starter base
      ([[The Warcraft AI starts with a starter base of stock WC3 structures]])

## Done (2026-10-10)

- [x] Build pipeline; 11 heroes; items and shops; bots; voice responses; the launcher with Dota models,
      icons, voice lines and the map layout; the Dota HUD and shop; Dota settings import; public GitHub
      repo, this vault and CLAUDE.md
