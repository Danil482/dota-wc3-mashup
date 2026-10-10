-- Dota-style item use for the Dota HUD. In Reforged 2.0.1 the native inventory
-- buttons stay dead once the console bars are hidden (no icons, clicks or
-- hotkeys in game, 2026-10-10), so the HUD's own item icons are the buttons.
-- A click or Z X C V B N uses the item in that slot of the player's hero:
-- no-target items fire at once; point, unit and tree items wait for a left
-- click in the world (a right click cancels). Runs in synced events only.
define("dota_items", function()
    local U = use("util")
    local I = {pending = {}}

    I.KEYS = {OSKEY_Z, OSKEY_X, OSKEY_C, OSKEY_V, OSKEY_B, OSKEY_N}
    -- player -> true: dota_settings.lua registered this player's own Dota item keys
    I.custom = {}
    local PICK_RADIUS = 150             -- unit / tree targets: nearest to the click

    local function heroOf(p) return use("heroes").bySlot[GetPlayerId(p)] end

    local function targetOf(it)
        local name = use("items").nameOf(it)
        return name and (use("data.ids").item_targets or {})[name] or "none"
    end

    function I.use(p, slot)
        local hero = heroOf(p)
        if not hero or not U.alive(hero) then return false end
        local it = UnitItemInSlot(hero, slot)
        if not it then return false end
        local t = targetOf(it)
        if t == "none" then
            I.pending[p] = nil
            return UnitUseItem(hero, it)
        end
        I.pending[p] = {slot = slot, item = it, target = t}
        DisplayTimedTextToPlayer(p, 0, 0, 2, "|cffffcc00Choose a target|r (right-click cancels)")
        return true
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

    local function nearestUnit(x, y)
        local best, bestD = nil, PICK_RADIUS
        for _, u in ipairs(U.enum(x, y, PICK_RADIUS)) do
            local dist = U.dist(x, y, GetUnitX(u), GetUnitY(u))
            if U.alive(u) and dist < bestD then best, bestD = u, dist end
        end
        return best
    end

    local function onMouseDown()
        local p = GetTriggerPlayer()
        local pend = I.pending[p]
        if not pend then return end
        I.pending[p] = nil
        if BlzGetTriggerPlayerMouseButton() ~= MOUSE_BUTTON_TYPE_LEFT then return end
        local hero = heroOf(p)
        if not hero or not U.alive(hero) or UnitItemInSlot(hero, pend.slot) ~= pend.item then return end
        local x, y = BlzGetTriggerPlayerMouseX(), BlzGetTriggerPlayerMouseY()
        if pend.target == "point" then
            UnitUseItemPoint(hero, pend.item, x, y)
        elseif pend.target == "tree" then
            local tree = nearestTree(x, y)
            if tree then UnitUseItemTarget(hero, pend.item, tree) end
        else
            local u = nearestUnit(x, y)
            if u then UnitUseItemTarget(hero, pend.item, u) end
        end
    end

    -- Keys and the world click, for the Dota players. Mouse events must not be
    -- registered while the map loads; this runs from the HUD after the start.
    function I.init(slots)
        local keys, mouse = CreateTrigger(), CreateTrigger()
        for _, slot in ipairs(slots) do
            for _, k in ipairs(I.KEYS) do BlzTriggerRegisterPlayerKeyEvent(keys, Player(slot), k, 0, true) end
            TriggerRegisterPlayerEvent(mouse, Player(slot), EVENT_PLAYER_MOUSE_DOWN)
        end
        TriggerAddAction(keys, function()
            use("safe").call(function()
                if I.custom[GetTriggerPlayer()] then return end
                local key = BlzGetTriggerPlayerKey()
                for i, k in ipairs(I.KEYS) do
                    if GetHandleId(k) == GetHandleId(key) then I.use(GetTriggerPlayer(), i - 1) end
                end
            end)
        end)
        TriggerAddAction(mouse, function() use("safe").call(onMouseDown) end)
    end

    return I
end)
