-- Offline exercise for the Dota settings (src/ui/dota_settings.lua), on top of
-- the frame and key model of tools/mock/dota_hud.lua. Adds the Preload file,
-- ability tooltips, sync data, key-down and key-up events with meta keys, the
-- unit under the cursor, the camera, selection, the worker type, ability
-- fields, orders and item use to the mock. After the normal run and the HUD
-- exercise it checks: the file is read only after loading and the tooltip
-- stash is restored; the keys reach every client through sync data; a D/F swap
-- keeps Warcraft's own keys; a remapped ability key presses the native hotkey;
-- item keys use the items through dota_items once, with Alt+B and B kept apart
-- and a held key acting once; dota_items' default keys skip the player but
-- still serve players without their own keys; the TP key finds the scroll; the
-- shop and select-hero keys; the synced cursor from mouse events registered
-- after the start; quick cast of a point ability at the cursor and of a unit
-- ability at the hovered (and only a visible) unit, on key press or release,
-- closing Warcraft's targeting cursor, by the build data's string order while
-- the Channel fields read at run time are empty (as in game), by order id when
-- the string order is refused, and by the run-time fields without build data;
-- a point item at the cursor; double-tap self cast; camera distance and zoom
-- lock; the right-click hold (moves only once the cursor moves, throttled, to
-- the synced selection, a move marker for the holder only, freed again on
-- every client, ends on release, death or another order); auto attack Never,
-- Standard and Always through the worker type, set again when lost, left
-- alone on units that are workers by type, summons, Stop held, Hold/Stop
-- toggles, right-click deny and the acquisition guard (a second stop on the
-- next tick unless a newer order came); Dota's failed-cast check of an
-- ability key on every client, by the build data's cell and the synced
-- selection; Dota's defaults without a file; nothing for the commander or
-- bots; and no handles in local code.
-- Failed checks are ERROR log lines, which fail the mock run.
if __mockHud and not __mockSettings then
    local M = __mockHud
    local T = {sync = {}, syncRegs = {}, tips = {}, forced = {}, cancels = 0, camera = {}, orders = {}, uses = {},
               itemCalls = {}, pans = 0, preloads = {}, abil = {}, hover = nil, immediate = {}, points = {},
               mouseRegs = {}, unitRegs = {}, fx = {}, destroyed = {}}
    __mockSettings = T

    -- What launcher\dvc_launcher\dota_settings.py writes for a player with quick
    -- cast on Q E R and the swapped D/F, W moved to 2, items on Z X C V, Alt+B
    -- and Space, TP on B, shop on F5 and hero selection on 1, the courier on
    -- F2 F3 F7 F8 and Grab All on F9 (tools/mock/inventory.lua); auto attack
    -- Standard with summons on Never, no auto attack while Stop is held,
    -- right-click allies to deny, quick cast on key press.
    T.files = {["DotaVsCommander\\dota_settings.txt"] = "function PreloadFiles takes nothing returns nothing\r\n\r\n"
        .. "\tcall PreloadStart()\r\n"
        .. '\tcall BlzSetAbilityTooltip(1095656547, "v=1;a1=81q;a2=50;a3=69q;a4=70q;a5=68q;a6=82q;i1=90q;i2=88q;'
        .. 'i3=67q;i4=86q;i5=66-4;i6=32q;tp=66;sh=116;hs=49;cs=113;cv=114;cb=118;ch=119;gs=120;'
        .. 'aa=1;as=0;ds=1;ta=0;fr=2;dt=1;di=1;to=2;qd=1;'
        .. 'zl=1;rs=0", 0)\r\n'
        .. "\tcall PreloadEnd( 0.0 )\r\n\r\nendfunction\r\n"}

    function Preloader(name)
        T.preloads[#T.preloads + 1] = {name = name, ready = use("log").ready == true}
        local text = T.files[name]
        if not text then return end
        for code, s, level in string.gmatch(text, 'call BlzSetAbilityTooltip%((%d+), "([^"]*)", (%d+)%)') do
            T.tips[tonumber(code) .. ":" .. tonumber(level)] = s
        end
    end
    function BlzSetAbilityTooltip(code, s, level) T.tips[code .. ":" .. level] = s end
    function BlzGetAbilityTooltip(code, level) return T.tips[code .. ":" .. level] or "" end

    -- sync data: every registered client gets the message a moment later
    local syncNow = nil
    function BlzTriggerRegisterPlayerSyncEvent(trig, p, prefix, fromServer)
        T.syncRegs[#T.syncRegs + 1] = {trig = trig, player = p, prefix = prefix}
        return __handle("event")
    end
    function BlzGetTriggerSyncData() return syncNow and syncNow.data end
    function BlzGetTriggerSyncPrefix() return syncNow and syncNow.prefix end
    local function deliver(msg)
        for _, r in ipairs(T.syncRegs) do
            if r.player == msg.player and r.prefix == msg.prefix then
                syncNow, M.trig = msg, {player = msg.player}
                for _, a in ipairs(r.trig.actions or {}) do a() end
            end
        end
        syncNow, M.trig = nil, {}
    end
    -- messages arrive in the order they were sent, as in the game
    local seq = 0
    function BlzSendSyncData(prefix, data)
        local msg = {player = GetLocalPlayer(), prefix = prefix, data = data}
        T.sync[#T.sync + 1] = msg
        seq = seq + 1
        __mock.timers[{active = true, timeout = 0.05, periodic = false, due = __mock.now + 0.05 + seq * 1e-7,
                       fn = function() deliver(msg) end}] = true
        return #data <= 255
    end

    -- Key events keep their meta keys and direction. As in the game, an event
    -- fires while all its meta keys are held, so a key-up registered without
    -- meta keys always arrives.
    local keyConst = {[0x73] = OSKEY_F4, [0x1B] = OSKEY_ESCAPE}
    function ConvertOsKeyType(n)
        keyConst[n] = keyConst[n] or __const(n)
        return keyConst[n]
    end
    -- dota_items' default item keys (common.j's hex constants are nil in the stubs)
    for name, vk in pairs({OSKEY_Z = 0x5A, OSKEY_X = 0x58, OSKEY_C = 0x43, OSKEY_V = 0x56, OSKEY_B = 0x42,
                           OSKEY_N = 0x4E}) do
        if _G[name] == nil then _G[name] = ConvertOsKeyType(vk) end
    end
    local prevKey = BlzTriggerRegisterPlayerKeyEvent
    function BlzTriggerRegisterPlayerKeyEvent(trig, p, key, meta, down)
        local ev = prevKey(trig, p, key, meta, down)
        local r = M.keys[#M.keys]
        r.meta, r.down = meta, down
        return ev
    end
    local now = {key = nil, meta = 0, down = false}
    function BlzGetTriggerPlayerKey() return now.key end
    function BlzGetTriggerPlayerMetaKey() return now.meta end
    function BlzGetTriggerPlayerIsKeyDown() return now.down end

    -- key handlers only do local work or synced work that creates no handles
    T.handles = 0
    local function fire(p, vk, meta, down)
        local key = ConvertOsKeyType(vk)
        local h0 = M.handles
        now.key, now.meta, now.down = key, meta, down
        for _, r in ipairs(M.keys) do
            if r.player == p and r.key == key and (r.down == true) == down and ((r.meta or 0) & ~meta) == 0 then
                M.trig = {player = p}
                for _, a in ipairs(r.trig.actions or {}) do a() end
            end
        end
        M.trig, now.key, now.meta, now.down = {}, nil, 0, false
        T.handles = T.handles + M.handles - h0
    end
    T.fire = fire
    function T.press(p, vk, meta)
        fire(p, vk, meta or 0, true)
        fire(p, vk, meta or 0, false)
    end
    -- held down with `repeats` repeated key-downs; letGo: the meta keys are let go first
    function T.hold(p, vk, meta, repeats, letGo)
        fire(p, vk, meta, true)
        for _ = 1, repeats do fire(p, vk, letGo and 0 or meta, true) end
        fire(p, vk, letGo and 0 or meta, false)
    end

    function ForceUIKey(s) T.forced[#T.forced + 1] = s end
    function ForceUICancel() T.cancels = T.cancels + 1 end
    function BlzGetMouseFocusUnit() return T.hover end

    -- Mouse events (synced in the game) with their world point and button.
    local mouseNow = {x = 0, y = 0}
    function BlzGetTriggerPlayerMouseX() return mouseNow.x end
    function BlzGetTriggerPlayerMouseY() return mouseNow.y end
    function BlzGetTriggerPlayerMouseButton() return mouseNow.button end
    local prevPlayerEvent = TriggerRegisterPlayerEvent
    function TriggerRegisterPlayerEvent(trig, p, ev)
        T.mouseRegs[#T.mouseRegs + 1] = {trig = trig, player = p, event = ev, ready = use("log").ready == true}
        return prevPlayerEvent(trig, p, ev)
    end
    function T.mouse(p, kind, x, y, button)
        local ev = ({down = EVENT_PLAYER_MOUSE_DOWN, up = EVENT_PLAYER_MOUSE_UP, move = EVENT_PLAYER_MOUSE_MOVE})[kind]
        mouseNow.x, mouseNow.y, mouseNow.button = x, y, button
        for _, r in ipairs(T.mouseRegs) do
            if r.player == p and r.event == ev then
                M.trig = {player = p}
                for _, a in ipairs(r.trig.actions or {}) do a() end
            end
        end
        M.trig = {}
    end

    -- Unit events: a unit acquiring a target on its own.
    local prevUnitEvent, prevTriggerUnit = TriggerRegisterUnitEvent, GetTriggerUnit
    function TriggerRegisterUnitEvent(trig, u, ev)
        T.unitRegs[#T.unitRegs + 1] = {trig = trig, unit = u, event = ev}
        return prevUnitEvent(trig, u, ev)
    end
    function GetTriggerUnit()
        if T.trigUnit then return T.trigUnit end
        return prevTriggerUnit()
    end
    function GetEventTargetUnit() return T.acqTarget end
    function T.acquire(u, target)
        T.trigUnit, T.acqTarget = u, target
        for _, r in ipairs(T.unitRegs) do
            if r.unit == u and r.event == EVENT_UNIT_ACQUIRED_TARGET then
                for _, a in ipairs(r.trig.actions or {}) do a() end
            end
        end
        T.trigUnit, T.acqTarget = nil, nil
    end
    function SetCameraField(field, v, d) T.camera[field] = v end
    function GetCameraField(field) return T.camera[field] or 1650 end

    -- Units are tracked when the settings arrive, long before the exercise:
    -- the worker type (the stubs keep no unit types) is modelled for the
    -- whole run.
    local prevIsType, prevAddType, prevRemoveType = IsUnitType, UnitAddType, UnitRemoveType
    function IsUnitType(u, t)
        if t == UNIT_TYPE_PEON and type(u) == "table" then return u.peon == true end
        return prevIsType(u, t)
    end
    function UnitAddType(u, t)
        if t ~= UNIT_TYPE_PEON or type(u) ~= "table" then return prevAddType(u, t) end
        u.peon = true
        return true
    end
    function UnitRemoveType(u, t)
        if t ~= UNIT_TYPE_PEON or type(u) ~= "table" then return prevRemoveType(u, t) end
        u.peon = nil
        return true
    end
    local prevIdType, ACOLYTE = IsUnitIdType, FourCC("uaco")
    function IsUnitIdType(id, t)
        if t == UNIT_TYPE_PEON then return id == ACOLYTE end
        return prevIdType(id, t)
    end

    -- Behaviour that would change the other exercises: on during ours only.
    local function install()
        local saved = {}
        local function set(name, fn)
            saved[name] = _G[name]
            _G[name] = fn
        end
        set("IsUnitSelected", function(u, p)
            if p ~= GetLocalPlayer() then return false end
            for _, s in ipairs(M.selection) do
                if s == u then return true end
            end
            return false
        end)
        set("ClearSelection", function() M.selection = {} end)
        set("SelectUnit", function(u, on) if on then M.selection[#M.selection + 1] = u end end)
        set("PanCameraToTimed", function() T.pans = T.pans + 1 end)
        set("IsUnitVisible", function(u) return not u.hidden end)
        set("IsUnitEnemy", function(u, p)
            local Roles = use("roles")
            return Roles.side(GetPlayerId(GetOwningPlayer(u))) ~= Roles.side(GetPlayerId(p))
        end)
        set("GroupEnumUnitsOfPlayer", function(g, p)
            g.units = {}
            for _, u in ipairs(__mock.units) do
                if u.owner == p and not u.dead then g.units[#g.units + 1] = u end
            end
        end)
        set("IssueImmediateOrderById", function(u, oid)
            T.immediate[#T.immediate + 1] = {u = u, oid = oid}
            return true
        end)
        set("UnitUseItemPoint", function(u, it, x, y)
            T.points[#T.points + 1] = {u = u, it = it, x = x, y = y}
            return true
        end)
        local ORDERS = {attack = 851983, move = 851986, stop = 851972, holdposition = 851993, smart = 851971}
        set("OrderId", function(s) return ORDERS[s] or (900000 + #s) end)
        set("BlzGetUnitAbility", function(u, id) return {id = id} end)
        set("BlzGetAbilityStringLevelField", function(ab) return (T.abil[ab.id] or {}).order or "" end)
        set("BlzGetAbilityIntegerLevelField", function(ab) return (T.abil[ab.id] or {}).target or 0 end)
        set("IssueTargetOrderById", function(u, oid, target)
            T.orders[#T.orders + 1] = {u = u, oid = oid, target = target}
            return true
        end)
        set("IssuePointOrderById", function(u, oid, x, y)
            T.orders[#T.orders + 1] = {u = u, oid = oid, x = x, y = y}
            return true
        end)
        -- string orders (the way the bots cast); T.refuseString: the game refuses them
        set("IssueTargetOrder", function(u, order, target)
            if T.refuseString then return false end
            T.orders[#T.orders + 1] = {u = u, oid = OrderId(order), target = target, str = true}
            return true
        end)
        set("IssuePointOrder", function(u, order, x, y)
            if T.refuseString then return false end
            T.orders[#T.orders + 1] = {u = u, oid = OrderId(order), x = x, y = y, str = true}
            return true
        end)
        set("AddSpecialEffect", function(path, x, y)
            local fx = __handle("effect")
            T.fx[#T.fx + 1] = {fx = fx, path = path, x = x, y = y}
            return fx
        end)
        set("DestroyEffect", function(fx) T.destroyed[fx] = true end)
        set("UnitUseItemTarget", function(u, it, target)
            T.uses[#T.uses + 1] = {u = u, it = it, target = target}
            return saved.UnitUseItemTarget(u, it, target)
        end)
        local Items = use("dota_items")
        local itemUse = Items.use
        function Items.use(p, slot)
            T.itemCalls[#T.itemCalls + 1] = {p = p, slot = slot}
            return itemUse(p, slot)
        end
        return function()
            for name, fn in pairs(saved) do _G[name] = fn end
            Items.use = itemUse
        end
    end

    -- entries of `list` after `from` whose `field` is `value`
    local function since(list, from, field, value)
        local out = {}
        for i = from + 1, #list do
            if list[i][field] == value then out[#out + 1] = list[i] end
        end
        return out
    end

    local function advance(seconds)
        local target = __mock.now + seconds
        while true do
            local nextT, nextDue = nil, math.huge
            for t in pairs(__mock.timers) do
                if t.active and t.due <= target and t.due < nextDue then nextT, nextDue = t, t.due end
            end
            if not nextT then break end
            __mock.now = nextDue
            if nextT.periodic then nextT.due = nextT.due + math.max(nextT.timeout, 0.001) else nextT.active = false end
            if nextT.fn then nextT.fn() end
        end
        __mock.now = target
    end

    local function exercise()
        local Log = use("log")
        local failures, checks = 0, 0
        local function check(name, ok, detail)
            checks = checks + 1
            if not ok then
                failures = failures + 1
                Log.error("dota_settings exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
            end
        end
        local S, H, Roles, Shop, Items = use("dota_settings"), use("heroes"), use("roles"), use("dota_shop"),
            use("dota_items")
        local Events, ids = use("events"), use("data.ids")
        local p0 = Player(0)
        local hero = H.bySlot[0]
        check("hero of player 0", hero ~= nil)
        if not hero then return end
        if S.started then
            Log.info("dota_settings exercise: started by game.lua")
        else
            S.init()
        end
        advance(0.2)

        -- the file: read after loading, stash restored, settings sent once
        check("settings file read", #T.preloads == 1 and T.preloads[1].name == "DotaVsCommander\\dota_settings.txt",
            #T.preloads)
        check("file read only after loading", T.preloads[1] == nil or T.preloads[1].ready)
        check("tooltip stash restored", BlzGetAbilityTooltip(FourCC("ANdc"), 0) == "")
        local mine = S.mine()
        check("own settings parsed", mine and mine.zl and mine.dt and mine.to == 2 and mine.cd == 1134, mine and mine.to)
        local sent = 0
        for _, m in ipairs(T.sync) do
            if m.prefix == "dvcset" then
                sent = sent + 1
                check("settings fit one sync message", #m.data <= 255, #m.data)
            end
        end
        check("settings sent once", sent == 1, sent)
        check("keys applied for player 0", S.applied(0) ~= nil)
        check("dota_items' default keys skip player 0", Items.custom[p0] == true)

        -- every key has a key-down with its meta keys and a plain key-up
        local function reg(p, vk, meta, down)
            local key = ConvertOsKeyType(vk)
            for _, r in ipairs(M.keys) do
                if r.player == p and r.key == key and (r.meta or 0) == meta and r.down == down then return r end
            end
            return nil
        end
        for _, k in ipairs({{81, 0}, {50, 0}, {69, 0}, {82, 0}, {90, 0}, {88, 0}, {67, 0}, {86, 0}, {66, 4}, {32, 0},
                           {66, 0}, {116, 0}, {49, 0}}) do
            check("key " .. k[1] .. "-" .. k[2] .. " registered", reg(p0, k[1], k[2], true) ~= nil
                and reg(p0, k[1], 0, false) ~= nil)
        end
        check("D and F stay Warcraft's (swap skipped)", reg(p0, 68, 0, false) == nil and reg(p0, 70, 0, false) == nil)

        -- camera: Dota's distance, zoom locked
        check("camera distance", T.camera[CAMERA_FIELD_TARGET_DISTANCE] == 1134, T.camera[CAMERA_FIELD_TARGET_DISTANCE])
        T.camera[CAMERA_FIELD_TARGET_DISTANCE] = 1800
        advance(0.3)
        check("zoom locked", T.camera[CAMERA_FIELD_TARGET_DISTANCE] == 1134, T.camera[CAMERA_FIELD_TARGET_DISTANCE])

        M.selection = {hero}
        T.hover = nil
        local function emptyInventory()
            for i = 0, 5 do
                local it = UnitItemInSlot(hero, i)
                if it then RemoveItem(it) end
            end
            Items.pending[p0] = nil
        end
        local function slotOf(it)
            for i = 0, 5 do
                if UnitItemInSlot(hero, i) == it then return i end
            end
            return nil
        end
        local function itemUses(from, p)
            local out = {}
            for _, c in ipairs(since(T.itemCalls, from, "p", p)) do out[#out + 1] = c.slot end
            return out
        end

        -- items: one use per press through dota_items; Alt+B and B apart; a held key acts once
        emptyInventory()
        for _ = 1, 6 do UnitAddItemById(hero, FourCC(ids.items.item_magic_wand)) end
        local c = #T.itemCalls
        T.press(p0, 90)
        local got = itemUses(c, p0)
        check("Z uses slot 1 once", #got == 1 and got[1] == 0, #got)
        advance(3)
        c = #T.itemCalls
        T.press(p0, 66, 4)
        got = itemUses(c, p0)
        check("Alt+B uses slot 5 only", #got == 1 and got[1] == 4, #got)
        advance(3)
        c = #T.itemCalls
        T.hold(p0, 66, 4, 3, true)
        got = itemUses(c, p0)
        check("a held Alt+B acts once, Alt let go first", #got == 1 and got[1] == 4, #got)
        -- the hero's free first scroll (inventory.lua) leaves the TP slot
        local Inv = use("inventory")
        local first = Inv.take(p0, "tp", 0)
        if first then use("items").remove(nil, first) end
        advance(3)
        c = #T.itemCalls
        T.press(p0, 66)
        check("B without a TP scroll does nothing", #itemUses(c, p0) == 0 and Items.pending[p0] == nil)
        local tp = use("items").make("item_tpscroll", 0)
        check("a scroll fills the TP slot", Inv.put(p0, tp, "tp", 0))
        advance(3)
        c = #T.itemCalls
        T.press(p0, 66)
        check("B waits for the TP slot's target", #itemUses(c, p0) == 0
            and Items.pending[p0] ~= nil and Items.pending[p0].tp == true)
        Items.pending[p0] = nil
        local orders = #T.orders
        local saveTp = Inv.teleport
        local tpTo = nil
        Inv.teleport = function(p, x, y) tpTo = {x = x, y = y} return true end
        advance(3)
        T.press(p0, 66)
        T.press(p0, 66)
        check("double B near the fountain just waits for a target", tpTo == nil and Items.pending[p0] ~= nil)
        Items.pending[p0] = nil
        local f = use("data.mapdata").dota.fountain
        local hx0, hy0 = GetUnitX(hero), GetUnitY(hero)
        SetUnitPosition(hero, f.x + 2000, f.y + 2000)
        advance(3)
        T.press(p0, 66)
        T.press(p0, 66)
        check("double B from afar teleports to the fountain", tpTo ~= nil and tpTo.x == f.x and tpTo.y == f.y
            and Items.pending[p0] == nil)
        SetUnitPosition(hero, hx0, hy0)
        Inv.teleport = saveTp
        RemoveItem(tp)
        Items.pending[p0] = nil
        check("no hero orders from the TP key", #since(T.orders, orders, "u", hero) == 0)
        local p3 = Player(3)
        c = #T.itemCalls
        T.press(p3, 90)
        got = itemUses(c, p3)
        check("a player without own keys keeps dota_items' Z", #got == 1 and got[1] == 0, #got)
        advance(3)

        -- shop on F5, hero selection on 1 (double tap centres the camera)
        local open = Shop.isOpen()
        T.press(p0, 116)
        check("F5 toggles the shop", Shop.isOpen() ~= open)
        T.press(p0, 116)
        check("F5 toggles the shop back", Shop.isOpen() == open)
        M.selection = {}
        local pans = T.pans
        T.press(p0, 49)
        check("1 selects the hero", #M.selection == 1 and M.selection[1] == hero)
        T.press(p0, 49)
        check("double 1 centres the camera", T.pans == pans + 1, T.pans - pans)
        M.selection = {hero}
        advance(3)

        -- W moved to 2: the native W hotkey is pressed
        local n = #T.forced
        T.press(p0, 50)
        check("2 presses Warcraft's W", #T.forced == n + 1 and T.forced[#T.forced] == "W", T.forced[#T.forced])
        T.press(p0, 81)
        check("Q is Warcraft's own key, not pressed again", #T.forced == n + 1)
        advance(3)

        -- quick cast at the hovered unit, double-tap self cast (Pudge: hook on Q, Dismember on R)
        local enemy = CreateUnit(Player(SLOT_HORDE), FourCC("hfoo"), GetUnitX(hero) + 200, GetUnitY(hero), 0)
        local function abilityId(name) return ids.abilities[name] and FourCC(ids.abilities[name]) end
        local hook, dismember = abilityId("pudge_meat_hook"), abilityId("pudge_dismember")
        if ids.heroes.pudge and hook and dismember then
            local pudge = CreateUnit(p0, FourCC(ids.heroes.pudge), GetUnitX(hero), GetUnitY(hero), 0)
            H.keyOf[pudge], H.bySlot[0] = "pudge", pudge
            pudge.abilities[hook], pudge.abilities[dismember] = 1, 1
            -- the Channel fields read at run time come back empty, as in game:
            -- casts go by the build data
            T.abil[hook], T.abil[dismember] = {}, {}
            local targetsOf = ids.ability_targets or {}
            check("build data: the hook's order and point target", ids.orders.pudge_meat_hook ~= nil
                and targetsOf.pudge_meat_hook == 2, tostring(targetsOf.pudge_meat_hook))
            check("build data: Dismember's unit target", targetsOf.pudge_dismember == 1,
                tostring(targetsOf.pudge_dismember))
            local HOOK_ID, DISMEMBER_ID = OrderId(ids.orders.pudge_meat_hook), OrderId(ids.orders.pudge_dismember)
            M.selection = {pudge}
            local orders, cancels = #T.orders, T.cancels
            local cx, cy = GetUnitX(pudge) + 640, GetUnitY(pudge) - 320
            T.press(p0, 81)
            advance(0.2)
            check("no quick cast before the cursor is known", #since(T.orders, orders, "u", pudge) == 0
                and T.cancels == cancels)
            T.hover = enemy
            T.mouse(p0, "move", cx, cy)
            T.mouse(p0, "move", 0, 0)          -- over an opaque UI frame: ignored
            check("cursor from the synced mouse events", S.cursor(0).x == cx and S.cursor(0).y == cy)
            advance(3)
            T.press(p0, 81)
            advance(0.2)
            got = since(T.orders, orders, "u", pudge)
            local o = got[1] or {}
            check("quick cast Q (point) at the cursor, not at the hovered unit", #got == 1
                and o.oid == HOOK_ID and o.str and o.x == cx and o.y == cy, #got)
            check("quick cast closes the targeting cursor", T.cancels == cancels + 1, T.cancels - cancels)
            T.press(p0, 82)
            advance(0.2)
            got = since(T.orders, orders, "u", pudge)
            o = got[2] or {}
            check("quick cast R (unit) at the hovered unit", #got == 2 and o.target == enemy
                and o.oid == DISMEMBER_ID and o.str, #got)
            advance(3)
            T.hover = nil
            T.press(p0, 82)
            check("a unit quick cast with nothing hovered keeps the targeting cursor",
                #since(T.orders, orders, "u", pudge) == 2 and T.cancels == cancels + 2, T.cancels - cancels)
            T.press(p0, 82)
            advance(0.2)
            got = since(T.orders, orders, "u", pudge)
            o = got[3] or {}
            check("double R casts Dismember on Pudge", #got == 3 and o.target == pudge
                and o.oid == DISMEMBER_ID, #got)
            T.press(p0, 82)
            advance(0.2)
            check("a third R is a new first tap", #since(T.orders, orders, "u", pudge) == 3)
            advance(3)
            -- quick cast on the key release (dota_quickcast_onkeydown off)
            S.mine().qd = false
            cancels = T.cancels
            T.fire(p0, 81, 0, true)
            advance(0.2)
            check("release mode: the press only aims", #since(T.orders, orders, "u", pudge) == 3
                and T.cancels == cancels)
            T.mouse(p0, "move", cx - 100, cy + 50)
            T.fire(p0, 81, 0, false)
            advance(0.2)
            got = since(T.orders, orders, "u", pudge)
            o = got[4] or {}
            check("release mode: quick cast at the cursor on the release", #got == 4 and o.x == cx - 100
                and o.y == cy + 50 and T.cancels == cancels + 1, #got)
            S.mine().qd = true
            advance(3)
            -- fallbacks: the order id when the string order is refused; the
            -- run-time fields when the build data has no entry
            T.refuseString = true
            T.press(p0, 81)
            advance(0.2)
            T.refuseString = nil
            got = since(T.orders, orders, "u", pudge)
            o = got[5] or {}
            check("a refused string order falls back to the order id", #got == 5 and not o.str
                and o.oid == HOOK_ID and o.x == cx - 100, #got)
            advance(3)
            local buildOrder, buildKind = ids.orders.pudge_meat_hook, targetsOf.pudge_meat_hook
            ids.orders.pudge_meat_hook, targetsOf.pudge_meat_hook = nil, nil
            T.abil[hook] = {order = "hookorder", target = 2}
            T.press(p0, 81)
            advance(0.2)
            ids.orders.pudge_meat_hook, targetsOf.pudge_meat_hook = buildOrder, buildKind
            got = since(T.orders, orders, "u", pudge)
            o = got[6] or {}
            check("without build data the run-time fields cast", #got == 6 and o.oid == OrderId("hookorder"), #got)
            advance(3)
            -- an ability key asks gamesounds for Dota's failed-cast sounds, in
            -- synced code: the ability in the key's cell by the build data, the
            -- hero selected as last synced, on every client alike
            local cells = ids.ability_cells or {}
            check("build data: the hook's and Dismember's cells", cells.pudge_meat_hook == 8
                and cells.pudge_dismember == 11, tostring(cells.pudge_meat_hook) .. "/" .. tostring(cells.pudge_dismember))
            local GS = use("gamesounds")
            local realCheck, asked = GS.checkCast, {}
            GS.checkCast = function(h, id) asked[#asked + 1] = {h = h, id = id} return true end
            M.selection = {pudge}
            advance(0.2)
            T.press(p0, 82)
            check("R asks for Dismember's failed-cast sounds", #asked == 1 and asked[1].h == pudge
                and asked[1].id == dismember, #asked)
            advance(3)
            local presser = GetLocalPlayer
            GetLocalPlayer = function() return Player(1) end
            local forced0 = #T.forced
            T.press(p0, 81)
            GetLocalPlayer = presser
            check("another client asks too, without the presser's local part", #asked == 2 and asked[2].id == hook
                and #T.forced == forced0, #asked)
            advance(3)
            M.selection = {}
            advance(0.2)
            T.press(p0, 82)
            check("no failed-cast check while the hero is not selected", #asked == 2, #asked)
            GS.checkCast = realCheck
            M.selection = {pudge}
            advance(3)
            H.keyOf[pudge], H.bySlot[0] = nil, hero
            RemoveUnit(pudge)
            M.selection = {hero}
        else
            Log.warn("dota_settings exercise: Pudge not in this build, ability casts not checked")
        end

        -- items: quick cast hands the hovered unit to the waiting item; double tap on yourself
        emptyInventory()
        local staff = UnitAddItemById(hero, FourCC(ids.items.item_force_staff))
        local key = ({90, 88, 67, 86})[(slotOf(staff) or 9) + 1]
        check("force staff on a quick-cast key", key ~= nil and (ids.item_targets or {}).item_force_staff == "unit")
        if key then
            local uses = #T.uses
            T.hover = enemy
            T.press(p0, key)
            advance(0.2)
            got = since(T.uses, uses, "u", hero)
            check("quick cast item at the hovered unit", #got == 1 and got[1].it == staff and got[1].target == enemy
                and Items.pending[p0] == nil, #got)
            advance(3)
            enemy.hidden = true
            T.press(p0, key)
            advance(0.2)
            check("no quick cast at a unit the player cannot see", #since(T.uses, uses, "u", hero) == 1
                and Items.pending[p0] ~= nil)
            enemy.hidden = nil
            Items.pending[p0] = nil
            advance(3)
            T.hover = nil
            T.press(p0, key)
            T.press(p0, key)
            advance(0.2)
            got = since(T.uses, uses, "u", hero)
            check("double tap uses the item on the hero", #got == 2 and got[2].target == hero
                and Items.pending[p0] == nil, #got)
            advance(3)
        end
        emptyInventory()
        -- a point item on a quick-cast key fires at the cursor
        local blink = ids.items.item_blink and UnitAddItemById(hero, FourCC(ids.items.item_blink))
        key = blink and ({90, 88, 67, 86})[(slotOf(blink) or 9) + 1]
        if key then
            local pts = #T.points
            T.mouse(p0, "move", 1234, -567)
            T.press(p0, key)
            got = since(T.points, pts, "u", hero)
            check("quick cast point item at the cursor", #got == 1 and got[1].it == blink and got[1].x == 1234
                and got[1].y == -567 and Items.pending[p0] == nil, #got)
            advance(3)
        end
        emptyInventory()

        -- mouse events: registered after the start, for the hero players only
        local mouseRegs, early = 0, 0
        for _, r in ipairs(T.mouseRegs) do
            if r.event == EVENT_PLAYER_MOUSE_MOVE then
                mouseRegs = mouseRegs + 1
                if not r.ready or r.player ~= p0 then early = early + 1 end
            end
        end
        check("mouse move registered once, after the start, for player 0 only", mouseRegs == 1 and early == 0,
            mouseRegs .. "/" .. early)

        -- right-click hold: moves toward the cursor once it moves, throttled
        local MOVE_ID = OrderId("move")
        local function moves(from, u)
            local out = {}
            for _, o in ipairs(since(T.orders, from, "u", u)) do
                if o.oid == MOVE_ID then out[#out + 1] = o end
            end
            return out
        end
        M.selection = {hero}
        advance(0.3)
        local hx, hy = GetUnitX(hero), GetUnitY(hero)
        local before = #T.orders
        local CONFIRM = "UI\\Feedback\\Confirmation\\Confirmation.mdl"
        local function markers(from, x, y)
            local out = {}
            for i = from + 1, #T.fx do
                local f = T.fx[i]
                if f.x == x and f.y == y and (f.path == CONFIRM or f.path == "") then out[#out + 1] = f end
            end
            return out
        end
        local fx0 = #T.fx
        T.mouse(p0, "move", hx + 300, hy)
        T.mouse(p0, "down", hx + 300, hy, MOUSE_BUTTON_TYPE_RIGHT)
        check("right button starts the hold", S.holding(0))
        advance(0.3)
        check("no repeat while the cursor stays", #moves(before, hero) == 0, #moves(before, hero))
        T.mouse(p0, "move", hx + 500, hy + 100)
        advance(0.06)
        got = moves(before, hero)
        check("hold moves the hero to the cursor", #got == 1 and got[1].x == hx + 500 and got[1].y == hy + 100, #got)
        local marks = markers(fx0, hx + 500, hy + 100)
        check("the held move shows the move marker to the holder", #marks == 1 and marks[1].path == CONFIRM, #marks)
        check("the marker stays a moment", marks[1] ~= nil and not T.destroyed[marks[1].fx])
        advance(0.7)
        check("the marker goes away", marks[1] ~= nil and T.destroyed[marks[1].fx] == true)
        -- another client creates and frees the same effect, with no model
        local seenBy = GetLocalPlayer
        GetLocalPlayer = function() return Player(1) end
        fx0 = #T.fx
        T.mouse(p0, "move", hx + 520, hy + 140)
        advance(0.06)
        GetLocalPlayer = seenBy
        marks = markers(fx0, hx + 520, hy + 140)
        check("other clients make the marker with no model", #marks == 1 and marks[1].path == "", #marks)
        advance(0.7)
        check("other clients free it too", marks[1] ~= nil and T.destroyed[marks[1].fx] == true)
        before = #T.orders
        T.mouse(p0, "move", hx + 500, hy + 100)
        advance(0.06)
        check("hold moves again after the pause", #moves(before, hero) == 1, #moves(before, hero))
        T.mouse(p0, "move", hx + 600, hy + 100)
        advance(0.06)
        check("hold is throttled", #moves(before, hero) == 1, #moves(before, hero))
        advance(0.2)
        check("hold repeats after the throttle", #moves(before, hero) == 2, #moves(before, hero))
        local n0 = #moves(before, hero)
        for i = 1, 20 do
            T.mouse(p0, "move", hx + 600 + i * 40, hy)
            advance(0.05)
        end
        local n = #moves(before, hero) - n0
        check("hold never floods orders (1 s of dragging)", n >= 4 and n <= 7, n)
        -- the player's own selection (synced) gets the moves
        local summon = CreateUnit(p0, FourCC("hfoo"), hx, hy - 200, 0)
        Events.emit("unit_enter", summon)
        M.selection = {hero, summon}
        advance(0.3)
        before = #T.orders
        T.mouse(p0, "move", hx - 400, hy)
        advance(0.2)
        check("hold moves the selected own units", #moves(before, hero) == 1 and #moves(before, summon) == 1,
            #moves(before, summon))
        Events.emit("order", hero, MOVE_ID, nil, hx, hy)
        check("a move order keeps the hold", S.holding(0))
        Events.emit("order", hero, 852100, nil, nil, nil)
        check("another order ends the hold", not S.holding(0))
        T.mouse(p0, "move", hx - 600, hy)
        advance(0.3)
        check("no moves after the hold ended", #moves(before, hero) == 1)
        -- release and death
        T.mouse(p0, "down", hx, hy, MOUSE_BUTTON_TYPE_RIGHT)
        T.mouse(p0, "up", hx, hy, MOUSE_BUTTON_TYPE_LEFT)
        check("a left release keeps the hold", S.holding(0))
        T.mouse(p0, "up", hx, hy, MOUSE_BUTTON_TYPE_RIGHT)
        check("right release ends the hold", not S.holding(0))
        M.selection = {hero}
        advance(0.3)
        T.mouse(p0, "down", hx, hy, MOUSE_BUTTON_TYPE_RIGHT)
        hero.dead = true
        T.mouse(p0, "move", hx + 200, hy)
        advance(0.3)
        check("the hold ends when the hero dies", not S.holding(0))
        hero.dead = false
        T.mouse(p0, "up", hx, hy, MOUSE_BUTTON_TYPE_RIGHT)

        -- auto attack: a unit that may not pick targets on its own is a worker.
        -- Standard idles after a move, attacks again on an attack order.
        Events.emit("order", hero, OrderId("move"), nil, 0, 0)
        check("standard: no auto attack after a move (a worker)", hero.peon == true)
        Events.emit("order", hero, OrderId("attack"), nil, 0, 0)
        check("standard: attack-move attacks (no worker)", hero.peon == nil)
        local STOP_ID, HOLD_ID, SMART_ID, ATTACK_ID = OrderId("stop"), OrderId("holdposition"), OrderId("smart"),
            OrderId("attack")
        -- want: true when the unit may pick targets on its own
        local function acq(label, u, order, target, want)
            Events.emit("order", u, order, target, nil, nil)
            check(label, (u.peon == nil) == want, tostring(u.peon))
        end
        acq("standard: stop idles", hero, STOP_ID, nil, false)
        hero.peon = nil                                 -- the type lost some other way
        advance(0.6)
        check("the worker type is set again within half a second", hero.peon == true)
        acq("standard: a spell attacks again", hero, 852100, nil, true)
        acq("standard: hold idles", hero, HOLD_ID, nil, false)
        acq("standard: right-click on an enemy attacks", hero, SMART_ID, enemy, true)
        acq("standard: right-click on the ground idles", hero, SMART_ID, nil, false)
        local ally = CreateUnit(Player(SLOT_ANCIENTS), FourCC("hfoo"), hx + 100, hy, 0)
        acq("standard: a deny idles", hero, ATTACK_ID, ally, false)
        -- summons on Never
        check("summon on Never: no auto attack", summon.peon == true)
        acq("summon on Never: attack-move attacks", summon, ATTACK_ID, nil, true)
        acq("summon on Never: an attack picks no new target", summon, ATTACK_ID, enemy, false)
        -- Stop held: no auto attack until released
        acq("standard: attack again", hero, ATTACK_ID, enemy, true)
        T.fire(p0, 83, 0, true)
        check("stop held: no auto attack", hero.peon == true)
        T.fire(p0, 83, 0, true)
        T.fire(p0, 83, 0, false)
        check("stop released: auto attack back", hero.peon == nil)
        -- a worker by its own type (a persuaded acolyte) keeps it
        local acolyte = CreateUnit(p0, FourCC("uaco"), hx, hy + 200, 0)
        acolyte.peon = true
        Events.emit("unit_enter", acolyte)
        Events.emit("order", acolyte, ATTACK_ID, nil, 0, 0)
        advance(0.6)
        check("a worker by type stays one when it may attack", acolyte.peon == true)
        RemoveUnit(acolyte)
        -- an illusion made while the hero is a worker may copy the added type
        local copy = CreateUnit(p0, GetUnitTypeId(hero), hx, hy - 100, 0)
        copy.peon = true
        Events.emit("unit_enter", copy)
        Events.emit("order", copy, ATTACK_ID, nil, 0, 0)
        check("an illusion with a copied worker type loses it on attack-move", copy.peon == nil)
        RemoveUnit(copy)
        -- right-click allies "To Deny": deniable units are attacked, others followed
        before = #T.orders
        ally.life, ally.maxLife = 40, 100
        Events.emit("order", hero, SMART_ID, ally, nil, nil)
        advance(0.05)
        got = since(T.orders, before, "u", hero)
        check("right-click a deniable ally attacks it", #got == 1 and got[1].oid == ATTACK_ID and got[1].target == ally,
            #got)
        ally.life = 90
        Events.emit("order", hero, SMART_ID, ally, nil, nil)
        advance(0.05)
        check("right-click a healthy ally follows it", #since(T.orders, before, "u", hero) == 1)
        -- the acquisition guard stops a new target the unit may not take, at
        -- once and again on the next tick (the engine's own attack follows the event)
        local stops = #T.immediate
        local function lastStop(u)
            local s = T.immediate[#T.immediate]
            return s ~= nil and s.u == u and s.oid == STOP_ID
        end
        acq("standard: move", hero, OrderId("move"), nil, false)
        T.acquire(hero, enemy)
        check("guard stops a new target after a move", #T.immediate == stops + 1 and lastStop(hero),
            #T.immediate - stops)
        advance(0.05)
        check("guard stops it again on the next tick", #T.immediate == stops + 2 and lastStop(hero),
            #T.immediate - stops)
        check("guard's stops keep the idle state", hero.peon == true)
        T.acquire(hero, enemy)
        acq("standard: a new move before the tick", hero, OrderId("move"), nil, false)
        advance(0.05)
        check("a newer order cancels the second stop", #T.immediate == stops + 3, #T.immediate - stops)
        acq("standard: attack", hero, ATTACK_ID, enemy, true)
        T.acquire(hero, ally)
        advance(0.05)
        check("guard leaves an attacking unit alone", #T.immediate == stops + 3, #T.immediate - stops)
        acq("summon: explicit attack", summon, ATTACK_ID, enemy, false)
        T.acquire(summon, enemy)
        advance(0.05)
        check("guard leaves the explicit target alone", #T.immediate == stops + 3, #T.immediate - stops)
        T.acquire(summon, ally)
        check("guard stops a summon on Never", #T.immediate == stops + 4 and lastStop(summon), #T.immediate - stops)
        advance(0.05)
        check("guard stops the summon again on the next tick", #T.immediate == stops + 5 and lastStop(summon),
            #T.immediate - stops)
        RemoveUnit(summon)
        RemoveUnit(ally)
        RemoveUnit(enemy)

        -- other players: Dota's defaults without a file, Never, commander and bots
        local saved1, saved2 = Roles.humans[1], Roles.humans[2]
        Roles.humans[1], Roles.humans[2] = true, true
        local before = #M.keys
        S.apply(1, "v=1;ta=1")
        local list = S.applied(1) or {}
        local byField = {}
        for _, b in ipairs(list) do byField[b.field] = b end
        check("defaults: Z X C V B N", byField.i1 and byField.i1.vk == 90 and byField.i6 and byField.i6.vk == 78)
        check("defaults: Q W E D F R on Warcraft's keys", byField.a4 and byField.a4.native and byField.a6.native)
        check("defaults: F4 and F1 stay with the shop and Warcraft", byField.sh == nil and byField.hs == nil)
        check("defaults: dota_items' keys skip player 1", Items.custom[Player(1)] == true)
        local p1Keys = 0
        for i = before + 1, #M.keys do
            if M.keys[i].player == Player(1) then p1Keys = p1Keys + 1 end
        end
        check("defaults registered for player 1", p1Keys == 2 * #list and p1Keys > 0, p1Keys)
        -- Hold/Stop toggles (ta) on Standard: Stop forces Always, Hold forces Never, attacks clear it
        local h1 = H.bySlot[1]
        if h1 then
            local function acq1(label, order, target, want)
                Events.emit("order", h1, order, target, nil, nil)
                check(label, (h1.peon == nil) == want, tostring(h1.peon))
            end
            local foe = CreateUnit(Player(SLOT_HORDE), FourCC("hfoo"), GetUnitX(h1) + 300, GetUnitY(h1), 0)
            acq1("toggle: Stop forces Always", OrderId("stop"), nil, true)
            acq1("toggle: Always after a move", OrderId("move"), nil, true)
            acq1("toggle: Hold forces Never", OrderId("holdposition"), nil, false)
            acq1("toggle: Never after a spell", 852100, nil, false)
            acq1("toggle: an attack clears it", OrderId("attack"), foe, true)
            acq1("toggle: Standard again after a move", OrderId("move"), nil, false)
            RemoveUnit(foe)
        end
        local other = H.bySlot[2]
        S.apply(2, "v=1;aa=0")
        if other then
            check("never: no auto attack", other.peon == true)
            Events.emit("order", other, OrderId("attack"), nil, 0, 0)
            check("never: attack-move attacks", other.peon == nil)
            Events.emit("order", other, OrderId("smart"), nil, 0, 0)
            check("never: idle again after a move", other.peon == true)
        end
        Roles.humans[1], Roles.humans[2] = saved1, saved2
        S.apply(SLOT_COMMANDER_AI, "")
        check("no keys for the commander", S.applied(SLOT_COMMANDER_AI) == nil)
        S.apply(3, "")
        check("no keys for a bot", S.applied(3) == nil and not Items.custom[Player(3)])

        -- format edge cases
        check("binding with quick", select(3, S.binding("81q")) == true and S.binding("81q") == 81)
        check("binding with alt", select(2, S.binding("66-4")) == 4)
        check("bad bindings refused", not S.binding("") and not S.binding("27") and not S.binding("999")
            and not S.binding("81-99") and not S.binding("x"))
        local l2, skipped = S.bindings(S.parse("v=1;a4=70;a5=68;i1=65;i2=90;i3=90;sh=115;hs=112"))
        check("clashes skipped", #l2 == 1 and l2[1].field == "i2" and #skipped == 4, #l2 .. "/" .. #skipped)
        check("no handles in key handlers", T.handles == 0, T.handles)
        Log.info("dota_settings exercise: " .. checks .. " checks, " .. failures .. " failed")
    end

    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("dota_settings") then return end
        done = true
        local restore = install()
        use("safe").call(exercise)
        restore()
        use("log").flush()
    end
end
