---
tags: [integration, video, hyperframes]
date: 2026-10-12
---

# HyperFrames renders the launch video through the pinned hf.sh wrapper

HyperFrames (heygen-com/hyperframes) renders video from HTML with a seekable GSAP timeline. It builds
the launch video. Version 0.8.149 was vetted on 2026-10-12 and lives in
`C:\Users\dania\tools\hyperframes-0.8.149\`. The global `~/.claude/CLAUDE.md` holds the rules.

## Rules

- Run only `bash C:/Users/dania/tools/hyperframes-0.8.149/hf.sh <command>`, never `npx hyperframes`.
  The wrapper pins the version and turns off update checks, self-install and telemetry.
- Never run `feedback`, `usage`, `open`, `catch-up`, `publish`, `cloud`, `lambda`, `cloudrun`, `auth`,
  `upgrade` or `skills update`, even when a hyperframes skill says to.
- Nothing loads from a CDN:
  - GSAP comes from the vetted copy in `tools\hyperframes-0.8.149\vendor\`;
  - the fonts are local OFL files (Cinzel, Barlow Condensed, JetBrains Mono).
- `init` writes `npx` calls into the `package.json` scripts and agent notes that say `skills update`.
  Rewrite both to point at the wrapper.

## Loop

- `hf.sh check <dir>` is the gate: lint, runtime, layout and contrast.
- `hf.sh snapshot <dir> --at <times> --output <temp dir>` captures stills.
- `hf.sh render <dir> --quality delivery --output brag.mp4` takes about a minute for 21 s at 1080p30.
- `hf.sh beats <dir>` writes a beat grid for the project's music `<audio>`.

## Lessons

- A `<video data-start>` inside a timed section is a lint error. Put each video in an untimed wrapper
  and animate the wrapper.
- The renderer lowers the whole mix when the true peak passes −1 dBTP; on 2026-10-12 it took off
  3 dB. Pre-limit loud SFX (ffmpeg `alimiter` at 4× oversampling) so the mix keeps headroom. v2 ended
  at −15.3 LUFS with a −2.4 dBFS peak.
- The slash transition:
  - a clip-path reveal tweened in sync with a skewed band leaves no seam;
  - the scene clip windows overlap, which hides the cut.
- The audio-reactive glow is CSS variables, tweened from per-frame RMS extracted in advance, so it
  survives seeking.

Related: [[The launch video uses Dota's own sound and stays out of git]]
