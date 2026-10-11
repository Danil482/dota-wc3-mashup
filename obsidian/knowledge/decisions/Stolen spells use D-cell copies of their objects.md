---
tags: [decision, abilities, rubick]
date: 2026-10-10
---

# Stolen spells use D-cell copies of their objects

## Decision

Rubick's Spell Steal works in two ways:
- a Lua Dota spell borrows one of Rubick's D-cell Channel slots;
- every other spell is added to Rubick as a copy object with hotkey D and cell (1,1).

`gen_objects` writes these copies (`data.ids.rubick_copies`, 82 of them) for:
- every non-Channel Dota hero ability;
- every hero spell of the four Warcraft races (from `abilitydata.slk`).

`abilities.lua` maps each copy to its ability's handlers:
- `A.copyId`;
- `A.level`, which every hero module's `level()` uses;
- `ctx.castId`.

## Why

A button's hotkey can't change at run time, so a stolen spell kept its own key (e.g. Q) and
clashed with Rubick's.
