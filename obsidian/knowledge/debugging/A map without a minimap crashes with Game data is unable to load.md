---
tags: [debugging, engine, loading]
date: 2026-10-10
---

# A map without a minimap crashes with Game data is unable to load

## Symptom

Starting the map shows the crash dialog "Game data is unable to load".

## Cause

The archive had no `war3mapMap.blp` and no `war3map.mmp`.

## Fix

- `tools/gen_minimap.py` renders both files from the terrain and the layout.
- The loading screen preset is set to 0 in `w3i`.

Related: [[The map is built from source with one build.py command]]
