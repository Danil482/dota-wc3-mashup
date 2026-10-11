-- Offline exercise of the Techies handlers (heroes B: meepo, chen, furion, techies).
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

__mockB.list[#__mockB.list + 1] = {name = "techies", fn = function(B)
    local A, Events, Mods = use("abilities"), use("events"), use("mods")
    local T = use("hero_techies")
    local ids = use("data.ids")
    local X, Y = -8400, 3000
    local p, enemy = Player(4), Player(7)
    local tech = B.unit(p, ids.heroes.techies, X, Y, {hero = true, level = 12, mana = 600})
    tech.tal = true           -- per-unit ability fields (tools/mock/talents.lua) from the start
    local foe = B.unit(enemy, "hfoo", X + 400, Y)
    local foeHero = B.unit(enemy, "Hpal", X + 600, Y, {hero = true})
    B.tree(X + 620, Y + 60)
    for _, n in ipairs({"techies_sticky_bomb", "techies_reactive_tazer", "techies_suicide"}) do B.learn(tech, n, 4) end
    B.learn(tech, "techies_land_mines", 3)
    B.learn(tech, "techies_mutually_assured_destruction", 1)
    Events.emit("hero_spawned", tech, "techies", 4)

    -- Sticky Bomb: lands next to the hero, chases, sticks, explodes
    local hp = foeHero.life
    B.cast("techies_sticky_bomb", tech, 4, nil, X + 500, Y)
    B.advance(1.6)
    B.check(Mods.has(foeHero, "techies_sticky_bomb"), "bomb stuck to the hero")
    B.advance(2.2)
    B.check(foeHero.life < hp and Mods.has(foeHero, "techies_sticky_bomb_slow"), "bomb exploded")
    -- and one that lands on nothing
    B.cast("techies_sticky_bomb", tech, 4, nil, X - 600, Y)
    B.advance(3.5)

    -- Reactive Tazer: attackers get zapped, detonation disarms around
    B.cast("techies_reactive_tazer", tech, 4, tech)
    B.advance(0.05)
    B.check(GetUnitAbilityLevel(tech, A.id("techies_tazer_detonate")) > 0, "detonate shown")
    B.attack(foe, tech, 15)
    B.check(Mods.has(foe, "techies_tazer_disarm"), "attacker disarmed")
    SetUnitPosition(foeHero, X + 100, Y)
    B.cast("techies_tazer_detonate", tech, 1)
    B.check(Mods.has(foeHero, "techies_tazer_disarm") and not Mods.has(tech, "techies_tazer"), "detonated")
    B.advance(0.2)
    B.check(GetUnitAbilityLevel(tech, A.id("techies_tazer_detonate")) == 0, "detonate hidden again")
    B.cast("techies_reactive_tazer", tech, 4, tech)
    B.advance(6.2)
    B.check(not Mods.has(tech, "techies_tazer"), "tazer expired")

    -- Blast Off!: interrupted (refund), then a full leap
    local ctx = B.cast("techies_suicide", tech, 4, nil, X + 500, Y)
    B.advance(0.3)
    ctx.def.onEndCast(ctx)
    B.check(GetUnitX(tech) == X, "interrupted blast stays")
    tech.life = 500
    ctx = B.cast("techies_suicide", tech, 4, nil, X + 500, Y)
    B.advance(0.75)
    ctx.def.onEndCast(ctx)
    B.advance(1)
    B.check(math.abs(GetUnitX(tech) - (X + 500)) < 1, "landed at the target")
    B.check(tech.life < 500 and tech.life >= 1, "blast self damage")
    B.check(Mods.has(foe, "techies_blast_off_stun"), "landing stuns")
    SetUnitPosition(tech, X, Y)

    -- Proximity Mines: placement rule, charges, trigger after the threshold
    A.get("techies_land_mines").onLearn(tech, 3, A.get("techies_land_mines"))
    SetUnitPosition(foeHero, X + 2000, Y)
    SetUnitPosition(foe, X + 2000, Y + 100)
    B.cast("techies_land_mines", tech, 3, nil, X + 300, Y - 600)
    B.cast("techies_land_mines", tech, 3, nil, X + 300, Y + 600)
    B.cast("techies_land_mines", tech, 3, nil, X + 1200, Y)
    local n = 0
    for m in pairs(T.mines) do
        n = n + 1
        B.mark(m)
    end
    B.check(n == 3 and T.charges[tech].n == 0, "three mines, no charges left")
    B.advance(2)
    SetUnitPosition(foeHero, X + 1250, Y)
    B.advance(1.3)
    n = 0
    for _ in pairs(T.mines) do n = n + 1 end
    B.check(n == 2, "mine exploded on the hero, mines left " .. n)
    B.advance(15)
    B.check(T.charges[tech].n >= 1, "a charge came back")

    -- M.A.D.: mana regen and the barrel on death
    T.madTick()
    B.check(Mods.sum(tech, "mana_regen") > 0, "mad mana regen")
    SetUnitPosition(foe, X + 100, Y)
    foe.life = 500
    hp = foe.life
    tech.dead = true
    Events.emit("death", tech, foe)
    B.advance(1.6)
    B.check(foe.life < hp, "mad barrel exploded")
    tech.dead = false
    B.advance(1)

    -- Talents, Aghanim's Scepter (Minefield Sign, Proximity Mines range) and
    -- Aghanim's Shard (M.A.D. planted and detonated)
    local Tal, H, Dmg = use("talents"), use("heroes"), use("damage")
    if not Tal.started then Tal.init() end
    for m in pairs(T.mines) do RemoveUnit(m) end
    SetUnitPosition(foe, X + 6000, Y + 6000)
    SetUnitPosition(foeHero, X + 6000, Y - 6000)
    SetUnitPosition(tech, X, Y)
    tech.life, tech.mana = 500, 600
    local made = {}
    local function victim(x, y)
        local v = B.unit(enemy, "Hpal", x, y, {hero = true, hp = 5000})
        made[#made + 1] = v
        return v
    end
    local function taken(v) return 5000 - v.life end
    local probe = victim(X + 6000, Y)
    Dmg.deal(tech, probe, 100, "magical")
    local magic = taken(probe) / 100
    B.check(magic > 0.5 and magic <= 1, "magic damage factor " .. magic)
    local function stickyDamage(x, y)
        local v = victim(x, y)
        B.cast("techies_sticky_bomb", tech, 4, nil, x - 50, y)
        B.advance(4)
        return taken(v)
    end
    local function blastDamage(x, y)
        local v = victim(x, y)
        tech.life = 500
        T.leap(tech, 4, x - 50, y)
        B.advance(1)
        SetUnitPosition(tech, X, Y)
        return taken(v)
    end
    local sticky0, blast0 = stickyDamage(X, Y + 3000), blastDamage(X + 3000, Y)

    local slot = GetPlayerId(p)
    local was = H.bySlot[slot]
    H.keyOf[tech], H.bySlot[slot] = "techies", tech
    tech.level = 30
    Tal.register(tech)
    for _, n in ipairs({"special_bonus_unique_techies_3", "special_bonus_unique_techies",
                        "special_bonus_unique_techies_tazer_duration", "special_bonus_unique_techies_2",
                        "special_bonus_unique_techies_5", "special_bonus_unique_techies_4"}) do
        B.check(Tal.pick(tech, n), "talent " .. n)
    end
    local r = stickyDamage(X, Y + 3500) / sticky0
    B.check(math.abs(r - 480 / 320) < 0.01, "talent +160 Sticky Bomb damage, ratio " .. r)
    r = blastDamage(X + 3500, Y) / blast0
    B.check(math.abs(r - 675 / 500) < 0.01, "talent +175 Blast Off! damage, ratio " .. r)
    local cd = BlzGetUnitAbilityCooldown(tech, A.id("techies_suicide"), 3)
    B.check(math.abs(cd - 10) < 0.01, "talent -15s Blast Off! cooldown: " .. cd)
    B.cast("techies_reactive_tazer", tech, 4, tech)
    local tz = Mods.get(tech, "techies_tazer")
    B.check(tz ~= nil and math.abs(tz.disarm - 3.75) < 0.01, "talent +25% tazer disarm")
    B.advance(7.2)
    B.check(Mods.has(tech, "techies_tazer"), "talent +25% tazer duration")
    B.advance(0.5)
    B.check(not Mods.has(tech, "techies_tazer"), "longer tazer expired")
    T.charges[tech].n, T.charges[tech].nextAt = 3, nil
    B.cast("techies_land_mines", tech, 3, nil, X - 3000, Y - 3000)
    local now = use("timer").now()
    local placed = nil
    for m, info in pairs(T.mines) do
        if info.techies == tech and GetUnitX(m) == X - 3000 then placed = m end
    end
    B.check(placed ~= nil and math.abs(T.mines[placed].armAt - now - 0.2) < 0.01, "talent -0.8s mine activation delay")
    B.check(math.abs(T.charges[tech].nextAt - now - 13) < 0.01, "talent -2s mine charge time")
    RemoveUnit(placed)

    -- Aghanim's Scepter
    local code = use("data.ids").items.item_ultimate_scepter
    B.check(code ~= nil and UnitAddItem ~= nil, "scepter item")
    local scepter = CreateItem(FourCC(code), 0, 0)
    UnitAddItem(tech, scepter)
    use("items").refresh(tech)
    B.check(Tal.hasScepter(tech), "scepter on")
    B.check(GetUnitAbilityLevel(tech, A.id("techies_minefield_sign")) == 1, "scepter grants Minefield Sign")
    local range = BlzGetAbilityRealLevelField(BlzGetUnitAbility(tech, A.id("techies_land_mines")), ABILITY_RLF_CAST_RANGE, 2)
    B.check(math.abs(range - 750) < 1, "scepter Proximity Mines cast range " .. range)
    local SX, SY = X, Y + 1500
    B.cast("techies_minefield_sign", tech, 1, nil, SX, SY)
    local sign = T.signs[tech]
    B.check(sign ~= nil and GetUnitAbilityLevel(sign.unit, FourCC("Apiv")) == 0, "sign planted in sight")
    local guarded = B.unit(p, ids.units.techies_mine, SX + 300, SY)
    T.mines[guarded] = {techies = tech, level = 3, armAt = math.huge, near = 0, hidden = true}
    B.advance(0.15)
    B.check(T.mines[guarded].guarded == true, "a mine under the sign is invulnerable")
    local va, vb = victim(SX + 300, SY + 50), victim(X + 3000, Y + 3050)
    local free = B.unit(p, ids.units.techies_mine, X + 3000, Y + 3000)
    T.mineExplode(guarded, {techies = tech, level = 3})
    T.mineExplode(free, {techies = tech, level = 3})
    r = taken(va) / taken(vb)
    B.check(math.abs(r - 1.15) < 0.01, "a mine under the sign deals 15% more, ratio " .. r)
    local walker = victim(SX + 150, SY)
    B.advance(0.15)
    B.check(sign.field ~= nil, "an enemy hero near the sign starts the minefield")
    for i = 1, 3 do
        SetUnitPosition(walker, SX + 150 + 150 * i, SY)
        B.advance(0.1)
    end
    B.advance(0.1)
    local hits = taken(walker) / (300 * magic)
    B.check(math.abs(hits - 2) < 0.01, "minefield: 300 damage per 200 units moved, hits " .. hits)
    B.advance(10)
    B.check(T.signs[tech] == nil, "the sign is gone after the minefield")

    -- Aghanim's Shard
    B.check(Tal.consumeShard(tech), "shard consumed")
    local plant, det = A.id("techies_mad_plant"), A.id("techies_mad_detonate")
    B.check(plant ~= nil and det ~= nil and GetUnitAbilityLevel(tech, plant) == 1, "shard: M.A.D. turns active")
    cd = BlzGetUnitAbilityCooldown(tech, plant, 0)
    B.check(math.abs(cd - 30) < 0.01, "shard M.A.D. cooldown " .. cd)
    range = BlzGetAbilityRealLevelField(BlzGetUnitAbility(tech, plant), ABILITY_RLF_CAST_RANGE, 0)
    B.check(math.abs(range - 450) < 1, "shard M.A.D. cast range " .. range)
    local vm = victim(X - 1500, Y)
    B.cast("techies_mad_plant", tech, 1, nil, X - 1450, Y)
    B.advance(0.05)
    B.check(T.planted[tech] ~= nil and GetUnitAbilityLevel(tech, det) == 1, "charge planted, Detonate M.A.D. shown")
    B.cast("techies_mad_detonate", tech, 1)
    B.advance(0.05)
    local want = (50 + 0.4 * 600) * magic
    B.check(math.abs(taken(vm) - want) < 1, "detonated M.A.D. deals 50 + 40% max mana: " .. taken(vm))
    B.check(T.planted[tech] == nil and GetUnitAbilityLevel(tech, det) == 0, "Detonate M.A.D. gone with the charge")

    UnitRemoveItem(tech, scepter)
    use("items").refresh(tech)
    for _, v in ipairs(made) do RemoveUnit(v) end
    Tal.forget(tech)
    H.keyOf[tech], H.bySlot[slot] = nil, was
    tech.tal = nil
end}
