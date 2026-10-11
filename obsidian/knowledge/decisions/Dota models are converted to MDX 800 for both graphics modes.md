---
tags: [decision, models, launcher]
date: 2026-10-10
---

# Dota models are converted to MDX 800 for both graphics modes

## Decision

The launcher's converter (`launcher/dvw_launcher/mdx/`) writes classic MDX version 800:
1. VRF exports the player's Dota models to glTF.
2. The converter turns them into MDX with BLP1 textures (JPEG content).

## Why

- Classic graphics cannot load the HD formats (900/1000/1100).
- HD graphics draws 800 models with the classic shader.

So 800 is the only version that renders in both modes. Sources: Hive Workshop (Dr Super Good)
and mdx-m3-viewer's sanity test.

## What it costs

- No normal maps, PBR, glow or team colour.
- Skin weights are rounded to quarters: a vertex group lists a bone once per quarter. Whether
  the game honours repeated bones is unconfirmed; if it does not, skinning falls back to
  equal weights.

## Conversion details

- Geosets are split below about 7,430 vertices or 16,386 indices. Larger classic geosets
  render garbled.
- Walk cycles have Dota's root motion removed.
- The portrait camera lives inside the main model.
- Each model gets the attachment points Origin, Overhead, Head, Chest, Hand, Weapon and Foot.

## Scope (2026-10-10)

- 22 units:
  - 11 heroes with their default items;
  - 3 lane creeps;
  - towers (one model, four copies);
  - 2 barracks;
  - the Ancient;
  - the fountain.
- About 11.8 MB added to the personalized map.
- A cold conversion takes 44–54 s.

## Update (evening of 2026-10-10)

- All textures are palette BLP1 now, not JPEG (`TEXTURE_ENCODING`). This is part of the hang
  mitigation, and the map came out 0.5 MiB smaller.
- 71 units are converted:
  - neutrals;
  - Roshan;
  - summons;
  - wards;
  - 9 runes.
- Neutrals, Roshan, summons and wards also get static portrait models; see
  [[Neutral portraits are static palette models]].

## Update (2026-10-11)

The terrain package converts 24 Dota tree models with the same converter, each with its stump.
See [[Trees stay WC3 destructables with Dota models swapped in]].

Related: [[Dota content reaches the map only through the launcher]]
