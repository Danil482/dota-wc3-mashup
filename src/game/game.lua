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
        use("economy").init()
        use("victory").init()
        use("heroes").init()
        use("voice").init()
        use("hero_bot").init()
        use("cheats").init()
        use("dummy").init()
        use("heroes").pickAll(function()
            Log.info("all heroes picked")
        end)
        use("creeps").start(Cmd.raceKey)
        use("world").init()                 -- world clock 0:00; first lane wave at 0:30
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
