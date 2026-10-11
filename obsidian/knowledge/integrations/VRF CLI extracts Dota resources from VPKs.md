---
tags: [integration, launcher, dota]
date: 2026-10-10
---

# VRF CLI extracts Dota resources from VPKs

Source2Viewer CLI (ValveResourceFormat, MIT) is how the launcher reads the player's
Dota 2 VPKs.

## What it does for the launcher

- lists VPK files;
- exports `vtex_c` textures to PNG (icons, HUD art, model textures);
- extracts the voice line sounds;
- exports models to glTF for the MDX converter. 73 models take about 19 s.
- for the map port, decompiles entity lumps, copies the gridnav (`maps/dota.gnv`) and exports
  the physics and ground meshes as glb. That takes about 17 s cold, once per Dota build.

## Packaging

- The CLI is downloaded into `launcher/vendor`, which git ignores.
- `launcher/build.ps1` copies it to `dist\DotaVsWarcraft\vrf`.
- Its license is in `launcher/licenses/ValveResourceFormat-LICENSE.txt`.
- Downloads and extracted files are untrusted data: Python that reads them runs with `-I`.

Related: [[Dota content reaches the map only through the launcher]]
