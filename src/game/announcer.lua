-- Dota's default announcer for the Dota players (data.audio.announcer, from
-- the player's own Dota 2; tools/select_vo.py): the pre-game lines and the
-- horn at 0:00, first blood, kill streaks and multi-kills, the Dota team's
-- towers and barracks falling, denied or under attack, enemy towers falling,
-- Roshan's death and the end of the game. The Dota team plays Radiant: "your"
-- lines are about its buildings, Roshan "has fallen to the Radiant" when the
-- heroes kill him and "to the Dire" when the Warcraft side does. As in
-- Dota, lines never overlap: they queue by priority, stale ones are dropped,
-- and the music steps back while one plays. Only Dota players hear them; the
-- Warcraft player keeps Warcraft's sounds.
--
-- Hooks: announcer.init([secondsToHorn]) in game.lua begin() right after
-- creeps.start (the horn defaults to the first lane wave, creeps.first);
-- announcer.gameOver(winnerSide) in victory.lua; announcer.say(key) for the
-- lines other modules own: "fort_rad" (Glyph), "scan_rad" (Scan),
-- "cour_kill_rad" (the courier died).
define("announcer", function()
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Roles = use("roles")
    local Sound = use("sound")
    local A = {started = false, over = false, hornAt = nil, hornDone = false, firstBlood = false}

    A.GAP = 0.3                 -- silence between two lines
    A.MAX_AGE = {[0] = 4, [1] = 12, [2] = 10, [3] = 12}  -- seconds a queued line may wait, by priority
    A.MAX_QUEUE = 6
    -- Dota 2 wiki, "Kill streak" (multi-kills): each kill within 18 s of the
    -- previous one; not in Dota's game files.
    A.MULTI_WINDOW = 18
    A.TOWER_ALERT = 60          -- seconds between "under attack" lines of one building
    A.ANCIENT_ALERT = 20
    A.ALERT_QUIET = 10          -- an attack is new after this long without enemy hits
    A.ENEMY_TOWER_GAP = 8       -- seconds between two "An enemy tower has fallen."

    local STREAK = {[3] = "kill_spree", [4] = "kill_dominate", [5] = "kill_mega", [6] = "kill_unstop",
                    [7] = "kill_wicked", [8] = "kill_monster", [9] = "kill_godlike"}    -- 10+: kill_holy
    local MULTI = {[2] = "kill_double", [3] = "kill_triple", [4] = "kill_ultra"}        -- 5+: kill_rampage
    -- Warcraft's attacking towers of the four races (the Warcraft base)
    local ENEMY_TOWERS = {"hgtw", "hctw", "hatw", "owtw", "uzg1", "uzg2", "etrp"}

    local queue = {}
    local busyUntil = 0
    local streak, multi = {}, {}        -- hero -> kills since its last death / current multi-kill
    local lastDeath = {}                -- Dota player slot -> time (Meepo's clones die together)
    local hits, alerts = {}, {}         -- building -> last enemy hit / last "under attack" line
    local enemyTower = {}
    local lastEnemyTower = -100
    local roshanCode = nil

    local function now() return Timer.now() end
    local function sideOf(u) return Roles.side(GetPlayerId(GetOwningPlayer(u))) end
    local function heroOfSlot(slot) return defined("heroes") and use("heroes").bySlot[slot] or nil end

    local function pump()
        local t = now()
        if t < busyUntil or #queue == 0 then return end
        local keep = {}
        for _, q in ipairs(queue) do
            if t - q.at <= (A.MAX_AGE[q.priority] or 6) then keep[#keep + 1] = q end
        end
        queue = keep
        local best, at = nil, nil
        for i, q in ipairs(queue) do
            if not best or q.priority > best.priority then best, at = q, i end
        end
        if not best then return end
        table.remove(queue, at)
        Sound.play(best.e.path, "dota", {volume = best.e.volume})
        busyUntil = t + best.e.duration + A.GAP
        if defined("music") then use("music").duck(best.e.duration) end
    end

    -- Queues a line (data.audio.announcer key). priority: 3 match flow and
    -- first blood, 2 kills and Roshan, 1 buildings falling, 0 alerts. A line
    -- with a tag replaces a waiting line with the same tag ("Double kill!"
    -- still waiting when the triple comes is not said).
    function A.say(key, priority, tag)
        local e = Sound.entry("announcer", key)
        if not e then return end
        if A.over and key ~= "victory_rad" and key ~= "victory_dire" then return end
        priority = priority or 1
        if tag then
            for i, q in ipairs(queue) do
                if q.tag == tag then
                    table.remove(queue, i)
                    break
                end
            end
        end
        if #queue >= A.MAX_QUEUE then
            local low = 1
            for i, q in ipairs(queue) do
                if q.priority < queue[low].priority then low = i end
            end
            if queue[low].priority > priority then return end
            table.remove(queue, low)
        end
        queue[#queue + 1] = {key = key, e = e, priority = priority, at = now(), tag = tag}
        pump()
    end

    -- ------------------------------------------------------------ match flow

    -- The horn at 0:00: Dota's horn, "The battle begins!", the music's turn
    -- from the countdown, and each hero player's own battle cry.
    function A.horn()
        if A.hornDone then return end
        A.hornDone = true
        Sound.sfx("horn", "dota")
        A.say("battle_begin", 3)
        if defined("music") then use("music").horn() end
        for _, slot in ipairs(Roles.heroSlots) do
            local hero = heroOfSlot(slot)
            if hero and Roles.humans[slot] then Sound.vo(hero, "battlebegins", 1, true) end
        end
    end

    -- Schedules the pre-game lines and the horn `hornIn` seconds from now.
    function A.clock(hornIn)
        local t = now()
        A.hornAt = t + hornIn
        local function at(when, fn) Timer.after(math.max(0, when - now()), fn) end
        if hornIn >= 25 then A.say("battle_prepare", 3) end
        if hornIn >= 29 then at(A.hornAt - 30, function() A.say("count_battle_30", 3) end) end
        if hornIn >= 9 then at(A.hornAt - 10, function() A.say("count_battle_10", 3) end) end
        at(A.hornAt, A.horn)
    end

    -- The end of the game: "Radiant victory!" or "Dire victory!" and the
    -- music's stinger. Call before Warcraft's victory dialog.
    function A.gameOver(winnerSide)
        if A.over then return end
        A.over = true
        queue, busyUntil = {}, 0
        A.say(winnerSide == "dota" and "victory_rad" or "victory_dire", 3)
        if defined("music") then use("music").gameOver(winnerSide) end
    end

    -- ------------------------------------------------------------ kills

    -- The hero a kill counts for: a Dota player's hero for anything that
    -- player owns (summons, illusions), else a real hero, else none (towers,
    -- creeps and the Warcraft army still end streaks and draw first blood).
    local function credit(killer)
        local hero = heroOfSlot(GetPlayerId(GetOwningPlayer(killer)))
        if hero then return hero end
        if IsUnitType(killer, UNIT_TYPE_HERO) and not IsUnitIllusion(killer) then return killer end
        return nil
    end

    local function heroDied(dying, killer)
        local t = now()
        local slot = GetPlayerId(GetOwningPlayer(dying))
        local own = heroOfSlot(slot)
        if own then
            if lastDeath[slot] and t - lastDeath[slot] < 0.1 then return end
            lastDeath[slot] = t
        end
        local victim = own or dying
        streak[victim], multi[victim] = nil, nil
        if not killer or killer == dying then return end
        local ks, ds = sideOf(killer), sideOf(dying)
        if ks == ds or ks == "none" or ds == "none" then return end
        local hero = credit(killer)
        if not A.firstBlood then
            A.firstBlood = true
            A.say("first_blood", 3)
            if hero then Sound.vo(hero, "firstblood") end
        end
        if not hero then return end
        local m = multi[hero]
        if m and t - m.last <= A.MULTI_WINDOW then
            m.n, m.last = m.n + 1, t
        else
            m = {n = 1, last = t}
            multi[hero] = m
        end
        local id = GetHandleId(hero)
        if m.n >= 2 then A.say(m.n >= 5 and "kill_rampage" or MULTI[m.n], 2, "multi" .. id) end
        local n = (streak[hero] or 0) + 1
        streak[hero] = n
        if n >= 3 then A.say(n >= 10 and "kill_holy" or STREAK[n], 2, "streak" .. id) end
    end

    function A.streak(hero) return streak[hero] or 0 end

    -- ------------------------------------------------------------ buildings

    -- "tower"/"rax"/"ancient" and the lane ("top", "mid", "bot", "base") of a
    -- Dota team building, or nil.
    local function building(u)
        local S = defined("structures") and use("structures") or nil
        local kind = S and u and S.kindOf(u)
        if not kind then return nil end
        return kind, S.laneOf(u)
    end

    local function buildingDied(dying, killer)
        local kind, lane = building(dying)
        if kind == "tower" then
            local denied = killer ~= nil and sideOf(killer) == "dota"
            if lane == "base" then
                if not denied then A.say("tower_fallen", 1) end
            else
                A.say((denied and "twr_deny_yr_" or "twr_fall_yr_") .. lane, 1)
            end
        elseif kind == "rax" then
            A.say("rax_fall_yr_" .. lane, 1)
        elseif kind == nil and enemyTower[GetUnitTypeId(dying)] and sideOf(dying) == "warcraft"
            and killer and sideOf(killer) == "dota" and now() - lastEnemyTower >= A.ENEMY_TOWER_GAP then
            lastEnemyTower = now()
            A.say("tower_enemy_fallen", 1)
        end
    end

    -- "Your top tower is under attack.": the Warcraft player's units or heroes
    -- start hitting one of our buildings (his creep waves only for the Ancient).
    local function buildingHit(source, target)
        local kind, lane = building(target)
        if not kind or sideOf(source) ~= "warcraft" then return end
        if kind ~= "ancient" and GetPlayerId(GetOwningPlayer(source)) == SLOT_HORDE then return end
        local t = now()
        local quiet = t - (hits[target] or -1000) >= A.ALERT_QUIET
        hits[target] = t
        if kind == "ancient" then
            if t - (alerts[target] or -1000) >= A.ANCIENT_ALERT then
                alerts[target] = t
                A.say("anc_attack_yr", 1)
            end
        elseif quiet and t - (alerts[target] or -1000) >= A.TOWER_ALERT then
            alerts[target] = t
            if kind == "tower" then
                A.say(lane == "base" and "tower_attack" or ("twr_attack_yr_" .. lane), 0)
            else
                A.say("rax_attack_yr_" .. lane, 0)
            end
        end
    end

    local function roshanDied(dying, killer)
        local by = killer and sideOf(killer) or "none"
        if by == "dota" then
            A.say("roshan_fallen_rad", 2)
        elseif by == "warcraft" then
            A.say("roshan_fallen_dire", 2)
        end
        Sound.sfx("roshan_death", nil, GetUnitX(dying), GetUnitY(dying), 1, {near = 1500, far = 9000})
    end

    -- ------------------------------------------------------------ start

    local function onDeath(dying, killer)
        if not dying then return end
        if IsUnitType(dying, UNIT_TYPE_HERO) and not IsUnitIllusion(dying) and sideOf(dying) ~= "none" then
            heroDied(dying, killer)
        elseif roshanCode and GetUnitTypeId(dying) == roshanCode then
            roshanDied(dying, killer)
        elseif IsUnitType(dying, UNIT_TYPE_STRUCTURE) then
            buildingDied(dying, killer)
        end
    end

    -- Without the victory.lua hook the end still gets its line, a moment late.
    local function watchVictory()
        if A.over then return true end
        if not defined("victory") or not use("victory").over then return end
        local S = defined("structures") and use("structures") or nil
        local ancient = S and S.ancient
        A.gameOver((ancient and not use("util").alive(ancient)) and "warcraft" or "dota")
        return true
    end

    -- Test builds: -ann <key> plays a line, -horn sounds the horn now,
    -- -gg dota|warcraft plays the end of the game.
    local function testCommands()
        local trig = CreateTrigger()
        for i = 0, SLOT_WARCRAFT do
            TriggerRegisterPlayerChatEvent(trig, Player(i), "-ann ", false)
            TriggerRegisterPlayerChatEvent(trig, Player(i), "-horn", true)
            TriggerRegisterPlayerChatEvent(trig, Player(i), "-gg ", false)
        end
        TriggerAddAction(trig, function()
            use("safe").call(function()
                local msg = GetEventPlayerChatString()
                local key = string.match(msg, "^%-ann%s+(%S+)")
                local winner = string.match(msg, "^%-gg%s+(%a+)")
                if key then A.say(key, 3) end
                if msg == "-horn" then A.horn() end
                if winner then A.gameOver(winner == "dota" and "dota" or "warcraft") end
            end)
        end)
    end

    function A.init(hornIn)
        if A.started then return end
        A.started = true
        for _, code in ipairs(ENEMY_TOWERS) do enemyTower[FourCC(code)] = true end
        if defined("world") then roshanCode = use("world").code("units", "roshan") end
        Events.on("death", onDeath)
        Events.on("damaged", function(source, target)
            if source and target then buildingHit(source, target) end
        end)
        Timer.every(0.1, pump)
        Timer.every(0.5, watchVictory)
        A.clock(hornIn or (defined("creeps") and use("creeps").first) or 30)
        if BUILD_TEST_MODE then testCommands() end
        Log.info("announcer: horn in " .. string.format("%.0f", A.hornAt - now()) .. " s")
    end

    return A
end)
