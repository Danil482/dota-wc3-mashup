---
tags: [session, build, heroes, launcher]
date: 2026-10-10
---

# Mashup skeleton from an empty folder to Dota models in game

This is the first session. It began with the Melty creator prompt and ended with a playable
personalized map and a public repo.

## What was done

- **Design** agreed with the user, see
  [[Up to five Dota heroes fight one Warcraft commander]]:
  - WC3 is the host;
  - an asymmetric match of up to 5 Dota heroes against 1 commander;
  - 11 heroes;
  - MIT with remixes allowed.
- **Build pipeline and map format** for Reforged 2.0.1 (see
  [[The map is built from source with one build.py command]]). The map loads after three fixes:
  - no print/Preload during load;
  - a minimap;
  - StormLib packing.
- **Framework**: events, timers, modifiers, stats, damage, the ability registry, sound and log,
  plus an offline mock with per-hero exercises.
- **Agents built** 11 heroes, items and 12 shops, bots driven by Valve bot data, and the
  launcher: icons, voice lines, and models for 22 units. The world agent built 14 neutral
  camps, runes, Roshan with the Aegis and Cheese, lane creep upgrades, backdoor protection
  and the tier-1 aura. The lead hooked the world into `game.lua`, `economy.lua` and
  `creeps.lua`; it is checked on the mock only.
- **Test helpers**: level 30 heroes, immortal hero and creep dummies, and an enemy caster
  switched on with `-spells`.
- **Fixes from the user's in-game tests**:
  - bots no longer control the human's hero, and humans pick first;
  - channels can be cancelled ([[Channels never lock the command card]]);
  - Shadow Fiend's ultimate is back, and its razes are linked;
  - Ogre Magi's Dumb Luck works, along with item HP and mana bonuses
    ([[Health and mana bonuses are applied as deltas with BlzSetUnitMaxHP]]);
  - Techies' Tazer casts instantly on W, with Detonate on the second W press;
  - Blast Off clears trees only within 175;
  - invisible models fixed ([[Test builds use WC3 stand-in models]]);
  - hotkeys fixed ([[Ability hotkeys come from the command card cell]]).
- **Dota voice responses** for heroes ([[Hero responses are Dota voice lines played from Lua]]).
- **The user confirmed in game** that Dota models and textures render on the personalized map.
- **Repo**: this vault, CLAUDE.md, README and LICENSE; pushed to a public GitHub repo.

## What was not done

- **Melty publishing**: blocked while the user's VPN is on
  ([[Melty cannot check the token while a VPN is on]]).
- **Multiplayer**: not tested with two clients.
- **Still running in agents**:
  - building portraits and Dota models for neutrals, Roshan and summons, plus `uwal`;
  - item icons, HUD textures and more voice lines;
  - the Dota-style HUD and shop.
- **`research/`** (jassdoc and SLK metadata) is not in git, so a fresh clone cannot build yet.

## Key decisions

- [[Warcraft III is the host game, not Dota 2]]
- [[Map archives are packed with StormLib, not mdx-m3-viewer]]
- [[Dota models are converted to MDX 800 for both graphics modes]]
- [[Test builds use WC3 stand-in models]]
- [[Ability hotkeys come from the command card cell]]
- All docs in this repo are in English; chat with the user stays in Russian.

## Open questions

- **Bounty rune spots**: 6 spots, one per outer jungle. Should it be two?
- **Tower armor aura**: tier 1 only for now. Liquipedia also lists it on tier 3.
- **Backdoor damage reduction**: 40% from patch notes. It may now be 50%.
- **Aegis**: relies on WC3 reincarnation firing no death event. Check this in game.

## Next session – entry points

1. Integrate the agents' results:
   - the HUD init line in `src/game/game.lua`;
   - rebuild `dist` with `launcher\build.ps1`.
2. Build a personalized test map ([[Dota content reaches the map only through the launcher]])
   and launch it with `tools\run_test.ps1`. The user clicks through the start dialogs.
3. With the VPN off: the Melty steps in [[Current priorities for October 2026]].
