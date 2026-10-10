-- Neutral camps at every mapdata "camps" spot, Neutral Hostile. A camp's
-- type comes from its name (small, medium, large, ancient); the outer camps
-- (o_top1, o_bot2, ...) carry no type: their 1 is medium, their 2 large.
-- Dota rules: first spawn at 1:00, then on every full minute when nothing
-- stands in the spawn box, so pulling creeps out before the minute stacks the
-- camp. Creeps dragged past the leash walk home and heal back. Each spawn
-- picks a random Dota composition for the camp type; neutral upgrades (every
-- 7.5 minutes: health, damage, armor, attack speed, gold, XP) and the Dota
-- magic resistance apply at spawn. Bounty: Dota gold range plus upgrades and
-- XP, through World.bountyOf. Ancients are WC3 "ancient" units (object data).
define("world_camps", function()
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Mods = use("mods")
    local U = use("util")
    local C = {camps = {}, creeps = {}}

    C.BOX = 360               -- spawn box radius around the camp spot
    C.SPREAD = 140            -- creeps stand on a circle this wide
    C.LEASH = 800             -- farther than this from the camp: walk home
    C.HOME = 120              -- "home" when this close to the spawn point
    C.ALERT = 600             -- camp mates within this join a fight

    -- Dota compositions per camp type (npc_dota_neutral_<name>).
    C.POOLS = {
        small = {
            {"kobold", "kobold", "kobold", "kobold_tunneler", "kobold_taskmaster"},
            {"forest_troll_berserker", "forest_troll_berserker", "forest_troll_high_priest"},
            {"gnoll_assassin", "gnoll_assassin", "gnoll_assassin"},
            {"ghost", "fel_beast", "fel_beast"},
            {"harpy_scout", "harpy_scout", "harpy_storm"},
        },
        medium = {
            {"alpha_wolf", "giant_wolf", "giant_wolf"},
            {"ogre_magi", "ogre_mauler", "ogre_mauler"},
            {"satyr_soulstealer", "satyr_trickster", "satyr_trickster"},
            {"mud_golem", "mud_golem"},
        },
        large = {
            {"centaur_khan", "centaur_outrunner", "centaur_outrunner"},
            {"satyr_hellcaller", "satyr_soulstealer", "satyr_trickster", "satyr_trickster"},
            {"polar_furbolg_ursa_warrior", "polar_furbolg_champion", "polar_furbolg_champion"},
            {"enraged_wildkin", "wildkin", "wildkin"},
            {"dark_troll_warlord", "dark_troll", "dark_troll"},
        },
        ancient = {
            {"black_dragon", "black_drake", "black_drake"},
            {"granite_golem", "rock_golem", "rock_golem"},
            {"big_thunder_lizard", "small_thunder_lizard", "small_thunder_lizard"},
        },
    }

    local W                   -- the world module (set by init)
    local MOVE = nil          -- order id of "move"
    local bounty = {}         -- creep -> {name, n}: kept after persuasion or death
    local ignore = {}         -- unit type id -> true: wards never block a spawn box

    local function neutral() return Player(PLAYER_NEUTRAL_AGGRESSIVE) end

    function C.typeOf(name)
        for _, t in ipairs({"ancient", "large", "medium", "small"}) do
            if string.find(name, t, 1, true) then return t end
        end
        return string.match(name, "(%d)$") == "2" and "large" or "medium"
    end

    -- Neutral upgrade steps reached by now (neutral_upgrade ability values).
    function C.level()
        local up = W.data().neutral_upgrade
        return math.min(up.max_level, math.floor(W.clock() / up.increase_time))
    end

    local function upgrade(u, n)
        if n <= 0 then return end
        local up = W.data().neutral_upgrade
        local hp = BlzGetUnitMaxHP(u) + up.increase_health * n
        BlzSetUnitMaxHP(u, hp)
        SetWidgetLife(u, hp)
        BlzSetUnitBaseDamage(u, BlzGetUnitBaseDamage(u, 0) + up.increase_damage * n, 0)
        BlzSetUnitArmor(u, BlzGetUnitArmor(u) + up.increase_armor * n)
        local cd = BlzGetUnitAttackCooldown(u, 0)
        if cd > 0 then BlzSetUnitAttackCooldown(u, cd / (1 + up.increase_aspd * n / 100), 0) end
    end

    -- Units standing in the spawn box (wards do not count).
    function C.occupants(camp)
        return U.enum(camp.x, camp.y, C.BOX, function(u)
            return not ignore[GetUnitTypeId(u)] and GetUnitAbilityLevel(u, FourCC("Aloc")) == 0
        end)
    end

    function C.spawn(camp)
        local pool = C.POOLS[camp.kind]
        local set = pool[GetRandomInt(1, #pool)]
        local n = C.level()
        local turn = GetRandomReal(0, 2 * math.pi)
        local made = {}
        for i, name in ipairs(set) do
            local code = W.code("units", "neutral_" .. name)
            if code then
                local x, y = U.polar(camp.x, camp.y, C.SPREAD, turn + 2 * math.pi * i / #set)
                local u = CreateUnit(neutral(), code, x, y, GetRandomReal(0, 360))
                UnitAddSleepPerm(u, false)
                upgrade(u, n)
                local resist = (W.data().neutrals[name] or {}).magic_resist or 0
                if resist > 0 then
                    Mods.add(u, "neutral_resist", {dispel = "none", props = {magic_resist = resist / 100}})
                end
                C.creeps[u] = {camp = camp, hx = x, hy = y, returning = false}
                bounty[u] = {name = name, n = n}
                made[#made + 1] = u
            end
        end
        camp.spawns = camp.spawns + 1
        return made
    end

    -- Every full minute from 1:00: spawn where the box is empty.
    function C.minute()
        for _, camp in ipairs(C.camps) do
            if #C.occupants(camp) == 0 then C.spawn(camp) end
        end
    end

    local function goHome(u, c)
        c.returning = true
        IssuePointOrder(u, "move", c.hx, c.hy)
    end

    -- Leash: past C.LEASH from the camp a creep walks back, ignoring attacks,
    -- and heals fully once home. Persuaded creeps (Chen) are let go.
    function C.leash()
        for u, c in pairs(C.creeps) do
            if not U.alive(u) or GetOwningPlayer(u) ~= neutral() then
                C.creeps[u] = nil
            elseif c.returning then
                if U.dist(GetUnitX(u), GetUnitY(u), c.hx, c.hy) <= C.HOME then
                    c.returning = false
                    SetWidgetLife(u, BlzGetUnitMaxHP(u))
                    SetUnitState(u, UNIT_STATE_MANA, GetUnitState(u, UNIT_STATE_MAX_MANA))
                    IssueImmediateOrder(u, "stop")
                elseif GetUnitCurrentOrder(u) ~= MOVE then
                    IssuePointOrder(u, "move", c.hx, c.hy)
                end
            elseif U.dist(GetUnitX(u), GetUnitY(u), c.camp.x, c.camp.y) > C.LEASH then
                goHome(u, c)
            end
        end
    end

    -- An attacked camp creep and its idle camp mates fight back (WC3 creeps
    -- do this too; this also covers attackers beyond acquisition range).
    function C.attacked(attacker, target)
        local c = C.creeps[target]
        if not c or c.returning or not attacker or not U.alive(target) then return end
        if U.dist(GetUnitX(attacker), GetUnitY(attacker), c.camp.x, c.camp.y) > C.LEASH then return end
        for u, o in pairs(C.creeps) do
            if o.camp == c.camp and not o.returning and U.alive(u) and GetUnitCurrentOrder(u) == 0
                and U.unitDist(u, target) <= C.ALERT then
                IssueTargetOrder(u, "attack", attacker)
            end
        end
    end

    function C.bountyOf(u)
        local b = bounty[u]
        if not b then return nil end
        local d = W.data().neutrals[b.name]
        local up = W.data().neutral_upgrade
        if not d then return nil end
        return GetRandomInt(d.gold_min, d.gold_max) + up.increase_gold * b.n, d.xp + up.increase_xp * b.n
    end

    function C.count(camp)
        local n = 0
        for u, c in pairs(C.creeps) do
            if U.alive(u) and (camp == nil or c.camp == camp) then n = n + 1 end
        end
        return n
    end

    function C.find(name)
        for _, camp in ipairs(C.camps) do
            if camp.name == name then return camp end
        end
        return nil
    end

    local function cleanup()
        for u in pairs(bounty) do
            if not U.alive(u) then bounty[u] = nil end
        end
    end

    function C.init(world)
        W = world
        MOVE = OrderId("move")
        local units = use("data.ids").units
        for _, key in ipairs({"wardobserver", "wardsentry"}) do
            if units[key] then ignore[FourCC(units[key])] = true end
        end
        local names = {}
        for name in pairs(use("data.mapdata").camps or {}) do names[#names + 1] = name end
        table.sort(names)         -- same order on every machine
        for _, name in ipairs(names) do
            local p = use("data.mapdata").camps[name]
            C.camps[#C.camps + 1] = {name = name, kind = C.typeOf(name), x = p.x, y = p.y, spawns = 0}
        end
        W.addBounty(C.bountyOf)
        W.at(60, 60, C.minute)
        Timer.every(0.5, C.leash)
        Timer.every(30, cleanup)
        Events.on("attacked", C.attacked)
        Log.info("world: " .. #C.camps .. " neutral camps")
    end

    return C
end)
