-- Immortal target dummies by the Dota fountain (test builds and solo games):
-- a hero dummy for hero-only spells, a creep dummy and an enemy caster that
-- storm-bolts nearby human heroes while -spells is on. They belong to their
-- own player slot that is hostile only to human hero players, so towers,
-- the fountain, creeps and bots leave them alone. Damage never kills them;
-- a floating counter shows the last hit and the damage per second.
define("dummy", function()
    local Timer = use("timer")
    local Roles = use("roles")
    local U = use("util")
    local D = {units = {}}

    local SLOT = 9
    local HERO = FourCC("Hpal")
    local CREEP = FourCC("hfoo")
    local CASTER = FourCC("Hmkg")
    local BOLT = FourCC("AHtb")
    local ATTACK = FourCC("Aatk")
    local BOLT_RANGE = 700

    local function setupAlliances()
        local p = Player(SLOT)
        for i = 0, PLAYER_COUNT - 1 do
            local friendly = not (Roles.humans[i] and Roles.side(i) == "dota")
            for _, kind in ipairs({ALLIANCE_PASSIVE, ALLIANCE_HELP_REQUEST, ALLIANCE_HELP_RESPONSE}) do
                SetPlayerAlliance(p, Player(i), kind, friendly)
                SetPlayerAlliance(Player(i), p, kind, friendly)
            end
        end
    end

    local function spawn(id, x, y, name, active)
        local u = CreateUnit(Player(SLOT), id, x, y, 45)
        if IsUnitType(u, UNIT_TYPE_HERO) then
            SetHeroLevel(u, 25, false)
            BlzSetHeroProperName(u, name)
        else
            BlzSetUnitName(u, name)
        end
        if active then
            BlzUnitDisableAbility(u, ATTACK, true, false)   -- casts, never attacks
        else
            BlzPauseUnitEx(u, true)             -- stands still, never attacks
        end
        local state = {unit = u, log = {}, tag = CreateTextTag()}
        SetTextTagPermanent(state.tag, true)
        SetTextTagColor(state.tag, 255, 210, 80, 255)
        D.units[u] = state
        return u
    end

    function D.toggleSpells()
        D.casting = not D.casting
        return D.casting
    end

    function D.init()
        if not use("cheats").enabled() then return end
        setupAlliances()
        local f = use("data.mapdata").dota.fountain
        spawn(HERO, f.x + 650, f.y + 250, "Target Dummy (hero)")
        spawn(CREEP, f.x + 250, f.y + 650, "Target Dummy (creep)")
        -- an enemy caster for spell blocks and reflects, switched by -spells
        local hx, hy = f.x + 900, f.y + 900
        local caster = spawn(CASTER, hx, hy, "Spell Caster (-spells)", true)
        SelectHeroSkill(caster, BOLT)
        BlzSetUnitAbilityCooldown(caster, BOLT, 0, 3)
        BlzSetAbilityRealLevelField(BlzGetUnitAbility(caster, BOLT), ABILITY_RLF_DURATION_HERO, 0, 1)
        D.caster = caster
        Timer.every(4, function()
            if not D.casting or not U.alive(caster) then return end
            local best, bestDist = nil, BOLT_RANGE
            for slot, h in pairs(use("heroes").bySlot) do
                local d = U.unitDist(caster, h)
                if Roles.humans[slot] and Roles.side(slot) == "dota" and U.alive(h) and d < bestDist then
                    best, bestDist = h, d
                end
            end
            if best then
                IssueTargetOrder(caster, "thunderbolt", best)
            elseif U.dist(GetUnitX(caster), GetUnitY(caster), hx, hy) > 150 then
                IssuePointOrder(caster, "move", hx, hy)
            end
        end)

        -- never lethal: cap each hit just below the remaining life
        use("damage").onDamaging(function(source, target, info)
            if D.units[target] and info.amount >= GetWidgetLife(target) - 1 then
                info.amount = math.max(0, GetWidgetLife(target) - 1)
            end
        end)
        use("damage").onDamaged(function(source, target, amount)
            local s = D.units[target]
            if s and amount > 0 then
                s.log[#s.log + 1] = {t = Timer.now(), amount = amount}
                s.last = amount
            end
        end)
        Timer.every(0.25, function()
            local now = Timer.now()
            for u, s in pairs(D.units) do
                local sum, keep = 0, {}
                for _, e in ipairs(s.log) do
                    if now - e.t <= 3 then
                        sum = sum + e.amount
                        keep[#keep + 1] = e
                    end
                end
                s.log = keep
                -- quiet for 3 s: full health and mana again
                if #keep == 0 then
                    SetWidgetLife(u, BlzGetUnitMaxHP(u))
                    SetUnitState(u, UNIT_STATE_MANA, BlzGetUnitMaxMana(u))
                end
                SetTextTagText(s.tag, string.format("last %d  |  DPS %d", math.floor(s.last or 0), math.floor(sum / 3)), 0.024)
                SetTextTagPos(s.tag, GetUnitX(u) - 120, GetUnitY(u), 220)
                if not U.alive(u) then ReviveHero(u, GetUnitX(u), GetUnitY(u), false) end
            end
        end)
    end

    return D
end)
