# Dota vs Commander – map framework reference

Warcraft III: Reforged 2.0.1 custom map, Lua 5.3. All `src/**/*.lua` files are concatenated into one
`war3map.lua` by `tools/build_lua.py`; modules register with `define(name, factory)` and resolve each
other lazily with `use(name)`. Natives are the ones in `research/jass/common.j` and `research/jass/blizzard.j`
(jassdoc copies). Check every native name and signature there before using it.

## Hard rules
- Never call `print`. Never call `Preload*` yourself. Both break map loading if they run while loading; use `use("log")`.
- Do not create handles or run game code at file top level. Code runs from functions only, after `Game.start`.
- Every callback you register with natives must go through `use("safe").call(fn, ...)` or the
  framework helpers (`Timer`, `Events`), which already wrap errors and log them.
- No globals except `define(...)` calls. Keep state in module locals.
- Hero key → Dota name: `npc_dota_hero_<key>`; keys: pudge, meepo, tinker, rubick, morphling, furion, chen,
  antimage, techies, ogre_magi, nevermore.

## Data
- `use("data.heroes")[hero]` – Dota 2 numbers from the player's patch: `stats`, `abilities[]` with `name`,
  `title`, `AbilityBehavior`, `AbilityCooldown`, `AbilityManaCost`, `AbilityCastRange`, `values{key = "a b c d"}`.
- `use("data.ids")` – generated raw codes: `abilities[name]`, `heroes[hero]`, `heroes[hero .. "_innates"]`,
  `units[key]`, `buffs[key]`, `orders[name]` (order string of Channel-based abilities, for bots/dummies),
  `ability_targets[name]` (a hero Channel's target type), `ability_cells[name]` (command card cell y * 4 + x, the
  same on every client), `order_probe` (test-only probe Channels).
- `use("data.sounds")[hero][event]` – voice-line paths extracted from Dota 2 (`cast_<ability>`, `kill`, ...).
- `use("data.audio")` – Dota's default music pack, announcer and effects (`tools/select_vo.py`):
  `music|announcer|sfx[key] = {path, duration, volume}`; loop tracks add `start`, `stop`, `sync{}`, `restart`.
- `use("data.mapdata")` – every gameplay position: `bounds`, `lanes{top,mid,bot}` (Dota spawn → commander
  spawn), `dota{fountain, ancient, shop, towers{top,mid,bot,base}, barracks}`, `commander{start, mines,
  expansions, spawns}`, `roshan`, `runes`, optional `bounty_runes`, `side_shops`, `camps{name = pos}` (a camp's
  type comes from its name: small, medium, large or ancient). Read positions from here only; never hard-code them.

### Data modules and the launcher (contract)
`tools/build_lua.py` writes each data module between two marker lines:
```
-- @dvc-data-begin data.<name>
define("data.<name>", function() ... end)
-- @dvc-data-end data.<name>
```
The base map's `data.mapdata` is the hand-made layout from `tools/layout.py`. The launcher
(`launcher/dvc_launcher/terrain`) replaces the `data.mapdata` block of a personalized map with Dota's own
layout, read from the player's Dota 2, together with the map's terrain (`war3map.w3e`, `.wpm`, `.doo`,
`war3mapMap.blp`) and start locations (`war3map.w3i`, `war3mapUnits.doo`). So:
- keep exactly one marked `data.mapdata` block and its schema (above); new keys must be optional in Lua;
- the map stays 160 × 160 tiles, centre at the origin, playable area ±9216: the launcher checks the base w3e
  and keeps the base layout if the size differs;
- code must work with any positions and counts (Dota has 28 camps and 2 bounty rune spots).

## Modules
### abilities – `use("abilities")`
- `A.define(name, {onCast, onChannel, onEndCast, onLearn, onToggle})` – `name` is the Dota ability name.
  - `onCast(ctx)` fires at the cast point; `onChannel(ctx)` at order start; `onEndCast(ctx)` when a channel ends
    or is interrupted; `onLearn(hero, level, def)` on learn/level up (use it for passives);
    `onToggle(unit, on, def)` for `kind: "toggle"` abilities (Immolation orders).
  - `ctx = {def, caster, owner, level, target, x, y}`; `ctx.v("damage")` reads the Dota value at `ctx.level`.
- `A.value(name, key, level)`, `A.id(name)` (raw code integer), `A.get(name)`, `A.data(name)`.
- Casting a Dota ability also plays a `cast_<ability>` voice line (60 %).

### mods – `use("mods")` (buffs/debuffs)
- `Mods.add(unit, key, spec)`; spec: `duration`, `source`, `props`, `effect` (model path), `attach`,
  `tick` + `onTick(m)`, `onRemove(m, expired)`, `debuff`, `dispel` ("basic" | "strong" | "none"), `stacks`, `persist`.
  Re-adding a key refreshes it.
- Numeric props, summed over a unit's modifiers: `armor`, `damage`, `attack_speed` (Dota points), `max_hp`,
  `max_mana`, `str`, `agi`, `int`, `move_flat`, `move_pct` (-0.3 = 30 % slow), `hp_regen`, `mana_regen`,
  `magic_resist` (0.1 = 10 %, multiplicative), `spell_amp`, `lifesteal`, `spell_lifesteal`, `damage_block` (max).
  `props.perStack = true` multiplies numbers by `m.stacks`.
- Status props (true): `stun`, `silence`, `root`, `disarm`, `hex`, `invisible`, `magic_immune`, `invulnerable`, `break`.
- `Mods.remove`, `Mods.get`, `Mods.has`, `Mods.remaining`, `Mods.sum`, `Mods.max`, `Mods.flag(unit, status)`,
  `Mods.dispel(unit, {debuffs, buffs, strong})`, `Mods.clear(unit)`.

### damage – `use("damage")`
- `Damage.deal(source, target, amount, kind, opts)` with kind `"magical" | "physical" | "pure"`;
  applies magic resistance / armor / spell amp; returns damage dealt. `opts.pierce` ignores spell immunity.
- `Damage.heal(unit, amount)`.
- `Damage.onDamaging(fn(source, target, info))` before reductions; `info.amount` is editable,
  `info.attack` is true for basic attacks, `info.spell` holds `Damage.deal`'s context.
- `Damage.onDamaged(fn(source, target, amount, info))` after.

### util – `use("util")`
`dist`, `angle`, `polar(x, y, d, a)`, `clamp`, `unitDist`, `alive`, `isHero`, `isStructure`, `isMagicImmune`,
`enum(x, y, r, filter)`, `enemiesOf(player, x, y, r, allowStructures)`, `alliesOf(player, x, y, r)`,
`nearest(list, x, y)`, `levelValue("a b c d", level)`.

### timer – `use("timer")`
`Timer.now()`, `Timer.after(s, fn)`, `Timer.every(s, fn)` (return true to stop; returns handle with `:stop()`),
`Timer.onFrame(fn(dt))` (1/32 s loop; return true to unregister) – use it for projectiles and motion.

### events – `use("events")`
`Events.on(name, fn)`. Names: `spell_channel`, `spell_effect`, `spell_endcast` (caster, abilId, target, x, y),
`death` (dying, killer), `hero_level`, `hero_skill` (hero, abilId), `item_pickup`/`item_drop`/`item_use`
(unit, item), `order` (unit, orderId, target, x, y), `attacked` (attacker, target), `trained`, `summon`
(summoner, summoned), `damaging`/`damaged` (source, target), `unit_enter`, `hero_spawned` (unit, heroKey, slot),
`hero_respawned`, `ability_cast` (caster, def, target, x, y), `research_finish`.

### sound – `use("sound")`
`Sound.vo(unit, event, chance, ownerOnly)`, `Sound.has(unit, event)`, `Sound.at(path, x, y, volume)`,
`Sound.heroOf(unit)`. Dota audio: `Sound.sfx(key, audience, x, y, gain, opts)` plays `data.audio.sfx[key]`
(3D when x, y are given), `Sound.play(path, audience, opts)`, `Sound.entry(group, key)`. `audience`: nil for
everyone, `"dota"` for the Dota side, a player, or `function(player)`. Every sound is created on every client and
muted by volume for the others; never call these inside a `GetLocalPlayer()` block.

### music, announcer, gamesounds – Dota's music, announcer and gameplay sounds
- `use("music")`: `init()` (after roles), `horn()`, `gameOver(winnerSide)`, `buyback(unit)`, `duck(seconds)`,
  `state(slot)`. Dota players only; the commander keeps Warcraft's music.
- `use("announcer")`: `init([secondsToHorn])` (default `creeps.first`), `say(key, priority, tag)`,
  `gameOver(winnerSide)`, `horn()`; keys are `data.audio.announcer` keys (`fort_rad`, `scan_rad`, `cour_kill_rad`, ...).
- `use("gamesounds")`: `init()`, `buy(p)`, `sell(p)`, `combine(p)`, `error(p)`, `castFail(hero, "cooldown"|"mana")`,
  `checkCast(hero, abilId)` (from synced key code), `tpStart(unit, x, y)`, `tpEnd(unit, done)`.

### bots – `use("bots")`
`Bots.hint(abilityName, spec)` – tell the generic hero bot how to use an ability (see `src/ai/bots.lua`).

### commander, commander_base – the commander's base
- `use("commander")`: `setup(raceKey)` (from `game.lua`), `halls()`, `player`, `raceKey`, `hall{x, y, half, unit}`,
  `starters`/`starterTarget` (starter structures made/wanted). Test builds with the AI commander log its slot,
  start location and setup once, then `summary()` every 30 s; `activity{orders, builds, trained}` counts what its
  units were told to do.
- `use("commander_base")`: the starter base, stock WC3 structures around the hall. Tune `STARTER[race]`
  (`{id, count, role}`, role `tower` | `production` | `supply`) and `FOR` (`"ai"` default, `"all"`, `"none"`).
  `plan(raceKey, site)` returns the spots, `build(p, raceKey, site)` creates them.

### log – `use("log")`
`Log.info`, `Log.warn`, `Log.error`. Shown on screen in test builds.

### controls_probe – `use("controls_probe")` (test builds)
`run()` at the start logs which trigger orders the engine takes from Channel abilities (by target type, by string
and by id) and whether the acquisition range calls hold, to `log.txt` and `controls_probe.txt`.

## Object specs – `specs/heroes/<hero>.json`
`tools/gen_objects.py` builds every WC3 object from these plus the Dota data. Per ability under `abilities`:
- `kind`: `"active"` (default unless the Dota ability is passive/toggle) → Channel ('ANcl') with targeting from the
  Dota behavior; `"passive"` → icon-only Evasion at 0 %; `"toggle"` → Immolation with on/off orders;
  `"native"` → a real WC3 ability: `base` (raw code) plus `fields` (`{fieldId: value or [per level]}`, ids from
  `research/slk/abilitymetadata.slk`).
- `target`: 0 none, 1 unit, 2 point, 3 unit or point (Channel only); `channel`: seconds of channelling;
  `range`, `radiusKey` (Dota value key for the AoE circle), `targets` (atar string), `order` (Channel order string;
  without one a Channel gets an order of a WC3 hero spell with the same kind of target, `ORDERS` in gen_objects.py),
  `anim`, `desc` (English, your own words; never copy Valve text), `title`, `include` (keep a hidden/not-learnable
  ability), `innateActive` (granted at spawn, not learned), `skip`.
- Hero-level `units`, `abilities_extra`, `buffs`: `{key: {"base": "xxxx", "fields": {...}}}` for summons,
  dummies and dummy-cast spells. Look them up with `use("data.ids").units[key]` etc.

## Build and check
- `.venv\Scripts\python.exe -I tools\build.py --test --work build\work_<you>` builds everything into your own
  folder and runs the script offline against a mock WC3 API (`tools/mock_runtime.lua`). It must print
  `MOCK RESULT: OK`. Never build without `--work` (that rewrites shared files).
- The mock only checks that code runs without Lua errors; it does not simulate combat. In-game tests are run by
  the lead.
