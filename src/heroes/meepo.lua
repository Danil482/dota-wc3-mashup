-- Meepo: Earthbind, Poof, Ransack, Divided We Stand and the Geomancy innate;
-- Aghanim's Shard grants Dig to every Meepo, Aghanim's Scepter MegaMeepo
-- (with its MegaMeepo Fling) to the main one.
-- Clones are real extra heroes of Meepo's unit type. They hand every point of
-- experience they earn to the main Meepo, copy his level and learned skills,
-- respawn with him, and all Meepos die together. They take his talents but
-- not his attribute bonuses (talents.lua addMember).
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
    local DIG, MEGA, FLING = "meepo_petrify", "meepo_megameepo", "meepo_megameepo_fling"
    local LEARNED = {EARTHBIND, POOF, RANSACK, DWS}
    -- Fling stands in for MegaMeepo while it is up; this module adds it
    use("talents").manual(FLING)
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

    -- Dota's 1.5 s cast point is a Channel follow-through (minus the unit's
    -- own cast point); the level 25 talent shortens it, so each Meepo's Poof
    -- object follows its own value.
    local function poofTime(lvl, u)
        return A.value(POOF, "cast_duration", lvl, u) - UNIT_CAST_POINT
    end

    local function syncPoof(u)
        local id = A.id(POOF)
        local ab = id and BlzGetUnitAbility(u, id)
        if not ab then return end
        for li = 0, math.max(1, BlzGetAbilityIntegerField(ab, ABILITY_IF_LEVELS), GetUnitAbilityLevel(u, id)) - 1 do
            BlzSetAbilityRealLevelField(ab, ABILITY_RLF_FOLLOW_THROUGH_TIME, li, math.max(0.05, poofTime(li + 1, u)))
        end
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
        use("talents").addMember(m, c)
        syncPoof(c)
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
    local mega = {}             -- main Meepo -> MegaMeepo state (below)

    local function stacked(u)
        local s = mega[u]
        return s and #s.stack or 0
    end

    A.define(EARTHBIND, {
        onCast = function(ctx)
            local c = ctx.caster
            local radius, duration = ctx.v("radius"), ctx.v("duration")
            -- talent: attacks on the netted always hit (true strike)
            local sure = ctx.v("true_strike") > 0 or nil
            -- MegaMeepo throws one more net per stacked Meepo, side by side
            local nets = 1 + stacked(c)
            local a = U.angle(GetUnitX(c), GetUnitY(c), ctx.x, ctx.y)
            for i = 1, nets do
                local off = (i - (nets + 1) / 2) * ctx.v("megameepo_net_offset")
                local tx, ty = U.polar(ctx.x, ctx.y, off, a + math.pi / 2)
                missile({model = "Abilities\\Spells\\Orc\\Ensnare\\EnsnareMissile.mdl",
                    x = GetUnitX(c), y = GetUnitY(c), tx = tx, ty = ty, speed = ctx.v("speed"),
                    onHit = function(x, y)
                        fx("Abilities\\Spells\\Orc\\Ensnare\\ensnareTarget.mdl", x, y)
                        for _, t in ipairs(U.enemiesOf(ctx.owner, x, y, radius)) do
                            if not U.isMagicImmune(t) then
                                Mods.add(t, "meepo_earthbind", {duration = duration, source = c, debuff = true,
                                    props = {root = true, no_evade = sure},
                                    effect = "Abilities\\Spells\\Orc\\Ensnare\\ensnareTarget.mdl", attach = "origin"})
                            end
                        end
                    end})
            end
        end,
    })

    ---------------------------------------------------------------- Poof
    -- The teleport happens only if the cast point (poofTime) completes.
    local poofing = {}          -- caster -> {start, target, x, y, fx}

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
        -- MegaMeepo: + megameepo_poof_scaling % per stacked Meepo
        local dmg = A.value(POOF, "poof_damage", lvl, caster)
            * (1 + stacked(caster) * A.value(POOF, "megameepo_poof_scaling", lvl, caster) / 100)
        for _, t in ipairs(U.enemiesOf(GetOwningPlayer(caster), x, y, A.value(POOF, "radius", lvl, caster))) do
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
            if Timer.now() - p.start < poofTime(ctx.level, c) - 0.1 then
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
            local steal = A.value(RANSACK, "health_steal_heroes", lvl, source)
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

    ---------------------------------------------------------------- Dig (Aghanim's Shard)
    -- A basic dispel, then for `duration` the Meepo is stunned, invulnerable
    -- and out of sight underground, regaining hp_restore % of its maximum
    -- health over it (https://liquipedia.net/dota2/Meepo, Dig).
    local DUST = "Objects\\Spawnmodels\\Undead\\ImpaleTargetDust\\ImpaleTargetDust.mdl"
    A.define(DIG, {
        onChannel = function(ctx)
            if Mods.flag(ctx.caster, "root") then cancel(ctx.caster, "Rooted") end
        end,
        onCast = function(ctx)
            local u = ctx.caster
            local dur = math.max(0.1, ctx.v("duration"))
            Mods.dispel(u, {debuffs = true})
            SetUnitVertexColor(u, 255, 255, 255, 0)
            fx(DUST, GetUnitX(u), GetUnitY(u))
            Mods.add(u, "meepo_dig", {duration = dur, source = u, dispel = "none",
                props = {stun = true, invulnerable = true,
                         hp_regen = BlzGetUnitMaxHP(u) * ctx.v("hp_restore") / 100 / dur},
                onRemove = function()
                    SetUnitVertexColor(u, 255, 255, 255, 255)
                    if U.alive(u) then fx(DUST, GetUnitX(u), GetUnitY(u)) end
                end})
        end,
    })

    ---------------------------------------------------------------- MegaMeepo (Aghanim's Scepter)
    -- The main Meepo lifts the clones within `radius` onto his shoulders for
    -- `duration`: they ride hidden and invulnerable, he gains stats_pct % of
    -- his best base attribute per rider to every attribute, and MegaMeepo
    -- Fling takes the button to throw them one by one at enemies. It ends
    -- when the time is up, the last one is thrown or he dies; the riders left
    -- jump off around him (https://liquipedia.net/dota2/Meepo, MegaMeepo).
    local function megaStats(s)
        local u = s.main
        local best = math.max(GetHeroStr(u, false), GetHeroAgi(u, false), GetHeroInt(u, false))
        local b = math.floor(best * s.pct) * #s.stack
        Mods.add(u, "meepo_megameepo", {source = u, persist = true, dispel = "none", props = {str = b, agi = b, int = b}})
    end

    local function dropOff(c, x, y)
        Mods.remove(c, "meepo_megameepo_ride")
        ShowUnit(c, true)
        SetUnitPathing(c, true)
        if U.alive(c) then SetUnitPosition(c, x, y) end
    end

    local function endMega(u)
        local s = mega[u]
        if not s then return end
        mega[u] = nil
        Mods.remove(u, "meepo_megameepo")
        for i, c in ipairs(s.stack) do
            dropOff(c, U.polar(GetUnitX(u), GetUnitY(u), s.knock, 2 * math.pi * i / #s.stack))
        end
        s.stack = {}
        local fling, megaId = A.id(FLING), A.id(MEGA)
        if fling then UnitRemoveAbility(u, fling) end
        if megaId then BlzUnitHideAbility(u, megaId, false) end
    end
    M.endMega = endMega

    local function riders(u, radius)
        local g = groupOf(u)
        local out = {}
        for _, c in ipairs(g and g.clones or {}) do
            if U.alive(c) and U.unitDist(c, u) <= radius then out[#out + 1] = c end
        end
        return out
    end

    A.define(MEGA, {
        onChannel = function(ctx)
            if #riders(ctx.caster, ctx.v("radius")) == 0 then cancel(ctx.caster, "No Meepo nearby") end
        end,
        onCast = function(ctx)
            local u = ctx.caster
            if cloneOf[u] or mega[u] then return end
            local s = {main = u, stack = riders(u, ctx.v("radius")), pct = ctx.v("stats_pct") / 100,
                       knock = ctx.v("end_knockback_distance")}
            if #s.stack == 0 then return end
            mega[u] = s
            for _, c in ipairs(s.stack) do
                Mods.add(c, "meepo_megameepo_ride", {source = u, dispel = "none", props = {stun = true, invulnerable = true}})
                SetUnitPathing(c, false)
                ShowUnit(c, false)
            end
            megaStats(s)
            fxOn("Abilities\\Spells\\Orc\\FeralSpirit\\feralspirittarget.mdl", u, "origin")
            -- Fling takes MegaMeepo's button; not inside its own cast event
            local megaId = ctx.def.id
            Timer.after(0, function()
                if mega[u] ~= s then return end
                local fling = A.id(FLING)
                if fling then
                    UnitAddAbility(u, fling)
                    UnitMakeAbilityPermanent(u, true, fling)
                end
                BlzUnitHideAbility(u, megaId, true)
            end)
            local ends = Timer.now() + ctx.v("duration")
            Timer.every(0.1, function()
                if mega[u] ~= s then return true end
                if not U.alive(u) or Timer.now() >= ends then
                    endMega(u)
                    return true
                end
                for _, c in ipairs(s.stack) do
                    SetUnitX(c, GetUnitX(u))
                    SetUnitY(c, GetUnitY(u))
                end
                return false
            end)
        end,
    })

    A.define(FLING, {
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            local s = mega[u]
            if not s or #s.stack == 0 or not U.alive(t) then return end
            local c = table.remove(s.stack)
            dropOff(c, GetUnitX(u), GetUnitY(u))
            Mods.add(c, "meepo_fling_flight", {duration = 5, source = u, dispel = "none",
                                               props = {stun = true, invulnerable = true}})
            local speed = math.max(100, ctx.v("fling_movespeed"))
            local dmg, radius = ctx.v("fling_damage"), ctx.v("fling_radius")
            local slow, slowFor = ctx.v("movement_slow") / 100, ctx.v("fling_slow_duration")
            Timer.onFrame(function(dt)
                if not U.alive(c) then return true end
                local step = speed * dt
                if not U.alive(t) or U.unitDist(c, t) <= step + 50 then
                    Mods.remove(c, "meepo_fling_flight")
                    local x, y = GetUnitX(c), GetUnitY(c)
                    fx("Abilities\\Spells\\Orc\\WarStomp\\WarStompCaster.mdl", x, y)
                    for _, e in ipairs(U.enemiesOf(GetOwningPlayer(u), x, y, radius)) do
                        Damage.deal(u, e, dmg, "magical")
                        if U.alive(e) and not U.isMagicImmune(e) then
                            Mods.add(e, "meepo_fling_slow", {duration = slowFor, source = u, debuff = true,
                                                             props = {move_pct = slow}})
                        end
                    end
                    return true
                end
                local a = U.angle(GetUnitX(c), GetUnitY(c), GetUnitX(t), GetUnitY(t))
                SetUnitX(c, GetUnitX(c) + step * math.cos(a))
                SetUnitY(c, GetUnitY(c) + step * math.sin(a))
                return false
            end)
            if #s.stack == 0 then
                Timer.after(0, function() endMega(u) end)     -- not inside Fling's own cast event
            else
                megaStats(s)
            end
        end,
    })

    function M.mega(u) return mega[u] end

    Events.on("death", function(dying)
        if mega[dying] then endMega(dying) end
    end)

    -- the level 25 talent shortens Poof's cast for every Meepo
    Events.on("talent", function(hero)
        local g = groups[hero]
        if not g then return end
        for _, u in ipairs(members(g)) do syncPoof(u) end
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
        if abil == A.id(POOF) then
            for _, u in ipairs(members(g)) do syncPoof(u) end
        end
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
    Bots.hint(DIG, {target = "none", radius = 700, hpBelow = 0.3})
    Bots.hint(MEGA, {target = "none", radius = 600, check = function(u) return #riders(u, 600) > 0 end})
    Bots.hint(FLING, {target = "enemyHero", range = 900})

    -- exposed for tests and other modules
    M.groupOf, M.members, M.spawnClone, M.syncAll, M.geomancyAll = groupOf, members, spawnClone, syncAll, geomancyAll
    M.isClone = function(u) return cloneOf[u] ~= nil end
    return M
end)
