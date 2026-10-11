-- Who plays what. Any of the six user slots can end up a hero player or the
-- Warcraft player: a human in the Warcraft slot plays Warcraft, a lone human
-- may choose to, otherwise a computer that is in the game does (aiSlot).
-- Every hero slot without a human gets a bot.
define("roles", function()
    local Log = use("log")
    local Roles = {
        humans = {},        -- slot -> true
        heroSlots = {},     -- ordered list of slots that field a Dota hero
        warcraft = nil,     -- slot owning the Warcraft base
        warcraftIsAI = false,
    }

    local function isHuman(i)
        local p = Player(i)
        return GetPlayerController(p) == MAP_CONTROL_USER
            and GetPlayerSlotState(p) == PLAYER_SLOT_STATE_PLAYING
    end

    local function isPlayingComputer(i)
        local p = Player(i)
        return GetPlayerController(p) == MAP_CONTROL_COMPUTER
            and GetPlayerSlotState(p) == PLAYER_SLOT_STATE_PLAYING
    end

    -- The melee AI runs only for a computer that is in the game. A game
    -- started straight from the map leaves the "Warcraft AI" slot empty and
    -- puts its one computer into a user slot (slot 1), so that one plays.
    local function aiSlot()
        if isPlayingComputer(SLOT_WARCRAFT) then return SLOT_WARCRAFT end
        if isPlayingComputer(SLOT_WARCRAFT_AI) then return SLOT_WARCRAFT_AI end
        for i = 0, SLOT_WARCRAFT do
            if isPlayingComputer(i) then return i end
        end
        Log.warn("roles: no computer is playing, so the Warcraft AI takes the empty slot "
            .. SLOT_WARCRAFT_AI .. " and its melee AI cannot run")
        return SLOT_WARCRAFT_AI
    end

    function Roles.detect()
        local count, only = 0, nil
        for i = 0, SLOT_WARCRAFT do
            if isHuman(i) then
                Roles.humans[i] = true
                count, only = count + 1, i
            end
        end
        Roles.humanCount, Roles.soloSlot = count, (count == 1) and only or nil
        return count
    end

    -- soloWantsWarcraft: the lone human picked "Warcraft" in the role dialog
    function Roles.assign(soloWantsWarcraft)
        if Roles.humans[SLOT_WARCRAFT] then
            Roles.warcraft = SLOT_WARCRAFT
        elseif soloWantsWarcraft and Roles.soloSlot then
            Roles.warcraft = Roles.soloSlot
        else
            Roles.warcraft = aiSlot()
            Roles.warcraftIsAI = true
        end
        Roles.heroSlots = {}
        for i = 0, SLOT_WARCRAFT do
            if i ~= Roles.warcraft and #Roles.heroSlots < 5 then
                Roles.heroSlots[#Roles.heroSlots + 1] = i
            end
        end
        Log.info("roles: warcraft=" .. Roles.warcraft .. (Roles.warcraftIsAI and " (AI)" or "")
            .. " heroes=" .. table.concat(Roles.heroSlots, ","))
    end

    function Roles.isBot(slot)
        return not Roles.humans[slot]
    end

    -- A slot that fields a Dota hero (human or bot), not the computer slots.
    function Roles.isHeroSlot(slot)
        for i = 1, #Roles.heroSlots do
            if Roles.heroSlots[i] == slot then return true end
        end
        return false
    end

    function Roles.side(slot)
        if slot == SLOT_ANCIENTS or slot == SLOT_BUILDINGS then
            return "dota"
        end
        if slot == Roles.warcraft or slot == SLOT_HORDE or slot == SLOT_WARCRAFT_AI then
            return "warcraft"
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

    -- Every slot of the game: the lobby's and the buildings' outside it.
    function Roles.slots()
        local out = {}
        for i = 0, PLAYER_COUNT - 1 do out[#out + 1] = i end
        out[#out + 1] = SLOT_BUILDINGS
        return out
    end

    function Roles.setupAlliances()
        local slots = Roles.slots()
        for _, a in ipairs(slots) do
            for _, b in ipairs(slots) do
                if a ~= b then
                    local sa, sb = Roles.side(a), Roles.side(b)
                    local allied = sa ~= "none" and sa == sb
                    for _, kind in ipairs(ALLIANCES) do
                        SetPlayerAlliance(Player(a), Player(b), kind, allied)
                    end
                end
            end
        end
        -- The buildings' slot is outside the lobby: it looks like the Ancients
        -- and leaves the other players outside the lobby (the test dummies) alone.
        local buildings = Player(SLOT_BUILDINGS)
        SetPlayerColor(buildings, GetPlayerColor(Player(SLOT_ANCIENTS)))
        SetPlayerName(buildings, GetPlayerName(Player(SLOT_ANCIENTS)))
        for i = PLAYER_COUNT, bj_MAX_PLAYERS - 1 do
            if i ~= SLOT_BUILDINGS then
                SetPlayerAlliance(buildings, Player(i), ALLIANCE_PASSIVE, true)
                SetPlayerAlliance(Player(i), buildings, ALLIANCE_PASSIVE, true)
            end
        end
        -- Neutral hostile creeps (jungle, Roshan) fight every player but the
        -- buildings' owner: as in Dota, towers leave the jungle alone and
        -- neutrals leave the buildings alone, while lane creeps of both sides
        -- fight neutrals, so a camp can be pulled into a lane wave
        for _, a in ipairs(slots) do
            local leaveAlone = a == SLOT_BUILDINGS
            SetPlayerAlliance(Player(PLAYER_NEUTRAL_AGGRESSIVE), Player(a), ALLIANCE_PASSIVE, leaveAlone)
            SetPlayerAlliance(Player(a), Player(PLAYER_NEUTRAL_AGGRESSIVE), ALLIANCE_PASSIVE, leaveAlone)
        end
    end

    return Roles
end)
