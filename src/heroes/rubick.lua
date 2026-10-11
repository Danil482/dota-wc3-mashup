-- Rubick (npc_dota_hero_rubick): Telekinesis (+ Telekinesis Land), Fade Bolt,
-- Arcane Supremacy and Spell Steal, with the Dota 2 values from data.heroes.
-- WC3 objects: specs/heroes/rubick.json.
--
-- Spell Steal works on Warcraft III hero spells as well as on our Dota spells:
--  1. Every spell_effect cast by a hero (not an illusion) records the ability id
--     and level as that hero's last spell. Item abilities, morphs/splits and
--     Spell Steal itself are skipped.
--  2. A native WC3 hero spell is copied onto Rubick with UnitAddAbility at the
--     victim's level, so channels, summons and self-buffs behave natively. Its
--     button is moved to the free D cell, for Rubick's owner only.
--  3. A Lua-driven Dota spell (Channel object) is never added as is, because its
--     order string could collide with Rubick's own Channel abilities. One of four
--     Channel slots in Dota's empty-slot cell D (rubick_stolen_unit / _point /
--     _none / _any by target type), each with its own order, takes the spell's icon,
--     tooltip, range, area, cost, cooldown and channel time and forwards its
--     casts to the spell's handlers at the stolen level. Dota toggles and
--     native-based Dota spells fall back to case 2.
define("hero_rubick", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Bots = use("bots")
    local M = {}

    -- The extra objects (Land, stolen-spell slots) use keys that are not Dota
    -- ability names: the hero bot treats every Dota-named object as learnable.
    local TELE, LAND, BOLT = "rubick_telekinesis", "rubick_tk_land", "rubick_fade_bolt"
    local SUPREMACY, STEAL = "rubick_arcane_supremacy", "rubick_spell_steal"
    -- Stolen-spell slots by Channel target type (Ncl2).
    local SLOT_BY_TARGET = {[0] = "rubick_stolen_none", [1] = "rubick_stolen_unit", [2] = "rubick_stolen_point",
                            [3] = "rubick_stolen_any"}
    local NOT_STEALABLE = {
        [STEAL] = true, [LAND] = true, rubick_stolen_none = true, rubick_stolen_unit = true,
        rubick_stolen_point = true, rubick_stolen_any = true,
        morphling_replicate = true, morphling_morph_swap = true,
    }
    -- Native spells that change the caster's unit type or hide the hero.
    local BLOCKED = {}
    for _, code in ipairs({"AEme", "ANcr", "ANrg", "ANef"}) do BLOCKED[FourCC(code)] = true end

    local FX = {
        lifted = "Abilities\\Spells\\Human\\AerialShackles\\AerialShacklesTarget.mdl",
        landing = "Abilities\\Spells\\Orc\\WarStomp\\WarStompCaster.mdl",
        landMark = "Abilities\\Spells\\Other\\Aneu\\AneuTarget.mdl",
        stun = "Abilities\\Spells\\Human\\Thunderclap\\ThunderclapTarget.mdl",
        bolt = "CLPB",
        boltHit = "Abilities\\Spells\\Human\\Feedback\\SpellBreakerAttack.mdl",
        weakened = "Abilities\\Spells\\Undead\\Cripple\\CrippleTarget.mdl",
        stealMissile = "Abilities\\Spells\\Human\\SpellSteal\\SpellStealMissile.mdl",
        stolen = "Abilities\\Spells\\Human\\SpellSteal\\SpellStealTarget.mdl",
    }
    local CROW = FourCC("Amrf")

    local loc = Location(0, 0)
    local function groundZ(x, y)
        MoveLocation(loc, x, y)
        return GetLocationZ(loc)
    end

    local function level(u, name)
        return A.level(u, name)
    end

    local nameById = nil
    local function nameOf(id)
        if not nameById then
            nameById = {}
            for name, code in pairs(use("data.ids").abilities) do nameById[FourCC(code)] = name end
        end
        return nameById[id]
    end

    local function cancelCast(u, msg)
        PauseUnit(u, true)
        IssueImmediateOrder(u, "stop")
        PauseUnit(u, false)
        if msg then
            DisplayTimedTextToPlayer(GetOwningPlayer(u), 0, 0, 2, "|cffffcc00" .. msg .. "|r")
        end
    end

    -- Effect flying from (x, y) to a unit; onHit runs when it arrives.
    local function homing(model, x, y, height, target, speed, onHit)
        local fx = AddSpecialEffect(model, x, y)
        Timer.onFrame(function(dt)
            if not U.alive(target) then
                DestroyEffect(fx)
                return true
            end
            local tx, ty = GetUnitX(target), GetUnitY(target)
            local step = speed * dt
            if U.dist(x, y, tx, ty) <= step + 24 then
                DestroyEffect(fx)
                onHit()
                return true
            end
            local a = U.angle(x, y, tx, ty)
            x, y = x + step * math.cos(a), y + step * math.sin(a)
            BlzSetSpecialEffectPosition(fx, x, y, groundZ(x, y) + height)
            BlzSetSpecialEffectYaw(fx, a)
            return false
        end)
    end

    -- Telekinesis --------------------------------------------------------------
    local lifts = {}          -- caster -> lift state

    local function land(s)
        if s.done then return end
        s.done = true
        if lifts[s.caster] == s then
            lifts[s.caster] = nil
            if s.landId then
                UnitRemoveAbility(s.caster, s.landId)
                BlzUnitHideAbility(s.caster, A.id(TELE), false)
            end
        end
        local t = s.target
        if not U.alive(t) then return end
        SetUnitFlyHeight(t, s.baseHeight, 0)
        SetUnitPosition(t, s.lx, s.ly)
        local x, y = GetUnitX(t), GetUnitY(t)
        DestroyEffect(AddSpecialEffect(FX.landing, x, y))
        for _, e in ipairs(U.enemiesOf(s.owner, x, y, s.radius)) do
            -- level 20 talent: the landing deals landing_damage (physical,
            -- https://liquipedia.net/dota2/Rubick, Telekinesis Land)
            if s.landing > 0 then Damage.deal(s.caster, e, s.landing, Damage.PHYSICAL) end
            if U.alive(e) and not U.isMagicImmune(e) then
                Mods.add(e, "rubick_telekinesis_stun", {
                    duration = s.stun, source = s.caster, debuff = true, dispel = "strong",
                    props = {stun = true}, effect = FX.stun, attach = "overhead",
                })
            end
        end
    end

    -- Aghanim's Shard: Rubick may lift himself or an ally (not stunned, thrown
    -- after shard_teammate_throw_delay, shard_max_land_distance_bonus_pct %
    -- farther); the landing still stuns enemies around
    -- (https://liquipedia.net/dota2/Rubick, Telekinesis).
    local function friendly(ctx)
        return ctx.target ~= nil and not IsUnitEnemy(ctx.target, ctx.owner)
    end

    A.define(TELE, {
        onChannel = function(ctx)
            if friendly(ctx) and ctx.v("shard_teammate_throw_delay") <= 0 then
                cancelCast(ctx.caster, "Telekinesis lifts allies with Aghanim's Shard")
            end
        end,
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            if not U.alive(t) or U.isMagicImmune(t) then return end
            local ally = friendly(ctx)
            if ally and ctx.v("shard_teammate_throw_delay") <= 0 then return end
            local s = {
                caster = u, target = t, owner = ctx.owner, started = Timer.now(),
                lift = ctx.v("lift_duration"), fall = ctx.v("fall_duration"), stun = ctx.v("stun_duration"),
                radius = ctx.v("radius"), maxLand = ctx.v("max_land_distance"),
                landing = ctx.v("landing_damage"), x0 = GetUnitX(t), y0 = GetUnitY(t),
            }
            if ally then
                s.lift = ctx.v("shard_teammate_throw_delay") + s.fall
                s.maxLand = s.maxLand * (1 + ctx.v("shard_max_land_distance_bonus_pct") / 100)
            end
            s.lx, s.ly = s.x0, s.y0
            lifts[u] = s
            if UnitAddAbility(t, CROW) then UnitRemoveAbility(t, CROW) end
            s.baseHeight = GetUnitDefaultFlyHeight(t)
            local rise = math.max(0.1, s.lift - s.fall)
            SetUnitFlyHeight(t, s.baseHeight + 250, 250 / rise)
            Mods.add(t, "rubick_telekinesis", {
                duration = s.lift, source = u, debuff = not ally, dispel = "strong",
                props = {stun = not ally or nil}, effect = FX.lifted, attach = "origin",
                onRemove = function() land(s) end,
            })
            -- As in Dota, Land takes Telekinesis' button (Q) while the target is up;
            -- deferred: hiding an ability inside its own cast event is unsafe.
            local landId = A.id(LAND)
            if landId and U.alive(u) then
                Timer.after(0, function()
                    if s.done or lifts[u] ~= s then return end
                    UnitAddAbility(u, landId)
                    BlzUnitHideAbility(u, A.id(TELE), true)
                    s.landId = landId
                end)
            end
            -- Glide toward the chosen landing point; drop during fall_duration.
            Timer.onFrame(function(dt)
                if s.done then return true end
                local left = s.started + s.lift - Timer.now()
                if not s.falling and left <= s.fall then
                    s.falling = true
                    SetUnitFlyHeight(t, s.baseHeight, 250 / math.max(0.05, s.fall))
                end
                if U.alive(t) and left > dt then
                    local x, y = GetUnitX(t), GetUnitY(t)
                    local d = U.dist(x, y, s.lx, s.ly)
                    if d > 1 then
                        local step = math.min(d, d * dt / left)
                        local a = U.angle(x, y, s.lx, s.ly)
                        SetUnitX(t, x + step * math.cos(a))
                        SetUnitY(t, y + step * math.sin(a))
                    end
                end
                return false
            end)
        end,
    })

    A.define(LAND, {
        onCast = function(ctx)
            local s = lifts[ctx.caster]
            if not s or s.done then return end
            local d = U.dist(s.x0, s.y0, ctx.x, ctx.y)
            if d > s.maxLand then
                s.lx, s.ly = U.polar(s.x0, s.y0, s.maxLand, U.angle(s.x0, s.y0, ctx.x, ctx.y))
            else
                s.lx, s.ly = ctx.x, ctx.y
            end
            DestroyEffect(AddSpecialEffect(FX.landMark, s.lx, s.ly))
        end,
    })

    -- Fade Bolt -----------------------------------------------------------------
    -- Jumps to the nearest enemy not hit yet within `radius`; every jump deals
    -- jump_damage_reduction_pct % less. The debuff cuts all damage the unit deals.
    local function boltLink(x1, y1, z1, x2, y2, z2)
        local l = AddLightningEx(FX.bolt, true, x1, y1, z1, x2, y2, z2)
        SetLightningColor(l, 0.45, 1, 0.45, 1)
        Timer.after(0.25, function() DestroyLightning(l) end)
    end

    A.define(BOLT, {
        onCast = function(ctx)
            local u, owner = ctx.caster, ctx.owner
            local p = {
                damage = ctx.v("damage"), jump = ctx.v("jump_damage_reduction_pct") / 100,
                weaken = ctx.v("damage_reduction") / 100, duration = ctx.v("duration"),
                radius = ctx.v("radius"), delay = ctx.v("jump_delay"),
            }
            local hit = {}
            local function strike(fromX, fromY, fromZ, t, amount)
                hit[t] = true
                local tx, ty, tz = GetUnitX(t), GetUnitY(t), BlzGetUnitZ(t) + 50
                boltLink(fromX, fromY, fromZ, tx, ty, tz)
                DestroyEffect(AddSpecialEffectTarget(FX.boltHit, t, "chest"))
                if not U.isMagicImmune(t) then
                    Damage.deal(u, t, amount, Damage.MAGICAL)
                    Mods.add(t, "rubick_fade_bolt", {
                        duration = p.duration, source = u, debuff = true,
                        props = {rubick_fade = p.weaken}, effect = FX.weakened, attach = "chest",
                    })
                end
                Timer.after(p.delay, function()
                    local best, bestD = nil, math.huge
                    for _, e in ipairs(U.enemiesOf(owner, tx, ty, p.radius)) do
                        if not hit[e] and not U.isMagicImmune(e) then
                            local d = U.dist(tx, ty, GetUnitX(e), GetUnitY(e))
                            if d < bestD then best, bestD = e, d end
                        end
                    end
                    if best then strike(tx, ty, tz, best, amount * (1 - p.jump)) end
                end)
            end
            if U.alive(ctx.target) then
                strike(GetUnitX(u), GetUnitY(u), BlzGetUnitZ(u) + 80, ctx.target, p.damage)
            end
        end,
    })

    Damage.onDamaging(function(source, target, info)
        if not source or info.amount <= 0 then return end
        local weaken = Mods.max(source, "rubick_fade")
        if weaken > 0 then info.amount = info.amount * (1 - weaken) end
    end)

    -- Arcane Supremacy, cast range bonus -----------------------------------------
    local stolen = {}         -- rubick -> {rec, slotId | pos}
    local rangeBase = {}      -- unit -> {abilId -> {levelIndex -> object cast range}}

    local function objectRange(u, id, li)
        local per = rangeBase[u]
        if not per then per = {}; rangeBase[u] = per end
        local lv = per[id]
        if not lv then lv = {}; per[id] = lv end
        if lv[li] == nil then
            local ab = BlzGetUnitAbility(u, id)
            lv[li] = ab and BlzGetAbilityRealLevelField(ab, ABILITY_RLF_CAST_RANGE, li) or 0
        end
        return lv[li]
    end

    local function setRange(u, id, base, bonus, li)
        local ab = BlzGetUnitAbility(u, id)
        if not ab or not base or base <= 0 then return end
        local want = base + bonus
        if math.abs(BlzGetAbilityRealLevelField(ab, ABILITY_RLF_CAST_RANGE, li) - want) > 0.5 then
            BlzSetAbilityRealLevelField(ab, ABILITY_RLF_CAST_RANGE, li, want)
        end
    end

    local function supremacyActive(u)
        return level(u, SUPREMACY) > 0 and not Mods.flag(u, "break")
    end

    -- SIMPLIFIED: WC3 has no unit-wide cast range; the bonus is written into the
    -- per-unit range of Rubick's abilities and of the stolen spell.
    function M.applyRanges(u)
        local lvl = level(u, SUPREMACY)
        local bonus = supremacyActive(u) and A.value(SUPREMACY, "cast_range", lvl) or 0
        for _, name in ipairs({TELE, BOLT, STEAL}) do
            local id = A.id(name)
            if id and GetUnitAbilityLevel(u, id) > 0 and A.rangeBonus(u, id, "supremacy") ~= bonus then
                A.setRangeBonus(u, id, "supremacy", bonus)
            end
        end
        -- Aghanim's Scepter: Spell Steal reaches cast_range_scepter
        local steal = A.id(STEAL)
        local sl = steal and GetUnitAbilityLevel(u, steal) or 0
        if sl > 0 then
            local reach = A.value(STEAL, "cast_range_scepter", sl, u)
            local extra = reach > 0 and reach - A.value(STEAL, "AbilityCastRange", sl) or 0
            if A.rangeBonus(u, steal, "scepter") ~= extra then A.setRangeBonus(u, steal, "scepter", extra) end
        end
        local s = stolen[u]
        if s then
            if s.slotId then
                setRange(u, s.slotId, s.rec.range, bonus, 0)
            else
                local l = GetUnitAbilityLevel(u, s.rec.id)
                if l > 0 then setRange(u, s.rec.id, objectRange(u, s.rec.id, l - 1), bonus, l - 1) end
            end
        end
    end

    -- Spell amplification: Lua spells read the "spell_amp" modifier; native WC3
    -- spells cast by Rubick (stolen ones) are amplified in the damage event.
    local function applySupremacy(u)
        if supremacyActive(u) then
            local amp = A.value(SUPREMACY, "spell_amp", level(u, SUPREMACY)) / 100
            local m = Mods.get(u, "rubick_arcane_supremacy")
            if not m or m.props.spell_amp ~= amp then
                Mods.add(u, "rubick_arcane_supremacy", {props = {spell_amp = amp}, persist = true, dispel = "none"})
            end
        elseif Mods.has(u, "rubick_arcane_supremacy") then
            Mods.remove(u, "rubick_arcane_supremacy")
        end
        M.applyRanges(u)
    end

    Damage.onDamaging(function(source, target, info)
        if not source or info.attack or info.spell ~= nil or info.amount <= 0 then return end
        local amp = supremacyActive(source) and Mods.sum(source, "spell_amp") or 0
        -- level 25 talent: stolen spells deal spell_amp_percent % more.
        -- SIMPLIFIED: only stolen native spells; a stolen Lua spell deals
        -- its damage through Damage.deal, which does not know the spell.
        if stolen[source] then amp = amp + A.value(STEAL, "spell_amp_percent", level(source, STEAL), source) / 100 end
        if amp ~= 0 then info.amount = info.amount * (1 + amp) end
    end)

    local tracked = {}        -- units whose supremacy/ranges are kept up to date
    local rubicks = {}        -- Rubick heroes (bot hint upkeep)
    local updateStealHint     -- defined with Spell Steal below
    local function register(u)
        if not u or tracked[u] then return end
        tracked[u] = true
        Timer.every(0.5, function()
            if GetUnitTypeId(u) == 0 then
                tracked[u] = nil
                return true
            end
            if U.alive(u) then
                applySupremacy(u)
                if rubicks[u] then updateStealHint(u) end
            end
            return false
        end)
    end

    A.define(SUPREMACY, {
        onLearn = function(hero)
            register(hero)
            applySupremacy(hero)
        end,
    })

    -- Spell Steal ------------------------------------------------------------------
    local lastSpell = {}      -- hero -> last stealable spell record

    local function carriedItemAbility(u, id)
        for slot = 0, UnitInventorySize(u) - 1 do
            local item = UnitItemInSlot(u, slot)
            if item and BlzGetItemAbility(item, id) then return true end
        end
        return false
    end

    function M.describe(caster, id)
        local lvl = GetUnitAbilityLevel(caster, id)
        if lvl <= 0 then return nil end
        local name = nameOf(id)
        if name and NOT_STEALABLE[name] then return nil end
        local ab = BlzGetUnitAbility(caster, id)
        if (ab and BlzGetAbilityBooleanField(ab, ABILITY_BF_ITEM_ABILITY)) or carriedItemAbility(caster, id) then
            return nil                                  -- items (WC3 or Dota) are never stolen
        end
        local def = name and A.get(name) or nil
        if not def then
            if not ab or BLOCKED[id] or not BlzGetAbilityBooleanField(ab, ABILITY_BF_HERO_ABILITY) then
                return nil
            end
            return {id = id, level = lvl}
        end
        local rec = {id = id, level = lvl, name = name, def = def}
        local order = use("data.ids").orders[name]
        local li = lvl - 1
        if ab and order and not def.onToggle
                and BlzGetAbilityStringLevelField(ab, ABILITY_SLF_BASE_ORDER_ID_NCL6, li) == order then
            local targetType = BlzGetAbilityIntegerLevelField(ab, ABILITY_ILF_TARGET_TYPE, li)
            rec.slot = SLOT_BY_TARGET[targetType] or SLOT_BY_TARGET[1]
            rec.options = BlzGetAbilityIntegerLevelField(ab, ABILITY_ILF_OPTIONS, li)
            rec.follow = BlzGetAbilityRealLevelField(ab, ABILITY_RLF_FOLLOW_THROUGH_TIME, li)
            rec.range = BlzGetAbilityRealLevelField(ab, ABILITY_RLF_CAST_RANGE, li)
            rec.aoe = BlzGetAbilityRealLevelField(ab, ABILITY_RLF_AREA_OF_EFFECT, li)
            rec.cooldown = BlzGetUnitAbilityCooldown(caster, id, li)
            rec.mana = BlzGetUnitAbilityManaCost(caster, id, li)
        end
        return rec
    end

    Events.on("spell_effect", function(caster, id)
        if not caster or not IsUnitType(caster, UNIT_TYPE_HERO) or IsUnitIllusion(caster) then return end
        local rec = M.describe(caster, id)
        if rec then lastSpell[caster] = rec end
    end)

    function M.lastSpell(u) return lastSpell[u] end

    -- The stolen native ability keeps its own button position in object data;
    -- it is moved to the free D cell (1,1) on the owner's screen only.
    local function moveButton(u, id, x, y)
        if GetLocalPlayer() == GetOwningPlayer(u) then
            BlzSetAbilityPosX(id, x)
            BlzSetAbilityPosY(id, y)
        end
    end

    function M.clear(u)
        local s = stolen[u]
        if not s then return end
        stolen[u] = nil
        if s.slotId then
            UnitRemoveAbility(u, s.slotId)
        else
            local def = s.rec.def
            if def and def.onUnlearn then def.onUnlearn(u, def) end
            UnitRemoveAbility(u, s.id)
            if s.pos then moveButton(u, s.id, s.pos[1], s.pos[2]) end
        end
    end

    function M.grant(u, rec, duration, cdPct)
        M.clear(u)
        if not U.alive(u) then return end
        local s = {rec = rec}
        local li = rec.level - 1
        -- level 15 talent: stolen spells cost stolen_mana_reduction % less
        local manaCut = A.value(STEAL, "stolen_mana_reduction", level(u, STEAL), u) / 100
        if rec.slot then
            local slotId = A.id(rec.slot)
            if not slotId then return end
            UnitAddAbility(u, slotId)
            s.slotId = slotId
            -- a Dota spell comes without its owner's talents but with Rubick's
            -- own Scepter and Shard (https://liquipedia.net/dota2/Rubick, Spell Steal)
            local follow, mana, cooldown = rec.follow or 0, rec.mana or 0, rec.cooldown or 0
            if rec.name then
                mana = A.value(rec.name, "AbilityManaCost", rec.level, u)
                cooldown = A.value(rec.name, "AbilityCooldown", rec.level, u)
                if follow > 0 and A.value(rec.name, "AbilityChannelTime", rec.level) > 0 then
                    follow = A.value(rec.name, "AbilityChannelTime", rec.level, u)
                end
            end
            local ab = BlzGetUnitAbility(u, slotId)
            if ab then
                BlzSetAbilityIntegerLevelField(ab, ABILITY_ILF_OPTIONS, 0, rec.options or 1)
                BlzSetAbilityRealLevelField(ab, ABILITY_RLF_FOLLOW_THROUGH_TIME, 0, follow)
                BlzSetAbilityRealLevelField(ab, ABILITY_RLF_AREA_OF_EFFECT, 0, rec.aoe or 0)
            end
            BlzSetUnitAbilityManaCost(u, slotId, 0, math.floor(mana * (1 - manaCut) + 0.5))
            BlzSetUnitAbilityCooldown(u, slotId, 0, cooldown * (1 - cdPct))
            BlzSetAbilityIcon(slotId, BlzGetAbilityIcon(rec.id))
            BlzSetAbilityTooltip(slotId, BlzGetAbilityTooltip(rec.id, li), 0)
            BlzSetAbilityExtendedTooltip(slotId, BlzGetAbilityExtendedTooltip(rec.id, li), 0)
        else
            -- the D-cell copy keeps the spell off Rubick's own hotkeys; a spell
            -- without a copy only gets its button moved and keeps its hotkey
            local id = A.copyId(rec.id) or rec.id
            s.id = id
            if GetUnitAbilityLevel(u, id) == 0 then UnitAddAbility(u, id) end
            SetUnitAbilityLevel(u, id, rec.level)
            if id == rec.id then
                s.pos = {BlzGetAbilityPosX(id), BlzGetAbilityPosY(id)}
                moveButton(u, id, 1, 1)
            end
            BlzSetUnitAbilityCooldown(u, id, li, BlzGetUnitAbilityCooldown(u, id, li) * (1 - cdPct))
            if manaCut > 0 then
                BlzSetUnitAbilityManaCost(u, id, li, math.floor(BlzGetUnitAbilityManaCost(u, id, li) * (1 - manaCut) + 0.5))
            end
            if rec.def and rec.def.onLearn then rec.def.onLearn(u, rec.level, rec.def) end
        end
        stolen[u] = s
        M.applyRanges(u)
        DestroyEffect(AddSpecialEffectTarget(FX.stolen, u, "origin"))
        Timer.after(duration, function()
            if stolen[u] == s then M.clear(u) end
        end)
    end

    function M.stolen(u) return stolen[u] end

    A.define(STEAL, {
        onChannel = function(ctx)
            local t = ctx.target
            if t and not lastSpell[t] then cancelCast(ctx.caster, "That hero has no spell to steal yet") end
        end,
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            local rec = t and lastSpell[t]
            if not rec then return end
            local duration = ctx.v("duration")
            local cdPct = ctx.v("stolen_spell_cooldown_percent") / 100
            DestroyEffect(AddSpecialEffectTarget(FX.stolen, t, "origin"))
            homing(FX.stealMissile, GetUnitX(t), GetUnitY(t), 80, u, math.max(100, ctx.v("projectile_speed")),
                function() M.grant(u, rec, duration, cdPct) end)
        end,
    })

    -- The hidden slots forward their casts to the stolen spell's handlers.
    local function teamAllows(u, rec, target)
        local data = A.data(rec.def.name)
        local team = data and data.AbilityUnitTargetTeam or ""
        local enemy, friendly = string.find(team, "ENEMY") ~= nil, string.find(team, "FRIENDLY") ~= nil
        if enemy and not friendly then return IsUnitEnemy(target, GetOwningPlayer(u)) end
        if friendly and not enemy then return IsUnitAlly(target, GetOwningPlayer(u)) end
        return true
    end

    local function forward(kind)
        return function(ctx)
            local s = stolen[ctx.caster]
            if not s or s.slotId ~= ctx.def.id then return end
            local rec = s.rec
            if kind == "onChannel" and ctx.target and not teamAllows(ctx.caster, rec, ctx.target) then
                cancelCast(ctx.caster, "Invalid target for this spell")
                return
            end
            local fn = rec.def[kind]
            if not fn then return end
            local lvl = rec.level
            -- castId: the ability actually cast (the slot), e.g. so a stolen
            -- Rearm does not refresh the slot it is cast from.
            local sub = {def = rec.def, caster = ctx.caster, owner = ctx.owner, level = lvl,
                         target = ctx.target, x = ctx.x, y = ctx.y, castId = ctx.def.id}
            function sub.v(key) return A.value(rec.def.name, key, lvl, ctx.caster) end
            sub.cast = sub.v
            fn(sub)
        end
    end

    for _, name in pairs(SLOT_BY_TARGET) do
        A.define(name, {onChannel = forward("onChannel"), onCast = forward("onCast"), onEndCast = forward("onEndCast")})
    end

    -- The hero bot ignores hint.check and targets the weakest enemy hero in
    -- range, so the Spell Steal hint is only offered while every enemy hero in
    -- range has a spell to steal.
    local STEAL_HINT = {target = "enemyHero", ultimate = true,
                        check = function(u, t) return t ~= nil and lastSpell[t] ~= nil end}
    function M.stealReady(u)
        local lvl = level(u, STEAL)
        if lvl <= 0 then return false end
        local any, all = false, true
        for _, e in ipairs(U.enemiesOf(GetOwningPlayer(u), GetUnitX(u), GetUnitY(u),
                                       A.value(STEAL, "AbilityCastRange", lvl) + 300)) do
            if U.isHero(e) then
                any = true
                if not lastSpell[e] then all = false end
            end
        end
        return any and all
    end
    updateStealHint = function(u)
        Bots.hint(STEAL, M.stealReady(u) and STEAL_HINT or nil)
    end

    Events.on("death", function(dying)
        if stolen[dying] then M.clear(dying) end
    end)

    local function addRubick(u)
        rubicks[u] = true
        register(u)
    end
    Events.on("hero_spawned", function(u, key)
        if key == "rubick" then addRubick(u) end
    end)
    for u, key in pairs(use("heroes").keyOf) do
        if key == "rubick" then addRubick(u) end
    end
    M.addRubick = addRubick

    -- Bots ------------------------------------------------------------------------
    -- The Land and stolen-spell slots are not in the bot's skill list; their
    -- hints document the intended use for a bot that reads extra abilities.
    Bots.hint(TELE, {target = "enemyHero"})
    Bots.hint(LAND, {target = "point", check = function(u) return lifts[u] ~= nil end})
    Bots.hint(BOLT, {target = "enemy"})
    Bots.hint(STEAL, STEAL_HINT)
    Bots.hint(SLOT_BY_TARGET[1], {target = "enemyHero"})
    Bots.hint(SLOT_BY_TARGET[2], {target = "point"})
    Bots.hint(SLOT_BY_TARGET[3], {target = "enemyHero"})
    Bots.hint(SLOT_BY_TARGET[0], {target = "none", radius = 600})

    M.lifts = lifts
    return M
end)
