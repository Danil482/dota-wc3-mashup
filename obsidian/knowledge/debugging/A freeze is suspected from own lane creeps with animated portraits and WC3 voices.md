---
tags: [debugging, hang, models, open]
date: 2026-10-11
---

# A freeze is suspected from own lane creeps with animated portraits and WC3 voices

## Symptom (2026-10-11, game 2 of the evening test)

The game froze (Windows *Application Hang*, event 1002) right after game time 229.75. No Lua error, no
"game over"; the log's last lines were refused attack orders on an allied T1 and an announcer line.

## Analysis (status: suspected, not confirmed)

- No Lua loop that can spin was found; every converted model passes `tools/check_mdx.js` and a deeper
  emitter dump (no NaN/Inf, at most 48 live particles per emitter, sequences ≥ 300 ms).
- The Radiant melee and ranged lane creeps (`dota_melee` on `nfrl`, `dota_ranged` on `nfrs`) are the only
  converted units that still pair an animated Dota portrait with a talking WC3 sound set ("Furbolg").
  That is the profile of [[Selecting some Dota neutrals hung the game]], whose fix skipped them
  (`gen_objects.py` clears `usnd` only for `neutral_*` and Roshan). Partial matches: `chen_zealot`
  (static portrait, sound set kept), `ancient` (animated portrait, TreeofLife sounds).
- Game 2 ran about 47 s behind wall time (pause or slowdown, unknown).

## Planned fix and check

Static portraits (`portrait=True` in `mdx/units.py`, `"portrait"` in `specs/models.json`) and an empty
`usnd` for `dota_melee`, `dota_ranged` and `dota_siege`; a test-build black box (`blackbox.txt`, a 1 s
heartbeat with the last 64 events and a watchdog). Next test: click own creeps 10–20 times first; on a
freeze, note the CPU in Task Manager and create a dump before closing.
