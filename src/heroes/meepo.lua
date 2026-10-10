-- Meepo: Earthbind, Poof, Ransack, Divided We Stand and the Geomancy innate.
-- Clones are real extra heroes of Meepo's unit type. They hand every point of
-- experience they earn to the main Meepo, copy his level and learned skills,
-- respawn with him, and all Meepos die together.
define("hero_meepo", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Safe = use("safe")
    local Log = use("log")
    local Bots = use("bots")
    local M = {}

    local EARTHBIND, POOF, RANSACK = "meepo_earthbind", "meepo_poof", "meepo_ransack"
    local DWS, GEOMANCY = "meepo_divided_we_stand", "meepo_geomancy"
    local LEARNED = {EARTHBIND, POOF, RANSACK, DWS}
    local UNIT_CAST_POINT = 0.3       -- "ucpt" of every hero, see gen_objects.py
    local CREEP_STEAL = 0.6           -- Ransack against non-heroes (Dota tooltip: 60 %)
    local TREE_TYPES = {"ATtr", "BTtw", "CTtr", "FTtw", "LTlt", "NTtw", "WTtw", "WTst", "YTct", "YTwt",
                        "YTst", "YTft", "VTlt", "DTsh", "ZTtw", "ITtw", "ATtc", "OTtw", "KTtw", "JTct",
                        "JTtw", "GTsh", "BTtc", "CTtc", "NTtc", "ZTtc", "ITtc"}

    ---------------------------------------------------------------- helpers
    local function fx(model, x, y)
        DestroyEffect(AddSpecialEffect(model, x, y))
    end

    local function fxOn(model, u, attach)
        DestroyEffect(AddSpecialEffectTarget(model, u, attach or "origin"))
    end

    local zloc = nil
    local function groundZ(x, y)
        if not zloc then zloc = Location(0, 0) end
        MoveLocation(zloc, x, y)
        return GetLocationZ(zloc)
    end

    -- Stops a cast before its cost is paid (spell_channel runs before the effect).
    local function cancel(u, msg)
        PauseUnit(u, true)
        IssueImmediateOrder(u, "stop")
        PauseUnit(u, false)
        if msg then
            DisplayTimedTextToPlayer(GetOwningPlayer(u), 0, 0, 2, "|cffffcc00" .. msg .. "|r")
        end
    end

    -- Dota charges nothing for a cast point that gets interrupted.
    local function refund(ctx)
        local cost = BlzGetUnitAbilityManaCost(ctx.caster, ctx.def.id, math.max(0, ctx.level - 1))
        SetUnitState(ctx.caster, UNIT_STATE_MANA, GetUnitState(ctx.caster, UNIT_STATE_MANA) + cost)
        BlzEndUnitAbilityCooldown(ctx.caster, ctx.def.id)
    end

    -- A model flying from (x, y) to a point at `speed`; onHit(x, y) on arrival.
    local function missile(o)
        local e = AddSpecialEffect(o.model, o.x, o.y)
        local x, y, age = o.x, o.y, 0
        local a = U.angle(x, y, o.tx, o.ty)
        BlzSetSpecialEffectYaw(e, a)
        Timer.onFrame(function(dt)
            age = age + dt
            local d = U.dist(x, y, o.tx, o.ty)
            local step = o.speed * dt
            if d <= step or age > 10 then
                DestroyEffect(e)
                o.onHit(o.tx, o.ty)
                return true
            end
            x, y = x + step * math.cos(a), y + step * math.sin(a)
            BlzSetSpecialEffectPosition(e, x, y, groundZ(x, y) + (o.z or 60))
            return false
        end)
    end

    local treeType = nil
    local rect = nil
    -- Alive trees within r of (x, y).
    local function treesIn(x, y, r)
        if not treeType then
            treeType = {}
            for _, c in ipairs(TREE_TYPES) do treeType[FourCC(c)] = true end
        end
        if not rect then rect = Rect(0, 0, 0, 0) end
        SetRect(rect, x - r, y - r, x + r, y + r)
        local out = {}
        EnumDestructablesInRect(rect, nil, function()
            Safe.call(function()
                local d = GetEnumDestructable()
                if treeType[GetDestructableTypeId(d)] and GetDestructableLife(d) > 0
                    and U.dist(x, y, GetDestructableX(d), GetDestructableY(d)) <= r then
                    out[#out + 1] = d
                end
            end)
        end)
        return out
    end

    local function inWater(x, y)
        -- IsTerrainPathable is true when the pathing flag is NOT set
        return not IsTerrainPathable(x, y, PATHING_TYPE_FLOATABILITY)
    end

    local function level(u, name)
        return A.level(u, name)
    end

    ---------------------------------------------------------------- Meepo groups
    -- main Meepo -> {main, clones = {}, xp = {clone -> last synced xp}, water, geo}
    local groups, cloneOf = {}, {}
    local meepoType = nil
    local loops = false
    local startLoops            -- forward declaration

    local function groupOf(u)
        if u == nil then return nil end
        local g = cloneOf[u] or groups[u]
        if g then return g end
        if meepoType == nil then
            local code = use("data.ids").heroes.meepo
            meepoType = code and FourCC(code) or -1
        end
        if GetUnitTypeId(u) == meepoType and IsUnitType(u, UNIT_TYPE_HERO) and not IsUnitIllusion(u) then
            g = {main = u, clones = {}, xp = {}, water = 0, geo = {}}
            groups[u] = g
            startLoops()
            return g
        end
        return nil
    end

    local function members(g)
        local list = {g.main}
        for _, c in ipairs(g.clones) do list[#list + 1] = c end
        return list
    end

    local function dropSkillPoints(u)
        local left = GetHeroSkillPoints(u)
        if left > 0 then UnitModifySkillPoints(u, -left) end
    end

    -- Clone experience follows the main Meepo exactly.
    local function syncXp(g, c)
        local xp = GetHeroXP(g.main)
        if GetHeroXP(c) < xp then SetHeroXP(c, xp, false) end
        g.xp[c] = GetHeroXP(c)
        dropSkillPoints(c)
    end

    -- Learn an ability on a clone up to the main Meepo's level of it.
    local function learnLike(g, c, id)
        local want = GetUnitAbilityLevel(g.main, id)
        local guard = 0
        while GetUnitAbilityLevel(c, id) < want and guard < 6 do
            guard = guard + 1
            UnitModifySkillPoints(c, 1)
            SelectHeroSkill(c, id)
        end
        dropSkillPoints(c)
    end

    local function spawnClone(g)
        local m = g.main
        local x, y = U.polar(GetUnitX(m), GetUnitY(m), 150, GetRandomReal(0, 2 * math.pi))
        local c = CreateUnit(GetOwningPlayer(m), GetUnitTypeId(m), x, y, GetUnitFacing(m))
        cloneOf[c] = g
        g.clones[#g.clones + 1] = c
        -- SIMPLIFIED: clones carry no items (Dota shares the main inventory and
        -- splits item stats, the dps_penalty_pct value); no inventory at all.
        UnitRemoveAbility(c, FourCC("AInv"))
        for _, code in ipairs(use("data.ids").heroes["meepo_innates"] or {}) do
            UnitAddAbility(c, FourCC(code))
            UnitMakeAbilityPermanent(c, true, FourCC(code))
        end
        syncXp(g, c)
        for _, name in ipairs(LEARNED) do
            local id = A.id(name)
            if id then learnLike(g, c, id) end
        end
        SetWidgetLife(c, BlzGetUnitMaxHP(c))
        SetUnitState(c, UNIT_STATE_MANA, GetUnitState(c, UNIT_STATE_MAX_MANA))
        use("sound").register(c, "meepo")
        fx("Abilities\\Spells\\Orc\\FeralSpirit\\feralspirittarget.mdl", x, y)
        local slot = GetPlayerId(GetOwningPlayer(m))
        if use("roles").isBot(slot) and defined("hero_bot") then
            use("hero_bot").add(c, "meepo")
        end
        Log.info("meepo clone " .. #g.clones .. " for slot " .. slot)
        return c
    end

    -- Clone experience goes to the main Meepo; then every clone copies him.
    local function syncAll()
        for main, g in pairs(groups) do
            if #g.clones > 0 then
                local gained = 0
                for _, c in ipairs(g.clones) do
                    local now, last = GetHeroXP(c), g.xp[c] or GetHeroXP(c)
                    if now > last then gained = gained + (now - last) end
                end
                if gained > 0 then AddHeroXP(main, gained, true) end
                for _, c in ipairs(g.clones) do syncXp(g, c) end
            end
        end
    end

    ---------------------------------------------------------------- Geomancy
    -- Every Meepo grants its terrain bonus to all Meepos: a tree within
    -- tree_radius gives HP regen, dirt (anything but water) gives move speed,
    -- water makes their attacks slow.
    local function geomancyAll()
        for _, g in pairs(groups) do
            local list = members(g)
            local r = A.value(GEOMANCY, "tree_radius", 1)
            local nTree, nDirt, nWater = 0, 0, 0
            for _, u in ipairs(list) do
                if U.alive(u) and level(u, GEOMANCY) > 0 and not Mods.flag(u, "break") then
                    local x, y = GetUnitX(u), GetUnitY(u)
                    if #treesIn(x, y, r) > 0 then nTree = nTree + 1 end
                    if inWater(x, y) then nWater = nWater + 1 else nDirt = nDirt + 1 end
                end
            end
            g.water = nWater
            local regen = nTree * A.value(GEOMANCY, "tree_regen", 1)
            local ms = nDirt * A.value(GEOMANCY, "dirt_move_speed", 1) / 100
            local key = regen .. ":" .. ms
            for _, u in ipairs(list) do
                if U.alive(u) and g.geo[u] ~= key then
                    g.geo[u] = key
                    Mods.add(u, "meepo_geomancy", {persist = true, dispel = "none",
                        props = {hp_regen = regen, move_pct = ms}})
                end
            end
        end
    end

    startLoops = function()
        if loops then return end
        loops = true
        Timer.every(0.25, syncAll)
        Timer.every(0.5, geomancyAll)
    end

    ---------------------------------------------------------------- Earthbind
    A.define(EARTHBIND, {
        onCast = function(ctx)
            local c = ctx.caster
            local radius, duration = ctx.v("radius"), ctx.v("duration")
            missile({model = "Abilities\\Spells\\Orc\\Ensnare\\EnsnareMissile.mdl",
                x = GetUnitX(c), y = GetUnitY(c), tx = ctx.x, ty = ctx.y, speed = ctx.v("speed"),
                onHit = function(x, y)
                    fx("Abilities\\Spells\\Orc\\Ensnare\\ensnareTarget.mdl", x, y)
                    for _, t in ipairs(U.enemiesOf(ctx.owner, x, y, radius)) do
                        if not U.isMagicImmune(t) then
                            Mods.add(t, "meepo_earthbind", {duration = duration, source = c, debuff = true,
                                props = {root = true},
                                effect = "Abilities\\Spells\\Orc\\Ensnare\\ensnareTarget.mdl", attach = "origin"})
                        end
                    end
                end})
        end,
    })

    ---------------------------------------------------------------- Poof
    -- Dota's 1.5 s cast point is a Channel follow-through (minus the unit's own
    -- cast point); the teleport happens only if it completes.
    local poofing = {}          -- caster -> {start, target, x, y, fx}

    local function poofTime(lvl)
        return A.value(POOF, "cast_duration", lvl) - UNIT_CAST_POINT
    end

    -- The Meepo to arrive at: the targeted Meepo, else the one nearest the point.
    local function destination(caster, target, x, y)
        local g = groupOf(caster)
        if not g then return caster end
        if target and (cloneOf[target] == g or groups[target] == g) and U.alive(target) then
            return target
        end
        if target then x, y = GetUnitX(target), GetUnitY(target) end
        local alive = {}
        for _, u in ipairs(members(g)) do
            if U.alive(u) then alive[#alive + 1] = u end
        end
        return U.nearest(alive, x, y) or caster
    end

    local function poofBlast(caster, lvl, x, y)
        fx("Abilities\\Spells\\Orc\\WarStomp\\WarStompCaster.mdl", x, y)
        local dmg = A.value(POOF, "poof_damage", lvl)
        for _, t in ipairs(U.enemiesOf(GetOwningPlayer(caster), x, y, A.value(POOF, "radius", lvl))) do
            Damage.deal(caster, t, dmg, "magical")
        end
    end

    A.define(POOF, {
        onChannel = function(ctx)
            if Mods.flag(ctx.caster, "root") then cancel(ctx.caster, "Rooted") end
        end,
        onCast = function(ctx)
            local c = ctx.caster
            local old = poofing[c]
            if old and old.fx then DestroyEffect(old.fx) end
            poofing[c] = {start = Timer.now(), target = ctx.target, x = ctx.x, y = ctx.y,
                fx = AddSpecialEffectTarget("Abilities\\Spells\\Human\\MassTeleport\\MassTeleportTarget.mdl", c, "origin")}
        end,
        onEndCast = function(ctx)
            local c = ctx.caster
            local p = poofing[c]
            if not p then return end
            poofing[c] = nil
            DestroyEffect(p.fx)
            if Timer.now() - p.start < poofTime(ctx.level) - 0.1 then
                refund(ctx)
                return
            end
            if not U.alive(c) then return end
            local dest = destination(c, p.target, p.x, p.y)
            -- departure and arrival are separate hits, so a self-Poof hits twice
            fx("Abilities\\Spells\\NightElf\\Blink\\BlinkCaster.mdl", GetUnitX(c), GetUnitY(c))
            poofBlast(c, ctx.level, GetUnitX(c), GetUnitY(c))
            if dest ~= c then
                SetUnitPosition(c, GetUnitX(dest), GetUnitY(dest))
            end
            fx("Abilities\\Spells\\NightElf\\Blink\\BlinkTarget.mdl", GetUnitX(c), GetUnitY(c))
            poofBlast(c, ctx.level, GetUnitX(c), GetUnitY(c))
        end,
    })

    ---------------------------------------------------------------- Ransack (+ Geomancy water slow)
    A.define(RANSACK, {
        onLearn = function(hero) groupOf(hero) end,
    })

    Damage.onDamaged(function(source, target, amount, info)
        if not info.attack or source == nil or target == nil then return end
        local g = groupOf(source)
        if not g or not U.alive(target) or U.isStructure(target) then return end
        local owner = GetOwningPlayer(source)
        if not IsUnitEnemy(target, owner) then return end
        local broken = Mods.flag(source, "break")
        local lvl = level(source, RANSACK)
        if lvl > 0 and not broken then
            local steal = A.value(RANSACK, "health_steal_heroes", lvl)
            if not U.isHero(target) then steal = steal * CREEP_STEAL end
            local dealt = Damage.deal(source, target, steal, "pure", {noAmp = true, tag = "meepo_ransack"})
            if dealt > 0 then
                for _, u in ipairs(members(g)) do
                    if U.alive(u) then Damage.heal(u, dealt) end
                end
                fxOn("Abilities\\Spells\\Undead\\VampiricAura\\VampiricAuraTarget.mdl", source, "origin")
            end
        end
        if g.water > 0 and U.alive(target) and level(source, GEOMANCY) > 0 and not broken then
            Mods.add(target, "meepo_geomancy_slow", {
                duration = A.value(GEOMANCY, "water_slow_duration", 1), source = source, debuff = true,
                props = {move_pct = -g.water * A.value(GEOMANCY, "water_move_slow", 1) / 100}})
        end
    end)

    ---------------------------------------------------------------- Divided We Stand
    A.define(DWS, {
        onLearn = function(hero, lvl)
            if cloneOf[hero] then return end
            local g = groupOf(hero)
            if not g then return end
            local want = math.floor(A.value(DWS, "tooltip_clones", lvl) + 0.5)
            local guard = 0
            while #g.clones < want and guard < 8 do
                guard = guard + 1
                spawnClone(g)
            end
        end,
    })

    -- Skills learned by the main Meepo are learned by every clone too.
    Events.on("hero_skill", function(hero, abil)
        local g = groups[hero]
        if not g then return end
        for _, c in ipairs(g.clones) do learnLike(g, c, abil) end
    end)

    -- Clones never keep skill points of their own.
    Events.on("hero_level", function(hero)
        if cloneOf[hero] then dropSkillPoints(hero) end
    end)

    Events.on("hero_spawned", function(u, key)
        if key == "meepo" then groupOf(u) end
    end)

    -- If any Meepo dies, they all die (only the one actually killed gives a bounty).
    Events.on("death", function(dying)
        local g = cloneOf[dying] or groups[dying]
        if not g or g.dying then return end
        g.dying = true
        for _, u in ipairs(members(g)) do
            if u ~= dying and U.alive(u) then KillUnit(u) end
        end
        g.dying = false
    end)

    -- Clones come back with the main Meepo.
    Events.on("hero_respawned", function(u)
        local g = groups[u]
        if not g then return end
        for _, c in ipairs(g.clones) do
            if not U.alive(c) then
                local x, y = U.polar(GetUnitX(u), GetUnitY(u), 150, GetRandomReal(0, 2 * math.pi))
                ReviveHero(c, x, y, true)
            end
        end
    end)

    ---------------------------------------------------------------- bots
    Bots.hint(EARTHBIND, {target = "enemyHero", point = true})
    Bots.hint(POOF, {target = "self", radius = 375, minEnemies = 2})

    -- exposed for tests and other modules
    M.groupOf, M.members, M.spawnClone, M.syncAll, M.geomancyAll = groupOf, members, spawnClone, syncAll, geomancyAll
    M.isClone = function(u) return cloneOf[u] ~= nil end
    return M
end)
