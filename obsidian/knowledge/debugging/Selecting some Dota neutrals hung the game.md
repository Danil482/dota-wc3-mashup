---
tags: [debugging, models, portraits]
date: 2026-10-10
---

# Selecting some Dota neutrals hung the game

## Symptom

In personalized builds, clicking a neutral sometimes froze the game:
- Windows logged Application Hang (event 1002, AppHangB1), not a crash;
- WC3 wrote no crash log.

The four cases: a satyr, an owl (wildkin), after a kobold, after wolves. The same type was
fine at other times. It never happened in the stand-in build.

## How it was narrowed

- Test builds log every new HUD focus and flush at once (`hud focus <name> <type>`). The
  culprit is the click after the last logged line.
- Windows' Application event log tells a hang from a crash.

## Findings

- All 126 textures and their 1158 mips decode strictly, and all MDX files pass the checks.
- The hangs match creep sound sets with FaceFX lip-sync for SD portraits (Satyr, Owlbear, Ogre,
  ForestTroll). The kobold case does not fit.

## Mitigation (untested in game yet)

- static palette portraits: [[Neutral portraits are static palette models]];
- `usnd = ""` on neutrals and Roshan.
