---
tags: [debugging, models, launcher]
date: 2026-10-10
---

# Invisible units mean the map points to Dota models without the launcher

## Symptom

- Units are invisible: only the selection circle shows.
- Portraits are black.
- The user reports that a hero "disappeared".

## Cause

The object data references `war3mapImported\Dota\<key>.mdx`, but the launcher never put the
files into this map.

## Fix

- Build test maps with stand-ins (the default for `--test`).
- Or personalize the map with the launcher before playing it.

See [[Test builds use WC3 stand-in models]].

## Expected in test builds

Green command-card icons are normal in test builds: `BTNDota_*` textures also come from the
launcher.
