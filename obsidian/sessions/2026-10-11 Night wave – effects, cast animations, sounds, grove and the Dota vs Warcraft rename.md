---
tags: [session, agents, vfx, audio, talents, hud, items, lane, warcraft, rename, testing]
date: 2026-10-11
---

# Night wave – effects, cast animations, sounds, grove and the Dota vs Warcraft rename

Continues [[2026-10-11 Lane rules, inventory with courier, talents and the Warcraft AI slot]]. Agents ran
three at a time; two in-game tests with the user (Anti-Mage, then Pudge/Techies). The user ended the
session when usage limits ran low; the last three agents were stopped before they edited anything.

## What was done

- **Lead fixes from in-game test 1** (all mock-checked):
  - quick cast for native abilities (Anti-Mage's Blink and the natives of seven more heroes), see
    [[Quick cast sent no order for native abilities without a Channel target kind]];
  - a swing guard in `lane.lua`: an attack on an ally that may not be denied stops as it starts
    (no denies at full health, no killing teammates or own buildings), plus traces of the order path;
  - test builds end the game, `-noend` keeps it going ([[Test builds end the game like release builds]]);
  - cheats `-item NAME` (`shard` consumes Aghanim's Shard at once) and `-log`; log lines no longer
    appear on screen (file only, the user's request);
  - `Kit.blocker` fades its template's hover highlight (the panel glare);
  - the mock fails on ERROR lines that left the 600-line window, and `run_test.ps1` only on level tags
    ([[The mock missed ERROR lines that left the log's 600-line window]]).
- **Agents (all finished, MOCK RESULT OK):**
  - talents2: unique talents, Scepter and Shard for Techies, Ogre Magi and Shadow Fiend; Anti-Mage
    checked. All 11 heroes are done.
  - vfx: 39 Dota effects (17 missiles, 22 spells) converted by the launcher
    ([[Dota spell effects reach the map through data.effects, missiles through object data]]).
  - bootstrap: `tools/fetch_research.py` and `tools/requirements.txt`; a clean clone builds.
  - hudfix: item cooldowns enforced on every use path (`Items.ready`), drag and drop through synced
    hovers plus a click mode, autotest checks retry until heroes exist.
  - hud2: the ability row shows any selected unit's abilities, top-bar portraits select heroes (double
    click centres the camera), the courier countdown, quick cast for D-cell forms and Rubick's copies.
  - lumber: the Warcraft grove; the user chose 51 trees and triple lumber
    ([[The Warcraft base has a grove of 51 Dire trees with triple lumber]]).
  - audio: sounds warmed up at start and freed by synced timers instead of `KillSoundWhenDone`;
    Warcraft's UI warning voices muted for Dota players; `-sfx`, `-sfxch`, `-wc3ui` test commands.
  - anims: per-ability cast animations ([[Each Dota ability plays its own cast animation through Spell tags]]).
  - rename-1 and rename-2: the project is **Dota vs Warcraft**
    ([[The WC3 side is called Warcraft, never commander]]).
  - hang analysis (read-only), see [[A freeze is suspected from own lane creeps with animated portraits and WC3 voices]].
- **In-game test 2** (`build\work_play5`): every autotest check PASS; grove 51 × 3; sound warm-up OK;
  item cooldowns and drag and drop work per the user; the game froze at about 230 s.
- **Launch video** with the `brag-slim` skill: `build\brag-output\brag.mp4` (21 s, gameplay from the
  user's recording, original synthesized soundtrack, "Dota vs Warcraft"); kept out of git because the
  frames show Dota and WC3 art.
- **Live tests:** the user allows auto-clicking the two start dialogs only when they say so in a session
  (CLAUDE.md rule 3); the click positions still need calibrating.

## What was not done

- **warbase** (stopped after research, no edits): 11 Warcraft towers at the Dire spots with Dota's tower
  numbers (T1 1800 HP armor 12 dmg 88–92; T2/T3 2500, 16, 170–174; T4 2600, 21, 170–174; 0.9 s, range
  700), race looks `hgtw`/`owtw`/`uzg1`/`etrp`, Dota tier protection, neutral buildings (Tavern,
  fountains, Goblin Merchant and Laboratory, Mercenary Camp, Marketplace). Notes in
  `build\work_warbase\progress.md`. The Dota towers' damage in `gen_objects.py` is hand-set and doesn't
  match Dota's numbers.
- **hangfix** (stopped after analysis): static portraits and empty sound sets for `dota_melee`,
  `dota_ranged`, `dota_siege`; the black box; timer/log/Dismember guards. Steps in
  `build\work_hangfix\progress.md`.
- **talentui** (stopped mid-spec): the talent tree still draws rectangles, which the user dislikes.
- **vfx2**: missiles mostly invisible in game; Dota visuals for Glyph, Mana Break and mana burn;
  Techies' Minefield Sign model; an in-game effects gallery cheat; the hover flicker.
- **audio2**: Dota attack and impact sounds per hero, creep and tower (they are WC3's today); item pickup,
  drop and ping sounds.
- `src/data/ids.json` was not refreshed with a main build; the `-AutoStart` click positions.

## Key decisions

- [[The WC3 side is called Warcraft, never commander]]
- [[Test builds end the game like release builds]]
- [[The Warcraft base has a grove of 51 Dire trees with triple lumber]]
- [[Dota spell effects reach the map through data.effects, missiles through object data]]
- [[Each Dota ability plays its own cast animation through Spell tags]]
- Log lines go to the file only in test builds; `-log` shows them.
- Live tests: the lead may auto-click the start dialogs only on the user's word in that session.

## Open questions

- Delete the old `DotaVsCommander` folders (`dist`, `%LOCALAPPDATA%`, CustomMapData)?
- Was game 2 paused or alt-tabbed (it ran ~47 s behind wall time)?
- Warcraft tier protection: lock every Warcraft structure, or only those inside the base (warbase's
  suggestion, as `world_towers.lua` does for the Dota base)?
- Meepo's Dig and MegaMeepo cast clips look swapped in Dota's data.

## Next session – entry points

1. Refresh `src/data/ids.json` (main build), rebuild dist, and test in game: click own lane creeps 10–20
   times first (the suspected freeze).
2. hangfix with a fresh brief from its progress notes.
3. warbase with a fresh brief from its progress notes (and the protection-scope decision).
4. vfx2 (missiles first), audio2, then the talent tree UI (restart the spec).
