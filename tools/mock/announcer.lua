-- Offline exercise for Dota's announcer (src/game/announcer.lua) and the
-- gameplay sounds (src/game/gamesounds.lua). Runs after the main mock run:
-- records every sound the modules create (path, volume as the local player
-- hears it, start time) and drives the horn, first blood, multi-kills and
-- streaks, Dota buildings falling, denied and under attack, Roshan, the end
-- of the game, last hits, denies, level-ups, runes, failed casts and the
-- Town Portal. Checks that lines never overlap and that the Warcraft player
-- hears none of it. Failed checks become ERROR lines, which fail the mock run.
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

    -- Same loop as __mock.advance (local, so wrappers of it are not re-entered).
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

    local sounds = {}
    local listener = {slot = 0}
    local nextId = 1000

    local function install()
        stub("GetLocalPlayer", function() return Player(listener.slot) end)
        stub("GetHandleId", function(h)
            if type(h) ~= "table" then return 0 end
            if not h.__id then nextId = nextId + 1 h.__id = nextId end
            return h.__id
        end)
        stub("CreateSound", function(path, looping, is3d)
            local s = __handle("sound")
            s.path, s.looping, s.is3d, s.vol, s.created = path, looping, is3d, 127, __mock.now
            sounds[#sounds + 1] = s
            return s
        end)
        stub("SetSoundVolume", function(s, v) s.vol = v end)
        stub("StartSound", function(s) s.started = __mock.now end)
        stub("StopSound", function(s, kill) s.stopped, s.killed = __mock.now, kill end)
        stub("KillSoundWhenDone", function(s) s.autokill = true end)
        stub("SetSoundPosition", function(s, x, y) s.x, s.y = x, y end)
        stub("IsUnitType", function(u, t)
            if type(u) ~= "table" or not u.ax then return orig("IsUnitType")(u, t) end
            if t == UNIT_TYPE_DEAD then return u.dead == true end
            if t == UNIT_TYPE_HERO then return u.hero == true end
            if t == UNIT_TYPE_STRUCTURE then return u.structure == true end
            return false
        end)
    end

    local function exercise()
        local A, G, Sound = use("announcer"), use("gamesounds"), use("sound")
        local Log, Events, Roles = use("log"), use("events"), use("roles")
        local audio = use("data.audio")
        local failures, checks = 0, 0
        local function check(name, ok, detail)
            checks = checks + 1
            if not ok then
                failures = failures + 1
                Log.error("announcer exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
            end
        end
        local function path(group, key) return audio[group][key].path end
        local function made(p, since)
            local out = {}
            for _, s in ipairs(sounds) do
                if s.path == p and s.created >= (since or 0) then out[#out + 1] = s end
            end
            return out
        end
        local function lines(since)
            local out = {}
            for _, s in ipairs(sounds) do
                if s.created >= since and string.find(s.path, "Sound\\Dota\\announcer\\", 1, true) then
                    out[#out + 1] = s
                end
            end
            return out
        end
        local function keyOf(p) return string.match(p, "\\([%w_]+)%.%w+$") end
        local function order(list)
            local keys = {}
            for _, s in ipairs(list) do keys[#keys + 1] = keyOf(s.path) end
            return table.concat(keys, ",")
        end

        -- units: the real heroes (spawned by heroes.lua, never replaced here),
        -- stand-ins owned by their players as event sources, the Warcraft
        -- player's heroes and army
        local units = {}
        local function unit(slot, code, x, y, o)
            o = o or {}
            local u = CreateUnit(Player(slot), type(code) == "string" and FourCC(code) or code, x or 0, y or 0, 0)
            u.ax, u.hero, u.structure = true, o.hero == true, o.structure == true
            units[#units + 1] = u
            return u
        end
        local H = use("heroes")
        local waited = 0
        while not (H.bySlot[0] and H.bySlot[1]) and waited < 60 do
            advance(1)
            waited = waited + 1
        end
        local hero = H.bySlot[0]
        if not hero or not H.bySlot[1] then
            Log.warn("announcer exercise: no heroes spawned, skipped")
            return
        end
        local hk = H.keyOf[hero]
        local flagged = {hero, H.bySlot[1]}
        for _, u in ipairs(flagged) do u.ax, u.hero = true, true end
        local me = unit(0, "Hpal", -5000, -5000, {hero = true})        -- our player's stand-in

        if not A.started then A.init(12) end
        if not G.started then G.init() end

        -- pre-game: ten seconds to battle, then the horn and "The battle begins!"
        if A.hornDone then
            Log.info("announcer exercise: the horn sounded before the exercise, pre-game checks skipped")
        else
            local t0, hornAt = __mock.now, A.hornAt or __mock.now
            advance(math.max(0, hornAt - __mock.now) + 0.5)
            local horn = made(path("sfx", "horn"), t0)
            check("horn plays once", #horn == 1, #horn)
            check("horn is 2D", horn[1] and not horn[1].is3d)
            check("the Dota player hears the horn", horn[1] and horn[1].vol == 127, horn[1] and horn[1].vol)
            check("battle begins said", #made(path("announcer", "battle_begin"), t0) == 1)
            if hornAt - t0 >= 10 then
                check("ten seconds to battle said", #made(path("announcer", "count_battle_10"), t0) == 1)
            end
        end
        advance(3)

        -- first blood, then two more kills at once: "Triple kill!" replaces the
        -- waiting double kill, and the third kill is a killing spree
        local c1 = unit(7, "Hpal", -4900, -5000, {hero = true})
        local c2 = unit(7, "Obla", -4900, -5100, {hero = true})
        local c3 = unit(7, "Udea", -4900, -5200, {hero = true})
        local t1 = __mock.now
        local firstBlood = A.firstBlood
        Events.emit("death", c1, me)          -- anything our player owns counts for its hero
        Events.emit("death", c2, me)
        Events.emit("death", c3, me)
        advance(10)
        local said = lines(t1)
        -- with first blood still to come the double kill waits behind it and
        -- the triple replaces it; otherwise the double is said at once
        local want = firstBlood and "kill_double,kill_triple,kill_spree" or "first_blood,kill_triple,kill_spree"
        check("kill lines in Dota's order", order(said) == want, order(said))
        for i = 2, #said do
            local prev = audio.announcer[keyOf(said[i - 1].path)]
            check("lines never overlap", said[i].created >= said[i - 1].created + prev.duration - 0.001,
                keyOf(said[i - 1].path) .. " -> " .. keyOf(said[i].path))
        end
        check("streak counted for the hero", A.streak(hero) == 3, A.streak(hero))
        -- our player's hero dies: its streak ends; a deny draws no line
        Events.emit("death", me, c1)
        check("streak ends on death", A.streak(hero) == 0, A.streak(hero))
        local mate = unit(1, "Hamg", -5000, -4900, {hero = true})
        local t2 = __mock.now
        Events.emit("death", mate, me)
        advance(3)
        check("no line for a deny", #lines(t2) == 0, order(lines(t2)))
        -- Meepo: two heroes of one player dying at once are one kill
        local clone = unit(1, "Hamg", -5000, -4800, {hero = true})
        local killer = unit(7, "Hpal", -4800, -4800, {hero = true})
        Events.emit("death", mate, killer)
        Events.emit("death", clone, killer)
        check("clones die as one kill", A.streak(killer) == 1, A.streak(killer))
        advance(4)

        -- buildings
        local S = use("structures")
        local t3 = __mock.now
        if S.towers.top and S.towers.top[1] then
            for _, lane in ipairs({"top", "mid", "bot", "base"}) do
                for _, u in ipairs(S.towers[lane] or {}) do u.ax, u.structure = true, true end
            end
            for _, lane in ipairs({"top", "mid", "bot"}) do
                for _, u in ipairs(S.barracks[lane] or {}) do u.ax, u.structure = true, true end
            end
            if S.ancient then S.ancient.ax, S.ancient.structure = true, true end
            local foot = unit(7, "hfoo", 0, 0)
            local wave = unit(SLOT_HORDE, "hfoo", 0, 0)
            Events.emit("damaged", wave, S.towers.bot[1])
            advance(0.2)
            check("creep waves raise no tower alert", #lines(t3) == 0, order(lines(t3)))
            Events.emit("damaged", foot, S.towers.bot[1])
            Events.emit("damaged", foot, S.towers.bot[1])
            advance(3)
            check("tower under attack said once", order(lines(t3)) == "twr_attack_yr_bot", order(lines(t3)))
            local t4 = __mock.now
            Events.emit("death", S.towers.top[1], foot)
            Events.emit("death", S.towers.mid[1], me)
            Events.emit("death", S.barracks.bot[1], foot)
            if S.towers.base[1] then Events.emit("death", S.towers.base[1], foot) end
            Events.emit("damaged", wave, S.ancient)
            advance(14)
            local got = order(lines(t4))
            for _, key in ipairs({"twr_fall_yr_top", "twr_deny_yr_mid", "rax_fall_yr_bot", "anc_attack_yr"}) do
                check("building line " .. key, string.find(got, key, 1, true) ~= nil, got)
            end
            if S.towers.base[1] then check("T4 line", string.find(got, "tower_fallen", 1, true) ~= nil, got) end
            -- an enemy tower falls to the Dota side
            local t5 = __mock.now
            local guard = unit(7, "hgtw", 0, 0, {structure = true})
            Events.emit("death", guard, me)
            advance(3)
            check("enemy tower line", order(lines(t5)) == "tower_enemy_fallen", order(lines(t5)))
        else
            Log.warn("announcer exercise: no Dota towers in this build, building checks skipped")
        end

        -- Roshan falls to the Radiant
        local rosh = defined("world") and use("world").code("units", "roshan")
        if rosh then
            local t6 = __mock.now
            local r = unit(PLAYER_NEUTRAL_AGGRESSIVE, rosh, 0, 0)
            Events.emit("death", r, me)
            advance(3)
            check("Roshan line", order(lines(t6)) == "roshan_fallen_rad", order(lines(t6)))
            local roar = made(path("sfx", "roshan_death"), t6)
            check("Roshan's death roar in 3D", #roar == 1 and roar[1].is3d, #roar)
        end

        -- gameplay sounds: last hit, deny, level-up, learn, rune, failed casts
        local t7 = __mock.now
        local creep = unit(SLOT_HORDE, "hfoo", -4000, -4000)
        Events.emit("death", creep, me)
        local coins = made(path("sfx", "coins"), t7)
        check("last hit pays a coin to its player", #coins == 1 and coins[1].vol > 0, #coins)
        local own = unit(SLOT_ANCIENTS, "hfoo", -4000, -4100)
        Events.emit("death", own, me)
        check("deny sound at the creep", #made(path("sfx", "deny"), t7) == 1)
        Events.emit("rune_activated", hero, "haste")
        local rune = made(path("sfx", "rune_haste"), t7)
        check("haste rune sound where it was taken", #rune == 1 and rune[1].is3d and rune[1].vol > 0, #rune)
        local runeLine = use("data.sounds")[hk].rune_haste
        check("the hero's haste line", runeLine and #made(runeLine[1], t7) == 1)
        advance(3)
        Events.emit("hero_level", hero)
        Events.emit("hero_level", hero)
        check("one level-up sound for two levels at once", #made(path("sfx", "levelup"), t7) == 1)
        Events.emit("hero_skill", hero, 0)
        check("learn sound", #made(path("sfx", "learn"), t7) == 1)
        advance(3)       -- the hero's level-up line (voice.lua) holds its voice for 2.5 s
        G.castFail(hero, "mana")
        G.castFail(hero, "mana")
        check("no-mana beep every time", #made(path("sfx", "fail_mana"), t7) == 2)
        local nomana = 0
        for _, p in ipairs(use("data.sounds")[hk].nomana or {}) do nomana = nomana + #made(p, t7) end
        check("no-mana line at most every few seconds", nomana == 1, nomana)
        -- a key press of an ability on cooldown, then of a ready one
        local abil = FourCC("A000")
        stub("GetUnitAbilityLevel", function(u, a) return (u == hero and a == abil) and 1 or 0 end)
        stub("BlzGetUnitAbilityCooldownRemaining", function() return 5.0 end)
        check("ability on cooldown is not ready", G.checkCast(hero, abil) == false)
        check("cooldown beep", #made(path("sfx", "fail_cooldown"), t7) == 1)
        stub("BlzGetUnitAbilityCooldownRemaining", function() return 0.0 end)
        stub("BlzGetUnitAbilityManaCost", function() return 0 end)
        check("a ready ability makes no sound", G.checkCast(hero, abil) == true
            and #made(path("sfx", "fail_cooldown"), t7) == 1)
        G.buy(Player(0))
        check("purchase sound", #made(path("sfx", "buy"), t7) == 1)
        -- Town Portal: two hums while channeling, departure and arrival when done
        G.tpStart(hero, 2000, 2000)
        local hums = {}
        for _, s in ipairs(sounds) do
            if s.created >= t7 and s.looping then hums[#hums + 1] = s end
        end
        check("two portal hums", #hums == 2, #hums)
        G.tpEnd(hero, true)
        check("hums stop", hums[1] and hums[1].killed and hums[2] and hums[2].killed)
        check("arrival sound at the target", #made(path("sfx", "tp_appear"), t7) == 1)

        -- the Warcraft player hears none of the Dota players' lines and UI
        -- sounds (world sounds such as the portal above are for everyone)
        advance(0.5)
        listener.slot = 7
        local t8 = __mock.now
        A.say("first_blood", 3)
        G.buy(Player(0))
        advance(0.2)
        local heard = nil
        for _, s in ipairs(sounds) do
            local dota = string.find(s.path, "Sound\\Dota\\announcer\\", 1, true)
                or string.find(s.path, "Sound\\Dota\\sfx\\", 1, true)
            if dota and s.created >= t8 and s.vol > 0 then heard = s.path .. " at " .. s.vol end
        end
        check("the Warcraft player hears no Dota line", heard == nil, heard)
        listener.slot = 0
        advance(3)

        -- the end: "Radiant victory!" at once (the music, which its own
        -- exercise checks, is left running)
        local t9 = __mock.now
        local Music = defined("music") and use("music") or nil
        local musicOver = Music and Music.gameOver
        if Music then Music.gameOver = function() end end
        A.gameOver("dota")
        if Music then Music.gameOver = musicOver end
        check("victory line at once", order(lines(t9)) == "victory_rad", order(lines(t9)))
        A.say("first_blood", 3)
        advance(3)
        check("nothing after the end", order(lines(t9)) == "victory_rad", order(lines(t9)))

        for _, u in ipairs(units) do u.dead = true end
        for _, u in ipairs(flagged) do u.ax, u.hero = nil, nil end
        for _, lane in ipairs({"top", "mid", "bot", "base"}) do
            for _, u in ipairs(S.towers[lane] or {}) do u.ax, u.structure = nil, nil end
            for _, u in ipairs(S.barracks[lane] or {}) do u.ax, u.structure = nil, nil end
        end
        if S.ancient then S.ancient.ax, S.ancient.structure = nil, nil end
        Log.info("announcer exercise: " .. checks .. " checks, " .. failures .. " failed")
    end

    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("announcer") or not defined("data.audio") then return end
        done = true
        install()
        local ok, err = xpcall(exercise, debug and debug.traceback or tostring)
        restore()
        if not ok then use("log").error("announcer exercise crashed: " .. tostring(err)) end
        use("log").flush()
    end
end
