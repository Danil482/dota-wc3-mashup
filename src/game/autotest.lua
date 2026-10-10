-- In-game test harness (test builds only). Runs scripted checks and logs
-- PASS/FAIL lines plus "TEST DONE"; tools/run_test.ps1 reads the log file.
AUTOTEST_ROLE = AUTOTEST_ROLE or "hero"

define("autotest", function()
    local Log = use("log")
    local Timer = use("timer")
    local Roles = use("roles")
    local U = use("util")
    local T = {}
    local steps = {}
    local deaths = 0
    local botCasts = 0

    function T.at(seconds, name, fn)
        steps[#steps + 1] = {at = seconds, name = name, fn = fn}
    end

    T.at(1, "roles assigned", function()
        return Roles.commander ~= nil and #Roles.heroSlots == 5,
            "commander " .. tostring(Roles.commander) .. ", heroes " .. #Roles.heroSlots
    end)

    T.at(1, "dota structures", function()
        local S = use("structures")
        return S.count() == 11 and U.alive(S.ancient) and U.alive(S.fountain),
            "towers " .. S.count() .. ", ancient " .. tostring(U.alive(S.ancient))
    end)

    T.at(1, "tier protection", function()
        local S = use("structures")
        return BlzIsUnitInvulnerable(S.towers.mid[2]) and not BlzIsUnitInvulnerable(S.towers.mid[1]),
            "t1 open, t2 protected"
    end)

    T.at(50, "bot heroes spawned", function()
        local H = use("heroes")
        return H.count() >= 5 - Roles.humanCount, "heroes " .. H.count()
    end)

    T.at(2, "commander base", function()
        local Cmd = use("commander")
        return Cmd.halls() >= 1, "halls " .. Cmd.halls() .. ", race " .. tostring(Cmd.raceKey)
    end)

    -- Gameplay constants: Dota hero HP = 120 + 22 per strength point.
    T.at(3, "dota attribute constants", function()
        local H = use("heroes")
        for _, u in pairs(H.bySlot) do
            local expect = 120 + 22 * GetHeroStr(u, true)
            local hp = BlzGetUnitMaxHP(u)
            return math.abs(hp - expect) <= 2, "max hp " .. hp .. ", expected " .. expect
        end
        return false, "no hero"
    end)

    -- Object data: our ability objects exist with their tooltips.
    T.at(3, "ability objects", function()
        local id = use("abilities").id("pudge_meat_hook")
        local tip = id and BlzGetAbilityTooltip(id, 0) or ""
        return string.find(tip, "Meat Hook") ~= nil, "tooltip '" .. tip .. "'"
    end)

    T.at(50, "bots active", function()
        local n = use("hero_bot").count()
        return n == 5 - Roles.humanCount, "bots " .. n
    end)

    T.at(70, "heroes left base", function()
        local f = use("data.mapdata").dota.fountain
        local out = 0
        for _, u in pairs(use("heroes").bySlot) do
            if U.dist(GetUnitX(u), GetUnitY(u), f.x, f.y) > 2500 then out = out + 1 end
        end
        return out >= 2, "heroes away from fountain " .. out
    end)

    T.at(115, "heroes gain experience", function()
        local best = 0
        for _, u in pairs(use("heroes").bySlot) do best = math.max(best, GetHeroXP(u)) end
        return best > 0, "max xp " .. best
    end)

    T.at(36, "first creep wave", function()
        local C = use("creeps")
        local d, h = C.count(SLOT_ANCIENTS), C.count(SLOT_HORDE)
        return d >= 12 and h >= 12, "dota " .. d .. ", horde " .. h
    end)

    T.at(116, "bots cast abilities", function()
        return botCasts > 0, "bot casts " .. botCasts
    end)

    T.at(110, "lanes fight", function()
        return deaths > 0, "deaths " .. deaths
    end)

    function T.run()
        use("events").on("death", function() deaths = deaths + 1 end)
        use("events").on("ability_cast", function(caster, def)
            if def and Roles.isBot(GetPlayerId(GetOwningPlayer(caster))) then
                botCasts = botCasts + 1
                Log.info("bot cast " .. def.name)
            end
        end)
        table.sort(steps, function(a, b) return a.at < b.at end)
        local last = 0
        for _, s in ipairs(steps) do
            last = math.max(last, s.at)
            Timer.after(s.at, function()
                local ok, detail = s.fn()
                Log.check(s.name, ok, detail)
            end)
        end
        Timer.after(last + 1, function()
            Log.info("TEST DONE")
            Log.flush()
        end)
    end

    return T
end)
