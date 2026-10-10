-- Dota team buildings: towers, barracks, the Ancient, fountain and shop, all
-- owned by the Ancients computer slot. Dota's protection rules apply: a tower
-- stays invulnerable until the previous tier in its lane falls, barracks until
-- their tier-3 tower falls, tier-4 towers until any tier-3 tower falls, and the
-- Ancient until both tier-4 towers are down.
define("structures", function()
    local Log = use("log")
    local Events = use("events")
    local U = use("util")
    local S = {towers = {}, barracks = {}, ancient = nil, fountain = nil, shop = nil}

    local function id(key) return FourCC(use("data.ids").units[key]) end

    local function create(key, pos, face)
        local u = CreateUnit(Player(SLOT_ANCIENTS), id(key), pos.x, pos.y, face or 225)
        return u
    end

    local guards = {}     -- unit -> list of units that must die before it is vulnerable

    local function protect(u, deps)
        guards[u] = deps
        SetUnitInvulnerable(u, true)
    end

    local function refresh()
        for u, deps in pairs(guards) do
            local open = false
            for _, d in ipairs(deps) do
                if not U.alive(d) then open = true break end
            end
            if open then
                SetUnitInvulnerable(u, false)
                guards[u] = nil
            end
        end
    end

    function S.create()
        local m = use("data.mapdata").dota
        for _, lane in ipairs({"top", "mid", "bot"}) do
            local list = {}
            for tier, pos in ipairs(m.towers[lane]) do
                list[tier] = create("tower" .. tier, pos)
            end
            S.towers[lane] = list
            protect(list[2], {list[1]})
            protect(list[3], {list[2]})
            local rax = {create("rax_melee", m.barracks[lane][1], 270), create("rax_ranged", m.barracks[lane][2], 270)}
            S.barracks[lane] = rax
            protect(rax[1], {list[3]})
            protect(rax[2], {list[3]})
        end
        local tier3 = {S.towers.top[3], S.towers.mid[3], S.towers.bot[3]}
        local t4 = {}
        for i, pos in ipairs(m.towers.base) do
            t4[i] = create("tower4", pos)
            protect(t4[i], tier3)
        end
        S.towers.base = t4
        S.ancient = create("ancient", m.ancient, 225)
        protect(S.ancient, {})
        guards[S.ancient] = nil
        SetUnitInvulnerable(S.ancient, true)
        S.fountain = create("fountain", m.fountain, 45)
        S.shop = create("shop", m.shop, 90)
        Events.on("death", function(dying)
            if guards[dying] then guards[dying] = nil end
            refresh()
            -- The Ancient opens once both tier-4 towers are dead
            if not U.alive(t4[1]) and not U.alive(t4[2]) and BlzIsUnitInvulnerable(S.ancient) then
                SetUnitInvulnerable(S.ancient, false)
                Log.info("ancient is now vulnerable")
            end
        end)
        Log.info("structures created")
    end

    function S.count()
        local n = 0
        for _, lane in pairs(S.towers) do n = n + #lane end
        return n
    end

    return S
end)
