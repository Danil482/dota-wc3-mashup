-- Dota-style item use and handling for the Dota HUD. In Reforged 2.0.1 the
-- native inventory buttons stay dead once the console bars are hidden (no
-- icons, clicks or hotkeys in game, 2026-10-10), so the HUD's own item icons
-- are the buttons.
--
-- Use: a click or Z X C V B N uses the item in that main slot of the
-- player's hero; no-target items fire at once; point, unit and tree items
-- wait for a left click in the world (a right click cancels; a click on a
-- HUD frame reports 0, 0 and is ignored). The TP slot works the same way
-- (inventory.lua teleports with the hero's TP ability).
--
-- Drag and drop, as in Dota: press on an item slot and release on another
-- slot to move or swap (main inventory, backpack, TP slot and stash under
-- inventory.lua's rules, the courier's slots among themselves); release over
-- the world to drop the item there, or over an allied hero to give it. The
-- hero (or the courier) walks there first; stash items drop in the fountain.
-- A release over the HUD's empty space puts the item back.
--
-- Two clicks move items too, for where the engine spoils a drag: a click on
-- a slot whose click uses nothing (backpack, stash, courier) picks it, and a
-- click on another slot swaps the two; a press off the slots or a right
-- click cancels. Main slots keep Dota's click: they use their item.
--
-- Multiplayer: the slot under each player's mouse comes from synced frame
-- MOUSE_ENTER / MOUSE_LEAVE events (item slots, and the HUD's click blockers
-- for its empty space): a press over the bottom HUD reports the ground under
-- it, so its coordinates cannot tell (jassdoc, BlzGetTriggerPlayerMouseX).
-- Presses and releases come from synced mouse events (registered after the
-- game started), and which items the HUD rows show (the hero's or the
-- courier's) from a sync message the HUD sends when it changes. Everything
-- acting on items runs in those synced events.
define("dota_items", function()
    local U = use("util")
    local Timer = use("timer")
    local Events = use("events")
    local Safe = use("safe")
    local Log = use("log")
    local I = {pending = {}, view = {}, hover = {}, hud = {}, drag = {}, picked = {}, walks = {}, dropped = {},
               tpClicks = {}}

    I.KEYS = {OSKEY_Z, OSKEY_X, OSKEY_C, OSKEY_V, OSKEY_B, OSKEY_N}
    -- player -> true: dota_settings.lua registered this player's own Dota item keys
    I.custom = {}
    local PICK_RADIUS = 150             -- unit / tree targets: nearest to the click
    local DROP_ON_UNIT = 100            -- an item released this close to a unit was dropped on it
    local DOUBLE_CLICK = 0.5            -- seconds between the clicks of a double click
    local DROP_RANGE = 100              -- a walking drop happens this close to its point
    local GIVE_RANGE = 250              -- ... and a walking give this close to the ally
    local SETTLE = 0.2                  -- a release over its own slot waits this long for a late MOUSE_ENTER
    local VIEW = "dvwview"
    local sentView = nil                -- local: the view last sent

    local function Inv() return use("inventory") end
    local function heroOf(p) return use("heroes").bySlot[GetPlayerId(p)] end

    local function say(p, text) DisplayTimedTextToPlayer(p, 0, 0, 2, text) end

    -- Test builds: one flushed line per press, release, hover change while
    -- the button is held and click-mode step, to see what the engine sends.
    local function trace(fmt, ...)
        if BUILD_TEST_MODE then
            Log.info("dota_items: " .. string.format(fmt, ...))
            Log.flush()
        end
    end

    local function tag(h) return h and (h.row .. ":" .. tostring(h.i)) or "none" end

    local function fail(p, text)
        say(p, "|cffff6060" .. text .. "|r")
        if defined("gamesounds") then use("gamesounds").error(p) end
    end

    local function targetOf(it)
        local name = use("items").nameOf(it)
        return name and (use("data.ids").item_targets or {})[name] or "none"
    end

    -- The slot number behind a HUD row cell, by the player's synced view:
    -- the main and backpack rows show the courier's nine slots while the
    -- courier is the focus.
    function I.slotOf(p, row, i)
        local cour = I.view[p] == "cour"
        if row == "main" then return cour and (Inv().COUR + i) or i end
        if row == "bag" then return cour and (Inv().COUR + 6 + i) or (Inv().BAG + i) end
        if row == "tp" then return Inv().TP end
        if row == "stash" then return Inv().STASH + i end
        return nil
    end

    function I.use(p, slot)
        local hero = heroOf(p)
        if not hero or not U.alive(hero) then return false end
        local it = UnitItemInSlot(hero, slot)
        if not it then return false end
        I.picked[p] = nil
        if not use("items").ready(hero, it, "hud") then return false end
        local t = targetOf(it)
        if t == "none" then
            I.pending[p] = nil
            return UnitUseItem(hero, it)
        end
        I.pending[p] = {slot = slot, item = it, target = t}
        say(p, "|cffffcc00Choose a target|r (right-click cancels)")
        return true
    end

    -- The TP slot: wait for the target point.
    function I.useTp(p)
        local hero = heroOf(p)
        if not hero or not U.alive(hero) then return false end
        local tp = Inv().get(p, "tp", 0)
        if not tp then
            fail(p, "No Town Portal Scroll")
            return false
        end
        I.picked[p] = nil
        if not use("items").ready(hero, tp, "tp") then return false end
        I.pending[p] = {tp = true, target = "point"}
        say(p, "|cffffcc00Choose a target|r (right-click cancels)")
        return true
    end

    -- A double tap or double click of the TP slot targets the fountain from
    -- at least 1500 away (https://dota2.fandom.com/wiki/Town_Portal_Scroll);
    -- nearer it waits for a target as usual.
    I.TP_HOME_MIN = 1500
    function I.tpHome(p)
        local hero = heroOf(p)
        local f = use("data.mapdata").dota.fountain
        if not hero or U.dist(GetUnitX(hero), GetUnitY(hero), f.x, f.y) < I.TP_HOME_MIN then return I.useTp(p) end
        I.pending[p] = nil
        return Inv().teleport(p, f.x, f.y)
    end

    -- The click mode: a first click picks a slot, the next one swaps it
    -- with another slot (the item of either moves; with both full they swap).
    local function pick(p, row, i)
        local slot, pk = I.slotOf(p, row, i), I.picked[p]
        I.picked[p] = nil
        if pk then
            local from, to = pk.slot, slot
            if not Inv().item(p, from) then from, to = slot, pk.slot end
            local ok, why = false, nil
            if from ~= to then ok, why = Inv().move(p, from, to) end
            if not ok and why then fail(p, why) end
            trace("player %d click mode: %d to %d -> %s", GetPlayerId(p), from, to, tostring(ok))
            return ok
        end
        local full = Inv().item(p, slot) ~= nil
        I.picked[p] = {slot = slot}
        say(p, full and "|cffffcc00Click a slot to move the item there|r (right-click cancels)"
            or "|cffffcc00Click an item to move it here|r (right-click cancels)")
        trace("player %d click mode: picked %s:%d (%s)", GetPlayerId(p), row, i, full and "an item" or "empty")
        return true
    end

    -- A click on a HUD slot (synced): main slots use the hero's items, the
    -- TP slot its scroll; any other click is the click mode's.
    function I.click(p, row, i)
        I.drag[p] = nil                     -- pressed and released on this slot
        local d = I.dropped[p]
        if d and d.row == row and d.i == i and Timer.now() - d.at < 0.5 then return false end
        local view = I.view[p] or "hero"
        if view == "other" then return false end
        if I.picked[p] then return pick(p, row, i) end
        if row == "main" and view == "hero" then
            return I.use(p, i)
        elseif row == "tp" then
            if view ~= "hero" then return false end
            local now, last = Timer.now(), I.tpClicks[p]
            I.tpClicks[p] = now
            if last and now - last <= DOUBLE_CLICK then
                I.tpClicks[p] = nil
                return I.tpHome(p)
            end
            return I.useTp(p)
        end
        return pick(p, row, i)
    end

    -- Dota's "Grab All" under the stash row.
    function I.grab(p)
        local n, why = Inv().grabAll(p)
        if n == 0 and why then fail(p, why) end
        return n
    end

    local function nearestTree(x, y)
        local best, bestD = nil, PICK_RADIUS
        local r = Rect(x - PICK_RADIUS, y - PICK_RADIUS, x + PICK_RADIUS, y + PICK_RADIUS)
        EnumDestructablesInRect(r, nil, function()
            local d = GetEnumDestructable()
            local dist = U.dist(x, y, GetDestructableX(d), GetDestructableY(d))
            if GetDestructableLife(d) > 0 and dist < bestD then best, bestD = d, dist end
        end)
        RemoveRect(r)
        return best
    end

    local function nearestUnit(x, y, filter, radius)
        local best, bestD = nil, radius or PICK_RADIUS
        for _, u in ipairs(U.enum(x, y, radius or PICK_RADIUS, filter)) do
            local dist = U.dist(x, y, GetUnitX(u), GetUnitY(u))
            if dist < bestD then best, bestD = u, dist end
        end
        return best
    end

    -- ------------------------------------------------------------ drag and drop

    -- A drag pending its release (hover changes are traced meanwhile).
    local function held(p)
        local d = I.drag[p]
        return d ~= nil and Timer.now() - d.at < 5
    end

    local function hoverTrace(p, what, row, i)
        if held(p) then
            trace("player %d %s %s:%s %s", GetPlayerId(p), what, row, tostring(i),
                I.drag[p].up and "after the release" or "while held")
        end
    end

    -- Synced: the HUD slot under the player's mouse; row "hud" is one of the
    -- HUD's click blockers (its empty space), named by `i`.
    function I.enter(p, row, i)
        if row == "hud" then
            I.hud[p] = I.hud[p] or {}
            I.hud[p][i] = true
        else
            I.hover[p] = {row = row, i = i}
        end
        hoverTrace(p, "enter", row, i)
    end

    function I.leave(p, row, i)
        if row == "hud" then
            if I.hud[p] then I.hud[p][i] = nil end
        else
            local h = I.hover[p]
            if h and h.row == row and h.i == i then I.hover[p] = nil end
        end
        hoverTrace(p, "leave", row, i)
    end

    -- The stash row hides away from home, maybe without a MOUSE_LEAVE: its
    -- hovers count while the HUD shows it (dota_hud's condition).
    local function stashShown(p)
        local hero = heroOf(p)
        return #Inv().list(p, "stash") > 0 or (hero ~= nil and U.alive(hero) and use("items").nearHome(hero))
    end

    -- The item slot under the player's mouse, if any.
    local function slotHover(p)
        local h = I.hover[p]
        if h and h.row == "stash" and not stashShown(p) then return nil end
        return h
    end

    -- Whether the mouse is over the HUD's empty space (a click blocker).
    local function overBlocker(p)
        for name in pairs(I.hud[p] or {}) do
            if name ~= "stash" or stashShown(p) then return true end
        end
        return false
    end

    -- Local, from the HUD: which items its rows show ("hero", "cour",
    -- "other"); every client learns it through sync data.
    function I.setView(view)
        if view ~= sentView then
            sentView = view
            BlzSendSyncData(VIEW, view)
        end
    end

    -- The item reaches the ground or the ally (the walk is over).
    local function handOver(p, w)
        local where, i = Inv().where(w.slot)
        if Inv().item(p, w.slot) ~= w.item then return end
        Inv().take(p, where, i)
        local ally = w.target
        if ally and U.alive(ally) then
            local q = GetOwningPlayer(ally)
            if heroOf(q) == ally and Inv().give(q, w.item) then
                Inv().changed(q)
                Inv().changed(p)
                return
            end
            -- no room: at the ally's feet, as Warcraft's own give does
            w.x, w.y = GetUnitX(ally), GetUnitY(ally)
        end
        SetItemPosition(w.item, w.x, w.y)
        SetItemVisible(w.item, true)
        Inv().changed(p)
    end

    -- An item dragged out of the HUD and released over the world at (x, y).
    function I.release(p, slot, x, y)
        local where, i = Inv().where(slot)
        local it = where and Inv().get(p, where, i)
        if not it then return false end
        local actor = where == "cour" and Inv().courier(p) or heroOf(p)
        if not actor or not U.alive(actor) then return false end
        local ally = nearestUnit(x, y, function(u)
            return u ~= actor and IsUnitType(u, UNIT_TYPE_HERO) and IsUnitAlly(u, p) and not IsUnitIllusion(u)
        end, DROP_ON_UNIT)
        if ally == nil and nearestUnit(x, y, function(u) return IsUnitEnemy(u, p) end, DROP_ON_UNIT) then
            fail(p, "Items cannot be given to enemies")
            return false
        end
        if where == "stash" then
            if ally then
                fail(p, "Stash items can only be dropped in the fountain")
                return false
            end
            local f = use("data.mapdata").dota.fountain
            Inv().take(p, "stash", i)
            SetItemPosition(it, f.x, f.y)
            SetItemVisible(it, true)
            return true
        end
        if where == "main" then
            if ally then return UnitDropItemTarget(actor, it, ally) end
            return UnitDropItemPoint(actor, it, x, y)
        end
        -- the backpack, the TP slot and the courier hold hidden items: the
        -- holder walks there, then hands the item over
        local w = {slot = slot, item = it, x = x, y = y, target = ally, actor = actor}
        I.walks[p] = w
        w.moving = true
        if ally then
            IssueTargetOrder(actor, "move", ally)
        else
            IssuePointOrder(actor, "move", x, y)
        end
        w.moving = false
        return true
    end

    local function walkTick()
        for p, w in pairs(I.walks) do
            local a, t = w.actor, w.target
            if not U.alive(a) or Inv().item(p, w.slot) ~= w.item or (t and not U.alive(t)) then
                I.walks[p] = nil
            else
                local tx, ty, range = w.x, w.y, DROP_RANGE
                if t then tx, ty, range = GetUnitX(t), GetUnitY(t), GIVE_RANGE end
                if U.dist(GetUnitX(a), GetUnitY(a), tx, ty) <= range then
                    I.walks[p] = nil
                    handOver(p, w)
                end
            end
        end
    end

    -- ------------------------------------------------------------ mouse

    local function onMouseDown()
        local p = GetTriggerPlayer()
        local x, y = BlzGetTriggerPlayerMouseX(), BlzGetTriggerPlayerMouseY()
        local left = BlzGetTriggerPlayerMouseButton() == MOUSE_BUTTON_TYPE_LEFT
        -- on the HUD: over a slot or its empty space (the bottom HUD reports
        -- the ground under it), or at 0, 0 (its opaque parts)
        local h = slotHover(p)
        local onFrame = h ~= nil or overBlocker(p) or (x == 0 and y == 0)
        if left then
            -- a drag starts only from a press on an item slot
            I.drag[p] = nil
            local slot = h and I.view[p] ~= "other" and I.slotOf(p, h.row, h.i)
            if slot and Inv().item(p, slot) then
                I.drag[p] = {row = h.row, i = h.i, slot = slot, at = Timer.now()}
            end
        end
        -- a click-mode pick ends with a press off the slots or a right-click
        local picked = I.picked[p]
        if picked and (not left or not h) then I.picked[p] = nil end
        if onFrame or I.drag[p] or picked or I.pending[p] then
            trace("player %d %s press at %d,%d over %s%s -> %s", GetPlayerId(p), left and "left" or "other",
                math.floor(x), math.floor(y), tag(h), overBlocker(p) and " (hud)" or "",
                I.drag[p] and ("drag from " .. tag(I.drag[p])) or "no drag")
        end
        local pend = I.pending[p]
        -- the item keeps waiting through a press on the HUD
        if not pend or onFrame then return end
        I.pending[p] = nil
        if not left then return end
        local hero = heroOf(p)
        if not hero or not U.alive(hero) then return end
        if pend.tp then
            local ok, why = Inv().teleport(p, x, y)
            if not ok and why then fail(p, why) end
            return
        end
        if UnitItemInSlot(hero, pend.slot) ~= pend.item then return end
        if not use("items").ready(hero, pend.item, "target") then return end
        if pend.target == "point" then
            UnitUseItemPoint(hero, pend.item, x, y)
        elseif pend.target == "tree" then
            local tree = nearestTree(x, y)
            if tree then UnitUseItemTarget(hero, pend.item, tree) end
        else
            local u = nearestUnit(x, y, function(t) return U.alive(t) end)
            if u then UnitUseItemTarget(hero, pend.item, u) end
        end
    end

    -- Where a drag ended: on another slot (moved there), over the HUD (put
    -- back), or over the world at the release point (dropped or given).
    -- `late`: decided a moment after a release over its own slot, when only
    -- a late hover of another slot moves it (a mouse moved off after a
    -- click must not drop the item).
    local function resolve(p, d, late)
        if I.drag[p] ~= d then return end          -- a click on its slot came first
        I.drag[p] = nil
        local h, what = slotHover(p), nil
        if h and (h.row ~= d.row or h.i ~= d.i) then
            I.dropped[p] = {row = h.row, i = h.i, at = Timer.now()}
            I.picked[p] = nil
            local ok, why = Inv().move(p, d.slot, I.slotOf(p, h.row, h.i))
            if not ok and why then fail(p, why) end
            what = "moved to " .. tag(h) .. " " .. tostring(ok)
        elseif late or h or overBlocker(p) or (d.x == 0 and d.y == 0) then
            what = h and "released on its own slot" or (late and "no other slot after the release: kept"
                or "released over the HUD: kept")
        else
            I.picked[p] = nil
            what = "released over the world " .. tostring(I.release(p, d.slot, d.x, d.y))
        end
        trace("player %d drag from %s: %s", GetPlayerId(p), tag(d), what)
    end

    local function onMouseUp()
        local p = GetTriggerPlayer()
        if BlzGetTriggerPlayerMouseButton() ~= MOUSE_BUTTON_TYPE_LEFT then return end
        local x, y = BlzGetTriggerPlayerMouseX(), BlzGetTriggerPlayerMouseY()
        local d, h = I.drag[p], slotHover(p)
        if d or h or overBlocker(p) then
            trace("player %d left release at %d,%d over %s%s", GetPlayerId(p), math.floor(x), math.floor(y), tag(h),
                overBlocker(p) and " (hud)" or "")
        end
        if not d or d.up then return end
        d.up, d.x, d.y = true, x, y
        -- still over its own slot: a click, or a drag whose hover events the
        -- engine held back until the release; a late MOUSE_ENTER tells
        if h and h.row == d.row and h.i == d.i then
            Timer.after(SETTLE, function() resolve(p, d, true) end)
        else
            resolve(p, d)
        end
    end

    -- A walking drop or give ends with any order the player gives.
    local function onOrder(u)
        for p, w in pairs(I.walks) do
            if w.actor == u and not w.moving then I.walks[p] = nil end
        end
    end

    -- Keys, mouse and view sync, for the Dota players. Mouse events must not
    -- be registered while the map loads; this runs from the HUD after the start.
    function I.init(slots)
        local keys, down, up, view = CreateTrigger(), CreateTrigger(), CreateTrigger(), CreateTrigger()
        for _, slot in ipairs(slots) do
            for _, k in ipairs(I.KEYS) do BlzTriggerRegisterPlayerKeyEvent(keys, Player(slot), k, 0, true) end
            TriggerRegisterPlayerEvent(down, Player(slot), EVENT_PLAYER_MOUSE_DOWN)
            TriggerRegisterPlayerEvent(up, Player(slot), EVENT_PLAYER_MOUSE_UP)
            BlzTriggerRegisterPlayerSyncEvent(view, Player(slot), VIEW, false)
        end
        TriggerAddAction(keys, function()
            Safe.call(function()
                if I.custom[GetTriggerPlayer()] then return end
                local key = BlzGetTriggerPlayerKey()
                for i, k in ipairs(I.KEYS) do
                    if GetHandleId(k) == GetHandleId(key) then I.use(GetTriggerPlayer(), i - 1) end
                end
            end)
        end)
        TriggerAddAction(down, function() Safe.call(onMouseDown) end)
        TriggerAddAction(up, function() Safe.call(onMouseUp) end)
        TriggerAddAction(view, function()
            Safe.call(function()
                local v = BlzGetTriggerSyncData()
                if v == "hero" or v == "cour" or v == "other" then I.view[GetTriggerPlayer()] = v end
            end)
        end)
        Events.on("order", onOrder)
        Timer.every(0.1, walkTick)
    end

    return I
end)
