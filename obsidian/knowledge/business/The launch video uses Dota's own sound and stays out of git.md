---
tags: [business, video, audio, publishing]
date: 2026-10-12
---

# The launch video uses Dota's own sound and stays out of git

## Decision

On 2026-10-12 the user asked for the launch video to be rebuilt on HyperFrames with Dota's own music.
Version 2 (`build\brag-output-2026-10-12-100410\`) takes its sound from the player's Dota 2 install,
via our launcher's cache, plus a few CC0 Kenney impacts:
- Dota's Radiant horn under the hook;
- the `valve_dota_001` battle music 3, its end stinger and the Radiant victory stinger;
- the announcer's "battle begins" line at the title;
- Dota UI sounds: the skill-level tick for the checklist and the item combine for the rules chips.

The video also shows Dota and WC3 art, as v1 did. So it lives only in `build\`, which git ignores,
and never in the repo. See [[Dota content reaches the map only through the launcher]].

## How the score is cut

The cuts follow the music's own grid, so the edit can be redone after `build\` is cleaned.
- `battle_03` runs at 140 BPM (one bar is 1.714 s).
  - Its first hit, 0.685 s into the file, lands at 1.287 s on "1 WARCRAFT ARMY".
  - Bar 8, the end of its 8-bar phrase, then lands at 15.000 s.
  - Scene cuts sit on the downbeats at 3.001, 6.429, 11.572 and 15.000 s.
- `battle_03_end` hits 0.655 s into its file. It is placed so the hit falls at 15.000 s, under the
  punchline.
- `radiant_win`'s strongest accent, 2.187 s into the file, lands at 18.287 s, under the lockup.
- Roughly measured keys:
  - `battle_03` is in A minor;
  - its end stinger sits on E, the dominant;
  - the victory fanfare is in A.

  So the outro resolves V → I.
- The bed ducks to 0.45 under the announcer.
- ffmpeg pre-mixes the music into `composition/assets/music/dvw-score.wav`. The SFX are separate
  `<audio>` clips.

## Open

- The user decides whether the video may go into the Melty listing or a public post. It carries Dota
  music, voice and art, and CLAUDE.md rule 1 keeps game content out of uploads.

Related: [[HyperFrames renders the launch video through the pinned hf.sh wrapper]],
[[The mashup is published on Melty under MIT with remixes allowed]]
