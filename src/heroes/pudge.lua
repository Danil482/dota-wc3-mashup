-- Pudge (npc_dota_hero_pudge): Meat Hook, Rot, Meat Shield (pudge_flesh_heap),
-- Flesh Heap (innate pudge_innate_graft_flesh) and Dismember, using the Dota 2
-- values from data.heroes. WC3 objects: specs/heroes/pudge.json.
define("hero_pudge", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Bots = use("bots")
    local M = {units = {}}

    local HOOK, ROT, SHIELD = "pudge_meat_hook", "pudge_rot", "pudge_flesh_heap"
    local HEAP, DISMEMBER = "pudge_innate_graft_flesh", "pudge_dismember"

    local FX = {
        hook = "abilities\\weapons\\WyvernSpear\\WyvernSpearMissile.mdl",
        hookHit = "Objects\\Spawnmodels\\Orc\\OrcSmallDeathExplode\\OrcSmallDeathExplode.mdl",
        rot = "Abilities\\Spells\\Undead\\PlagueCloud\\PlagueCloudCaster.mdl",
        shield = "Abilities\\Spells\\NightElf\\Barkskin\\BarkSkinTarget.mdl",
        heap = "Abilities\\Spells\\Items\\AIsm\\AIsmTarget.mdl",
        devour = "Abilities\\Spells\\Orc\\Devour\\DevourEffectArt.mdl",
        feed = "Abilities\\Spells\\Undead\\VampiricAura\\VampiricAuraTarget.mdl",
    }
    local CHAIN = "LEAS"          -- Aerial Shackles lightning, reads as a chain
    local LOCUST = FourCC("Aloc")

    local loc = Location(0, 0)
    local function groundZ(x, y)
        MoveLocation(loc, x, y)
        return GetLocationZ(loc)
    end

    local function level(u, name)
        local id = A.id(name)
        return id and GetUnitAbilityLevel(u, id) or 0
    end

    local function reveal(owner, x, y, radius, duration)
        if radius <= 0 then return end
        local fm = CreateFogModifierRadius(owner, FOG_OF_WAR_VISIBLE, x, y, radius, true, false)
        FogModifierStart(fm)
        Timer.after(duration, function()
            FogModifierStop(fm)
            DestroyFogModifier(fm)
        end)
    end

    function M.register(u)
        if u and not M.units[u] then M.units[u] = true end
    end

    -- Meat Hook ---------------------------------------------------------------
    -- The hook always flies its full cast range toward the target point, snags
    -- the first unit (ally or enemy, not buildings) and reels it back.
    local function hookable(t, caster)
        return t ~= caster and U.alive(t)
            and not IsUnitType(t, UNIT_TYPE_STRUCTURE)
            and not IsUnitType(t, UNIT_TYPE_ANCIENT)
            and not BlzIsUnitInvulnerable(t)
            and not IsUnitHidden(t)
            and GetUnitAbilityLevel(t, LOCUST) == 0
            and not Mods.has(t, "pudge_meat_hook")
    end

    -- SIMPLIFIED: "non-ancient creep" in WC3 terms is any non-hero that is not
    -- an ancient and has no resistant skin (closest match to Dota's ancients).
    local function slainByHook(t)
        return not IsUnitType(t, UNIT_TYPE_HERO)
            and not IsUnitType(t, UNIT_TYPE_ANCIENT)
            and not IsUnitType(t, UNIT_TYPE_RESISTANT)
    end

    local function findVictim(h)
        local best, bestD = nil, math.huge
        for _, t in ipairs(U.enum(h.x, h.y, h.width + 64, nil)) do
            if hookable(t, h.caster) then
                local d = U.dist(h.x, h.y, GetUnitX(t), GetUnitY(t))
                if d <= h.width + BlzGetUnitCollisionSize(t) and d < bestD then
                    best, bestD = t, d
                end
            end
        end
        return best
    end

    local function release(h)
        local t = h.victim
        h.victim = nil
        if t then
            Mods.remove(t, "pudge_meat_hook")
            if U.alive(t) then SetUnitPosition(t, GetUnitX(t), GetUnitY(t)) end
        end
    end

    local function latch(h, t)
        local u = h.caster
        local tx, ty = GetUnitX(t), GetUnitY(t)
        DestroyEffect(AddSpecialEffect(FX.hookHit, tx, ty))
        reveal(h.owner, tx, ty, h.vision, h.visionTime)
        local enemy = IsUnitEnemy(t, h.owner)
        if enemy then
            if slainByHook(t) then
                -- exactly lethal, so spell lifesteal does not see a huge hit;
                -- a second blow covers damage blocks on the target
                Damage.deal(u, t, GetWidgetLife(t) + 1, Damage.PURE, {noAmp = true, pierce = true})
                if U.alive(t) then Damage.deal(u, t, 1000000, Damage.PURE, {noAmp = true, pierce = true}) end
            else
                Damage.deal(u, t, h.damage, Damage.PURE, {pierce = true})
            end
        end
        if U.alive(t) then
            h.victim = t
            -- dragged units are disabled; the duration is only a safety net
            Mods.add(t, "pudge_meat_hook", {duration = 2 * h.range / h.speed + 1, source = u,
                                            props = {stun = true}, debuff = enemy, dispel = "none"})
        end
    end

    local function finishHook(h)
        release(h)
        DestroyEffect(h.fx)
        DestroyLightning(h.chain)
    end

    local function stepHook(h, dt)
        local u = h.caster
        local step = h.speed * dt
        if h.out then
            h.travel = h.travel + step
            h.x, h.y = U.polar(h.x0, h.y0, math.min(h.travel, h.range), h.angle)
            local victim = findVictim(h)
            if victim then
                latch(h, victim)
                h.out = false
            elseif h.travel >= h.range then
                h.out = false
            end
            h.frames = h.frames + 1
            -- SIMPLIFIED: flight vision as short fog reveals every 4 frames
            if h.frames % 4 == 0 then reveal(h.owner, h.x, h.y, h.vision, 0.3) end
        else
            local cx, cy = GetUnitX(u), GetUnitY(u)
            if not U.alive(u) or U.dist(h.x, h.y, cx, cy) <= step + 100 then
                finishHook(h)
                return true
            end
            h.x, h.y = U.polar(h.x, h.y, step, U.angle(h.x, h.y, cx, cy))
            if h.victim then
                if U.alive(h.victim) then
                    SetUnitX(h.victim, h.x)
                    SetUnitY(h.victim, h.y)
                else
                    release(h)
                end
            end
        end
        local z = groundZ(h.x, h.y) + 70
        local ux, uy = GetUnitX(u), GetUnitY(u)
        BlzSetSpecialEffectPosition(h.fx, h.x, h.y, z)
        MoveLightningEx(h.chain, true, ux, uy, groundZ(ux, uy) + 70, h.x, h.y, z)
        return false
    end

    A.define(HOOK, {
        onCast = function(ctx)
            local u = ctx.caster
            M.register(u)
            local x0, y0 = GetUnitX(u), GetUnitY(u)
            local tx, ty = ctx.x or x0, ctx.y or y0
            if ctx.target then tx, ty = GetUnitX(ctx.target), GetUnitY(ctx.target) end
            local angle = math.rad(GetUnitFacing(u))
            if U.dist(x0, y0, tx, ty) > 1 then angle = U.angle(x0, y0, tx, ty) end
            local range = ctx.v("AbilityCastRange")
            if range <= 0 then range = 1300 end
            local speed = math.max(100, ctx.v("hook_speed"))
            -- Pudge stays locked in the throw for a share of the outbound flight
            local lock = range / speed * ctx.v("self_stun_duration_percent") / 100
            if lock > 0 then
                Mods.add(u, "pudge_hook_followthrough", {duration = lock, source = u, props = {stun = true}, dispel = "none"})
            end
            local h = {caster = u, owner = ctx.owner, x0 = x0, y0 = y0, x = x0, y = y0, angle = angle,
                       range = range, speed = speed, width = ctx.v("hook_width"), damage = ctx.v("damage"),
                       vision = ctx.v("vision_radius"), visionTime = ctx.v("vision_duration"),
                       travel = 0, frames = 0, out = true}
            local z = groundZ(x0, y0) + 70
            h.fx = AddSpecialEffect(FX.hook, x0, y0)
            BlzSetSpecialEffectYaw(h.fx, angle)
            BlzSetSpecialEffectPosition(h.fx, x0, y0, z)
            h.chain = AddLightningEx(CHAIN, true, x0, y0, z, x0, y0, z)
            Timer.onFrame(function(dt) return stepHook(h, dt) end)
        end,
    })

    -- Rot ---------------------------------------------------------------------
    local rot = {}          -- unit -> {fx, timer}

    local function stopRot(u)
        local s = rot[u]
        if not s then return end
        rot[u] = nil
        DestroyEffect(s.fx)
        s.timer:stop()
    end

    local function botOwned(u)
        return use("roles").isBot(GetPlayerId(GetOwningPlayer(u)))
    end

    local function rotTick(u, tick)
        local lvl = level(u, ROT)
        if not U.alive(u) or lvl <= 0 then
            stopRot(u)
            return
        end
        local dmg = A.value(ROT, "rot_damage", lvl) * tick
        local slow = A.value(ROT, "rot_slow", lvl) / 100
        local radius = A.value(ROT, "rot_radius", lvl)
        local x, y = GetUnitX(u), GetUnitY(u)
        -- The bot driver only switches toggles on; a bot Pudge turns Rot off
        -- after a second without enemies close by.
        local s = rot[u]
        if botOwned(u) then
            if #U.enemiesOf(GetOwningPlayer(u), x, y, radius + 150) == 0 then
                s.idle = (s.idle or 0) + tick
                if s.idle >= 1 then
                    IssueImmediateOrder(u, "unimmolation")
                    stopRot(u)
                    return
                end
            else
                s.idle = 0
            end
        end
        for _, e in ipairs(U.enemiesOf(GetOwningPlayer(u), x, y, radius)) do
            if not U.isMagicImmune(e) then
                Damage.deal(u, e, dmg, Damage.MAGICAL)
                local m = Mods.get(e, "pudge_rot")
                if m and m.props.move_pct == slow then
                    m.expires = Timer.now() + 0.3          -- refresh without rebuilding
                else
                    Mods.add(e, "pudge_rot", {duration = 0.3, source = u, props = {move_pct = slow}, debuff = true})
                end
            end
        end
        -- self damage: magical, never lethal
        Damage.deal(u, u, dmg, Damage.MAGICAL, {nonLethal = true})
    end

    local function startRot(u)
        if rot[u] then return end
        local tick = A.value(ROT, "rot_tick", level(u, ROT))
        if tick <= 0 then tick = 0.2 end
        local s = {fx = AddSpecialEffectTarget(FX.rot, u, "origin")}
        rot[u] = s
        s.timer = Timer.every(tick, function()
            if rot[u] ~= s then return true end
            rotTick(u, tick)
            return rot[u] ~= s
        end)
    end

    A.define(ROT, {
        toggleOrder = "immolation",
        onToggle = function(u, on)
            M.register(u)
            if on then startRot(u) else stopRot(u) end
        end,
    })

    function M.rotOn(u) return rot[u] ~= nil end

    -- Meat Shield (pudge_flesh_heap) -------------------------------------------
    -- Instant (Berserk base). Blocks a flat amount from every damage instance.
    -- SIMPLIFIED: for basic attacks the block applies before armor (the
    -- damaging event sees raw attack damage).
    A.define(SHIELD, {
        onCast = function(ctx)
            M.register(ctx.caster)
            local m = Mods.add(ctx.caster, "pudge_meat_shield", {duration = ctx.v("duration"), source = ctx.caster,
                                                                 effect = FX.shield, attach = "chest", dispel = "none"})
            if m then m.block = ctx.v("damage_block") end
        end,
    })

    Damage.onDamaging(function(source, target, info)
        if info.spell and info.spell.opts and info.spell.opts.nonLethal then
            info.amount = math.min(info.amount, math.max(0, GetWidgetLife(target) - 1))
        end
        local m = target and Mods.get(target, "pudge_meat_shield")
        if m and m.block and info.amount > 0 then
            info.amount = math.max(0, info.amount - m.block)
        end
    end)

    -- Flesh Heap (innate) -------------------------------------------------------
    local stacks = {}         -- unit -> stacks

    local function applyHeap(u)
        local n = stacks[u] or 0
        if n <= 0 then return end
        Mods.add(u, "pudge_graft_flesh", {source = u, persist = true, dispel = "none",
                                         props = {str = n * A.value(HEAP, "flesh_heap_strength_buff_amount", 1)}})
    end

    function M.stacks(u) return stacks[u] or 0 end

    Events.on("death", function(dying, killer)
        if not IsUnitType(dying, UNIT_TYPE_HERO) or IsUnitIllusion(dying) then return end
        local range = A.value(HEAP, "flesh_heap_range", 1)
        for u in pairs(M.units) do
            if level(u, HEAP) > 0 and IsUnitEnemy(dying, GetOwningPlayer(u))
                and (killer == u or (U.alive(u) and U.unitDist(u, dying) <= range)) then
                stacks[u] = (stacks[u] or 0) + 1
                applyHeap(u)
                if U.alive(u) then DestroyEffect(AddSpecialEffectTarget(FX.heap, u, "origin")) end
            end
        end
    end)

    Events.on("hero_respawned", function(u)
        if M.units[u] and not Mods.has(u, "pudge_graft_flesh") then applyHeap(u) end
    end)

    -- Dismember -------------------------------------------------------------------
    local dismember = {}      -- caster -> channel state

    local function endDismember(u, stopChannel)
        local s = dismember[u]
        if not s then return end
        dismember[u] = nil
        s.done = true
        s.timer:stop()
        Mods.remove(s.target, "pudge_dismember")
        if stopChannel and U.alive(u) then IssueImmediateOrder(u, "stop") end
    end

    A.define(DISMEMBER, {
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            M.register(u)
            if not t or not U.alive(t) then return end
            endDismember(u, false)
            local channel = ctx.v("AbilityChannelTime")
            if channel <= 0 then channel = 2.75 end
            local ticks = math.max(1, ctx.v("ticks"))
            -- damage per second over the whole channel, paid out in `ticks`
            -- instances that all land before the channel ends
            local share = channel / ticks
            local interval = (channel - 0.1) / ticks
            local lvl = ctx.level
            local s = {target = t, n = 0}
            s.timer = Timer.every(interval, function()
                if s.done then return true end
                if not U.alive(t) or not U.alive(u) then
                    endDismember(u, true)
                    return true
                end
                local dps = A.value(DISMEMBER, "dismember_damage", lvl)
                    + A.value(DISMEMBER, "strength_damage", lvl) * GetHeroStr(u, true)
                local dealt = Damage.deal(u, t, dps * share, Damage.MAGICAL, {pierce = true})
                Damage.heal(u, dealt)
                DestroyEffect(AddSpecialEffectTarget(FX.feed, u, "origin"))
                s.n = s.n + 1
                return s.n >= ticks
            end)
            dismember[u] = s
            Mods.add(t, "pudge_dismember", {duration = channel + 0.25, source = u, props = {stun = true}, debuff = true,
                                            dispel = "strong", effect = FX.devour, attach = "chest"})
            -- reel the victim in until it is right in front of Pudge
            local pull = A.value(DISMEMBER, "pull_units_per_second", lvl)
            local limit = A.value(DISMEMBER, "pull_distance_limit", lvl)
            Timer.onFrame(function(dt)
                if s.done or not U.alive(t) or not U.alive(u) then return true end
                local d = U.unitDist(u, t)
                if d > limit then
                    local a = U.angle(GetUnitX(t), GetUnitY(t), GetUnitX(u), GetUnitY(u))
                    local x, y = U.polar(GetUnitX(t), GetUnitY(t), math.min(pull * dt, d - limit), a)
                    SetUnitX(t, x)
                    SetUnitY(t, y)
                end
                return false
            end)
        end,
        onEndCast = function(ctx)
            endDismember(ctx.caster, false)
        end,
    })

    function M.dismembering(u) return dismember[u] ~= nil end

    -- Registration: spawned Pudges carry the innate; learning registers too.
    Events.on("hero_spawned", function(u, key)
        if key == "pudge" then M.register(u) end
    end)
    for u, key in pairs(use("heroes").keyOf) do
        if key == "pudge" then M.register(u) end
    end

    -- Bot hints -----------------------------------------------------------------
    Bots.hint(HOOK, {target = "enemyHero", point = true, range = 1100})
    Bots.hint(ROT, {target = "none", toggle = true, radius = 250})
    Bots.hint(SHIELD, {target = "none", radius = 500, hpBelow = 0.8})
    Bots.hint(DISMEMBER, {target = "enemyHero", ultimate = true, range = 400})

    return M
end)
