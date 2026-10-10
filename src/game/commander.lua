-- The Commander: a full Warcraft III race started at the top-right base with
-- the stock melee starting units, gold mines and resources. Research done by
-- the commander is mirrored onto the Horde slot so it also strengthens the
-- uncontrollable creep waves. Without a human commander the computer slot
-- plays with Blizzard's melee AI for the chosen race.
define("commander", function()
    local Log = use("log")
    local Events = use("events")
    local Roles = use("roles")
    local Cmd = {raceKey = nil, player = nil}

    local HALLS = {
        "htow", "hkee", "hcas", "ogre", "ostr", "ofrt", "unpl", "unp1", "unp2", "etol", "etoa", "etoe",
    }
    local isHall = {}

    local function raceKeyOf(race)
        if race == RACE_ORC then return "orc" end
        if race == RACE_UNDEAD then return "undead" end
        if race == RACE_NIGHTELF then return "nightelf" end
        return "human"
    end

    local AI_SCRIPT = {human = "human.ai", orc = "orc.ai", undead = "undead.ai", nightelf = "elf.ai"}

    -- raceKey: optional override ("human", "orc", "undead", "nightelf")
    function Cmd.setup(raceKey)
        for _, code in ipairs(HALLS) do isHall[FourCC(code)] = true end
        local p = Player(Roles.commander)
        Cmd.player = p
        Cmd.raceKey = raceKey or raceKeyOf(GetPlayerRace(p))
        local m = use("data.mapdata").commander
        for _, pos in ipairs(m.mines) do
            CreateUnit(Player(PLAYER_NEUTRAL_PASSIVE), FourCC("ngol"), pos.x, pos.y, 270)
        end
        for _, pos in ipairs(m.expansions) do
            CreateUnit(Player(PLAYER_NEUTRAL_PASSIVE), FourCC("ngol"), pos.x, pos.y, 270)
        end
        local loc = Location(m.start.x, m.start.y)
        local starters = {
            human = MeleeStartingUnitsHuman, orc = MeleeStartingUnitsOrc,
            undead = MeleeStartingUnitsUndead, nightelf = MeleeStartingUnitsNightElf,
        }
        starters[Cmd.raceKey](p, loc, false, GetLocalPlayer() == p, true)
        RemoveLocation(loc)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, 750)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_LUMBER, 300)
        if Roles.commanderIsAI then
            StartMeleeAI(p, AI_SCRIPT[Cmd.raceKey])
        end

        Events.on("research_finish", function(u, tech)
            if GetOwningPlayer(u) == p then
                SetPlayerTechResearched(Player(SLOT_HORDE), tech, GetPlayerTechCount(p, tech, true))
            end
        end)
        Log.info("commander " .. GetPlayerId(p) .. " plays " .. Cmd.raceKey .. (Roles.commanderIsAI and " (AI)" or ""))
    end

    -- Town halls (any tier, finished or under construction) the commander owns.
    function Cmd.halls()
        local n = 0
        local g = CreateGroup()
        GroupEnumUnitsOfPlayer(g, Cmd.player, nil)
        local size = BlzGroupGetSize(g)
        for i = 0, size - 1 do
            local u = BlzGroupUnitAt(g, i)
            if isHall[GetUnitTypeId(u)] and not IsUnitType(u, UNIT_TYPE_DEAD) then n = n + 1 end
        end
        DestroyGroup(g)
        return n
    end

    return Cmd
end)
