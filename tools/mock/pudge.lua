-- Offline exercise for the Pudge module (hero batch A). tools/mock_run.py
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


__heroesA.at(20, function()
    local H = __heroesA
    local ids = use("data.ids")
    local A = use("abilities")
    local Mods = use("mods")
    local P = use("hero_pudge")
    local X, Y = 40000, 40000

    local pudge = H.unit(10, ids.heroes.pudge, X, Y, {hero = true, level = 18, str = 40, life = 1500, mana = 500, maxMana = 500})
    UnitAddAbility(pudge, A.id("pudge_innate_graft_flesh"))
    P.register(pudge)
    H.learn(pudge, "pudge_meat_hook", 4)
    H.learn(pudge, "pudge_rot", 4)
    H.learn(pudge, "pudge_flesh_heap", 4)
    H.learn(pudge, "pudge_dismember", 3)

    local foe = H.unit(11, "Hamg", X + 600, Y, {hero = true, life = 1500})
    local creep = H.unit(11, "hfoo", X, Y + 700, {life = 420})

    -- Meat Hook at the hero: pure damage, dragged back next to Pudge
    H.cast(pudge, "pudge_meat_hook", nil, X + 1300, Y)
    H.check("pudge hook locks pudge", Mods.flag(pudge, "stun"))

    H.after(1.5, function()
        H.check("pudge hook damages hero", math.abs(foe.life - (1500 - 360)) < 0.01, foe.life)
        H.check("pudge hook drags hero", math.abs(foe.x - X) < 250, foe.x)
        H.check("pudge hook releases", not Mods.has(foe, "pudge_meat_hook"))
        -- second hook kills the creep outright
        H.cast(pudge, "pudge_meat_hook", nil, X, Y + 1300)
    end)

    H.after(3.0, function()
        H.check("pudge hook slays creep", creep.dead == true, creep.life)
        -- Rot on: the hero next to Pudge burns and is slowed, Pudge never dies
        pudge.life = 30
        H.emit("order", pudge, 852177)
        H.check("pudge rot on", P.rotOn(pudge))
    end)

    H.after(4.5, function()
        H.check("pudge rot burns", (foe.taken or 0) > 360, foe.taken)
        H.check("pudge rot slows", Mods.has(foe, "pudge_rot"))
        H.check("pudge rot non-lethal", pudge.life >= 1 and not pudge.dead, pudge.life)
        H.emit("order", pudge, 852178)
        H.check("pudge rot off", not P.rotOn(pudge))
        pudge.life = 1500
        -- Meat Shield blocks a flat amount of any damage
        H.cast(pudge, "pudge_flesh_heap")
        H.check("pudge meat shield blocks", H.hit(foe, pudge, 100, false) == 74, "100 -> " .. tostring(H.hit(foe, pudge, 100, false)))
        -- Dismember the hero
        foe.x, foe.y = X + 180, Y
        H.cast(pudge, "pudge_dismember", foe)
        H.check("pudge dismember holds", Mods.flag(foe, "stun"))
    end)

    local takenBefore
    H.after(4.6, function() takenBefore = foe.taken or 0 end)

    H.after(7.5, function()
        local dealt = (foe.taken or 0) - takenBefore
        -- (120 + 0.9 * 40) * 2.75 magical, 25 % hero resistance
        H.check("pudge dismember damage", math.abs(dealt - 156 * 2.75 * 0.75) < 1, dealt)
        H.check("pudge dismember pulls", math.abs(foe.x - X) <= 126, foe.x)
        H.endCast(pudge, "pudge_dismember", foe)
        H.check("pudge dismember ends", not Mods.has(foe, "pudge_dismember"))
        -- Flesh Heap: an enemy hero dies next to Pudge
        H.kill(foe, pudge)
        H.check("pudge flesh heap stack", P.stacks(pudge) == 1 and Mods.sum(pudge, "str") == 2, Mods.sum(pudge, "str"))
        -- a bot-owned Pudge (slot 10 has no human) switches Rot off when alone
        H.emit("order", pudge, 852177)
    end)

    H.after(9.0, function()
        H.check("pudge bot rot auto-off", not P.rotOn(pudge))
        use("log").info("heroesA pudge exercise done")
    end)
end)
