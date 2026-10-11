-- Offline exercise of the Chen handlers (heroes B: meepo, chen, furion, techies).
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

__mockB.list[#__mockB.list + 1] = {name = "chen", fn = function(B)
    local A, Events, Mods = use("abilities"), use("events"), use("mods")
    local C = use("hero_chen")
    local ids = use("data.ids")
    local X, Y = -8400, 7400
    local p, enemy = Player(2), Player(7)
    local chen = B.unit(p, ids.heroes.chen, X, Y, {hero = true, level = 30})
    local ally = B.unit(p, "hfoo", X + 50, Y)
    local foe = B.unit(enemy, "hfoo", X + 100, Y)
    local foeHero = B.unit(enemy, "Hpal", X + 150, Y + 60, {hero = true})
    local lane = B.unit(Player(SLOT_HORDE), ids.units.human_melee, X + 120, Y - 40, {unitLevel = 2})
    local neutral = B.unit(Player(PLAYER_NEUTRAL_AGGRESSIVE), "nfrl", X - 100, Y, {unitLevel = 2})
    local big = B.unit(Player(PLAYER_NEUTRAL_AGGRESSIVE), "nfrl", X - 120, Y, {unitLevel = 9})
    B.learn(chen, "chen_penitence", 4)
    B.learn(chen, "chen_holy_persuasion", 1)
    B.learn(chen, "chen_divine_favor", 4)
    B.learn(chen, "chen_zealot", 1)
    B.learn(chen, "chen_hand_of_god", 3)

    -- Zealot joins on spawn
    Events.emit("hero_spawned", chen, "chen", 2)
    local z = C.zealotOf[chen]
    B.check(z ~= nil, "zealot spawned")
    B.mark(z)

    -- Penitence and the attack speed it grants to attacking allies
    B.cast("chen_penitence", chen, 4, foeHero)
    B.advance(0.5)
    B.check(Mods.has(foeHero, "chen_penitence"), "penitence applied")
    B.attack(ally, foeHero, 20)
    B.check(Mods.has(ally, "chen_penitence_haste"), "allies attack faster")

    -- Holy Persuasion: lane creep (re-created for Chen), then a neutral which
    -- replaces it at max_units 1; a level 9 creep is refused
    local ctx = B.cast("chen_holy_persuasion", chen, 1, lane)
    local mine = nil
    for u, owner in pairs(C.persuaded) do if owner == chen then mine = u end end
    B.check(mine ~= nil and mine ~= lane and GetOwningPlayer(mine) == p, "lane creep taken over")
    B.mark(mine)
    B.cast("chen_holy_persuasion", chen, 1, neutral)
    B.check(C.persuaded[neutral] == chen and GetOwningPlayer(neutral) == p, "neutral persuaded")
    B.check(C.persuaded[mine] == nil, "oldest convert dropped at the limit")
    B.cast("chen_holy_persuasion", chen, 1, big)
    B.check(C.persuaded[big] == nil, "high level creep refused")
    -- unsummon by order (global) and through the cast
    B.attack(foe, neutral, 10)
    B.check(not C.unsummon(chen, neutral), "recently hurt creep stays")
    B.advance(3.5)
    Events.emit("order", chen, OrderId(ids.orders.chen_holy_persuasion), neutral, nil, nil)
    B.advance(0.1)
    B.check(C.persuaded[neutral] == nil, "unsummoned")

    -- Divine Favor aura and active (on Chen: all his units)
    A.get("chen_divine_favor").onLearn(chen, 4, A.get("chen_divine_favor"))
    B.cast("chen_divine_favor", chen, 4, chen)
    B.cast("chen_divine_favor", chen, 4, ally)
    B.advance(0.6)
    B.check(Mods.has(ally, "chen_divine_favor_aura"), "aura regen")
    B.check(Mods.sum(z, "heal_amp") > 0, "favor on Chen blesses his units")

    -- Hand of God heals with Divine Favor's amplification
    ally.life = 100
    B.cast("chen_hand_of_god", chen, 3)
    B.check(ally.life > 100 + 400, "hand of god heal (amplified)")
    B.check(Mods.has(z, "chen_hand_of_god"), "heal over time on controlled units")

    -- Zealot innate: teleport everything to Chen, and a teleport broken by damage
    SetUnitPosition(z, X + 3000, Y)
    B.cast("chen_zealot", chen, 1, chen)
    B.advance(6.2)
    B.check(math.abs(GetUnitX(z) - X) < 500, "zealot teleported to Chen")
    SetUnitPosition(ally, X + 3000, Y)
    B.cast("chen_zealot", chen, 1, ally)
    B.attack(foe, ally, 10)
    B.advance(6.2)
    B.check(math.abs(GetUnitX(ally) - X) > 2000, "damage cancels the teleport")

    -- Martyrdom: the Zealot sacrifices itself, then returns
    local hp = foe.life
    B.cast("chen_martyrdom", z, 1, foe)
    B.advance(0.5)
    B.check(foe.life < hp and z.dead, "martyrdom hits and the zealot dies")
    Events.emit("death", z, nil)
    B.advance(31)
    local z2 = C.zealotOf[chen]
    B.check(z2 ~= nil and z2 ~= z, "zealot respawns")
    B.mark(z2)
    Events.emit("hero_respawned", chen, "chen", 2)
    C.follow()
    C.favorAura()
    B.advance(1)

    -- Talents, Aghanim's Scepter (channelled Hand of God) and Shard (Ancients)
    local T, H = use("talents"), use("heroes")
    if not T.started then T.init() end
    local was = H.bySlot[2]
    H.keyOf[chen], H.bySlot[2] = "chen", chen
    T.register(chen)
    B.check(T.pick(chen, "special_bonus_unique_chen_2"), "chen full heal talent")
    B.check(T.pick(chen, "special_bonus_unique_chen_4"), "chen persuasion health talent")
    z2.life = 10
    B.cast("chen_hand_of_god", chen, 3)
    B.check(z2.life == BlzGetUnitMaxHP(z2), "talent: hand of god fully heals chen's units")
    local code = ids.items.item_ultimate_scepter
    if code and UnitAddItem then
        UnitAddItem(chen, CreateItem(FourCC(code), 0, 0))
        use("items").refresh(chen)
        B.check(A.value("chen_hand_of_god", "AbilityCooldown", 3, chen) == 70, "scepter hand of god cooldown")
        SetUnitPosition(ally, X + 100, Y)
        local ctx = B.cast("chen_hand_of_god", chen, 3)
        Mods.add(ally, "test_curse", {duration = 5, debuff = true, props = {move_pct = -0.5}})
        B.advance(0.3)
        B.check(C.channelling(chen) and not Mods.has(ally, "test_curse") and Mods.has(ally, "chen_hand_of_god_ward"),
            "scepter channel shields allies")
        ctx.def.onEndCast(ctx)
        B.advance(0.5)
        B.check(not C.channelling(chen), "channel ends")
    end
    local ancient = B.unit(Player(PLAYER_NEUTRAL_AGGRESSIVE), "nfrl", X - 100, Y + 100, {unitLevel = 2})
    local isAncient = IsUnitType
    IsUnitType = function(u, t)
        if u == ancient and t == UNIT_TYPE_ANCIENT then return true end
        return isAncient(u, t)
    end
    B.cast("chen_holy_persuasion", chen, 1, ancient)
    B.check(C.persuaded[ancient] == nil, "no ancients without the shard")
    T.consumeShard(chen)
    B.cast("chen_holy_persuasion", chen, 1, ancient)
    B.check(C.persuaded[ancient] == chen, "shard persuades an ancient")
    IsUnitType = isAncient
    T.forget(chen)
    H.keyOf[chen], H.bySlot[2] = nil, was
end}
