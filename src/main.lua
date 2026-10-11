-- Map entry points. WC3 calls config() while building the lobby and main()
-- when the game starts. Slot layout:
--   0..4  user slots, force "Dota" (hero players; empty slots get bots)
--   5     user slot, force "Warcraft"
--   6     computer "The Ancients": Dota lane creeps
--   7     computer "Warcraft AI": plays Warcraft when no human does
--   8     computer "Horde": the Warcraft player's uncontrollable creep waves
--   10    outside the lobby: the Dota buildings, left alone by the neutral
--         camps that lane creeps fight (roles.lua)
PLAYER_COUNT = 9
SLOT_DOTA_MAX = 4
SLOT_WARCRAFT = 5
SLOT_ANCIENTS = 6
SLOT_WARCRAFT_AI = 7
SLOT_HORDE = 8
SLOT_BUILDINGS = 10

local function startLocations()
    local m = use("data.mapdata")
    local f, s = m.dota.fountain, m.warcraft.start
    return {
        [0] = f, [1] = f, [2] = f, [3] = f, [4] = f,
        [5] = s, [6] = m.dota.ancient, [7] = s, [8] = s,
    }
end

function config()
    SetMapName("Dota vs Warcraft")
    SetMapDescription("Up to five Dota 2 heroes against one Warcraft III player.")
    SetPlayers(PLAYER_COUNT)
    SetTeams(PLAYER_COUNT)
    SetGamePlacement(MAP_PLACEMENT_TEAMS_TOGETHER)

    local starts = startLocations()
    for i = 0, PLAYER_COUNT - 1 do
        DefineStartLocation(i, starts[i].x, starts[i].y)
    end

    for i = 0, PLAYER_COUNT - 1 do
        local p = Player(i)
        SetPlayerStartLocation(p, i)
        -- without it WC3 deals start locations at random, as in melee, and the
        -- Warcraft AI may take a start away from its hall and mine
        ForcePlayerStartLocation(p, i)
        SetPlayerColor(p, ConvertPlayerColor(i))
        if i <= SLOT_WARCRAFT then
            SetPlayerController(p, MAP_CONTROL_USER)
            SetPlayerRaceSelectable(p, true)
            SetPlayerRacePreference(p, RACE_PREF_RANDOM)
        else
            SetPlayerController(p, MAP_CONTROL_COMPUTER)
            SetPlayerRaceSelectable(p, false)
            SetPlayerRacePreference(p, i == SLOT_ANCIENTS and RACE_PREF_NIGHTELF or RACE_PREF_RANDOM)
        end
    end

    -- Lobby teams: 0 = Dota (slots 0-4 and the Ancients), 1 = Warcraft side
    for i = 0, PLAYER_COUNT - 1 do
        local team = (i <= SLOT_DOTA_MAX or i == SLOT_ANCIENTS) and 0 or 1
        SetPlayerTeam(Player(i), team)
    end
end

function main()
    local m = use("data.mapdata")
    local b = m.bounds
    SetCameraBounds(b.min + 512, b.min + 256, b.max - 512, b.max - 256,
                    b.min + 512, b.max - 256, b.max - 512, b.min + 256)
    SetDayNightModels("Environment\\DNC\\DNCLordaeron\\DNCLordaeronTerrain\\DNCLordaeronTerrain.mdl",
                      "Environment\\DNC\\DNCLordaeron\\DNCLordaeronUnit\\DNCLordaeronUnit.mdl")
    NewSoundEnvironment("Default")
    SetAmbientDaySound("LordaeronSummerDay")
    SetAmbientNightSound("LordaeronSummerNight")
    SetMapMusic("Music", true, 0)
    InitBlizzard()
    -- All mod code runs from a timer once loading has finished.
    TimerStart(CreateTimer(), 0.0, false, function()
        use("safe").call(function()
            use("game").start()
        end)
    end)
end
