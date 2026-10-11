---
tags: [debugging, controls, engine]
date: 2026-10-11
---

# SetUnitAcquireRange ignores 0, so a zero range can't stop auto-attacks

## Symptom

With Dota's Standard auto-attack, the hero still ran at creeps after a move or a stop. The guard
logged `took a new target after move (mode 1, range 600, ...)` right after its own refresh had
set the range to 0.

## Finding

The controls probe measured it on a footman with a default range of 500:

| Set | Reads back |
|---|---|
| SetUnitAcquireRange 0 | 500 |
| SetUnitAcquireRange 1 | 500 |
| SetUnitAcquireRange 100 | 100 |
| Field `UNIT_RF_ACQUISITION_RANGE` 0 | 500 |
| Field 100 | 100 |

A zero range is never applied, so it can't keep a unit from acquiring targets. WC3 also pulls
idle units into fights through `CallForHelp=600` in `Units\MiscGame.txt`.

## Fix

[[Auto-attack is held off with the worker unit type]].
