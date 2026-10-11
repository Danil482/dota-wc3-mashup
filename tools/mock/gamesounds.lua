-- Offline exercise for the sound plumbing (src/core/sound.lua) behind the
-- gameplay sounds (src/game/gamesounds.lua). Runs after the main mock run
-- and records every sound handle: how it was created, the local player's
-- volume, its channel, 3D position and distances, start, stop and whether
-- KillSoundWhenDone was used. Checks the start-of-game warm-up of every
-- effect file, the purchase and sale sounds for their player only, each
-- rune's 3D sound for everyone near, that sounds are freed by a synced timer
-- after their known length (never KillSoundWhenDone), the test-build trace
-- lines, and that Warcraft's UI volume group is muted on Dota players'
-- clients only. Failed checks become ERROR lines, which fail the mock run.
do
    local saved = {}
    local function stub(name, fn)
        if saved[name] == nil then saved[name] = _G[name] end
        _G[name] = fn
    end
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
    local volumeGroups = {}
    local listener = {slot = 0}
    local nextId = 5000

    local function install()
        stub("GetLocalPlayer", function() return Player(listener.slot) end)
        stub("GetHandleId", function(h)
            if type(h) ~= "table" then return 0 end
            if not h.__id then nextId = nextId + 1 h.__id = nextId end
            return h.__id
        end)
        stub("CreateSound", function(path, looping, is3d, stopOutOfRange, fadeIn, fadeOut, eax)
            local s = __handle("sound")
            s.path, s.looping, s.is3d, s.vol, s.created, s.eax = path, looping, is3d, 127, __mock.now, eax
            sounds[#sounds + 1] = s
            return s
        end)
        stub("SetSoundVolume", function(s, v) s.vol = v end)
        stub("SetSoundChannel", function(s, c) s.channel = c end)
        stub("SetSoundPosition", function(s, x, y) s.x, s.y = x, y end)
        stub("SetSoundDistances", function(s, near, far) s.near, s.far = near, far end)
        stub("SetSoundDistanceCutoff", function(s, cutoff) s.cutoff = cutoff end)
        stub("StartSound", function(s) s.started = __mock.now end)
        stub("StopSound", function(s, kill) s.stopped, s.killed = __mock.now, kill end)
        stub("KillSoundWhenDone", function(s) s.autokill = true end)
        stub("GetSoundIsLoading", function() return false end)
        stub("GetSoundIsPlaying", function(s) return s.started ~= nil and not s.stopped end)
        stub("VolumeGroupSetVolume", function(g, scale)
            volumeGroups[#volumeGroups + 1] = {group = g, scale = scale, slot = listener.slot}
        end)
    end

    local function exercise()
        local G, Sound, Log, Events, Roles = use("gamesounds"), use("sound"), use("log"), use("events"), use("roles")
        local audio = use("data.audio")
        local failures, checks = 0, 0
        local function check(name, ok, detail)
            checks = checks + 1
            if not ok then
                failures = failures + 1
                Log.error("gamesounds exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
            end
        end
        local function path(key) return audio.sfx[key].path end
        local function made(p, since)
            local out = {}
            for _, s in ipairs(sounds) do
                if s.path == p and s.created >= since then out[#out + 1] = s end
            end
            return out
        end
        local function logText() return __mock.files["DotaVsWarcraft\\log.txt"] or "" end
        if not G.started then G.init() end
        advance(6)                      -- a warm-up started here finishes

        -- the warm-up: two kept handles (2D and 3D) per effect file
        local keys, warmed = 0, 0
        for key in pairs(audio.sfx) do
            keys = keys + 1
            if Sound.warm[key] ~= nil and #Sound.warm[key] == 2 then warmed = warmed + 1 end
        end
        check("every effect file is warmed up at the start", keys > 0 and warmed == keys, warmed .. "/" .. keys)

        -- a purchase: 2D, Dota's volume, for the buyer only, freed by a timer
        local t0 = __mock.now
        G.buy(Player(0))
        local buy = made(path("buy"), t0)[1]
        check("purchase sound", buy ~= nil and buy.started ~= nil and not buy.is3d)
        check("purchase at Dota's volume", buy and buy.vol == Sound.volume(audio.sfx.buy.volume), buy and buy.vol)
        check("our sounds stay on channel 0, off Warcraft's UI channel", buy and buy.channel == 0, buy and buy.channel)
        check("no KillSoundWhenDone", buy and not buy.autokill)
        advance(0.3)
        check("purchase traced", string.find(logText(), "sound buy for p0 2d", 1, true) ~= nil)
        advance(audio.sfx.buy.duration + Sound.MARGIN)
        check("purchase freed after its length", buy and buy.killed == true and buy.stopped
            and math.abs(buy.stopped - (t0 + audio.sfx.buy.duration + Sound.MARGIN)) < 0.01, buy and buy.stopped)

        -- a sale: the coins for the seller only
        local t1 = __mock.now
        listener.slot = 1
        G.sell(Player(0))
        listener.slot = 0
        G.sell(Player(0))
        local sales = made(path("coins"), t1)
        check("sale sound for the seller", #sales == 2 and sales[2].vol == Sound.volume(audio.sfx.coins.volume), #sales)
        check("nobody else hears the sale", sales[1] and sales[1].vol == 0, sales[1] and sales[1].vol)
        advance(0.3)
        check("sale traced", string.find(logText(), "sound coins(sell) for p0 2d", 1, true) ~= nil)

        -- each rune: its own sound in 3D where it was taken, for everyone near
        local hero = defined("heroes") and use("heroes").bySlot[0] or nil
        if not hero then
            Log.warn("gamesounds exercise: no hero for slot 0, rune checks skipped")
        else
            hero.x, hero.y = hero.x or 0, hero.y or 0
            for _, kind in ipairs({"bounty", "water", "doubledamage", "haste", "illusion", "invisibility",
                                   "regeneration", "arcane", "shield"}) do
                local t = __mock.now
                listener.slot = 3
                Events.emit("rune_activated", hero, kind)
                listener.slot = 0
                local s = made(path("rune_" .. kind), t)[1]
                check(kind .. " rune sound in 3D", s ~= nil and s.is3d and s.started ~= nil and s.x == hero.x
                    and s.y == hero.y and s.near == 800 and s.far == 3500 and s.cutoff == 4000, kind)
                check(kind .. " rune sound for everyone near", s and s.vol == Sound.volume(audio.sfx["rune_" .. kind].volume),
                    s and s.vol)
                advance(3)              -- the hero's rune line holds its voice for 2.5 s
            end
            check("rune traced", string.find(logText(), "sound rune_shield for all at", 1, true) ~= nil)

            -- a voice line: 3D at the hero, freed by a timer as well
            local t2 = __mock.now
            Sound.vo(hero, "spawn", 1, true)
            local line = nil
            for _, s in ipairs(sounds) do
                if s.created >= t2 and s.is3d and string.find(s.path, "Sound\\Dota\\", 1, true) then line = s end
            end
            if line then
                check("a voice line has no KillSoundWhenDone", not line.autokill)
                advance(Sound.LIFE + 0.1)
                check("a voice line is freed after Sound.LIFE", line.killed == true, line.stopped)
            end
        end

        -- Warcraft's interface sounds: muted for the human Dota player, kept
        -- for the Warcraft player, on the right client only
        check("Warcraft UI muted for the Dota player", G.warcraftUiMuted(Player(0)))
        local cmd = Roles.warcraft or SLOT_WARCRAFT
        check("Warcraft UI kept for the Warcraft player", not G.warcraftUiMuted(Player(cmd)))
        listener.slot = 0
        G.muteWarcraftUi(Player(0), true)
        local mine = volumeGroups[#volumeGroups]
        check("the Dota player's client mutes the UI group",
            mine and mine.group == SOUND_VOLUMEGROUP_UI and mine.scale == 0 and mine.slot == 0)
        local n = #volumeGroups
        listener.slot = cmd
        G.muteWarcraftUi(Player(0), true)
        check("other clients keep their UI group", #volumeGroups == n, #volumeGroups - n)
        listener.slot = 0

        Log.info("gamesounds exercise: " .. checks .. " checks, " .. failures .. " failed")
    end

    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("gamesounds") or not defined("data.audio") then return end
        done = true
        install()
        local ok, err = xpcall(exercise, debug and debug.traceback or tostring)
        restore()
        if not ok then use("log").error("gamesounds exercise crashed: " .. tostring(err)) end
        use("log").flush()
    end
end
