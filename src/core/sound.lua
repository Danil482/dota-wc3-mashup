-- Sounds. Hero voice lines (data.sounds: {hero = {event = {path, ...}}}) and
-- Dota's music, announcer and effects (data.audio: {music|announcer|sfx =
-- {key = {path, duration, volume, ...}}}) come from the player's own Dota 2
-- install: the launcher extracts them into the map under those paths
-- (tools/select_vo.py chooses them). A missing file simply plays nothing.
--
-- Multiplayer: every sound is created and started on every client, in the
-- same order; who hears it is only its volume, set per client. Never call
-- these functions inside a GetLocalPlayer() block.
--
-- Lifetime: Warcraft (FMOD) loads a sound file in the background the first
-- time it is used, and a sound started before its file is ready begins only
-- once it is. KillSoundWhenDone frees such a sound before anyone hears it
-- (the first purchase, sale and rune pickup were silent in game), and it
-- fires at different moments on clients with sound off. So a synced timer
-- frees each sound after its known length instead (S.free), as music.lua
-- does, and S.warmup loads every effect file once at the start of the game.
define("sound", function()
    local Timer = use("timer")
    local S = {}

    S.CHANNEL = 0               -- Warcraft sound channel of our sounds ("General"; its UI warnings use 8)
    S.LIFE = 12                 -- seconds a sound of unknown length (voice line, announcer) may last
    S.MARGIN = 1                -- seconds past a sound's known end before it is freed
    S.TRACE_VO = 20             -- test builds: voice lines traced per game (every effect is traced)
    S.warm = {}                 -- effect key -> its warm-up handles (2D, 3D), kept so the file stays loaded

    local heroOf = {}           -- unit -> hero key (registered at spawn)
    local busyUntil = {}        -- unit -> game time its current line ends
    local tracedVo = 0
    local warming = false

    function S.register(unit, heroKey)
        heroOf[unit] = heroKey
    end

    function S.heroOf(unit)
        return heroOf[unit]
    end

    -- Frees a started sound after `seconds`, at the same moment on every
    -- client (GetSoundDuration is per client, and 0 with sound off).
    function S.free(s, seconds)
        Timer.after(seconds, function() StopSound(s, true, false) end)
    end

    -- Test builds: one flushed log line per traced play, written a moment
    -- after the start: what was asked to play, for whom ("all", "dota", "pN")
    -- or where, the handle, this client's volume and channel, whether the
    -- file was still loading at the start and whether the sound plays by then
    -- (a sound shorter than the check may already be over).
    local function trace(label, s, audience, x, y, vol, channel, length)
        if not BUILD_TEST_MODE then return end
        local loading = GetSoundIsLoading(s)
        local who = audience == nil and "all" or audience == "dota" and "dota"
            or type(audience) == "function" and "some" or ("p" .. GetPlayerId(audience))
        local where = x and string.format(" at %.0f,%.0f", x, y) or " 2d"
        Timer.after(math.min(0.25, math.max(0.05, (length or 1) * 0.5)), function()
            local Log = use("log")
            Log.info(string.format("sound %s for %s%s: handle %d, vol %d, ch %d, loading %s, playing %s",
                label, who, where, GetHandleId(s), vol, channel, tostring(loading), tostring(GetSoundIsPlaying(s))))
            Log.flush()
        end)
    end

    -- "folder\file" of a path, for traces.
    local function shortName(path)
        return string.match(path, "([^\\/]+[\\/][^\\/]+)$") or path
    end

    -- 3D sound at a point. volume 0-127. With a player only that player hears
    -- it: sounds are created for everyone and muted elsewhere, since creating
    -- handles for one player alone desyncs multiplayer games.
    function S.at(path, x, y, volume, player)
        local s = CreateSound(path, false, true, true, 10, 10, "DefaultEAXON")
        local vol = (player == nil or GetLocalPlayer() == player) and (volume or 110) or 0
        SetSoundChannel(s, S.CHANNEL)
        SetSoundVolume(s, vol)
        SetSoundDistances(s, 600, 3000)
        SetSoundPosition(s, x, y, 60)
        StartSound(s)
        S.free(s, S.LIFE)
        if tracedVo < S.TRACE_VO then
            tracedVo = tracedVo + 1
            trace("vo " .. shortName(path), s, player, x, y, vol, S.CHANNEL, 2)
        end
    end

    -- Plain 2D sound for one player (UI feedback).
    function S.local2d(player, path, volume)
        local s = CreateSound(path, false, false, false, 10, 10, "")
        SetSoundChannel(s, S.CHANNEL)
        SetSoundVolume(s, GetLocalPlayer() == player and (volume or 110) or 0)
        StartSound(s)
        S.free(s, S.LIFE)
    end

    -- True when the unit's hero has lines for the event.
    function S.has(unit, event)
        local key = heroOf[unit]
        local lines = key and (use("data.sounds")[key] or {})[event]
        return lines ~= nil and #lines > 0
    end

    -- A voice line for the unit's hero; event is "spawn", "respawn", "kill",
    -- "death", "levelup", "laugh", "move", "attack", "cast_<ability>" or one
    -- of the other events of tools/select_vo.py (notyet, nomana, rune_<kind>,
    -- aegis, battlebegins, firstblood). chance < 1 plays it only sometimes;
    -- ownerOnly keeps it to the hero's player, like Dota's order responses.
    -- Lines do not overlap per unit.
    function S.vo(unit, event, chance, ownerOnly)
        local key = heroOf[unit]
        if not key then return end
        local lines = (use("data.sounds")[key] or {})[event]
        if not lines or #lines == 0 then return end
        if chance and GetRandomReal(0, 1) > chance then return end
        local now = Timer.now()
        if (busyUntil[unit] or 0) > now then return end
        busyUntil[unit] = now + 2.5
        S.at(lines[GetRandomInt(1, #lines)], GetUnitX(unit), GetUnitY(unit), 120,
             ownerOnly and GetOwningPlayer(unit) or nil)
    end

    -- ------------------------------------------------------------ Dota audio

    -- data.audio[group][key] ({path, duration, volume, ...}) or nil.
    function S.entry(group, key)
        if not defined("data.audio") then return nil end
        local g = use("data.audio")[group]
        return g and g[key] or nil
    end

    -- Players on the Dota side (the hero players; bots have no ears).
    function S.isDota(p)
        return use("roles").side(GetPlayerId(p)) == "dota"
    end

    -- Does the local player belong to the audience? nil: everyone; "dota":
    -- the Dota side; a player; or a function(player) -> boolean.
    function S.hears(audience)
        local lp = GetLocalPlayer()
        if audience == nil then return true end
        if audience == "dota" then return S.isDota(lp) end
        if type(audience) == "function" then return audience(lp) == true end
        return audience == lp
    end

    -- 0..1 (Dota's event volume times a gain) -> Warcraft's 0..127.
    function S.volume(v)
        return math.max(0, math.min(127, math.floor(127 * v + 0.5)))
    end

    -- Can anyone hear it? A bot's coins or a team without humans need no
    -- sound at all. Synced state only (who is human), so every client skips
    -- the same sounds.
    function S.anyHuman(audience)
        local Roles = use("roles")
        if audience == nil or type(audience) == "function" then return true end
        if audience == "dota" then
            for _, slot in ipairs(Roles.heroSlots) do
                if Roles.humans[slot] then return true end
            end
            return false
        end
        return Roles.humans[GetPlayerId(audience)] == true
    end

    -- Starts a sound for the audience. opts: volume (0..1, default 1), x and
    -- y (3D at that point when given), z, near and far (3D distances),
    -- looping, channel (default S.CHANNEL), duration (seconds; the sound is
    -- freed that long plus S.MARGIN after its start, S.LIFE when unknown),
    -- keep (true: the caller stops it with StopSound), label (for traces).
    -- Returns the handle, or nil when no human is in the audience.
    function S.play(path, audience, opts)
        if not S.anyHuman(audience) then return nil end
        opts = opts or {}
        local is3d = opts.x ~= nil
        local channel = opts.channel or S.CHANNEL
        local vol = S.hears(audience) and S.volume(opts.volume or 1) or 0
        local s = CreateSound(path, opts.looping == true, is3d, is3d, 10, 10, is3d and "DefaultEAXON" or "")
        SetSoundChannel(s, channel)
        SetSoundVolume(s, vol)
        if is3d then
            SetSoundDistances(s, opts.near or 600, opts.far or 3000)
            SetSoundDistanceCutoff(s, (opts.far or 3000) + 500)
            SetSoundPosition(s, opts.x, opts.y, opts.z or 60)
        end
        StartSound(s)
        if not opts.keep and not opts.looping then S.free(s, (opts.duration or S.LIFE) + S.MARGIN) end
        trace(opts.label or shortName(path), s, audience, opts.x, opts.y, vol, channel, opts.duration)
        return s
    end

    -- A data.audio effect ({group}, key) for the audience, 2D or at x, y.
    -- gain scales Dota's own event volume; opts.why names the cause in
    -- traces ("coins(sell)"). Returns the handle or nil.
    function S.sfx(key, audience, x, y, gain, opts)
        local e = S.entry("sfx", key)
        if not e then
            if BUILD_TEST_MODE then use("log").warn("sound " .. tostring(key) .. ": no such effect in data.audio") end
            return nil
        end
        local o = {}
        for k, v in pairs(opts or {}) do o[k] = v end
        o.volume = e.volume * (gain or 1)
        o.x, o.y = x, y
        o.duration = o.duration or e.duration
        o.label = key .. (o.why and ("(" .. o.why .. ")") or "")
        return S.play(e.path, audience, o)
    end

    -- Loads every effect file at the start of the game, so the first coin,
    -- purchase or rune pickup plays at once: each file starts at volume 0,
    -- once as a 2D sound and once in 3D at this client's camera (only the
    -- position is local), a tenth of a second after the previous start (a
    -- few voices at a time), stops half a second later, and both handles are
    -- kept so the file stays loaded. About five seconds in all. Synced code
    -- only (game start).
    function S.warmup()
        if warming or not defined("data.audio") then return end
        warming = true
        local keys = {}
        for key in pairs(use("data.audio").sfx or {}) do keys[#keys + 1] = key end
        table.sort(keys)            -- the same order on every client
        local slow = {}
        local function start(i, key, is3d)
            local s = CreateSound(S.entry("sfx", key).path, false, is3d, is3d, 10, 10, is3d and "DefaultEAXON" or "")
            S.warm[key] = S.warm[key] or {}
            S.warm[key][#S.warm[key] + 1] = s
            SetSoundChannel(s, S.CHANNEL)
            SetSoundVolume(s, 0)
            if is3d then
                SetSoundDistances(s, 600, 3000)
                SetSoundDistanceCutoff(s, 3500)
                SetSoundPosition(s, GetCameraTargetPositionX(), GetCameraTargetPositionY(), 60)
            end
            StartSound(s)
            Timer.after(0.5, function()
                StopSound(s, false, false)
                if GetSoundIsLoading(s) then slow[#slow + 1] = key end      -- this client only: log text
                if is3d and i == #keys and BUILD_TEST_MODE then
                    use("log").info("sound warm-up: " .. #keys .. " effects, still loading after 0.5 s: "
                        .. (#slow > 0 and table.concat(slow, " ") or "none"))
                end
            end)
        end
        for i, key in ipairs(keys) do         -- all 2D starts, then all 3D ones: one file's two starts lie seconds apart
            Timer.after(0.1 * i, function() start(i, key, false) end)
            Timer.after(0.1 * (#keys + i), function() start(i, key, true) end)
        end
    end

    return S
end)
