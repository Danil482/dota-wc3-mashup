-- Dota voice lines for heroes in place of Warcraft's unit responses (the
-- personalized map gives heroes no WC3 sound set): move and attack orders
-- for the hero's own player, kills, deaths, level-ups and respawns. Spawn
-- lines play in "heroes", cast lines in "abilities"; rune, Aegis and
-- failed-cast lines in "gamesounds", battle-begins and first-blood lines in
-- "announcer".
define("voice", function()
    local Events = use("events")
    local Timer = use("timer")
    local Roles = use("roles")
    local S = use("sound")
    local V = {}

    local ORDER_COOLDOWN = 5          -- seconds between order responses per hero
    local ORDER_CHANCE = 0.7
    local nextOrderLine = {}

    function V.init()
        local MOVE, SMART, ATTACK = OrderId("move"), OrderId("smart"), OrderId("attack")
        Events.on("order", function(u, order, target)
            if not S.heroOf(u) or not Roles.humans[GetPlayerId(GetOwningPlayer(u))] then return end
            local event
            if order == ATTACK or (order == SMART and target and IsUnitEnemy(target, GetOwningPlayer(u))) then
                event = "attack"
            elseif order == MOVE or order == SMART then
                event = "move"
            else
                return
            end
            local now = Timer.now()
            if (nextOrderLine[u] or 0) > now then return end
            nextOrderLine[u] = now + ORDER_COOLDOWN
            S.vo(u, event, ORDER_CHANCE, true)
        end)
        Events.on("death", function(dying, killer)
            if S.heroOf(dying) then S.vo(dying, "death") end
            if killer and killer ~= dying and S.heroOf(killer) and IsUnitType(dying, UNIT_TYPE_HERO)
                and IsUnitEnemy(dying, GetOwningPlayer(killer)) then
                Timer.after(0.8, function() S.vo(killer, "kill") end)
            end
        end)
        Events.on("hero_level", function(u) S.vo(u, "levelup", 0.6) end)
        -- Dota has its own respawn lines; spawn lines remain the fallback
        Events.on("hero_respawned", function(u) S.vo(u, S.has(u, "respawn") and "respawn" or "spawn") end)
    end

    return V
end)
