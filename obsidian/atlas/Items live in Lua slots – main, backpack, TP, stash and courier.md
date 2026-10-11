---
tags: [atlas, items, inventory, courier, hud]
date: 2026-10-11
---

# Items live in Lua slots – main, backpack, TP, stash and courier

A hero's six WC3 inventory slots are Dota's main inventory. Everything else is Lua storage in
`src/game/inventory.lua`:
- the backpack (3 slots);
- the stash (6 slots at the home shop);
- the TP scroll slot;
- the courier's 9 slots.

Stored items are real WC3 items hidden in a map corner, so they keep their charges and their
Lua state (`items.lua` istate: cooldown, owner, Power Treads' attribute). Built on 2026-10-11 by
the inventory agent; not yet seen in game.

## Slot numbers

Slot numbers follow Dota: 0–5 main, 6–8 backpack, 9–14 stash, 15 TP. The courier uses 20–28.

## Buying

- `Items.purchase` pays only for the missing parts. Parts the player already owns count, in the
  main slots, backpack, stash or courier.
- Each bought part goes through `Inv.receive`:
  - at the home shop, to the main slots, then the backpack, then the stash;
  - elsewhere, to the stash;
  - with the stash full, it drops in the fountain.
- Players can buy anywhere, even while dead.
- Secret Shop items need the hero or the courier at a Secret Shop. Current Dota has no side
  shops, so shop 5 stands at both `mapdata.side_shops` spots.
- Upgrades form within one place (the hero, the stash or the courier). The hero and the stash
  combine together only at home.
- Items remember their buyer. An ally can carry one but gets no stats from it, can't use it
  unless Dota marks it shareable, and can't sell it. Selling within 10 s refunds the full cost.

## Backpack and TP slot

- Backpack items are inactive. Moving one into the main slots puts it on a 6 s cooldown unless
  the hero is near a shop.
- Off the main slots, cooldowns run at half speed (`Items.park`).
- The TP slot casts through a hidden TP ability on the hero, so all scrolls share one cooldown.
- Every hero starts with a free, unsellable scroll on a 100 s cooldown.
- A double tap teleports to the fountain.

## Drag and drop

`src/ui/dota_items.lua` handles drag and drop between the main slots, the backpack, the TP slot
and the stash (at home only). Same-item stacks merge. Releasing over the world drops the item
there, and releasing over an allied hero gives it. This rests on engine behaviour that isn't
confirmed yet: hover events while the button is held, and clicks firing on release.

## Courier

`src/game/courier.lua` gives one courier per human Dota player; bots have none and shop at the
fountain.
- It walks until the hero reaches level 4, then a flying unit replaces it.
- Its command card follows Dota (`gen_objects.py` `COURIER_CARD`): Q Retrieve, W Secret Shop,
  E Return, D Speed Burst, F Transfer, R Shield.
- Its numbers come from `data.courier`, which `tools/extract_courier.py` writes from the
  player's `npc_units.txt` and `npc_abilities.txt`.
- Courier keys come from the player's Dota settings: F2 select, F3 deliver, Speed Burst, Shield,
  Grab All.

## HUD

`dota_hud.lua`'s item block is 0.170 wide. It has:
- a backpack row under the items;
- the TP slot;
- a stash row with Grab All above the block, shown when it holds items or the hero is at home;
- courier buttons: select, showing its respawn seconds, and Deliver.

Related: [[Items are used through HUD buttons, not the WC3 inventory]],
[[Dota players get a frame-based HUD with their own item buttons]],
[[Dota settings reach the game through a local file, never the map]]

## Update (2026-10-11, night)

- Cooldowns are enforced in Lua: `Items.ready(hero, it, via)` refuses a recharging item on every path
  (HUD clicks and keys, target clicks, quick cast, the TP slot, cast start in `item_actives.lua` for bots
  and the rest) with Dota's "Recharging..." line and the cooldown beep. `Items.used` also starts WC3's
  own cooldown.
- Drag and drop: mouse events over the HUD report the ground under it (jassdoc), not 0,0, so a press
  counts as on the HUD by the synced hovers; a release still over the source waits 0.2 s for a late
  hover. A click mode swaps backpack, stash and courier slots without a held button. Confirmed working
  in game.
