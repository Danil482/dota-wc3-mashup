# CLAUDE.md – rules for this repo

This file is the contract for Claude and any other AI assistant working in this repo. It
overrides default behaviour. Read it before touching files.

## Project at a glance

- **What**: Dota vs Commander, a Warcraft III Reforged Lua map. Up to five Dota 2 heroes
  (bots fill empty slots) fight one commander who plays a full WC3 race, with creep waves
  from the base.
- **Content**: the Dota models, icons and voice lines come from the player's own Dota 2
  install through the launcher in `launcher/`. The repo and every release contain no Dota or
  WC3 assets.
- **Publishing**: on Melty (melty.gg), license MIT, remixes allowed.
- **Status board**: `obsidian/00-home/Current priorities for October 2026.md`.
- **Session log**: `obsidian/sessions/`.

## Language

1. Chat with the user is in **Russian**. Use the en-dash (–), not the em-dash, in Russian
   text.
2. Everything written into the repo is in **English**: the Obsidian vault (notes and file
   names), this file, README, code comments and commit messages.

## Reporting

- 2–4 sentences: result first, then what to do next.
- No tool narration and no recaps.
- At most one caveat, and only if it changes the next step.

## Hard rules

1. **No game content in git or in an upload.** That means no Dota or WC3 models, textures,
   sounds, or raw game data files.
   - `research/` (jassdoc, SLK metadata, extracted Dota scripts) and `build/` stay
     untracked.
   - Only launcher output on the player's PC may hold Dota files.
2. **Secrets.** The Melty token goes only in the `Authorization` header of Melty calls: never
   in files, commits, logs, screenshots or replies.
   - Never read `.env`, `.env.*` or `config.py`.
   - If Melty reports the token invalid or revoked, ask the user for a fresh Publish prompt.
     Don't loop retries.
3. **In-game tests.**
   - The user clicks the start dialogs ("OK", then "Play offline") on every launch. Tell the
     user before launching.
   - Never simulate mouse or keyboard input.
   - Screenshots capture only the game window (PrintWindow), never the whole screen.
4. **Git.**
   - Commit only when the user asks.
   - Stage files by name.
   - Never force-push.
   - Never skip hooks.
5. **Publishing on Melty** happens only with the user's explicit go-ahead.

## Build and test

```
.venv\Scripts\python.exe -I tools\build.py --test --work build\work_<name>
powershell -ExecutionPolicy Bypass -File tools\run_test.ps1 -Map build\work_<name>\DotaVsCommander_test.w3x -Timeout 3000 -Keep
```

- A build is good only if it prints `MOCK RESULT: OK`. Autotest FAIL lines on the mock (towers,
  XP) are expected, because the mock has no real units.
- `--test` uses WC3 stand-in models. `--dota-models` uses the paths that only a personalized
  map has.
- To get a personalized map, rebuild the launcher with `launcher\build.ps1`, then run
  `dist\DotaVsCommander\DotaVsCommander.exe --dota "<dota 2 beta>" --map <w3x> --out <w3x> --prepare-only --quiet`.
- In-game log: `Documents\Warcraft III\CustomMapData\DotaVsCommander\log.txt`. Documents may
  be redirected.
- Test chat cheats: `-lvl N`, `-gold N`, `-refresh`, `-wtf`, `-respawn`, `-spells`.

## Engine invariants – do not break without discussion

1. No `print()` or `Preload` while the map loads. All code starts from a 0 s timer after
   `main()`.
2. The archive must contain `war3mapMap.blp` and `war3map.mmp`, and it must be packed with
   StormLib (`tools/mpq_pack.py`).
3. Every Channel-based ability needs its own order string. Channels keep `Ncl5` = 0 so
   Stop or a move order interrupts them.
4. A hero has at most five learnable abilities. Hotkeys come from the command card cell
   (`CELL_KEYS` in `tools/gen_objects.py`).
5. Max HP and max mana bonuses go through `BlzSetUnitMaxHP` and `BlzSetUnitMaxMana` deltas
   (`src/core/stats.lua`), not through item bonus abilities.
6. Never create handles for one player only. Create them for everyone, and keep only the
   local state (sound volume, frame visibility) per player.
7. Hero numbers come from Dota's data (`src/data/heroes.json`, `items.json`, `world.json`).
   Don't hand-tune them in Lua.

## Agents

- Run independent pieces in parallel background agents. Each brief names the files the agent
  owns.
- Shared files are re-read right before each edit and changed in small, local edits:
  `tools/gen_objects.py`, `launcher/dvc_launcher/cli.py`, `launcher/build.ps1` and
  `launcher/tests/test_dist.py`.
- Each agent builds into its own `--work build\work_<name>`. Agents never launch WC3 and
  never commit.
- Agents return their `game.lua` hook lines, and the lead integrates them.
- Agents do not inherit this file. Pass them the relevant rules: language, no game content,
  no secrets, no game launches.

## Obsidian vault (`obsidian/`)

| Folder | Purpose |
|---|---|
| `00-home/` | `index.md` (navigation) and the current priorities note |
| `atlas/` | How the system is built: modules, data flow, build, launcher |
| `knowledge/decisions/` | Decisions with rationale |
| `knowledge/debugging/` | Bugs, root causes, fixes |
| `knowledge/patterns/` | Reusable techniques |
| `knowledge/integrations/` | External tools and services |
| `knowledge/business/` | Publishing, licensing, listing |
| `sessions/` | One note per session: `YYYY-MM-DD <slug>.md` |

**Note rules**
- Each file name is a statement ("Test builds use WC3 stand-in models"), not a category.
- Every note has frontmatter with `tags` and `date`.
- Link related notes liberally with `[[wiki links]]`.

**Session ritual** ("wrap up", /end)
1. Write a session note.
2. Update the priorities note with absolute dates.
3. Update `index.md`.
4. Sync the atlas, decision, debugging and pattern notes with what changed.
5. Commit the vault and `CLAUDE.md` first, then the code.
6. Push.

## Environment

- **OS and shells**: Windows 11, PowerShell 5.1 (no `&&`). Bash is available for POSIX scripts.
- **Python**: 3.12 in `.venv`. Run it with `-I` whenever it reads downloaded or extracted
  files.
- **Node**: tools in `tools/` (`npm install` there: mdx-m3-viewer, puppeteer and others).
- **Warcraft III**: Reforged 2.0.1, launched from the game root.
- **Dota 2**: usually `...\steamapps\common\dota 2 beta`.

## What stays untracked

`.venv/`, `build/`, `dist/`, `research/`, `launcher/vendor/`, `tools/vendor/`, `node_modules/`,
`.idea/`, `.obsidian/`, `*.log`.
