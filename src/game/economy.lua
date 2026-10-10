-- Gold and experience the Dota way: passive gold for hero players, last-hit
-- bounties, shared XP for heroes near a death. Native WC3 XP is switched off
-- in gameplay constants, so the commander's own heroes get XP here as well.
define("economy", function()
    local Events = use("events")
    local Timer = use("timer")
    local Roles = use("roles")
    local U = use("util")
    local E = {}

    local CREEP_GOLD = {dota_melee = 36, dota_ranged = 45, dota_siege = 73}
    local CREEP_XP = {dota_melee = 57, dota_ranged = 69, dota_siege = 88}
    local XP_RANGE = 1500

    local creepKey = {}

    local function lookup()
        for key, code in pairs(use("data.ids").units) do
            local side, kind = key:match("^(%a+)_(%a+)$")
            if side and side ~= "rax" and CREEP_GOLD["dota_" .. kind] then
                creepKey[FourCC(code)] = "dota_" .. kind
            end
        end
    end

    local function addGold(p, amount)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD) + math.floor(amount))
    end

    local function bountyText(u, amount)
        local t = CreateTextTag()
        SetTextTagText(t, "+" .. math.floor(amount), 0.023)
        SetTextTagPos(t, GetUnitX(u), GetUnitY(u), 60)
        SetTextTagColor(t, 255, 220, 0, 255)
        SetTextTagVelocity(t, 0, 0.03)
        SetTextTagPermanent(t, false)
        SetTextTagLifespan(t, 2)
        SetTextTagFadepoint(t, 1)
    end

    local function valueOf(dying)
        local wg, wx = use("world").bountyOf(dying)
        if wg then return wg, wx end
        local key = creepKey[GetUnitTypeId(dying)]
        if key then return CREEP_GOLD[key], CREEP_XP[key] end
        if IsUnitType(dying, UNIT_TYPE_HERO) then
            local lvl = GetHeroLevel(dying)
            return 110 + 8 * lvl, 100 + 25 * lvl
        end
        if IsUnitType(dying, UNIT_TYPE_STRUCTURE) then
            return 150, 0
        end
        local lvl = GetUnitLevel(dying)
        return 10 + 8 * lvl, 20 + 15 * lvl
    end

    local function shareXp(dying, xp, side)
        local x, y = GetUnitX(dying), GetUnitY(dying)
        local heroes = U.enum(x, y, XP_RANGE, function(u)
            return IsUnitType(u, UNIT_TYPE_HERO) and Roles.side(GetPlayerId(GetOwningPlayer(u))) == side
        end)
        if #heroes == 0 then return end
        for _, h in ipairs(heroes) do
            AddHeroXP(h, math.floor(xp / #heroes), true)
        end
    end

    function E.init()
        lookup()
        Timer.every(0.6, function()
            for _, slot in ipairs(Roles.heroSlots) do
                addGold(Player(slot), 1)
            end
        end)
        Events.on("death", function(dying, killer)
            if not killer then return end
            local deadSide = Roles.side(GetPlayerId(GetOwningPlayer(dying)))
            local killerSlot = GetPlayerId(GetOwningPlayer(killer))
            local killerSide = Roles.side(killerSlot)
            if killerSide == "none" or killerSide == deadSide then return end
            local gold, xp = valueOf(dying)
            if killerSide == "dota" then
                -- last hits by hero players (towers and creeps earn nothing)
                if killerSlot ~= SLOT_ANCIENTS then
                    addGold(GetOwningPlayer(killer), gold)
                    bountyText(dying, gold)
                end
            elseif killerSide == "commander" then
                -- The commander earns half the bounty for anything his side kills
                addGold(Player(use("roles").commander), gold * 0.5)
            end
            if xp > 0 then shareXp(dying, xp, killerSide) end
        end)
    end

    return E
end)
