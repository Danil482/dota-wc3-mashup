---
tags: [decision, architecture]
date: 2026-10-10
---

# Warcraft III is the host game, not Dota 2

## Decision

The mashup is a Warcraft III Reforged Lua map. Dota 2 is a required companion install, used
only as a content source: models, icons and voice lines.

## Why

- The commander side needs RTS base building, races, production and an AI opponent. WC3 has
  all of these built in.
- A WC3 map can carry imported models, textures and sounds in its archive. A Dota 2 custom
  game cannot load WC3 assets, and it needs the Workshop Tools pipeline.
- The user chose WC3 after the two hosts were compared.

## Alternative

A Dota 2 custom game with an RTS layer written from scratch.

## Trade-offs

- Every Dota mechanic is rebuilt in Lua on top of WC3: abilities over Channel, stats through
  bonus abilities, and a limit of five learnable abilities per hero.
- Dota assets need conversion; see [[Dota models are converted to MDX 800 for both graphics modes]].

Related: [[Up to five Dota heroes fight one Warcraft commander]]
