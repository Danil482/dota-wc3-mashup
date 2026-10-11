-- Ogre Magi (npc_dota_hero_ogre_magi): Fireblast, Ignite, Bloodlust, Dumb Luck
-- (innate) and Multicast, using the Dota 2 values from data.heroes, plus
-- Unrefined Fireblast (Aghanim's Scepter) and Fire Shield (Aghanim's Shard,
-- ogre_magi_smash). Values are read with the caster, so its talents and
-- upgrades apply (src/game/talents.lua).
-- WC3 objects: specs/heroes/ogre_magi.json.
define("hero_ogre_magi", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Bots = use("bots")
    local M = {units = {}}

    local FIREBLAST, IGNITE, BLOODLUST = "ogre_magi_fireblast", "ogre_magi_ignite", "ogre_magi_bloodlust"
    local DUMB, MULTI = "ogre_magi_dumb_luck", "ogre_magi_multicast"
    local UNREFINED, SMASH = "ogre_magi_unrefined_fireblast", "ogre_magi_smash"

    -- Dota gives Ogre 120 base mana (StatusMana); generated heroes start at 75.
    local BASE_MANA_BONUS = 45
    local LUST_BUFF = FourCC("Bblo")      -- buff of the native Bloodlust base

    local Fx = use("fx")
    local FX = {
        fireblast = Fx.model("ogre_magi_fireblast", "Abilities\\Spells\\Other\\Incinerate\\FireLordDeathExplode.mdl"),
        stun = "Abilities\\Spells\\Human\\Thunderclap\\ThunderclapTarget.mdl",
        ignite = Fx.model("ogre_magi_ignite", "Abilities\\Weapons\\RedDragonBreath\\RedDragonMissile.mdl"),
        burn = "Abilities\\Spells\\Other\\BreathOfFire\\BreathOfFireDamage.mdl",
        lust = "Abilities\\Spells\\Orc\\Bloodlust\\BloodlustTarget.mdl",
        shield = "Abilities\\Spells\\Human\\ManaShield\\ManaShieldCaster.mdl",
    }

    local loc = Location(0, 0)
    local function groundZ(x, y)
        MoveLocation(loc, x, y)
        return GetLocationZ(loc)
    end

    local function level(u, name)
        return A.level(u, name)
    end

    local function botOwned(u)
        return use("roles").isBot(GetPlayerId(GetOwningPlayer(u)))
    end

    -- Multicast ---------------------------------------------------------------------
    -- Chances are "at least N casts" thresholds (75/30/15 at max level), each
    -- raised by 1 % per strength_for_one_pct Strength.
    function M.multicast(u)
        local lvl = level(u, MULTI)
        if lvl <= 0 or Mods.flag(u, "break") then return 1 end
        local per = A.value(MULTI, "strength_for_one_pct", lvl, u)
        local bonus = per > 0 and GetHeroStr(u, true) / per * A.value(MULTI, "one_tooltip", lvl, u) or 0
        local function chance(key)
            local c = A.value(MULTI, key, lvl, u)
            return c > 0 and c + bonus or 0
        end
        local roll = GetRandomReal(0, 100)
        if roll < chance("multicast_4_times") then return 4 end
        if roll < chance("multicast_3_times") then return 3 end
        if roll < chance("multicast_2_times") then return 2 end
        return 1
    end

    local function announce(u, n)
        if n < 2 then return end
        local tt = CreateTextTag()
        SetTextTagText(tt, "Multicast x" .. n, 0.028)
        SetTextTagPosUnit(tt, u, 140)
        SetTextTagColor(tt, 255, 150 - 40 * (n - 2), 40, 255)
        SetTextTagVelocity(tt, 0, 0.035)
        SetTextTagPermanent(tt, false)
        SetTextTagLifespan(tt, 1.6)
        SetTextTagFadepoint(tt, 1.0)
    end

    -- Fireblast -------------------------------------------------------------------------
    local function blast(u, t, dmg, stun)
        if not U.alive(t) then return end
        DestroyEffect(AddSpecialEffectTarget(FX.fireblast, t, "origin"))
        if U.isMagicImmune(t) then return end
        Damage.deal(u, t, dmg, Damage.MAGICAL)
        if U.alive(t) then
            Mods.add(t, "ogre_magi_fireblast", {duration = stun, source = u, props = {stun = true}, debuff = true,
                                                dispel = "strong", effect = FX.stun, attach = "overhead"})
        end
    end

    -- One blast, then Multicast's extra blasts on the same target.
    local function fireblast(u, t, dmg, stun, delay, multicast)
        blast(u, t, dmg, stun)
        local n = multicast and M.multicast(u) or 1
        announce(u, n)
        for i = 2, n do
            Timer.after((i - 1) * delay, function() blast(u, t, dmg, stun) end)
        end
    end

    A.define(FIREBLAST, {
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            M.register(u)
            if not t then return end
            fireblast(u, t, ctx.v("fireblast_damage"), ctx.v("stun_duration"), ctx.v("multicast_delay"), true)
        end,
    })

    -- Level 25 talent (fireblast_proc): that share of Ogre's attacks on enemy
    -- units casts Fireblast on the target, without mana or cooldown.
    -- Not confirmed from Dota's code: such a Fireblast does not Multicast.
    Damage.onDamaging(function(source, target, info)
        if not info.attack or not source or not target or not M.units[source] then return end
        local lvl = level(source, FIREBLAST)
        if lvl <= 0 or U.isStructure(target) or not IsUnitEnemy(target, GetOwningPlayer(source)) then return end
        local chance = A.value(FIREBLAST, "fireblast_proc", lvl, source)
        if chance <= 0 or GetRandomReal(0, 100) >= chance then return end
        -- after this damage event: Fireblast deals damage of its own
        Timer.after(0, function()
            fireblast(source, target, A.value(FIREBLAST, "fireblast_damage", lvl, source),
                      A.value(FIREBLAST, "stun_duration", lvl, source), 0, false)
        end)
    end)

    -- Unrefined Fireblast (Aghanim's Scepter, Dota 7.41): base_damage +
    -- str_multiplier x Ogre's Strength and the Fireblast stun, Multicast on
    -- the same target. It costs scepter_mana % of Ogre's current mana: the
    -- ability's mana cost follows his mana (syncUnrefined).
    A.define(UNREFINED, {
        onChannel = function(ctx) M.syncUnrefined(ctx.caster) end,
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            M.register(u)
            if not t then return end
            fireblast(u, t, ctx.v("base_damage") + ctx.v("str_multiplier") * GetHeroStr(u, true),
                      ctx.v("stun_duration"), ctx.v("multicast_delay"), true)
        end,
    })

    function M.syncUnrefined(u)
        local id = A.id(UNREFINED)
        if not id or GetUnitAbilityLevel(u, id) == 0 then return end
        local cost = math.floor(GetUnitState(u, UNIT_STATE_MANA) * A.value(UNREFINED, "scepter_mana", 1, u) / 100
                                * (1 - Mods.sum(u, "mana_reduction")) + 0.5)
        if BlzGetUnitAbilityManaCost(u, id, 0) ~= cost then BlzSetUnitAbilityManaCost(u, id, 0, cost) end
    end

    -- Ignite -------------------------------------------------------------------------------
    local function burn(u, t, lvl)
        if not U.alive(t) or U.isMagicImmune(t) then return end
        local dur = A.value(IGNITE, "duration", lvl, u)
        if Mods.has(t, "ogre_magi_ignite") then
            dur = dur + Mods.remaining(t, "ogre_magi_ignite")      -- repeat hits extend the burn
        end
        local m = Mods.add(t, "ogre_magi_ignite", {
            duration = dur, source = u, debuff = true, effect = FX.burn, attach = "chest", tick = 1.0,
            props = {move_pct = A.value(IGNITE, "slow_movement_speed_pct", lvl, u) / 100},
            onTick = function(mod)
                Damage.deal(mod.source, mod.unit, mod.burn or 0, Damage.MAGICAL)
            end,
        })
        if m then m.burn = A.value(IGNITE, "burn_damage", lvl, u) end
    end

    -- A homing missile from (x, y) to t; onHit runs when it arrives.
    local function missile(model, x, y, t, speed, onHit)
        local fx = AddSpecialEffect(model, x, y)
        Timer.onFrame(function(dt)
            if not U.alive(t) then
                DestroyEffect(fx)
                return true
            end
            local tx, ty = GetUnitX(t), GetUnitY(t)
            local step = speed * dt
            if U.dist(x, y, tx, ty) <= step + 24 then
                DestroyEffect(fx)
                onHit()
                return true
            end
            local a = U.angle(x, y, tx, ty)
            x, y = U.polar(x, y, step, a)
            BlzSetSpecialEffectPosition(fx, x, y, groundZ(x, y) + 80)
            BlzSetSpecialEffectYaw(fx, a)
            return false
        end)
    end

    local function throw(u, t, lvl, speed)
        missile(FX.ignite, GetUnitX(u), GetUnitY(u), t, speed, function() burn(u, t, lvl) end)
    end

    local function randomEnemy(u, radius, used)
        local owner = GetOwningPlayer(u)
        local pool = {}
        for _, e in ipairs(U.enemiesOf(owner, GetUnitX(u), GetUnitY(u), radius)) do
            if not used[e] and IsUnitVisible(e, owner) and not U.isMagicImmune(e) then pool[#pool + 1] = e end
        end
        if #pool == 0 then return nil end
        return pool[GetRandomInt(1, #pool)]
    end

    A.define(IGNITE, {
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            M.register(u)
            if not t then return end
            local lvl = ctx.level
            local speed = math.max(100, ctx.v("projectile_speed"))
            local aoe = ctx.v("ignite_multicast_aoe")
            local used = {}
            -- every cast drenches its target and one more random enemy
            local function cast(primary)
                used[primary] = true
                throw(u, primary, lvl, speed)
                local extra = randomEnemy(u, aoe, used)
                if extra then
                    used[extra] = true
                    throw(u, extra, lvl, speed)
                end
            end
            cast(t)
            local n = M.multicast(u)
            announce(u, n)
            for i = 2, n do
                Timer.after((i - 1) * ctx.v("multicast_delay"), function()
                    local p = randomEnemy(u, aoe, used)
                    if not p and U.alive(t) then p = t end
                    if p then cast(p) end
                end)
            end
        end,
    })

    -- Bloodlust ------------------------------------------------------------------------------
    -- Native Bloodlust base (targeting, autocast, buff icon, +25 % size); the
    -- speed bonuses are Lua modifiers.
    -- SIMPLIFIED: extra multicast targets get the modifier and a visual only
    -- (no native buff, no size increase). Multicast ignores items.
    local lusting = {}        -- unit -> true while it carries our modifier

    local function lust(ogre, t, lvl, native)
        if not U.alive(t) then return end
        local as = (t == ogre) and A.value(BLOODLUST, "self_bonus", lvl, ogre)
            or A.value(BLOODLUST, "bonus_attack_speed", lvl, ogre)
        local m = Mods.add(t, "ogre_magi_bloodlust", {
            duration = A.value(BLOODLUST, "duration", lvl, ogre), source = ogre,
            props = {attack_speed = as, move_pct = A.value(BLOODLUST, "bonus_movement_speed", lvl, ogre) / 100},
            effect = (not native) and FX.lust or nil, attach = "hand,left",
            onRemove = function(mod, expired)
                if not expired then UnitRemoveAbility(mod.unit, LUST_BUFF) end
            end,
        })
        if m then
            m.native, m.since = native, Timer.now()
            lusting[t] = true
        end
    end

    A.define(BLOODLUST, {
        onLearn = function(u)
            M.register(u)
            -- bots use the autocast
            if botOwned(u) then IssueImmediateOrder(u, "bloodluston") end
        end,
        onCast = function(ctx)
            local u = ctx.caster
            M.register(u)
            local t = ctx.target or u
            lust(u, t, ctx.level, true)
            local n = M.multicast(u)
            if n < 2 then return end
            announce(u, n)
            local pool = {}
            for _, a in ipairs(U.alliesOf(ctx.owner, GetUnitX(u), GetUnitY(u), ctx.v("multicast_bloodlust_aoe"))) do
                if a ~= t and U.alive(a) then pool[#pool + 1] = a end
            end
            for _ = 2, n do
                if #pool == 0 then break end
                local k = GetRandomInt(1, #pool)
                local a = pool[k]
                pool[k] = pool[#pool]
                pool[#pool] = nil
                lust(u, a, ctx.level, false)
            end
        end,
    })

    -- WC3 dispels remove the native buff; drop the speed bonus with it.
    local function syncLust()
        local now = Timer.now()
        for t in pairs(lusting) do
            local m = Mods.get(t, "ogre_magi_bloodlust")
            if not m then
                lusting[t] = nil
            elseif m.native and now - m.since > 0.5 and GetUnitAbilityLevel(t, LUST_BUFF) == 0 then
                lusting[t] = nil
                Mods.remove(t, "ogre_magi_bloodlust")
            end
        end
    end

    -- Fire Shield (Aghanim's Shard, Dota 7.41 ogre_magi_smash) ---------------------------
    -- The ally takes damage_absorb_pct % less from the next `attacks` attacks
    -- of enemy heroes, and each absorbed attack throws a fireball (damage,
    -- magical) back at the attacker. Multicast shields random allies within
    -- multicast_fireshield_aoe of Ogre.
    local function shield(ogre, t)
        if not U.alive(t) then return end
        local m = Mods.add(t, "ogre_magi_smash", {duration = A.value(SMASH, "duration", 1, ogre), source = ogre,
                                                  props = {}, effect = FX.shield, attach = "origin"})
        if m then m.left = A.value(SMASH, "attacks", 1, ogre) end
    end

    A.define(SMASH, {
        onCast = function(ctx)
            local u = ctx.caster
            M.register(u)
            local t = ctx.target or u
            shield(u, t)
            local n = M.multicast(u)
            if n < 2 then return end
            announce(u, n)
            local pool = {}
            for _, a in ipairs(U.alliesOf(ctx.owner, GetUnitX(u), GetUnitY(u), ctx.v("multicast_fireshield_aoe"))) do
                if a ~= t and U.alive(a) then pool[#pool + 1] = a end
            end
            for _ = 2, n do
                if #pool == 0 then break end
                local k = GetRandomInt(1, #pool)
                shield(u, pool[k])
                pool[k] = pool[#pool]
                pool[#pool] = nil
            end
        end,
    })

    Damage.onDamaging(function(source, target, info)
        if not info.attack or not source or not target then return end
        local m = Mods.get(target, "ogre_magi_smash")
        if not m or not U.isHero(source) or not IsUnitEnemy(source, GetOwningPlayer(target)) then return end
        local ogre = m.source
        info.amount = info.amount * (1 - A.value(SMASH, "damage_absorb_pct", 1, ogre) / 100)
        local dmg = A.value(SMASH, "damage", 1, ogre)
        missile(FX.ignite, GetUnitX(target), GetUnitY(target), source, A.value(SMASH, "projectile_speed", 1, ogre),
                function() Damage.deal(ogre, source, dmg, Damage.MAGICAL) end)
        m.left = (m.left or 1) - 1
        if m.left <= 0 then Mods.remove(target, "ogre_magi_smash") end
    end)

    -- Dumb Luck (innate) ------------------------------------------------------------------
    -- Max mana and mana regeneration from Strength; any Intelligence from
    -- items is cancelled so Ogre's Intelligence stays 0.
    local function dumbLuck(u)
        if level(u, DUMB) <= 0 or not U.alive(u) then return end
        local str = GetHeroStr(u, true)
        local m = Mods.get(u, "ogre_magi_dumb_luck")
        local ours = m and m.props.int or 0
        local int = -math.max(0, GetHeroInt(u, true) - ours)
        local mana = str * A.value(DUMB, "mana_per_str", 1, u) + BASE_MANA_BONUS
        local regen = str * A.value(DUMB, "mana_regen_per_str", 1, u)
        if m and m.props.max_mana == mana and m.props.mana_regen == regen and m.props.int == int then return end
        Mods.add(u, "ogre_magi_dumb_luck", {source = u, persist = true, dispel = "none",
                                            props = {max_mana = mana, mana_regen = regen, int = int}})
        if not m then
            SetUnitState(u, UNIT_STATE_MANA, BlzGetUnitMaxMana(u))      -- spawn with a full pool
        end
    end

    A.define(DUMB, {})
    A.define(MULTI, {onLearn = function(u) M.register(u) end})

    -- Registration ----------------------------------------------------------------------------
    local loop = nil
    function M.register(u)
        if not u or M.units[u] then return end
        M.units[u] = true
        dumbLuck(u)
        if not loop then
            loop = Timer.every(0.5, function()
                for unit in pairs(M.units) do dumbLuck(unit) end
                syncLust()
            end)
            Timer.every(0.1, function()
                for unit in pairs(M.units) do M.syncUnrefined(unit) end
            end)
        end
    end

    Events.on("hero_spawned", function(u, key)
        if key == "ogre_magi" then M.register(u) end
    end)
    for u, key in pairs(use("heroes").keyOf) do
        if key == "ogre_magi" then M.register(u) end
    end

    -- Bot hints ----------------------------------------------------------------------------------
    Bots.hint(FIREBLAST, {target = "enemyHero"})
    Bots.hint(IGNITE, {target = "enemyHero"})
    Bots.hint(BLOODLUST, {target = "allyHero"})
    Bots.hint(UNREFINED, {target = "enemyHero"})
    Bots.hint(SMASH, {target = "allyHero"})

    return M
end)
