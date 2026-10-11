---
tags: [debugging, abilities, orders, controls]
date: 2026-10-11
---

# Point quick casts failed on Channel orders the engine refuses

## Symptom

Quick cast at the ground never fired Pudge's Meat Hook. Every press logged
`qp order ... refused`. Casting through the command card worked, and so did unit quick cast
(Dismember).

## How it was narrowed

1. **Run-time field reads.** `Ncl6`/`Ncl2` read at run time plus `Issue*OrderById` refused
   everything. The next build cast from build data (`data.ids.orders`) and logged the details of
   each cast.
2. **The order itself.** The data was right (`acidbomb`, kind 2, enough mana, no cooldown), yet
   the point order was refused by string and by id.
3. **Probe.** A test-build probe ([[Test-build engine probes answer what the mock can't]])
   issued every hero Channel's real order:
   - point orders were taken for blizzard, flamestrike, clusterrockets, massteleport,
     forceofnature, raisedead, sentinel, ensnare, entanglingroots and starfall;
   - they were refused for `acidbomb` (Sticky Bomb) and `blink` (Poof);
   - instant and unit orders were taken for every order tried.
4. **Probe footmen.** The probe's own test footmen refused every point order, whatever the
   order. Some setup detail of those units differs, so that part of the table proves nothing
   about points.

## Fix

[[Channel orders come from pools that match the target type]]. Meat Hook got `blizzard`, and all
11 casts in the next test were issued.

## Still open

- Fixed on 2026-10-11, not yet confirmed in game: Poof has `massteleport` and Sticky Bomb has
  `blizzard`, both from the probe's accepted list.
- Why some orders are refused isn't known. The order's native target kind alone doesn't explain
  it: `raisedead` (instant) and `ensnare` (unit) were accepted as point orders.
