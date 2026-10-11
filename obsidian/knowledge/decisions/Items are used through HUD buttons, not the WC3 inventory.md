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
- Since 2026-10-11 the item buttons show a cooldown sweep and charges. Item cooldowns live in Lua
  on the item (`Items.startCooldown`, `cdLeft`), because WC3's remaining-cooldown read can return
  0 for Channel abilities.
- Since 2026-10-11 (evening):
  - the backpack, stash, TP slot and courier are wired in;
  - drag and drop works between slots, onto the ground and onto an allied hero;
  - see [[Items live in Lua slots – main, backpack, TP, stash and courier]].
  None of this has been seen in game yet.
- A click on a HUD frame reports (0,0); such clicks no longer fire a pending point item (fixed
  on 2026-10-11).
