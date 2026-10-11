-- Dota hero players: hero pick (a dialog for humans, random for bots), spawn at
-- the fountain with the hero's innate abilities, and Dota-style respawn.
define("heroes", function()
    local Log = use("log")
    local Events = use("events")
    local Timer = use("timer")
    local Roles = use("roles")
    local U = use("util")
    local H = {bySlot = {}, keyOf = {}, taken = {}}

    local function ids() return use("data.ids").heroes end

    function H.roster()
        local list = {}
        for key in pairs(use("data.heroes")) do list[#list + 1] = key end
        table.sort(list)
        return list
    end

    local function fountain() return use("data.mapdata").dota.fountain end

    function H.spawn(slot, key)
        local code = ids()[key]
        local f = fountain()
        local u = CreateUnit(Player(slot), FourCC(code), f.x + 350, f.y + 350, 45)
        H.bySlot[slot], H.keyOf[u], H.taken[key] = u, key, slot
        use("sound").register(u, key)
        for _, inn in ipairs(ids()[key .. "_innates"] or {}) do
            UnitAddAbility(u, FourCC(inn))
            UnitMakeAbilityPermanent(u, true, FourCC(inn))
        end
        SetPlayerState(Player(slot), PLAYER_STATE_RESOURCE_GOLD, 600)
        if GetLocalPlayer() == Player(slot) then
            ClearSelection()
            SelectUnit(u, true)
            PanCameraToTimed(GetUnitX(u), GetUnitY(u), 0)
        end
        Log.info("slot " .. slot .. " spawns " .. key)
        use("sound").vo(u, "spawn")
        -- Humans keep control of their hero even in test builds.
        if Roles.isBot(slot) then
            use("hero_bot").add(u, key)
        end
        Events.emit("hero_spawned", u, key, slot)
        return u
    end

    -- Prefer heroes whose ability module exists, so bots use real spells.
    local function randomFree()
        local ready, free = {}, {}
        for _, key in ipairs(H.roster()) do
            if not H.taken[key] then
                free[#free + 1] = key
                if defined("hero_" .. key) then ready[#ready + 1] = key end
            end
        end
        local pool = #ready > 0 and ready or free
        return pool[GetRandomInt(1, #pool)]
    end

    -- Draft: humans pick first from a dialog of free heroes; bots fill the
    -- remaining slots afterwards (or after 45 s if a human never picks).
    local function showDialog(slot, done)
        local d = DialogCreate()
        DialogSetMessage(d, "Pick your Dota hero")
        local buttons = {}
        for _, key in ipairs(H.roster()) do
            if not H.taken[key] then
                local title = use("data.heroes")[key].title
                if not defined("hero_" .. key) then title = title .. " (no spells yet)" end
                buttons[DialogAddButton(d, title, 0)] = key
            end
        end
        local trig = CreateTrigger()
        TriggerRegisterDialogEvent(trig, d)
        TriggerAddAction(trig, function()
            use("safe").call(function()
                local key = buttons[GetClickedButton()]
                DialogDisplay(Player(slot), d, false)
                DestroyTrigger(trig)
                if H.bySlot[slot] then return end
                if not key or H.taken[key] then
                    showDialog(slot, done)      -- someone took it meanwhile: ask again
                    return
                end
                H.spawn(slot, key)
                done()
            end)
        end)
        DialogDisplay(Player(slot), d, true)
    end

    function H.pickAll(onDone)
        local humans, bots = {}, {}
        for _, slot in ipairs(Roles.heroSlots) do
            if Roles.isBot(slot) then bots[#bots + 1] = slot else humans[#humans + 1] = slot end
        end
        local finished = false
        local function botsPick()
            if finished then return end
            finished = true
            for _, slot in ipairs(humans) do
                if not H.bySlot[slot] then H.spawn(slot, randomFree()) end
            end
            for _, slot in ipairs(bots) do
                H.spawn(slot, randomFree())
            end
            if onDone then onDone() end
        end
        local waiting = #humans
        if waiting == 0 then
            botsPick()
            return
        end
        for _, slot in ipairs(humans) do
            showDialog(slot, function()
                waiting = waiting - 1
                if waiting == 0 then botsPick() end
            end)
        end
        Timer.after(45, botsPick)
    end

    -- Dota 2 respawn times grow with level, capped at 100 seconds.
    function H.respawnTime(level)
        return math.min(100, 4 + 3.2 * level)
    end

    H.respawnAt = {}          -- dead hero -> game time of its fountain respawn
    H.respawnPenalty = {}     -- hero -> seconds added to its next respawn (after a buyback)
    local respawnGen = {}

    local function respawn(hero, key, slot)
        H.respawnAt[hero] = nil
        respawnGen[hero] = (respawnGen[hero] or 0) + 1
        local f = fountain()
        ReviveHero(hero, f.x + 350, f.y + 350, true)
        Events.emit("hero_respawned", hero, key, slot)
    end

    -- Respawns a dead hero that waits for its fountain respawn now (buyback);
    -- false when it is not waiting for one.
    function H.revive(hero)
        local key = H.keyOf[hero]
        if not key or not H.respawnAt[hero] or U.alive(hero) then return false end
        respawn(hero, key, GetPlayerId(GetOwningPlayer(hero)))
        return true
    end

    function H.init()
        Events.on("death", function(dying)
            local key = H.keyOf[dying]
            if not key then return end
            local slot = GetPlayerId(GetOwningPlayer(dying))
            local t = H.respawnTime(GetHeroLevel(dying)) + (H.respawnPenalty[dying] or 0)
            H.respawnPenalty[dying] = nil
            H.respawnAt[dying] = Timer.now() + t
            local gen = (respawnGen[dying] or 0) + 1
            respawnGen[dying] = gen
            Log.info(key .. " died, respawn in " .. string.format("%.0f", t))
            Timer.after(t, function()
                if respawnGen[dying] == gen then respawn(dying, key, slot) end
            end)
        end)
    end

    function H.count()
        local n = 0
        for _, u in pairs(H.bySlot) do
            if u then n = n + 1 end
        end
        return n
    end

    return H
end)
