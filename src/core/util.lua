-- Geometry, unit queries and small helpers shared by every module.
define("util", function()
    local U = {}
    local group = CreateGroup()

    function U.dist(x1, y1, x2, y2)
        local dx, dy = x2 - x1, y2 - y1
        return math.sqrt(dx * dx + dy * dy)
    end

    function U.angle(x1, y1, x2, y2)
        return math.atan(y2 - y1, x2 - x1)
    end

    function U.polar(x, y, distance, angle)
        return x + distance * math.cos(angle), y + distance * math.sin(angle)
    end

    function U.clamp(v, lo, hi)
        if v < lo then return lo end
        if v > hi then return hi end
        return v
    end

    function U.unitDist(a, b)
        return U.dist(GetUnitX(a), GetUnitY(a), GetUnitX(b), GetUnitY(b))
    end

    function U.alive(u)
        return u ~= nil and GetUnitTypeId(u) ~= 0 and not IsUnitType(u, UNIT_TYPE_DEAD)
    end

    function U.isHero(u) return IsUnitType(u, UNIT_TYPE_HERO) end
    function U.isStructure(u) return IsUnitType(u, UNIT_TYPE_STRUCTURE) end
    function U.isMagicImmune(u) return IsUnitType(u, UNIT_TYPE_MAGIC_IMMUNE) end

    -- Alive units within radius of (x, y) that pass filter(u); returns a list.
    function U.enum(x, y, radius, filter)
        local out = {}
        GroupEnumUnitsInRange(group, x, y, radius, nil)
        local n = BlzGroupGetSize(group)
        for i = 0, n - 1 do
            local u = BlzGroupUnitAt(group, i)
            if U.alive(u) and (filter == nil or filter(u)) then
                out[#out + 1] = u
            end
        end
        GroupClear(group)
        return out
    end

    -- Enemies of `owner` (a player) that spells may target: alive, visible
    -- units that are not structures unless allowStructures is set.
    function U.enemiesOf(owner, x, y, radius, allowStructures)
        return U.enum(x, y, radius, function(u)
            return IsUnitEnemy(u, owner)
                and (allowStructures or not IsUnitType(u, UNIT_TYPE_STRUCTURE))
                and not BlzIsUnitInvulnerable(u)
                and GetUnitAbilityLevel(u, FourCC("Aloc")) == 0
        end)
    end

    function U.alliesOf(owner, x, y, radius)
        return U.enum(x, y, radius, function(u)
            return IsUnitAlly(u, owner) and GetUnitAbilityLevel(u, FourCC("Aloc")) == 0
        end)
    end

    function U.nearest(list, x, y)
        local best, bestD = nil, math.huge
        for i = 1, #list do
            local d = U.dist(x, y, GetUnitX(list[i]), GetUnitY(list[i]))
            if d < bestD then
                best, bestD = list[i], d
            end
        end
        return best, bestD
    end

    -- Value for an ability level from a space-separated Dota list ("8 14 20 26").
    function U.levelValue(list, level)
        if type(list) == "number" then
            return list
        end
        local n, last = 0, 0
        for token in string.gmatch(list, "[^%s]+") do
            n = n + 1
            last = tonumber(token) or 0
            if n == level then
                return last
            end
        end
        return last
    end

    return U
end)
