---
tags: [debugging, engine, loading]
date: 2026-10-10
---

# print or Preload during map load keeps the map from opening

## Symptom

The game loads the map and drops back to the main menu, with no error.

## Cause

`print()` or `Preload` called while the map loads, in `main()` or `config()`. Reforged 2.0.1
refuses the map.

## Fix

- All mod code starts from a 0 s timer after `main()`.
- `Log` buffers until `Log.ready`.
- On-screen messages use `DisplayTimedTextToPlayer`, never `print`.

## How it was found

We bisected with probe maps:
1. A known-good ladder map with a Preload hook.
2. The same map repacked.
3. Our files with a quiet script.

The probe scripts were deleted after the fix.

Related: [[A map without a minimap crashes with Game data is unable to load]]
