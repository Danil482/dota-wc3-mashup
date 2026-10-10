-- Dota 2 world systems: neutral camps (world_camps.lua), runes
-- (world_runes.lua), Roshan and the Aegis (world_roshan.lua), the Dota
-- towers' backdoor protection, armor aura and true sight (world_towers.lua)
-- and lane creep upgrades (here). Numbers come from src/data/world.json
-- (tools/extract_world.py); WC3 objects from tools/gen_objects.py world().
--
-- The game clock (Dota's 0:00) starts with World.init(): bounty runes and
-- Roshan at 0:00, camps from 1:00, water runes at 2:00 and 4:00, power runes
-- from 6:00, lane and neutral creep upgrades every 7:30.
-- Hooks for other modules:
--   World.bountyOf(unit) -> gold, xp or nil   economy.lua valueOf
--   World.scaleCreep(unit, key)               creeps.lua spawn (key "dota_melee", "orc_ranged", ...)
define("world", function()
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Safe = use("safe")
    local U = use("util")
    local W = {started = false}

    local t0 = nil
    local jobs = {}           -- {next, every, fn}: game clock events
    local lookups = {}        -- fn(unit) -> gold, xp: bounties of world units
    local lane = {}           -- lane creep -> {kind, n}

    -- Dota's lane creep upgrades every 7.5 minutes (game code, not in the KV
    -- data). Siege creeps do not scale with time in Dota.
    W.LANE_STEP = 450
    W.LANE_MAX = 30
    W.LANE_UPGRADE = {
        melee = {hp = 12, damage = 1, gold = 1, xp = 0},
        ranged = {hp = 12, damage = 2, gold = 3, xp = 8},
        siege = {hp = 0, damage = 0, gold = 0, xp = 0},
    }

    function W.data() return use("data.world") end

    -- Raw code (integer) of a world object: kind "units" | "items" | "abilities".
    function W.code(kind, key)
        local w = use("data.ids").world
        local c = w and w[kind] and w[kind][key]
        return c and FourCC(c) or nil
    end

    -- Seconds since 0:00 (0 before init).
    function W.clock() return t0 and math.max(0, Timer.now() - t0) or 0 end
    function W.minutes() return W.clock() / 60 end

    -- Run fn(at) when the clock reaches `at`, then every `every` seconds.
    function W.at(at, every, fn)
        jobs[#jobs + 1] = {next = at, every = every, fn = fn}
    end

    local function tick()
        local now = W.clock()
        for _, j in ipairs(jobs) do
            while j.next and j.next <= now do
                local at = j.next
                j.next = j.every and (at + j.every) or nil
                Safe.call(j.fn, at)
            end
        end
    end

    -- Tests: jump the game clock forward and run what became due.
    function W.skip(seconds)
        if t0 then
            t0 = t0 - seconds
            tick()
        end
    end

    -- ------------------------------------------------------------ bounties

    function W.addBounty(fn) lookups[#lookups + 1] = fn end

    -- Gold and XP for killing a world unit (camp creep, Roshan, upgraded
    -- lane creep), or nil to let economy.lua decide.
    function W.bountyOf(u)
        if not u then return nil end
        local info = lane[u]
        if info then
            local b = W.data().lane[info.kind]
            local up = W.LANE_UPGRADE[info.kind]
            return GetRandomInt(b.gold_min, b.gold_max) + up.gold * info.n, b.xp + up.xp * info.n
        end
        for i = 1, #lookups do
            local gold, xp = lookups[i](u)
            if gold then return gold, xp end
        end
        return nil
    end

    -- ------------------------------------------------------------ lane creeps

    function W.laneLevel()
        return math.min(W.LANE_MAX, math.floor(W.clock() / W.LANE_STEP))
    end

    -- Applies the current lane creep upgrades to a freshly spawned creep and
    -- registers its Dota bounty. key ends in _melee, _ranged or _siege.
    function W.scaleCreep(u, key)
        local kind = key and string.match(key, "_(%a+)$")
        local up = W.LANE_UPGRADE[kind]
        if not u or not up or not defined("data.world") then return end
        local n = W.laneLevel()
        lane[u] = {kind = kind, n = n}
        if n <= 0 then return end
        if up.hp > 0 then
            local hp = BlzGetUnitMaxHP(u) + up.hp * n
            BlzSetUnitMaxHP(u, hp)
            SetWidgetLife(u, hp)
        end
        if up.damage > 0 then
            BlzSetUnitBaseDamage(u, BlzGetUnitBaseDamage(u, 0) + up.damage * n, 0)
        end
    end

    function W.laneInfo(u) return lane[u] end

    -- ------------------------------------------------------------ shared helpers

    function W.announce(msg, seconds)
        DisplayTimedTextToPlayer(GetLocalPlayer(), 0, 0, seconds or 6, msg)
    end

    function W.text(u, s, r, g, b)
        local t = CreateTextTag()
        SetTextTagText(t, s, 0.023)
        SetTextTagPos(t, GetUnitX(u), GetUnitY(u), 80)
        SetTextTagColor(t, r or 255, g or 220, b or 0, 255)
        SetTextTagVelocity(t, 0, 0.03)
        SetTextTagPermanent(t, false)
        SetTextTagLifespan(t, 2.5)
        SetTextTagFadepoint(t, 1.5)
    end

    function W.addGold(p, amount)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD) + math.floor(amount))
    end

    -- Players who share a team reward with p: every Dota hero player, or the
    -- commander alone.
    function W.teamPlayers(p)
        local Roles = use("roles")
        local side = Roles.side(GetPlayerId(p))
        local out = {}
        if side == "dota" then
            for _, slot in ipairs(Roles.heroSlots) do out[#out + 1] = Player(slot) end
        elseif side == "commander" and Roles.commander then
            out[1] = Player(Roles.commander)
        else
            out[1] = p
        end
        return out
    end

    -- Base attack damage as Dota counts it (heroes: plus the main attribute).
    function W.baseDamage(u)
        local d = BlzGetUnitBaseDamage(u, 0) + BlzGetUnitDiceNumber(u, 0) * (BlzGetUnitDiceSides(u, 0) + 1) / 2
        if IsUnitType(u, UNIT_TYPE_HERO) then
            d = d + math.max(GetHeroStr(u, true), GetHeroAgi(u, true), GetHeroInt(u, true))
        end
        return d
    end

    function W.playerName(u)
        return GetPlayerName(GetOwningPlayer(u))
    end

    -- ------------------------------------------------------------ start

    local function sweep()
        for u in pairs(lane) do
            if not U.alive(u) then lane[u] = nil end
        end
    end

    -- Starts the game clock and every world system. Call once after
    -- use("structures").create().
    function W.init()
        if W.started then return end
        if not defined("data.world") or not use("data.ids").world then
            Log.warn("world: no data (run tools/extract_world.py and rebuild objects)")
            return
        end
        W.started = true
        t0 = Timer.now()
        for _, name in ipairs({"world_camps", "world_runes", "world_roshan", "world_towers"}) do
            Safe.call(function() use(name).init(W) end)
        end
        Timer.every(0.25, tick)
        Timer.every(30, sweep)
        Events.emit("world_started")
        tick()
        Log.info("world: clock started")
    end

    return W
end)
