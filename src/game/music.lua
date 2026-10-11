-- Dota's music for the Dota players, from the player's own Dota 2 (the
-- default pack, data.audio.music; tools/select_vo.py): the pre-game countdown
-- until the horn, laning tracks with silences between them, battle music
-- while the player's hero fights the Warcraft player's army or heroes, Roshan's
-- music while it fights Roshan, the death music while it is dead, the
-- respawn and buyback stingers, and the victory or defeat stinger. Durations,
-- volumes, loop and sync points are Dota's own. The Warcraft player keeps
-- Warcraft's music.
--
-- How it plays: Warcraft's PlayMusic replays only the first track it was
-- given (jassdoc, patch 1.36), so each track is a 2D sound instead. Tracks
-- belong to shared decks (main, battle, roshan, dead, stinger) and are
-- created on every client at the same moments, decided from synced game
-- state only (damage, deaths, the clock). Each client then mixes them for
-- its own player by volume: a Dota player's state (pregame, main, battle,
-- roshan, dead, over) sets per-deck weights that ramp for crossfades. Other
-- players hear nothing. Loops restart from the top so the new copy's start
-- point meets the old copy's end point, as Dota's restart_time does; battle
-- and Roshan music end with their outro stinger on the next sync point.
--
-- Hooks: music.horn() from announcer.lua at 0:00; music.gameOver(side) and
-- music.buyback(unit) from the modules that own those moments.
define("music", function()
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Roles = use("roles")
    local Safe = use("safe")
    local Sound = use("sound")
    local M = {started = false, over = false, hornDone = false, listeners = {}}

    M.GAIN = 1.0                -- on top of Dota's own event volumes
    M.CHANNEL = 0               -- Warcraft sound channel; 7 is "Music" (try in game with -musicch 7)
    M.TICK = 0.05
    M.FADE_IN = {main = 1.5, battle = 0.3, roshan = 0.5, dead = 0.5}
    M.FADE_OUT = {main = 0.8, battle = 1.0, roshan = 1.0, dead = 1.0}
    M.BATTLE_WINDOW = 4         -- hits inside this many seconds ...
    M.BATTLE_SCORE = 3          -- ... worth this much start the battle music (a hero's hit is worth 2)
    M.BATTLE_HOLD = 6           -- the battle ends this long after the last hit
    M.ROSHAN_HOLD = 6
    M.AFTER_HORN = {4, 8}       -- seconds from the horn to the first laning track
    M.GAP = {10, 30}            -- silence between laning tracks
    M.RETURN = {5, 12}          -- silence before laning music comes back after a fight or a death
    M.HORN_FADE = 1.5           -- the countdown fades out with the horn (Dota: DOTAMusic.StopPrehorn)
    M.DUCK = 0.7                -- music under announcer lines
    M.JOIN_DEAD = 5             -- a death this soon after another joins its death music

    local DECKS = {"main", "battle", "roshan", "dead", "stinger"}
    local LANING = {"laning_01", "laning_02", "laning_03"}
    local BATTLES = {"battle_01", "battle_02", "battle_03"}

    local decks = {}            -- name -> {voices = {}, ...}
    local bySlot = {}           -- slot -> listener
    local byHero = {}           -- hero unit -> listener
    local duckUntil = 0
    local roshanCode = nil

    local function now() return Timer.now() end
    local function track(key) return Sound.entry("music", key) end
    local function rand(r) return GetRandomReal(r[1], r[2]) end

    -- ------------------------------------------------------------ voices

    -- This client's listener sets volumes only, never decisions.
    local function localWeight(v)
        local L = bySlot[GetPlayerId(GetLocalPlayer())]
        if not L or v.dead then return 0 end
        if v.audience then
            if not v.audience[L.slot] then return 0 end
            return v.deck.name == "dead" and L.mix.dead or 1
        end
        return L.mix[v.deck.name] or 0
    end

    local function applyVolume(v)
        local vol = v.e.volume * M.GAIN * v.fade * localWeight(v)
        if now() < duckUntil then vol = vol * M.DUCK end
        local n = Sound.volume(vol)
        if n ~= v.vol then
            v.vol = n
            SetSoundVolume(v.s, n)
        end
    end

    -- Starts a track in a deck (synced code only). opts.audience: {slot =
    -- true} hears it instead of the deck mix; opts.fade: fade-in seconds.
    local function start(deck, key, opts)
        opts = opts or {}
        local e = track(key)
        if not e then return nil end
        local s = CreateSound(e.path, false, false, false, 10, 10, "")
        SetSoundChannel(s, M.CHANNEL)
        SetSoundVolume(s, 0)
        StartSound(s)
        local t = now()
        local v = {s = s, key = key, e = e, deck = deck, started = t, ends = t + e.duration,
                   fade = opts.fade and 0 or 1, target = 1, rate = opts.fade and 1 / opts.fade or 0,
                   audience = opts.audience, vol = -1}
        deck.voices[#deck.voices + 1] = v
        applyVolume(v)
        return v
    end

    local function kill(v)
        if v.dead then return end
        v.dead = true
        StopSound(v.s, true, false)
    end

    -- Fades a voice out over `seconds`, then frees it.
    local function fadeOut(v, seconds)
        if v.dead then return end
        v.target, v.rate = 0, 1 / math.max(0.05, seconds)
    end

    local function stopDeck(deck, seconds)
        for _, v in ipairs(deck.voices) do fadeOut(v, seconds) end
    end

    local function updateVoices(dt)
        local t = now()
        for _, name in ipairs(DECKS) do
            local d = decks[name]
            local keep = {}
            for _, v in ipairs(d.voices) do
                if not v.dead then
                    if v.fade ~= v.target then
                        local step = v.rate * dt
                        v.fade = v.target > v.fade and math.min(v.target, v.fade + step) or math.max(v.target, v.fade - step)
                    end
                    if (v.target == 0 and v.fade <= 0) or t >= v.ends + 0.25 then
                        kill(v)
                    else
                        applyVolume(v)
                        keep[#keep + 1] = v
                    end
                end
            end
            d.voices = keep
        end
    end

    -- ------------------------------------------------------------ listeners

    local function pick(list, last)
        local pool = {}
        for _, k in ipairs(list) do
            if k ~= last and track(k) then pool[#pool + 1] = k end
        end
        if #pool == 0 then return last end
        return pool[GetRandomInt(1, #pool)]
    end

    -- How much a unit counts for battle music against this listener: the
    -- Warcraft player's own units and heroes do; his creep waves (Dota's lane
    -- creeps), buildings and neutrals do not.
    local function foeWeight(u)
        if not u then return 0 end
        local slot = GetPlayerId(GetOwningPlayer(u))
        if slot == SLOT_HORDE or Roles.side(slot) ~= "warcraft" then return 0 end
        if IsUnitType(u, UNIT_TYPE_STRUCTURE) then return 0 end
        return IsUnitType(u, UNIT_TYPE_HERO) and 2 or 1
    end

    local function isRoshan(u)
        if not u then return false end
        if roshanCode == nil and defined("world") then roshanCode = use("world").code("units", "roshan") or false end
        return roshanCode and GetUnitTypeId(u) == roshanCode or false
    end

    -- A hit between a listener's hero and another unit (either direction).
    local function hit(L, other)
        local t = now()
        if isRoshan(other) then
            L.lastRoshan = t
            return
        end
        local w = foeWeight(other)
        if w == 0 then return end
        L.hits[#L.hits + 1] = {t = t, w = w}
        L.lastFight = t
    end

    local function battleScore(L, t)
        local keep, score = {}, 0
        for _, h in ipairs(L.hits) do
            if t - h.t <= M.BATTLE_WINDOW then
                keep[#keep + 1] = h
                score = score + h.w
            end
        end
        L.hits = keep
        return score
    end

    local function desired(L, t)
        if M.over then return "over" end
        if L.dead then return "dead" end
        if L.inBattle and t - L.lastFight > M.BATTLE_HOLD then L.inBattle = false end
        if not L.inBattle and battleScore(L, t) >= M.BATTLE_SCORE then L.inBattle = true end
        if L.inBattle then return "battle" end
        if t - L.lastRoshan <= M.ROSHAN_HOLD then return "roshan" end
        return M.hornDone and "main" or "pregame"
    end

    local function anyIn(state)
        for _, L in ipairs(M.listeners) do
            if L.state == state then return true end
        end
        return false
    end

    local MIXES = {"main", "battle", "roshan", "dead"}

    local function updateListeners(dt)
        local t = now()
        for _, L in ipairs(M.listeners) do
            if not L.hero then
                local hero = defined("heroes") and use("heroes").bySlot[L.slot] or nil
                if hero then
                    L.hero = hero
                    byHero[hero] = L
                end
            end
            local state = desired(L, t)
            if state ~= L.state then
                -- leaving a fight: its outro still plays for this listener
                if L.state == "battle" or L.state == "roshan" then L.after = L.state end
                L.state = state
            end
            local d = L.after and decks[L.after]
            if d and (state == "dead" or state == "over" or state == L.after or anyIn(L.after)
                      or (d.state == "off" and not (d.outro and not d.outro.dead))) then
                L.after = nil     -- the outro has rung out (or the music went on for others)
            end
            local want = {main = 0, battle = 0, roshan = 0, dead = 0}
            if (state == "main" or state == "pregame") and t >= L.holdMain and not L.after then want.main = 1 end
            if state == "battle" or state == "roshan" or state == "dead" then want[state] = 1 end
            if L.after then want[L.after] = 1 end
            for _, deck in ipairs(MIXES) do
                local w, target = L.mix[deck], want[deck]
                if w < target then
                    L.mix[deck] = math.min(target, w + dt / M.FADE_IN[deck])
                elseif w > target then
                    L.mix[deck] = math.max(target, w - dt / M.FADE_OUT[deck])
                end
            end
        end
    end

    -- ------------------------------------------------------------ main deck

    -- Pre-game countdown, then laning tracks with silences between them. When
    -- nobody listens (fights, deaths) the track stops; a new one starts after
    -- a pause once someone is back.
    local function updateMain()
        local d, t = decks.main, now()
        local wanted = false
        for _, L in ipairs(M.listeners) do
            if (L.state == "main" or L.state == "pregame") and t >= L.holdMain and not L.after then wanted = true end
        end
        if d.state == "pregame" then
            -- the countdown ran out and no horn came: carry on as after the horn
            if #d.voices == 0 and t > d.since + 5 then M.horn() end
            return
        end
        if not wanted then
            d.unwanted = d.unwanted or t
            if d.state == "play" and t - d.unwanted >= M.FADE_OUT.main then
                stopDeck(d, 0.3)
                d.state, d.next = "gap", nil
            end
            return
        end
        d.unwanted = nil
        if d.state == "gap" then
            if d.next == nil then d.next = t + rand(M.RETURN) end
            if t >= d.next then
                local key = pick(LANING, d.last)
                if key and start(d, key) then
                    d.last, d.state = key, "play"
                    d.ends = t + track(key).duration
                    Log.info("music: " .. key)
                else
                    d.next = t + rand(M.GAP)
                end
            end
        elseif d.state == "play" and t >= d.ends then
            d.state, d.next = "gap", t + rand(M.GAP)
        end
    end

    -- ------------------------------------------------------------ loop decks

    -- Battle and Roshan music: a looping track while a listener is in that
    -- state, then its outro (<key>_end) placed so its start point lands on
    -- the next sync point of the loop, where the loop stops.
    local function loopRestart(e)
        return e.restart or ((e.stop or e.duration) - (e.start or 0))
    end

    local function startLoop(d, key)
        if not key then return end
        d.gen = d.gen + 1
        d.key, d.state, d.copies, d.outro, d.stopAt = key, "play", {}, nil, nil
        local gen = d.gen
        local function copy()
            if d.gen ~= gen or (d.state ~= "play" and d.state ~= "ending") then return end
            local v = start(d, key)
            if not v then return end
            d.copies[#d.copies + 1] = v
            local wait = loopRestart(v.e)
            if wait > 1 then
                Timer.after(wait, function()
                    -- while ending, copies keep coming until the stop point
                    if d.gen == gen and (d.state == "play" or (d.state == "ending" and d.stopAt
                        and now() + 0.05 < d.stopAt)) then
                        copy()
                    end
                end)
            end
        end
        copy()
        Log.info("music: " .. key)
    end

    -- The next sync point of the loop at least `lead` seconds away.
    local function nextSync(d, lead)
        local last = d.copies[#d.copies]
        if not last then return nil end
        local e, t = last.e, now()
        local sync = e.sync or {e.start or 0, e.stop or e.duration}
        local best = nil
        for k = 0, 1 do
            local base = last.started + k * loopRestart(e)
            for _, s in ipairs(sync) do
                local at = base + s
                if at - lead >= t + 0.05 and (best == nil or at < best) then best = at end
            end
        end
        return best
    end

    local function endLoop(d)
        local outro = track(d.key .. "_end")
        local lead = outro and (outro.start or 0) or 0
        local at = nextSync(d, lead) or (now() + 0.1)
        d.state, d.stopAt = "ending", at
        d.endGen = (d.endGen or 0) + 1
        local gen, ending = d.gen, d.endGen
        local function current() return d.gen == gen and d.endGen == ending and d.state == "ending" end
        Timer.after(math.max(0, at - lead - now()), function()
            if current() and outro then d.outro = start(d, d.key .. "_end") end
        end)
        Timer.after(math.max(0, at - now()), function()
            if not current() then return end
            for _, v in ipairs(d.copies) do fadeOut(v, 0.15) end
            d.copies = {}
            d.state = "outro"
            d.idleAt = now() + (outro and ((outro.stop or outro.duration) - (outro.start or 0)) or 0)
        end)
    end

    local function updateLoop(d, state, keys)
        local active = anyIn(state)
        if d.state == "off" then
            if active then startLoop(d, pick(keys, d.key)) end
        elseif d.state == "play" then
            if not active then endLoop(d) end
        elseif d.state == "ending" then
            -- back in the fight before the outro began: the loop just goes on
            if active and not d.outro then d.state, d.stopAt = "play", nil end
        elseif d.state == "outro" then
            -- a new fight may start once the outro's last bar is reached; its
            -- tail (d.outro) still rings for the listeners who left this one
            if now() >= (d.idleAt or 0) then d.state = "off" end
        end
    end

    -- ------------------------------------------------------------ death

    local function died(L)
        L.dead = true
        local d, t = decks.dead, now()
        for _, v in ipairs(d.voices) do
            if not v.dead and v.target > 0 and t - v.started <= M.JOIN_DEAD then
                v.audience[L.slot] = true
                L.deadVoice = v
                return
            end
        end
        L.deadVoice = start(d, "killed", {audience = {[L.slot] = true}})
    end

    -- stinger: "respawn" after a normal respawn, nil after a buyback (which
    -- has its own stinger).
    local function respawned(L, stinger)
        if not L.dead then return end
        L.dead = false
        local v = L.deadVoice
        L.deadVoice = nil
        if v and not v.dead then
            local others = false
            for slot in pairs(v.audience) do
                if slot ~= L.slot then others = true end
            end
            if others then v.audience[L.slot] = nil else fadeOut(v, M.FADE_OUT.dead) end
        end
        if M.over then return end
        local e = stinger and track(stinger)
        if e then
            start(decks.stinger, stinger, {audience = {[L.slot] = true}})
            L.holdMain = math.max(L.holdMain, now() + e.duration)
        end
    end

    -- ------------------------------------------------------------ hooks

    -- The horn at 0:00: the countdown fades, laning music follows.
    function M.horn()
        if not M.started or M.hornDone then return end
        M.hornDone = true
        local d = decks.main
        if d.state == "pregame" then
            stopDeck(d, M.HORN_FADE)
            d.state, d.next = "gap", now() + rand(M.AFTER_HORN)
        end
    end

    -- Victory or defeat for the Dota side: every track fades, the stinger plays.
    function M.gameOver(winnerSide)
        if not M.started or M.over then return end
        M.over = true
        for _, name in ipairs(DECKS) do stopDeck(decks[name], 1.0) end
        local audience = {}
        for _, L in ipairs(M.listeners) do audience[L.slot] = true end
        local key = winnerSide == "dota" and "radiant_win" or "radiant_lose"
        start(decks.stinger, key, {audience = audience})
        Log.info("music: " .. key)
    end

    -- A hero bought back: the buyback stinger for every Dota player; the
    -- buyer's death music stops. Call before the revive's hero_respawned.
    function M.buyback(unit)
        if not M.started or M.over then return end
        local audience = {}
        for _, L in ipairs(M.listeners) do audience[L.slot] = true end
        start(decks.stinger, "buy_back", {audience = audience})
        local L = unit and byHero[unit]
        if L then
            respawned(L, nil)
            L.holdMain = math.max(L.holdMain, now() + ((track("buy_back") or {}).duration or 0))
        end
    end

    -- Music steps back under an announcer line for `seconds`.
    function M.duck(seconds)
        duckUntil = math.max(duckUntil, now() + seconds)
    end

    function M.state(slot)
        local L = bySlot[slot]
        return L and L.state or nil
    end

    function M.deck(name) return decks[name] end

    local function tick()
        local dt = M.TICK
        updateListeners(dt)
        if not M.over then
            updateMain()
            updateLoop(decks.battle, "battle", BATTLES)
            updateLoop(decks.roshan, "roshan", {"roshan"})
        end
        updateVoices(dt)
    end

    -- Test builds: -music shows the state, -musicch N picks the sound
    -- channel of new tracks, -musicgain X scales the music.
    local function testCommands()
        local trig = CreateTrigger()
        for i = 0, SLOT_WARCRAFT do
            TriggerRegisterPlayerChatEvent(trig, Player(i), "-music", false)
        end
        TriggerAddAction(trig, function()
            use("safe").call(function()
                local msg = GetEventPlayerChatString()
                local ch = string.match(msg, "^%-musicch%s+(%d+)")
                local gain = string.match(msg, "^%-musicgain%s+([%d%.]+)")
                if ch then M.CHANNEL = tonumber(ch) end
                if gain then M.GAIN = tonumber(gain) or M.GAIN end
                local parts = {}
                for _, L in ipairs(M.listeners) do parts[#parts + 1] = L.slot .. "=" .. tostring(L.state) end
                for _, name in ipairs(DECKS) do
                    local d = decks[name]
                    parts[#parts + 1] = name .. ":" .. tostring(d.state or "-") .. "/" .. #d.voices
                end
                Log.info("music: channel " .. M.CHANNEL .. ", gain " .. M.GAIN .. ", " .. table.concat(parts, " "))
            end)
        end)
    end

    -- Starts the director; call once roles are assigned (game.lua begin()).
    function M.init()
        if M.started then return end
        M.started = true
        for _, name in ipairs(DECKS) do decks[name] = {name = name, voices = {}, gen = 0, state = "off"} end
        decks.main.state = "gap"
        for _, slot in ipairs(Roles.heroSlots) do
            if Roles.humans[slot] then
                local L = {slot = slot, player = Player(slot), state = nil, dead = false, hits = {},
                           lastFight = -1000, lastRoshan = -1000, inBattle = false, holdMain = 0,
                           mix = {main = 1, battle = 0, roshan = 0, dead = 0}}
                M.listeners[#M.listeners + 1] = L
                bySlot[slot] = L
            end
        end
        -- Warcraft's map music stops for a Dota player whose map has Dota's
        -- music (a launcher-built map). Local calls that create no handles.
        local probe = track("laning_01")
        if Sound.isDota(GetLocalPlayer()) and probe and GetSoundFileDuration(probe.path) > 0 then
            StopMusic(false)
            ClearMapMusic()
        end
        if #M.listeners > 0 and track("countdown") then
            decks.main.state, decks.main.since = "pregame", now()
            start(decks.main, "countdown")
        end
        Events.on("damaged", function(source, target)
            if not source or not target then return end
            local L = byHero[source]
            if L then hit(L, target) end
            L = byHero[target]
            if L then hit(L, source) end
        end)
        Events.on("death", function(dying)
            local L = dying and byHero[dying]
            if L then died(L) end
        end)
        Events.on("hero_respawned", function(u)
            local L = byHero[u]
            if L then respawned(L, "respawn") end
        end)
        -- a Lua error must not stop the music for good, nor flood the log
        local errors = 0
        Timer.every(M.TICK, function()
            if not Safe.call(tick) then errors = errors + 1 end
            return errors > 20
        end)
        if BUILD_TEST_MODE then testCommands() end
        Log.info("music: " .. #M.listeners .. " Dota listener(s)")
    end

    return M
end)
