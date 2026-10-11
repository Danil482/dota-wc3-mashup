-- Game orchestration: runs once from main() after InitBlizzard().
define("game", function()
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Roles = use("roles")
    local Game = {}

    local function begin(raceKey)
        -- hero modules register their abilities when first used
        for key in pairs(use("data.heroes")) do
            if defined("hero_" .. key) then
                use("safe").call(function() use("hero_" .. key) end)
            end
        end
        local Cmd = use("commander")
        Cmd.setup(raceKey)
        use("structures").create()
        use("items").init()
        use("inventory").init()             -- backpack, stash, TP slot; purchases go to the hero, the stash or the fountain
        use("talents").init()               -- talents, Attribute Bonus, Aghanim's Scepter and Shard
        use("economy").init()
        use("victory").init()
        use("heroes").init()
        use("voice").init()
        use("safe").call(function() use("gamesounds").init() end)   -- Dota's coins, denies, level-ups, rune and Aegis sounds
        use("safe").call(function() use("music").init() end)        -- Dota music for Dota players; the commander keeps Warcraft's
        use("hero_bot").init()
        use("cheats").init()
        use("dummy").init()
        use("safe").call(function() use("courier").init() end)   -- one courier per human Dota player
        use("heroes").pickAll(function()
            Log.info("all heroes picked")
        end)
        use("creeps").start(Cmd.raceKey)
        use("safe").call(function() use("announcer").init() end)    -- right after creeps.start: the horn sounds with the first wave
        use("lane").init()                  -- denies, aggro, day and night from the horn, Glyph, Scan, buyback
        use("world").init()                 -- world clock 0:00; first lane wave at 0:30
        use("safe").call(function() use("dota_hud").init() end)   -- Dota HUD and shop for hero players
        use("safe").call(function() use("dota_talents").init() end)   -- talent tree and Aghanim's sign by the ability row
        use("safe").call(function() use("dota_glyph").init() end)   -- Glyph, Scan and buyback buttons by the minimap
        use("safe").call(function() use("dota_settings").init() end)   -- Dota players' own keys and settings
        use("safe").call(function() use("controls_probe").run() end)   -- test builds: which trigger orders the engine takes (controls_probe.txt)
        if BUILD_TEST_MODE then
            use("autotest").run()
        end
        Log.flush()
    end

    -- A lone human chooses a side; everyone else uses the lobby slots.
    local function chooseRole(done)
        if BUILD_TEST_MODE or Roles.humanCount ~= 1 or Roles.soloSlot == SLOT_COMMANDER then
            done(BUILD_TEST_MODE and AUTOTEST_ROLE == "commander", nil)
            return
        end
        local p = Player(Roles.soloSlot)
        local d = DialogCreate()
        DialogSetMessage(d, "Play as")
        local hero = DialogAddButton(d, "A Dota hero (with bot teammates)", 0)
        local races = {
            [DialogAddButton(d, "Commander: Human", 0)] = "human",
            [DialogAddButton(d, "Commander: Orc", 0)] = "orc",
            [DialogAddButton(d, "Commander: Undead", 0)] = "undead",
            [DialogAddButton(d, "Commander: Night Elf", 0)] = "nightelf",
        }
        local trig = CreateTrigger()
        TriggerRegisterDialogEvent(trig, d)
        TriggerAddAction(trig, function()
            use("safe").call(function()
                local b = GetClickedButton()
                DialogDisplay(p, d, false)
                DestroyTrigger(trig)
                if b == hero then
                    done(false, nil)
                else
                    done(true, races[b])
                end
            end)
        end)
        DialogDisplay(p, d, true)
    end

    function Game.start()
        Log.clock = Timer.now
        Log.debug = BUILD_TEST_MODE
        Log.ready = true
        Log.info("game start, test mode " .. tostring(BUILD_TEST_MODE))

        Events.init()
        use("mods").init()
        use("stats").init()
        use("damage").init()
        use("abilities").init()
        Roles.detect()
        Timer.every(5, function()
            Log.flush()
        end)
        -- Dialogs need the game to be running, so wait a moment.
        Timer.after(0.1, function()
            chooseRole(function(command, raceKey)
                Roles.assign(command)
                Roles.setupAlliances()
                begin(raceKey)
            end)
        end)
        Log.flush()
    end

    return Game
end)
