-- Dota's courier: one per human Dota player, spawned at the fountain with the
-- player's hero (bots shop at the fountain and have none). As in Dota
-- (https://dota2.fandom.com/wiki/Courier and its changelog page
-- https://dota2.fandom.com/wiki/Courier/Changelogs, 7.27, 7.29 and 7.35):
--   * it walks until its owner's hero reaches level 4, then flies: the
--     flying unit replaces the walking one;
--   * it gains 10 movement speed per hero level after the first, unlocks
--     Speed Burst at level 10 and Shield at level 20;
--   * 1 melee hero attack, 2 ranged hero attacks or 6 other attacks kill
--     it; spells do not (it is spell immune), and it is invulnerable in the
--     fountain's aura (https://dota2.fandom.com/wiki/Fountain: radius 1200,
--     the buff lingers 3 s);
--   * it respawns at the fountain 60 s + 6 s per hero level after its
--     death, still carrying its items;
--   * carrying a Clarity, Mango, Faerie Fire, Healing Salve or Tango slows
--     it by 15% (not during Speed Burst, which is hasted).
-- Numbers that Dota's files hold (speed, health, vision, Speed Burst and
-- Shield) come from data.courier (tools/extract_courier.py).
--
-- Its command card is Dota's (tools/gen_objects.py COURIER_CARD): Retrieve
-- Items (Q: fetch the stash within 650 of the home shop, then deliver),
-- Go To Secret Shop (W), Return Items (E: put its items into the stash),
-- Speed Burst (D), Transfer Items (F: follow the hero, hand everything over,
-- go home), Shield (R). If the hero dies during a delivery, the courier
-- returns the items. Any order the player gives ends its task. Its items
-- are inventory.lua's "cour" slots: inactive, kept while it is dead, bought
-- into when it stands at a Secret Shop.
--
-- Hooks: C.of(p), C.record(p), C.add(p), C.deliver(p) (Dota's "Deliver
-- Items", F3), C.cast(p, name) (Speed Burst and Shield keys), C.select(p,
-- double) (F2; local).
-- Start with use("courier").init() after use("inventory").init().
define("courier", function()
    local Events = use("events")
    local Timer = use("timer")
    local Mods = use("mods")
    local U = use("util")
    local Log = use("log")
    local C = {started = false}

    C.SPEED_PER_LEVEL = 10
    C.RESPAWN_BASE, C.RESPAWN_PER_LEVEL = 60, 6
    C.FLY_LEVEL, C.BURST_LEVEL, C.SHIELD_LEVEL = 4, 10, 20
    C.HITS = {melee = 1, ranged = 2, other = 6}
    C.FOUNTAIN_RADIUS, C.FOUNTAIN_LINGER = 1200, 3
    C.SLOW = 0.15
    C.SLOWING = {item_clarity = true, item_enchanted_mango = true, item_faerie_fire = true, item_flask = true,
                 item_tango = true}
    -- The wiki's Retrieve Items: the courier walks to a spot 400 in front of
    -- the shopkeeper and takes the stash within 250 + 400 of it.
    C.STASH_SPOT, C.STASH_RANGE = 400, 650
    -- How close it comes to hand items to the hero: the wiki gives none, so
    -- the stash's pickup range (250) is used.
    C.HANDOFF = 250
    C.ARRIVE = 150              -- a walk to the fountain or a Secret Shop ends this close
    C.TICK = 0.2

    local couriers = {}         -- player id -> {player, unit, flying, task, dead, ...}
    local byUnit = {}           -- unit -> courier record
    local issuing = false       -- this module is ordering a courier
    local abil = {}             -- ability name -> id
    local nameOf = {}           -- ability id -> name

    local function I() return use("items") end
    local function Inv() return use("inventory") end
    local function data() return use("data.courier") end
    local function heroOf(p) return use("heroes").bySlot[GetPlayerId(p)] end

    local function say(p, text) DisplayTimedTextToPlayer(p, 0, 0, 3, text) end

    local function fail(p, text)
        say(p, "|cffff6060" .. text .. "|r")
        if defined("gamesounds") then use("gamesounds").error(p) end
    end

    -- The player's courier unit (alive or not), or nil.
    function C.of(p)
        local c = p and couriers[GetPlayerId(p)]
        return c and c.unit or nil
    end

    function C.record(p) return couriers[GetPlayerId(p)] end

    local function level(c)
        local hero = heroOf(c.player)
        return hero and math.max(1, GetHeroLevel(hero)) or 1
    end

    local function fountain() return use("data.mapdata").dota.fountain end

    local function homeSpot(c)
        local f = fountain()
        return f.x + 200 + 60 * (c.id % 5), f.y + 100
    end

    -- Dota's stash spot: 400 in front of the home shop, toward the fountain.
    local function stashSpot()
        local s = use("structures").shop or I().shops[1]
        local f = fountain()
        if not s then return f.x, f.y end
        local sx, sy = GetUnitX(s), GetUnitY(s)
        return U.polar(sx, sy, C.STASH_SPOT, U.angle(sx, sy, f.x, f.y))
    end

    local function nearStash(u)
        local s = use("structures").shop or I().shops[1]
        return s ~= nil and U.unitDist(u, s) <= C.STASH_RANGE
    end

    -- The team's Secret Shop: the one nearer to the Dota fountain.
    local function secretShop()
        local f = fountain()
        local best, bestD = nil, math.huge
        for _, s in ipairs(I().secretShops or {}) do
            local d = U.dist(f.x, f.y, GetUnitX(s), GetUnitY(s))
            if d < bestD then best, bestD = s, d end
        end
        return best
    end

    local function order(c, fn)
        issuing = true
        local ok = fn(c.unit)
        issuing = false
        return ok
    end

    local function moveTo(c, x, y)
        c.goal = {x = x, y = y}
        return order(c, function(u) return IssuePointOrder(u, "move", x, y) end)
    end

    local function count(c)
        return #Inv().list(c.player, "cour")
    end

    -- ------------------------------------------------------------ tasks

    local start

    local function goHome(c)
        c.task = "home"
        moveTo(c, homeSpot(c))
    end

    -- Every item the courier carries goes to the hero (main inventory and
    -- backpack, scrolls to the TP slot); what does not fit stays on it.
    local function handOver(c)
        local p = c.player
        local left = 0
        for _, e in ipairs(Inv().list(p, "cour")) do
            Inv().take(p, "cour", e.i)
            if not Inv().give(p, e.item) then
                Inv().put(p, e.item, "cour", e.i)
                left = left + 1
            end
        end
        Inv().changed(p)
        if left > 0 then fail(p, "The hero's inventory is full") end
    end

    local function takeStash(c)
        local p = c.player
        for _, e in ipairs(Inv().list(p, "stash")) do
            if Inv().free(p, "cour") == 0 then break end
            Inv().take(p, "stash", e.i)
            Inv().put(p, e.item, "cour")
        end
        Inv().combine(p)
    end

    local function putStash(c)
        local p = c.player
        for _, e in ipairs(Inv().list(p, "cour")) do
            if Inv().free(p, "stash") == 0 then break end
            Inv().take(p, "cour", e.i)
            Inv().put(p, e.item, "stash")
        end
        Inv().changed(p)
    end

    -- Walks toward the task's place; `again`: only when it stands idle.
    local function head(c, again)
        local u = c.unit
        if again and GetUnitCurrentOrder(u) ~= 0 then return end
        if c.task == "transfer" then
            local hero = heroOf(c.player)
            order(c, function(cu) return IssueTargetOrder(cu, "move", hero) end)
        elseif c.task == "retrieve" or c.task == "return" then
            moveTo(c, stashSpot())
        elseif c.goal then
            moveTo(c, c.goal.x, c.goal.y)
        end
    end

    -- One step of the courier's task (C.TICK).
    local function step(c)
        local u = c.unit
        if c.dead or not U.alive(u) or not c.task then return end
        local p = c.player
        local task = c.task
        if task == "retrieve" then
            if not nearStash(u) then return head(c, true) end
            if #Inv().list(p, "stash") == 0 then return goHome(c) end
            takeStash(c)
            start(c, "transfer")
        elseif task == "transfer" then
            local hero = heroOf(p)
            if not U.alive(hero) then return start(c, "return") end
            if U.unitDist(u, hero) > C.HANDOFF then return head(c, true) end
            handOver(c)
            goHome(c)
        elseif task == "return" then
            if not nearStash(u) then return head(c, true) end
            putStash(c)
            goHome(c)
        else
            local g = c.goal
            if g and U.dist(GetUnitX(u), GetUnitY(u), g.x, g.y) > C.ARRIVE then return head(c, true) end
            c.task, c.goal = nil, nil
        end
    end

    -- Starts a task: "retrieve", "transfer", "return", "secret" or "home".
    -- Dota: with nothing to fetch or carry, the courier goes home instead.
    start = function(c, task)
        c.goal = nil
        local p = c.player
        if task == "secret" then
            local s = secretShop()
            if not s then return end
            c.task, c.goal = "secret", {x = GetUnitX(s), y = GetUnitY(s)}
            return head(c)
        end
        if task == "home" or (task == "retrieve" and #Inv().list(p, "stash") == 0)
                or ((task == "transfer" or task == "return") and count(c) == 0) then
            return goHome(c)
        end
        c.task = task
        step(c)
        if c.task == task then head(c) end
    end

    -- ------------------------------------------------------------ abilities

    local function burst(c)
        Mods.remove(c.unit, "courier_slow")
        Mods.add(c.unit, "courier_burst", {duration = data().abilities.courier_burst.values.duration,
            props = {move_pct = data().abilities.courier_burst.values.movement_speed / 100}, dispel = "none"})
    end

    local function shield(c)
        Mods.add(c.unit, "courier_shield", {duration = data().abilities.courier_shield.values.duration,
            props = {invulnerable = true}, dispel = "none"})
    end

    local RUN = {
        courier_take_stash_items = function(c) start(c, "retrieve") end,
        courier_go_to_secretshop = function(c) start(c, "secret") end,
        courier_return_stash_items = function(c) start(c, "return") end,
        courier_transfer_items = function(c) start(c, "transfer") end,
        courier_burst = burst,
        courier_shield = shield,
    }

    local function onSpell(caster, id)
        local c = byUnit[caster]
        local name = nameOf[id]
        if not c or not name then return end
        -- an order given inside the spell's own event would be overridden
        Timer.after(0, function()
            if byUnit[caster] == c and not c.dead then RUN[name](c) end
        end)
    end

    -- Dota's "Deliver Items" (F3, the HUD button): the stash's items when
    -- there are any, else what the courier carries.
    function C.deliver(p)
        local c = couriers[GetPlayerId(p)]
        if not c then return false end
        if c.dead then
            fail(p, "The courier is dead")
            return false
        end
        if #Inv().list(p, "stash") > 0 then
            start(c, "retrieve")
        elseif count(c) > 0 then
            start(c, "transfer")
        else
            fail(p, "No items to deliver")
            return false
        end
        return true
    end

    -- Speed Burst or Shield from the player's keys: the courier casts it, so
    -- its cooldown and unlock level hold.
    function C.cast(p, name)
        local c = couriers[GetPlayerId(p)]
        if not c or c.dead or not abil[name] then return false end
        local want = name == "courier_burst" and C.BURST_LEVEL or C.SHIELD_LEVEL
        if level(c) < want then
            fail(p, "The courier learns that at hero level " .. want)
            return false
        end
        local o = use("data.ids").courier.orders[name]
        local ok = order(c, function(u) return IssueImmediateOrder(u, o) end)
        if not ok then fail(p, "Not ready yet") end
        return ok
    end

    -- Local, on the presser's client: Dota's "Select Courier" (F2); a double
    -- tap also centres the camera on it.
    function C.select(p, double)
        local u = C.of(p)
        if p ~= GetLocalPlayer() or not U.alive(u) then return end
        ClearSelection()
        SelectUnit(u, true)
        if double then PanCameraToTimed(GetUnitX(u), GetUnitY(u), 0) end
    end

    -- ------------------------------------------------------------ the unit

    local function unitCode(flying)
        local units = use("data.ids").courier.units
        return FourCC(flying and units.courier_flying or units.courier)
    end

    -- Level effects: speed, flying, Speed Burst and Shield unlocks.
    local function sync(c)
        local u = c.unit
        if c.dead or not U.alive(u) then return end
        local lv = level(c)
        if (lv >= C.FLY_LEVEL) ~= c.flying then
            c.flying = lv >= C.FLY_LEVEL
            local old = u
            local mine = IsUnitSelected(old, GetLocalPlayer())
            u = CreateUnit(c.player, unitCode(c.flying), GetUnitX(old), GetUnitY(old), GetUnitFacing(old))
            byUnit[old], byUnit[u], c.unit, c.speedLevel = nil, c, u, nil
            RemoveUnit(old)
            if (c.taken or 0) > 0 then SetWidgetLife(u, math.max(1, BlzGetUnitMaxHP(u) * (1 - c.taken))) end
            if mine then SelectUnit(u, true) end
            local task = c.task
            c.task = nil
            if task then start(c, task) end
        end
        if c.speedLevel ~= lv then
            c.speedLevel = lv
            Mods.add(u, "courier_level", {persist = true, dispel = "none",
                                          props = {move_flat = C.SPEED_PER_LEVEL * (lv - 1)}})
            BlzUnitDisableAbility(u, abil.courier_burst, lv < C.BURST_LEVEL, false)
            BlzUnitDisableAbility(u, abil.courier_shield, lv < C.SHIELD_LEVEL, false)
        end
    end

    local function spawn(c)
        local x, y = homeSpot(c)
        c.dead, c.task, c.speedLevel, c.taken = false, nil, nil, 0
        c.flying = level(c) >= C.FLY_LEVEL
        c.unit = CreateUnit(c.player, unitCode(c.flying), x, y, 270)
        byUnit[c.unit] = c
        sync(c)
    end

    -- The player's courier, once (with the hero's first spawn).
    function C.add(p)
        local id = GetPlayerId(p)
        if couriers[id] then return end
        local c = {player = p, id = id}
        couriers[id] = c
        spawn(c)
        Log.info("courier for player " .. id)
    end

    -- Fountain aura, consumable slow, level effects, tasks.
    local function tick()
        local f = fountain()
        for _, c in pairs(couriers) do
            local u = c.unit
            if not c.dead and U.alive(u) then
                sync(c)
                u = c.unit
                if U.dist(GetUnitX(u), GetUnitY(u), f.x, f.y) <= C.FOUNTAIN_RADIUS then
                    Mods.add(u, "courier_fountain", {duration = C.FOUNTAIN_LINGER, props = {invulnerable = true},
                                                     dispel = "none"})
                    -- the fountain is the only thing that heals it
                    if (c.taken or 0) > 0 then
                        c.taken = 0
                        SetWidgetLife(u, BlzGetUnitMaxHP(u))
                    end
                end
                local slowed = false
                if not Mods.has(u, "courier_burst") then
                    for _, e in ipairs(Inv().list(c.player, "cour")) do
                        if C.SLOWING[e.name] then slowed = true end
                    end
                end
                if slowed ~= Mods.has(u, "courier_slow") then
                    if slowed then
                        Mods.add(u, "courier_slow", {persist = true, dispel = "none", props = {move_pct = -C.SLOW}})
                    else
                        Mods.remove(u, "courier_slow")
                    end
                end
                step(c)
            end
        end
    end

    -- Attacks to kill: melee heroes 1, ranged heroes 2, anything else 6;
    -- other damage does nothing. The health bar shows the share taken; the
    -- killing hit is an overkill, so Warcraft's armor and attack types
    -- cannot change the count.
    local function onDamaging(source, target, info)
        local c = target and byUnit[target]
        if not c then return end
        local hits = nil
        if info.attack and source then
            hits = C.HITS.other
            if IsUnitType(source, UNIT_TYPE_HERO) then
                hits = IsUnitType(source, UNIT_TYPE_MELEE_ATTACKER) and C.HITS.melee or C.HITS.ranged
            end
        end
        info.amount = 0
        if not hits then return end
        c.taken = (c.taken or 0) + 1 / hits
        local max = BlzGetUnitMaxHP(target)
        if c.taken >= 1 - 1e-6 then
            info.amount = max * 100
        else
            SetWidgetLife(target, math.max(1, max * (1 - c.taken)))
        end
    end

    local function onDeath(dying)
        local c = dying and byUnit[dying]
        if not c or c.unit ~= dying then return end
        c.dead, c.task = true, nil
        local wait = C.RESPAWN_BASE + C.RESPAWN_PER_LEVEL * level(c)
        c.respawnAt = Timer.now() + wait
        byUnit[dying] = nil
        if defined("announcer") then use("announcer").say("cour_kill_rad", 1) end
        Timer.after(wait, function()
            if c.dead then spawn(c) end
        end)
    end

    local function onOrder(u)
        local c = byUnit[u]
        if c and not issuing then c.task, c.goal, c.follow = nil, nil, nil end
    end

    function C.init()
        if C.started then return end
        C.started = true
        local ids = use("data.ids").courier
        if not ids then
            Log.warn("courier: no courier objects in this map")
            return
        end
        for name, code in pairs(ids.abilities) do
            abil[name] = FourCC(code)
            nameOf[FourCC(code)] = name
        end
        local Roles = use("roles")
        Events.on("hero_spawned", function(_, _, slot)
            if Roles.humans[slot] then C.add(Player(slot)) end
        end)
        Events.on("spell_effect", onSpell)
        Events.on("death", onDeath)
        Events.on("order", onOrder)
        use("damage").onDamaging(onDamaging)
        Timer.every(C.TICK, tick)
    end

    return C
end)
