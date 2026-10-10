-- Lane creep waves every 30 seconds. Dota creeps (Ancients slot) walk each
-- lane from the Dota base to the Commander's town hall; the Commander's
-- uncontrollable race creeps (Horde slot) walk the same lanes the other way to
-- the Ancient. Every fifth wave adds a siege creep. Walkers attack-move from
-- waypoint to waypoint and are nudged when idle.
define("creeps", function()
    local Log = use("log")
    local Timer = use("timer")
    local U = use("util")
    local C = {waves = 0, interval = 30, first = 30, raceKey = "human"}

    local walkers = {}     -- unit -> {path, index}
    local ARRIVE = 400

    local function ids() return use("data.ids").units end

    local function order(u, w)
        local p = w.path[w.index]
        IssuePointOrder(u, "attack", p.x, p.y)
    end

    local function spawn(slot, key, x, y, path, lane)
        local code = ids()[key]
        if not code then
            Log.warn("no creep type " .. key)
            return nil
        end
        local u = CreateUnit(Player(slot), FourCC(code), x, y, 0)
        use("world").scaleCreep(u, key)
        local w = {path = path, index = 1, lane = lane, slot = slot}
        walkers[u] = w
        order(u, w)
        return u
    end

    local function paths()
        local m = use("data.mapdata")
        local out = {}
        for lane, pts in pairs(m.lanes) do
            local dota, horde = {}, {}
            for i = 1, #pts do dota[#dota + 1] = pts[i] end
            dota[#dota + 1] = m.commander.start
            for i = #pts, 1, -1 do horde[#horde + 1] = pts[i] end
            horde[#horde + 1] = m.dota.ancient
            out[lane] = {dota = dota, horde = horde, hordeSpawn = m.commander.spawns[lane]}
        end
        return out
    end

    function C.wave()
        C.waves = C.waves + 1
        local siege = C.waves % 5 == 0
        local race = C.raceKey
        for lane, p in pairs(C.paths) do
            local d0, h0 = p.dota[1], p.hordeSpawn
            for i = 1, 3 do
                spawn(SLOT_ANCIENTS, "dota_melee", d0.x + 40 * i, d0.y - 40 * i, p.dota, lane)
                spawn(SLOT_HORDE, race .. "_melee", h0.x - 40 * i, h0.y + 40 * i, p.horde, lane)
            end
            spawn(SLOT_ANCIENTS, "dota_ranged", d0.x - 80, d0.y - 80, p.dota, lane)
            spawn(SLOT_HORDE, race .. "_ranged", h0.x + 80, h0.y + 80, p.horde, lane)
            if siege then
                spawn(SLOT_ANCIENTS, "dota_siege", d0.x - 160, d0.y - 160, p.dota, lane)
                spawn(SLOT_HORDE, race .. "_siege", h0.x + 160, h0.y + 160, p.horde, lane)
            end
        end
        Log.info("wave " .. C.waves .. (siege and " (siege)" or ""))
    end

    -- The most advanced creep a side has on a lane: highest waypoint index,
    -- then closest to its next waypoint. Returns the unit or nil.
    function C.front(lane, slot)
        local best, bestIndex, bestDist = nil, -1, math.huge
        for u, w in pairs(walkers) do
            if w.lane == lane and w.slot == slot and U.alive(u) then
                local p = w.path[w.index]
                local d = U.dist(GetUnitX(u), GetUnitY(u), p.x, p.y)
                if w.index > bestIndex or (w.index == bestIndex and d < bestDist) then
                    best, bestIndex, bestDist = u, w.index, d
                end
            end
        end
        return best
    end

    function C.count(slot)
        local n = 0
        for u in pairs(walkers) do
            if U.alive(u) and GetPlayerId(GetOwningPlayer(u)) == slot then n = n + 1 end
        end
        return n
    end

    function C.start(raceKey)
        C.raceKey = raceKey or C.raceKey
        C.paths = paths()
        Timer.after(C.first, function()
            C.wave()
            Timer.every(C.interval, function() C.wave() end)
        end)
        Timer.every(1.5, function()
            for u, w in pairs(walkers) do
                -- dead, or taken over (e.g. Chen's Holy Persuasion): stop driving it
                if not U.alive(u) or GetPlayerId(GetOwningPlayer(u)) ~= w.slot then
                    walkers[u] = nil
                else
                    local p = w.path[w.index]
                    if w.index < #w.path and U.dist(GetUnitX(u), GetUnitY(u), p.x, p.y) < ARRIVE then
                        w.index = w.index + 1
                        order(u, w)
                    elseif GetUnitCurrentOrder(u) == 0 then
                        order(u, w)
                    end
                end
            end
        end)
    end

    return C
end)
