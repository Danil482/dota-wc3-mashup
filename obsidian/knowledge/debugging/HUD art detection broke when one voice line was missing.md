---
tags: [debugging, hud, launcher]
date: 2026-10-11
---

# HUD art detection broke when one voice line was missing

## Symptom

A personalized test map showed the HUD with WC3 textures. The log had `dota_hud: ... dota art false`.

## Cause

`Kit.detect` in `src/ui/hud_kit.lua` decided "the launcher's files are here" from one sound:
the first voice line of the first hero in `data.sounds`. The audio agent added new events
(`aegis`), which sorted first. The older launcher used for that test didn't extract them, so the
one line it checked was missing.

## Fix

`Kit.detect` accepts the first line of any long-standing event (spawn, move, attack, kill,
death, levelup) of any hero.

A sturdier option is still open: a launcher-written marker module (`data.launcher`) next to the
`data.mapdata` block.

## Lesson

A test map must be built with a launcher that matches the base map. After changing what the
launcher extracts, rebuild `dist` (`launcher\build.ps1`) or run the launcher from source.
