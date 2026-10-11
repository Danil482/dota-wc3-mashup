-- Test builds only: one in-game run answers what the offline mock cannot,
-- like the UI probe (Kit.probe). At the start it gives footmen of the neutral
-- passive player, at the Dota fountain, Channel abilities and orders them:
--   A: the probe Channels of tools/gen_objects.py (ids.order_probe): every
--      Channel target type with the order of a native spell of each target
--      kind, ordered as an instant, a unit and a point order;
--   B: every hero Channel with its build order (ids.orders): a point order
--      for point and unit-or-point Channels, an instant order for those
--      without a target;
--   C: what SetUnitAcquireRange and the acquisition range field read back
--      at once and a second later, and whether the worker type (the auto
--      attack mechanism of dota_settings.lua) can be added and removed.
-- Every order goes by string, then by order id, and the footman stops right
-- after each, so a taken order never starts a cast; the A and B footmen are
-- removed in the same call, before the next frame, and the C footman is
-- hidden. The table goes to log.txt (not on screen) and to
-- DotaVsCommander\controls_probe.txt, which survives the log rolling over.
-- "++" taken by string and by id, "--" refused by both.
--
-- Start in game.lua begin(), test builds: use("controls_probe").run()
define("controls_probe", function()
    local Log = use("log")
    local Timer = use("timer")
    local P = {}

    local FILE = "DotaVsCommander\\controls_probe.txt"
    local STOP = 851972
    local FOOTMAN = FourCC("hfoo")
    local KIND = {[0] = "none", "unit", "point", "unit or point"}
    local ALL = {instant = true, unit = true, point = true}

    local function sign(ok) return ok and "+" or "-" end

    local function both(u, issue, issueById, order, ...)
        local byString = issue(u, order, ...)
        IssueImmediateOrderById(u, STOP)
        local byId = issueById(u, OrderId(order), ...)
        IssueImmediateOrderById(u, STOP)
        return sign(byString) .. sign(byId)
    end

    local function forms(u, order, target, x, y, which)
        local out = {}
        if which.instant then out[#out + 1] = "instant " .. both(u, IssueImmediateOrder, IssueImmediateOrderById, order) end
        if which.unit then out[#out + 1] = "unit " .. both(u, IssueTargetOrder, IssueTargetOrderById, order, target) end
        if which.point then out[#out + 1] = "point " .. both(u, IssuePointOrder, IssuePointOrderById, order, x, y) end
        return table.concat(out, ", ")
    end

    -- A footman per Channel target type and options: the orders on each differ.
    local function synthetic(lines, p, x, y)
        local probe = use("data.ids").order_probe or {}
        local casters, target = {}, CreateUnit(p, FOOTMAN, x + 150, y, 0)
        for _, c in ipairs(probe) do
            local key = c.target .. "/" .. c.options
            casters[key] = casters[key] or CreateUnit(p, FOOTMAN, x, y, 0)
            UnitAddAbility(casters[key], FourCC(c.code))
        end
        for _, c in ipairs(probe) do
            lines[#lines + 1] = string.format("A: Channel target %d (%s), options %d, order %s (native spell: %s): %s",
                c.target, KIND[c.target], c.options, c.order, c.native,
                forms(casters[c.target .. "/" .. c.options], c.order, target, x + 300, y, ALL))
        end
        local control = CreateUnit(p, FOOTMAN, x, y, 0)
        lines[#lines + 1] = "A: control, an order no ability of the footman has (blizzard): "
            .. forms(control, "blizzard", target, x + 300, y, ALL)
        RemoveUnit(control)
        for _, u in pairs(casters) do RemoveUnit(u) end
        RemoveUnit(target)
    end

    -- One footman per ability: orders repeat across heroes.
    local function heroChannels(lines, p, x, y)
        local ids = use("data.ids")
        local names = {}
        for name in pairs(ids.ability_targets or {}) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            local kind, order, code = ids.ability_targets[name], ids.orders[name], ids.abilities[name]
            if order and code and kind ~= 1 then
                local u, id = CreateUnit(p, FOOTMAN, x, y, 0), FourCC(code)
                UnitAddAbility(u, id)
                BlzSetUnitAbilityManaCost(u, id, 0, 0)
                lines[#lines + 1] = string.format("B: %s, Channel target %d, order %s: %s", name, kind, order,
                    forms(u, order, nil, x + 300, y, kind == 0 and {instant = true} or {point = true}))
                RemoveUnit(u)
            end
        end
    end

    local function acquisition(p, x, y, done)
        local u = CreateUnit(p, FOOTMAN, x, y, 0)
        ShowUnit(u, false)
        local function read()
            return string.format("%.0f (field %.0f)", GetUnitAcquireRange(u),
                BlzGetUnitRealField(u, UNIT_RF_ACQUISITION_RANGE))
        end
        local default = GetUnitDefaultAcquireRange(u)
        local out = {string.format("C: footman acquisition range, default %.0f: now %s", default, read())}
        for _, v in ipairs({0, 1, 100}) do
            SetUnitAcquireRange(u, v)
            out[#out + 1] = string.format("SetUnitAcquireRange %d -> %s", v, read())
        end
        SetUnitAcquireRange(u, default)
        for _, v in ipairs({0, 100}) do
            BlzSetUnitRealField(u, UNIT_RF_ACQUISITION_RANGE, v)
            out[#out + 1] = string.format("field %d -> %s", v, read())
        end
        SetUnitAcquireRange(u, 0)
        BlzSetUnitRealField(u, UNIT_RF_ACQUISITION_RANGE, 0)
        out[#out + 1] = "both 0 -> " .. read()
        SetUnitAcquireRange(u, 100)
        local added = UnitAddType(u, UNIT_TYPE_PEON)
        local isWorker = IsUnitType(u, UNIT_TYPE_PEON)
        local removed = UnitRemoveType(u, UNIT_TYPE_PEON)
        local line = table.concat(out, "; ") .. string.format("; worker type: added %s, is worker %s, removed %s, "
            .. "is worker %s", tostring(added), tostring(isWorker), tostring(removed),
            tostring(IsUnitType(u, UNIT_TYPE_PEON)))
        Timer.after(1, function()
            done(line .. "; SetUnitAcquireRange 100, a second later -> " .. read())
            RemoveUnit(u)
        end)
    end

    -- Preload lines are cut like the log's (Log.flush).
    local function save(lines)
        PreloadGenClear()
        PreloadGenStart()
        for _, s in ipairs(lines) do
            s = string.gsub(s, '"', "'")
            for pos = 1, #s, 200 do Preload(string.sub(s, pos, pos + 199)) end
        end
        PreloadGenEnd(FILE)
    end

    function P.run()
        if not BUILD_TEST_MODE then return end
        local f = use("data.mapdata").dota.fountain
        local p = Player(PLAYER_NEUTRAL_PASSIVE)
        local lines = {"controls probe: order by string and by id, + taken, - refused"}
        synthetic(lines, p, f.x, f.y)
        heroChannels(lines, p, f.x, f.y)
        acquisition(p, f.x, f.y, function(line)
            lines[#lines + 1] = line
            P.lines = lines
            local loud = Log.debug
            Log.debug = false            -- the table goes to the file, not across the screen
            for _, s in ipairs(lines) do Log.info(s) end
            Log.debug = loud
            Log.flush()
            save(lines)
            Log.info("controls probe: " .. #lines .. " lines in " .. FILE)
        end)
    end

    return P
end)
