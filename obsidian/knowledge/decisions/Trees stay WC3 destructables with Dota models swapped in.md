---
tags: [decision, terrain, models, launcher]
date: 2026-10-11
---

# Trees stay WC3 destructables with Dota models swapped in

## Decision

The personalized map keeps WC3 tree destructables. `war3map.w3b` points three standard tree
types at 24 converted Dota models (`launcher/dvw_launcher/terrain/trees.py`):
- `LTlt`, 10 variations: Radiant trees in their default material (pines, oaks, bamboo);
- `FTtw`, 10 variations: oaks in their other materials (autumn, white, pink and red blossom);
- `BTtw`, 4 variations: Dire trees.

Models and skins come from the map's tree entities.
- Each tree keeps Dota's facing (`bfxr` = −1) and scale.
- Each model carries Dota's own stump.
- Animations: Stand, Stand Hit, Death (the tree falls, the stump stays) and Birth.

## Why

Tango, Quelling Blade, Blast Off, Sprout, Force of Nature, harvesting, pathing and vision all
rely on WC3 tree destructables. All three types were already in every hero's `TREE_TYPES`, so no
hero code changed.

## Ground textures

Ground tiles follow the per-vertex blend weights of Dota's four-layer ground materials: 13 tile
types, textured from their Dota layer with Dota's tints. They are written:
- for classic as BLP and DDS at `TerrainArt\<set>\<file>`;
- for HD as a diffuse DDS at `_hd.w3mod\TerrainArt\<set>\<file>_diffuse.dds`.

On the Dire side, the base and expansion tiles are forced to buildable types.

Status on 2026-10-11:
- in Reforged graphics the Dota trees and ground show;
- in classic graphics the textures are broken, and the details are pending from the user.

## Notes

- Dota tree models contain a `_stump_model` mesh (used) and an `_inspector` mesh (skipped).
- Reforged 2.0.1 stores classic tiles as 512×256 DXT5 DDS with mips. HD tiles are 2048×1024
  `_diffuse`/`_normal`/`_orm` DDS under `_hd.w3mod`.
- Cliff faces still use WC3's textures.

Related: [[Blocked ground rises into cliffs only over Dota-blocked cells]],
[[Dota models are converted to MDX 800 for both graphics modes]]
