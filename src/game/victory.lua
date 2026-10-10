-- Win conditions: the Dota side wins when the commander has no town hall left;
-- the commander wins when the Ancient falls. The fountain heals its allies.
define("victory", function()
    local Log = use("log")
    local Events = use("events")
    local Timer = use("timer")
    local Roles = use("roles")
    local U = use("util")
    local V = {over = false}

    local function finish(winnerSide)
        if V.over then return end
        V.over = true
        Log.info("game over, winner: " .. winnerSide)
        Log.flush()
        for slot = 0, SLOT_COMMANDER do
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

    function V.init()
        local S = use("structures")
        local Cmd = use("commander")
        Events.on("death", function(dying)
            if dying == S.ancient and not BUILD_TEST_MODE then finish("commander") end
        end)
        -- The Dota side wins once the commander has had a town hall and lost
        -- them all. Test builds never end the game on their own.
        local hadHall = false
        Timer.every(2, function()
            if V.over then return true end
            local n = Cmd.halls()
            if n > 0 then
                hadHall = true
            elseif hadHall and not BUILD_TEST_MODE then
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
