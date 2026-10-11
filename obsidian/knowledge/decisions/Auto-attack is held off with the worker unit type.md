---
tags: [decision, controls, settings]
date: 2026-10-11
---

# Auto-attack is held off with the worker unit type

## Decision

While Dota's auto-attack setting says a unit must not pick targets on its own,
`src/ui/dota_settings.lua` gives it the worker type (`UNIT_TYPE_PEON`) and takes it away
afterwards. Workers never acquire targets by themselves, but they still attack, deny and
attack-move when ordered.

- Dota's Never / Standard / Always semantics are unchanged.
- Units whose own type is a worker are left alone.
- The stop-on-acquire guard stays as a backstop. Its log line says whether the unit was a
  worker at that moment.

## Why

- `SetUnitAcquireRange(u, 0)` is ignored by the engine; see
  [[SetUnitAcquireRange ignores 0, so a zero range can't stop auto-attacks]].
- WC3 also pulls idle units into nearby fights through `CallForHelp=600` in
  `Units\MiscGame.txt`, whatever the acquisition range.
- A guard that stops the hero after it takes a target lets him lurch toward creeps.

The user confirmed the change in game on 2026-10-11: no target was taken in 4.5 minutes.

## Watch for

- An idle-worker button in the HUD.
- Drag selection.
- How the AI prioritises targets.

Related: [[Dota settings reach the game through a local file, never the map]]
