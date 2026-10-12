---
tags: [session, video, hyperframes, audio, publishing]
date: 2026-10-12
---

# Launch video rebuilt on HyperFrames with Dota's own sound

Continues [[2026-10-11 Night wave – effects, cast animations, sounds, grove and the Dota vs Warcraft rename]].
A short session: the context briefing, then the launch video rebuilt on the newly vetted HyperFrames
0.8.149 and scored with Dota's own music and sounds, as the user asked. No map, launcher or tool code
changed.

## What was done

- **Briefing** (`/begin`): the vault is healthy, with no broken links and every one of its 66 notes linked from the index.
- **HyperFrames rule:** the global `~/.claude/CLAUDE.md` already says to run HyperFrames only through the
  pinned `hf.sh`, so nothing was added.
- **Launch video v2** in `build\brag-output-2026-10-12-100410\` (not in git):
  - `brag.mp4`: 21 s, 1920×1080, 30 fps, −15.3 LUFS;
  - the poster `brag.jpg`, baked in as frame 0;
  - `share-copy.txt`, `brag-plan.md`, `composition-brief.md`;
  - the HyperFrames project in `composition/`.

  See [[The launch video uses Dota's own sound and stays out of git]] and
  [[HyperFrames renders the launch video through the pinned hf.sh wrapper]].
  - The story is the same as v1:
    - the hook "5 DOTA HEROES / 1 WARCRAFT ARMY";
    - the reveal over Dota's map and the live HUD;
    - "Bring your own Dota", with the launcher checklist and 11 hero cards;
    - "Dota's rules. Warcraft's engine.";
    - the punchline "Not a single Dota file shipped."
  - The score comes from the player's Dota install:
    - the Radiant horn;
    - `battle_03`, cut on its own bar grid;
    - the announcer at the title;
    - `battle_03_end` leading into the Radiant victory stinger.
  - Fixes over v1:
    - the voice-line count is 648 (`src/data/sounds.json`), not 496;
    - the Morphling clip held a camera jump, so only the tower shot is used, slowed to 0.7×.

## What was not done

- The user has not watched the video yet, and it was not uploaded anywhere.
- None of the 2026-10-11 entry points were started: the main build for `ids.json`, the freeze test,
  hangfix, warbase, vfx2, audio2 and talentui.

## Key decisions

- [[The launch video uses Dota's own sound and stays out of git]]: Dota music, at the user's request.
- HyperFrames runs only through `hf.sh`. GSAP and the fonts are local files inside the project.

## Open questions

- May the video go into the Melty listing or a public post? It carries Dota music, the announcer and
  Dota art, and CLAUDE.md rule 1 bars game content from uploads.
- Keep the announcer line at the title? Dropping it means removing one `<audio>` element.
- The video's Dota audio came from the old `%LOCALAPPDATA%\DotaVsCommander` cache. The composition
  keeps its own copies, so deleting the old folders (an open question since 2026-10-11) doesn't break
  re-renders.

## Next session – entry points

1. The user watches `brag.mp4`. Adjust sounds or scenes on request and re-render with `hf.sh render`.
2. The 2026-10-11 entry points still stand:
   - main build for `ids.json`;
   - rebuild dist;
   - the freeze test (click own lane creeps 10–20 times);
   - hangfix and warbase with fresh briefs.
