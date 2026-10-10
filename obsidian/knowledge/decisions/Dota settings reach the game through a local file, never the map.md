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
- per-key quick cast at the cursor (from synced mouse moves; `BlzGetMouseWorldX/Y` don't exist
  in 2.0.1);
- double-tap self cast;
- auto-attack modes 0/1/2 with a target-acquired guard;
- right-click semantics;
- camera distance and zoom lock;
- right-click hold to move.

## Not possible

- Keys that clash with native hotkeys are skipped: WC3 can't turn a native hotkey off.
- Edge-pan and camera speed can't be set.
- There is no courier.
