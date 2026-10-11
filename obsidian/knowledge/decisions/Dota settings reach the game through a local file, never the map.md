---
tags: [decision, settings, multiplayer]
date: 2026-10-10
---

# Dota settings reach the game through a local file, never the map

## Decision

The launcher (`launcher\dvc_launcher\dota_settings.py`) reads the player's Dota settings:
- keys from `Steam\userdata\<account>\570\remote\cfg\dotakeys_personal.lst`, over the VPK's
  `cfg/dotakeys.lst`;
- convars from `remote\user_convars.vcfg`.

The account is Steam's active user, then `loginusers.vdf` (AutoLogin, newest login). The
launcher writes `Documents\Warcraft III\CustomMapData\DotaVsCommander\dota_settings.txt`, a
Preload script that stores a compact string in an unused ability's tooltip.
`src/ui/dota_settings.lua` loads it with Preloader after the game starts and syncs what game
state needs.

## Why not inside the map

Every player in a lobby must have the identical map file, and WC3 sends the host's map to
joiners. Personal settings inside the map would break joining or overwrite the joiners'
settings.

## What is applied

- ability, item, TP, shop and select-hero keys;
- per-key quick cast at the cursor, from synced mouse moves (`BlzGetMouseWorldX/Y` don't exist
  in 2.0.1). The cast uses string orders from build data
  ([[Channel orders come from pools that match the target type]]);
- double-tap self cast;
- auto-attack modes 0/1/2, held off with the worker unit type
  ([[Auto-attack is held off with the worker unit type]]);
- right-click semantics;
- camera distance and zoom lock;
- right-click hold to move, with WC3's move marker shown to the holder only;
- Dota's "not yet" and "no mana" lines when an ability key fails;
- since 2026-10-11: the TP key uses the TP slot, and the courier keys (select F2, deliver F3,
  Speed Burst, Shield, Grab All) drive the courier
  ([[Items live in Lua slots – main, backpack, TP, stash and courier]]). The launcher's
  `MAX_DATA` grew from 250 to 300 characters; the part synced between players stays under 255.
  The launcher dist must be rebuilt before a personalized test picks these keys up.

## Not possible

- Keys that clash with native hotkeys are skipped: WC3 can't turn a native hotkey off.
- Edge-pan and camera speed can't be set.
- Glyph and Scan have no hotkeys yet.
