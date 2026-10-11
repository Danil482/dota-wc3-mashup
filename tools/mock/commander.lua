-- Offline exercise for the commander (src/game/commander.lua) and its starter
-- base (src/game/commander_base.lua). At 5 s of mock time it checks that the
-- AI commander's setup ran (starter structures created, the melee AI
-- started, the diagnostics summary builds), then plans every race's starter
-- base on the base layout, on a layout shaped like the personalized map's
-- (mine 700 units from the hall) and on cramped ground, and checks that no
-- structure overlaps the hall, the mine or another structure, stands on the
-- hall-to-mine path or an exit path, or covers unbuildable ground. Failed
-- checks become ERROR lines, which fail the mock run.
do
    local RACES = {"human", "orc", "undead", "nightelf"}

    local function dist(a, b)
        return math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
    end

    local function exercise()
        local Log = use("log")
        local B = use("commander_base")
        local Cmd = use("commander")
        local md = use("data.mapdata")
        local failures = 0
        local function check(name, ok, detail)
            if not ok then
                failures = failures + 1
                Log.error("commander exercise: " .. name .. (detail and (" - " .. tostring(detail)) or ""))
            end
        end

        -- the AI commander's setup in this mock game (slot 7, no human commander)
        check("AI commander", Cmd.player == Player(SLOT_COMMANDER_AI), Cmd.player and GetPlayerId(Cmd.player))
        check("melee AI started", (__mock.calls.StartMeleeAI or 0) == 1, __mock.calls.StartMeleeAI)
        check("starter base created", Cmd.starters == B.count(Cmd.raceKey) and Cmd.starters > 0,
            Cmd.starters .. " of " .. B.count(Cmd.raceKey))
        local made = 0
        for _, u in ipairs(__mock.units) do
            if u.owner == Cmd.player and B.HALF[string.pack(">I4", u.typeId)] then made = made + 1 end
        end
        check("starter structures owned by the commander", made == Cmd.starters, made)
        local line = Cmd.summary()
        check("summary", line:find("^commander AI: gold %d+, lumber %d+, food %d+/%d+, workers") ~= nil, line)
        check("starter base for the AI only", B.enabled(true) and not B.enabled(false))

        -- footprint checks, independent of commander_base's own geometry
        local function segDist(px, py, a, b)
            local dx, dy = b.x - a.x, b.y - a.y
            local t = math.max(0, math.min(1, ((px - a.x) * dx + (py - a.y) * dy) / (dx * dx + dy * dy)))
            return math.sqrt((a.x + t * dx - px) ^ 2 + (a.y + t * dy - py) ^ 2)
        end
        local function squareToSegment(s, a, b)
            local best = math.huge
            for i = 0, 8 do
                for j = 0, 8 do
                    if i == 0 or i == 8 or j == 0 or j == 8 then
                        local x, y = s.x - s.half + s.half * i / 4, s.y - s.half + s.half * j / 4
                        best = math.min(best, segDist(x, y, a, b))
                    end
                end
            end
            return best
        end
        local function apart(a, b, gap)
            local reach = a.half + b.half + gap
            return math.abs(a.x - b.x) >= reach or math.abs(a.y - b.y) >= reach
        end

        local function verify(tag, raceKey, site, blocked, expectAll)
            local plan = B.plan(raceKey, site)
            local name = tag .. " " .. raceKey
            if expectAll then
                check(name .. ": all placed", #plan == B.count(raceKey), #plan .. " of " .. B.count(raceKey))
            else
                check(name .. ": some placed", #plan > 0, #plan)
            end
            local mine = {x = site.mine.x, y = site.mine.y, half = B.MINE_HALF}
            for i, s in ipairs(plan) do
                local what = name .. ": " .. s.id .. " at " .. s.x .. "," .. s.y
                check(what .. " clear of the hall", apart(s, site.hall, B.HALL_GAP))
                check(what .. " clear of the mine", apart(s, mine, B.MINE_GAP))
                for j = i + 1, #plan do
                    check(what .. " clear of " .. plan[j].id, apart(s, plan[j], B.GAP))
                end
                check(what .. " off the hall-to-mine path", squareToSegment(s, site.hall, site.mine) >= B.MINE_PATH,
                    squareToSegment(s, site.hall, site.mine))
                for _, e in ipairs(site.exits) do
                    check(what .. " off the exit path", squareToSegment(s, site.hall, e) >= B.EXIT_PATH,
                        squareToSegment(s, site.hall, e))
                end
                check(what .. " near the hall", dist(s, site.hall) <= 1500, dist(s, site.hall))
                if blocked then
                    local bad = false
                    for dy = 16 - s.half, s.half - 16, 32 do
                        for dx = 16 - s.half, s.half - 16, 32 do
                            if blocked(s.x + dx, s.y + dy) then bad = true end
                        end
                    end
                    check(what .. " on buildable ground", not bad)
                end
            end
        end

        local function site(hall, mine, exits, enemy)
            return {
                hall = hall, mine = mine, mines = {mine}, exits = exits, bounds = md.bounds.max,
                front = math.atan(enemy.y - hall.y, enemy.x - hall.x),
            }
        end
        local c = md.commander
        local baseExits = {}
        for _, lane in ipairs({"bot", "mid", "top"}) do baseExits[#baseExits + 1] = c.spawns[lane] end
        local dotaShaped = {
            hall = {x = 5500, y = 5000, half = B.HALL_HALF}, mine = {x = 6000, y = 5500},
            exits = {{x = 3200, y = 5800}, {x = 4100, y = 3600}, {x = 6300, y = 3600}},
        }

        local saved = IsTerrainPathable
        for _, raceKey in ipairs(RACES) do
            local hall = {x = c.start.x, y = c.start.y, half = raceKey == "nightelf" and 192 or B.HALL_HALF}
            verify("base layout", raceKey, site(hall, c.mines[1], baseExits, md.dota.ancient), nil, true)
            verify("dota-shaped layout", raceKey,
                site(dotaShaped.hall, dotaShaped.mine, dotaShaped.exits, md.dota.ancient), nil, true)
            -- cramped: cliffs north-west of the hall and beyond 1100 units
            local h = dotaShaped.hall
            local function blocked(x, y)
                return (x < h.x + 200 and y > h.y + 150) or math.sqrt((x - h.x) ^ 2 + (y - h.y) ^ 2) > 1100
            end
            IsTerrainPathable = function(x, y) return blocked(x, y) end
            verify("cramped ground", raceKey,
                site(dotaShaped.hall, dotaShaped.mine, dotaShaped.exits, md.dota.ancient), blocked, false)
            IsTerrainPathable = saved
        end
        IsTerrainPathable = saved

        Log.info("commander exercise: " .. failures .. " failed checks")
    end

    local function run()
        if not defined or not defined("commander") then return end
        local ok, err = xpcall(exercise, debug and debug.traceback or tostring)
        if not ok then use("log").error("commander exercise crashed: " .. tostring(err)) end
        use("log").flush()
    end

    TimerStart(CreateTimer(), 5.0, false, run)
end
