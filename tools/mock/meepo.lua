-- Offline exercise of the Meepo handlers (heroes B: meepo, chen, furion, techies).
-- The prelude below is shared by tools/mock/{chen,furion,meepo,techies}.lua;
-- whichever loads first installs it. Exercises run once, after the normal mock
-- run, with a few natives stubbed for units they create (u.hb = true) and
-- restored afterwards, so other heroes' mock code is unaffected.
if not __mockB then
    local B = {list = {}, done = false, trees = {}}
    __mockB = B

    -- Same loop as __mock.advance in mock_runtime.lua; kept local so other
    -- wrappers of __mock.advance are not re-entered when time passes here.
    function B.advance(seconds)
        local target = __mock.now + seconds
        while true do
            local nextT, nextDue = nil, math.huge
            for t in pairs(__mock.timers) do
                if t.active and t.due <= target and t.due < nextDue then nextT, nextDue = t, t.due end
            end
            if not nextT then break end
            __mock.now = nextDue
            if nextT.periodic then nextT.due = nextT.due + math.max(nextT.timeout, 0.001) else nextT.active = false end
            if nextT.fn then nextT.fn() end
        end
        __mock.now = target
    end

    local saved = {}
    local function stub(name, fn)
        if saved[name] == nil then saved[name] = _G[name] end
        _G[name] = fn
    end
    local function orig(name) return saved[name] end
    local function ours(u) return type(u) == "table" and u.hb == true end

    B.eventDamage, B.eventAttack, B.water = 0, false, false

    function B.install()
        stub("IsUnitType", function(u, t)
            if not ours(u) then return orig("IsUnitType")(u, t) end
            if t == UNIT_TYPE_DEAD then return u.dead == true end
            if t == UNIT_TYPE_HERO then return u.hero == true end
            if t == UNIT_TYPE_STRUCTURE then return u.structure == true end
            return false
        end)
        -- sides as roles.lua allies them: Dota slots 0-4 and 6, neutrals, the rest
        local function side(p)
            local id = GetPlayerId(p)
            if id <= 4 or id == 6 then return "dota" end
            if id == PLAYER_NEUTRAL_AGGRESSIVE then return "neutral" end
            return "warcraft"
        end
        stub("IsUnitEnemy", function(u, p)
            if not ours(u) then return orig("IsUnitEnemy")(u, p) end
            return side(u.owner) ~= side(p)
        end)
        stub("IsUnitAlly", function(u, p)
            if not ours(u) then return orig("IsUnitAlly")(u, p) end
            return side(u.owner) == side(p)
        end)
        stub("IsUnitVisible", function(u, p)
            if not ours(u) then return orig("IsUnitVisible")(u, p) end
            return true
        end)
        stub("UnitDamageTarget", function(src, tgt, amount, ...)
            if not ours(tgt) then return orig("UnitDamageTarget")(src, tgt, amount, ...) end
            tgt.life = math.max(1, tgt.life - amount)
            return true
        end)
        stub("GetUnitState", function(u, s)
            if not ours(u) then return orig("GetUnitState")(u, s) end
            if s == UNIT_STATE_MANA then return u.mana end
            if s == UNIT_STATE_MAX_MANA then return u.maxMana end
            if s == UNIT_STATE_LIFE then return u.life end
            return 0.0
        end)
        stub("SetUnitState", function(u, s, v)
            if not ours(u) then return orig("SetUnitState")(u, s, v) end
            if s == UNIT_STATE_MANA then u.mana = v end
        end)
        stub("BlzGetUnitMaxMana", function(u)
            if not ours(u) then return orig("BlzGetUnitMaxMana")(u) end
            return u.maxMana
        end)
        stub("BlzSetUnitMaxHP", function(u, hp)
            if ours(u) then u.maxLife = hp end
        end)
        stub("GetHeroXP", function(u) return ours(u) and (u.xp or 0) or 0 end)
        stub("SetHeroXP", function(u, xp) if ours(u) then u.xp = xp end end)
        stub("AddHeroXP", function(u, xp) if ours(u) then u.xp = (u.xp or 0) + xp end end)
        stub("GetHeroSkillPoints", function(u) return ours(u) and (u.points or 0) or 0 end)
        stub("UnitModifySkillPoints", function(u, d)
            if ours(u) then u.points = (u.points or 0) + d end
            return true
        end)
        stub("SelectHeroSkill", function(u, id)
            if ours(u) and (u.points or 0) > 0 then
                u.points = u.points - 1
                u.abilities[id] = (u.abilities[id] or 0) + 1
            end
        end)
        stub("SetUnitOwner", function(u, p) if ours(u) then u.owner = p end end)
        stub("GetUnitLevel", function(u) return ours(u) and (u.unitLevel or 1) or 0 end)
        stub("ReviveHero", function(u, x, y)
            if ours(u) then u.dead, u.x, u.y, u.life = false, x, y, u.maxLife end
            return true
        end)
        stub("GetEventDamage", function() return B.eventDamage end)
        stub("BlzGetEventIsAttack", function() return B.eventAttack end)
        stub("BlzSetEventDamage", function(v) B.setDamage = v end)
        stub("IsTerrainPathable", function() return not B.water end)
        -- destructables: a list of fake trees
        stub("Rect", function(a, b, c, d) return {minx = a, miny = b, maxx = c, maxy = d} end)
        stub("SetRect", function(r, a, b, c, d) r.minx, r.miny, r.maxx, r.maxy = a, b, c, d end)
        stub("EnumDestructablesInRect", function(r, filter, fn)
            local list = {}
            for _, d in ipairs(B.trees) do list[#list + 1] = d end
            for _, d in ipairs(list) do
                if d.x >= r.minx and d.x <= r.maxx and d.y >= r.miny and d.y <= r.maxy then
                    B.enumD = d
                    fn()
                end
            end
        end)
        stub("GetEnumDestructable", function() return B.enumD end)
        stub("CreateDestructable", function(id, x, y)
            local d = {typeId = id, x = x, y = y, life = 50}
            B.trees[#B.trees + 1] = d
            return d
        end)
        stub("RemoveDestructable", function(d)
            for i, t in ipairs(B.trees) do
                if t == d then table.remove(B.trees, i) break end
            end
        end)
        stub("KillDestructable", function(d) d.life = 0 end)
        stub("GetDestructableTypeId", function(d) return d.typeId end)
        stub("GetDestructableLife", function(d) return d.life end)
        stub("GetDestructableX", function(d) return d.x end)
        stub("GetDestructableY", function(d) return d.y end)
    end

    function B.restore()
        for name, fn in pairs(saved) do _G[name] = fn end
        saved = {}
    end

    -- Flags a unit (ours or made by a hero module) for the stubs above.
    function B.mark(u, o)
        o = o or {}
        u.hb = true
        u.hero = o.hero or false
        u.life, u.maxLife = o.hp or 500, o.hp or 500
        u.mana, u.maxMana = o.mana or 400, o.mana or 400
        u.xp, u.points, u.unitLevel, u.level = o.xp or 0, 0, o.unitLevel or 1, o.level or 1
        return u
    end

    function B.unit(owner, code, x, y, o)
        local id = type(code) == "string" and FourCC(code) or code
        return B.mark(CreateUnit(owner, id, x, y, 0), o)
    end

    function B.learn(u, name, level)
        local id = use("abilities").id(name)
        assert(id, "no ability object for " .. name)
        u.abilities[id] = level
    end

    function B.tree(x, y)
        local d = {typeId = FourCC("LTlt"), x = x, y = y, life = 50}
        B.trees[#B.trees + 1] = d
        return d
    end

    -- Context like abilities.lua builds it for a cast.
    function B.ctx(name, caster, level, target, x, y)
        local A = use("abilities")
        local def = A.get(name)
        assert(def, "no handlers for " .. name)
        local ctx = {def = def, caster = caster, owner = GetOwningPlayer(caster), level = level, target = target,
                     x = x or (target and GetUnitX(target)) or GetUnitX(caster),
                     y = y or (target and GetUnitY(target)) or GetUnitY(caster)}
        function ctx.v(key) return A.value(name, key, level, caster) end   -- with the caster's upgrades, as in game
        return ctx
    end

    function B.cast(name, caster, level, target, x, y)
        local ctx = B.ctx(name, caster, level, target, x, y)
        if ctx.def.onChannel then ctx.def.onChannel(ctx) end
        if ctx.def.onCast then ctx.def.onCast(ctx) end
        return ctx
    end

    -- A basic attack from source on target through the real damage hooks.
    function B.attack(source, target, amount)
        local Events = use("events")
        B.eventDamage, B.eventAttack = amount, true
        Events.emit("attacked", source, target)
        Events.emit("damaging", source, target)
        Events.emit("damaged", source, target)
        B.eventDamage, B.eventAttack = 0, false
    end

    function B.check(ok, msg)
        if not ok then error("check failed: " .. msg, 2) end
    end

    local prev = __mock.advance
    function __mock.advance(seconds)
        prev(seconds)
        if B.done then return end
        B.done = true
        for _, ex in ipairs(B.list) do
            B.trees = {}
            B.install()
            local ok, err = xpcall(ex.fn, debug and debug.traceback or tostring, B)
            B.restore()
            if not ok then error("heroes-B mock exercise '" .. ex.name .. "': " .. tostring(err), 0) end
            use("log").info("mock exercise " .. ex.name .. " ok")
        end
        use("log").flush()
    end
end

__mockB.list[#__mockB.list + 1] = {name = "meepo", fn = function(B)
    local A, Events = use("abilities"), use("events")
    local M = use("hero_meepo")
    local ids = use("data.ids")
    local X, Y = -8400, 8400
    local p, enemy = Player(1), Player(7)
    local meepo = B.unit(p, ids.heroes.meepo, X, Y, {hero = true, level = 12, xp = 5000})
    local foe = B.unit(enemy, "hfoo", X + 100, Y)
    local foeHero = B.unit(enemy, "Hpal", X + 150, Y + 60, {hero = true})
    B.tree(X + 80, Y + 80)
    for _, n in ipairs({"meepo_earthbind", "meepo_poof", "meepo_ransack"}) do B.learn(meepo, n, 4) end
    B.learn(meepo, "meepo_geomancy", 1)
    Events.emit("hero_spawned", meepo, "meepo", 1)

    -- Divided We Stand: two clones that copy level and skills
    B.learn(meepo, "meepo_divided_we_stand", 2)
    A.get("meepo_divided_we_stand").onLearn(meepo, 2, A.get("meepo_divided_we_stand"))
    local g = M.groupOf(meepo)
    B.check(#g.clones == 2, "two clones")
    for _, c in ipairs(g.clones) do B.mark(c, {hero = true}) end
    -- learning on the main Meepo mirrors onto the clones
    B.learn(meepo, "meepo_earthbind", 4)
    Events.emit("hero_skill", meepo, A.id("meepo_earthbind"))
    Events.emit("hero_level", g.clones[1])
    -- clone experience goes to the main Meepo
    g.clones[1].xp = (g.clones[1].xp or 0) + 200
    local before = meepo.xp
    M.syncAll()
    B.check(meepo.xp >= before + 200, "clone xp moved to main")
    B.check(g.clones[2].xp == meepo.xp, "clones follow main xp")

    -- Earthbind net
    B.cast("meepo_earthbind", meepo, 4, nil, X + 150, Y + 60)
    B.advance(1.5)
    B.check(use("mods").has(foeHero, "meepo_earthbind"), "earthbind roots")

    -- Poof: completed to a clone, then interrupted (refund)
    local ctx = B.cast("meepo_poof", meepo, 4, g.clones[1])
    B.advance(1.25)
    ctx.def.onEndCast(ctx)
    ctx = B.cast("meepo_poof", g.clones[2], 4, nil, X + 500, Y)
    B.advance(0.3)
    ctx.def.onEndCast(ctx)
    ctx = B.cast("meepo_poof", meepo, 4, meepo)
    B.advance(1.25)
    ctx.def.onEndCast(ctx)

    -- Ransack and the Geomancy water slow through the damage hooks
    B.water = true
    M.geomancyAll()
    meepo.life = 300
    B.attack(meepo, foeHero, 30)
    B.attack(g.clones[1], foe, 30)
    B.check(meepo.life > 300, "ransack heals")
    B.check(use("mods").has(foe, "meepo_geomancy_slow"), "water attack slows")
    B.water = false
    M.geomancyAll()
    B.advance(1)

    -- one dies, all die; they come back with the main Meepo
    Events.emit("death", g.clones[2], foeHero)
    B.check(meepo.dead and g.clones[1].dead, "all Meepos die together")
    meepo.dead = false
    Events.emit("hero_respawned", meepo, "meepo", 1)
    B.check(not g.clones[1].dead and not g.clones[2].dead, "clones respawn")
    B.advance(2)

    -- Talents, Dig (Aghanim's Shard) and MegaMeepo (Aghanim's Scepter)
    local T, H, Mods = use("talents"), use("heroes"), use("mods")
    if not T.started then T.init() end
    local was = H.bySlot[1]
    H.keyOf[meepo], H.bySlot[1] = "meepo", meepo
    T.register(meepo)
    for _, c in ipairs(g.clones) do T.addMember(meepo, c) end
    meepo.level = 25
    meepo.x, meepo.y = X, Y
    for _, c in ipairs(g.clones) do c.x, c.y = X + 50, Y end
    foeHero.life, foeHero.dead = 500, false
    B.check(T.pick(meepo, "special_bonus_unique_meepo_4"), "meepo true strike talent")
    B.check(T.pick(meepo, "special_bonus_unique_meepo_poof_cast_point"), "meepo poof cast talent")
    B.check(T.pick(meepo, "special_bonus_unique_meepo_2"), "meepo poof damage talent")
    B.check(A.value("meepo_poof", "poof_damage", 4, g.clones[1]) == 180, "clone poof damage with the talent")
    B.cast("meepo_earthbind", g.clones[1], 4, nil, X + 150, Y + 60)
    B.advance(1.5)
    local net = Mods.get(foeHero, "meepo_earthbind")
    B.check(net ~= nil and net.props.no_evade == true, "earthbind true strike")
    -- Poof completes after the shorter cast (0.75 - 0.3 s)
    local hp = foeHero.life
    ctx = B.cast("meepo_poof", g.clones[1], 4, meepo)
    B.advance(0.5)
    ctx.def.onEndCast(ctx)
    B.check(foeHero.life < hp, "poof lands after the talent's shorter cast")

    T.consumeShard(meepo)
    local dig = A.id("meepo_petrify")
    B.check(GetUnitAbilityLevel(meepo, dig) == 1 and GetUnitAbilityLevel(g.clones[1], dig) == 1, "dig for every meepo")
    g.clones[2].life = 100
    B.cast("meepo_petrify", g.clones[2], 1)
    B.check(Mods.flag(g.clones[2], "invulnerable") and Mods.flag(g.clones[2], "stun"), "dig hides the meepo")
    B.advance(3.2)
    B.check(not Mods.flag(g.clones[2], "invulnerable"), "dig ends")

    local code = ids.items.item_ultimate_scepter
    if code and UnitAddItem then
        UnitAddItem(meepo, CreateItem(FourCC(code), 0, 0))
        use("items").refresh(meepo)
        local megaId, fling = A.id("meepo_megameepo"), A.id("meepo_megameepo_fling")
        B.check(GetUnitAbilityLevel(meepo, megaId) == 1 and GetUnitAbilityLevel(g.clones[1], megaId) == 0,
            "megameepo for the main meepo only")
        for _, c in ipairs(g.clones) do c.x, c.y = X + 50, Y end
        meepo.x, meepo.y = X, Y
        B.cast("meepo_megameepo", meepo, 1)
        B.advance(0.2)
        local s = M.mega(meepo)
        B.check(s ~= nil and #s.stack == 2 and GetUnitAbilityLevel(meepo, fling) == 1, "megameepo lifts both clones")
        B.check(Mods.sum(meepo, "str") > 0, "megameepo shares stats")
        hp = foeHero.life
        B.cast("meepo_megameepo_fling", meepo, 1, foeHero)
        B.advance(1.0)
        B.check(foeHero.life < hp and Mods.has(foeHero, "meepo_fling_slow"), "fling hits and slows")
        B.cast("meepo_megameepo_fling", meepo, 1, foeHero)
        B.advance(1.0)
        B.check(M.mega(meepo) == nil and GetUnitAbilityLevel(meepo, fling) == 0, "megameepo ends with the last fling")
    end
    T.forget(meepo)
    H.keyOf[meepo], H.bySlot[1] = nil, was
end}
