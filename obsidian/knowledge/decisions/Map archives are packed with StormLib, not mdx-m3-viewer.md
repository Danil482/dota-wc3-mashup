---
tags: [decision, build, mpq]
date: 2026-10-10
---

# Map archives are packed with StormLib, not mdx-m3-viewer

## Decision

`tools/mpq_pack.py` packs the `.w3x` with StormLib v9.40 (x64 DLL, called through ctypes):
- MPQ v1;
- `(listfile)`;
- `(attributes)` with CRC32 and MD5;
- zlib compression.

The launcher repacks personalized maps with the same DLL.

## Why

- mdx-m3-viewer's MPQ writer first wrote a hash table that was too small. After that was
  fixed, the game still rejected its archives.
- StormLib is the reference MPQ implementation.

## Notes

- The DLL is downloaded into `tools/vendor` and `launcher/vendor`, which git ignores.
  Its SHA-256 was checked against the release's `release.sha256`.
- License: MIT (`launcher/licenses/StormLib-LICENSE.txt`).
- mdx-m3-viewer is still used to write the other map files (`w3i`, `doo`) and to parse maps
  for checks.

Related: [[The map is built from source with one build.py command]]
