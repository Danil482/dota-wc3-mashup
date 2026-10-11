---
tags: [decision, naming, project]
date: 2026-10-11
---

# The WC3 side is called Warcraft, never commander

## Decision

On 2026-10-11 the user renamed the project from "Dota vs Commander" to **Dota vs Warcraft** and asked
that the word "commander" leave the project entirely. The WC3 side is "Warcraft": the Warcraft player,
the Warcraft AI, the Warcraft base.

## What changed

- Names: `DotaVsWarcraft.exe`, `dist\DotaVsWarcraft`, `DotaVsWarcraft(_test).w3x`, the CustomMapData and
  `%LOCALAPPDATA%` folders `DotaVsWarcraft`, the map title "Dota vs Warcraft", lobby slots "Warcraft" and
  "Warcraft AI", the top bar "Warcraft (AI)".
- Launcher internals: `launcher/dvw_launcher`, `DVW_USER_DIR`, data markers `-- @dvw-data-begin/end`,
  Lua sync prefixes `dvw…`.
- Code: modules `warcraft` and `warcraft_base`, `Roles.warcraft`, `SLOT_WARCRAFT(_AI)`, the side value
  `"warcraft"`, `mapdata.warcraft`, the cheat `-gg dota|warcraft`.
- The rename ran in two phases because other agents were editing code: readable text and the vault
  first, identifiers and files once they had finished
  ([[Parallel agents split the repo by file ownership]]).

## Left as is

- The npm package `commander` (a third-party dependency of the Node tools).
- Git history and the old user folders `dist\DotaVsCommander`, `%LOCALAPPDATA%\DotaVsCommander` and
  `CustomMapData\DotaVsCommander` on the user's PC.

Related: [[Up to five Dota heroes fight one Warcraft player]]
