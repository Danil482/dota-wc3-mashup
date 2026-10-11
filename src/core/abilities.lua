-- Ability registry. Each Dota ability has a WC3 object (see tools/gen_objects.py)
-- whose raw code is looked up by Dota name in the generated "ids" module;
-- Lua handlers receive a context with the caster, level, target and a value
-- reader over the hero's Dota 2 numbers (use("data.heroes")).
--
-- A.define(name, {onCast, onChannel, onEndCast, onLearn, onToggle}) where
--   onCast(ctx)            effect point reached (EVENT_PLAYER_UNIT_SPELL_EFFECT)
--   onChannel(ctx)         cast started (SPELL_CHANNEL), before the cast point
--   onEndCast(ctx)         channel finished or was interrupted (SPELL_ENDCAST)
--   onLearn(unit, level)   hero learned or levelled the ability
--   onToggle(unit, on)     toggle abilities (Immolation-based) switched
-- ctx.v("key") reads the caster's value for ctx.level, with every upgrade the
-- caster has (A.value with a unit, below).
define("abilities", function()
    local Events = use("events")
    local Log = use("log")
    local U = use("util")
    local A = {}

    local defs = {}          -- raw code -> def
    local byName = {}        -- dota name -> def
    local dataIndex = nil    -- dota name -> herodata ability entry

    local function index()
        if dataIndex then return dataIndex end
        dataIndex = {}
        for hero, info in pairs(use("data.heroes")) do
            for _, ab in ipairs(info.abilities) do
                ab.hero = hero
                dataIndex[ab.name] = ab
            end
        end
        return dataIndex
    end

    function A.data(name)
        return index()[name]
    end

    function A.id(name)
        local code = use("data.ids").abilities[name]
        return code and FourCC(code) or nil
    end

    -- Spell Steal's copy of an ability: same object, D hotkey and cell
    -- (tools/gen_objects.py rubick_copy). Raw id -> raw id.
    local copyOf = nil
    function A.copyId(id)
        if not copyOf then
            copyOf = {}
            for orig, copy in pairs(use("data.ids").rubick_copies or {}) do copyOf[FourCC(orig)] = FourCC(copy) end
        end
        return copyOf[id]
    end

    -- A unit's level in a Dota ability, through its own object or a stolen copy.
    function A.level(u, name)
        local id = A.id(name)
        if not id then return 0 end
        local lvl = GetUnitAbilityLevel(u, id)
        local copy = A.copyId(id)
        if lvl == 0 and copy then lvl = GetUnitAbilityLevel(u, copy) end
        return lvl
    end

    function A.define(name, def)
        local id = A.id(name)
        if not id then
            Log.warn("ability without object: " .. name)
            return def
        end
        def.name, def.id, def.data = name, id, A.data(name)
        defs[id] = def
        local copy = A.copyId(id)
        if copy then defs[copy] = def end
        byName[name] = def
        return def
    end

    function A.get(name) return byName[name] end

    -- The upgrade sources a unit has: {talent name | "scepter" | "shard" = true}
    -- (src/game/talents.lua sets this; nil means none).
    A.sourcesOf = function(u) return nil end

    local function token(raw, level)
        local n, last = 0, nil
        for t in string.gmatch(raw, "[^%s]+") do
            n = n + 1
            last = t
            if n == level then return t end
        end
        return last
    end

    -- Dota's upgrade operations (data.heroes ability "bonus"): "=v" sets,
    -- "+v"/"-v"/"v" add, "+v%" adds that share of the base, "xv" multiplies,
    -- in that order; one token per ability level.
    local function upgraded(base, ops, have, level)
        local set, add, pct, mul = nil, 0, 0, 1
        for source, raw in pairs(ops) do
            local t = have[source] and token(raw, level)
            if t then
                local op, rest = string.match(t, "^([x=]?)(.*)$")
                local percent = string.sub(rest, -1) == "%"
                if percent then rest = string.sub(rest, 1, -2) end
                local v = tonumber((string.gsub(rest, "^%+", ""))) or 0
                if op == "=" then set = v
                elseif op == "x" then mul = mul * v
                elseif percent then pct = pct + v
                else add = add + v end
            end
        end
        return ((set or base) + add + base * pct / 100) * mul
    end

    -- `base` with the upgrades of `key` that unit u has.
    function A.apply(name, key, base, level, u)
        local d = A.data(name)
        local ops = u and d and d.bonus and d.bonus[key]
        local have = ops and A.sourcesOf(u)
        if not have then return base end
        return upgraded(base, ops, have, math.max(1, level))
    end

    -- Dota value for a key at a level: AbilityValues first, then the
    -- ability's own fields (AbilityCooldown, AbilityCastRange, ...). With a
    -- unit, its talents, Aghanim's Scepter and Shard upgrades are applied.
    function A.value(name, key, level, u)
        local d = A.data(name)
        if not d then return 0 end
        local raw = d.values and d.values[key]
        if raw == nil then raw = d[key] end
        local v = raw ~= nil and U.levelValue(raw, math.max(1, level)) or 0
        if u then v = A.apply(name, key, v, level, u) end
        return v
    end

    -- Cast range bonuses: every source (items, talents, Ebb and Flow, ...)
    -- sets its own flat bonus on a unit's ability, and the ability's range
    -- field gets the object range plus their sum, on every level.
    local rangeBase = {}      -- unit -> {abilId -> {levelIndex -> object range}}
    local rangeBonus = {}     -- unit -> {abilId -> {source -> bonus}}

    function A.applyRange(u, id)
        local ab = BlzGetUnitAbility(u, id)
        if not ab then return end
        local total = 0
        for _, b in pairs((rangeBonus[u] or {})[id] or {}) do total = total + b end
        local per = rangeBase[u]
        if not per then per = {}; rangeBase[u] = per end
        local base = per[id]
        if not base then base = {}; per[id] = base end
        for li = 0, math.max(1, BlzGetAbilityIntegerField(ab, ABILITY_IF_LEVELS), GetUnitAbilityLevel(u, id)) - 1 do
            if base[li] == nil then base[li] = BlzGetAbilityRealLevelField(ab, ABILITY_RLF_CAST_RANGE, li) end
            if base[li] > 0 and math.abs(BlzGetAbilityRealLevelField(ab, ABILITY_RLF_CAST_RANGE, li) - (base[li] + total)) > 0.5 then
                BlzSetAbilityRealLevelField(ab, ABILITY_RLF_CAST_RANGE, li, base[li] + total)
            end
        end
    end

    function A.rangeBonus(u, id, source)
        local per = rangeBonus[u]
        return per and per[id] and per[id][source] or 0
    end

    function A.setRangeBonus(u, id, source, bonus)
        local per = rangeBonus[u]
        if not per then per = {}; rangeBonus[u] = per end
        local list = per[id]
        if not list then list = {}; per[id] = list end
        list[source] = bonus ~= 0 and bonus or nil
        A.applyRange(u, id)
    end

    -- castId: the object actually cast, the ability's own or Spell Steal's copy.
    local function context(def, caster, target, x, y, castId)
        castId = castId or def.id
        local level = GetUnitAbilityLevel(caster, castId)
        local ctx = {def = def, caster = caster, owner = GetOwningPlayer(caster), level = level,
                     target = target, x = x, y = y, castId = castId}
        function ctx.v(key) return A.value(def.name, key, level, caster) end
        return ctx
    end

    -- Abilities a unit owns that silence should disable: our Dota abilities
    -- plus any native WC3 hero spell (stolen by Spell Steal, copied by Morph,
    -- or a Warcraft hero's own), found by walking the unit's ability list.
    function A.ownedBy(u)
        local list, seen = {}, {}
        for id in pairs(defs) do
            if GetUnitAbilityLevel(u, id) > 0 then
                list[#list + 1] = id
                seen[id] = true
            end
        end
        local i = 0
        while true do
            local ab = BlzGetUnitAbilityByIndex(u, i)
            if not ab then break end
            local id = BlzGetAbilityId(ab)
            if not seen[id] and BlzGetAbilityBooleanField(ab, ABILITY_BF_HERO_ABILITY) then
                list[#list + 1] = id
                seen[id] = true
            end
            i = i + 1
        end
        return list
    end

    local ORDER_ON = {[852177] = true}     -- immolation
    local ORDER_OFF = {[852178] = true}    -- unimmolation

    function A.init()
        Events.on("spell_channel", function(caster, abil, target, x, y)
            local d = defs[abil]
            if d and d.onChannel then d.onChannel(context(d, caster, target, x, y, abil)) end
        end)
        Events.on("spell_effect", function(caster, abil, target, x, y)
            local d = defs[abil]
            if d and d.onCast then d.onCast(context(d, caster, target, x, y, abil)) end
            if d then use("sound").vo(caster, "cast_" .. d.name, 0.6) end
            Events.emit("ability_cast", caster, d, target, x, y)
        end)
        Events.on("spell_endcast", function(caster, abil, target, x, y)
            local d = defs[abil]
            if d and d.onEndCast then d.onEndCast(context(d, caster, target, x, y, abil)) end
        end)
        Events.on("hero_skill", function(hero, abil)
            local d = defs[abil]
            if d and d.onLearn then d.onLearn(hero, GetUnitAbilityLevel(hero, abil), d) end
        end)
        Events.on("order", function(u, order)
            if ORDER_ON[order] or ORDER_OFF[order] then
                for id, d in pairs(defs) do
                    if d.onToggle and d.toggleOrder == "immolation" and GetUnitAbilityLevel(u, id) > 0 then
                        d.onToggle(u, ORDER_ON[order] == true, d)
                    end
                end
            end
        end)
        use("mods").silenceable = A.ownedBy
    end

    return A
end)
