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
  `units[key]`, `buffs[key]`, `orders[name]` (order string of Channel-based abilities, for bots/dummies).
- `use("data.sounds")[hero][event]` – voice-line paths extracted from Dota 2 (`cast_<ability>`, `kill`, ...).

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
`Sound.vo(unit, event, chance)`, `Sound.at(path, x, y, volume)`, `Sound.heroOf(unit)`.

### bots – `use("bots")`
`Bots.hint(abilityName, spec)` – tell the generic hero bot how to use an ability (see `src/ai/bots.lua`).

### log – `use("log")`
`Log.info`, `Log.warn`, `Log.error`. Shown on screen in test builds.

## Object specs – `specs/heroes/<hero>.json`
`tools/gen_objects.py` builds every WC3 object from these plus the Dota data. Per ability under `abilities`:
- `kind`: `"active"` (default unless the Dota ability is passive/toggle) → Channel ('ANcl') with targeting from the
  Dota behavior; `"passive"` → icon-only Evasion at 0 %; `"toggle"` → Immolation with on/off orders;
  `"native"` → a real WC3 ability: `base` (raw code) plus `fields` (`{fieldId: value or [per level]}`, ids from
  `research/slk/abilitymetadata.slk`).
- `target`: 0 none, 1 unit, 2 point, 3 unit or point (Channel only); `channel`: seconds of channelling;
  `range`, `radiusKey` (Dota value key for the AoE circle), `targets` (atar string), `order` (Channel order string),
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
