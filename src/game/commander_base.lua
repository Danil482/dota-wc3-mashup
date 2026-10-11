-- The commander's starter base: a race-specific opening of defensive towers,
-- a production building and supply around the town hall, created finished at
-- game start. They are stock WC3 units, so every number is the game's own,
-- and the melee AI counts them as its own: its build order skips what it
-- already has and goes on from there.
--
-- Spots are searched on a grid around the hall. A spot must be buildable,
-- walkable ground, keep the hall-to-mine worker path and the paths from the
-- hall to the lane exits (the creep spawns) open, and keep a gap to the hall,
-- the mine and the other structures. Towers prefer the hall's front (towards
-- the Dota Ancient), production the front sides, supply the back.
define("commander_base", function()
    local B = {}

    -- Who starts with the base: "ai" (the AI commander only), "all" (a human
    -- commander too) or "none".
    B.FOR = "ai"

    -- Per race, in placement order.
    B.STARTER = {
        human = {
            {id = "hgtw", count = 2, role = "tower"},        -- Guard Tower
            {id = "hbar", count = 1, role = "production"},   -- Barracks
            {id = "hhou", count = 3, role = "supply"},       -- Farm
        },
        orc = {
            {id = "owtw", count = 2, role = "tower"},        -- Watch Tower
            {id = "obar", count = 1, role = "production"},   -- Barracks
            {id = "otrb", count = 2, role = "supply"},       -- Orc Burrow
        },
        undead = {
            {id = "uzg1", count = 2, role = "tower"},        -- Spirit Tower (also supply)
            {id = "usep", count = 1, role = "production"},   -- Crypt
            {id = "uzig", count = 1, role = "supply"},       -- Ziggurat
        },
        nightelf = {
            {id = "etrp", count = 2, role = "tower"},        -- Ancient Protector
            {id = "eaom", count = 1, role = "production"},   -- Ancient of War
            {id = "emow", count = 2, role = "supply"},       -- Moon Well
        },
    }

    -- Half the side of each building's pathing texture (unitui.slk pathTex in
    -- 32-unit cells: 4x4 -> 64, 6x6 -> 96, 12x12 -> 192, 16x16 -> 256).
    B.HALF = {
        hgtw = 64, hbar = 192, hhou = 64,
        owtw = 64, obar = 192, otrb = 96,
        uzg1 = 96, usep = 192, uzig = 96,
        etrp = 96, eaom = 192, emow = 96,
    }
    B.HALL_HALF, B.MINE_HALF = 256, 256

    -- angle: from the hall's front, either side, give or take slack; dist:
    -- from the hall's centre; spread: keep this far from the same role.
    local ROLE = {
        tower = {angle = 0, slack = 0, dist = 800, spread = 700},
        production = {angle = math.pi / 3, slack = math.pi / 6, dist = 720, spread = 0},
        supply = {angle = math.pi, slack = math.pi / 3, dist = 640, spread = 0},
    }
    B.GAP, B.HALL_GAP, B.MINE_GAP = 64, 96, 128     -- free ground around structures
    B.MINE_PATH, B.EXIT_PATH = 288, 192             -- half widths of the kept paths
    local MIN_DIST, MAX_DIST, STEP, GRID = 320, 1408, 64, 32

    function B.enabled(isAI)
        return B.FOR == "all" or (B.FOR == "ai" and isAI)
    end

    function B.count(raceKey)
        local n = 0
        for _, e in ipairs(B.STARTER[raceKey] or {}) do n = n + e.count end
        return n
    end

    local function segDist(px, py, ax, ay, bx, by)
        local dx, dy = bx - ax, by - ay
        local len2 = dx * dx + dy * dy
        local t = len2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / len2)) or 0
        local cx, cy = ax + t * dx - px, ay + t * dy - py
        return math.sqrt(cx * cx + cy * cy)
    end

    local function onPath(site, x, y, half)
        local r = half * 1.415                          -- the footprint's corner
        local h = site.hall
        if site.mine and segDist(x, y, h.x, h.y, site.mine.x, site.mine.y) < B.MINE_PATH + r then
            return true
        end
        for _, e in ipairs(site.exits) do
            if segDist(x, y, h.x, h.y, e.x, e.y) < B.EXIT_PATH + r then return true end
        end
        return false
    end

    local function overlaps(x, y, half, boxes)
        for _, b in ipairs(boxes) do
            local reach = half + b.half
            if math.abs(x - b.x) < reach and math.abs(y - b.y) < reach then return true end
        end
        return false
    end

    -- IsTerrainPathable is true where the pathing type is NOT set.
    local function groundOk(x, y, half)
        for dy = 16 - half, half - 16, 32 do
            for dx = 16 - half, half - 16, 32 do
                if IsTerrainPathable(x + dx, y + dy, PATHING_TYPE_BUILDABILITY)
                    or IsTerrainPathable(x + dx, y + dy, PATHING_TYPE_WALKABILITY) then
                    return false
                end
            end
        end
        return true
    end

    -- Whole-number grid points around the hall: no trigonometry, so every
    -- client gets exactly the same spots.
    local function gridSpots(site)
        local out = {}
        local cx = GRID * math.floor(site.hall.x / GRID + 0.5)
        local cy = GRID * math.floor(site.hall.y / GRID + 0.5)
        for dy = -MAX_DIST, MAX_DIST, STEP do
            for dx = -MAX_DIST, MAX_DIST, STEP do
                local d2 = dx * dx + dy * dy
                if d2 >= MIN_DIST * MIN_DIST and d2 <= MAX_DIST * MAX_DIST then
                    out[#out + 1] = {x = cx + dx, y = cy + dy}
                end
            end
        end
        return out
    end

    local function score(site, role, x, y, placed)
        local h = site.hall
        local rel = math.atan(y - h.y, x - h.x) - site.front
        rel = math.abs((rel + math.pi) % (2 * math.pi) - math.pi)
        local d = math.sqrt((x - h.x) ^ 2 + (y - h.y) ^ 2)
        local s = math.max(0, math.abs(rel - role.angle) - role.slack) + math.abs(d - role.dist) / 600
        for _, p in ipairs(placed) do
            if p.role == role then
                local near = role.spread - math.sqrt((x - p.x) ^ 2 + (y - p.y) ^ 2)
                if near > 0 then s = s + near / 400 end
            end
        end
        return s
    end

    local function pick(site, spots, half, role, boxes, placed)
        local lim = site.bounds - half - 128
        local ranked = {}
        for _, c in ipairs(spots) do
            if math.abs(c.x) <= lim and math.abs(c.y) <= lim and not overlaps(c.x, c.y, half, boxes)
                and not onPath(site, c.x, c.y, half) then
                ranked[#ranked + 1] = {x = c.x, y = c.y, s = score(site, role, c.x, c.y, placed)}
            end
        end
        table.sort(ranked, function(a, b)
            if a.s ~= b.s then return a.s < b.s end
            if a.x ~= b.x then return a.x < b.x end
            return a.y < b.y
        end)
        for _, c in ipairs(ranked) do
            if groundOk(c.x, c.y, half) then return c end
        end
        return nil
    end

    -- site = {hall = {x, y, half}, mine = {x, y} (the hall's mine) or nil,
    -- mines = {{x, y}, ...} (every mine nearby), exits = {{x, y}, ...},
    -- front = angle towards the enemy, bounds = playable half size}.
    -- Returns {{id, x, y, half}, ...}, one entry per structure that found a spot.
    function B.plan(raceKey, site)
        local spots = gridSpots(site)
        local boxes = {{x = site.hall.x, y = site.hall.y, half = site.hall.half + B.HALL_GAP}}
        for _, m in ipairs(site.mines) do
            boxes[#boxes + 1] = {x = m.x, y = m.y, half = B.MINE_HALF + B.MINE_GAP}
        end
        local placed = {}
        for _, entry in ipairs(B.STARTER[raceKey] or {}) do
            local half, role = B.HALF[entry.id], ROLE[entry.role]
            for _ = 1, entry.count do
                local spot = pick(site, spots, half, role, boxes, placed)
                if spot then
                    placed[#placed + 1] = {id = entry.id, x = spot.x, y = spot.y, half = half, role = role}
                    boxes[#boxes + 1] = {x = spot.x, y = spot.y, half = half + B.GAP}
                end
            end
        end
        return placed
    end

    function B.build(p, raceKey, site)
        local units = {}
        for _, s in ipairs(B.plan(raceKey, site)) do
            units[#units + 1] = CreateUnit(p, FourCC(s.id), s.x, s.y, bj_UNIT_FACING)
        end
        return units
    end

    return B
end)
