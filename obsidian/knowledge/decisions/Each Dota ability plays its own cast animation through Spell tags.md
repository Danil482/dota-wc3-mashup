---
tags: [decision, models, animation, launcher]
date: 2026-10-11
---

# Each Dota ability plays its own cast animation through Spell tags

## Decision

The converter used to give each hero one "Spell" sequence for every ability. Since 2026-10-11
(`launcher/dvw_launcher/mdx/units.py`, converter version 5):
- Dota activities map to WC3 sequence names: CAST_1–5 → "Spell One".."Spell Five", CAST_6 → "Spell
  First", CAST_7 → "Spell Second", OVERRIDE_4 → "Spell Third"; RAZE_n and OVERRIDE_1–3 fill in for a
  missing CAST_n. Heroes only; a sequence whose clip equals Spell's is skipped.
- `gen_objects.py` sets each ability's `aani` to `spell,<tag>` from Dota's `AbilityCastAnimation`
  (now in `heroes.json`); Channel activities get `spell,channel`; the TP scroll `stand,channel`.
- Instant natives (Counterspell, Flesh Heap, Frenzy, toggles) keep no animation: Dota's are upper-body
  gestures that WC3 can't layer.

## Why it works

WC3 picks the sequence with the most matching tags, then the fewest extra ones (jassdoc); stock Cluster
Rockets asks for `spell,one` on the Goblin Tinker. Stand-in test models fall back to "Spell".

## Open

Meepo's Dig and MegaMeepo clips look swapped in Dota's data; Blast Off, Dismember's start and TP arrival
need code-played animations.

Related: [[Dota models are converted to MDX 800 for both graphics modes]]
