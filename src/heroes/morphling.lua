-- Morphling (npc_dota_hero_morphling): Waveform, Adaptive Strike, Attribute
-- Shift (Agility / Strength Gain), Morph with Morph Replicate, and the Ebb and
-- Flow innate, with the Dota 2 values from data.heroes. Copied spells take
-- Morphling's own Aghanim's upgrades, never the target's talents. Not done:
-- the Scepter's Morph illusion and switching Attribute Shift while stunned
-- (Shard; its halved mana cost is in).
-- WC3 objects: specs/heroes/morphling.json.
--
-- Morph design: the target hero's basic (non-ultimate) hero abilities are read
-- with BlzGetUnitAbilityByIndex and copied at the target's levels, and
-- BlzSetUnitSkin gives Morphling its model; this works the same for Warcraft
-- heroes (native spells) and Dota heroes (our objects). Morphling's own basics
-- are removed while he is in the copied form (levels and cooldowns are kept),
-- and the Morph button is replaced by Morph Replicate, which swaps both ability
-- sets and models until Morph ends or he dies. Removing (not hiding) abilities
-- keeps order strings unique on the unit and stays clear of the silence code,
-- which also toggles BlzUnitDisableAbility.
define("hero_morphling", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Bots = use("bots")
    local Fx = use("fx")
    local M = {}

    local WAVE, STRIKE = "morphling_waveform", "morphling_adaptive_strike_agi"
    local AGI, STR = "morphling_morph_agi", "morphling_morph_str"
    -- Morph Replicate's object key is not the Dota name: the hero bot treats
    -- every Dota-named object as learnable.
    local MORPH, SWAP, EBB = "morphling_replicate", "morphling_morph_swap", "morphling_ebb_and_flow"
    local OWN_BASICS = {WAVE, STRIKE, AGI, STR}
    local MAX_LEVEL = {[WAVE] = 4, [STRIKE] = 4, [AGI] = 4, [STR] = 4, [MORPH] = 3}

    -- Waveform's AbilityDamage is a top-level Dota field that heroes.json does
    -- not export; these are the patch values (75 150 225 300).
    local WAVE_DAMAGE = {75, 150, 225, 300}

    -- Native spells that change the caster's unit type or hide the hero.
    local BLOCKED = {}
    for _, code in ipairs({"AEme", "ANcr", "ANrg", "ANef"}) do BLOCKED[FourCC(code)] = true end

    local FX = {
        wave = Fx.model("morphling_waveform", "Abilities\\Spells\\Other\\CrushingWave\\CrushingWaveMissile.mdl"),
        waveHit = "Abilities\\Spells\\Other\\CrushingWave\\CrushingWaveDamage.mdl",
        strike = Fx.model("morphling_adaptive_strike", "Abilities\\Weapons\\WaterElementalMissile\\WaterElementalMissile.mdl"),
        strikeHit = "Abilities\\Spells\\Other\\CrushingWave\\CrushingWaveDamage.mdl",
        stun = "Abilities\\Spells\\Human\\Thunderclap\\ThunderclapTarget.mdl",
        agi = "Abilities\\Spells\\Items\\AIam\\AIamTarget.mdl",
        str = "Abilities\\Spells\\Items\\AIsm\\AIsmTarget.mdl",
        morph = "Abilities\\Spells\\Orc\\EtherealForm\\SpiritWalkerChange.mdl",
    }

    local loc = Location(0, 0)
    local function groundZ(x, y)
        MoveLocation(loc, x, y)
        return GetLocationZ(loc)
    end

    local function id(name) return A.id(name) end
    local function level(u, name)
        return A.level(u, name)
    end

    local nameById = nil
    local function nameOf(abil)
        if not nameById then
            nameById = {}
            for name, code in pairs(use("data.ids").abilities) do nameById[FourCC(code)] = name end
        end
        return nameById[abil]
    end

    local function cancelCast(u, msg)
        PauseUnit(u, true)
        IssueImmediateOrder(u, "stop")
        PauseUnit(u, false)
        if msg then
            DisplayTimedTextToPlayer(GetOwningPlayer(u), 0, 0, 2, "|cffffcc00" .. msg .. "|r")
        end
    end

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

    -- Cooldowns: BlzGetUnitAbilityCooldownRemaining can read 0 for Channel-based
    -- abilities, so casts by Morphling are also timed here.
    local readyAt = {}        -- unit -> {abilId -> game time it is ready}
    Events.on("spell_effect", function(caster, abil)
        local t = readyAt[caster]
        if not t then return end
        local lvl = GetUnitAbilityLevel(caster, abil)
        if lvl > 0 then t[abil] = Timer.now() + BlzGetUnitAbilityCooldown(caster, abil, lvl - 1) end
    end)

    local function remaining(u, abil)
        local t = readyAt[u]
        local own = t and t[abil] and (t[abil] - Timer.now()) or 0
        return math.max(0, BlzGetUnitAbilityCooldownRemaining(u, abil), own)
    end

    -- Per-unit cast range bonus (Ebb and Flow): abilities.lua sums it with the
    -- item and talent bonuses ----------------------------------------------------------
    local function applyRange(u, abil, bonus)
        if GetUnitAbilityLevel(u, abil) > 0 and A.rangeBonus(u, abil, "ebb") ~= bonus then
            A.setRangeBonus(u, abil, "ebb", bonus)
        end
    end

    local function strBonus(u, key)
        return GetHeroStr(u, true) * A.value(EBB, key, 1) / 100
    end
    local function agiBonus(u, key)
        return GetHeroAgi(u, true) * A.value(EBB, key, 1) / 100
    end
    local function ebbActive(u) return level(u, EBB) > 0 end

    -- Waveform -------------------------------------------------------------------------
    A.define(WAVE, {
        onChannel = function(ctx)
            if Mods.flag(ctx.caster, "root") then cancelCast(ctx.caster, "Can't surge while rooted") end
        end,
        onCast = function(ctx)
            local u, owner = ctx.caster, ctx.owner
            local x0, y0 = GetUnitX(u), GetUnitY(u)
            -- The object range is large so a far click never makes him walk
            -- (Dota OVERSHOOT); the real range is applied here.
            local range = ctx.v("AbilityCastRange") + (ebbActive(u) and strBonus(u, "cast_range_per_str") or 0)
            local dist = math.min(U.dist(x0, y0, ctx.x, ctx.y), range)
            local ang = U.dist(x0, y0, ctx.x, ctx.y) > 1 and U.angle(x0, y0, ctx.x, ctx.y)
                or GetUnitFacing(u) * math.pi / 180
            local speed = math.max(1, ctx.v("speed"))
            local half = ctx.v("width") / 2
            local damage = WAVE_DAMAGE[math.max(1, math.min(#WAVE_DAMAGE, ctx.level))]
            local hit = {}
            Mods.add(u, "morphling_waveform", {
                duration = dist / speed + 0.5, source = u, dispel = "none", props = {invulnerable = true},
            })
            BlzPauseUnitEx(u, true)
            SetUnitPathing(u, false)
            SetUnitVertexColor(u, 255, 255, 255, 40)
            local fx = AddSpecialEffect(FX.wave, x0, y0)
            BlzSetSpecialEffectYaw(fx, ang)
            local moved = 0
            local function finish()
                DestroyEffect(fx)
                SetUnitVertexColor(u, 255, 255, 255, 255)
                SetUnitPathing(u, true)
                BlzPauseUnitEx(u, false)
                Mods.remove(u, "morphling_waveform")
                if U.alive(u) then SetUnitPosition(u, GetUnitX(u), GetUnitY(u)) end
            end
            Timer.onFrame(function(dt)
                if not U.alive(u) then
                    finish()
                    return true
                end
                local step = math.min(speed * dt, dist - moved)
                local nx, ny = U.polar(GetUnitX(u), GetUnitY(u), step, ang)
                SetUnitX(u, nx)
                SetUnitY(u, ny)
                moved = moved + step
                BlzSetSpecialEffectPosition(fx, nx, ny, groundZ(nx, ny))
                for _, e in ipairs(U.enemiesOf(owner, nx, ny, half + 40)) do
                    if not hit[e] and U.dist(nx, ny, GetUnitX(e), GetUnitY(e)) <= half + BlzGetUnitCollisionSize(e) then
                        hit[e] = true
                        Damage.deal(u, e, damage, Damage.MAGICAL)
                        DestroyEffect(AddSpecialEffectTarget(FX.waveHit, e, "chest"))
                    end
                end
                if moved >= dist - 0.5 then
                    finish()
                    return true
                end
                return false
            end)
        end,
    })

    -- Adaptive Strike -------------------------------------------------------------------
    -- Damage multiplier on Agility goes from damage_min (Agility <= 0.5 x Strength)
    -- to damage_max (Agility >= 1.5 x Strength); stun and knockback scale the same
    -- way with Strength over Agility.
    function M.strikeNumbers(u, v)
        local agi, str = math.max(1, GetHeroAgi(u, true)), math.max(1, GetHeroStr(u, true))
        local ta = U.clamp(agi / str - 0.5, 0, 1)
        local ts = U.clamp(str / agi - 0.5, 0, 1)
        local mult = v("damage_min") + (v("damage_max") - v("damage_min")) * ta
        return v("damage_base") + agi * mult,
            v("stun_min") + (v("stun_max") - v("stun_min")) * ts,
            v("knockback_min") + (v("knockback_max") - v("knockback_min")) * ts
    end

    A.define(STRIKE, {
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            if not U.alive(t) then return end
            local damage, stun, push = M.strikeNumbers(u, ctx.v)
            local pushTime = ctx.v("knockback_duration")
            local speed = math.max(100, ctx.v("projectile_speed"))
            local x, y = GetUnitX(u), GetUnitY(u)
            local fx = AddSpecialEffect(FX.strike, x, y)
            Timer.onFrame(function(dt)
                if not U.alive(t) then
                    DestroyEffect(fx)
                    return true
                end
                local tx, ty = GetUnitX(t), GetUnitY(t)
                local step = speed * dt
                if U.dist(x, y, tx, ty) <= step + 24 then
                    DestroyEffect(fx)
                    DestroyEffect(AddSpecialEffectTarget(FX.strikeHit, t, "chest"))
                    if not U.isMagicImmune(t) then
                        Damage.deal(u, t, damage, Damage.MAGICAL)
                        if U.alive(t) then
                            Mods.add(t, "morphling_adaptive_strike", {
                                duration = stun, source = u, debuff = true, props = {stun = true},
                                effect = FX.stun, attach = "overhead",
                            })
                            knockback(t, x, y, push, pushTime)
                        end
                    end
                    return true
                end
                local a = U.angle(x, y, tx, ty)
                x, y = x + step * math.cos(a), y + step * math.sin(a)
                BlzSetSpecialEffectPosition(fx, x, y, groundZ(x, y) + 70)
                BlzSetSpecialEffectYaw(fx, a)
                return false
            end)
        end,
    })

    -- Attribute Shift --------------------------------------------------------------------
    -- Agility Gain is the framework toggle (Immolation orders); Strength Gain is a
    -- Mana Shield toggle with zero absorption (manashieldon / manashieldoff), so
    -- both have a real on/off button. Only one can be on.
    local shift = {}          -- unit -> "agi" | "str"
    local looping = {}
    local OFF_ORDER = {agi = "unimmolation", str = "manashieldoff"}

    local function shiftLoop(u)
        if looping[u] then return end
        looping[u] = true
        local acc, fxTime = 0, 0
        Timer.onFrame(function(dt)
            local mode = shift[u]
            local lvl = math.max(level(u, AGI), level(u, STR))
            if not mode or not U.alive(u) or lvl <= 0 then
                looping[u] = nil
                shift[u] = nil
                return true
            end
            local str, agi = GetHeroStr(u, false), GetHeroAgi(u, false)
            if (mode == "agi" and str <= 1) or (mode == "str" and agi <= 1) then return false end
            local cost = A.value(AGI, "mana_cost", lvl, u) * dt       -- halved by Aghanim's Shard
            local mana = GetUnitState(u, UNIT_STATE_MANA)
            if mana < cost then
                shift[u] = nil
                IssueImmediateOrder(u, OFF_ORDER[mode])
                return false
            end
            SetUnitState(u, UNIT_STATE_MANA, mana - cost)
            acc = acc + A.value(AGI, "morph_rate", lvl) * math.max(1, A.value(AGI, "points_per_tick", lvl)) * dt
            while acc >= 1 do
                acc = acc - 1
                str, agi = GetHeroStr(u, false), GetHeroAgi(u, false)
                if mode == "agi" then
                    if str <= 1 then break end
                    SetHeroStr(u, str - 1, true)
                    SetHeroAgi(u, agi + 1, true)
                else
                    if agi <= 1 then break end
                    SetHeroAgi(u, agi - 1, true)
                    SetHeroStr(u, str + 1, true)
                end
            end
            fxTime = fxTime + dt
            if fxTime >= 1 then
                fxTime = 0
                DestroyEffect(AddSpecialEffectTarget(mode == "agi" and FX.agi or FX.str, u, "origin"))
            end
            return false
        end)
    end

    function M.shiftOn(u, mode)
        local cur = shift[u]
        if cur == mode then return end
        shift[u] = mode
        if cur then
            -- the other toggle goes off; issued after this order event finishes
            Timer.after(0, function() IssueImmediateOrder(u, OFF_ORDER[cur]) end)
        end
        shiftLoop(u)
    end

    function M.shiftOff(u, mode)
        if shift[u] == mode then shift[u] = nil end
    end

    function M.shifting(u) return shift[u] end

    local sessions = {}       -- unit -> active Morph state

    -- Agility Gain and Strength Gain are linked: learning one levels both.
    local function syncShift(hero, learned, other)
        local s = sessions[hero]
        if s and s.form == "target" then return end   -- both stashed; see hero_skill below
        local lvl = level(hero, learned)
        local otherId = id(other)
        if not otherId or lvl <= 0 then return end
        if GetUnitAbilityLevel(hero, otherId) == 0 then UnitAddAbility(hero, otherId) end
        SetUnitAbilityLevel(hero, otherId, lvl)
    end

    A.define(AGI, {
        toggleOrder = "immolation",
        onToggle = function(u, on)
            if on then M.shiftOn(u, "agi") else M.shiftOff(u, "agi") end
        end,
        onLearn = function(hero) syncShift(hero, AGI, STR) end,
    })

    A.define(STR, {
        onLearn = function(hero) syncShift(hero, STR, AGI) end,
    })

    local MS_ON, MS_OFF = OrderId("manashieldon"), OrderId("manashieldoff")
    Events.on("order", function(u, order)
        if order ~= MS_ON and order ~= MS_OFF then return end
        if level(u, STR) <= 0 then return end
        if order == MS_ON then M.shiftOn(u, "str") else M.shiftOff(u, "str") end
    end)

    -- Morph ----------------------------------------------------------------------------
    -- Copies: hero abilities (not items, not ultimates) the target has learned.
    function M.collectCopies(u, t)
        local out, seen = {}, {}
        for i = 0, 63 do
            local ab = BlzGetUnitAbilityByIndex(t, i)
            if not ab then break end
            local abil = BlzGetAbilityId(ab)
            if abil ~= 0 and not seen[abil] then
                seen[abil] = true
                local lvl = GetUnitAbilityLevel(t, abil)
                if lvl > 0 and GetUnitAbilityLevel(u, abil) == 0 and not BLOCKED[abil]
                        and BlzGetAbilityBooleanField(ab, ABILITY_BF_HERO_ABILITY)
                        and not BlzGetAbilityBooleanField(ab, ABILITY_BF_ITEM_ABILITY)
                        and BlzGetAbilityIntegerField(ab, ABILITY_IF_REQUIRED_LEVEL) < 6 then
                    local name = nameOf(abil)
                    out[#out + 1] = {id = abil, level = lvl, def = name and A.get(name) or nil}
                end
            end
        end
        return out
    end

    local function stash(u, abil, store)
        local lvl = GetUnitAbilityLevel(u, abil)
        if lvl <= 0 then return end
        store[abil] = {level = lvl, ready = Timer.now() + remaining(u, abil)}
        UnitRemoveAbility(u, abil)
    end

    local function unstash(u, abil, rec)
        if GetUnitAbilityLevel(u, abil) == 0 then UnitAddAbility(u, abil) end
        SetUnitAbilityLevel(u, abil, rec.level)
        local left = rec.ready - Timer.now()
        if left > 0.05 then BlzStartUnitAbilityCooldown(u, abil, left) end
    end

    local function toTarget(u, s)
        if s.form == "target" then return end
        for _, name in ipairs(OWN_BASICS) do
            local abil = id(name)
            if abil then stash(u, abil, s.own) end
        end
        shift[u] = nil
        for _, c in ipairs(s.copies) do
            unstash(u, c.id, s.copyState[c.id] or {level = c.level, ready = 0})
            if c.def and c.def.onLearn then c.def.onLearn(u, c.level, c.def) end
        end
        BlzSetUnitSkin(u, s.skin)
        if s.primary and s.primary > 0 then BlzSetUnitIntegerField(u, UNIT_IF_PRIMARY_ATTRIBUTE, s.primary) end
        s.form = "target"
        DestroyEffect(AddSpecialEffectTarget(FX.morph, u, "origin"))
    end

    local function toOwn(u, s)
        if s.form == "own" then return end
        for _, c in ipairs(s.copies) do
            if c.def and c.def.onUnlearn then c.def.onUnlearn(u, c.def) end
            stash(u, c.id, s.copyState)
        end
        for abil, rec in pairs(s.own) do unstash(u, abil, rec) end
        s.own = {}
        BlzSetUnitSkin(u, GetUnitTypeId(u))
        if s.ownPrimary and s.ownPrimary > 0 then
            BlzSetUnitIntegerField(u, UNIT_IF_PRIMARY_ATTRIBUTE, s.ownPrimary)
        end
        s.form = "own"
        DestroyEffect(AddSpecialEffectTarget(FX.morph, u, "origin"))
    end

    function M.endMorph(u)
        local s = sessions[u]
        if not s then return end
        sessions[u] = nil
        toOwn(u, s)
        local swap, morph = id(SWAP), id(MORPH)
        if swap then UnitRemoveAbility(u, swap) end
        if morph then
            if GetUnitAbilityLevel(u, morph) == 0 then UnitAddAbility(u, morph) end
            SetUnitAbilityLevel(u, morph, s.morphLevel)
            local left = s.morphReady - Timer.now()
            if left > 0.05 then BlzStartUnitAbilityCooldown(u, morph, left) end
        end
    end

    function M.session(u) return sessions[u] end

    A.define(MORPH, {
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            if sessions[u] or not U.alive(t) or t == u or not U.isHero(t) then return end
            local s = {
                target = t, skin = GetUnitTypeId(t), copies = M.collectCopies(u, t),
                own = {}, copyState = {}, form = "own",
                primary = BlzGetUnitIntegerField(t, UNIT_IF_PRIMARY_ATTRIBUTE),
                ownPrimary = BlzGetUnitIntegerField(u, UNIT_IF_PRIMARY_ATTRIBUTE),
                morphLevel = ctx.level,
                morphReady = Timer.now() + BlzGetUnitAbilityCooldown(u, ctx.def.id, ctx.level - 1),
            }
            sessions[u] = s
            -- Swap the Morph button for Morph Replicate once the cast is over.
            Timer.after(0, function()
                if sessions[u] ~= s then return end
                UnitRemoveAbility(u, ctx.def.id)
                local swap = id(SWAP)
                if swap then UnitAddAbility(u, swap) end
                toTarget(u, s)
            end)
            Timer.after(ctx.v("duration"), function()
                if sessions[u] == s then M.endMorph(u) end
            end)
        end,
    })

    -- SIMPLIFIED: Morph Replicate is a Channel cast with the hero's cast point,
    -- so it interrupts the current order; in Dota it is instant. Instant WC3
    -- bases (Berserk, Wind Walk...) share orders with items or copied spells.
    A.define(SWAP, {
        onCast = function(ctx)
            local s = sessions[ctx.caster]
            if not s then return end
            if s.form == "target" then toOwn(ctx.caster, s) else toTarget(ctx.caster, s) end
        end,
    })

    -- Learning a swapped-out ability during Morph: WC3 (re)adds it at level 1,
    -- so the point is banked on the stashed level and the button removed again.
    local IS_OWN_BASIC = {[WAVE] = true, [STRIKE] = true, [AGI] = true, [STR] = true}
    Events.on("hero_skill", function(u, abil)
        local s = sessions[u]
        if not s then return end
        local name = nameOf(abil)
        local function bank(rec, maxLvl)
            if rec.level >= maxLvl then
                UnitModifySkillPoints(u, 1)
            else
                rec.level = rec.level + 1
            end
        end
        if name == MORPH then
            local rec = {level = s.morphLevel}
            bank(rec, MAX_LEVEL[MORPH])
            s.morphLevel = rec.level
            UnitRemoveAbility(u, abil)
        elseif s.form == "target" and IS_OWN_BASIC[name] then
            local rec = s.own[abil]
            if rec then
                bank(rec, MAX_LEVEL[name])
            else
                rec = {level = math.max(1, GetUnitAbilityLevel(u, abil)), ready = 0}
                s.own[abil] = rec
            end
            UnitRemoveAbility(u, abil)
            local other = (name == AGI and id(STR)) or (name == STR and id(AGI)) or nil
            if other then
                s.own[other] = s.own[other] or {ready = 0}
                s.own[other].level = rec.level
            end
        end
    end)

    Events.on("death", function(dying)
        if sessions[dying] then M.endMorph(dying) end
        shift[dying] = nil
    end)

    -- Ebb and Flow ----------------------------------------------------------------------
    -- Agility: +move speed (and attack range in his own form); Strength: +cast
    -- range and slow resistance. Kept while morphed.
    local ebb = {}            -- unit -> last applied values

    local function setAttackRange(u, r)
        -- SIMPLIFIED: attack range goes through the weapon field; the engine may
        -- ignore it (known native bug), in which case the bonus is not shown.
        BlzSetUnitWeaponRealField(u, UNIT_WEAPON_RF_ATTACK_RANGE, 1, r)
        if math.abs(BlzGetUnitWeaponRealField(u, UNIT_WEAPON_RF_ATTACK_RANGE, 0) - r) > 1 then
            BlzSetUnitWeaponRealField(u, UNIT_WEAPON_RF_ATTACK_RANGE, 0, r)
        end
    end

    function M.ebbTick(u)
        local s = sessions[u]
        if s and s.form == "target" and not Mods.flag(u, "hex") and BlzGetUnitSkin(u) ~= s.skin then
            BlzSetUnitSkin(u, s.skin)        -- an ended hex restores the base model
        end
        -- Bots turn Strength Gain on when hurt (hint) and off here once healed.
        if shift[u] == "str" and use("roles").isBot(GetPlayerId(GetOwningPlayer(u)))
                and GetWidgetLife(u) > 0.7 * BlzGetUnitMaxHP(u) then
            shift[u] = nil
            IssueImmediateOrder(u, OFF_ORDER.str)
        end
        if not ebbActive(u) then return end
        local e = ebb[u]
        if not e then e = {}; ebb[u] = e end

        local move = math.floor(agiBonus(u, "move_speed_per_agi") * 2 + 0.5) / 2
        if e.move ~= move then
            e.move = move
            Mods.add(u, "morphling_ebb", {props = {move_flat = move}, persist = true, dispel = "none"})
        end

        -- SIMPLIFIED: slow resistance only counters Lua slows (negative move_pct
        -- modifiers); native WC3 slows are not reduced.
        local resist = math.min(1, strBonus(u, "slow_resist_per_str") / 100)
        local slows = 0
        for _, v in ipairs(Mods.values(u, "move_pct")) do
            if v < 0 then slows = slows + v end
        end
        local counter = math.floor(-slows * resist * 1000 + 0.5) / 1000
        if e.counter ~= counter then
            e.counter = counter
            if counter > 0 then
                Mods.add(u, "morphling_ebb_slow_resist", {props = {move_pct = counter}, persist = true, dispel = "none"})
            else
                Mods.remove(u, "morphling_ebb_slow_resist")
            end
        end

        local cast = math.floor(strBonus(u, "cast_range_per_str") + 0.5)
        for _, name in ipairs({STRIKE, MORPH}) do
            local abil = id(name)
            if abil then applyRange(u, abil, cast) end
        end
        if s then
            for _, c in ipairs(s.copies) do applyRange(u, c.id, cast) end
        end

        if not s or s.form == "own" then
            -- + the level 15 attack range talent (talents.lua "attack_range")
            local range = math.floor((e.baseRange or 350) + Mods.sum(u, "attack_range")
                + agiBonus(u, "attack_range_per_agi") + 0.5)
            if e.range ~= range then
                e.range = range
                setAttackRange(u, range)
            end
        end
    end

    local tracked = {}
    local function register(u)
        if not u or tracked[u] then return end
        tracked[u] = true
        readyAt[u] = readyAt[u] or {}
        ebb[u] = ebb[u] or {}
        local stats = use("data.heroes").morphling.stats
        ebb[u].baseRange = tonumber(stats.AttackRange) or 350
        Timer.every(0.25, function()
            if GetUnitTypeId(u) == 0 then
                tracked[u] = nil
                return true
            end
            if U.alive(u) then M.ebbTick(u) end
            return false
        end)
    end
    M.register = register

    A.define(EBB, {})

    Events.on("hero_spawned", function(u, key)
        if key == "morphling" then register(u) end
    end)
    for u, key in pairs(use("heroes").keyOf) do
        if key == "morphling" then register(u) end
    end

    -- Bots ---------------------------------------------------------------------------------
    -- The hero bot toggles with Immolation orders only: Agility Gain is a toggle
    -- hint; Strength Gain is a plain cast of its "manashieldon" order when hurt
    -- (switching to it turns Agility Gain off). Morph Replicate is not in the
    -- bot's skill list; its hint documents the intended use.
    Bots.hint(WAVE, {target = "enemyHero", point = true, range = 800})
    Bots.hint(STRIKE, {target = "enemyHero"})
    Bots.hint(AGI, {toggle = true, radius = 700})
    Bots.hint(STR, {target = "none", radius = 900, hpBelow = 0.35})
    Bots.hint(MORPH, {target = "enemyHero", ultimate = true})
    Bots.hint(SWAP, {target = "none", hpBelow = 0.25})

    M.knockback = knockback
    return M
end)
