---
tags: [decision, items, hud]
date: 2026-10-10
---

# Items are used through HUD buttons, not the WC3 inventory

## Decision

`src/ui/dota_items.lua` uses items for Dota players:
- a click on the HUD's item button, or a key: Z X C V B N by default, or the player's Dota keys
  through `dota_settings` (`I.custom`);
- no-target items fire at once with `UnitUseItem`;
- point, unit and tree items wait for the next left world click (synced
  `EVENT_PLAYER_MOUSE_DOWN`), then call `UnitUseItemPoint` or `UnitUseItemTarget` on the
  nearest unit or tree within 150; a right click cancels.

`gen_objects` exports each item's target kind as `data.ids.item_targets`.

## Why

Under the Dota HUD, the native inventory buttons showed no icons and took no clicks or hotkeys,
even after they were looked up by name; see [[Native inventory buttons die under the Dota HUD]].

## Trade-offs

- Items are always used by the player's main hero.
- There is no drag and drop or drop-on-ground yet.
- Since 2026-10-11 the item buttons show a cooldown sweep and charges. Item cooldowns live in Lua
  on the item (`Items.startCooldown`, `cdLeft`), because WC3's remaining-cooldown read can return
  0 for Channel abilities.
- Backpack, stash, TP slot and courier storage exist in `src/game/inventory.lua` but are not
  wired yet.
- A pending point item may be cast at (0,0) when the targeting click lands on a frame, because
  frame clicks report 0,0 (finding, 2026-10-11).
