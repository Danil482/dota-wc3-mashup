---
tags: [atlas, lane, economy, structures, hud]
date: 2026-10-11
---

# Lane rules run in lane.lua on top of WC3 combat

WC3 fights the battles: attacks, targeting, damage and pathing. Dota's lane rules sit on top of
it in Lua and change only what Dota does differently. Built on 2026-10-11 by the lane agent;
nothing here has been seen in game yet.

## Where each rule lives

| Rule | Module | What it does |
|---|---|---|
| Day and night | `lane.lua`, `gen_objects.py` | `DayLength=600` in `war3mapMisc.txt`. It is night before the horn, dawn comes with the horn (`creeps.firstAt`, Dota's 0:00), and day and night then swap every 5 min. |
| Vision | `tools/extract_world.py` → `world.json` | Buildings and lane creeps take day and night vision from Dota's `npc_units.txt`. |
| Denies | `lane.lua`, `economy.lua`, `hero_bot.lua` | An attack order on an ally that can't be denied is stopped, with Dota's error line and beep. Allowed: a non-hero below 50%, a tower or barracks below 10%, a ward. A deny shows "!" to everyone and pays no gold. Enemy heroes within `E.DENY_RANGE` share half the XP. Bots deny. |
| Kill gold | `economy.lua` | A hero kill pays 125 + 8 × victim level. Structures pay 150. Only hero slots are paid (`Roles.isHeroSlot`). The gold popup shows to the killer only. |
| Buyback | `economy.lua`, `heroes.lua` | `E.buybackCost` (200 + net worth / 13), a 480 s cooldown, a 60% gold penalty until the skipped respawn would have ended, and +25 s on the next death. `H.revive` brings the hero back, and `music.buyback` plays. |
| Gold income | `economy.lua` | `E.earn` applies the buyback penalty. Bounty runes and Midas don't go through it yet. |
| Glyph | `structures.lua` | Buildings invulnerable for 7 s, lane creeps for 3 s. Towers past tier 1 hit 5 extra targets. It is refreshed when the first T1, the first T2 and the first melee barracks fall. Announcer line `fort_rad`. |
| Scan | `lane.lua` | Two team charges. Enemy heroes in a 900 radius for 8 s show as red minimap pings. Announcer line `scan_rad`. |
| Aggro | `lane.lua` | Attacking an enemy hero, or ordering an attack on one, draws enemy lane creeps within 500 for 2.3 s, with a 3 s cooldown per attacker. The creeps then return to their lane. Towers switch to an enemy who attacks a hero in their range. |
| Creep pulls | `roles.lua` | The buildings live in slot 10; see [[Dota buildings live in slot 10 outside the lobby so creeps can be pulled]]. |

## HUD

`src/ui/dota_glyph.lua` puts Glyph and Scan by the minimap's top right and a buyback button
with its cost while the hero is dead. It also shows Dota's red error line. The buttons sit
under `Hud.F.fgBottom` but outside its area.

Scan targets the next left click on the ground; a right click cancels. Whether a minimap click
works is untested. The state itself belongs to `structures.lua` (Glyph), `lane.lua` (Scan) and
`economy.lua` (buyback); the HUD only shows it.

## Text

Every player-facing line comes from `data.strings` through `Lane.text(token, ...)`; see
[[Player-facing strings are keyed by Dota localization tokens]].

## Numbers

Dota's own files hold some of the numbers:
- the Glyph durations, multishot targets and refresh rules (`dota_english.txt`);
- the Scan radius and duration;
- the buyback gold penalty;
- vision.

The rest come from third-party pages cited in the code, and they are unverified. The list is in
[[2026-10-11 Lane rules, inventory with courier, talents and the Warcraft AI slot]].

## Not done yet

- Streak gold, assist gold and Dota's hero-kill XP formula.
- Illusion bounties: an illusion kill still pays full hero gold.
- Bounties for the Warcraft player's buildings.
- The camp leash (`world_camps` `C.LEASH`, 800) is too short for pulls.
- Dota's Glyph and Scan hotkeys.

Related: [[Up to five Dota heroes fight one Warcraft player]],
[[The Dota side aims at full parity with Dota 2]]
