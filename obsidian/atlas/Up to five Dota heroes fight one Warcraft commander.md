---
tags: [atlas, game-design]
date: 2026-10-10
---

# Up to five Dota heroes fight one Warcraft commander

The design was agreed with the user before the build started, on 2026-10-10.

## Sides

- **Dota**: up to five heroes; bots take the empty slots. Humans pick from a dialog first, and
  bots pick after them or after 45 s.
- **Commander**: one player with a full WC3 race of their choice: altar, heroes, buildings
  and their own army.
  - Uncontrollable creep waves leave the commander base every 30 s.
  - An AI commander plays when no human takes the slot. It starts with a starter base
    ([[The AI commander starts with a starter base of stock WC3 structures]]). In single player
    its slot is still empty ([[The AI commander idles because its computer slot is empty in single player]]).
- **Slots**: 9 in total. Dota force mask `0b001011111`, commander force `0b110100000`.
  Slot 9 holds the test dummies.

## Map

The Dota layout: three lanes, the river, neutral camps, runes, Roshan, towers T1–T4, barracks,
the Ancient and the fountain. The layout code is `tools/layout.py`, and the data is in
`src/data/mapdata.json`.

## Win conditions

The Dota side wins by destroying every commander town hall; the commander wins by destroying
the Ancient.

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

## Engine limit

A WC3 hero can learn at most five abilities. Extra abilities become innates whose level
follows a main ability. That is how Shadow Fiend's razes freed a slot for the ultimate (see
[[Dota sub-abilities share the main ability cell via BlzUnitHideAbility]]).

Related: [[Warcraft III is the host game, not Dota 2]],
[[The map script is split into define and use modules]]
