-- Applies summed modifier properties to units through hidden bonus abilities
-- (green numbers in the UI) and native setters. Attribute-derived Dota stats
-- (HP per strength, armor per agility, ...) come from gameplay constants.
-- Properties: armor, damage, attack_speed (Dota points, 100 = +100%),
-- max_hp, max_mana, str, agi, int, move_flat, move_pct, hp_regen, mana_regen.
define("stats", function()
    local U = use("util")
    local Timer = use("timer")
    local S = {}

    local ARMOR = FourCC("Zarm")   -- from AId1, field Idef
    local DAMAGE = FourCC("Zdmg")  -- from AItg, field Iatt
    local ASPEED = FourCC("Zats")  -- from AIsx, field Isx1
    local ATTR = FourCC("Zatr")    -- from AIx1, fields Iagi, Iint, Istr

    local applied = {}             -- unit -> last applied values
    local regen = {}               -- unit -> {hp = x, mana = y} per second

    local function ensure(u, abil)
        if GetUnitAbilityLevel(u, abil) == 0 then
            UnitAddAbility(u, abil)
            UnitMakeAbilityPermanent(u, true, abil)
        end
        return BlzGetUnitAbility(u, abil)
    end

    local function refreshAbility(u, abil)
        IncUnitAbilityLevel(u, abil)
        DecUnitAbilityLevel(u, abil)
    end

    local function setInt(u, abil, field, value)
        BlzSetAbilityIntegerLevelField(ensure(u, abil), field, 0, value)
        refreshAbility(u, abil)
    end

    function S.refresh(u)
        if not U.alive(u) then
            -- a dead hero keeps its changed max life and mana: reconcile on revival
            regen[u] = nil
            if applied[u] and IsUnitType(u, UNIT_TYPE_HERO) then
                applied[u].pending = true
            else
                applied[u] = nil
            end
            return
        end
        if applied[u] then applied[u].pending = nil end
        local M = use("mods")
        local a = applied[u]
        if not a then
            a = {}
            applied[u] = a
        end
        local function changed(key, value)
            if a[key] ~= value then
                a[key] = value
                return true
            end
            return false
        end

        local armor = math.floor(M.sum(u, "armor") + 0.5)
        if changed("armor", armor) then setInt(u, ARMOR, ABILITY_ILF_DEFENSE_BONUS_IDEF, armor) end

        local dmg = math.floor(M.sum(u, "damage") + 0.5)
        if changed("damage", dmg) then setInt(u, DAMAGE, ABILITY_ILF_ATTACK_BONUS, dmg) end

        local as = M.sum(u, "attack_speed") / 100
        if changed("aspeed", as) then
            BlzSetAbilityRealLevelField(ensure(u, ASPEED), ABILITY_RLF_ATTACK_SPEED_INCREASE_ISX1, 0, as)
            refreshAbility(u, ASPEED)
        end

        -- max life and mana move by the difference to what was applied before:
        -- item bonus abilities ignore field changes after they are added
        local hp = math.floor(M.sum(u, "max_hp") + 0.5)
        local dhp = hp - (a.hp or 0)
        if dhp ~= 0 then
            a.hp = hp
            local pct = GetWidgetLife(u) / math.max(1, BlzGetUnitMaxHP(u))
            BlzSetUnitMaxHP(u, math.max(1, BlzGetUnitMaxHP(u) + dhp))
            SetWidgetLife(u, math.max(1, pct * BlzGetUnitMaxHP(u)))
        end

        local mana = math.floor(M.sum(u, "max_mana") + 0.5)
        local dmana = mana - (a.mana or 0)
        if dmana ~= 0 then
            a.mana = mana
            local pct = GetUnitState(u, UNIT_STATE_MANA) / math.max(1, BlzGetUnitMaxMana(u))
            BlzSetUnitMaxMana(u, math.max(0, BlzGetUnitMaxMana(u) + dmana))
            SetUnitState(u, UNIT_STATE_MANA, pct * BlzGetUnitMaxMana(u))
        end

        if IsUnitType(u, UNIT_TYPE_HERO) then
            local str = math.floor(M.sum(u, "str") + 0.5)
            local agi = math.floor(M.sum(u, "agi") + 0.5)
            local int = math.floor(M.sum(u, "int") + 0.5)
            if changed("str", str) or changed("agi", agi) or changed("int", int) then
                local ab = ensure(u, ATTR)
                BlzSetAbilityIntegerLevelField(ab, ABILITY_ILF_STRENGTH_BONUS_ISTR, 0, str)
                BlzSetAbilityIntegerLevelField(ab, ABILITY_ILF_AGILITY_BONUS, 0, agi)
                BlzSetAbilityIntegerLevelField(ab, ABILITY_ILF_INTELLIGENCE_BONUS, 0, int)
                refreshAbility(u, ATTR)
            end
        end

        local base = GetUnitDefaultMoveSpeed(u)
        local ms = U.clamp((base + M.sum(u, "move_flat")) * (1 + M.sum(u, "move_pct")), 100, 550)
        if M.flag(u, "hex") then ms = 140 end
        if changed("ms", ms) then SetUnitMoveSpeed(u, ms) end

        local hpr, mpr = M.sum(u, "hp_regen") * (1 + M.sum(u, "heal_amp")), M.sum(u, "mana_regen")
        if hpr ~= 0 or mpr ~= 0 then
            regen[u] = {hp = hpr, mana = mpr}
        else
            regen[u] = nil
        end
    end

    function S.init()
        local STEP = 0.25
        Timer.every(STEP, function()
            local revived = {}
            for u, a in pairs(applied) do
                if a.pending and U.alive(u) then revived[#revived + 1] = u end
            end
            for _, u in ipairs(revived) do S.refresh(u) end
            for u, r in pairs(regen) do
                if U.alive(u) then
                    if r.hp ~= 0 then SetWidgetLife(u, GetWidgetLife(u) + r.hp * STEP) end
                    if r.mana ~= 0 then
                        SetUnitState(u, UNIT_STATE_MANA, GetUnitState(u, UNIT_STATE_MANA) + r.mana * STEP)
                    end
                end
            end
        end)
    end

    return S
end)
