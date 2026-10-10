-- Dota tower rules on top of structures.lua:
-- * Backdoor protection (every structure but tier 1 towers): while no enemy
--   lane creep (Horde slot) has been within 900 for 15 s, the building takes
--   40% less damage and regenerates the damage taken meanwhile at 90 HP/s.
--   Base buildings (tier 3-4 towers, barracks, the Ancient) also lose it
--   while any enemy lane creep is inside the base (behind the tier 3 line).
--   Radius, delay and regeneration are the patch's backdoor_protection
--   values; the 40% is Dota's game code.
-- * Tower Protection aura on tier 1 towers: +5 armor and +3 HP regeneration
--   to allied heroes within 900 (Dota lists it on towers; tiers in AURA_TIERS).
-- * True sight around every Dota tower (WC3 detection, tower attack range).
define("world_towers", function()
    local Log = use("log")
    local Timer = use("timer")
    local Mods = use("mods")
    local Damage = use("damage")
    local U = use("util")
    local T = {protected = {}, aura = {}}

    T.REDUCTION = 0.40
    T.STEP = 0.5
    T.AURA = {armor = 5, hp_regen = 3, radius = 900, linger = 0.5}
    T.AURA_TIERS = {[1] = true}
    T.BASE_MARGIN = 400       -- the base starts this far behind the tier 3 towers

    local W, bd
    local edgeX, edgeY = nil, nil

    local function horde(u)
        return GetPlayerId(GetOwningPlayer(u)) == SLOT_HORDE and not IsUnitType(u, UNIT_TYPE_STRUCTURE)
    end

    -- Any enemy lane creep inside the Dota base.
    function T.baseInvaded()
        if not edgeX then return false end
        local a = use("structures").ancient
        if not a then return false end
        local cx, cy = GetUnitX(a), GetUnitY(a)
        local found = U.enum(cx, cy, 4000, function(u)
            return horde(u) and GetUnitX(u) < edgeX and GetUnitY(u) < edgeY
        end)
        return #found > 0
    end

    function T.update()
        local now = Timer.now()
        local invaded = T.baseInvaded()
        for u, s in pairs(T.protected) do
            if not U.alive(u) then
                T.protected[u] = nil
            else
                local near = (s.inBase and invaded)
                    or #U.enum(GetUnitX(u), GetUnitY(u), bd.radius, horde) > 0
                if near then s.lastCreep = now end
                s.active = now - s.lastCreep >= bd.activation_time
                if s.active and s.pool > 0 then
                    local heal = math.min(s.pool, bd.regen_rate * T.STEP)
                    s.pool = s.pool - heal
                    SetWidgetLife(u, math.min(BlzGetUnitMaxHP(u), GetWidgetLife(u) + heal))
                end
            end
        end
        for _, t in ipairs(T.aura) do
            if U.alive(t) then
                for _, h in ipairs(U.alliesOf(GetOwningPlayer(t), GetUnitX(t), GetUnitY(t), T.AURA.radius)) do
                    if IsUnitType(h, UNIT_TYPE_HERO) then
                        Mods.add(h, "tower_protection", {duration = T.STEP + T.AURA.linger, dispel = "none",
                                                         props = {armor = T.AURA.armor, hp_regen = T.AURA.hp_regen}})
                    end
                end
            end
        end
    end

    function T.isProtected(u)
        local s = T.protected[u]
        return s ~= nil and s.active
    end

    local function protect(u, inBase)
        if u then T.protected[u] = {inBase = inBase, lastCreep = -1000, pool = 0, active = true} end
    end

    function T.init(world)
        W = world
        bd = W.data().backdoor
        local S = use("structures")
        local m = use("data.mapdata").dota
        local sight = W.code("abilities", "truesight")
        for _, lane in ipairs({"top", "mid", "bot"}) do
            local list = S.towers[lane] or {}
            protect(list[2], false)
            protect(list[3], true)
            for _, rax in ipairs(S.barracks[lane] or {}) do protect(rax, true) end
            for tier, t in ipairs(list) do
                if T.AURA_TIERS[tier] then T.aura[#T.aura + 1] = t end
            end
            local p = m.towers[lane] and m.towers[lane][3]
            if p then
                edgeX = math.max(edgeX or p.x, p.x)
                edgeY = math.max(edgeY or p.y, p.y)
            end
        end
        for _, t in ipairs(S.towers.base or {}) do
            protect(t, true)
            if T.AURA_TIERS[4] then T.aura[#T.aura + 1] = t end
        end
        protect(S.ancient, true)
        if edgeX then edgeX, edgeY = edgeX + T.BASE_MARGIN, edgeY + T.BASE_MARGIN end
        if sight then
            for _, lane in pairs(S.towers) do
                for _, t in ipairs(lane) do
                    UnitAddAbility(t, sight)
                    UnitMakeAbilityPermanent(t, true, sight)
                end
            end
        end
        Damage.onDamaging(function(source, target, info)
            local s = T.protected[target]
            if s and s.active then info.amount = info.amount * (1 - T.REDUCTION) end
        end)
        Damage.onDamaged(function(source, target, amount)
            local s = T.protected[target]
            if s and s.active and amount > 0 then s.pool = s.pool + amount end
        end)
        Timer.every(T.STEP, T.update)
        local n = 0
        for _ in pairs(T.protected) do n = n + 1 end
        Log.info("world: backdoor protection on " .. n .. " buildings, " .. #T.aura .. " tower auras")
    end

    return T
end)
