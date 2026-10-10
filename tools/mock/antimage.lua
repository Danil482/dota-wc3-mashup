-- Offline exercise for the Anti-Mage module (hero batch A). tools/mock_run.py
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


__heroesA.at(21, function()
    local H = __heroesA
    local ids = use("data.ids")
    local A = use("abilities")
    local Mods = use("mods")
    local AM = use("hero_antimage")
    local X, Y = 44000, 40000

    local am = H.unit(10, ids.heroes.antimage, X, Y, {hero = true, level = 10, agi = 40, life = 1200, mana = 400, maxMana = 400})
    UnitAddAbility(am, A.id("antimage_persectur"))
    AM.register(am)
    H.learn(am, "antimage_mana_break", 4)
    H.learn(am, "antimage_blink", 4)
    H.learn(am, "antimage_counterspell", 4)
    H.learn(am, "antimage_mana_void", 3)
    H.check("am counterspell resist", Mods.sum(am, "magic_resist") > 0.34, Mods.sum(am, "magic_resist"))

    local foe = H.unit(11, "Hamg", X + 150, Y, {hero = true, life = 1500, mana = 200, maxMana = 500})
    local creep = H.unit(11, "hfoo", X + 350, Y, {life = 500})

    -- Mana Break + Persecutor
    local dealt = H.hit(am, foe, 40)
    H.check("am mana break burns", math.abs(foe.mana - 137.5) < 0.01, foe.mana)
    H.check("am mana break damage", math.abs(dealt - (40 + 62.5 * 0.65)) < 0.01, dealt)
    H.check("am persecutor slows", Mods.has(foe, "antimage_persecutor"), Mods.sum(foe, "move_pct"))
    H.check("am no break on manaless", H.hit(am, creep, 40) == 40)

    -- Blink: free cast, then cancelled while rooted
    H.cast(am, "antimage_blink", nil, X + 600, Y)
    local stops = __mock.calls.IssueImmediateOrder or 0
    Mods.add(am, "heroesA_root", {duration = 0.3, props = {root = true}})
    H.emit("spell_channel", am, A.id("antimage_blink"), nil, X + 600, Y)
    H.check("am blink stopped when rooted", (__mock.calls.IssueImmediateOrder or 0) == stops + 1)

    -- Counterspell: shell plus reflection of an enemy Storm Bolt
    local shell = FourCC(ids.abilities.antimage_spell_shield)
    H.cast(am, "antimage_counterspell")
    H.check("am counterspell shell", Mods.has(am, "antimage_counterspell") and GetUnitAbilityLevel(am, shell) == 1)
    local bolt = FourCC("AHtb")
    SetUnitAbilityLevel(foe, bolt, 2)
    foe.order = 852095
    H.emit("spell_effect", foe, bolt, am, 0, 0)
    local dummies = 0
    for _, u in ipairs(__mock.units) do
        if u.typeId == FourCC(ids.units.antimage_reflector) then dummies = dummies + 1 end
    end
    H.check("am counterspell reflects", H.targetOrders == 1 and dummies == 1, tostring(H.targetOrders) .. "/" .. dummies)

    H.after(1.6, function()
        H.check("am counterspell ends", not Mods.has(am, "antimage_counterspell") and GetUnitAbilityLevel(am, shell) == 0)
        -- Mana Void: 362.5 missing mana, the creep next to it is hit as well
        local before, creepBefore = foe.taken or 0, creep.taken or 0
        H.cast(am, "antimage_mana_void", foe)
        H.check("am mana void damage", (foe.taken or 0) - before > 200, (foe.taken or 0) - before)
        H.check("am mana void splash", (creep.taken or 0) > creepBefore, creep.taken)
        H.check("am mana void stun", Mods.flag(foe, "stun"))
        -- Break switches the passive magic resistance off
        Mods.add(am, "heroesA_break", {duration = 1.0, props = {["break"] = true}})
    end)

    H.after(2.4, function()
        H.check("am break removes resist", Mods.sum(am, "magic_resist") == 0, Mods.sum(am, "magic_resist"))
    end)

    H.after(3.4, function()
        H.check("am resist returns", Mods.sum(am, "magic_resist") > 0.34, Mods.sum(am, "magic_resist"))
        use("log").info("heroesA antimage exercise done")
    end)
end)
