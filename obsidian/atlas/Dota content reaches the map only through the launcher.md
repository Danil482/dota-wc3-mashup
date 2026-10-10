---
tags: [atlas, launcher, assets]
date: 2026-10-10
---

# Dota content reaches the map only through the launcher

Neither the repo nor a release contains Dota or WC3 models, textures or sounds. The base map
only references paths. The launcher fills those paths from the Dota 2 install on the
player's PC:
- source: `launcher/dvc_launcher`;
- PyInstaller build: `dist\DotaVsCommander\DotaVsCommander.exe`.

## What the launcher does

1. Finds Dota 2 and WC3 (`installs.py`) and reads the VPKs with
   [[VRF CLI extracts Dota resources from VPKs]].
2. Converts the icons of abilities, heroes and items (`assets.py`, `blp.py`). The map paths
   are:
   - `ReplaceableTextures\CommandButtons\BTNDota_<key>.blp`
   - the matching `DISBTN` and `PASBTN` variants.
3. Extracts voice lines to `Sound\Dota\<hero>\<event>_<n>.mp3`:
   - `launcher/vo_manifest.json` lists the sources;
   - `src/data/sounds.json` lists the paths for the map script.
4. Converts models (`models.py` and the `mdx/` converter, listed in `specs/models.json`):
   - `war3mapImported\Dota\<key>.mdx`
   - textures `war3mapImported\Dota\<key>_<name>.blp`
5. Ports Dota's map layout into the terrain and map data (`terrain\`); see
   [[Dota's map layout is ported 1 to 1 by the launcher]].
6. Converts item icons (`src/data/items.json` "icons") and the HUD art (`specs/hud_assets.json`).
7. Repacks the map with StormLib and verifies the archive.
8. Writes the player's Dota settings next to the map, never into it (`dota_settings.py`); see
   [[Dota settings reach the game through a local file, never the map]].

Models: 71 units, including static portraits for neutrals, Roshan, summons and wards, plus
wards and runes ([[Neutral portraits are static palette models]]).

The output is cached per Dota build in `%LOCALAPPDATA%\DotaVsCommander\cache`. A cold run takes
about a minute; a warm run takes 3–4 s.

## A personalized test map

```
.venv\Scripts\python.exe -I tools\build.py --test --dota-models --work build\work_e2e
dist\DotaVsCommander\DotaVsCommander.exe --dota "<dota 2 beta folder>" --map build\work_e2e\DotaVsCommander_test.w3x --out build\work_e2e\personal\DotaVsCommander_test.w3x --prepare-only --quiet
```

Related: [[Dota models are converted to MDX 800 for both graphics modes]],
[[Invisible units mean the map points to Dota models without the launcher]]
