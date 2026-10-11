---
tags: [session, agents, terrain, audio, controls, warcraft, hud]
date: 2026-10-11
---

# Dota parity wave – terrain, audio, controls and the Warcraft AI

Continues [[2026-10-10 Dota terrain, working HUD and imported Dota settings]]. The session
restored the work front from the vault and gave it to background agents. The user set a new
goal: [[The Dota side aims at full parity with Dota 2]].

## What was done

- **Agents.** Seven agents started at once. A network drop on the user's side killed them all.
  After that they restarted at most three at a time, which is now a rule in CLAUDE.md
  ([[Parallel agents split the repo by file ownership]]). Launcher source runs got
  `DVW_USER_DIR`, so parallel runs keep separate caches.
- **ground** (the launcher's terrain package):
  - blocked ground now looks blocked on 98.7% of blocked cells, up from 32.8%; pathing is
    unchanged ([[Blocked ground rises into cliffs only over Dota-blocked cells]]);
  - Dota trees replace WC3 trees ([[Trees stay WC3 destructables with Dota models swapped in]]);
  - Dota ground textures, chosen per blend layer.
- **audio:** Dota music, Dota's announcer and core gameplay sounds for Dota players
  ([[Dota music plays as 2D sounds mixed per player by volume]]). The init lines are in
  `game.lua` and `victory.lua`. Hero voice lines went from 496 to 648.
- **controls** (and the first inventory agent, which spent its run on the same file):
  - quick cast casts from build data;
  - Channel orders come from pools per target kind
    ([[Channel orders come from pools that match the target type]]);
  - auto-attack is held off with the worker unit type
    ([[Auto-attack is held off with the worker unit type]]);
  - right-click hold shows the move marker;
  - failed casts play Dota's "not yet" and "no mana" lines;
  - HUD art detection no longer depends on one voice line
    ([[HUD art detection broke when one voice line was missing]]);
  - a test-build probe writes `controls_probe.txt`
    ([[Test-build engine probes answer what the mock can't]]).
- **Warcraft AI:**
  - a starter base of stock WC3 structures
    ([[The Warcraft AI starts with a starter base of stock WC3 structures]]);
  - AI diagnostics every 30 s in test builds;
  - `ForcePlayerStartLocation` added in `main.lua`. It was not the cause of the idle AI; see
    [[The Warcraft AI idles because its computer slot is empty in single player]].
- **inventory** (second agent):
  - item cooldown sweep and charges on the HUD's item buttons;
  - HUD buttons now sit inside transparent click blockers;
  - `items.json` gained `secret` and `shareable` flags;
  - `src/game/inventory.lua` holds backpack, stash, TP slot and courier storage, but it is not
    wired into the game yet.
- **Launcher dist** rebuilt with the ground and audio changes. The personalized map is 68.8 MB,
  and a cold launcher run takes 57 s.
- **Three in-game tests**, run by the user:
  - working: right-click hold with its marker, denies, unit quick cast, point quick cast
    (after the order pools), auto-attack (no target taken in 4.5 minutes), HUD art, music,
    the "not yet" line, Dota trees and ground in Reforged graphics;
  - the probe settled why point casts failed ([[Point quick casts failed on Channel orders the engine refuses]])
    and that SetUnitAcquireRange ignores 0 ([[SetUnitAcquireRange ignores 0, so a zero range can't stop auto-attacks]]).

## What was not done

- **talents, vfx and bootstrap:** queued, not started. The user paused new agents because
  usage limits ran low.
- **lane:** stopped before its first edit. Its plan is below.
- **inventory tasks 3–6:** stash and buying anywhere, backpack and TP slot, drag and drop,
  courier. The plan is below.
- **Classic graphics:** the textures are broken there. The user saw it but hasn't described it
  yet; Reforged looks right.
- **Neutral clicks:** still not tested (three tests, no neutral clicked).
- **Point Channels still refused:** Meepo's Poof (`blink`) and Techies' Sticky Bomb
  (`acidbomb`) keep spec orders that the probe shows the engine refuses.
- **Bots cast nothing:** two runs, two times zero; likely no enemy hero to target while the
  Warcraft AI idles.
- **Melty publishing:** not touched.

## Key decisions

- [[The Dota side aims at full parity with Dota 2]]
- [[Channel orders come from pools that match the target type]]
- [[Auto-attack is held off with the worker unit type]]
- [[Dota music plays as 2D sounds mixed per player by volume]]
- [[Blocked ground rises into cliffs only over Dota-blocked cells]]
- [[Trees stay WC3 destructables with Dota models swapped in]]
- [[The Warcraft AI starts with a starter base of stock WC3 structures]]
- At most three agents run at the same time (CLAUDE.md).

## Open questions

- **Classic textures:** what exactly breaks? The ground agent writes classic tiles as BLP and as
  DDS at `TerrainArt\<set>\<file>`; one of them may confuse the classic renderer.
- **Warcraft AI after the slot fix:** does the melee AI play once it runs in a playing computer
  slot?
- **The base that vanished:** in the Reforged run, at 4:00 the AI's summary dropped to 0
  structures and 0 workers, with no "game over" line. What removed the base, and why didn't
  victory fire?
- **Lane rules:** may short Dota error strings ("Can't Deny, Target Health Too High") be used
  word for word?
- **Lane numbers:** deny XP share, aggro radius and duration, Glyph and Scan cooldowns, and the
  buyback formula are Dota game code, not in the player's files; they need wiki citations.

## Lane plan (research only, no code)

1. **Denies.** A synced order handler refuses attacks on allies unless the target is a non-hero
   below 50%, a tower or barracks below 10%, or a ward. Then:
   - a "!" text tag for everyone;
   - the enemy gets a reduced XP share and no gold;
   - the last-hit gold popup is shown to the killer only;
   - bots deny in `hero_bot.lua`.
2. **Pulls.** Move the Dota buildings to a new slot 10 outside the lobby, passive with Neutral
   Hostile, and make the lane creeps' slot hostile to neutrals again. Same step:
   - `announcer.lua:230` must filter by `UNIT_TYPE_STRUCTURE`;
   - `economy.lua:84` pays hero slots only.
   - Risk: check in game that towers on a slot outside the lobby still shoot.
3. **Aggro.**
   - When a Dota hero attacks an enemy hero, the Warcraft side's lane creeps within 500 switch
     to him for about 2.3 s.
   - When a Warcraft unit does it, our lane creeps and the Dota towers that have it in range
     switch to it.
   - `creeps.lua` then resumes the lane order.
4. **Glyph and Scan.**
   - Glyph lives in `structures.lua`, next to tier protection.
   - Buttons go under `Hud.F.fgBottom`, by the minimap's top right.
   - Announcer lines: `fort_rad` and `scan_rad`.
5. **Day and night.** `SetFloatGameState(GAME_STATE_TIME_OF_DAY, 6)` at world start, and a
   600 s cycle (`DayLength` in the misc block). Dota's vision values come from `npc_units.txt`.
6. **Buyback.**
   - `heroes.lua` needs an early-revive API.
   - Cost 200 + net worth/13 and a 480 s cooldown, both from memory.
   - Call `music.buyback(hero)` before the respawn event.
7. **Kill gold.** Compare `economy.lua` with Dota. Today a hero kill pays the killer only, and
   every structure pays 150 gold to the last hitter only.

## Inventory plan for tasks 3–6

- **Purchases.** Pay for the missing pieces only. Each piece goes through `Inv.receive`:
  - to the hero at the home shop, or at a secret shop for secret items;
  - otherwise to the stash;
  - otherwise it drops at the fountain.
- **Combining.**
  - It runs per location: the hero (main slots and backpack), the stash, the courier.
  - Hero and stash combine together only at home.
  - The result takes the first consumed slot.
- **Secret shops.**
  - Secret items sell only at `mapdata.side_shops`; shop unit 5 moves there.
  - The shop stops refusing purchases for "too far" and "dead".
- **HUD.** The HUD block widens to about 0.17: a backpack row under the items, the TP slot and
  a stash row above.
- **Drag and drop.** Synced frame MOUSE_ENTER/LEAVE plus the player's mouse down and up.
- **Courier.**
  - A unit and its own module.
  - Courier keys need new launcher and `dota_settings` fields.
- **Bots.** They call `Inv.arrange` and grab their stash at home.
- **Wiring.** Add `use("inventory").init()` right after `use("items").init()` when the module
  is wired.

## Next session – entry points

1. Small fixes, no agent needed:
   - in `roles.lua`, give the Warcraft AI a playing computer slot;
   - kind-matched orders for Poof and Sticky Bomb;
   - start the day at 6:00;
   - `Ncl5 = 0` for channelled items such as the TP scroll;
   - remove the probe Channels once their answer is recorded.
2. Ask the user what broke in classic graphics, then fix the tile format.
3. When limits allow, restart agents (three at a time): talents, lane (from the plan above),
   inventory tasks 3–6, vfx, bootstrap.
4. Then the Melty steps in [[Current priorities for October 2026]].
