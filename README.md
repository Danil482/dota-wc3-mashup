# Dota vs Commander

A Dota 2 × Warcraft III mashup for **Warcraft III Reforged**. Up to five Dota heroes (bots fill
the empty slots) fight one **commander**, who plays a full Warcraft race: base building,
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
- The commander side: any WC3 race, with an AI commander when no human takes the slot.
- The Dota map: neutral camps, runes, Roshan with Aegis, backdoor protection, lane creep
  upgrades.

## Building from source

- Python 3.12 (`.venv`), plus Node.js for `tools/`.
- Run `npm install` in `tools/`.
- Put the StormLib x64 DLL in `tools/vendor/`.
- `research/` is not included. It needs jassdoc's `common.j` / `Blizzard.j` and the WC3 SLK
  metadata.

```
.venv\Scripts\python.exe -I tools\build.py --test --work build\work_dev
```

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
