---
tags: [decision, abilities, ui]
date: 2026-10-10
---

# Ability hotkeys come from the command card cell

## Decision

`gen_objects.py` takes each hero ability's hotkey from its command card cell (`CELL_KEYS`):

| Cell | Key |
|---|---|
| (0,2) | Q |
| (1,2) | W |
| (2,2) | E |
| (3,2) | R |
| (1,1) | D |
| (2,1) | F |
| (0,1) | G |
| (3,1) | T |

- A spec's `"hotkey"` overrides the table.
- The learn menu uses the same letter.
- M, S, H, A, P and O stay with the WC3 commands.

## Why

The old scheme gave keys by learnable-slot order, and each innate reused the next learnable
key. Shadow Fiend ended up with two razes and Feast of Souls on W. Tinker's Keen Conveyance
and Eureka shared a cell.

## Intentional shared cells

These abilities share a cell but never show at the same time:
- Techies' Detonate over Reactive Tazer;
- Morphling's morph swap over Replicate;
- Rubick's stolen spell slots;
- Chen's Martyrdom, which lives on the Zealot.

See [[Dota sub-abilities share the main ability cell via BlzUnitHideAbility]].
