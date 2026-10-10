-- Sounds. Hero voice lines come from the player's own Dota 2 install: the
-- launcher extracts them into the map under the paths listed in data.sounds
-- ({hero = {event = {path, ...}}}). A missing file simply plays nothing.
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

    -- A voice line for the unit's hero; event is "spawn", "kill", "death",
    -- "levelup", "laugh", "move", "attack" or "cast_<ability>". chance < 1
    -- plays it only sometimes; ownerOnly keeps it to the hero's player, like
    -- Dota's order responses. Lines do not overlap per unit.
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

    return S
end)
