-- Offline exercise for the music director (src/game/music.lua). Runs after
-- the main mock run with Dota's track data compressed 20x in time, records
-- every sound the director creates (path, the local player's volume, start
-- and stop) and walks one Dota player through a game: the countdown, the
-- horn, laning tracks, a battle with loop copies and its outro on a sync
-- point, Roshan, death and respawn, a buyback, announcer ducking and the
-- victory stinger. Also checks that the commander hears none of it, and that
-- the deck decisions do not depend on the local player. Failed checks become
-- ERROR lines, which fail the mock run.
do
    local saved = {}
    local function stub(name, fn)
        if saved[name] == nil then saved[name] = _G[name] end
        _G[name] = fn
    end
    local function orig(name) return saved[name] or _G[name] end
    local function restore()
        for name, fn in pairs(saved) do _G[name] = fn end
        saved = {}
    end

    local function advance(seconds)
        local target = __mock.now + seconds
        while true do
            local nextT, nextDue = nil, math.huge
            for t in pairs(__mock.timers) do
                if t.active and t.due <= target and t.due < nextDue then nextT, nextDue = t, t.due end
            end
            if not nextT then break end
            __mock.now = nextDue
            if nextT.periodic then nextT.due = nextT.due + math.max(nextT.timeout, 0.001) else nextT.active = false end
            if nextT.fn then nextT.fn() end
        end
        __mock.now = target
    end

    local SCALE = 0.05
    local sounds = {}
    local listener = {slot = 0}

    local function install()
        stub("GetLocalPlayer", function() return Player(listener.slot) end)
        stub("CreateSound", function(path, looping, is3d)
            local s = __handle("sound")
            s.path, s.looping, s.is3d, s.vol, s.created = path, looping, is3d, 127, __mock.now
            sounds[#sounds + 1] = s
            return s
        end)
        stub("SetSoundVolume", function(s, v) s.vol = v end)
        stub("SetSoundChannel", function(s, c) s.channel = c end)
        stub("StartSound", function(s) s.started = __mock.now end)
        stub("StopSound", function(s, kill) s.stopped, s.killed = __mock.now, kill end)
        stub("KillSoundWhenDone", function(s) s.autokill = true end)
        stub("IsUnitType", function(u, t)
            if type(u) ~= "table" or not u.mx then return orig("IsUnitType")(u, t) end
            if t == UNIT_TYPE_DEAD then return u.dead == true end
            if t == UNIT_TYPE_HERO then return u.hero == true end
            return false
        end)
    end

    -- data.audio.music and the director's timings, 20x faster
    local function compress(M, music)
        local back = {data = {}, tun = {}}
        for key, e in pairs(music) do
            local copy = {}
            for k, v in pairs(e) do copy[k] = v end
            back.data[key] = copy
            for _, f in ipairs({"duration", "start", "stop", "restart"}) do
                if e[f] then e[f] = e[f] * SCALE end
            end
            if e.sync then
                local s = {}
                for i, v in ipairs(e.sync) do s[i] = v * SCALE end
                e.sync = s
            end
        end
        for _, f in ipairs({"BATTLE_WINDOW", "BATTLE_HOLD", "ROSHAN_HOLD", "HORN_FADE", "JOIN_DEAD"}) do
            back.tun[f] = M[f]
            M[f] = M[f] * SCALE * 2
        end
        for _, f in ipairs({"AFTER_HORN", "GAP", "RETURN"}) do
            back.tun[f] = M[f]
            M[f] = {M[f][1] * SCALE, M[f][2] * SCALE}
        end
        for _, f in ipairs({"FADE_IN", "FADE_OUT"}) do
            back.tun[f] = M[f]
            local t = {}
            for k, v in pairs(M[f]) do t[k] = v * SCALE * 2 end
            M[f] = t
        end
        return function()
            for key, copy in pairs(back.data) do
                local e = music[key]
                for k in pairs(e) do e[k] = nil end
                for k, v in pairs(copy) do e[k] = v end
            end
            for f, v in pairs(back.tun) do M[f] = v end
        end
    end

    local function exercise()
        local M, Log, Events = use("music"), use("log"), use("events")
        local music = use("data.audio").music
        local failures, checks = 0, 0
        local function check(name, ok, detail)
            checks = checks + 1
            if not ok then
                failures = failures + 1
                Log.error("music exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
            end
        end
        -- music tracks only (voice lines share names such as respawn_1)
        local function keyOf(s) return string.match(s.path, "^Sound\\Dota\\music\\([%w_]+)%.%w+$") end
        local function live(prefix)
            local out = {}
            for _, s in ipairs(sounds) do
                if not s.killed and string.find(keyOf(s) or "", "^" .. prefix) then out[#out + 1] = s end
            end
            return out
        end
        local function created(prefix, since)
            local n = 0
            for _, s in ipairs(sounds) do
                if s.created >= since and string.find(keyOf(s) or "", "^" .. prefix) then n = n + 1 end
            end
            return n
        end
        local function loudest(prefix)
            local v = 0
            for _, s in ipairs(live(prefix)) do v = math.max(v, s.vol) end
            return v
        end
        local function vol(key) return math.floor(127 * music[key].volume + 0.5) end

        -- the real hero of slot 0 (spawned by heroes.lua; never replaced here)
        local H = use("heroes")
        local waited = 0
        while not H.bySlot[0] and waited < 60 do
            advance(1)
            waited = waited + 1
        end
        local hero = H.bySlot[0]
        if not hero then
            Log.warn("music exercise: no hero spawned, skipped")
            return
        end
        local undo = compress(M, music)
        hero.mx, hero.hero = true, true
        local foe = CreateUnit(Player(7), FourCC("hfoo"), -4900, -5000, 0)
        local foeHero = CreateUnit(Player(7), FourCC("Hpal"), -4900, -5100, 0)
        foe.mx, foeHero.mx, foeHero.hero = true, true, true
        local wave = CreateUnit(Player(SLOT_HORDE), FourCC("hfoo"), -4900, -4900, 0)
        wave.mx = true

        local fresh = not M.started
        if fresh then
            M.init()
            check("one Dota listener", #M.listeners == 1, #M.listeners)
            advance(0.1)
            check("countdown plays", #live("countdown") == 1 and loudest("countdown") == vol("countdown"),
                loudest("countdown"))
            check("music on the configured channel",
                live("countdown")[1] and live("countdown")[1].channel == M.CHANNEL)
            -- the horn: the countdown fades, a laning track follows
            M.horn()
            advance(M.HORN_FADE + 0.2)
            check("countdown gone after the horn", #live("countdown") == 0)
            advance(M.AFTER_HORN[2] + 0.2)
        else
            -- started by game.lua: tracks begun before the exercise are not
            -- recorded; the laning checks follow the battle below
            Log.info("music exercise: the director was started by game.lua, countdown checks skipped")
            M.horn()
            advance(1)
        end
        local laning = live("laning")
        if fresh or #laning > 0 then
            check("a laning track after the horn", #laning == 1, #laning)
            check("laning at Dota's volume", laning[1] and laning[1].vol == vol(keyOf(laning[1])),
                laning[1] and laning[1].vol)
            -- the announcer ducks the music
            M.duck(0.5)
            advance(0.1)
            check("music steps back under the announcer", laning[1] and laning[1].vol < vol(keyOf(laning[1])),
                laning[1] and laning[1].vol)
            advance(0.6)
        end

        -- creep waves start no battle; the commander's units do
        Events.emit("damaged", wave, hero)
        Events.emit("damaged", wave, hero)
        Events.emit("damaged", wave, hero)
        advance(0.1)
        check("no battle against creep waves", M.state(0) == "main", M.state(0))
        local tb = __mock.now
        Events.emit("damaged", foe, hero)
        Events.emit("damaged", hero, foeHero)
        advance(0.1)
        check("battle state", M.state(0) == "battle", M.state(0))
        local battle = live("battle_0")
        check("a battle track starts", #battle == 1, #battle)
        local key = battle[1] and keyOf(battle[1])
        -- keep fighting over two loop restarts
        local e = key and music[key]
        local restart = e and (e.restart or (e.stop - e.start)) or 1
        local t = 0
        while t < restart * 2.2 do
            Events.emit("damaged", foe, hero)
            advance(0.1)
            t = t + 0.1
        end
        check("the loop restarts from the top", created(key or "x", tb) >= 3, created(key or "x", tb))
        check("laning music stopped during the battle", #live("laning") == 0 or loudest("laning") == 0)
        check("battle at Dota's volume", loudest("battle_0") == vol(key or "battle_01"), loudest("battle_0"))
        -- stop fighting: the outro starts on a sync point and the loop stops there
        local te = __mock.now
        advance(M.BATTLE_HOLD + 0.2)
        check("the fight is over", M.state(0) == "main", M.state(0))
        local outro = (key or "x") .. "_end"
        local waitedEnd = 0
        while created(outro, te) == 0 and waitedEnd < 3 do
            advance(0.05)
            waitedEnd = waitedEnd + 0.05
        end
        check("battle outro plays", created(outro, te) == 1, created(outro, te))
        advance(0.1)
        check("the outro is heard", loudest(outro) > 0, loudest(outro))
        advance(2)
        check("the battle loop has stopped", #live(key or "x") <= 1)
        advance(M.RETURN[2] + music.battle_01_end.duration + 0.5)
        check("laning music returns", #live("laning") >= 1 and loudest("laning") > 0, #live("laning"))

        -- Roshan
        local rosh = defined("world") and use("world").code("units", "roshan")
        if rosh then
            local r = CreateUnit(Player(PLAYER_NEUTRAL_AGGRESSIVE), rosh, -4800, -5000, 0)
            local tr = __mock.now
            for _ = 1, 10 do
                Events.emit("damaged", hero, r)
                advance(0.1)
            end
            check("Roshan state", M.state(0) == "roshan", M.state(0))
            check("Roshan's music", created("roshan", tr) >= 1 and loudest("roshan") > 0)
            advance(M.ROSHAN_HOLD + music.roshan.duration)
            check("Roshan's outro", created("roshan_end", tr) == 1, created("roshan_end", tr))
            advance(1)
        end

        -- death and respawn
        local td = __mock.now
        Events.emit("death", hero, foeHero)
        advance(0.5)
        check("dead state", M.state(0) == "dead", M.state(0))
        check("death music at full volume", loudest("killed") == vol("killed"), loudest("killed"))
        check("nothing else heard while dead", loudest("laning") == 0 and loudest("battle") == 0)
        Events.emit("hero_respawned", hero, "pudge", 0)
        advance(0.5)
        check("death music fades on respawn", #live("killed") == 0)
        check("respawn stinger", created("respawn", td) == 1 and loudest("respawn") == vol("respawn"))
        -- a buyback: its own stinger, no respawn stinger
        advance(music.respawn.duration + 0.5)
        local tbb = __mock.now
        Events.emit("death", hero, foeHero)
        advance(0.3)
        M.buyback(hero)
        Events.emit("hero_respawned", hero, "pudge", 0)
        advance(0.3)
        check("buyback stinger", created("buy_back", tbb) == 1)
        check("no respawn stinger after a buyback", created("respawn", tbb) == 0)
        check("death music gone after the buyback", #live("killed") == 0)

        -- the decisions are the same on every client: as the commander's
        -- client, the same tracks exist and are silent
        local function tracks()
            local n = 0
            for _, s in ipairs(sounds) do
                if keyOf(s) then n = n + 1 end
            end
            return n
        end
        local count = tracks()
        listener.slot = 7
        advance(0.2)
        local loud = 0
        for _, s in ipairs(sounds) do
            if keyOf(s) and not s.killed and s.vol > 0 then loud = loud + 1 end
        end
        check("the commander hears no Dota music", loud == 0, loud)
        check("no extra tracks for another client", tracks() == count, tracks() - count)
        listener.slot = 0
        advance(0.2)

        -- victory
        local tv = __mock.now
        M.gameOver("dota")
        advance(1.5)
        check("victory stinger", created("radiant_win", tv) == 1 and loudest("radiant_win") == vol("radiant_win"))
        local others = 0
        for _, s in ipairs(sounds) do
            if keyOf(s) and not s.killed and keyOf(s) ~= "radiant_win" and s.vol > 0 then others = others + 1 end
        end
        check("everything else fades at the end", others == 0, others)

        foe.dead, foeHero.dead, wave.dead = true, true, true
        hero.mx, hero.hero = nil, nil
        undo()
        Log.info("music exercise: " .. checks .. " checks, " .. failures .. " failed, "
            .. #sounds .. " tracks started")
    end

    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("music") or not defined("data.audio") then return end
        done = true
        install()
        local ok, err = xpcall(exercise, debug and debug.traceback or tostring)
        restore()
        if not ok then use("log").error("music exercise crashed: " .. tostring(err)) end
        use("log").flush()
    end
end
