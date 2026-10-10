---
tags: [decision, stats, engine]
date: 2026-10-10
---

# Health and mana bonuses are applied as deltas with BlzSetUnitMaxHP

## Decision

`src/core/stats.lua` sums the `max_hp` and `max_mana` modifier props. It applies the
difference from the last applied value with `BlzSetUnitMaxHP` and `BlzSetUnitMaxMana`, and
keeps the current health and mana fraction.

A dead hero keeps its applied record (`pending`), and the stats timer reconciles it after the
revive. Removed non-hero units drop their record.

## Why

The hidden item-bonus abilities AIlf and AImb ignore field changes made after they are added:
- Ogre Magi's Dumb Luck showed 75 mana at level 30;
- item HP and mana bonuses did nothing.

The other bonuses still go through hidden abilities and work: armor, damage, attack speed
and attributes.

## Trade-off

Hero attribute changes add to max HP on top of the delta. This relies on WC3 applying
attribute HP and mana incrementally, which the user's test confirmed for Ogre.
