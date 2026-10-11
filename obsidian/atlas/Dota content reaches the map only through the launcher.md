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
3. Extracts voice lines to `Sound\Dota\<hero>\<event>_<n>.mp3`, plus Dota's music, announcer
   and gameplay sounds (MP3 for music and voices, mono WAV for effects):
   - `launcher/vo_manifest.json` lists the sources; its "audio" section covers music, the
     announcer and effects;
   - `src/data/sounds.json` and `src/data/audio.json` list the paths and timings for the map
     script.
4. Converts models (`models.py` and the `mdx/` converter, listed in `specs/models.json`):
   - `war3mapImported\Dota\<key>.mdx`
   - textures `war3mapImported\Dota\<key>_<name>.blp`
5. Ports Dota's map layout into the terrain and map data (`terrain\`): cliffs over blocked
   ground, Dota trees through `war3map.w3b`, and Dota ground tiles. See
   [[Dota's map layout is ported 1 to 1 by the launcher]],
   [[Blocked ground rises into cliffs only over Dota-blocked cells]] and
   [[Trees stay WC3 destructables with Dota models swapped in]].
6. Converts item icons (`src/data/items.json` "icons") and the HUD art (`specs/hud_assets.json`).
7. Repacks the map with StormLib and verifies the archive.
8. Writes the player's Dota settings next to the map, never into it (`dota_settings.py`),
   including the courier keys since 2026-10-11; see
   [[Dota settings reach the game through a local file, never the map]].

Planned: filling `data.strings` from the player's own Dota localization
([[Player-facing strings are keyed by Dota localization tokens]]).

Models: 71 units, including static portraits for neutrals, Roshan, summons and wards, plus
wards and runes ([[Neutral portraits are static palette models]]).

The output is cached per Dota build in `%LOCALAPPDATA%\DotaVsCommander\cache`. A cold run takes
about a minute; a warm run takes about 10 s. On 2026-10-11 the personalized map was about 69 MB,
mostly sounds (37 MB).

For development, `DVC_USER_DIR` moves the cache, logs and work folders, so parallel runs from
source don't share a cache. The PyInstaller exe is a windowed app: in PowerShell, run it with
`Start-Process -Wait`, or the shell returns before the map is written.

## A personalized test map

```
.venv\Scripts\python.exe -I tools\build.py --test --dota-models --work build\work_e2e
dist\DotaVsCommander\DotaVsCommander.exe --dota "<dota 2 beta folder>" --map build\work_e2e\DotaVsCommander_test.w3x --out build\work_e2e\personal\DotaVsCommander_test.w3x --prepare-only --quiet
```

Related: [[Dota models are converted to MDX 800 for both graphics modes]],
[[Invisible units mean the map points to Dota models without the launcher]]
