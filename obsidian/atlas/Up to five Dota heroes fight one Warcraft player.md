---
tags: [atlas, game-design]
date: 2026-10-10
---

# Up to five Dota heroes fight one Warcraft player

The design was agreed with the user before the build started, on 2026-10-10.

## Sides

- **Dota**: up to five heroes; bots take the empty slots. Humans pick from a dialog first, and
  bots pick after them or after 45 s.
- **Warcraft**: one player with a full WC3 race of their choice: altar, heroes, buildings
  and their own army.
  - Uncontrollable creep waves leave the Warcraft base every 30 s.
  - The Warcraft AI plays when no human takes the slot. It starts with a starter base
    ([[The Warcraft AI starts with a starter base of stock WC3 structures]]). It takes a
    computer that is actually playing (slot 5, slot 7, or a playing computer in a user slot,
    such as slot 1 in single player), and its start location moves to the base
    ([[The Warcraft AI idles because its computer slot is empty in single player]]).
- **Slots**: 9 in the lobby. Dota force mask `0b001011111`, Warcraft force `0b110100000`.
  Outside the lobby, slot 9 holds the test dummies and slot 10 the Dota buildings
  ([[Dota buildings live in slot 10 outside the lobby so creeps can be pulled]]).

## Map

The Dota layout: three lanes, the river, neutral camps, runes, Roshan, towers T1–T4, barracks,
the Ancient and the fountain. The layout code is `tools/layout.py`, and the data is in
`src/data/mapdata.json`. Dota's lane rules run in Lua on top of WC3 combat: denies, aggro, Glyph,
Scan, buyback, kill gold, and day and night. See [[Lane rules run in lane.lua on top of WC3 combat]].

## Win conditions

The Dota side wins by destroying every town hall of the Warcraft player; the Warcraft side wins
by destroying the Ancient.

## Heroes in v1

The v1 roster has 11 heroes:
- Pudge
- Meepo
- Tinker
- Rubick
- Morphling
- Nature's Prophet (`furion`)
- Chen
- Anti-Mage
- Techies
- Ogre Magi
- Shadow Fiend (`nevermore`)

Each one has its current Dota kit with the innate, and the shop sells the core items.
Talents, Aghanim's, facets and neutral items were left out of v1. Since 2026-10-11 they are on
the roadmap: [[The Dota side aims at full parity with Dota 2]].

The same day, talents, Aghanim's Scepter and Aghanim's Shard came in for every hero's data and
UI. Unique effects are coded for 8 of the 11 heroes; see
[[Talents, Scepter and Shard reach abilities through one value lookup]]. Items gained the
backpack, stash, TP slot and a courier
([[Items live in Lua slots – main, backpack, TP, stash and courier]]). Facets and neutral items
are still on the roadmap.

## Engine limit

A WC3 hero can learn at most five abilities. Extra abilities become innates whose level
follows a main ability. That is how Shadow Fiend's razes freed a slot for the ultimate (see
[[Dota sub-abilities share the main ability cell via BlzUnitHideAbility]]).

Related: [[Warcraft III is the host game, not Dota 2]],
[[The map script is split into define and use modules]]

## Update (2026-10-11, night)

- The Warcraft base has a grove behind the hall
  ([[The Warcraft base has a grove of 51 Dire trees with triple lumber]]).
- Planned (the user's request): 11 Warcraft towers at the Dire tower spots with Dota's tower numbers and
  Dota's tier protection, and the neutral buildings of a WC3 melee map in the base (Tavern, fountains,
  Goblin Merchant and Laboratory, Mercenary Camp, Marketplace), closed to Dota players.
