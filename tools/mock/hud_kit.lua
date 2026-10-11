-- Offline exercise for Kit.detect (src/ui/hud_kit.lua): the Dota HUD art is
-- used when any first line of the voice events every launcher version
-- extracts (spawn, move, attack, kill, death, levelup) is in the map, though
-- newer events such as "aegis" are missing; no line in the map keeps the
-- Warcraft art; FORCE_DOTA_TEXTURES wins.
-- Failed checks are ERROR log lines, which fail the mock run.
do
    local function exercise()
        local Log, Kit, sounds = use("log"), use("hud_kit"), use("data.sounds")
        local failures, checks = 0, 0
        local function check(name, ok, detail)
            checks = checks + 1
            if not ok then
                failures = failures + 1
                Log.error("hud_kit exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
            end
        end
        local heroes = {}
        for hero in pairs(sounds) do heroes[#heroes + 1] = hero end
        table.sort(heroes)
        local lastHero = sounds[heroes[#heroes]] or {}
        local present = {}
        local duration, wasDota, wasForced = GetSoundFileDuration, Kit.dota, Kit.FORCE_DOTA_TEXTURES
        GetSoundFileDuration = function(path) return present[path] and 2500 or 0 end
        Kit.FORCE_DOTA_TEXTURES = nil
        check("no voice line in the map: Warcraft art", Kit.detect() == false and Kit.dota == false)
        check("the last hero has a move line", lastHero.move and lastHero.move[1])
        present[(lastHero.move or {})[1] or ""] = true
        check("the last hero's move line alone, no newer events: Dota art", Kit.detect() == true and Kit.dota == true)
        Kit.FORCE_DOTA_TEXTURES = true
        present = {}
        check("forced Dota art", Kit.detect() == true)
        GetSoundFileDuration, Kit.dota, Kit.FORCE_DOTA_TEXTURES = duration, wasDota, wasForced
        Log.info("hud_kit exercise: " .. checks .. " checks, " .. failures .. " failed")
    end

    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("hud_kit") then return end
        done = true
        use("safe").call(exercise)
        use("log").flush()
    end
end
