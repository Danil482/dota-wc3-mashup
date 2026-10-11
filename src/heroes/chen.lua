-- Chen: Penitence, Holy Persuasion, Divine Favor, the Zealot innate and Hand
-- of God. Persuasion takes over lane creeps, neutrals and the commander's
-- non-hero units (Ancients too with Aghanim's Shard). The Zealot is a creep
-- that joins Chen and can sacrifice itself with Martyrdom; the innate's
-- active teleports Chen's units to him. With Aghanim's Scepter Hand of God is
-- channelled and shields the allies around Chen.
define("hero_chen", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Log = use("log")
    local Bots = use("bots")
    local C = {}

    local PENITENCE, PERSUASION, FAVOR = "chen_penitence", "chen_holy_persuasion", "chen_divine_favor"
    local ZEALOT, HAND, MARTYRDOM = "chen_zealot", "chen_hand_of_god", "chen_martyrdom"
    local MAP = 100000                    -- radius that covers the whole map

    -- Per-hero-level growth from the Dota KeyValues ("hero_levelup"), which the
    -- extracted heroes.json leaves out; read as value + growth * hero level.
    local HEALTH_MIN_PER_LEVEL = 50       -- chen_holy_persuasion health_min
    local ZEALOT_RESPAWN_PER_LEVEL = -1   -- chen_zealot zealot_respawn_time
    local ZEALOT_DAMAGE_PER_LEVEL = 2     -- chen_zealot damage
    -- chen_martyrdom lives on the Zealot unit and is not in heroes.json:
    local MARTYR_SPEED, MARTYR_BASE, MARTYR_HP_PCT, MARTYR_HEAL_PCT = 1000, 25, 20, 50
    -- Bounties as paid by economy.lua, for Holy Persuasion's gold share.
    local LANE_GOLD = {melee = 36, ranged = 45, siege = 73}

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

    local function cancel(u, msg)
        PauseUnit(u, true)
        IssueImmediateOrder(u, "stop")
        PauseUnit(u, false)
        if msg then
            DisplayTimedTextToPlayer(GetOwningPlayer(u), 0, 0, 2, "|cffffcc00" .. msg .. "|r")
        end
    end

    local function level(u, name)
        return A.level(u, name)
    end

    -- A homing model from (x, y) to a unit; onHit() on arrival, fizzles if it dies.
    local function homing(o)
        local e = AddSpecialEffect(o.model, o.x, o.y)
        local x, y, age = o.x, o.y, 0
        Timer.onFrame(function(dt)
            age = age + dt
            if not U.alive(o.target) then
                DestroyEffect(e)
                if o.onMiss then o.onMiss() end
                return true
            end
            local tx, ty = GetUnitX(o.target), GetUnitY(o.target)
            local d = U.dist(x, y, tx, ty)
            local step = o.speed * dt
            if d <= step or age > 10 then
                DestroyEffect(e)
                o.onHit()
                return true
            end
            local a = U.angle(x, y, tx, ty)
            x, y = x + step * math.cos(a), y + step * math.sin(a)
            BlzSetSpecialEffectYaw(e, a)
            BlzSetSpecialEffectPosition(e, x, y, groundZ(x, y) + 70)
            return false
        end)
    end

    -- Heal amplification (Divine Favor) applies to the heals of this module.
    local function healAmp(u)
        return 1 + Mods.sum(u, "heal_amp")
    end

    local function baseDamage(u)
        return BlzGetUnitBaseDamage(u, 0) + BlzGetUnitDiceNumber(u, 0) * (BlzGetUnitDiceSides(u, 0) + 1) / 2
    end

    local function isBotOwned(u)
        local slot = GetPlayerId(GetOwningPlayer(u))
        return slot <= SLOT_COMMANDER and use("roles").isBot(slot)
    end

    ---------------------------------------------------------------- state
    local persuaded = {}       -- creep -> Chen
    local controlled = {}      -- Chen -> list of persuaded creeps, oldest first
    local lastHurt = {}        -- persuaded creep -> time it last took damage
    local zealotOf = {}        -- Chen -> Zealot
    local zealotChen = {}      -- Zealot -> Chen
    local teleports = {}       -- unit -> pending Zealot teleport
    local auraHolders = {}     -- Chens with Divine Favor learned
    local loops = false
    local startLoops

    ---------------------------------------------------------------- Penitence
    A.define(PENITENCE, {
        onCast = function(ctx)
            local c, t = ctx.caster, ctx.target
            if not t then return end
            local dmg, duration = ctx.v("damage"), ctx.v("duration")
            local slow, haste = ctx.v("bonus_movement_speed"), ctx.v("bonus_attack_speed")
            homing({model = "Abilities\\Weapons\\PriestMissile\\PriestMissile.mdl", x = GetUnitX(c), y = GetUnitY(c),
                target = t, speed = ctx.v("speed"), onHit = function()
                    if U.isMagicImmune(t) then return end
                    fxOn("Abilities\\Spells\\Human\\HolyBolt\\HolyBoltSpecialArt.mdl", t, "chest")
                    Damage.deal(c, t, dmg, "pure")
                    local m = Mods.add(t, "chen_penitence", {duration = duration, source = c, debuff = true,
                        props = {move_pct = slow / 100},
                        effect = "Abilities\\Spells\\Human\\slow\\slowtarget.mdl", attach = "chest"})
                    if m then
                        m.haste, m.team = haste, ctx.owner
                    end
                end})
        end,
    })

    -- Allies attacking a penitent unit attack faster while they keep at it.
    Events.on("attacked", function(attacker, target)
        local m = Mods.get(target, "chen_penitence")
        if m and m.team and IsUnitAlly(attacker, m.team) then
            Mods.add(attacker, "chen_penitence_haste", {duration = 1.5, props = {attack_speed = m.haste}})
        end
    end)

    ---------------------------------------------------------------- Holy Persuasion
    local laneKinds = nil
    local function laneKind(u)
        if not laneKinds then
            laneKinds = {}
            for key, code in pairs(use("data.ids").units) do
                local side, kind = key:match("^(%a+)_(%a+)$")
                if side and side ~= "rax" and LANE_GOLD[kind] then laneKinds[FourCC(code)] = kind end
            end
        end
        return laneKinds[GetUnitTypeId(u)]
    end

    local function bountyOf(u)
        local kind = laneKind(u)
        if kind then return LANE_GOLD[kind] end
        return 10 + 8 * GetUnitLevel(u)
    end

    local function addGold(p, amount, u)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD) + amount)
        local t = CreateTextTag()
        SetTextTagText(t, "+" .. amount, 0.023)
        SetTextTagPos(t, GetUnitX(u), GetUnitY(u), 60)
        SetTextTagColor(t, 255, 220, 0, 255)
        SetTextTagVelocity(t, 0, 0.03)
        SetTextTagPermanent(t, false)
        SetTextTagLifespan(t, 2)
        SetTextTagFadepoint(t, 1)
    end

    -- Holy Persuasion's bonuses: minimum health, full mana, speed and damage.
    local function empower(chen, u, lvl)
        if lvl <= 0 then return end
        local minHp = A.value(PERSUASION, "health_min", lvl, chen) + HEALTH_MIN_PER_LEVEL * GetHeroLevel(chen)
        local maxHp = BlzGetUnitMaxHP(u)
        if maxHp < minHp then
            local frac = GetWidgetLife(u) / math.max(1, maxHp)
            BlzSetUnitMaxHP(u, math.floor(minHp))
            SetWidgetLife(u, math.max(1, frac * minHp))
        end
        SetUnitState(u, UNIT_STATE_MANA, GetUnitState(u, UNIT_STATE_MAX_MANA))
        Mods.add(u, "chen_persuaded", {persist = true, dispel = "none", props = {
            move_flat = A.value(PERSUASION, "movement_speed_bonus", lvl, chen),
            damage = math.floor(baseDamage(u) * A.value(PERSUASION, "damage_bonus", lvl, chen) / 100 + 0.5),
        }})
    end

    local function invalidTarget(chen, t, lvl)
        local owner = GetOwningPlayer(chen)
        if U.isHero(t) or U.isStructure(t) or IsUnitIllusion(t) or GetUnitAbilityLevel(t, FourCC("Aloc")) > 0 then
            return "Holy Persuasion only works on creeps"
        end
        if IsUnitType(t, UNIT_TYPE_ANCIENT) then
            -- Aghanim's Shard: Ancients too, one per level of Hand of God
            -- (https://liquipedia.net/dota2/Chen, Holy Persuasion)
            local cap = A.value(HAND, "ancient_creeps_scepter", math.max(1, level(chen, HAND)), chen)
            if level(chen, HAND) <= 0 or cap <= 0 then return "Cannot persuade ancient units" end
            local n = 0
            for _, c in ipairs(controlled[chen] or {}) do
                if U.alive(c) and persuaded[c] == chen and IsUnitType(c, UNIT_TYPE_ANCIENT) then n = n + 1 end
            end
            if n >= cap then return "No room for another Ancient" end
        end
        if GetOwningPlayer(t) == owner then return "Already under your control" end
        if IsUnitAlly(t, owner) and GetPlayerId(GetOwningPlayer(t)) ~= SLOT_ANCIENTS then
            return "Cannot take an ally's unit"
        end
        -- lane creeps count as Dota lane creeps (level 1) whatever WC3 unit they are built on
        local creepLevel = laneKind(t) and 1 or GetUnitLevel(t)
        if creepLevel > A.value(PERSUASION, "level_req", lvl) then return "Creep level too high" end
        return nil
    end

    -- Lane creeps are re-created for Chen: creeps.lua keeps ordering the
    -- original handles down their lane whatever their owner is.
    local function takeOver(t, owner)
        if laneKind(t) == nil then
            SetUnitOwner(t, owner, true)
            return t
        end
        local typ, x, y, face = GetUnitTypeId(t), GetUnitX(t), GetUnitY(t), GetUnitFacing(t)
        local frac = GetWidgetLife(t) / math.max(1, BlzGetUnitMaxHP(t))
        RemoveUnit(t)
        local u = CreateUnit(owner, typ, x, y, face)
        SetWidgetLife(u, math.max(1, frac * BlzGetUnitMaxHP(u)))
        return u
    end

    local function persuade(chen, t, lvl)
        local owner = GetOwningPlayer(chen)
        local gold = math.floor(bountyOf(t) * A.value(PERSUASION, "gold_pct", lvl) / 100)
        if gold > 0 then addGold(owner, gold, t) end
        local u = takeOver(t, owner)
        IssueImmediateOrder(u, "stop")
        empower(chen, u, lvl)
        persuaded[u] = chen
        fxOn("Abilities\\Spells\\Other\\Charm\\CharmTarget.mdl", u, "overhead")
        local alive = {}
        for _, c in ipairs(controlled[chen] or {}) do
            if U.alive(c) and persuaded[c] == chen then alive[#alive + 1] = c end
        end
        alive[#alive + 1] = u
        -- over the limit: the oldest persuaded creep dies
        local max = A.value(PERSUASION, "max_units", lvl)
        while #alive > max do
            local oldest = table.remove(alive, 1)
            persuaded[oldest] = nil
            KillUnit(oldest)
        end
        controlled[chen] = alive
        startLoops()
        return u
    end

    -- Recasting on one of Chen's own creeps, anywhere on the map, removes it
    -- if it has not been hurt lately; the cooldown is then much shorter.
    local function unsummon(chen, t)
        local id = A.id(PERSUASION)
        local lvl = level(chen, PERSUASION)
        if not id or lvl <= 0 or not U.alive(t) or persuaded[t] ~= chen then return false end
        if Mods.flag(chen, "stun") or Mods.flag(chen, "silence") or Mods.flag(chen, "hex") then return false end
        if BlzGetUnitAbilityCooldownRemaining(chen, id) > 0 then return false end
        local cost = BlzGetUnitAbilityManaCost(chen, id, lvl - 1)
        local mana = GetUnitState(chen, UNIT_STATE_MANA)
        if mana < cost then
            DisplayTimedTextToPlayer(GetOwningPlayer(chen), 0, 0, 2, "|cffffcc00Not enough mana|r")
            return false
        end
        if Timer.now() - (lastHurt[t] or -1000) < A.value(PERSUASION, "unsummon_time", lvl) then
            DisplayTimedTextToPlayer(GetOwningPlayer(chen), 0, 0, 2, "|cffffcc00That creep was hurt too recently|r")
            return false
        end
        SetUnitState(chen, UNIT_STATE_MANA, mana - cost)
        local cd = A.value(PERSUASION, "AbilityCooldown", lvl) - A.value(PERSUASION, "unsummon_cooldown_reduction", lvl)
        if cd > 0 then BlzStartUnitAbilityCooldown(chen, id, cd) end
        fx("Abilities\\Spells\\Undead\\Unsummon\\UnsummonTarget.mdl", GetUnitX(t), GetUnitY(t))
        persuaded[t] = nil
        RemoveUnit(t)
        return true
    end

    A.define(PERSUASION, {
        onChannel = function(ctx)
            local c, t = ctx.caster, ctx.target
            if not t then return end
            if persuaded[t] == c then
                cancel(c)
                unsummon(c, t)
                return
            end
            local why = invalidTarget(c, t, ctx.level)
            if why then cancel(c, why) end
        end,
        onCast = function(ctx)
            local c, t = ctx.caster, ctx.target
            if not t or not U.alive(t) or persuaded[t] == c or invalidTarget(c, t, ctx.level) then return end
            persuade(c, t, ctx.level)
        end,
    })

    -- Global unsummon: catch the order before Chen walks to his own creep.
    Events.on("order", function(u, order, target)
        if not target or persuaded[target] ~= u then return end
        local code = use("data.ids").orders[PERSUASION]
        if not code or order ~= OrderId(code) then return end
        Timer.after(0, function()
            IssueImmediateOrder(u, "stop")
            unsummon(u, target)
        end)
    end)

    ---------------------------------------------------------------- Divine Favor
    local function favorAura()
        for chen in pairs(auraHolders) do
            local lvl = level(chen, FAVOR)
            if lvl > 0 and U.alive(chen) and not Mods.flag(chen, "break") then
                local rate = A.value(FAVOR, "heal_rate", lvl)
                local r = A.value(FAVOR, "aura_radius", lvl)
                for _, a in ipairs(U.alliesOf(GetOwningPlayer(chen), GetUnitX(chen), GetUnitY(chen), r)) do
                    if not U.isStructure(a) then
                        Mods.add(a, "chen_divine_favor_aura", {duration = 1.0, dispel = "none",
                            props = {hp_regen = rate * healAmp(a)}})
                    end
                end
            end
        end
    end

    A.define(FAVOR, {
        onLearn = function(hero)
            auraHolders[hero] = true
            startLoops()
        end,
        onCast = function(ctx)
            local c = ctx.caster
            local t = ctx.target or c
            auraHolders[c] = true
            startLoops()
            local list = {t}
            if t == c then
                -- cast on Chen: Chen and every unit he controls
                list = U.enum(GetUnitX(c), GetUnitY(c), MAP, function(u)
                    return GetOwningPlayer(u) == ctx.owner and not U.isStructure(u)
                end)
            end
            for _, u in ipairs(list) do
                Mods.add(u, "chen_divine_favor", {duration = ctx.v("duration"), source = c, dispel = "none",
                    props = {armor = ctx.v("bonus_armor"), heal_amp = ctx.v("heal_amp") / 100},
                    effect = "Abilities\\Spells\\Human\\InnerFire\\InnerFireTarget.mdl", attach = "overhead"})
            end
        end,
    })

    ---------------------------------------------------------------- Hand of God
    -- Aghanim's Scepter: Chen channels Hand of God; while he does, allies
    -- within debuff_immune_radius shed debuffs, resist magic and heal
    -- nearby_hot_boost % faster (https://liquipedia.net/dota2/Chen, Hand of God).
    -- SIMPLIFIED: debuff immunity is a basic dispel every tick.
    local channels = {}       -- chen -> true while channelling Hand of God

    local function ward(ctx, hps)
        local c = ctx.caster
        local radius, resist, boost = ctx.v("debuff_immune_radius"), ctx.v("debuff_immune_resist") / 100,
            ctx.v("nearby_hot_boost") / 100
        channels[c] = true
        local TICK = 0.25
        Timer.every(TICK, function()
            if not channels[c] or not U.alive(c) then
                channels[c] = nil
                return true
            end
            for _, a in ipairs(U.alliesOf(ctx.owner, GetUnitX(c), GetUnitY(c), radius)) do
                if not U.isStructure(a) then
                    Mods.dispel(a, {debuffs = true})
                    local regen = Mods.has(a, "chen_hand_of_god") and hps * boost * healAmp(a) or nil
                    Mods.add(a, "chen_hand_of_god_ward", {duration = TICK + 0.1, source = c, dispel = "none",
                        props = {magic_resist = resist, hp_regen = regen}})
                end
            end
            return false
        end)
    end
    C.channelling = function(u) return channels[u] == true end

    A.define(HAND, {
        onCast = function(ctx)
            local c = ctx.caster
            local heal, hps, duration = ctx.v("heal_amount"), ctx.v("heal_per_second"), ctx.v("hot_duration")
            -- talents: a strong dispel, and a full heal for Chen and his own units
            local purge, full = ctx.v("does_purge") > 0, ctx.v("full_heal_on_chen_and_creeps") > 0
            local list = U.enum(GetUnitX(c), GetUnitY(c), MAP, function(u)
                if U.isStructure(u) then return false end
                return GetOwningPlayer(u) == ctx.owner or (U.isHero(u) and IsUnitAlly(u, ctx.owner))
            end)
            for _, u in ipairs(list) do
                local amp = healAmp(u)
                if purge then Mods.dispel(u, {debuffs = true, strong = true}) end
                if full and GetOwningPlayer(u) == ctx.owner then
                    SetWidgetLife(u, BlzGetUnitMaxHP(u))
                else
                    Damage.heal(u, heal * amp)
                end
                fxOn("Abilities\\Spells\\Human\\HolyBolt\\HolyBoltSpecialArt.mdl", u, "origin")
                Mods.add(u, "chen_hand_of_god", {duration = duration, source = c, props = {hp_regen = hps * amp},
                    effect = "Abilities\\Spells\\NightElf\\Rejuvenation\\RejuvenationTarget.mdl", attach = "chest"})
            end
            if ctx.v("AbilityChannelTime") > 0 then ward(ctx, hps) end
        end,
        onEndCast = function(ctx) channels[ctx.caster] = nil end,
    })

    ---------------------------------------------------------------- Zealot
    local function spawnZealot(chen)
        local code = use("data.ids").units.chen_zealot
        if not code or not U.alive(chen) or U.alive(zealotOf[chen]) then return nil end
        local back = GetUnitFacing(chen) * math.pi / 180 + math.pi
        local x, y = U.polar(GetUnitX(chen), GetUnitY(chen), 150, back)
        local z = CreateUnit(GetOwningPlayer(chen), FourCC(code), x, y, GetUnitFacing(chen))
        zealotOf[chen], zealotChen[z] = z, chen
        local mid = A.id(MARTYRDOM)
        if mid then UnitAddAbility(z, mid) end
        BlzSetUnitBaseDamage(z, BlzGetUnitBaseDamage(z, 0) + ZEALOT_DAMAGE_PER_LEVEL * GetHeroLevel(chen), 0)
        -- level 10 talent: the Zealot gets bonus_hp % more health and damage
        local more = A.value(ZEALOT, "bonus_hp", 1, chen) / 100
        if more > 0 then
            BlzSetUnitMaxHP(z, math.floor(BlzGetUnitMaxHP(z) * (1 + more) + 0.5))
            SetWidgetLife(z, BlzGetUnitMaxHP(z))
            local dmg = BlzGetUnitBaseDamage(z, 0)
            BlzSetUnitBaseDamage(z, math.floor(A.apply(ZEALOT, "damage", dmg, 1, chen) + 0.5), 0)
        end
        empower(chen, z, level(chen, PERSUASION))
        fx("Abilities\\Spells\\Human\\Resurrect\\ResurrectTarget.mdl", x, y)
        startLoops()
        return z
    end

    local function respawnTime(chen)
        return A.value(ZEALOT, "zealot_respawn_time", 1) + ZEALOT_RESPAWN_PER_LEVEL * GetHeroLevel(chen)
    end

    local function startTeleport(chen, u, delay)
        local old = teleports[u]
        if old then DestroyEffect(old.fx) end
        local tp = {chen = chen,
            fx = AddSpecialEffectTarget("Abilities\\Spells\\Human\\MassTeleport\\MassTeleportTarget.mdl", u, "origin")}
        teleports[u] = tp
        Timer.after(delay, function()
            if teleports[u] ~= tp then return end
            teleports[u] = nil
            DestroyEffect(tp.fx)
            if U.alive(u) and U.alive(chen) then
                local x, y = U.polar(GetUnitX(chen), GetUnitY(chen), 120, GetRandomReal(0, 2 * math.pi))
                SetUnitPosition(u, x, y)
                IssueImmediateOrder(u, "stop")
                fxOn("Abilities\\Spells\\Human\\MassTeleport\\MassTeleportCaster.mdl", u, "origin")
            end
        end)
    end

    -- Innate active: teleport one of Chen's units to him after a delay, or all
    -- of them when cast on Chen. Damage from enemy players cancels it.
    A.define(ZEALOT, {
        onChannel = function(ctx)
            local c, t = ctx.caster, ctx.target
            if not t then return end
            if t ~= c and (GetOwningPlayer(t) ~= ctx.owner or U.isHero(t) or U.isStructure(t)) then
                cancel(c, "Target Chen or a unit you control")
            end
        end,
        onCast = function(ctx)
            local c, t = ctx.caster, ctx.target
            if not t then return end
            local list = {}
            if t == c then
                list = U.enum(GetUnitX(c), GetUnitY(c), MAP, function(u)
                    return u ~= c and GetOwningPlayer(u) == ctx.owner and not U.isHero(u) and not U.isStructure(u)
                end)
            elseif GetOwningPlayer(t) == ctx.owner and not U.isHero(t) then
                list = {t}
            end
            local delay = ctx.v("teleport_delay")
            for _, u in ipairs(list) do startTeleport(c, u, delay) end
        end,
    })

    -- Zealot's Martyrdom: it gives its life to hurt an enemy or heal an ally.
    A.define(MARTYRDOM, {
        onCast = function(ctx)
            local z, t = ctx.caster, ctx.target
            if not t or t == z then return end
            local amount = MARTYR_BASE + MARTYR_HP_PCT / 100 * GetWidgetLife(z)
            local enemy = IsUnitEnemy(t, ctx.owner)
            local x, y = GetUnitX(z), GetUnitY(z)
            -- the Zealot leaves at once; it stays the damage source until impact
            SetUnitInvulnerable(z, true)
            ShowUnit(z, false)
            fx("Abilities\\Spells\\Human\\Resurrect\\ResurrectCaster.mdl", x, y)
            homing({model = "Abilities\\Weapons\\PriestMissile\\PriestMissile.mdl", x = x, y = y, target = t,
                speed = MARTYR_SPEED,
                onHit = function()
                    if enemy then
                        fxOn("Abilities\\Spells\\Human\\HolyBolt\\HolyBoltSpecialArt.mdl", t, "chest")
                        Damage.deal(z, t, amount, "magical")
                    else
                        fxOn("Abilities\\Spells\\Human\\Heal\\HealTarget.mdl", t, "origin")
                        Damage.heal(t, amount * MARTYR_HEAL_PCT / 100 * healAmp(t))
                    end
                    KillUnit(z)
                end,
                onMiss = function() KillUnit(z) end})
        end,
    })

    Events.on("hero_spawned", function(u, key)
        if key == "chen" then spawnZealot(u) end
    end)

    -- Whenever Chen respawns the Zealot joins him again.
    Events.on("hero_respawned", function(u, key)
        if key == "chen" and not U.alive(zealotOf[u]) then
            zealotOf[u] = nil
            spawnZealot(u)
        end
    end)

    Events.on("death", function(dying)
        local chen = zealotChen[dying]
        if chen then
            zealotChen[dying] = nil
            if zealotOf[chen] == dying then zealotOf[chen] = nil end
            Timer.after(math.max(1, respawnTime(chen)), function()
                if zealotOf[chen] == nil and U.alive(chen) then spawnZealot(chen) end
            end)
        end
        persuaded[dying] = nil
        lastHurt[dying] = nil
        local tp = teleports[dying]
        if tp then
            teleports[dying] = nil
            DestroyEffect(tp.fx)
        end
    end)

    Damage.onDamaged(function(source, target, amount, info)
        if target == nil or amount <= 0 then return end
        if persuaded[target] then lastHurt[target] = Timer.now() end
        local tp = teleports[target]
        if tp and source and IsUnitEnemy(source, GetOwningPlayer(target))
            and GetOwningPlayer(source) ~= Player(PLAYER_NEUTRAL_AGGRESSIVE) then
            teleports[target] = nil
            DestroyEffect(tp.fx)
        end
    end)

    ---------------------------------------------------------------- loops
    -- Bot Chens have no one to order their creeps around: they follow Chen.
    local function follow()
        for chen, list in pairs(controlled) do
            if U.alive(chen) and isBotOwned(chen) then
                local x, y = GetUnitX(chen), GetUnitY(chen)
                local all = {zealotOf[chen]}
                for _, u in ipairs(list) do all[#all + 1] = u end
                for _, u in ipairs(all) do
                    if U.alive(u) and U.dist(x, y, GetUnitX(u), GetUnitY(u)) > 700 then
                        IssuePointOrder(u, "attack", x + GetRandomReal(-150, 150), y + GetRandomReal(-150, 150))
                    end
                end
            end
        end
        for chen, z in pairs(zealotOf) do
            if controlled[chen] == nil and U.alive(chen) and U.alive(z) and isBotOwned(chen)
                and U.dist(GetUnitX(chen), GetUnitY(chen), GetUnitX(z), GetUnitY(z)) > 700 then
                IssuePointOrder(z, "attack", GetUnitX(chen), GetUnitY(chen))
            end
        end
    end

    startLoops = function()
        if loops then return end
        loops = true
        Timer.every(0.5, favorAura)
        Timer.every(1.0, follow)
    end

    ---------------------------------------------------------------- bots
    Bots.hint(PENITENCE, {target = "enemyHero"})
    Bots.hint(PERSUASION, {target = "enemy"})
    Bots.hint(FAVOR, {target = "allyHero"})
    Bots.hint(ZEALOT, {target = "self", radius = 700, minEnemies = 2, hpBelow = 0.5})
    Bots.hint(HAND, {target = "none", radius = 900, hpBelow = 0.35, ultimate = true})

    -- exposed for tests
    C.persuade, C.spawnZealot, C.unsummon, C.favorAura, C.follow = persuade, spawnZealot, unsummon, favorAura, follow
    C.zealotOf, C.persuaded = zealotOf, persuaded
    return C
end)
