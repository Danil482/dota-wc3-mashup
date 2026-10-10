---
tags: [decision, models, portraits]
date: 2026-10-10
---

# Neutral portraits are static palette models

## Decision

These units get a separate portrait model, `war3mapImported\Dota\<key>_portrait.mdx`:
- the neutrals;
- Roshan;
- the summons;
- the wards.

`specs/models.json` names it under `"portrait"`, and `upor` points at it. The portrait model
is:
- the Dota mesh baked into Stand frame 0;
- one root bone;
- palette BLP textures of 256 px or less;
- Stand, Portrait, Portrait Talk and Death sequences;
- a Portrait camera on the head.

The world keeps the full animated model. All model textures are palette BLP1 now, not JPEG.
Neutrals and Roshan also get `usnd = ""`.

## Why

Clicking neutrals hung the game four times in personalized builds and never in the stand-in
build (see [[Selecting some Dota neutrals hung the game]]). The user wanted a universal fix
that keeps Dota portraits, not WC3 ones.

## Trade-offs

- Neutral portraits don't animate.
- The map grew by about 4.3 MiB.
