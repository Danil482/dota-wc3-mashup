-- Offline exercise for the Ogre Magi module (hero batch A). tools/mock_run.py
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


__heroesA.at(23, function()
    local H = __heroesA
    local ids = use("data.ids")
    local A = use("abilities")
    local Mods = use("mods")
    local OG = use("hero_ogre_magi")
    local X, Y = 52000, 40000

    local ogre = H.unit(10, ids.heroes.ogre_magi, X, Y, {hero = true, level = 18, str = 48, int = 5, life = 2000, mana = 0, maxMana = 400})
    UnitAddAbility(ogre, A.id("ogre_magi_dumb_luck"))
    OG.register(ogre)
    local dl = Mods.get(ogre, "ogre_magi_dumb_luck")
    H.check("ogre dumb luck", dl ~= nil and dl.props.max_mana == 48 * 6 + 45 and math.abs(dl.props.mana_regen - 0.96) < 1e-9
        and dl.props.int == -5, dl and (dl.props.max_mana .. " " .. dl.props.mana_regen .. " " .. dl.props.int))
    H.learn(ogre, "ogre_magi_fireblast", 4)
    H.learn(ogre, "ogre_magi_ignite", 4)
    H.learn(ogre, "ogre_magi_bloodlust", 4)
    H.learn(ogre, "ogre_magi_multicast", 3)

    local foe = H.unit(11, "Hamg", X + 400, Y, {hero = true, life = 6000})
    local foe2 = H.unit(11, "hfoo", X + 600, Y + 300, {life = 3000})
    local ally = H.unit(10, "hfoo", X - 200, Y, {life = 500})

    -- Fireblast with Multicast forced to x4: four blasts 0.6 s apart
    H.withRoll(1, function() H.cast(ogre, "ogre_magi_fireblast", foe) end)
    H.check("ogre fireblast stuns", Mods.flag(foe, "stun"))

    H.after(2.0, function()
        H.check("ogre fireblast multicast", math.abs((foe.taken or 0) - 4 * 250 * 0.75) < 0.01, foe.taken)
        -- Ignite with Multicast x2: target and a random enemy, then one more cast
        local before = foe.taken or 0
        H.withRoll(50, function() H.cast(ogre, "ogre_magi_ignite", foe) end)
        H.after(1.5, function()
            H.check("ogre ignite target", Mods.has(foe, "ogre_magi_ignite"))
            H.check("ogre ignite random unit", Mods.has(foe2, "ogre_magi_ignite"))
            H.check("ogre ignite extends", Mods.remaining(foe, "ogre_magi_ignite") > 9, Mods.remaining(foe, "ogre_magi_ignite"))
        end)
        H.after(3.5, function()
            H.check("ogre ignite burns", (foe.taken or 0) - before > 50, (foe.taken or 0) - before)
        end)
    end)

    H.after(6.0, function()
        -- Bloodlust on himself, Multicast forced to x3: self bonus plus two allies
        local ally2 = H.unit(10, "hfoo", X - 100, Y + 200, {life = 500})
        UnitAddAbility(ogre, FourCC("Bblo"))        -- native buff the real cast applies
        H.withRoll(20, function() H.cast(ogre, "ogre_magi_bloodlust", ogre) end)
        H.check("ogre bloodlust self", Mods.sum(ogre, "attack_speed") == 100, Mods.sum(ogre, "attack_speed"))
        H.check("ogre bloodlust multicast", Mods.has(ally, "ogre_magi_bloodlust") and Mods.has(ally2, "ogre_magi_bloodlust"))
        H.after(1.2, function()
            H.check("ogre bloodlust kept", Mods.has(ogre, "ogre_magi_bloodlust"))
            UnitRemoveAbility(ogre, FourCC("Bblo"))  -- as a WC3 dispel would
        end)
        H.after(2.4, function()
            H.check("ogre bloodlust dispel sync", not Mods.has(ogre, "ogre_magi_bloodlust"))
            use("log").info("heroesA ogre_magi exercise done")
        end)
    end)

    -- Talents, Aghanim's Scepter (Unrefined Fireblast) and Shard (Fire Shield)
    local T = use("talents")
    local foe3, foe4, foe5, guard, scepter, procFrom
    H.after(9.0, function()
        if not T.started then T.init() end
        use("heroes").keyOf[ogre] = "ogre_magi"
        ogre.tal, ogre.level = true, 30
        T.register(ogre)
        for _, n in ipairs({"special_bonus_unique_ogre_magi_4", "special_bonus_unique_ogre_magi_dumb_luck_mana",
                            "special_bonus_unique_ogre_magi", "special_bonus_unique_ogre_magi_2",
                            "special_bonus_unique_ogre_magi_3", "special_bonus_unique_ogre_magi_multicast_chance"}) do
            H.check("ogre talent " .. n, T.pick(ogre, n))
        end
        foe3 = H.unit(11, "Hamg", X + 300, Y - 300, {hero = true, life = 6000})
        H.withRoll(99, function() H.cast(ogre, "ogre_magi_fireblast", foe3) end)
        H.check("ogre talent +175 fireblast damage", math.abs((foe3.taken or 0) - 425 * 0.75) < 0.01, foe3.taken)
        -- +10 % Multicast: a roll of 26 is x4 now (15 + 10 + 48 / 16 Strength)
        local n = 0
        H.withRoll(26, function() n = OG.multicast(ogre) end)
        H.check("ogre talent multicast chance", n == 4, n)
        UnitAddAbility(ogre, FourCC("Bblo"))
        H.withRoll(99, function() H.cast(ogre, "ogre_magi_bloodlust", ogre) end)
        H.check("ogre talent bloodlust self +35", Mods.sum(ogre, "attack_speed") == 135, Mods.sum(ogre, "attack_speed"))
        H.withRoll(99, function() H.cast(ogre, "ogre_magi_bloodlust", ally) end)
        local lm = Mods.get(ally, "ogre_magi_bloodlust")
        H.check("ogre talent bloodlust ally +20", lm ~= nil and lm.props.attack_speed == 100, lm and lm.props.attack_speed)
        H.withRoll(99, function() H.cast(ogre, "ogre_magi_ignite", foe3) end)
    end)
    H.after(10.0, function()
        local im = Mods.get(foe3, "ogre_magi_ignite")
        H.check("ogre talent +10 ignite burn", im ~= nil and im.burn == 60, im and im.burn)
        local dl2 = Mods.get(ogre, "ogre_magi_dumb_luck")
        H.check("ogre talent dumb luck +2/+0.01 per strength", dl2 ~= nil and dl2.props.max_mana == 48 * 8 + 45
            and math.abs(dl2.props.mana_regen - 48 * 0.03) < 1e-9, dl2 and (dl2.props.max_mana .. " " .. dl2.props.mana_regen))
        -- the level 25 talent: an attack casts Fireblast (roll forced under 17 %)
        foe4 = H.unit(11, "Hamg", X + 200, Y + 300, {hero = true, life = 6000})
        H.withRoll(1, function() H.hit(ogre, foe4, 50) end)
        procFrom = foe4.taken or 0
    end)
    H.after(10.3, function()
        H.check("ogre talent fireblast on attack", math.abs((foe4.taken or 0) - procFrom - 425 * 0.75) < 0.01
            and Mods.flag(foe4, "stun"), (foe4.taken or 0) - procFrom)
        H.withRoll(99, function() H.hit(ogre, foe4, 50) end)
        procFrom = foe4.taken or 0
    end)
    H.after(10.6, function()
        H.check("ogre talent fireblast on attack misses above 17", (foe4.taken or 0) == procFrom, foe4.taken)
        local code = ids.items.item_ultimate_scepter
        scepter = CreateItem(FourCC(code), 0, 0)
        UnitAddItem(ogre, scepter)
        use("items").refresh(ogre)
        local un = A.id("ogre_magi_unrefined_fireblast")
        H.check("ogre scepter grants unrefined fireblast", un ~= nil and GetUnitAbilityLevel(ogre, un) == 1)
        local cd = BlzGetUnitAbilityCooldown(ogre, A.id("ogre_magi_fireblast"), 3)
        H.check("ogre scepter fireblast cooldown -1", math.abs(cd - 7) < 0.01, cd)
        ogre.mana = 300
        local before = foe4.taken or 0
        local str = GetHeroStr(ogre, true)        -- 48 and the Scepter's +10
        H.withRoll(99, function() H.cast(ogre, "ogre_magi_unrefined_fireblast", foe4) end)
        H.check("ogre unrefined fireblast 150 + 1.5 x strength",
            str == 58 and math.abs((foe4.taken or 0) - before - (150 + 1.5 * str) * 0.75) < 0.01,
            str .. " " .. ((foe4.taken or 0) - before))
        H.check("ogre unrefined fireblast costs 35% of current mana", BlzGetUnitAbilityManaCost(ogre, un, 0) == 105,
            BlzGetUnitAbilityManaCost(ogre, un, 0))
        H.check("ogre shard", T.consumeShard(ogre))
        local sm = A.id("ogre_magi_smash")
        H.check("ogre shard grants fire shield", sm ~= nil and GetUnitAbilityLevel(ogre, sm) == 1)
        guard = H.unit(10, "hfoo", X - 300, Y - 200, {life = 1000})
        foe5 = H.unit(11, "Hamg", X - 300, Y - 600, {hero = true, life = 6000})
        H.withRoll(99, function() H.cast(ogre, "ogre_magi_smash", guard) end)
        H.check("ogre fire shield on", Mods.has(guard, "ogre_magi_smash"))
        local got = H.hit(foe5, guard, 100)
        H.check("ogre fire shield absorbs 85% of a hero attack", math.abs(got - 15) < 0.01, got)
        H.check("ogre fire shield ignores creep attacks", H.hit(foe2, guard, 100) == 100)
        H.hit(foe5, guard, 100)
        H.hit(foe5, guard, 100)
        H.check("ogre fire shield ends after three attacks", not Mods.has(guard, "ogre_magi_smash"))
        H.withRoll(1, function() H.cast(ogre, "ogre_magi_smash", guard) end)
        H.check("ogre fire shield multicast", Mods.has(guard, "ogre_magi_smash") and Mods.has(ally, "ogre_magi_smash")
            and Mods.has(ogre, "ogre_magi_smash"))
    end)
    H.after(11.6, function()
        H.check("ogre fire shield fireballs", math.abs((foe5.taken or 0) - 3 * 160 * 0.75) < 0.01, foe5.taken)
        UnitRemoveItem(ogre, scepter)
        use("items").refresh(ogre)
        T.forget(ogre)
        use("heroes").keyOf[ogre] = nil
        use("log").info("heroesA ogre_magi talents done")
    end)
end)
