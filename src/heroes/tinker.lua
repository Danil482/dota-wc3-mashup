-- Tinker (npc_dota_hero_tinker): Laser, March of the Machines, Deploy Turrets,
-- Keen Conveyance (active innate), Rearm and the Eureka! innate, with the Dota 2
-- values from data.heroes. WC3 objects: specs/heroes/tinker.json.
define("hero_tinker", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Bots = use("bots")
    local M = {}

    local LASER, MARCH, TURRETS = "tinker_laser", "tinker_march_of_the_machines", "tinker_deploy_turrets"
    local KEEN, REARM, EUREKA = "tinker_keen_teleport", "tinker_rearm", "tinker_eureka"
    local readyAt = {}        -- Tinker -> {abilId -> game time it is ready} (bot hints)

    -- Dota 2 7.36+ Rearm has affects_items = 0 (items are not refreshed). The
    -- mashup design asks for item refresh, so it is on; false = patch parity.
    local REARM_ITEMS = true

    local FX = {
        beam = "AFOD",                                                      -- red lightning
        laserHit = "Abilities\\Weapons\\FireBallMissile\\FireBallMissile.mdl",
        blind = "Abilities\\Spells\\Undead\\Curse\\CurseTarget.mdl",
        boom = "Abilities\\Weapons\\Mortar\\MortarMissile.mdl",
        crate = "Abilities\\Spells\\Other\\TinkerRocket\\TinkerRocketMissile.mdl",
        impact = "Abilities\\Spells\\Human\\Thunderclap\\ThunderClapCaster.mdl",
        rocket = "Abilities\\Spells\\Other\\TinkerRocket\\TinkerRocketMissile.mdl",
        rocketHit = "Abilities\\Weapons\\RocketMissile\\RocketMissile.mdl",
        tpCaster = "Abilities\\Spells\\Human\\MassTeleport\\MassTeleportCaster.mdl",
        tpTo = "Abilities\\Spells\\Human\\MassTeleport\\MassTeleportTo.mdl",
        tpDone = "Abilities\\Spells\\Human\\MassTeleport\\MassTeleportTarget.mdl",
        rearm = "Abilities\\Spells\\Items\\AIlm\\AIlmTarget.mdl",
        rearmDone = "Abilities\\Spells\\Items\\TomeOfRetraining\\TomeOfRetrainingCaster.mdl",
    }
    -- March robots: Dota's model when the launcher converted it (specs/models.json
    -- via data.ids), else WC3's clockwork goblin.
    local ROBOT = (use("data.ids").models or {}).tinker_robot
        or {model = "Units\\Creeps\\HeroTinkerRobot\\HeroTinkerRobot.mdl", scale = 0.55}
    local TIMED_LIFE = FourCC("BTLF")

    local loc = Location(0, 0)
    local function groundZ(x, y)
        MoveLocation(loc, x, y)
        return GetLocationZ(loc)
    end

    local function level(u, name)
        return A.level(u, name)
    end

    -- Pushes u away from (fx, fy) over `duration` without interrupting orders;
    -- stops at unwalkable ground.
    local function knockback(u, fx, fy, distance, duration)
        if distance <= 0 or not U.alive(u) then return end
        local ux, uy = GetUnitX(u), GetUnitY(u)
        local a = U.dist(fx, fy, ux, uy) > 1 and U.angle(fx, fy, ux, uy) or GetUnitFacing(u) * math.pi / 180
        local speed = distance / math.max(0.05, duration)
        local moved = 0
        Timer.onFrame(function(dt)
            if not U.alive(u) or moved >= distance then return true end
            local step = math.min(speed * dt, distance - moved)
            local nx, ny = U.polar(GetUnitX(u), GetUnitY(u), step, a)
            if IsTerrainPathable(nx, ny, PATHING_TYPE_WALKABILITY) and not IsUnitType(u, UNIT_TYPE_FLYING) then
                return true
            end
            SetUnitX(u, nx)
            SetUnitY(u, ny)
            moved = moved + step
            return moved >= distance
        end)
    end

    local function missText(u)
        local tag = CreateTextTag()
        SetTextTagText(tag, "miss", 0.023)
        SetTextTagPosUnit(tag, u, 20)
        SetTextTagColor(tag, 255, 80, 80, 255)
        SetTextTagVelocity(tag, 0, 0.04)
        SetTextTagPermanent(tag, false)
        SetTextTagLifespan(tag, 1.5)
        SetTextTagFadepoint(tag, 1.0)
    end

    -- Laser -------------------------------------------------------------------
    -- Pure damage plus a blind: the target's basic attacks miss.
    local function beam(u, t, seconds)
        local l = AddLightningEx(FX.beam, true, GetUnitX(u), GetUnitY(u), BlzGetUnitZ(u) + 70,
                                 GetUnitX(t), GetUnitY(t), BlzGetUnitZ(t) + 50)
        Timer.after(seconds, function() DestroyLightning(l) end)
    end

    A.define(LASER, {
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            if not U.alive(t) then return end
            beam(u, t, 0.3)
            DestroyEffect(AddSpecialEffectTarget(FX.laserHit, t, "chest"))
            if U.isMagicImmune(t) then return end
            Damage.deal(u, t, ctx.v("laser_damage"), Damage.PURE)
            Mods.add(t, "tinker_laser_blind", {
                duration = ctx.v("duration"), source = u, debuff = true,
                props = {tinker_blind = ctx.v("miss_rate") / 100},
                effect = FX.blind, attach = "overhead",
            })
        end,
    })

    -- SIMPLIFIED: a blinded attack deals 0 damage instead of a true WC3 miss, so
    -- native on-hit procs of WC3 heroes (Bash, Critical Strike) can still fire.
    Damage.onDamaging(function(source, target, info)
        if not info.attack or not source or info.amount <= 0 then return end
        local miss = Mods.max(source, "tinker_blind")
        if miss > 0 and GetRandomReal(0, 1) < miss then
            info.amount = 0
            missText(source)
        end
    end)

    -- March of the Machines ---------------------------------------------------
    -- Robots spawn on a line `radius` behind Tinker (perpendicular to the cast
    -- direction) and walk `distance` forward, sweeping a square centred on him.
    local function march(u, owner, cx, cy, ang, p)
        local dirX, dirY = math.cos(ang), math.sin(ang)
        local perpX, perpY = -dirY, dirX
        local total = math.floor(p.rate * p.duration + 0.5)
        local life = p.distance / p.speed
        local reach = p.radius * 1.5 + p.splash
        local robots, spawned, acc = {}, 0, 0

        local function removeAt(i, explode)
            local r = robots[i]
            if explode then
                DestroyEffect(AddSpecialEffect(FX.boom, r.x, r.y))
            else
                BlzSetSpecialEffectAlpha(r.fx, 0)
            end
            DestroyEffect(r.fx)
            robots[i] = robots[#robots]
            robots[#robots] = nil
        end

        Timer.onFrame(function(dt)
            if spawned < total then
                acc = acc + p.rate * dt
                while acc >= 1 and spawned < total do
                    acc = acc - 1
                    spawned = spawned + 1
                    local off = GetRandomReal(-p.radius, p.radius)
                    local x = cx - dirX * p.radius + perpX * off
                    local y = cy - dirY * p.radius + perpY * off
                    local fx = AddSpecialEffect(ROBOT.model, x, y)
                    BlzSetSpecialEffectScale(fx, ROBOT.scale)
                    BlzSetSpecialEffectYaw(fx, ang)
                    BlzPlaySpecialEffect(fx, ANIM_TYPE_WALK)
                    robots[#robots + 1] = {fx = fx, x = x, y = y, t = 0}
                end
            end
            local enemies = nil
            local i = 1
            while i <= #robots do
                local r = robots[i]
                r.t = r.t + dt
                r.x, r.y = r.x + dirX * p.speed * dt, r.y + dirY * p.speed * dt
                BlzSetSpecialEffectPosition(r.fx, r.x, r.y, groundZ(r.x, r.y))
                enemies = enemies or U.enemiesOf(owner, cx, cy, reach)
                local hit = false
                for _, e in ipairs(enemies) do
                    if U.alive(e) and U.dist(r.x, r.y, GetUnitX(e), GetUnitY(e))
                            <= p.collision + BlzGetUnitCollisionSize(e) then
                        hit = true
                        break
                    end
                end
                if hit then
                    for _, e in ipairs(enemies) do
                        if U.alive(e) and U.dist(r.x, r.y, GetUnitX(e), GetUnitY(e)) <= p.splash then
                            Damage.deal(u, e, p.damage, Damage.MAGICAL)
                        end
                    end
                    removeAt(i, true)
                elseif r.t >= life then
                    removeAt(i, false)
                else
                    i = i + 1
                end
            end
            return spawned >= total and #robots == 0
        end)
    end

    A.define(MARCH, {
        onCast = function(ctx)
            local u = ctx.caster
            local cx, cy = GetUnitX(u), GetUnitY(u)
            local ang = U.dist(cx, cy, ctx.x, ctx.y) > 1 and U.angle(cx, cy, ctx.x, ctx.y)
                or GetUnitFacing(u) * math.pi / 180
            march(u, ctx.owner, cx, cy, ang, {
                radius = ctx.v("radius"), collision = ctx.v("collision_radius"),
                splash = ctx.v("splash_radius"), duration = ctx.v("duration"),
                speed = math.max(1, ctx.v("speed")), rate = ctx.v("machines_per_sec"),
                distance = ctx.v("distance"), damage = ctx.v("damage"),
            })
        end,
    })

    -- Deploy Turrets ----------------------------------------------------------
    -- A crate falls for drop_delay seconds, knocks enemies (and Tinker) away
    -- from the impact and leaves turrets that shoot straight rockets.
    local function nearestTarget(owner, x, y, range)
        local heroes, others = {}, {}
        for _, e in ipairs(U.enemiesOf(owner, x, y, range)) do
            if U.isHero(e) then heroes[#heroes + 1] = e else others[#others + 1] = e end
        end
        if #heroes > 0 then return (U.nearest(heroes, x, y)) end
        -- SIMPLIFIED: Dota turrets aim at enemy heroes; with none in range they
        -- shoot at the nearest other enemy so they matter against creep waves.
        return (U.nearest(others, x, y))
    end

    local function rocket(u, owner, x, y, ang, p)
        local fx = AddSpecialEffect(FX.rocket, x, y)
        BlzSetSpecialEffectYaw(fx, ang)
        local dx, dy = math.cos(ang), math.sin(ang)
        local travelled = 0
        Timer.onFrame(function(dt)
            local step = p.missileSpeed * dt
            x, y = x + dx * step, y + dy * step
            travelled = travelled + step
            BlzSetSpecialEffectPosition(fx, x, y, groundZ(x, y) + 60)
            local victim = nil
            for _, e in ipairs(U.enemiesOf(owner, x, y, p.width / 2 + 64)) do
                if U.dist(x, y, GetUnitX(e), GetUnitY(e)) <= p.width / 2 + BlzGetUnitCollisionSize(e) then
                    victim = e
                    break
                end
            end
            if victim then
                DestroyEffect(fx)
                DestroyEffect(AddSpecialEffect(FX.rocketHit, x, y))
                Damage.deal(u, victim, p.missileDamage, Damage.MAGICAL)
                for _, e in ipairs(U.enemiesOf(owner, x, y, p.splashRadius)) do
                    if e ~= victim then
                        Damage.deal(u, e, p.missileDamage * p.splashPct, Damage.MAGICAL)
                    end
                end
                return true
            end
            if travelled >= p.missileRange then
                DestroyEffect(fx)
                return true
            end
            return false
        end)
    end

    local function spawnTurret(u, owner, x, y, p)
        local code = use("data.ids").units.tinker_turret
        if not code then return nil end
        local t = CreateUnit(owner, FourCC(code), x, y, GetRandomReal(0, 360))
        BlzSetUnitMaxHP(t, math.max(1, math.floor(p.hp + 0.5)))
        SetWidgetLife(t, p.hp)
        UnitApplyTimedLife(t, TIMED_LIFE, p.turretDuration)
        local function fire()
            if not U.alive(t) then return true end
            local tx, ty = GetUnitX(t), GetUnitY(t)
            local target = nearestTarget(owner, tx, ty, p.targetRange)
            if target then
                local a = U.angle(tx, ty, GetUnitX(target), GetUnitY(target))
                SetUnitFacing(t, a * 180 / math.pi)
                rocket(u, owner, tx, ty, a, p)
            end
            return false
        end
        Timer.after(p.activation, function()
            if fire() then return end
            Timer.every(p.interval, fire)
        end)
        return t
    end

    A.define(TURRETS, {
        onCast = function(ctx)
            local u, owner, x, y = ctx.caster, ctx.owner, ctx.x, ctx.y
            local p = {
                radius = ctx.v("drop_aoe_radius"), place = ctx.v("turret_placement_radius"),
                delay = ctx.v("drop_delay"), dropDamage = ctx.v("drop_damage"),
                kb = ctx.v("drop_knockback_distance"), kbTime = ctx.v("drop_knockback_duration"),
                kbSelf = ctx.v("drop_knockback_distance_tinker"),
                kbSelfTime = ctx.v("drop_knockback_duration_tinker"),
                count = math.max(1, ctx.v("turrets_per_drop") + ctx.v("extra_turrets_per_drop")),
                hp = ctx.v("turret_hp"), turretDuration = ctx.v("turret_duration"),
                interval = math.max(0.1, ctx.v("missile_spawn_interval")),
                activation = ctx.v("activation_time"),
                missileDamage = ctx.v("missile_damage"), missileSpeed = math.max(1, ctx.v("missile_speed")),
                targetRange = ctx.v("missile_target_range"), missileRange = ctx.v("missile_range"),
                width = ctx.v("missile_width"), splashRadius = ctx.v("radius_explosion"),
                splashPct = ctx.v("splash_pct") / 100,
            }
            local crate = AddSpecialEffect(FX.crate, x, y)
            BlzSetSpecialEffectPitch(crate, math.pi / 2)
            local elapsed = 0
            Timer.onFrame(function(dt)
                elapsed = elapsed + dt
                local h = 700 * math.max(0, 1 - elapsed / math.max(0.05, p.delay))
                BlzSetSpecialEffectPosition(crate, x, y, groundZ(x, y) + h)
                if elapsed < p.delay then return false end
                DestroyEffect(crate)
                DestroyEffect(AddSpecialEffect(FX.impact, x, y))
                DestroyEffect(AddSpecialEffect(FX.boom, x, y))
                for _, e in ipairs(U.enemiesOf(owner, x, y, p.radius)) do
                    Damage.deal(u, e, p.dropDamage, Damage.MAGICAL)
                    if U.alive(e) and not U.isMagicImmune(e) then
                        Mods.add(e, "tinker_turret_knockback", {
                            duration = p.kbTime, source = u, debuff = true, props = {stun = true},
                        })
                        knockback(e, x, y, p.kb, p.kbTime)
                    end
                end
                if U.alive(u) and U.dist(GetUnitX(u), GetUnitY(u), x, y) <= p.radius then
                    knockback(u, x, y, p.kbSelf, p.kbSelfTime)
                end
                local base = GetRandomReal(0, 2 * math.pi)
                for i = 1, p.count do
                    local tx, ty = U.polar(x, y, p.place, base + (i - 1) * 2 * math.pi / p.count)
                    spawnTurret(u, owner, tx, ty, p)
                end
                return true
            end)
        end,
    })

    -- Keen Conveyance ---------------------------------------------------------
    -- Destination: the friendly structure (level 2: or allied unit, level 3: or
    -- allied hero) nearest to the clicked point; Tinker lands at the clicked
    -- point clamped to [minimun_distance, maximum_distance] from it.
    local channels = {}       -- caster -> keen teleport channel state

    local function keenTarget(u, owner, x, y, lvl)
        local creepLvl = A.value(KEEN, "creep_teleport_level", lvl)
        local heroLvl = A.value(KEEN, "hero_teleport_level", lvl)
        local best, bestD = nil, math.huge
        for _, a in ipairs(U.alliesOf(owner, x, y, 40000)) do
            if a ~= u and not IsUnitIllusion(a) then
                local ok
                if U.isStructure(a) then
                    ok = true
                elseif U.isHero(a) then
                    ok = lvl >= heroLvl
                else
                    ok = lvl >= creepLvl
                end
                if ok then
                    local d = U.dist(x, y, GetUnitX(a), GetUnitY(a))
                    if d < bestD then best, bestD = a, d end
                end
            end
        end
        return best
    end

    local function cancelCast(u, msg)
        PauseUnit(u, true)
        IssueImmediateOrder(u, "stop")
        PauseUnit(u, false)
        if msg then
            DisplayTimedTextToPlayer(GetOwningPlayer(u), 0, 0, 2, "|cffffcc00" .. msg .. "|r")
        end
    end

    local function keenSpot(s)
        local tx, ty = GetUnitX(s.target), GetUnitY(s.target)
        return U.polar(tx, ty, s.offset, s.angle)
    end

    A.define(KEEN, {
        onChannel = function(ctx)
            if Mods.flag(ctx.caster, "root") then
                cancelCast(ctx.caster, "Can't teleport while rooted")
            elseif not keenTarget(ctx.caster, ctx.owner, ctx.x, ctx.y, ctx.level) then
                cancelCast(ctx.caster, "No friendly destination")
            end
        end,
        onCast = function(ctx)
            local u = ctx.caster
            local target = keenTarget(u, ctx.owner, ctx.x, ctx.y, ctx.level)
            if not target then return end
            local tx, ty = GetUnitX(target), GetUnitY(target)
            local d = U.dist(tx, ty, ctx.x, ctx.y)
            local s = {
                target = target, started = Timer.now(), channel = ctx.v("AbilityChannelTime"),
                angle = d > 1 and U.angle(tx, ty, ctx.x, ctx.y) or GetRandomReal(0, 2 * math.pi),
                offset = U.clamp(d, ctx.v("minimun_distance"), ctx.v("maximum_distance")),
            }
            local x, y = keenSpot(s)
            s.fxCaster = AddSpecialEffectTarget(FX.tpCaster, u, "origin")
            s.fxTo = AddSpecialEffect(FX.tpTo, x, y)
            s.vision = CreateFogModifierRadius(ctx.owner, FOG_OF_WAR_VISIBLE, x, y, ctx.v("vision_radius"), true, false)
            FogModifierStart(s.vision)
            channels[u] = s
        end,
        onEndCast = function(ctx)
            local u = ctx.caster
            local s = channels[u]
            if not s then return end
            channels[u] = nil
            DestroyEffect(s.fxCaster)
            DestroyEffect(s.fxTo)
            FogModifierStop(s.vision)
            DestroyFogModifier(s.vision)
            if Timer.now() - s.started < s.channel - 0.1 or not U.alive(u) then return end
            if not U.alive(s.target) then return end
            local x, y = keenSpot(s)
            DestroyEffect(AddSpecialEffect(FX.tpDone, GetUnitX(u), GetUnitY(u)))
            SetUnitPosition(u, x, y)
            DestroyEffect(AddSpecialEffect(FX.tpDone, GetUnitX(u), GetUnitY(u)))
        end,
    })

    -- Rearm -------------------------------------------------------------------
    local rearming = {}       -- caster -> {started, channel, fx}

    local function itemAbilities(item)
        local list = {}
        for i = 0, 7 do
            local ab = BlzGetItemAbilityByIndex(item, i)
            if not ab then break end
            local id = BlzGetAbilityId(ab)
            if id ~= 0 then list[#list + 1] = id end
        end
        local group = BlzGetItemIntegerField(item, ITEM_IF_COOLDOWN_GROUP)
        if group and group ~= 0 then list[#list + 1] = group end
        return list
    end

    -- castId: the ability Rearm was cast from when it is not Tinker's own
    -- object (a stolen copy in one of Rubick's slots); it keeps its cooldown.
    function M.refresh(u, castId)
        local rearmId = A.id(REARM)
        for i = 0, 99 do
            local ab = BlzGetUnitAbilityByIndex(u, i)
            if not ab then break end
            local id = BlzGetAbilityId(ab)
            if id ~= 0 and id ~= rearmId and id ~= castId then BlzEndUnitAbilityCooldown(u, id) end
        end
        if readyAt[u] then readyAt[u] = {} end
        if REARM_ITEMS then
            for slot = 0, UnitInventorySize(u) - 1 do
                local item = UnitItemInSlot(u, slot)
                if item then
                    for _, id in ipairs(itemAbilities(item)) do BlzEndUnitAbilityCooldown(u, id) end
                end
            end
        end
    end

    A.define(REARM, {
        onCast = function(ctx)
            rearming[ctx.caster] = {
                started = Timer.now(), channel = ctx.v("AbilityChannelTime"), castId = ctx.castId,
                fx = AddSpecialEffectTarget(FX.rearm, ctx.caster, "origin"),
            }
        end,
        onEndCast = function(ctx)
            local u = ctx.caster
            local s = rearming[u]
            if not s then return end
            rearming[u] = nil
            DestroyEffect(s.fx)
            if Timer.now() - s.started >= s.channel - 0.1 and U.alive(u) then
                M.refresh(u, s.castId)
                DestroyEffect(AddSpecialEffectTarget(FX.rearmDone, u, "origin"))
            end
        end,
        -- Keen Conveyance is "DependentOnAbility tinker_rearm": its level is
        -- Rearm's level (at least 1, since it is usable from the start).
        onLearn = function(hero, lvl)
            local keen = A.id(KEEN)
            if keen and GetUnitAbilityLevel(hero, keen) > 0 then
                SetUnitAbilityLevel(hero, keen, math.max(1, lvl))
            end
        end,
    })

    -- Eureka! -----------------------------------------------------------------
    -- Item cooldown reduction from Intelligence, applied right after an item is
    -- used (the cooldown starts after the use event, hence the 0 s delay).
    A.define(EUREKA, {})

    function M.itemCdr(u)
        if level(u, EUREKA) <= 0 or Mods.flag(u, "break") then return 0 end
        local per = math.max(1, A.value(EUREKA, "int_per_one_cdr", 1))
        local pct = math.min(A.value(EUREKA, "max_cdr", 1), math.floor(GetHeroInt(u, true) / per))
        return math.max(0, pct) / 100
    end

    Events.on("item_use", function(u, item)
        local cdr = M.itemCdr(u)
        if cdr <= 0 or not item then return end
        local list = itemAbilities(item)
        Timer.after(0, function()
            for _, id in ipairs(list) do
                local left = BlzGetUnitAbilityCooldownRemaining(u, id)
                if left > 0 then BlzStartUnitAbilityCooldown(u, id, left * (1 - cdr)) end
            end
        end)
    end)

    -- Bots ----------------------------------------------------------------------
    -- Cooldowns of Tinker's spells, timed here as well because the native
    -- remaining-cooldown read can return 0 for Channel-based abilities.
    Events.on("spell_effect", function(caster, abil)
        local t = readyAt[caster]
        if not t then return end
        local lvl = GetUnitAbilityLevel(caster, abil)
        if lvl > 0 then t[abil] = Timer.now() + BlzGetUnitAbilityCooldown(caster, abil, lvl - 1) end
    end)

    function M.anyOnCooldown(u)
        local now = Timer.now()
        for _, name in ipairs({LASER, MARCH, TURRETS}) do
            local id = A.id(name)
            if id and GetUnitAbilityLevel(u, id) > 0 then
                local tracked = readyAt[u] and readyAt[u][id] or 0
                if math.max(BlzGetUnitAbilityCooldownRemaining(u, id), tracked - now) > 0.5 then return true end
            end
        end
        return false
    end

    -- The hero bot ignores hint.check and tries ultimates first, so the Rearm
    -- hint is only offered while one of Tinker's spells is on cooldown.
    local REARM_HINT = {target = "none", radius = 1000, minEnemies = 1, check = M.anyOnCooldown}
    local tinkers = {}
    function M.register(u)
        if not u or tinkers[u] then return end
        tinkers[u] = true
        readyAt[u] = readyAt[u] or {}
        Timer.every(0.5, function()
            if GetUnitTypeId(u) == 0 then
                tinkers[u] = nil
                return true
            end
            Bots.hint(REARM, (U.alive(u) and M.anyOnCooldown(u)) and REARM_HINT or nil)
            return false
        end)
    end
    Events.on("hero_spawned", function(u, key)
        if key == "tinker" then M.register(u) end
    end)
    for u, key in pairs(use("heroes").keyOf) do
        if key == "tinker" then M.register(u) end
    end

    Bots.hint(LASER, {target = "enemyHero"})
    Bots.hint(MARCH, {target = "point", range = 300})
    Bots.hint(TURRETS, {target = "point"})
    Bots.hint(REARM, REARM_HINT)
    Bots.hint(KEEN, {target = "point", hpBelow = 0.25, destination = "fountain"})

    M.knockback = knockback
    return M
end)
