---
tags: [decision, vfx, launcher, models]
date: 2026-10-11
---

# Dota spell effects reach the map through data.effects, missiles through object data

## Decision

The launcher converts Dota particle systems into classic MDX 800 (`launcher/dvw_launcher/effects.py`,
`mdx/particles.py`, `mdx/fxtextures.py`, listed in `specs/effects.json`):
- each Dota system becomes at most one emitter: sprites → ParticleEmitter2 heads (ground-aligned →
  XY quad), trails → tails, ropes → ribbons; model renderers, lights and darkening layers are dropped;
- missile models get looping Stand plus Birth and Death; one-shots get a Death equal to Stand, so
  `DestroyEffect(AddSpecialEffect())` plays them.

How they reach the game:
- **Spell effects**: `data.effects` is empty in the base map; the launcher fills it between the
  `-- @dvw-data-begin/end data.effects` markers with only the effects it converted. Hero code calls
  `Fx.model(key, wc3Fallback)` (`src/core/fx.lua`), so an unpersonalized map keeps WC3 effects.
- **Attack missiles**: object data. In release and `--dota-models` builds `gen_objects.py` points
  `ua1m` at `war3mapImported\Dota\fx\<key>.mdx`; the launcher always writes every one of those files
  (a plain glow if a conversion fails). `--test` alone keeps WC3 missiles.

## Why object data for missiles

The controls probe (case D, 2026-10-11) set `UNIT_WEAPON_SF_ATTACK_PROJECTILE_ART` at run time: the
call returned true, but reading it back gave the old missile. The run-time route doesn't stick.

## Open (2026-10-11)

In game the user saw only Techies' missile, and it looked like WC3's; the others seemed invisible,
although the object data and all 39 files are in the map. Why the converted missiles don't render is
the first task of the next vfx agent ([[Current priorities for October 2026]]).

Related: [[Dota models are converted to MDX 800 for both graphics modes]],
[[Dota content reaches the map only through the launcher]]
