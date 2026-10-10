-- Offline exercise for the Shadow Fiend module (hero batch A). tools/mock_run.py
-- loads tools/mock/*.lua after mock_runtime.lua and before war3map.lua, so the
-- test is scheduled on the mock timeline and runs once the game has started.
-- The harness below (shared by the batch-A mock files, installed once) only
-- changes native behaviour for test units (u.hA) far outside the map.
if not __heroesA then
    __heroesA = {}
    local H = __heroesA
    local TEAM = {[10] = 1, [11] = 2}

    local function mine(u) return type(u) == "table" and u.hA == true end
    local function wrap(name, fn)
        local prev = _G[name]
        _G[name] = function(...) return fn(prev, ...) end
    end

    wrap("IsUnitEnemy", function(prev, u, p)
        if mine(u) then return TEAM[u.owner.id] ~= TEAM[p.id] end
        return prev(u, p)
    end)
    wrap("IsUnitAlly", function(prev, u, p)
        if mine(u) then return TEAM[u.owner.id] == TEAM[p.id] end
        return prev(u, p)
    end)
    wrap("IsUnitVisible", function(prev, u, p)
        if mine(u) then return true end
        return prev(u, p)
    end)
    wrap("IsUnitType", function(prev, u, t)
        if mine(u) then
            if t == UNIT_TYPE_DEAD then return u.dead == true end
            if t == UNIT_TYPE_HERO then return u.hero == true end
            if t == UNIT_TYPE_STRUCTURE then return u.structure == true end
            if t == UNIT_TYPE_MAGIC_IMMUNE then return u.immune == true end
            return false
        end
        return prev(u, t)
    end)
    wrap("GetUnitState", function(prev, u, s)
        if mine(u) then
            if s == UNIT_STATE_MANA then return u.mana or 0 end
            if s == UNIT_STATE_MAX_MANA then return u.maxMana or 0 end
            if s == UNIT_STATE_LIFE then return u.life or 0 end
            if s == UNIT_STATE_MAX_LIFE then return u.maxLife or 0 end
            return 0
        end
        return prev(u, s)
    end)
    wrap("SetUnitState", function(prev, u, s, v)
        if mine(u) then
            if s == UNIT_STATE_MANA then u.mana = math.max(0, math.min(v, u.maxMana or v)) end
            if s == UNIT_STATE_LIFE then u.life = v end
            return
        end
        return prev(u, s, v)
    end)
    wrap("BlzGetUnitMaxMana", function(prev, u)
        if mine(u) then return u.maxMana or 0 end
        return prev(u)
    end)
    -- attributes include modifier bonuses, as the stats module would apply them
    local function stat(u, field, prop, bonuses)
        return (u[field] or 0) + (bonuses and use("mods").sum(u, prop) or 0)
    end
    wrap("GetHeroStr", function(prev, u, b)
        if mine(u) then return stat(u, "str", "str", b) end
        return prev(u, b)
    end)
    wrap("GetHeroAgi", function(prev, u, b)
        if mine(u) then return stat(u, "agi", "agi", b) end
        return prev(u, b)
    end)
    wrap("GetHeroInt", function(prev, u, b)
        if mine(u) then return stat(u, "int", "int", b) end
        return prev(u, b)
    end)
    wrap("GetUnitFacing", function(prev, u)
        if mine(u) then return u.face or 0 end
        return prev(u)
    end)
    wrap("BlzSetUnitFacingEx", function(prev, u, a)
        if mine(u) then
            u.face = a
            return
        end
        return prev(u, a)
    end)
    wrap("GetUnitCurrentOrder", function(prev, u)
        if mine(u) then return u.order or 0 end
        return prev(u)
    end)
    -- Like the engine: damage to a test unit runs the damaging hooks (which may
    -- change the amount), then the damaged hooks, then the death event.
    wrap("UnitDamageTarget", function(prev, src, tgt, amount, ...)
        if not mine(tgt) then return prev(src, tgt, amount, ...) end
        if tgt.dead then return false end
        local a, d, s = BlzGetEventIsAttack, GetEventDamage, BlzSetEventDamage
        local final = amount
        BlzGetEventIsAttack = function() return false end
        GetEventDamage = function() return final end
        BlzSetEventDamage = function(v) final = v end
        local ok, err = pcall(H.emit, "damaging", src, tgt)
        local died = false
        if ok then
            tgt.life = (tgt.life or 0) - final
            tgt.taken = (tgt.taken or 0) + final
            died = tgt.life <= 0
            if died then tgt.dead = true end
            ok, err = pcall(H.emit, "damaged", src, tgt)
        end
        BlzGetEventIsAttack, GetEventDamage, BlzSetEventDamage = a, d, s
        if not ok then error(err, 0) end
        if died then H.emit("death", tgt, src) end
        return true
    end)
    wrap("IssueTargetOrderById", function(prev, u, order, target)
        if mine(target) then
            H.targetOrders = (H.targetOrders or 0) + 1
            return true
        end
        return prev(u, order, target)
    end)

    -- A test unit; opts fill the fields the wrappers above read.
    function H.unit(owner, code, x, y, opts)
        local u = CreateUnit(Player(owner), type(code) == "string" and FourCC(code) or code, x, y, 0)
        u.hA, u.face = true, 0
        for k, v in pairs(opts or {}) do u[k] = v end
        u.maxLife = u.maxLife or u.life or 1000
        u.life = u.life or u.maxLife
        return u
    end

    -- Runs fn at absolute mock time `at`; errors go to the log as ERROR.
    function H.at(at, fn)
        local t = CreateTimer()
        TimerStart(t, math.max(0, at - __mock.now), false, function()
            use("safe").call(fn)
        end)
    end

    function H.after(seconds, fn) H.at(__mock.now + seconds, fn) end

    function H.check(name, ok, detail)
        use("log").check("heroesA " .. name, ok and true or false, detail)
    end

    function H.emit(...) use("events").emit(...) end

    function H.learn(u, name, lvl)
        local id = use("abilities").id(name)
        SetUnitAbilityLevel(u, id, lvl)
        H.emit("hero_skill", u, id)
    end

    function H.cast(u, name, target, x, y)
        local id = use("abilities").id(name)
        H.emit("spell_channel", u, id, target, x or 0, y or 0)
        H.emit("spell_effect", u, id, target, x or 0, y or 0)
        return id
    end

    function H.endCast(u, name, target)
        H.emit("spell_endcast", u, use("abilities").id(name), target, 0, 0)
    end

    function H.kill(u, killer)
        u.dead, u.life = true, 0
        H.emit("death", u, killer)
    end

    -- Fires the damaging event as a basic attack (or spell) and returns the
    -- amount the hooks settled on.
    function H.hit(src, tgt, amount, isAttack)
        local a, d, s = BlzGetEventIsAttack, GetEventDamage, BlzSetEventDamage
        local result = amount
        BlzGetEventIsAttack = function() return isAttack ~= false end
        GetEventDamage = function() return amount end
        BlzSetEventDamage = function(v) result = v end
        local ok, err = pcall(H.emit, "damaging", src, tgt)
        BlzGetEventIsAttack, GetEventDamage, BlzSetEventDamage = a, d, s
        if not ok then error(err, 0) end
        return result
    end

    -- Forces Multicast and other rolls for the duration of fn.
    function H.withRoll(value, fn)
        local r = GetRandomReal
        GetRandomReal = function() return value end
        local ok, err = pcall(fn)
        GetRandomReal = r
        if not ok then error(err, 0) end
    end
end


__heroesA.at(22, function()
    local H = __heroesA
    local ids = use("data.ids")
    local A = use("abilities")
    local Mods = use("mods")
    local SF = use("hero_nevermore")
    local X, Y = 48000, 40000

    local sf = H.unit(10, ids.heroes.nevermore, X, Y, {hero = true, level = 12, agi = 40, life = 1200, mana = 800, maxMana = 800})
    UnitAddAbility(sf, A.id("nevermore_necromastery"))
    SF.register(sf)
    H.learn(sf, "nevermore_shadowraze1", 4)
    H.learn(sf, "nevermore_shadowraze2", 4)
    H.learn(sf, "nevermore_shadowraze3", 4)
    H.learn(sf, "nevermore_frenzy", 4)
    H.learn(sf, "nevermore_dark_lord", 4)
    H.learn(sf, "nevermore_requiem", 3)

    -- Necromastery: one soul per creep, four per hero
    local c1 = H.unit(11, "hfoo", X + 2500, Y, {life = 400})
    local h1 = H.unit(11, "Hamg", X + 2500, Y + 200, {hero = true, life = 800})
    H.kill(c1, sf)
    H.kill(h1, sf)
    H.check("sf necromastery souls", SF.souls(sf) == 5, SF.souls(sf))
    -- hero level 12: 1 + 0.8 * 2 = 2.6 damage per soul
    H.check("sf necromastery damage", math.abs(Mods.sum(sf, "damage") - 13) < 0.01, Mods.sum(sf, "damage"))

    -- Shadowraze (medium, 450 in front): 280 + 2 per soul, then +80 per stack
    local foe = H.unit(11, "Hblm", X + 450, Y, {hero = true, life = 4000, mana = 300, maxMana = 300})
    H.cast(sf, "nevermore_shadowraze2")
    local first = foe.taken or 0
    H.cast(sf, "nevermore_shadowraze2")
    local second = (foe.taken or 0) - first
    H.check("sf raze damage", math.abs(first - 290 * 0.75) < 0.01, first)
    H.check("sf raze stack bonus", math.abs(second - 370 * 0.75) < 0.01, second)
    H.check("sf raze stacks", (Mods.get(foe, "nevermore_shadowraze") or {}).stacks == 2)
    H.cast(sf, "nevermore_shadowraze1")
    H.cast(sf, "nevermore_shadowraze3")

    local cr
    H.after(0.6, function()
        H.check("sf presence armor", Mods.sum(foe, "armor") == -7, Mods.sum(foe, "armor"))
        -- Feast of Souls: heroes first, two enemies per interval
        cr = H.unit(11, "hfoo", X + 300, Y + 100, {life = 50})
        H.cast(sf, "nevermore_frenzy")
        H.check("sf feast buff", Mods.sum(sf, "attack_speed") == 80, Mods.sum(sf, "attack_speed"))
        H.check("sf feast collects", SF.souls(sf) == 5 + 3 + 1, SF.souls(sf))
        H.kill(cr, nil)
    end)

    local before
    H.after(1.0, function()
        before = foe.taken or 0
        H.cast(sf, "nevermore_requiem")
        H.endCast(sf, "nevermore_requiem")
    end)
    -- the first line reaches the hero ~0.4 s after release; one line = 0.6 s fear
    H.after(1.7, function()
        H.check("sf requiem damage", (foe.taken or 0) - before > 100, (foe.taken or 0) - before)
        H.check("sf requiem fear", Mods.has(foe, "nevermore_requiem") and Mods.flag(foe, "silence"))
    end)

    H.after(9.8, function()
        -- feast over: the living hero's souls are gone, the dead creep's lingers
        H.check("sf feast linger", SF.souls(sf) == 6, SF.souls(sf))
        local victim = H.unit(11, "hfoo", X + 150, Y, {life = 2000})
        -- death: half the souls fly out as Requiem (no fear), 70 % of stacks stay
        H.kill(sf, foe)
        H.check("sf death keeps souls", SF.souls(sf) == 3, SF.souls(sf))
        H.after(1.0, function()
            H.check("sf death requiem", (victim.taken or 0) > 0 and not Mods.has(victim, "nevermore_requiem"), victim.taken)
            sf.dead, sf.life = false, 1200
            H.emit("hero_respawned", sf, "nevermore", 10)
            H.check("sf respawn damage", math.abs(Mods.sum(sf, "damage") - 3 * 2.6) < 0.01, Mods.sum(sf, "damage"))
            use("log").info("heroesA nevermore exercise done")
        end)
    end)
end)
