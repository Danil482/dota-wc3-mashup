-- Anti-Mage (npc_dota_hero_antimage): Mana Break, Blink, Counterspell,
-- Persecutor (innate antimage_persectur) and Mana Void, using the Dota 2 values
-- from data.heroes. WC3 objects: specs/heroes/antimage.json.
define("hero_antimage", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Bots = use("bots")
    local M = {units = {}}

    local BREAK, BLINK, COUNTER = "antimage_mana_break", "antimage_blink", "antimage_counterspell"
    local PERSECUTOR, VOID = "antimage_persectur", "antimage_mana_void"

    local FX = {
        burn = "Abilities\\Spells\\Human\\Feedback\\SpellBreakerAttack.mdl",
        shell = "Abilities\\Spells\\Undead\\AntiMagicShell\\AntiMagicShell.mdl",
        reflect = "Abilities\\Spells\\Items\\SpellShieldAmulet\\SpellShieldCaster.mdl",
        void = "Abilities\\Spells\\Human\\ManaFlare\\ManaFlareBoltImpact.mdl",
        voidHit = "Abilities\\Spells\\Human\\Feedback\\ArcaneTowerAttack.mdl",
        stun = "Abilities\\Spells\\Human\\Thunderclap\\ThunderclapTarget.mdl",
    }
    -- Persecutor's slows grow per hero level ("hero_levelup" in the Dota KV,
    -- not carried by data.heroes).
    local SLOW_MIN_PER_LEVEL, SLOW_MAX_PER_LEVEL = 0.5, 1.0
    -- Native WC3 roots: Ensnare, Entangling Roots, Web
    local ROOT_BUFFS = {}
    for _, code in ipairs({"Bens", "Bena", "Beng", "BEer", "Bweb", "Bwea", "BIwb"}) do
        ROOT_BUFFS[#ROOT_BUFFS + 1] = FourCC(code)
    end

    local ids = use("data.ids")
    local SHELL_ID = ids.abilities.antimage_spell_shield and FourCC(ids.abilities.antimage_spell_shield)
    local DUMMY_ID = ids.units.antimage_reflector and FourCC(ids.units.antimage_reflector)
    local TIMED_LIFE = FourCC("BTLF")

    local function level(u, name)
        local id = A.id(name)
        return id and GetUnitAbilityLevel(u, id) or 0
    end

    -- Counterspell passive: magic resistance, switched off while broken.
    local function applyResist(u)
        local lvl = level(u, COUNTER)
        if lvl <= 0 or Mods.flag(u, "break") then
            if Mods.has(u, "antimage_counterspell_resist") then Mods.remove(u, "antimage_counterspell_resist") end
            return
        end
        local v = A.value(COUNTER, "magic_resistance", lvl) / 100
        local m = Mods.get(u, "antimage_counterspell_resist")
        if not m or m.props.magic_resist ~= v then
            Mods.add(u, "antimage_counterspell_resist", {source = u, persist = true, dispel = "none",
                                                        props = {magic_resist = v}})
        end
    end

    local loop = nil
    function M.register(u)
        if not u or M.units[u] then return end
        M.units[u] = true
        if not loop then
            loop = Timer.every(0.5, function()
                for unit in pairs(M.units) do
                    if U.alive(unit) then applyResist(unit) end
                end
            end)
        end
    end

    -- Mana Break and Persecutor: on-hit effects of basic attacks ----------------
    Damage.onDamaging(function(source, target, info)
        if not info.attack or not source or not target or source == target then return end
        local lb, lp = level(source, BREAK), level(source, PERSECUTOR)
        if lb <= 0 and lp <= 0 then return end
        if Mods.flag(source, "break") or not IsUnitEnemy(target, GetOwningPlayer(source))
            or U.isStructure(target) or U.isMagicImmune(target) then
            return
        end
        local maxMana = BlzGetUnitMaxMana(target)
        -- SIMPLIFIED: units without a mana pool are neither burned nor slowed
        if maxMana <= 0 then return end
        if lb > 0 then
            local mana = GetUnitState(target, UNIT_STATE_MANA)
            local burn = A.value(BREAK, "mana_per_hit", lb) + maxMana * A.value(BREAK, "mana_per_hit_pct", lb) / 100
            if IsUnitIllusion(source) then burn = burn * A.value(BREAK, "illusion_percentage", lb) / 100 end
            burn = math.min(burn, mana)
            if burn > 0 then
                SetUnitState(target, UNIT_STATE_MANA, mana - burn)
                info.amount = info.amount + burn * A.value(BREAK, "percent_damage_per_burn", lb) / 100
                DestroyEffect(AddSpecialEffectTarget(FX.burn, target, "origin"))
            end
        end
        if lp > 0 then
            local pct = GetUnitState(target, UNIT_STATE_MANA) / maxMana * 100
            local threshold = math.max(1, A.value(PERSECUTOR, "mana_threshold", 1))
            if pct <= threshold then
                local extra = math.max(0, GetHeroLevel(source) - 1)
                local low = A.value(PERSECUTOR, "move_slow_min", 1) + SLOW_MIN_PER_LEVEL * extra
                local high = A.value(PERSECUTOR, "move_slow_max", 1) + SLOW_MAX_PER_LEVEL * extra
                local slow = low + (high - low) * (1 - pct / threshold)
                Mods.add(target, "antimage_persecutor", {duration = A.value(PERSECUTOR, "slow_duration", 1),
                                                          source = source, props = {move_pct = -slow / 100}, debuff = true})
            end
        end
    end)

    A.define(BREAK, {onLearn = function(u) M.register(u) end})

    -- Blink: native WC3 Blink (overshoot and minimum range built in) ----------
    -- SIMPLIFIED: "root" means a Lua root or a WC3 Ensnare/Entangle/Web buff.
    local function rooted(u)
        if Mods.flag(u, "root") then return true end
        for _, b in ipairs(ROOT_BUFFS) do
            if GetUnitAbilityLevel(u, b) > 0 then return true end
        end
        return false
    end

    A.define(BLINK, {
        onChannel = function(ctx)
            M.register(ctx.caster)
            if rooted(ctx.caster) then IssueImmediateOrder(ctx.caster, "stop") end
        end,
    })

    -- Counterspell ------------------------------------------------------------------
    -- The active adds a native Spell Shield (cooldown 0) for its duration, which
    -- blocks every negative targeted spell; a dummy recasts the spell at its caster.
    -- SIMPLIFIED: only WC3-native spells are reflected (the commander side has
    -- no Lua spells); reflected channels last at most the dummy's 6 s life.
    local function reflect(am, caster, abil)
        if not DUMMY_ID or not U.alive(caster) then return end
        local order = GetUnitCurrentOrder(caster)
        local lvl = GetUnitAbilityLevel(caster, abil)
        if order == 0 or lvl <= 0 then return end
        local x, y = GetUnitX(am), GetUnitY(am)
        local face = math.deg(U.angle(x, y, GetUnitX(caster), GetUnitY(caster)))
        local d = CreateUnit(GetOwningPlayer(am), DUMMY_ID, x, y, face)
        UnitAddAbility(d, abil)
        SetUnitAbilityLevel(d, abil, lvl)
        BlzSetUnitAbilityManaCost(d, abil, lvl - 1, 0)
        BlzSetUnitAbilityCooldown(d, abil, lvl - 1, 0)
        local ab = BlzGetUnitAbility(d, abil)
        if ab then BlzSetAbilityRealLevelField(ab, ABILITY_RLF_CAST_RANGE, lvl - 1, 99999) end
        UnitApplyTimedLife(d, TIMED_LIFE, 6)
        if IssueTargetOrderById(d, order, caster) then
            DestroyEffect(AddSpecialEffectTarget(FX.reflect, am, "origin"))
        else
            RemoveUnit(d)
        end
    end

    Events.on("spell_effect", function(caster, abil, target)
        if not target or not caster or caster == target or not M.units[target] then return end
        if not Mods.has(target, "antimage_counterspell") then return end
        if DUMMY_ID and GetUnitTypeId(caster) == DUMMY_ID then return end
        if not IsUnitEnemy(caster, GetOwningPlayer(target)) then return end
        reflect(target, caster, abil)
    end)

    A.define(COUNTER, {
        onLearn = function(u)
            M.register(u)
            applyResist(u)
        end,
        onCast = function(ctx)
            local u = ctx.caster
            M.register(u)
            Mods.add(u, "antimage_counterspell", {
                duration = ctx.v("duration"), source = u, effect = FX.shell, attach = "origin",
                onRemove = function()
                    if SHELL_ID then UnitRemoveAbility(u, SHELL_ID) end
                end,
            })
            if SHELL_ID then UnitAddAbility(u, SHELL_ID) end
        end,
    })

    -- Mana Void ----------------------------------------------------------------------
    A.define(VOID, {
        onCast = function(ctx)
            local u, t = ctx.caster, ctx.target
            M.register(u)
            if not t or not U.alive(t) then return end
            local missing = math.max(0, BlzGetUnitMaxMana(t) - GetUnitState(t, UNIT_STATE_MANA))
            local dmg = missing * ctx.v("mana_void_damage_per_mana")
            local tx, ty = GetUnitX(t), GetUnitY(t)
            DestroyEffect(AddSpecialEffect(FX.void, tx, ty))
            if not U.isMagicImmune(t) then
                Mods.add(t, "antimage_mana_void", {duration = ctx.v("mana_void_ministun"), source = u, debuff = true,
                                                   dispel = "strong", props = {stun = true},
                                                   effect = FX.stun, attach = "overhead"})
            end
            if dmg <= 0 then return end
            for _, e in ipairs(U.enemiesOf(ctx.owner, tx, ty, ctx.v("mana_void_aoe_radius"))) do
                Damage.deal(u, e, dmg, Damage.MAGICAL)
                DestroyEffect(AddSpecialEffectTarget(FX.voidHit, e, "origin"))
            end
        end,
    })

    A.define(PERSECUTOR, {})

    -- Registration --------------------------------------------------------------------
    Events.on("hero_spawned", function(u, key)
        if key == "antimage" then M.register(u) end
    end)
    for u, key in pairs(use("heroes").keyOf) do
        if key == "antimage" then M.register(u) end
    end

    -- Bot hints -------------------------------------------------------------------------
    Bots.hint(BLINK, {target = "enemyHero", point = true, range = 1000})
    Bots.hint(COUNTER, {target = "none", radius = 700, ultimate = true, hpBelow = 0.6})
    Bots.hint(VOID, {target = "enemyHero", ultimate = true, targetHpBelow = 0.5})

    return M
end)
