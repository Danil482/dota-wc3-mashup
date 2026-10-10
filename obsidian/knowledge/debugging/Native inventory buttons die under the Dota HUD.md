---
tags: [debugging, ui, items]
date: 2026-10-10
---

# Native inventory buttons die under the Dota HUD

## Symptom

Bought items could be sold in the shop but never appeared in the inventory. They couldn't be
used by click or by hotkey (numpad or Dota keys).

## What was tried

1. **Origin item buttons:** `ORIGIN_FRAME_ITEM_BUTTON` looked up before the first selection,
   with their parent moved out of the console bar. Nothing worked.
2. **Named item buttons:** `InventoryButton_0..5`, like `CommandButton_*` for the command card
   (which works). Still nothing.

## Resolution

The HUD draws its own item buttons from `UnitItemInSlot` and `BlzGetItemIconPath`, and uses
items through `dota_items`; see [[Items are used through HUD buttons, not the WC3 inventory]].
The root cause inside the engine is not known.
