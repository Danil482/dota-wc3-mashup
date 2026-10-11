---
tags: [debugging, controls, quick-cast]
date: 2026-10-11
---

# Quick cast sent no order for native abilities without a Channel target kind

## Symptom

In game Anti-Mage's Blink did nothing on W: the log showed about 40 presses of
`cast antimage_blink …: order blink, kind 0, … no cast -> false` and `qp order …: refused`.

## Cause

`castAbility` in `src/ui/dota_settings.lua` takes the target kind from `ids.ability_targets`, which only
lists Channel-based abilities, and falls back to the Channel field `ABILITY_ILF_TARGET_TYPE`. Native
abilities (Blink on `AEbl`, and natives of Pudge, Ogre Magi, Morphling, Shadow Fiend, Tinker, Rubick and
Meepo) read 0 there, so no order was issued at all.

## Fix

When the build data has no kind, `castAbility` derives it from Dota's behaviour flags (`targets()`), as
the key handler already did. The `dota_settings` mock exercise sends the synced point cast for Blink.
Later hud2 made keys find the ability that actually holds a cell (granted forms, Rubick's copies) and
`gen_objects` records cells and kinds for `abilities_extra`.

Related: [[Channel orders come from pools that match the target type]]
