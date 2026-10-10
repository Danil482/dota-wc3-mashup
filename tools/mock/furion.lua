-- Offline exercise of the Nature's Prophet handlers (heroes B: meepo, chen, furion, techies).
-- The prelude below is shared by tools/mock/{chen,furion,meepo,techies}.lua;
-- whichever loads first installs it (see tools/mock/meepo.lua for details).
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
            return "commander"
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
        function ctx.v(key) return A.value(name, key, level) end
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

__mockB.list[#__mockB.list + 1] = {name = "furion", fn = function(B)
    local A, Events, Mods = use("abilities"), use("events"), use("mods")
    local F = use("hero_furion")
    local ids = use("data.ids")
    local X, Y = -8400, 6400
    local p, enemy = Player(3), Player(7)
    local fur = B.unit(p, ids.heroes.furion, X, Y, {hero = true, level = 10})
    local foe = B.unit(enemy, "hfoo", X + 300, Y)
    local foeHero = B.unit(enemy, "Hpal", X + 340, Y + 40, {hero = true})
    local far = B.unit(enemy, "hfoo", X + 2000, Y)
    for _, n in ipairs({"furion_sprout", "furion_teleportation", "furion_force_of_nature"}) do B.learn(fur, n, 4) end
    B.learn(fur, "furion_curse_of_the_forest", 1)
    B.learn(fur, "furion_wrath_of_nature", 3)
    B.learn(fur, "furion_spirit_of_the_forest", 1)
    Events.emit("hero_spawned", fur, "furion", 3)

    -- Sprout: a ring of trees, damage around it, gone after the duration
    local hp = foeHero.life
    B.cast("furion_sprout", fur, 4, foeHero)
    B.check(#B.trees == 8, "sprout grows 8 trees")
    B.check(foeHero.life < hp, "sprout damage")
    B.advance(4.2)
    B.check(#B.trees == 0, "sprout trees removed")

    -- Nature's Call: a grove of 6 trees gives max_treants (5 at level 4)
    for i = 1, 6 do B.tree(X - 400 + 40 * i, Y - 300) end
    B.cast("furion_force_of_nature", fur, 4, nil, X - 260, Y - 300)
    local list = {}
    for t, info in pairs(F.treants) do
        if info.owner == fur then list[#list + 1] = t end
    end
    B.check(#list == 5, "five treants, got " .. #list)
    for _, t in ipairs(list) do B.mark(t) end
    for _, d in ipairs(B.trees) do B.check(d.life == 0, "trees used up") end
    -- treants hit heroes harder
    B.eventDamage, B.eventAttack = 20, true
    Events.emit("damaging", list[1], foeHero)
    B.check(B.setDamage == 20 + A.value("furion_force_of_nature", "treant_bonus_hero_damage", 4), "treant hero bonus")
    B.eventDamage, B.eventAttack = 0, false

    -- Spirit of the Forest: trees and treants raise damage
    B.tree(X + 50, Y + 50)
    F.spiritAll()
    B.check(Mods.has(fur, "furion_spirit_of_the_forest"), "spirit bonus")

    -- Teleportation: interrupted (refund), then completed with a barrier
    local ctx = B.cast("furion_teleportation", fur, 4, nil, X + 1000, Y)
    B.advance(1)
    ctx.def.onEndCast(ctx)
    B.check(GetUnitX(fur) == X, "interrupted teleport stays")
    ctx = B.cast("furion_teleportation", fur, 4, nil, X + 1000, Y)
    B.advance(2.75)
    ctx.def.onEndCast(ctx)
    B.check(GetUnitX(fur) == X + 1000, "teleported")
    B.eventDamage, B.eventAttack = 100, false
    Events.emit("damaging", foe, fur)
    B.check(B.setDamage == 0, "barrier absorbs")
    B.eventDamage = 0
    SetUnitPosition(fur, X, Y)

    -- Curse of the Oldgrowth near the remaining tree and treants
    B.cast("furion_curse_of_the_forest", fur, 1)
    B.advance(1.1)
    B.check(Mods.has(foeHero, "furion_curse"), "curse on the hero")
    B.check(not Mods.has(foe, "furion_curse"), "curse is heroes only")

    -- Wrath of Nature bounces through visible enemies
    hp = far.life
    B.cast("furion_wrath_of_nature", fur, 3, foeHero)
    B.advance(1)
    B.check(far.life < hp, "wrath reached the far enemy")

    F.follow()
    B.advance(1)
end}
