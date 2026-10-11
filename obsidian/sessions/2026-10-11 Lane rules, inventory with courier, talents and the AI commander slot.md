---
tags: [session, agents, lane, inventory, talents, commander, controls]
date: 2026-10-11
---

# Lane rules, inventory with courier, talents and the AI commander slot

Continues [[2026-10-11 Dota parity wave – terrain, audio, controls and the AI commander]] on the
same day. The session picked up the plan: the lead made the small fixes, and three agents ran at
once (talents, inventory, lane). The user asked to wrap up once the three had reported, without
starting new agents.

## What was done

- **Small fixes by the lead:**
  - The AI commander now takes a computer that is actually playing. The order is slot 5, slot 7,
    then any playing computer among the user slots (slot 1 in a game started straight from the
    map). If none plays, slot 7 with a warning. `Cmd.setup` moves that slot's start location to
    the commander base, because the melee AI builds around its start location. See
    [[The AI commander idles because its computer slot is empty in single player]].
  - Poof got `massteleport`, and Sticky Bomb a pool order (`blizzard`). The probe saw the engine
    accept both as point orders on other heroes
    ([[Channel orders come from pools that match the target type]]).
  - Channelled items get `Ncl5 = 0`, so Stop or a move interrupts the TP scroll. The Lua already
    teleports only after a full channel ([[Channels never lock the command card]]).
  - The 18 synthetic probe Channels are gone. The controls probe keeps its hero Channel and
    acquisition parts ([[Test-build engine probes answer what the mock can't]]).
  - The mock runtime can mark computers as playing (`__mock.computers`), and the commander
    exercise checks the slot choice.
- **lane** finished all seven items of its plan; see
  [[Lane rules run in lane.lua on top of WC3 combat]]:
  - a 600 s day: night before the horn, dawn with the horn, Dota vision for buildings and creeps;
  - denies with Dota's limits, a "!" for everyone, half the XP to nearby enemies; bots deny;
  - hero kill gold 125 + 8 × level, paid to hero slots only;
  - buyback with its cost, cooldown and 60% gold penalty, a revive API and a buyback button;
  - Glyph (buildings 7 s, lane creeps 3 s, tower multishot, refreshes) and Scan (two charges);
  - creep and tower aggro;
  - creep pulls: the Dota buildings moved to slot 10, outside the lobby
    ([[Dota buildings live in slot 10 outside the lobby so creeps can be pulled]]);
  - every player-facing string in `src/data/strings.json`
    ([[Player-facing strings are keyed by Dota localization tokens]]).
- **inventory** finished tasks 3–6; see [[Items live in Lua slots – main, backpack, TP, stash and courier]]:
  - buying anywhere, into the stash; Secret Shop rules; combining per place; items remember
    their buyer;
  - the backpack and the TP slot with HUD rows, and a stash row with Grab All;
  - drag and drop between slots, onto the ground and onto an allied hero;
  - one courier per human player, with Dota's command card and the player's own courier keys
    (launcher `dota_settings.py`);
  - a click on a HUD frame (reported at 0,0) no longer fires a waiting item.
- **talents** stopped early (see below); see
  [[Talents, Scepter and Shard reach abilities through one value lookup]]:
  - `heroes.json` carries 8 talents and the Scepter and Shard upgrades for all 11 heroes;
  - `talents.lua` holds talents, Attribute Bonus, Scepter and Shard; `dota_talents.lua` draws the
    tree and Aghanim's sign; the shop sells the Shard; bots take talents;
  - unique talents and upgrades are coded for 8 heroes: Pudge, Meepo, Tinker, Rubick, Morphling,
    Nature's Prophet, Chen and Anti-Mage.
- **Integration.** The lead added six init lines to `game.lua`. The full build in
  `build\work_lead` prints `MOCK RESULT: OK`, with all 18 exercises at 0 failed.
  `src/data/ids.json` was refreshed from that build.

## What was not done

- **talents died at Anti-Mage** with "Prompt is too long": its context filled up
  ([[Parallel agents split the repo by file ownership]]). Not done:
  - Techies, Ogre Magi and Shadow Fiend have no unique talents, Scepter or Shard yet;
  - their modules still read values without the unit, so linked talents don't reach them;
  - Anti-Mage's exercise passes, but his part needs a check.
- **vfx and bootstrap** didn't start: the user said no new agents.
- **No in-game test** this session, so nothing new is confirmed in game.
- **Classic graphics:** the user hasn't described the bug yet.
- **The base that vanished at 4:00:** not looked into. The diagnostics will show it if it
  happens again.
- **The launcher dist** wasn't rebuilt, and the courier keys need it.
- `docs/FRAMEWORK.md` doesn't cover the new modules.

## Key decisions

- [[Dota buildings live in slot 10 outside the lobby so creeps can be pulled]]
- [[Player-facing strings are keyed by Dota localization tokens]]
- The AI commander takes a playing computer slot and moves its start location to the base.
- Lane numbers that Dota's files don't hold come from cited third-party pages and stay marked
  as unverified (the list below).

## Open questions

- **Strings:** may the fallbacks use Dota's exact words, or should the launcher fill
  `data.strings` from the player's own localization, in the player's language? The lead
  recommends the launcher.
- **Unverified lane numbers** (all cited in the code):
  - Glyph 300 s cooldown, first ready 180 s after the horn;
  - Scan 2 charges × 210 s;
  - buyback 200 + net worth / 13, 480 s cooldown, +25 s on the next death;
  - deny XP radius 1500 (1200 seen too); wards deniable at any health;
  - aggro 500 range, 2.3 s, 3 s cooldown;
  - hero kill gold 125 + 8 × level (patch 7.31).
- **Unverified inventory numbers:**
  - hand-over range 250;
  - Secret Shop range 900;
  - courier bounty (35 in `npc_units`, 25 + 5 per level on the wiki);
  - courier speed capped by `MaxUnitSpeed` 550.
- Does the melee AI play once the AI commander runs in slot 1?
- Do towers on slot 10 still shoot?

## Next session – entry points

1. Rebuild the launcher dist, then an in-game test (the user clicks):
   - the AI commander in slot 1;
   - Poof, Sticky Bomb and the TP interrupt;
   - towers on slot 10, the 600 s day, the Glyph, Scan and buyback buttons, Scan on the minimap;
   - drag and drop, the TP slot, the item block at 4:3, 16:9 and 21:9, the courier with F2 and F3;
   - the talent tree and the Shard;
   - Rubick's quick cast of stolen spells: their D slots have no `ability_targets` entry.
2. A new talents agent with a fresh brief for Techies, Ogre Magi and Shadow Fiend, plus a check of
   Anti-Mage. Give one agent at most four heroes.
3. The agents' small follow-ups in [[Current priorities for October 2026]].
4. The vfx and bootstrap agents, then the Melty steps.
