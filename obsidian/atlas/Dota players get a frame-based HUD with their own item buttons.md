---
tags: [atlas, hud, ui]
date: 2026-10-10
---

# Dota players get a frame-based HUD with their own item buttons

`src/ui/` replaces the Warcraft console for Dota players. The commander keeps the WC3 UI.

## Modules

- `hud_kit` – frame factories, cached setters, Dota art with WC3 fallbacks.
  - `Kit.button` is a transparent GLUEBUTTON template plus a BACKDROP icon.
  - `Kit.label` puts text on a button and adds a click layer. Register events on
    `Kit.hit(button)`; see [[Text labels on custom buttons swallow the mouse even when disabled]].
  - `Kit.probe` and `-uiprobe` are for debugging ([[UI probe logs show which frames get the mouse]]).
- `dota_hud` – the HUD itself:
  - hides the console bars and reparents the command card;
  - portrait, stats, HP and mana, ability row with "+" learn buttons;
  - item buttons, gold and the SHOP button;
  - selected-units bar with Dota Tab cycling;
  - top bar with heroes, the clock and the commander.
- `dota_shop` – two tabs, 12 categories, recipes on hover, a sell row, F4. Purchases run
  through `Items.purchase` inside synced frame events.
- `dota_items` – item use from the HUD buttons and keys; see
  [[Items are used through HUD buttons, not the WC3 inventory]].
- `dota_settings` – the player's Dota keys, quick cast, auto-attack, camera and right-click
  hold; see [[Dota settings reach the game through a local file, never the map]].

## Rules

- Every frame is created for every player. Only visibility, texture and text change in local
  code.
- Frame, key and mouse events are synced. Mouse events are registered only after the game
  starts.
- Dota art comes from the launcher (`specs/hud_assets.json` → `war3mapImported\Hud\*.blp`).
  Test builds fall back to WC3 textures.
- The world-click blocker under the panel (`BLOCK_BOTTOM_CLICKS`) is off: it swallowed the
  clicks meant for our buttons.

Related: [[The map script is split into define and use modules]]
