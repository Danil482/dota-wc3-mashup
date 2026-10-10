---
tags: [atlas, build]
date: 2026-10-10
---

# The map is built from source with one build.py command

```
.venv\Scripts\python.exe -I tools\build.py --test --work build\work_lead
```

## Steps of `tools/build.py`

1. `gen_mapdata.py`: lanes, camps and building spots → `src/data/mapdata.json`
2. `gen_terrain.py`: heights, water, trees
3. `gen_objects.py`: object data (`w3u`, `w3a`, `w3t`, `w3h`), `war3mapMisc.txt` with the
   Dota gameplay constants, and `ids.json` with the generated object codes
4. `gen_mock.py`: a stub WC3 API generated from `common.j` and `Blizzard.j`
5. `build_lua.py`: joins `src/**/*.lua` into `war3map.lua`
6. `mock_run.py`: runs the script offline on the mock (lupa, Lua 5.3). The build stops
   unless it prints `MOCK RESULT: OK`
7. `build_map.js`: `w3i`, `w3e`, `doo` and the other map files, written to a folder
8. `gen_minimap.py`: `war3mapMap.blp` and `war3map.mmp`
9. `mpq_pack.py`: packs the `.w3x` with StormLib

## Flags

- `--test`: the autotest and cheats, plus WC3 stand-in models
- `--dota-models`: the Dota model paths from `specs/models.json`, for the launcher
- `--work <dir>`: every output goes into its own folder, so parallel agent builds don't clash
- `--heroes a,b` and `--exclude game/items,...`: build a subset of the modules
- `--no-mock`: skip the offline run

## Map format

Reforged 2.0.1:
- `w3i` v31 with `scriptMode` 1 (Lua) and `graphicsMode` 3;
- `w3e` v11, written by our own encoder and checked byte for byte against a ladder map;
- `doo` v8/11 with skins.

A map without a minimap crashes, see
[[A map without a minimap crashes with Game data is unable to load]].

Related: [[Map archives are packed with StormLib, not mdx-m3-viewer]],
[[Test builds use WC3 stand-in models]],
[[Testing runs offline on a mock and in game with user clicks]]
