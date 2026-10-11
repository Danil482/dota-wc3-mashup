-- The Commander: a full Warcraft III race started at the top-right base with
-- the stock melee starting units, gold mines and resources, and for the AI
-- commander a starter base (commander_base.lua). Research done by the
-- commander is mirrored onto the Horde slot so it also strengthens the
-- uncontrollable creep waves. Without a human commander the computer slot
-- plays with Blizzard's melee AI for the chosen race.
define("commander", function()
    local Log = use("log")
    local Events = use("events")
    local Timer = use("timer")
    local Roles = use("roles")
    local U = use("util")
    local Base = use("commander_base")
    local Cmd = {raceKey = nil, player = nil, hall = nil, starters = 0, starterTarget = 0}

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

    local function unitsOf(p)
        local out = {}
        local g = CreateGroup()
        GroupEnumUnitsOfPlayer(g, p, nil)
        for i = 0, BlzGroupGetSize(g) - 1 do
            local u = BlzGroupUnitAt(g, i)
            if U.alive(u) then out[#out + 1] = u end
        end
        DestroyGroup(g)
        return out
    end

    -- The hall the melee starting units made (a Night Elf Tree of Life stands
    -- by the mine, not on the start), or the start itself.
    local function findHall(p, start)
        local best, bestD = nil, math.huge
        for _, u in ipairs(unitsOf(p)) do
            local d = U.dist(GetUnitX(u), GetUnitY(u), start.x, start.y)
            if isHall[GetUnitTypeId(u)] and d < bestD then best, bestD = u, d end
        end
        if not best then
            return {x = start.x, y = start.y, half = Base.HALL_HALF}
        end
        local half = GetUnitTypeId(best) == FourCC("etol") and 192 or Base.HALL_HALF
        return {x = GetUnitX(best), y = GetUnitY(best), half = half, unit = best}
    end

    local function siteOf(hall, mines)
        local m = use("data.mapdata")
        local near, nearD = nil, math.huge
        for _, pos in ipairs(mines) do
            local d = U.dist(pos.x, pos.y, hall.x, hall.y)
            if d < nearD then near, nearD = pos, d end
        end
        local lanes = {}
        for lane in pairs(m.commander.spawns) do lanes[#lanes + 1] = lane end
        table.sort(lanes)
        local exits = {}
        for _, lane in ipairs(lanes) do exits[#exits + 1] = m.commander.spawns[lane] end
        return {
            hall = hall, mine = near, mines = mines, exits = exits, bounds = m.bounds.max,
            front = math.atan(m.dota.ancient.y - hall.y, m.dota.ancient.x - hall.x),
        }
    end

    ---------------------------------------------------------------- diagnostics
    -- Test builds log the AI player's setup once and a summary every 30 s, so
    -- one in-game test shows whether the melee AI runs and what it does.
    local CONTROL = {
        {MAP_CONTROL_USER, "user"}, {MAP_CONTROL_COMPUTER, "computer"}, {MAP_CONTROL_RESCUABLE, "rescuable"},
        {MAP_CONTROL_NEUTRAL, "neutral"}, {MAP_CONTROL_CREEP, "creep"}, {MAP_CONTROL_NONE, "none"},
    }
    local SLOT = {
        {PLAYER_SLOT_STATE_PLAYING, "playing"}, {PLAYER_SLOT_STATE_EMPTY, "empty"}, {PLAYER_SLOT_STATE_LEFT, "left"},
    }
    local DIFFICULTY = {{AI_DIFFICULTY_NEWBIE, "easy"}, {AI_DIFFICULTY_NORMAL, "normal"}, {AI_DIFFICULTY_INSANE, "insane"}}
    local function label(value, list)
        for _, e in ipairs(list) do
            if value == e[1] then return e[2] end
        end
        return "?"
    end

    -- what the commander's units were told to do since the melee AI started
    local activity = {orders = 0, builds = 0, trained = 0}
    local reported = {orders = 0, builds = 0, trained = 0}
    Cmd.activity = activity

    function Cmd.aiActivity()
        return activity.orders + activity.builds + activity.trained
    end

    local function watchActivity(p)
        local function mine(u) return u and GetOwningPlayer(u) == p end
        Events.on("order", function(u) if mine(u) then activity.orders = activity.orders + 1 end end)
        Events.on("construct_start", function(u) if mine(u) then activity.builds = activity.builds + 1 end end)
        Events.on("trained", function(u) if mine(u) then activity.trained = activity.trained + 1 end end)
    end

    local function snapshot(p, hall, site)
        local start = use("data.mapdata").commander.start
        local k = GetPlayerStartLocation(p)
        local sx, sy = GetStartLocationX(k), GetStartLocationY(k)
        local off = U.dist(sx, sy, start.x, start.y)
        local control, slot = label(GetPlayerController(p), CONTROL), label(GetPlayerSlotState(p), SLOT)
        Log.info(string.format("commander AI %d: %s, slot %s, name '%s', race %s, difficulty %s, "
            .. "start location %d at %.0f,%.0f (%.0f from the base)", GetPlayerId(p), control, slot,
            GetPlayerName(p), Cmd.raceKey, label(GetAIDifficulty(p), DIFFICULTY), k, sx, sy, off))
        -- without ForcePlayerStartLocation the lobby deals start locations at
        -- random, as in melee: then slot and start location numbers differ
        local starts, slots = {}, {}
        for i = 0, PLAYER_COUNT - 1 do
            local q = Player(i)
            starts[#starts + 1] = i .. ">" .. GetPlayerStartLocation(q)
            if GetPlayerController(q) ~= MAP_CONTROL_USER or GetPlayerSlotState(q) == PLAYER_SLOT_STATE_PLAYING then
                slots[#slots + 1] = i .. " " .. label(GetPlayerController(q), CONTROL) .. "/"
                    .. label(GetPlayerSlotState(q), SLOT)
            end
        end
        Log.info("commander AI: start location by slot " .. table.concat(starts, " ")
            .. "; slots " .. table.concat(slots, ", "))
        Log.info(string.format("commander base: hall %s at %.0f,%.0f, mine %.0f away, starter base %d of %d",
            hall.unit and string.pack(">I4", GetUnitTypeId(hall.unit)) or "none", hall.x, hall.y,
            site.mine and U.dist(hall.x, hall.y, site.mine.x, site.mine.y) or -1, Cmd.starters, Cmd.starterTarget))
        if control ~= "computer" or slot ~= "playing" then
            Log.warn("commander AI: slot " .. GetPlayerId(p) .. " is not a playing computer, the melee AI cannot run")
        end
        if off > 600 then
            Log.warn(string.format("commander AI: its start location is %.0f from its base; "
                .. "the melee AI builds around its start location", off))
        end
    end

    local HARVEST, REPAIR = {}, OrderId("repair")
    for _, name in ipairs({"harvest", "returnresources", "resumeharvesting"}) do HARVEST[OrderId(name)] = true end

    function Cmd.summary()
        local p = Cmd.player
        local workers, harvest, build, idle, other, otherName = 0, 0, 0, 0, 0, nil
        local structures, army, heroes = 0, 0, 0
        for _, u in ipairs(unitsOf(p)) do
            if IsUnitType(u, UNIT_TYPE_STRUCTURE) then
                structures = structures + 1
            elseif IsUnitType(u, UNIT_TYPE_PEON) then
                workers = workers + 1
                local o = GetUnitCurrentOrder(u)
                if o == 0 then
                    idle = idle + 1
                elseif HARVEST[o] then
                    harvest = harvest + 1
                elseif o >= 0x1000000 or o == REPAIR then      -- build orders carry the structure's type id
                    build = build + 1
                else
                    other, otherName = other + 1, OrderId2String(o)
                end
            elseif IsUnitType(u, UNIT_TYPE_HERO) then
                heroes = heroes + 1
            else
                army = army + 1
            end
        end
        local line = string.format("commander AI: gold %d, lumber %d, food %d/%d, workers %d (harvest %d, build %d, "
            .. "idle %d, other %d%s), structures %d (%d unfinished), army %d, heroes %d, "
            .. "AI orders +%d, builds +%d, trained +%d",
            GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD), GetPlayerState(p, PLAYER_STATE_RESOURCE_LUMBER),
            GetPlayerState(p, PLAYER_STATE_RESOURCE_FOOD_USED), GetPlayerState(p, PLAYER_STATE_RESOURCE_FOOD_CAP),
            workers, harvest, build, idle, other, otherName and (" " .. otherName) or "",
            structures, GetPlayerStructureCount(p, true) - GetPlayerStructureCount(p, false), army, heroes,
            activity.orders - reported.orders, activity.builds - reported.builds, activity.trained - reported.trained)
        reported.orders, reported.builds, reported.trained = activity.orders, activity.builds, activity.trained
        return line
    end

    local function diagnose(p, hall, site)
        snapshot(p, hall, site)
        Timer.after(20, function()
            if Cmd.aiActivity() == 0 then
                Log.warn("commander AI: no orders, construction or training in 20 s, the melee AI is not running")
            end
        end)
        Timer.every(30, function()
            Log.info(Cmd.summary())
        end)
    end

    ---------------------------------------------------------------- setup
    local function startAI(p)
        StartMeleeAI(p, AI_SCRIPT[Cmd.raceKey])
        -- as Blizzard's MeleeStartingAI does: the undead AI may use its starting ghoul
        if Cmd.raceKey == "undead" then
            for _, u in ipairs(unitsOf(p)) do
                if GetUnitTypeId(u) == FourCC("ugho") then RecycleGuardPosition(u) end
            end
        end
    end

    -- raceKey: optional override ("human", "orc", "undead", "nightelf")
    function Cmd.setup(raceKey)
        for _, code in ipairs(HALLS) do isHall[FourCC(code)] = true end
        local p = Player(Roles.commander)
        Cmd.player = p
        Cmd.raceKey = raceKey or raceKeyOf(GetPlayerRace(p))
        local m = use("data.mapdata").commander
        local mines = {}
        for _, pos in ipairs(m.mines) do
            local u = CreateUnit(Player(PLAYER_NEUTRAL_PASSIVE), FourCC("ngol"), pos.x, pos.y, 270)
            mines[#mines + 1] = {x = GetUnitX(u), y = GetUnitY(u)}
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

        local hall = findHall(p, m.start)
        local site = siteOf(hall, mines)
        Cmd.hall = hall
        if Base.enabled(Roles.commanderIsAI) then
            Cmd.starterTarget = Base.count(Cmd.raceKey)
            Cmd.starters = #Base.build(p, Cmd.raceKey, site)
        end
        SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, 750)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_LUMBER, 300)
        if Roles.commanderIsAI then
            if BUILD_TEST_MODE then watchActivity(p) end
            startAI(p)
            if BUILD_TEST_MODE then diagnose(p, hall, site) end
        end

        Events.on("research_finish", function(u, tech)
            if GetOwningPlayer(u) == p then
                SetPlayerTechResearched(Player(SLOT_HORDE), tech, GetPlayerTechCount(p, tech, true))
            end
        end)
        Log.info("commander " .. GetPlayerId(p) .. " plays " .. Cmd.raceKey .. (Roles.commanderIsAI and " (AI)" or "")
            .. ", starter base " .. Cmd.starters .. " of " .. Cmd.starterTarget)
    end

    -- Town halls (any tier, finished or under construction) the commander owns.
    function Cmd.halls()
        local n = 0
        for _, u in ipairs(unitsOf(Cmd.player)) do
            if isHall[GetUnitTypeId(u)] then n = n + 1 end
        end
        return n
    end

    return Cmd
end)
