-- Sounds. Hero voice lines (data.sounds: {hero = {event = {path, ...}}}) and
-- Dota's music, announcer and effects (data.audio: {music|announcer|sfx =
-- {key = {path, duration, volume, ...}}}) come from the player's own Dota 2
-- install: the launcher extracts them into the map under those paths
-- (tools/select_vo.py chooses them). A missing file simply plays nothing.
--
-- Multiplayer: every sound is created and started on every client, in the
-- same order; who hears it is only its volume, set per client. Never call
-- these functions inside a GetLocalPlayer() block.
define("sound", function()
    local Timer = use("timer")
    local S = {}

    local heroOf = {}           -- unit -> hero key (registered at spawn)
    local busyUntil = {}        -- unit -> game time its current line ends

    function S.register(unit, heroKey)
        heroOf[unit] = heroKey
    end

    function S.heroOf(unit)
        return heroOf[unit]
    end

    -- 3D sound at a point. volume 0-127. With a player only that player hears
    -- it: sounds are created for everyone and muted elsewhere, since creating
    -- handles for one player alone desyncs multiplayer games.
    function S.at(path, x, y, volume, player)
        local s = CreateSound(path, false, true, true, 10, 10, "DefaultEAXON")
        SetSoundChannel(s, 0)
        SetSoundVolume(s, (player == nil or GetLocalPlayer() == player) and (volume or 110) or 0)
        SetSoundDistances(s, 600, 3000)
        SetSoundPosition(s, x, y, 60)
        StartSound(s)
        KillSoundWhenDone(s)
    end

    -- Plain 2D sound for one player (UI feedback).
    function S.local2d(player, path, volume)
        local s = CreateSound(path, false, false, false, 10, 10, "")
        SetSoundVolume(s, GetLocalPlayer() == player and (volume or 110) or 0)
        StartSound(s)
        KillSoundWhenDone(s)
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
    -- looping, channel (default 0), keep (true: the caller stops it with
    -- StopSound; otherwise it frees itself when done). Returns the handle,
    -- or nil when no human is in the audience.
    function S.play(path, audience, opts)
        if not S.anyHuman(audience) then return nil end
        opts = opts or {}
        local is3d = opts.x ~= nil
        local s = CreateSound(path, opts.looping == true, is3d, is3d, 10, 10, is3d and "DefaultEAXON" or "")
        SetSoundChannel(s, opts.channel or 0)
        SetSoundVolume(s, S.hears(audience) and S.volume(opts.volume or 1) or 0)
        if is3d then
            SetSoundDistances(s, opts.near or 600, opts.far or 3000)
            SetSoundDistanceCutoff(s, (opts.far or 3000) + 500)
            SetSoundPosition(s, opts.x, opts.y, opts.z or 60)
        end
        StartSound(s)
        if not opts.keep and not opts.looping then KillSoundWhenDone(s) end
        return s
    end

    -- A data.audio effect ({group}, key) for the audience, 2D or at x, y.
    -- gain scales Dota's own event volume. Returns the handle or nil.
    function S.sfx(key, audience, x, y, gain, opts)
        local e = S.entry("sfx", key)
        if not e then return nil end
        local o = {}
        for k, v in pairs(opts or {}) do o[k] = v end
        o.volume = e.volume * (gain or 1)
        o.x, o.y = x, y
        return S.play(e.path, audience, o)
    end

    return S
end)
