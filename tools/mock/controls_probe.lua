-- Offline exercise for the controls probe (src/ui/controls_probe.lua). The
-- engine's answers are modelled: a unit takes an order, by string or by id,
-- when one of its abilities has that order and its Channel target type takes
-- that form (0 instant, 1 unit, 2 point, 3 unit or point). Checks: no probe
-- Channels left in the build data, a line for every hero Channel without a
-- unit target (its mana cost zeroed),
-- the acquisition line a second later, a stop after every order, every
-- footman removed and the acquisition one hidden, the table in log.txt (not
-- on screen) and in controls_probe.txt.
-- Failed checks are ERROR log lines, which fail the mock run.
do
    local STOP = 851972
    local FILE = "DotaVsCommander\\controls_probe.txt"

    local function advance(seconds)
        local target = __mock.now + seconds
        while true do
            local nextT, nextDue = nil, math.huge
            for t in pairs(__mock.timers) do
                if t.active and t.due <= target and t.due < nextDue then nextT, nextDue = t, t.due end
            end
            if not nextT then break end
            __mock.now = nextDue
            if nextT.periodic then nextT.due = nextT.due + math.max(nextT.timeout, 0.001) else nextT.active = false end
            if nextT.fn then nextT.fn() end
        end
        __mock.now = target
    end

    local function exercise()
        local Log, P, ids = use("log"), use("controls_probe"), use("data.ids")
        local failures, checks = 0, 0
        local function check(name, ok, detail)
            checks = checks + 1
            if not ok then
                failures = failures + 1
                Log.error("controls_probe exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
            end
        end
        check("build data: no probe Channels", ids.order_probe == nil)

        -- ability id -> its order and Channel target type
        local abil = {}
        local heroLines = 0
        for name, t in pairs(ids.ability_targets or {}) do
            local code, order = ids.abilities[name], ids.orders[name]
            if code and order then
                abil[FourCC(code)] = {order = order, target = t}
                if t ~= 1 then heroLines = heroLines + 1 end
            end
        end
        local idOf, nameOf, nextId = {}, {}, 900000
        local function orderId(s)
            if not idOf[s] then
                nextId = nextId + 1
                idOf[s], nameOf[nextId] = nextId, s
            end
            return idOf[s]
        end
        local created, mine, issued, stops, manaZeroed = {}, {}, 0, 0, 0
        local function takes(u, order, form)
            if not mine[u] then return false end
            issued = issued + 1
            for id in pairs(u.abilities or {}) do
                local a = abil[id]
                if a and a.order == order then
                    if form == "instant" then return a.target == 0 end
                    if form == "unit" then return a.target == 1 or a.target == 3 end
                    return a.target == 2 or a.target == 3
                end
            end
            return false
        end
        local saved = {}
        local function set(name, fn)
            saved[name] = _G[name]
            _G[name] = fn
        end
        set("OrderId", orderId)
        set("CreateUnit", function(p, id, x, y, face)
            local u = saved.CreateUnit(p, id, x, y, face)
            created[#created + 1], mine[u] = u, true
            return u
        end)
        set("IssueImmediateOrder", function(u, s) return takes(u, s, "instant") end)
        set("IssueImmediateOrderById", function(u, id)
            if id == STOP then
                if mine[u] then stops = stops + 1 end
                return true
            end
            return takes(u, nameOf[id], "instant")
        end)
        set("IssueTargetOrder", function(u, s, t) return takes(u, s, "unit") and t ~= nil end)
        set("IssueTargetOrderById", function(u, id, t) return takes(u, nameOf[id], "unit") and t ~= nil end)
        set("IssuePointOrder", function(u, s) return takes(u, s, "point") end)
        set("IssuePointOrderById", function(u, id) return takes(u, nameOf[id], "point") end)
        set("BlzSetUnitAbilityManaCost", function(u, id, level, cost)
            if mine[u] and level == 0 and cost == 0 then manaZeroed = manaZeroed + 1 end
        end)
        set("ShowUnit", function(u, on) u.shown = on end)
        set("GetUnitDefaultAcquireRange", function() return 500 end)
        set("GetUnitAcquireRange", function(u) return u.acq or 500 end)
        set("SetUnitAcquireRange", function(u, r) u.acq = r end)
        set("BlzGetUnitRealField", function(u, f)
            if f == UNIT_RF_ACQUISITION_RANGE then return u.acqField or 500 end
            return saved.BlzGetUnitRealField(u, f)
        end)
        set("BlzSetUnitRealField", function(u, f, v)
            if f ~= UNIT_RF_ACQUISITION_RANGE then return saved.BlzSetUnitRealField(u, f, v) end
            u.acqField = v
            return true
        end)
        set("IsUnitType", function(u, t)
            if t == UNIT_TYPE_PEON and mine[u] then return u.peon == true end
            return saved.IsUnitType(u, t)
        end)
        set("UnitAddType", function(u, t)
            if t ~= UNIT_TYPE_PEON or not mine[u] then return saved.UnitAddType(u, t) end
            u.peon = true
            return true
        end)
        set("UnitRemoveType", function(u, t)
            if t ~= UNIT_TYPE_PEON or not mine[u] then return saved.UnitRemoveType(u, t) end
            u.peon = nil
            return true
        end)

        local loud = Log.debug
        P.lines = nil
        P.run()
        check("the table waits for the acquisition reading", P.lines == nil)
        advance(1.1)
        for name, fn in pairs(saved) do _G[name] = fn end

        local lines = P.lines or {}
        check("one line per hero Channel and the acquisition", #lines == 1 + heroLines + 1, #lines)
        local heroOk = 0
        for i = 2, 1 + heroLines do
            local line = lines[i] or ""
            if line:sub(1, 3) == "B: " and (line:sub(-10) == "instant ++" or line:sub(-8) == "point ++") then
                heroOk = heroOk + 1
            end
        end
        check("every hero Channel without a unit target is ordered in its form", heroOk == heroLines,
            heroOk .. "/" .. heroLines)
        check("hero Channels cost no mana on the footmen", manaZeroed == heroLines, manaZeroed)
        local last = lines[#lines] or ""
        check("acquisition: setters read back", string.find(last, "default 500", 1, true)
            and string.find(last, "SetUnitAcquireRange 0 -> 0 (field 500)", 1, true)
            and string.find(last, "field 0 -> 500 (field 0)", 1, true), last)
        check("acquisition: the worker type", string.find(last, "added true, is worker true, removed true, "
            .. "is worker false", 1, true), last)
        check("acquisition: a second later", string.find(last, "a second later -> 100 (field 0)", 1, true), last)
        check("every order is followed by a stop", issued > 0 and stops == issued, stops .. "/" .. issued)
        local left = 0
        for _, u in ipairs(created) do
            if GetUnitTypeId(u) ~= 0 then left = left + 1 end
        end
        check("every footman removed", #created > 0 and left == 0, left)
        check("the acquisition footman hidden", created[#created] ~= nil and created[#created].shown == false)
        local file = __mock.files[FILE] or ""
        check("table saved to its own file", string.find(file, "B: ", 1, true)
            and string.find(file, "worker type", 1, true), #file)
        local log = __mock.files["DotaVsCommander\\log.txt"] or ""
        check("table in the log", string.find(log, "controls probe: order by string and by id", 1, true), #log)
        check("log display restored", Log.debug == loud)
        Log.info("controls_probe exercise: " .. checks .. " checks, " .. failures .. " failed")
    end

    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("controls_probe") then return end
        done = true
        use("safe").call(exercise)
        use("log").flush()
    end
end
