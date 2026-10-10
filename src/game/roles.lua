-- Who plays what. Any of the six user slots can end up a hero player or the
-- commander: a human in the commander slot commands, a lone human may choose
-- to command, otherwise the "Commander AI" computer slot does. Every hero
-- slot without a human gets a bot.
define("roles", function()
    local Log = use("log")
    local Roles = {
        humans = {},        -- slot -> true
        heroSlots = {},     -- ordered list of slots that field a Dota hero
        commander = nil,    -- slot owning the commander's base
        commanderIsAI = false,
    }

    local function isHuman(i)
        local p = Player(i)
        return GetPlayerController(p) == MAP_CONTROL_USER
            and GetPlayerSlotState(p) == PLAYER_SLOT_STATE_PLAYING
    end

    function Roles.detect()
        local count, only = 0, nil
        for i = 0, SLOT_COMMANDER do
            if isHuman(i) then
                Roles.humans[i] = true
                count, only = count + 1, i
            end
        end
        Roles.humanCount, Roles.soloSlot = count, (count == 1) and only or nil
        return count
    end

    -- soloWantsCommand: the lone human picked "Commander" in the role dialog
    function Roles.assign(soloWantsCommand)
        if Roles.humans[SLOT_COMMANDER] then
            Roles.commander = SLOT_COMMANDER
        elseif soloWantsCommand and Roles.soloSlot then
            Roles.commander = Roles.soloSlot
        else
            Roles.commander = SLOT_COMMANDER_AI
            Roles.commanderIsAI = true
        end
        Roles.heroSlots = {}
        for i = 0, SLOT_COMMANDER do
            if i ~= Roles.commander and #Roles.heroSlots < 5 then
                Roles.heroSlots[#Roles.heroSlots + 1] = i
            end
        end
        Log.info("roles: commander=" .. Roles.commander .. (Roles.commanderIsAI and " (AI)" or "")
            .. " heroes=" .. table.concat(Roles.heroSlots, ","))
    end

    function Roles.isBot(slot)
        return not Roles.humans[slot]
    end

    function Roles.side(slot)
        if slot == SLOT_ANCIENTS then
            return "dota"
        end
        if slot == Roles.commander or slot == SLOT_HORDE or slot == SLOT_COMMANDER_AI then
            return "commander"
        end
        for i = 1, #Roles.heroSlots do
            if Roles.heroSlots[i] == slot then
                return "dota"
            end
        end
        return "none"
    end

    function Roles.isDotaPlayer(p)
        return Roles.side(GetPlayerId(p)) == "dota"
    end

    local ALLIANCES = {
        ALLIANCE_PASSIVE, ALLIANCE_HELP_REQUEST, ALLIANCE_HELP_RESPONSE,
        ALLIANCE_SHARED_XP, ALLIANCE_SHARED_SPELLS, ALLIANCE_SHARED_VISION,
    }

    function Roles.setupAlliances()
        for a = 0, PLAYER_COUNT - 1 do
            for b = 0, PLAYER_COUNT - 1 do
                if a ~= b then
                    local sa, sb = Roles.side(a), Roles.side(b)
                    local allied = sa ~= "none" and sa == sb
                    for _, kind in ipairs(ALLIANCES) do
                        SetPlayerAlliance(Player(a), Player(b), kind, allied)
                    end
                end
            end
        end
        -- Neutral hostile creeps (jungle, Roshan) fight every player, except the
        -- owners of towers, buildings and lane creeps: as in Dota, towers and
        -- lane waves leave the jungle alone and neutrals leave them alone
        for a = 0, PLAYER_COUNT - 1 do
            local leaveAlone = a == SLOT_ANCIENTS or a == SLOT_HORDE
            SetPlayerAlliance(Player(PLAYER_NEUTRAL_AGGRESSIVE), Player(a), ALLIANCE_PASSIVE, leaveAlone)
            SetPlayerAlliance(Player(a), Player(PLAYER_NEUTRAL_AGGRESSIVE), ALLIANCE_PASSIVE, leaveAlone)
        end
    end

    return Roles
end)
