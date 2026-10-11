-- Offline exercise for the Dota HUD and shop (src/ui/dota_hud.lua,
-- dota_shop.lua, hud_kit.lua). Adds a stateful model of the Reforged 2.0
-- frame API (default UI tree, points, visibility, parents, tooltips, frame and
-- key events) to the mock, then, after the normal mock run, spawns the heroes,
-- starts the HUD for Player(0) (unless game.lua already did) and checks: the
-- WC3 frames it keeps stay visible, the console art is hidden, the ability
-- row / 4 x 3 grid layouts, Dota's empty slots on the spare cells, learning
-- through the gold "+" buttons (Dota level rules), cooldown seconds, death
-- and respawn timers, the shop (open by button and keys, hover details with
-- recipe parts, buying by click with and without carried parts, refusals for
-- gold, range, a dead hero and a full inventory, stock, selling, another
-- player's clicks), the menu bar and layout bounds at 4:3, 16:9 and 21:9,
-- fallback textures on every button, and that no local code creates handles.
-- Failed checks are ERROR log lines, which fail the mock run.
if not __mockHud then
    local M = {handles = 0, regs = {}, keys = {}, selection = {}, hover = nil, pos = {}, created = {},
               trig = {}, width = 1920, height = 1080, observer = {}}
    __mockHud = M

    -- common.j defines these as ConvertOsKeyType($73) and ($1B); the stub
    -- generator skips hex arguments, so they would be nil (and equal)
    if OSKEY_F4 == nil then OSKEY_F4 = __const(0x73) end
    if OSKEY_ESCAPE == nil then OSKEY_ESCAPE = __const(0x1B) end

    -- every handle the mock hands out is counted (local code must create none)
    local rawHandle = __handle
    function __handle(t)
        M.handles = M.handles + 1
        return rawHandle(t)
    end

    local nextId = 1000
    function GetHandleId(h)
        if type(h) ~= "table" then return 0 end
        local id = rawget(h, "__hid")
        if not id then
            nextId = nextId + 1
            id = nextId
            rawset(h, "__hid", id)
        end
        return id
    end

    function GetLocalPlayer() return Player(0) end
    function BlzGetLocalClientWidth() return M.width end
    function BlzGetLocalClientHeight() return M.height end
    function IsPlayerObserver(p) return M.observer[GetPlayerId(p)] == true end

    local prevTriggerPlayer = GetTriggerPlayer
    function GetTriggerPlayer()
        if M.trig.player then return M.trig.player end
        return prevTriggerPlayer()
    end
    function BlzGetTriggerFrame() return M.trig.frame end
    function BlzGetTriggerFrameEvent() return M.trig.event end

    ---------------------------------------------------------------- frames

    local SIMPLE = {SIMPLEFRAME = true, SIMPLEBUTTON = true, SIMPLESTATUSBAR = true, SIMPLECHECKBOX = true,
                    SIMPLETOP = true, SIMPLEGRID = true, TEXTURE = true, STRING = true}
    local TYPES = {FRAME = true, BUTTON = true, GLUEBUTTON = true, TEXT = true, BACKDROP = true, SIMPLEFRAME = true,
                   SIMPLESTATUSBAR = true, SIMPLEBUTTON = true, HIGHLIGHT = true, SPRITE = true, STATUSBAR = true}
    local byName = {}

    local function fail(msg) error("frame mock: " .. msg, 3) end

    local function isFrame(f) return type(f) == "table" and rawget(f, "isFrame") == true end

    local function newFrame(kind, name, parent)
        local f = __handle("framehandle")
        rawset(f, "isFrame", true)
        f.kind, f.name, f.children, f.visible, f.points, f.enabled = kind, name, {}, true, {}, true
        f.simple = SIMPLE[kind] == true
        f.alpha, f.scale, f.level, f.text, f.value = 255, 1, 0, "", 0
        if parent then
            f.parent = parent
            parent.children[#parent.children + 1] = f
        end
        if name and name ~= "" then byName[name] = f end
        return f
    end
    M.newFrame = newFrame

    local function detach(f)
        local p = f.parent
        if not p then return end
        for i, c in ipairs(p.children) do
            if c == f then table.remove(p.children, i) break end
        end
        f.parent = nil
    end

    local function noTexString(f, what)
        if not isFrame(f) then fail(what .. " on a non-frame") end
        if f.kind == "TEXTURE" or f.kind == "STRING" then fail(what .. " on a " .. f.kind .. " child (crashes the game)") end
    end

    local function num(v, what)
        if type(v) ~= "number" or v ~= v or v == math.huge or v == -math.huge then
            fail(what .. " is not a finite number: " .. tostring(v))
        end
    end

    -- Reforged 2.0 default UI (the parts the HUD touches)
    local D = {}
    M.D = D
    local function build()
        D.gameUI = newFrame("FRAME", "", nil)
        D.world = newFrame("FRAME", "", D.gameUI)                 -- GAME_UI child 0
        newFrame("FRAME", "", D.gameUI)                           -- 1
        D.backdrop = newFrame("BACKDROP", "ConsoleUIBackdrop", D.gameUI)   -- 2
        newFrame("FRAME", "", D.gameUI)                           -- 3
        newFrame("FRAME", "", D.gameUI)                           -- 4
        D.mapGroup = newFrame("FRAME", "", D.gameUI)              -- 5: clock and minimap
        D.clock = newFrame("FRAME", "", D.mapGroup)
        D.minimap = newFrame("FRAME", "MiniMapFrame", D.mapGroup)
        D.portrait = newFrame("FRAME", "", D.gameUI)

        D.consoleUI = newFrame("SIMPLEFRAME", "ConsoleUI", nil)
        D.topBar = newFrame("SIMPLEFRAME", "ConsoleTopBar", D.consoleUI)        -- 0
        D.bottomBar = newFrame("SIMPLEFRAME", "ConsoleBottomBar", D.consoleUI)  -- 1
        D.resource = newFrame("SIMPLEFRAME", "ResourceBarFrame", D.consoleUI)   -- 2
        D.upper = newFrame("SIMPLEFRAME", "UpperButtonBarFrame", D.consoleUI)   -- 3
        D.upper.w, D.upper.h = 0.2, 0.022
        D.mmBar = newFrame("SIMPLEFRAME", "MinimapButtonBar", D.consoleUI)      -- 4
        D.deadzone = newFrame("SIMPLEFRAME", "", D.consoleUI)                   -- 5
        D.heroBar = newFrame("SIMPLEFRAME", "", D.consoleUI)                    -- 6
        D.mm = {}
        for i = 0, 4 do D.mm[i] = newFrame("SIMPLEBUTTON", "", D.mmBar) end
        for i = 1, 6 do newFrame("TEXTURE", string.format("ConsoleTexture%02d", i), i <= 3 and D.topBar or D.bottomBar) end
        D.overlay = newFrame("SIMPLEFRAME", "ConsoleBottomBarOverlay", D.bottomBar)
        D.cmdBar = newFrame("SIMPLEFRAME", "CommandBarFrame", D.bottomBar)
        D.cmd = {}
        for i = 0, 11 do D.cmd[i] = newFrame("SIMPLEFRAME", "CommandButton_" .. i, D.cmdBar) end
        D.container = newFrame("SIMPLEFRAME", "", D.bottomBar)
        D.info = newFrame("SIMPLEFRAME", "SimpleInfoPanelUnitDetail", D.container)
        D.buffBar = newFrame("SIMPLEFRAME", "", D.info)
        D.invBar = newFrame("SIMPLEFRAME", "", D.container)
        D.items = {}
        for i = 0, 5 do D.items[i] = newFrame("SIMPLEBUTTON", "InventoryButton_" .. i, D.invBar) end
        D.invCover = newFrame("SIMPLEFRAME", "SimpleInventoryCover", D.invBar)
        D.invText = newFrame("STRING", "InventoryText", D.invBar)
        newFrame("SIMPLEFRAME", "", D.bottomBar)                                -- idle worker
        D.tooltip = newFrame("SIMPLEFRAME", "", D.bottomBar)                    -- uber tooltip
    end

    local function originOf(t, i)
        if not D.gameUI then build() end
        local n = type(t) == "table" and t.__const
        if n == 0 then return D.gameUI end
        if n == 2 then return D.heroBar end
        if n == 7 then return D.items[math.min(i, 5)] end
        if n == 8 then return D.minimap end
        if n == 9 then return D.mm[math.min(i, 4)] end
        if n == 12 then return D.tooltip end
        if n == 16 then return D.portrait end
        if n == 17 then return D.world end
        if n == 18 then return D.consoleUI end
        if n == 21 then return D.buffBar end
        if n == 1 then fail("ORIGIN_FRAME_COMMAND_BUTTON looked up (created only on first selection)") end
        return newFrame("FRAME", "", D.gameUI)
    end

    function BlzGetOriginFrame(t, i) return originOf(t, i or 0) end
    function BlzGetFrameByName(name, ctx)
        if not D.gameUI then build() end
        return byName[name]
    end

    function BlzCreateFrameByType(kind, name, parent, inherits, ctx)
        if not TYPES[kind] then fail("frame type " .. tostring(kind)) end
        if not isFrame(parent) then fail("create " .. kind .. " without a parent frame") end
        if SIMPLE[kind] and not parent.simple then fail("simple " .. kind .. " under a Frame-family parent") end
        if not SIMPLE[kind] and parent.simple then fail(kind .. " under a SimpleFrame parent") end
        local f = newFrame(kind, name, parent)
        f.custom = true
        M.created[#M.created + 1] = f
        return f
    end
    function BlzCreateFrame() fail("BlzCreateFrame needs a loaded fdf template") end
    function BlzCreateSimpleFrame() fail("BlzCreateSimpleFrame needs a loaded fdf template") end

    function BlzFrameClearAllPoints(f) noTexString(f, "ClearAllPoints") f.points, f.all = {}, nil end
    function BlzFrameSetAbsPoint(f, p, x, y)
        noTexString(f, "SetAbsPoint")
        num(x, "x") num(y, "y")
        f.points[p] = {x = x, y = y}
    end
    function BlzFrameSetPoint(f, p, rel, rp, x, y)
        noTexString(f, "SetPoint")
        if not isFrame(rel) then fail("SetPoint relative to a non-frame") end
        num(x, "x") num(y, "y")
        f.points[p] = {rel = rel, rp = rp, x = x, y = y}
    end
    function BlzFrameSetAllPoints(f, rel)
        noTexString(f, "SetAllPoints")
        if not isFrame(rel) then fail("SetAllPoints to a non-frame") end
        f.all = rel
    end
    function BlzFrameSetSize(f, w, h)
        noTexString(f, "SetSize")
        num(w, "w") num(h, "h")
        f.w, f.h = w, h
    end
    function BlzFrameGetWidth(f) return f.w or 0 end
    function BlzFrameGetHeight(f) return f.h or 0 end
    function BlzFrameSetVisible(f, on) noTexString(f, "SetVisible") f.visible = on and true or false end
    function BlzFrameIsVisible(f)
        noTexString(f, "IsVisible")
        if f.tooltipOf then
            -- hovering a labelled button means hovering its click layer
            return M.hover == f.tooltipOf or (M.hover ~= nil and use("hud_kit").hitOf[M.hover] == f.tooltipOf)
        end
        return f.visible
    end
    function BlzFrameSetAlpha(f, a) noTexString(f, "SetAlpha") num(a, "alpha") f.alpha = a end
    function BlzFrameSetScale(f, s) noTexString(f, "SetScale") num(s, "scale") f.scale = s end
    function BlzFrameSetEnable(f, on) noTexString(f, "SetEnable") f.enabled = on end
    function BlzFrameSetLevel(f, l)
        noTexString(f, "SetLevel")
        if f.simple and l > 9 then fail("SimpleFrame level above 9 crashes") end
        f.level = l
    end
    function BlzFrameSetText(f, s)
        if not isFrame(f) then fail("SetText on a non-frame") end
        if type(s) ~= "string" then fail("SetText with " .. type(s)) end
        f.text = s
    end
    function BlzFrameGetText(f) return f.text end
    function BlzFrameSetTextAlignment(f, v, h) if not isFrame(f) then fail("SetTextAlignment") end end
    function BlzFrameSetTexture(f, path, flag, blend)
        if not isFrame(f) then fail("SetTexture on a non-frame") end
        if type(path) ~= "string" or path == "" then fail("SetTexture with an empty path") end
        f.texture = path
    end
    function BlzFrameSetVertexColor(f, c) if not isFrame(f) then fail("SetVertexColor") end end
    function BlzFrameSetModel(f, path, camera)
        if not isFrame(f) then fail("SetModel on a non-frame") end
        if f.kind ~= "STATUSBAR" and f.kind ~= "SPRITE" and f.kind ~= "MODEL" then fail("SetModel on a " .. f.kind) end
        if type(path) ~= "string" or path == "" then fail("SetModel with an empty path") end
        f.model = path
    end
    function BlzFrameSetMinMaxValue(f, a, b) num(a, "min") num(b, "max") f.min, f.max = a, b end
    function BlzFrameSetValue(f, v) num(v, "value") f.value = v end
    function BlzFrameGetValue(f) return f.value end
    function BlzFrameSetFont() fail("SetFont only works on String frames") end
    function BlzFrameSetParent(f, p)
        noTexString(f, "SetParent")
        if not isFrame(p) then fail("SetParent to a non-frame") end
        local q = p
        while q do
            if q == f then fail("SetParent cycle") end
            q = q.parent
        end
        if f.simple ~= p.simple then fail("SetParent across families") end
        detach(f)
        f.parent = p
        p.children[#p.children + 1] = f
    end
    function BlzFrameGetParent(f)
        if not isFrame(f) then fail("GetParent on a non-frame") end
        if not f.parent then fail("GetParent on a top-level frame (crashes the game)") end
        return f.parent
    end
    function BlzFrameGetChildrenCount(f) return #f.children end
    function BlzFrameGetChild(f, i)
        if i < 0 or i >= #f.children then fail("GetChild index " .. i .. " out of range (crashes the game)") end
        return f.children[i + 1]
    end
    function BlzFrameSetTooltip(f, tip)
        if not isFrame(f) or not isFrame(tip) then fail("SetTooltip") end
        if tip.tooltipOf then fail("tooltip frame serves two frames") end
        if f.simple ~= tip.simple then fail("SetTooltip across families") end
        tip.tooltipOf = f
    end
    function BlzFrameClick() end
    function BlzEnableUIAutoPosition(on) M.autoPosition = on end
    function BlzHideOriginFrames(on) M.hiddenOrigin = on end

    function BlzTriggerRegisterFrameEvent(trig, f, ev)
        if not isFrame(f) then fail("frame event on a non-frame") end
        M.regs[#M.regs + 1] = {trig = trig, frame = f, event = ev}
        return __handle("event")
    end
    function BlzTriggerRegisterPlayerKeyEvent(trig, p, key, meta, down)
        M.keys[#M.keys + 1] = {trig = trig, player = p, key = key}
        return __handle("event")
    end

    local function run(trig)
        for _, a in ipairs(trig.actions or {}) do a() end
    end

    -- A synced click on `f` by player `p`.
    function M.click(f, p)
        local n = 0
        local hit = use("hud_kit").hitOf[f]       -- a labelled button's click layer
        for _, r in ipairs(M.regs) do
            if (r.frame == f or (hit ~= nil and r.frame == hit)) and r.event == FRAMEEVENT_CONTROL_CLICK then
                M.trig = {player = p, frame = f, event = r.event}
                run(r.trig)
                n = n + 1
            end
        end
        M.trig = {}
        return n
    end

    function M.key(p, key)
        if key == nil then fail("key event without a key constant") end
        for _, r in ipairs(M.keys) do
            if r.player == p and r.key == key then
                M.trig = {player = p}
                run(r.trig)
            end
        end
        M.trig = {}
    end

    -- visible with every ancestor visible
    function M.shown(f)
        while f do
            if not f.visible then return false end
            f = f.parent
        end
        return true
    end

    function M.under(f, root)
        while f do
            if f == root then return true end
            f = f.parent
        end
        return false
    end

    -- bottom-left corner of a frame placed with absolute points
    function M.at(f)
        local p = f.points[FRAMEPOINT_BOTTOMLEFT]
        if p and p.rel == nil then return p.x, p.y end
        return nil
    end

    ---------------------------------------------------------------- units

    local prevIsUnitType = IsUnitType
    function IsUnitType(u, t)
        if type(u) == "table" and rawget(u, "dhud") then
            if t == UNIT_TYPE_HERO then return u.hero == true end
            if t == UNIT_TYPE_DEAD then return u.dead == true end
        end
        return prevIsUnitType(u, t)
    end
    local prevPoints, prevSelect = GetHeroSkillPoints, SelectHeroSkill
    function GetHeroSkillPoints(u)
        if type(u) == "table" and rawget(u, "dhud") then return u.points or 0 end
        return prevPoints(u)
    end
    function SelectHeroSkill(u, id)
        if type(u) == "table" and rawget(u, "dhud") then
            if (u.points or 0) > 0 then
                u.points = u.points - 1
                u.abilities[id] = (u.abilities[id] or 0) + 1
            end
            return
        end
        return prevSelect(u, id)
    end
    function GroupEnumUnitsSelected(g, p, filter)
        g.units = {}
        if p == Player(0) then
            for _, u in ipairs(M.selection) do g.units[#g.units + 1] = u end
        end
    end
    local prevPosX, prevPosY = BlzGetAbilityPosX, BlzGetAbilityPosY
    function BlzGetAbilityPosX(id)
        if id == nil then fail("BlzGetAbilityPosX without an ability") end
        local c = M.pos[id]
        return c and c[1] or prevPosX(id)
    end
    function BlzGetAbilityPosY(id)
        if id == nil then fail("BlzGetAbilityPosY without an ability") end
        local c = M.pos[id]
        return c and c[2] or prevPosY(id)
    end
    local prevCd = BlzGetUnitAbilityCooldownRemaining
    function BlzGetUnitAbilityCooldownRemaining(u, id)
        if type(u) == "table" and rawget(u, "dhud") then return (u.cd and u.cd[id]) or 0.0 end
        return prevCd(u, id)
    end

    ---------------------------------------------------------------- exercise

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

    -- command card cells as tools/gen_objects.py assigns them
    local function layoutCells()
        local ids = use("data.ids")
        for key, info in pairs(use("data.heroes")) do
            local innate = {}
            for _, code in ipairs(ids.heroes[key .. "_innates"] or {}) do innate[code] = true end
            local list = {}
            for _, ab in ipairs(info.abilities) do list[#list + 1] = ab end
            table.sort(list, function(a, b) return a.slot < b.slot end)
            local basics, inn = {}, {}
            for _, ab in ipairs(list) do
                local code = ids.abilities[ab.name]
                if code then
                    if innate[code] then
                        inn[#inn + 1] = code
                    elseif string.find(ab.AbilityType or "", "ULTIMATE") then
                        M.pos[FourCC(code)] = {3, 2}
                    else
                        basics[#basics + 1] = code
                    end
                end
            end
            local cells = {{0, 2}, {1, 2}, {2, 2}, {1, 1}, {2, 1}}
            local taken = {}
            for i, code in ipairs(basics) do
                local c = cells[math.min(i, 5)]
                M.pos[FourCC(code)] = c
                taken[c[1] .. "," .. c[2]] = true
            end
            local free = {}
            for _, c in ipairs({{2, 1}, {1, 1}, {0, 1}}) do
                if not taken[c[1] .. "," .. c[2]] then free[#free + 1] = c end
            end
            for _, code in ipairs(inn) do M.pos[FourCC(code)] = table.remove(free, 1) or {0, 1} end
        end
    end

    local function exercise()
        local Log = use("log")
        local failures, checks = 0, 0
        local function check(name, ok, detail)
            checks = checks + 1
            if not ok then
                failures = failures + 1
                Log.error("dota_hud exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
            end
        end
        local H = use("heroes")
        -- heroes: the bot draft fills every slot at 45 s
        local guard = 0
        while H.count() < 5 and guard < 10 do
            advance(1)
            guard = guard + 1
        end
        check("five heroes spawned", H.count() == 5, H.count())
        for _, u in pairs(H.bySlot) do
            rawset(u, "dhud", true)
            u.hero, u.level, u.points, u.xp = true, 1, 0, 0
            u.life, u.maxLife, u.mana, u.maxMana = 600, 600, 200, 300
        end
        layoutCells()
        local Hud, Shop, Kit = use("dota_hud"), use("dota_shop"), use("hud_kit")
        local Items = use("items")
        local Events = use("events")
        local ids = use("data.ids")
        if Hud.started then
            Log.info("dota_hud exercise: the HUD was started by game.lua")
        else
            Hud.init()
        end
        check("local view is dota", Hud.view() == "dota", Hud.view())
        local F, S, L = Hud.F, Hud.S, Hud.L
        local SF = Shop.F
        local p0, p1 = Player(0), Player(1)
        local hero = H.bySlot[0]
        local other = H.bySlot[1]
        local key = H.keyOf[hero]
        local row = Hud.rowOf(key)
        local hx, hy, ox, oy = hero.x, hero.y, other.x, other.y
        M.selection = {hero}

        -- default UI: kept frames visible, art and replaced panels hidden
        for i = 0, 11 do check("command button " .. i .. " shown", M.shown(D.cmd[i])) end
        for i = 0, 5 do check("item button " .. i .. " shown", M.shown(D.items[i])) end
        check("tooltip shown", M.shown(D.tooltip))
        check("portrait shown", M.shown(D.portrait))
        check("minimap shown", M.shown(D.minimap))
        check("menu buttons shown", M.shown(D.upper))
        check("console art hidden", not M.shown(D.topBar) and not M.shown(D.bottomBar))
        check("unit info panel hidden", not M.shown(D.info))
        check("resources and upkeep hidden", not M.shown(D.resource))
        check("wc3 clock hidden", not M.shown(D.clock))
        check("auto position off", M.autoPosition == false)
        check("hud roots shown", M.shown(F.fgRoot) and M.shown(F.bgRoot) and M.shown(F.simBottom))
        check("backgrounds below simple frames", M.under(F.bgRoot, D.backdrop))

        -- nothing to show (as before the draft when game.lua starts the HUD):
        -- the unit panels hide, and all of them come back with a unit
        M.selection = {}
        H.bySlot[0] = nil
        Hud.tick()
        check("stats hidden without a unit", F.statIcons[1].visible == false and F.hp.visible == false)
        H.bySlot[0] = hero
        M.selection = {hero}
        Hud.tick()
        for i = 1, 6 do
            check("stat " .. i .. " shown again", M.shown(F.statIcons[i]) and M.shown(F.statTexts[i].box))
        end
        check("health bar shown again", M.shown(F.hp) and M.shown(F.hpText.box))

        -- the shared update timer keeps running
        local t0 = S.ticks
        advance(1)
        check("HUD timer keeps running", S.ticks >= t0 + 9, S.ticks - t0)

        -- local code creates no handles
        local h0 = M.handles
        for _ = 1, 5 do Hud.tick() end
        Hud.applyView()
        check("no handles in local code", M.handles == h0, M.handles - h0)

        -- ability row: same height, left to right, own cells; other cells parked
        Hud.tick()
        check("row mode for the hero", S.mode == "row" and S.key == key, tostring(S.mode) .. " " .. tostring(S.key))
        local lastX, used = -1, {}
        for k, e in ipairs(row) do
            local idx = S.cellOf[k]
            check("slot " .. k .. " (" .. e.name .. ") has a cell", idx ~= nil)
            if idx then
                used[idx] = true
                if not e.empty then
                    check("ability " .. e.name .. " keeps its own cell",
                        idx == BlzGetAbilityPosY(e.id) * 4 + BlzGetAbilityPosX(e.id), idx)
                end
                local x, y = M.at(D.cmd[idx])
                check("slot " .. k .. " (" .. e.name .. ") in the row",
                    x and math.abs(y - L.BTN_Y) < 1e-6 and x > lastX, tostring(x) .. "," .. tostring(y))
                lastX = x or lastX
            end
        end
        for i = 0, 11 do
            if not used[i] then
                local _, y = M.at(D.cmd[i])
                check("cell " .. i .. " parked off-screen", y and y < 0, y)
            end
        end

        -- Dota's empty slots (Rubick's stolen spells) take the spare D and F cells
        if ids.heroes.rubick then
            local rrow = Hud.rowOf("rubick")
            local spare = {}
            for k, e in ipairs(rrow) do
                if e.empty then spare[#spare + 1] = k end
            end
            check("rubick row has two empty slots", #spare == 2, #spare)
            local rub = CreateUnit(p0, FourCC(ids.heroes.rubick), hero.x + 200, hero.y, 0)
            rawset(rub, "dhud", true)
            rub.hero, rub.level = true, 1
            M.selection = {rub}
            Hud.tick()
            check("rubick row mode", S.mode == "row" and S.key == "rubick", tostring(S.key))
            local d, f = S.cellOf[spare[1] or 0], S.cellOf[spare[2] or 0]
            check("empty slots on D and F", d == 5 and f == 6, tostring(d) .. "," .. tostring(f))
            local _, y = M.at(D.cmd[5])
            check("stolen-spell cell D shown in the row", y and math.abs(y - L.BTN_Y) < 1e-6, y)
            check("no learn + on an empty slot", spare[1] == nil or F.learn[spare[1]].visible == false)
            RemoveUnit(rub)
            M.selection = {hero}
            Hud.tick()
        end

        -- learning: basics at level 1, ultimate at 6
        local ult, basic = nil, nil
        for k, e in ipairs(row) do
            if e.ult and not ult then ult = k end
            if not e.ult and not e.innate and not e.empty and not basic then basic = k end
        end
        hero.points = 1
        Hud.tick()
        check("learn + on a basic ability", F.learn[basic].visible == true)
        check("no learn + on the ultimate at level 1", ult == nil or F.learn[ult].visible == false)
        M.click(F.learn[basic], p0)
        check("learn click levels the ability", GetUnitAbilityLevel(hero, row[basic].id) == 1 and hero.points == 0)
        Hud.tick()
        check("learn + hidden without points", F.learn[basic].visible == false)
        -- cooldown seconds over the button
        hero.cd = {[row[basic].id] = 7.3}
        Hud.tick()
        check("cooldown seconds shown", F.cd[basic].box.visible == true
            and string.find(F.cd[basic].t.text, "8", 1, true) ~= nil, F.cd[basic].t.text)
        hero.cd = nil
        Hud.tick()
        check("cooldown seconds hidden when ready", F.cd[basic].box.visible == false)
        hero.points, hero.level = 1, 2
        Hud.tick()
        check("basic level 2 needs hero level 3", F.learn[basic].visible == false)
        if ult then
            hero.level = 6
            Hud.tick()
            check("learn + on the ultimate at level 6", F.learn[ult].visible == true)
            M.click(F.learn[ult], p0)
            check("ultimate learned", GetUnitAbilityLevel(hero, row[ult].id) == 1)
        end
        -- another player's click acts on that player's hero only
        other.points = 1
        local orow = Hud.rowOf(H.keyOf[other])
        M.click(F.learn[1], p1)
        check("click learns for the clicking player", orow[1].innate or orow[1].empty
            or GetUnitAbilityLevel(other, orow[1].id) == 1)

        -- a clone of the hero (Meepo) shows the same row and the main hero's points
        local clone = CreateUnit(p0, GetUnitTypeId(hero), hero.x + 100, hero.y, 0)
        rawset(clone, "dhud", true)
        clone.hero, clone.level, clone.points = true, 6, 0
        M.selection = {clone}
        hero.points = 1
        Hud.tick()
        check("clone keeps the hero row", S.mode == "row" and S.key == key)
        check("clone shows the main hero's learn +", F.learn[basic].visible == true)
        hero.points = 0
        RemoveUnit(clone)

        -- a shop selected: the full 4 x 3 command card
        local shopUnit = Items.shops[1]
        M.selection = {shopUnit}
        Hud.tick()
        check("grid mode for a shop", S.mode == "grid")
        for i = 0, 11 do
            local x, y = M.at(D.cmd[i])
            check("grid cell " .. i .. " on screen", x and y >= 0 and y < L.PANEL_H + 0.01, y)
        end
        M.selection = {hero}
        Hud.tick()

        -- death and respawn in the top bar
        other.dead = true
        Events.emit("death", other, hero)
        Hud.tick()
        local t2 = F.top[2]
        check("respawn timer shown", t2.timer.box.visible and t2.timer.t.text ~= "", t2.timer.t.text)
        other.dead = false
        Events.emit("hero_respawned", other, H.keyOf[other], 1)
        Hud.tick()
        check("respawn timer hidden", t2.timer.box.visible == false)
        hero.dead = true
        Hud.tick()
        check("dead overlay on the portrait", F.dead.visible == true)
        hero.dead = false
        Hud.tick()

        ---------------------------------------------------------------- item slots
        -- cooldown sweep (model and wipe), seconds and charges on the item buttons
        do
            local Items = use("items")
            local names, activeName = {}, nil
            for name in pairs(ids.item_abilities) do names[#names + 1] = name end
            table.sort(names)
            for _, name in ipairs(names) do
                local e = Items.data(name)
                if not activeName and e and (e.cooldown or 0) >= 10 and not e.consumable then activeName = name end
            end
            for _, c in ipairs(Items.carried(hero)) do Items.remove(hero, c.item) end
            local it = UnitAddItemById(hero, FourCC(ids.items[activeName]))
            local cdTotal = Items.data(activeName).cooldown
            M.selection = {hero}
            Kit.SWEEP = "model"
            Items.used(hero, it, activeName)
            Hud.tick()
            Hud.tickSweeps()
            local s = F.slots[0]
            check("item shown in slot 0", M.shown(s.b) and s.item == it)
            check("sweep shown on cooldown", M.shown(s.cd.box) and not M.shown(s.cd.wipe))
            check("sweep starts dark", s.cd.bar.value < 0.05, s.cd.bar.value)
            check("sweep uses the cooldown model", s.cd.bar.model == Kit.SWEEP_MODEL, s.cd.bar.model)
            check("sweep model scaled to the slot", math.abs(s.cd.bar.scale - L.ITEM_H / 0.038) < 1e-6, s.cd.bar.scale)
            check("cooldown seconds shown", M.shown(s.cd.text.box)
                and string.find(s.cd.text.t.text, tostring(math.ceil(cdTotal)), 1, true) ~= nil, s.cd.text.t.text)
            advance(cdTotal / 2)
            Hud.tickSweeps()
            check("sweep at half time", math.abs(s.cd.bar.value - 0.5) < 0.05, s.cd.bar.value)
            Kit.SWEEP = "wipe"
            Hud.tickSweeps()
            local wy = s.cd.wipe.points[FRAMEPOINT_TOPRIGHT]
            check("wipe mode shows the overlay", M.shown(s.cd.wipe) and not M.shown(s.cd.box))
            check("wipe covers half the slot", wy ~= nil
                and math.abs((wy.y - s.cd.y0) / (s.cd.y1 - s.cd.y0) - 0.5) < 0.06, wy and wy.y)
            Kit.SWEEP = "model"
            advance(cdTotal / 2 + 0.5)
            Hud.tickSweeps()
            check("sweep hidden when ready", not M.shown(s.cd.box) and not M.shown(s.cd.text.box))
            -- WC3's own cooldown counts when it runs longer (a reduction or refresh by other code)
            hero.cd = {[Items.abilityId(activeName)] = 4.2}
            Hud.tickSweeps()
            check("native cooldown shown", M.shown(s.cd.box) and string.find(s.cd.text.t.text, "5", 1, true) ~= nil,
                s.cd.text.t.text)
            hero.cd = nil
            Hud.tickSweeps()
            Items.remove(hero, it)
            local tango = UnitAddItemById(hero, FourCC(ids.items.item_tango))
            SetItemCharges(tango, 3)
            Hud.tick()
            check("charges shown", s.charges.t.text == "3", s.charges.t.text)
            Items.remove(hero, tango)
            Hud.tick()
            check("empty slot hidden", not M.shown(s.b))
        end

        ---------------------------------------------------------------- click blockers
        -- every button sits under a blocker that covers its panel; the WC3
        -- portrait and minimap stay open
        do
            local function rect(f)
                local a, b = f.points[FRAMEPOINT_BOTTOMLEFT], f.points[FRAMEPOINT_TOPRIGHT]
                return a and b and {a.x, a.y, b.x, b.y} or nil
            end
            local function inside(f, box)
                local r, q = rect(f), rect(box)
                return r ~= nil and q ~= nil and r[1] >= q[1] - 1e-6 and r[2] >= q[2] - 1e-6
                    and r[3] <= q[3] + 1e-6 and r[4] <= q[4] + 1e-6
            end
            local function overlaps(f, box)
                local r, q = rect(f), rect(box)
                return r ~= nil and q ~= nil and r[1] < q[3] - 1e-6 and q[1] < r[3] - 1e-6
                    and r[2] < q[4] - 1e-6 and q[2] < r[4] - 1e-6
            end
            Hud.tick()
            check("bottom blocker shown", F.fgBottom.kind == "GLUEBUTTON" and M.shown(F.fgBottom))
            for i = 0, 5 do
                check("item slot " .. i .. " under the bottom blocker", M.under(Kit.hit(F.slots[i].b), F.fgBottom))
                check("item slot " .. i .. " inside the blocked area", inside(F.slots[i].b, F.fgBottom))
            end
            for k = 1, #F.learn do
                check("learn " .. k .. " under the bottom blocker", M.under(Kit.hit(F.learn[k]), F.fgBottom))
            end
            check("SHOP button under the bottom blocker", M.under(Kit.hit(F.shopBtn), F.fgBottom)
                and inside(F.shopBtn, F.fgBottom))
            local loose = 0
            for _, c in ipairs(Shop.cells) do
                if not M.under(Kit.hit(c.b), SF.root) then loose = loose + 1 end
            end
            check("shop buttons under the shop blocker", loose == 0 and SF.root.kind == "GLUEBUTTON"
                and rect(SF.root) ~= nil, loose)
            check("top bar blocker over the hero icons", M.under(F.top[1].icon, F.fgTop) and inside(F.top[1].icon, F.fgTop))
            for _, b in ipairs({F.fgBottom, F.blockStats, F.blockXp, F.fgTop}) do
                check("blocker leaves the portrait open", not overlaps(D.portrait, b))
                check("blocker leaves the minimap open", not overlaps(D.minimap, b))
            end
        end

        ---------------------------------------------------------------- shop
        local function gold(p) return GetPlayerState(p or p0, PLAYER_STATE_RESOURCE_GOLD) end
        local function setGold(n, p) SetPlayerState(p or p0, PLAYER_STATE_RESOURCE_GOLD, n) end
        local function clear(u)
            for _, c in ipairs(Items.carried(u)) do Items.remove(u, c.item) end
        end
        local function count(u) return #Items.carried(u) end
        local function cellFor(name)
            for _, c in ipairs(Shop.cells) do
                if c.name == name then return c end
            end
            return nil
        end
        local s1 = Items.shops[1]
        local function atShop(u) u.x, u.y = GetUnitX(s1) + 100, GetUnitY(s1) end

        -- test items from the data: a plain basic, an upgrade of basics with a scroll
        local basicItem, upgrade = nil, nil
        for _, s in ipairs(use("data.items").shops) do
            for _, n in ipairs(s.items) do
                local e = Items.data(n)
                if e and not basicItem and not e.recipe and not e.result and not e.stock and not e.stack
                        and not e.consumable and e.cost > 0 then
                    basicItem = n
                end
                if e and not upgrade and e.recipe and e.recipe.scroll and #e.recipe.parts == 1 then
                    local plain = true
                    for _, part in ipairs(e.recipe.parts[1]) do
                        local pe = Items.data(part)
                        if not pe or pe.recipe or pe.stack then plain = false end
                    end
                    if plain then upgrade = n end
                end
            end
        end
        check("test items found", basicItem ~= nil and upgrade ~= nil, tostring(basicItem) .. " " .. tostring(upgrade))
        local be, ue = Items.data(basicItem), Items.data(upgrade)
        local bc, uc = cellFor(basicItem), cellFor(upgrade)
        check("every shop item has a button", #Shop.cells == #(function()
            local all = {}
            for _, s in ipairs(use("data.items").shops) do
                for _, n in ipairs(s.items) do all[#all + 1] = n end
            end
            return all
        end)(), #Shop.cells)

        -- opening
        M.click(F.shopBtn, p0)
        check("shop opens from the SHOP button", Shop.isOpen() and M.shown(SF.root))
        M.click(F.shopBtn, p1)
        check("another player's SHOP click leaves this screen alone", Shop.isOpen())

        -- hover: the details pane shows the item and its recipe parts
        M.click(SF.tab[uc.tab], p0)
        M.hover = uc.b
        Hud.tick()
        check("hover shows the item", Shop.detail ~= nil and Shop.detail.name == upgrade and M.shown(SF.detail),
            Shop.detail and Shop.detail.name)
        check("details name", string.find(SF.dName.t.text, ue.title, 1, true) ~= nil, SF.dName.t.text)
        local wantParts, shownParts = #ue.recipe.parts[1] + 1, 0
        for i = 1, Shop.L.PARTS do
            if SF.parts[i].visible then shownParts = shownParts + 1 end
        end
        check("recipe parts shown on hover", shownParts == wantParts, shownParts .. "/" .. wantParts)
        check("hover highlight shown", M.shown(SF.hover))
        M.hover = nil

        -- buying by click at the shop: the item arrives, its cost is paid
        clear(hero)
        atShop(hero)
        setGold(5000)
        M.click(bc.b, p0)
        check("click buys " .. basicItem, Items.find(hero, basicItem) ~= nil and gold() == 5000 - be.cost, gold())

        -- an upgrade with one part carried: only the missing gold is paid
        clear(hero)
        setGold(ue.cost + 1000)
        local firstPart = ue.recipe.parts[1][1]
        M.click(cellFor(firstPart).b, p0)
        check("part bought", Items.find(hero, firstPart) ~= nil)
        M.hover = uc.b
        Hud.tick()
        M.hover = nil
        check("carried part dimmed in the details", SF.parts[1].alpha < 255, SF.parts[1].alpha)
        local price = Items.price(hero, upgrade)
        check("carried part lowers the price", price < ue.cost, price)
        local before = gold()
        M.click(uc.b, p0)
        check("click buys " .. upgrade .. " with the carried part", Items.find(hero, upgrade) ~= nil
            and Items.find(hero, firstPart) == nil and gold() == before - price, gold() .. " vs " .. (before - price))

        -- refusals: no gold and no item change hands
        local function refused(label, setup, undo)
            clear(hero)
            atShop(hero)
            setGold(5000)
            setup()
            local g, n = gold(), count(hero)
            M.click(bc.b, p0)
            check(label, gold() == g and count(hero) == n, gold() .. " gold, " .. count(hero) .. " items")
            if undo then undo() end
        end
        refused("refused without enough gold", function() setGold(be.cost - 1) end)
        refused("refused away from the shops", function() hero.x = hero.x + 5000 end)
        refused("refused while the hero is dead", function() hero.dead = true end, function() hero.dead = false end)
        refused("refused with a full inventory", function()
            for _ = 1, 6 do UnitAddItemById(hero, FourCC(ids.items[basicItem])) end
        end)

        -- another player's click buys for that player's hero only
        clear(hero)
        clear(other)
        atShop(other)
        setGold(5000, p1)
        local g0 = gold()
        M.click(bc.b, p1)
        check("player 1's click buys for player 1's hero", Items.find(other, basicItem) ~= nil
            and count(hero) == 0 and gold() == g0 and gold(p1) == 5000 - be.cost, count(hero))
        clear(other)
        other.x, other.y = ox, oy

        -- selling from the sell row
        atShop(hero)
        setGold(5000)
        M.click(bc.b, p0)
        Hud.tick()
        local slot = nil
        for i = 0, 5 do
            if not slot and UnitItemInSlot(hero, i) then slot = i end
        end
        check("sell button shown for the item", slot ~= nil and M.shown(Shop.sells[slot].b))
        local g1 = gold()
        M.click(Shop.sells[slot or 0].b, p0)
        check("sell click gives half the cost back", gold() == g1 + math.floor(be.cost * 0.5 + 0.5)
            and Items.find(hero, basicItem) == nil, gold() - g1)

        -- keys: F4 toggles, Esc closes
        M.key(p0, OSKEY_F4)
        check("F4 closes the shop", not Shop.isOpen())
        M.key(p0, OSKEY_F4)
        check("F4 opens the shop", Shop.isOpen())
        M.key(p0, OSKEY_ESCAPE)
        check("Esc closes the shop", not Shop.isOpen())
        M.key(p1, OSKEY_F4)
        check("another player's F4 leaves this screen alone", not Shop.isOpen())
        M.key(p0, OSKEY_F4)
        check("F4 opens the shop again", Shop.isOpen())

        -- limited stock (Dota wards and the like)
        local stocked = nil
        for _, s in ipairs(use("data.items").shops) do
            for _, n in ipairs(s.items) do
                local e = Items.data(n)
                if e and e.stock and not stocked and (e.stock.initial or 0) > 0 and (e.stock.time or 0) > 30 then
                    stocked = n
                end
            end
        end
        if stocked then
            local e = Items.data(stocked)
            atShop(hero)
            setGold(50000)
            local bought = 0
            for _ = 1, (e.stock.initial or 1) + 1 do
                if Shop.buy(p0, stocked) then bought = bought + 1 end
                clear(hero)
            end
            check("stock limits " .. stocked, bought == math.min(e.stock.initial, e.stock.max or 99), bought)
        end

        -- the open shop creates no handles while hovering and updating
        local h1 = M.handles
        M.hover = uc.b
        for _ = 1, 12 do Hud.tick() end
        M.hover = nil
        Hud.tick()
        check("no handles while the shop is open", M.handles == h1, M.handles - h1)
        M.click(SF.close, p0)
        check("X closes the shop", not Shop.isOpen())
        clear(hero)
        hero.x, hero.y = hx, hy

        ---------------------------------------------------------------- views
        check("commander keeps the WC3 UI", Hud.viewOf(Player(SLOT_COMMANDER_AI)) == nil)
        M.observer[10] = true
        check("observers keep the WC3 UI", Hud.viewOf(Player(10)) == nil)
        M.observer[10] = nil
        check("hero players get the Dota HUD", Hud.viewOf(p1) == "dota")

        -- menu bar and layout bounds on three screen shapes, then back to 4:3;
        -- Frame-family UI stays inside 4:3
        for _, wh in ipairs({{1920, 1080}, {3440, 1440}, {1440, 1080}}) do
            M.width, M.height = wh[1], wh[2]
            Hud.tick()
            Hud.tick()
            local at = wh[1] .. "x" .. wh[2]
            local SL = Kit.edges()
            local mp = D.upper.points[FRAMEPOINT_TOPLEFT]
            local wantX = (SL < -0.02) and (SL + 0.004) or 0.0
            check("menu bar placed at " .. at, mp ~= nil and math.abs(mp.x - wantX) < 1e-6 and math.abs(mp.y - 0.6) < 1e-6,
                mp and mp.x)
            local ix = M.at(F.top[1].icon)
            check("hero icons clear the menu bar at " .. at, ix ~= nil and mp ~= nil and ix >= mp.x + D.upper.w, ix)
            for _, f in ipairs(M.created) do
                local x, y = M.at(f)
                if x and M.shown(f) then
                    local p = f.points[FRAMEPOINT_TOPRIGHT]
                    local x1, y1 = p and p.x or x, p and p.y or y
                    local inside = x >= -0.001 and x1 <= 0.801 and y >= -0.001 and y1 <= 0.601
                    if not f.simple and not M.under(f, D.backdrop) then
                        check("frame inside 4:3 at " .. at, inside, string.format("%.3f %.3f %.3f %.3f", x, y, x1, y1))
                    end
                    check("frame on screen", y1 <= 0.61 and y >= -0.01, string.format("%.3f %.3f", y, y1))
                end
            end
        end
        M.width, M.height = 1920, 1080
        Hud.tick()

        -- test builds have no Dota art: every button shows a WC3 texture or a
        -- label, and no texture points into the launcher's folders
        if not Kit.dota then
            local isHit = {}                  -- click layers and blockers have no visuals by design
            for _, h in pairs(Kit.hitOf) do isHit[h] = true end
            for _, b in ipairs(Kit.blockers) do isHit[b] = true end
            for _, f in ipairs(M.created) do
                if (f.kind == "BUTTON" or f.kind == "GLUEBUTTON") and not isHit[f] then
                    local ok = false
                    for _, c in ipairs(f.children) do
                        if c.kind == "BACKDROP" and c.texture then ok = true end
                        for _, t in ipairs(c.children) do
                            if t.kind == "TEXT" and t.text ~= "" then ok = true end
                        end
                    end
                    check("button visible without Dota art", ok)
                end
                if f.texture then
                    check("fallback texture " .. f.texture, not string.find(f.texture, "war3mapImported", 1, true)
                        and not string.find(f.texture, "BTNDota_", 1, true))
                end
            end
        end

        -- every Dota image the Lua asks for is in specs/hud_assets.json
        local fh = io and io.open and io.open("specs/hud_assets.json", "r")
        if fh then
            local text = fh:read("a")
            fh:close()
            local targets = {}
            for t in string.gmatch(text, '"target"%s*:%s*"war3mapImported\\\\Hud\\\\([%w_]+)%.blp"') do targets[t] = true end
            for n in pairs(Kit.used) do check("hud asset listed: " .. n, targets[n] == true) end
        else
            Log.warn("dota_hud exercise: specs/hud_assets.json not found (run from the repo root)")
        end
        Log.info("dota_hud exercise: " .. checks .. " checks, " .. failures .. " failed")
    end

    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("dota_hud") then return end
        done = true
        use("safe").call(exercise)
        use("log").flush()
    end
end
