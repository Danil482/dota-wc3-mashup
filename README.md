# Dota vs Warcraft

A Dota 2 × Warcraft III mashup for **Warcraft III Reforged**. Up to five Dota heroes (bots fill
the empty slots) fight one **Warcraft player**, who plays a full WC3 race: base building,
heroes, an army of their own, and uncontrollable creep waves every 30 seconds. The battlefield
is Dota's: three lanes, the river, neutral camps, runes and Roshan.

Status: in development. Not yet released.

## What you need to play

- Warcraft III Reforged (developed and tested on 2.0.1)
- Dota 2, installed. The launcher reads the hero models, icons and voice lines from your own
  copy.

**This repository contains no game content.** The launcher (`launcher/`) builds a personal copy
of the map on your PC from your Dota 2 install. Nothing from either game is distributed here.

## Features

- 11 Dota heroes with their current kits and innates:
  - Pudge
  - Meepo
  - Tinker
  - Rubick
  - Morphling
  - Nature's Prophet
  - Chen
  - Anti-Mage
  - Techies
  - Ogre Magi
  - Shadow Fiend
- Dota items and shops.
- Bots that follow Valve's bot data for lanes, skill builds and item builds.
- The Warcraft side: any WC3 race, played by the Warcraft AI when no human takes the slot.
- The Dota map: neutral camps, runes, Roshan with Aegis, backdoor protection, lane creep
  upgrades.

## Build from a clean clone

You need Windows with Git, Python 3.12, Node.js 22.12 or newer, and Warcraft III Reforged
installed: the build reads Warcraft's object data tables from your own install. In PowerShell:

```
git clone https://github.com/Danil482/dota-wc3-mashup.git
cd dota-wc3-mashup
py -3.12 -m venv .venv
.venv\Scripts\python.exe -m pip install -r tools\requirements.txt
.venv\Scripts\python.exe -I tools\fetch_research.py
.venv\Scripts\python.exe -I tools\build.py --test --work build\work_dev
```

`tools/fetch_research.py` fills the git-ignored inputs of the build:

- `research/jass/`: jassdoc's `common.j` and `Blizzard.j` for the offline mock, from a pinned
  commit, SHA-256 checked.
- `research/slk/`: the SLK tables, read from Warcraft III's CASC storage.
- `tools/vendor/stormlib/`: StormLib 9.40, from the pinned release zip, SHA-256 checked.
- `tools/node_modules/`: `npm ci` from the lockfile.

It finds Warcraft III by itself; pass `--wc3 <folder>` if it can't. `--dota` also extracts the
Dota 2 data that the data-refresh tools read. A good build prints `MOCK RESULT: OK`. The autotest's
FAIL lines on the mock are expected, because the mock has no real units.

`docs/FRAMEWORK.md` describes the Lua framework. Architecture notes live in the Obsidian vault
under `obsidian/`.

## Credits

- [StormLib](https://github.com/ladislav-zezula/StormLib) by Ladislav Zezula (MIT): MPQ archives
- [ValveResourceFormat / Source2Viewer](https://github.com/ValveResourceFormat/ValveResourceFormat) (MIT): reading Dota 2 files
- [mdx-m3-viewer](https://github.com/flowtsohg/mdx-m3-viewer) (MIT): WC3 file formats
- [jassdoc](https://github.com/lep/jassdoc): the WC3 API reference used for the offline mock

Dota 2 is a trademark of Valve Corporation; Warcraft III is a trademark of Blizzard
Entertainment. This project is not affiliated with or endorsed by either company.

## License

MIT, see [LICENSE](LICENSE). Remixes are welcome.
