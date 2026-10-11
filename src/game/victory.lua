-- Win conditions: the Dota side wins when Warcraft has no town hall left;
-- Warcraft wins when the Ancient falls. The fountain heals its allies.
define("victory", function()
    local Log = use("log")
    local Events = use("events")
    local Timer = use("timer")
    local Roles = use("roles")
    local U = use("util")
    local V = {over = false, noEnd = false, pending = nil}

    local function finish(winnerSide)
        if V.over then return end
        if V.noEnd then
            -- the -noend cheat keeps a decided game going; say so once per winner
            if V.pending ~= winnerSide then
                V.pending = winnerSide
                Log.info("game over held by -noend, winner: " .. winnerSide)
                for i = 0, bj_MAX_PLAYERS - 1 do
                    DisplayTimedTextToPlayer(Player(i), 0, 0, 10, "|cffffcc00" .. (winnerSide == "dota"
                        and "The Dota side" or "The Warcraft side") .. " has won; -noend keeps the game going.|r")
                end
            end
            return
        end
        V.over = true
        Log.info("game over, winner: " .. winnerSide)
        Log.flush()
        use("safe").call(function() use("announcer").gameOver(winnerSide) end)   -- "Radiant/Dire victory!" + music stinger
        for slot = 0, SLOT_WARCRAFT do
            local p = Player(slot)
            if GetPlayerSlotState(p) == PLAYER_SLOT_STATE_PLAYING then
                if Roles.side(slot) == winnerSide then
                    CustomVictoryBJ(p, true, true)
                else
                    CustomDefeatBJ(p, winnerSide == "dota" and "The Dota heroes destroyed your base." or "Your Ancient has fallen.")
                end
            end
        end
    end

    -- The -noend cheat (test builds and solo games): on, a decided game goes
    -- on; off again, a game decided meanwhile ends.
    function V.setNoEnd(on)
        V.noEnd = on
        if not on and V.pending then finish(V.pending) end
    end

    function V.init()
        local S = use("structures")
        local Cmd = use("warcraft")
        Events.on("death", function(dying)
            if dying == S.ancient then finish("warcraft") end
        end)
        -- The Dota side wins once the Warcraft player has had a town hall and
        -- lost them all. Test builds end the game too (the user's call,
        -- 2026-10-11); -noend keeps a test game going.
        local hadHall = false
        Timer.every(2, function()
            if V.over then return true end
            local n = Cmd.halls()
            if n > 0 then
                hadHall = true
            elseif hadHall then
                finish("dota")
            end
        end)
        -- Fountain: heals and restores mana of nearby allies (Dota: ~4 %/s).
        Timer.every(0.5, function()
            local f = S.fountain
            if not U.alive(f) then return end
            for _, u in ipairs(U.alliesOf(Player(SLOT_ANCIENTS), GetUnitX(f), GetUnitY(f), 1100)) do
                SetWidgetLife(u, GetWidgetLife(u) + BlzGetUnitMaxHP(u) * 0.02)
                SetUnitState(u, UNIT_STATE_MANA, GetUnitState(u, UNIT_STATE_MANA) + BlzGetUnitMaxMana(u) * 0.02)
            end
        end)
    end

    return V
end)
