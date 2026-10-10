-- Dota 2 style HUD for the Dota-team players. The commander and observers
-- keep the normal Warcraft III interface.
--
--   bottom-left    minimap (WC3 minimap moved into a Dota frame)
--   bottom-centre  stats | portrait + level/XP | ability row with gold "+"
--                  learn buttons, ability level pips, mana costs, cooldown
--                  seconds; HP and mana bars with current/max and regen
--   bottom-right   3 x 2 items (WC3 inventory buttons), gold, SHOP button
--   top            five Dota heroes with HP/mana and respawn timers, game
--                  clock with day/night, the commander on the right
--
-- The ability row is built from the WC3 command buttons: cells that hold the
-- focused hero's abilities line up in one row (Dota's empty slots, such as
-- Rubick's stolen-spell slots, show the spare D/F cells); move/stop/hold/
-- attack/patrol and WC3's own learn button are parked off-screen (their
-- hotkeys keep working). Any other selection (shop, creeps, summons) shows
-- the full 4 x 3 command card in the same place.
--
-- Multiplayer: all frames and triggers are created for every player in
-- init(); per-player differences are visibility, texts, textures and
-- positions only. Learn clicks are synced frame events and act on the
-- clicking player's hero.
-- Start once roles are assigned (game.lua begin()): use("dota_hud").init()
-- (also starts the shop).
define("dota_hud", function()
    local Kit = use("hud_kit")
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Roles = use("roles")
    local Safe = use("safe")
    local Hud = {started = false}

    ---------------------------------------------------------------- layout
    -- Screen units: the 4:3 area is 0..0.8 x 0..0.6 (bottom-left origin).
    -- Wider screens extend left of 0 and right of 0.8 (16:9: -0.133..0.933).
    -- Everything stays inside 0..0.8 except the optional edge minimap, so all
    -- frame types render correctly on any aspect ratio. At 1080p, 0.01 = 18 px.
    local L = {
        TICK = 0.1,             -- the one update loop (seconds)
        -- bottom-centre panel, left to right: stats | portrait | abilities | items
        ABIL_CX = 0.40,         -- centre of the ability area (pushed right if the minimap is in the way)
        ABIL_W = 0.262,         -- ability area width (7 slots max)
        PORT_W = 0.076,         -- portrait column width
        STATS_W = 0.074,        -- damage/armor/speed + str/agi/int column width
        PANEL_H = 0.106,        -- panel height from the screen bottom
        BTN = 0.038,            -- ability button size (shrinks to fit 7 abilities)
        BTN_GAP = 0.004,        -- gap between ability buttons
        BTN_Y = 0.047,          -- bottom edge of the ability row
        LEARN_H = 0.015,        -- gold "+" learn button height, just above the row
        SEL_SIZE = 0.026,       -- icons of the selected-units bar above the panel
        PIP_H = 0.003,          -- ability level pips between row and HP bar
        HP_Y = 0.025, HP_H = 0.015,  -- health bar
        MP_Y = 0.008, MP_H = 0.013,  -- mana bar
        GRID = 0.031,           -- command card cell in grid mode (shop/creep selected)
        ITEMS_W = 0.122,        -- right block: 3 x 2 items, gold and SHOP button
        ITEM_W = 0.035, ITEM_H = 0.029, ITEM_GAP = 0.003,
        -- minimap
        MAP = 0.148,            -- minimap size
        MAP_X = 0.020,          -- left edge inside 4:3 (buttons column to its left)
        MAP_Y = 0.006,
        MINIMAP_AT_SCREEN_EDGE = false,  -- true: wide screens put it in the real corner
                                         -- (reparents MiniMapFrame to ConsoleUIBackdrop)
        -- top bar
        CLOCK_W = 0.066, CLOCK_H = 0.030,
        HERO_W = 0.026, HERO_H = 0.026, HERO_GAP = 0.002,  -- square hero icons (shrink if needed)
        CMD_W = 0.16,           -- commander block right of the clock
        -- Warcraft III frames
        TOOLTIP_DY = 0.012,     -- ability tooltip: bottom edge this far above the panel
        -- the stretched ConsoleUIBackdrop also took every click from our buttons
        -- in the strip (SHOP, "+" learn) in game, so it stays collapsed
        BLOCK_BOTTOM_CLICKS = false,
        MOVE_MENU_TO_EDGE = true,    -- wide screens: Quests/Menu/Allies/Log to the screen's top-left
        MENU_W = 0.255,              -- menu bar width when the game does not report it
        SHOW_BUFFS = true,           -- WC3 buff bar just above the abilities
        PARK_Y = -0.3,               -- unused command buttons live below the screen
        SPARE_CELLS = {5, 6},        -- D (1,1) and F (2,1): Dota's empty ability slots
    }
    Hud.L = L

    local ROW_MAX = 7
    local PIPS = 4
    local SEL_MAX = 10                  -- units in the selected-units bar
    local STR_REGEN, INT_REGEN = 0.1, 0.05     -- gameplay constants (tools/gen_objects.py MISC)
    local NEED_XP = {240, 640, 1160, 1760, 2440, 3200, 4000, 4900, 5900, 7000, 8200, 9500, 10900, 12400,
                     14000, 15700, 17500, 19400, 21400, 23600, 26000, 28600, 31400, 34400, 38400, 43400,
                     49400, 56400, 63900}
    local GREEN, GOLD, BLUE, GRAY, RED = "40ff40", "ffcc00", "80b0ff", "a0a0a0", "ff5050"

    local D = {cmd = {}, items = {}, mmButtons = {}}   -- Warcraft III frames
    local F = {}                                     -- our frames
    local S = {mode = nil, key = nil, n = 0, ticks = 0, dirty = true, L = 0.0, R = 0.8}
    local view = nil                                 -- local: "dota" or nil (WC3 UI)
    local failures = 0                               -- local: update errors so far
    local respawnAt = {}                             -- hero -> game time of revival (synced)
    local halls = 0                                  -- commander town halls (synced)
    local keyByType = {}                             -- unit type -> hero key
    local rows = {}                                  -- hero key -> ability row
    local selGroup = nil

    ---------------------------------------------------------------- data

    local function heroes() return use("heroes") end

    local function heroKeyOf(u)
        if not u then return nil end
        return heroes().keyOf[u] or keyByType[GetUnitTypeId(u)]
    end

    -- Abilities shown in the row: Dota's slot order with the ultimate last
    -- (Q W E D F ... R). Each: {name, id, ult, innate, max, rl, lb}; Dota's
    -- empty slots (rubick_empty1, ...) have no WC3 ability:
    -- {name, empty = true, max = 0}. Same content for every player.
    local function rowOf(key)
        if not key then return nil end
        local row = rows[key]
        if row then return row end
        row = {}
        local ids = use("data.ids")
        local info = use("data.heroes")[key]
        local innate = {}
        for _, code in ipairs(ids.heroes[key .. "_innates"] or {}) do innate[code] = true end
        local list = {}
        for _, ab in ipairs(info and info.abilities or {}) do list[#list + 1] = ab end
        table.sort(list, function(a, b) return (a.slot or 0) < (b.slot or 0) end)
        local others, ults = {}, {}
        local spare = #L.SPARE_CELLS
        for _, ab in ipairs(list) do
            local code = ids.abilities[ab.name]
            if not code and spare > 0 and string.find(ab.name, "_empty%d*$") then
                spare = spare - 1
                others[#others + 1] = {name = ab.name, empty = true, max = 0}
            elseif code then
                local v = ab.values or {}
                local e = {name = ab.name, id = FourCC(code), innate = innate[code] == true,
                           ult = string.find(ab.AbilityType or "", "ULTIMATE") ~= nil,
                           rl = tonumber(v.required_level), lb = tonumber(v.levels_between_upgrades)}
                if e.innate then
                    e.max = 1
                else
                    e.max = tonumber(ab.MaxLevel) or tonumber(v.max_level) or (e.ult and 3 or 4)
                end
                if e.ult and not e.innate then ults[#ults + 1] = e else others[#others + 1] = e end
            end
        end
        -- the ultimate always gets a slot, even when a hero has many abilities
        local room = ROW_MAX - math.min(#ults, ROW_MAX)
        for i = 1, math.min(#others, room) do row[#row + 1] = others[i] end
        for i = 1, math.min(#ults, ROW_MAX - #row) do row[#row + 1] = ults[i] end
        rows[key] = row
        return row
    end
    Hud.rowOf = rowOf

    -- Hero level needed for the next level of `e` (Dota rules: basic level n
    -- at hero level 2n-1, ultimates at 6/12/18, data overrides such as
    -- Divided We Stand's 3/10/17/24).
    local function required(e, cur)
        if e.rl and e.lb then return e.rl + cur * e.lb end
        if e.ult then return 6 + 6 * cur end
        return 1 + 2 * cur
    end

    local function canLearn(hero, e)
        if not e or e.innate or e.empty then return false end
        local cur = GetUnitAbilityLevel(hero, e.id)
        return cur < e.max and GetHeroLevel(hero) >= required(e, cur)
    end
    Hud.canLearn = canLearn

    ---------------------------------------------------------------- Warcraft III frames

    local function child(f, i)
        if not Kit.valid(f) then return nil end
        local n = BlzFrameGetChildrenCount(f)
        if not n or i >= n then return nil end
        local c = BlzFrameGetChild(f, i)
        return Kit.valid(c) and c or nil
    end

    local function named(name)
        local f = BlzGetFrameByName(name, 0)
        return Kit.valid(f) and f or nil
    end

    local function origin(t, i)
        local f = BlzGetOriginFrame(t, i or 0)
        return Kit.valid(f) and f or nil
    end

    -- Runs for every player: the first lookup of a frame takes a handle id.
    -- Origin frames first (a frame reached through the child API first can
    -- break its origin lookup), then names, parents, and indexed children.
    local function acquire()
        D.gameUI = origin(ORIGIN_FRAME_GAME_UI)
        D.world = origin(ORIGIN_FRAME_WORLD_FRAME)
        D.portrait = origin(ORIGIN_FRAME_PORTRAIT)
        D.minimap = origin(ORIGIN_FRAME_MINIMAP)
        D.tooltip = origin(ORIGIN_FRAME_UBERTOOLTIP)
        D.buffBar = origin(ORIGIN_FRAME_UNIT_PANEL_BUFF_BAR)
        D.heroBar = origin(ORIGIN_FRAME_HERO_BAR)
        for i = 0, 4 do D.mmButtons[i] = origin(ORIGIN_FRAME_MINIMAP_BUTTON, i) end
        D.simpleRoot = origin(ORIGIN_FRAME_SIMPLE_UI_PARENT)

        D.consoleUI = named("ConsoleUI") or D.simpleRoot
        D.backdrop = named("ConsoleUIBackdrop")
        D.topBar = named("ConsoleTopBar")
        D.bottomBar = named("ConsoleBottomBar")
        D.bottomOverlay = named("ConsoleBottomBarOverlay")
        D.cmdBar = named("CommandBarFrame")
        -- the named containers exist from the start; the origin buttons inside
        -- are created on the first selection, so they are never looked up here
        for i = 0, 11 do D.cmd[i] = named("CommandButton_" .. i) end
        -- Inventory buttons by name, like the command buttons: the origin item
        -- buttons looked up before the first selection were stand-ins, and the
        -- real ones stayed hidden inside the console bar (no icons, clicks or
        -- hotkeys in game, 2026-10-10).
        for i = 0, 5 do D.items[i] = named("InventoryButton_" .. i) end
        D.resource = named("ResourceBarFrame")
        D.upper = named("UpperButtonBarFrame")
        D.invCover = named("SimpleInventoryCover")

        -- parents are only asked of frames below a known root: asking a
        -- top-level frame for its parent can crash the game
        local function isRoot(f)
            return f == nil or Kit.same(f, D.gameUI) or Kit.same(f, D.consoleUI) or Kit.same(f, D.world)
                or Kit.same(f, D.simpleRoot)
        end
        local function parent(f)
            if not Kit.valid(f) or isRoot(f) then return nil end
            local p = BlzFrameGetParent(f)
            return Kit.valid(p) and p or nil
        end
        D.invBar = parent(D.items[0])
        D.mapParent = parent(D.minimap)
        -- frames that live inside the console art bars must leave them before
        -- the bars are hidden (a few levels up at most)
        local function inBars(f)
            local p = parent(f)
            for _ = 1, 4 do
                if p == nil or isRoot(p) then return false end
                if Kit.same(p, D.bottomBar) or Kit.same(p, D.topBar) then return true end
                p = parent(p)
            end
            return false
        end
        D.inBars = {}
        local movers = {}
        for _, k in ipairs({"cmdBar", "invBar", "tooltip", "buffBar", "portrait"}) do
            D.inBars[k] = D[k] ~= nil and inBars(D[k])
            if D.inBars[k] then movers[#movers + 1] = D[k] end
        end
        -- Safety net: a frame the HUD keeps that would still be inside a bar
        -- after the moves (its way up meets a bar before a moved container)
        -- means the bars stay visible, so the command card is never hidden.
        local function trapped(f)
            local p = f
            for _ = 1, 6 do
                if p == nil or isRoot(p) then return false end
                for _, m in ipairs(movers) do
                    if Kit.same(p, m) then return false end
                end
                if Kit.same(p, D.bottomBar) or Kit.same(p, D.topBar) then return true end
                p = parent(p)
            end
            return false
        end
        D.keepBars = false
        for _, f in ipairs({D.cmd[0], D.items[0], D.minimap, D.portrait, D.tooltip}) do
            if f and not D.keepBars and trapped(f) then D.keepBars = true end
        end

        -- Reforged 2.0 ConsoleUI children: 0 top bar, 1 bottom bar, 2 resources,
        -- 3 menu buttons, 4 minimap buttons, 5 command card mouse dead zone.
        local dz = child(D.consoleUI, 5)
        for _, known in ipairs({D.topBar, D.bottomBar, D.resource, D.upper, D.heroBar, D.cmdBar}) do
            if Kit.same(dz, known) then dz = nil end
        end
        D.deadzone = dz
        -- Day/night clock: child 0 of the minimap's group (GAME_UI child 5).
        local group = child(D.gameUI, 5)
        if group and Kit.same(group, D.mapParent) then
            local c = child(group, 0)
            if c and not Kit.same(c, D.minimap) then D.clock = c end
        end
    end

    local function reparent(f, p)
        if Kit.valid(f) and Kit.valid(p) then BlzFrameSetParent(f, p) end
    end

    local function hide(f)
        if Kit.valid(f) then BlzFrameSetVisible(f, false) end
    end

    ---------------------------------------------------------------- geometry

    local G = {}

    local function geometry()
        S.L, S.R = Kit.edges()
        G.wide = S.L < -0.02
        G.edgeMap = L.MINIMAP_AT_SCREEN_EDGE and G.wide and Kit.valid(D.backdrop)
        G.mapX = G.edgeMap and (S.L + 0.004) or L.MAP_X
        G.mapR = G.mapX + L.MAP
        local abilL = L.ABIL_CX - L.ABIL_W / 2
        local statsL = abilL - L.PORT_W - L.STATS_W
        local shift = 0
        if not G.edgeMap then shift = math.max(0, G.mapR + 0.006 - statsL) end
        G.abilL = abilL + shift
        G.abilR = G.abilL + L.ABIL_W
        G.portL = G.abilL - L.PORT_W
        G.statsL = G.portL - L.STATS_W
        G.itemsL = G.abilR + 0.004
        G.itemsR = G.itemsL + L.ITEMS_W
        G.abilCX = (G.abilL + G.abilR) / 2
    end

    local function itemRect(i)
        local c, r = i % 3, i // 3
        local x0 = G.itemsL + 0.0055 + c * (L.ITEM_W + L.ITEM_GAP)
        local y1 = L.PANEL_H - 0.004 - r * (L.ITEM_H + L.ITEM_GAP)
        return x0, y1 - L.ITEM_H, x0 + L.ITEM_W, y1
    end

    local function rowRects(n)
        local inner = L.ABIL_W - 0.012
        local size = math.min(L.BTN, (inner - (n - 1) * L.BTN_GAP) / math.max(1, n))
        local total = n * size + (n - 1) * L.BTN_GAP
        local x0 = G.abilL + (L.ABIL_W - total) / 2
        local out = {}
        for k = 1, n do
            local x = x0 + (k - 1) * (size + L.BTN_GAP)
            out[k] = {x, L.BTN_Y, x + size, L.BTN_Y + size}
        end
        return out
    end

    local function gridRect(i)
        local c, r = i % 4, i // 4
        local x0 = G.abilR - 0.006 - 4 * L.GRID - 3 * 0.002
        local y1 = L.PANEL_H - 0.005 - r * (L.GRID + 0.002)
        local x = x0 + c * (L.GRID + 0.002)
        return x, y1 - L.GRID, x + L.GRID, y1
    end

    ---------------------------------------------------------------- building

    -- Every frame is created here, for every player, hidden until the local
    -- view decides. Layers: bg (child of ConsoleUIBackdrop: below the WC3
    -- buttons), simple (SimpleFrames: bars), fg (child of the game UI: texts
    -- and our buttons, above everything).
    local function build()
        local C = Kit.C
        local gameUI = D.gameUI or BlzGetOriginFrame(ORIGIN_FRAME_GAME_UI, 0)
        F.bgBelow = Kit.valid(D.backdrop)
        F.bgRoot = Kit.frame(F.bgBelow and D.backdrop or gameUI)
        F.fgRoot = Kit.frame(gameUI)
        F.bgBottom, F.bgTop = Kit.frame(F.bgRoot), Kit.frame(F.bgRoot)
        F.fgBottom, F.fgTop = Kit.frame(F.fgRoot), Kit.frame(F.fgRoot)
        local simpleParent = D.consoleUI or BlzGetOriginFrame(ORIGIN_FRAME_SIMPLE_UI_PARENT, 0)
        F.simBottom, F.simTop = Kit.simple(simpleParent), Kit.simple(simpleParent)
        for _, f in ipairs({F.bgRoot, F.fgRoot, F.simBottom, F.simTop}) do BlzFrameSetVisible(f, false) end

        -- bottom backgrounds (only below the WC3 buttons, never over them)
        if F.bgBelow then
            F.panelBg = Kit.backdrop(F.bgBottom, Kit.tex("ability_bg", C.dark), Kit.dota and 255 or 225)
            F.itemsBg = Kit.backdrop(F.bgBottom, Kit.tex("inventory_bg", C.dark), Kit.dota and 255 or 225)
            F.mapBg = Kit.backdrop(F.bgBottom, Kit.tex("minimap_bg", C.dark), Kit.dota and 255 or 225)
            F.wells = {}
            for i = 1, 12 do F.wells[i] = Kit.backdrop(F.bgBottom, Kit.tex("ability_bevel", C.dark), Kit.dota and 255 or 170) end
            F.itemWells = {}
            for i = 0, 5 do F.itemWells[i] = Kit.backdrop(F.bgBottom, Kit.tex("item_well", C.dark), Kit.dota and 255 or 170) end
        end
        F.hpBg = Kit.backdrop(F.bgBottom, C.dark, 220)
        F.mpBg = Kit.backdrop(F.bgBottom, C.dark, 220)
        F.xpBg = Kit.backdrop(F.bgBottom, C.dark, 220)

        -- bars
        F.hp = Kit.bar(F.simBottom, Kit.tex("hp_fill", C.green))
        F.mp = Kit.bar(F.simBottom, Kit.tex("mana_fill", C.blue))
        F.xp = Kit.bar(F.simBottom, C.gold)

        -- texts and our buttons
        F.hpText = Kit.text(F.fgBottom, 0.85)
        F.hpRegen = Kit.text(F.fgBottom, 0.75, TEXT_JUSTIFY_RIGHT)
        F.mpText = Kit.text(F.fgBottom, 0.8)
        F.mpRegen = Kit.text(F.fgBottom, 0.7, TEXT_JUSTIFY_RIGHT)
        F.name = Kit.text(F.fgBottom, 0.75)
        F.levelBg = Kit.backdrop(F.fgBottom, Kit.tex("level_bg", C.dark), 235)
        F.level = Kit.text(F.fgBottom, 0.9)
        F.dead = Kit.backdrop(F.fgBottom, C.dark, 170)
        F.deadText = Kit.text(F.fgBottom, 1.5)
        F.statIcons, F.statTexts = {}, {}
        local icons = {
            Kit.tex("icon_damage", Kit.btn("BTNClawsOfAttack")), Kit.tex("icon_armor", Kit.btn("BTNHelmutPurple")),
            Kit.tex("icon_speed", Kit.btn("BTNBootsOfSpeed")), Kit.tex("icon_str", Kit.btn("BTNGauntletsOfOgrePower")),
            Kit.tex("icon_agi", Kit.btn("BTNSlippersOfAgility")), Kit.tex("icon_int", Kit.btn("BTNMantleOfIntelligence")),
        }
        for i = 1, 6 do
            F.statIcons[i] = Kit.backdrop(F.fgBottom, icons[i])
            F.statTexts[i] = Kit.text(F.fgBottom, 0.72, TEXT_JUSTIFY_LEFT)
        end
        F.learn, F.learnImg, F.learnText, F.pips, F.mana, F.cd = {}, {}, {}, {}, {}, {}
        for k = 1, ROW_MAX do
            F.learn[k], F.learnImg[k] = Kit.button(F.fgBottom, Kit.tex("levelup_button", C.gold))
            F.learnText[k] = Kit.label(F.learn[k], 1.1)
            -- white on Dota's dark gold, dark on the bright fallback yellow
            Kit.setText(F.learnText[k], Kit.dota and "|cffffffff+|r" or "|cff202020+|r")
            F.pips[k] = {}
            for j = 1, PIPS do F.pips[k][j] = Kit.backdrop(F.fgBottom, Kit.tex("pip_off", C.dark)) end
            F.mana[k] = Kit.text(F.fgBottom, 0.62, TEXT_JUSTIFY_RIGHT, TEXT_JUSTIFY_BOTTOM)
            F.cd[k] = Kit.text(F.fgBottom, 1.25)       -- cooldown seconds over the button
        end
        F.goldIcon = Kit.backdrop(F.fgBottom, Kit.tex("gold", Kit.btn("BTNChestOfGold")))
        F.gold = Kit.text(F.fgBottom, 1.0, TEXT_JUSTIFY_LEFT)
        F.shopBtn, F.shopImg = Kit.button(F.fgBottom, Kit.tex("shop_button", C.gold))
        F.shopText = Kit.label(F.shopBtn, 0.85)
        Kit.setText(F.shopText, Kit.dota and "|cffffe6a0SHOP|r" or "|cff202020SHOP|r")
        -- our own item buttons over the slots: icon, charges, use (dota_items)
        F.itemBtns, F.itemIcons, F.itemCharges = {}, {}, {}
        for i = 0, 5 do
            F.itemBtns[i], F.itemIcons[i] = Kit.button(F.fgBottom, C.dark)
            F.itemCharges[i] = Kit.label(F.itemBtns[i], 0.75, TEXT_JUSTIFY_RIGHT, TEXT_JUSTIFY_BOTTOM)
            Kit.show(F.itemBtns[i], false)
        end
        -- selected-units bar (see updateSelection)
        F.sel = {}
        for i = 1, SEL_MAX do
            local s = {}
            s.b, s.img = Kit.button(F.fgBottom, C.dark)
            s.hpBg = Kit.backdrop(F.fgBottom, C.dark, 230)
            s.hp = Kit.backdrop(F.fgBottom, C.green)
            for _, f in ipairs({s.b, s.hpBg, s.hp}) do Kit.show(f, false) end
            F.sel[i] = s
        end

        -- top bar
        F.topBg = Kit.backdrop(F.bgTop, Kit.tex("top_bar_bg", C.dark), Kit.dota and 255 or 200)
        F.cmdBg = Kit.backdrop(F.bgTop, Kit.tex("top_bar_bg", C.dark), Kit.dota and 255 or 200)
        F.clockBg = Kit.backdrop(F.bgTop, Kit.tex("timer_bg", C.dark), Kit.dota and 255 or 220)
        F.clock = Kit.text(F.fgTop, 1.25)
        F.dayIcon = Kit.backdrop(F.fgTop, Kit.tex("icon_sun", Kit.btn("BTNOrbOfFire")))
        F.top = {}
        for i = 1, 5 do
            local t = {}
            t.icon = Kit.backdrop(F.fgTop, Kit.btn("BTNHeroPaladin"))
            t.label = Kit.text(F.fgTop, 0.6)
            t.dead = Kit.backdrop(F.fgTop, C.dark, 170)
            t.timer = Kit.text(F.fgTop, 0.95)
            t.hpBg = Kit.backdrop(F.bgTop, C.dark, 230)
            t.hp = Kit.bar(F.simTop, Kit.tex("hp_fill", C.green))
            t.mp = Kit.bar(F.simTop, Kit.tex("mana_fill", C.blue))
            F.top[i] = t
        end
        F.cmdIcon = Kit.backdrop(F.fgTop, Kit.btn("BTNTownHall"))
        F.cmdName = Kit.text(F.fgTop, 0.8, TEXT_JUSTIFY_LEFT)
        F.cmdInfo = Kit.text(F.fgTop, 0.68, TEXT_JUSTIFY_LEFT)
    end

    ---------------------------------------------------------------- placement (local)

    local function placeBottom()
        local P = L.PANEL_H
        if F.bgBelow then
            Kit.place(F.panelBg, G.statsL, 0, G.abilR, P)
            Kit.place(F.itemsBg, G.itemsL - 0.002, 0, G.itemsR, P + 0.004)
            Kit.place(F.mapBg, G.mapX - 0.006, 0, G.mapR + 0.006, L.MAP_Y + L.MAP + 0.006)
            for i = 0, 5 do
                local x0, y0, x1, y1 = itemRect(i)
                Kit.place(F.itemWells[i], x0 - 0.001, y0 - 0.001, x1 + 0.001, y1 + 0.001)
            end
        end
        for i = 0, 5 do Kit.place(F.itemBtns[i], itemRect(i)) end
        -- portrait column
        local pl, pr = G.portL + 0.004, G.portL + L.PORT_W - 0.004
        Kit.place(F.xpBg, pl, 0.005, pr, 0.012)
        Kit.place(F.xp, pl + 0.001, 0.006, pr - 0.001, 0.011)
        Kit.placeText(F.name, pl, P - 0.017, pr, P - 0.005)
        Kit.place(F.levelBg, pl - 0.002, 0.013, pl + 0.020, 0.035)
        Kit.placeText(F.level, pl - 0.002, 0.013, pl + 0.020, 0.035)
        Kit.place(F.dead, pl, 0.016, pr, P - 0.004)
        Kit.placeText(F.deadText, pl, 0.016, pr, P - 0.004)
        -- stats column: damage, armor, speed, str, agi, int
        for i = 1, 6 do
            local y1 = P - 0.006 - (i - 1) * 0.0152
            local y0 = y1 - 0.0125
            Kit.place(F.statIcons[i], G.statsL + 0.006, y0, G.statsL + 0.0185, y1)
            Kit.placeText(F.statTexts[i], G.statsL + 0.021, y0, G.portL - 0.002, y1)
        end
        -- gold and shop button under the items
        Kit.place(F.goldIcon, G.itemsL + 0.006, 0.010, G.itemsL + 0.024, 0.030)
        Kit.placeText(F.gold, G.itemsL + 0.026, 0.010, G.itemsL + 0.068, 0.030)
        Kit.place(F.shopBtn, G.itemsR - 0.054, 0.009, G.itemsR - 0.005, 0.032)
    end

    -- HP/mana bars span the ability area (row mode) or its left part (grid).
    local function placeBars(grid)
        local x0 = G.abilL + 0.006
        local x1 = grid and (G.abilR - 0.006 - 4 * L.GRID - 3 * 0.002 - 0.006) or (G.abilR - 0.006)
        Kit.place(F.hpBg, x0, L.HP_Y, x1, L.HP_Y + L.HP_H)
        Kit.place(F.hp, x0 + 0.001, L.HP_Y + 0.001, x1 - 0.001, L.HP_Y + L.HP_H - 0.001)
        Kit.placeText(F.hpText, x0, L.HP_Y, x1, L.HP_Y + L.HP_H)
        Kit.placeText(F.hpRegen, x0, L.HP_Y, x1 - 0.003, L.HP_Y + L.HP_H)
        Kit.place(F.mpBg, x0, L.MP_Y, x1, L.MP_Y + L.MP_H)
        Kit.place(F.mp, x0 + 0.001, L.MP_Y + 0.001, x1 - 0.001, L.MP_Y + L.MP_H - 0.001)
        Kit.placeText(F.mpText, x0, L.MP_Y, x1, L.MP_Y + L.MP_H)
        Kit.placeText(F.mpRegen, x0, L.MP_Y, x1 - 0.003, L.MP_Y + L.MP_H)
    end

    local function park(f, i)
        local x = 0.05 * i
        Kit.place(f, x, L.PARK_Y, x + 0.03, L.PARK_Y + 0.03)
    end

    -- Command card: one Dota row for a hero, the 4 x 3 grid for anything else.
    local function applyCommands(mode, key)
        S.mode, S.key = mode, key
        local used = {}
        if mode == "row" then
            local row = rowOf(key)
            local rects = rowRects(#row)
            S.n, S.rects = #row, rects
            -- the cell of each slot: an ability's own cell (local: Rubick moves
            -- stolen spells for their owner), then the spare cells for Dota's
            -- empty slots
            local cellOf = {}
            for k, e in ipairs(row) do
                if not e.empty then
                    local idx = BlzGetAbilityPosY(e.id) * 4 + BlzGetAbilityPosX(e.id)
                    if idx >= 0 and idx <= 11 and not used[idx] then
                        used[idx], cellOf[k] = true, idx
                    end
                end
            end
            for k, e in ipairs(row) do
                if e.empty then
                    for _, idx in ipairs(L.SPARE_CELLS) do
                        if not used[idx] then
                            used[idx], cellOf[k] = true, idx
                            break
                        end
                    end
                end
            end
            S.cellOf = cellOf
            for k = 1, #row do
                local r = rects[k]
                local idx = cellOf[k]
                if idx and D.cmd[idx] then Kit.place(D.cmd[idx], r[1], r[2], r[3], r[4]) end
                if F.wells then
                    Kit.place(F.wells[k], r[1] - 0.003, r[2] - 0.003, r[3] + 0.003, r[4] + 0.003)
                    Kit.show(F.wells[k], true)
                end
                local w = r[3] - r[1]
                Kit.place(F.learn[k], r[1] + w * 0.08, r[4] + 0.002, r[3] - w * 0.08, r[4] + 0.002 + L.LEARN_H)
                Kit.placeText(F.mana[k], r[1], r[2] + 0.001, r[3] - 0.002, r[2] + 0.010)
                Kit.placeText(F.cd[k], r[1], r[2], r[3], r[4])
                local pw = (w - 0.002 * (PIPS - 1)) / PIPS
                for j = 1, PIPS do
                    local px = r[1] + (j - 1) * (pw + 0.002)
                    Kit.place(F.pips[k][j], px, r[2] - 0.0015 - L.PIP_H, px + pw, r[2] - 0.0015)
                end
            end
            for i = 0, 11 do
                if D.cmd[i] and not used[i] then park(D.cmd[i], i) end
            end
            if F.wells then
                for k = #row + 1, 12 do Kit.show(F.wells[k], false) end
            end
        else
            S.n, S.rects, S.cellOf = 0, {}, {}
            for i = 0, 11 do
                local x0, y0, x1, y1 = gridRect(i)
                if D.cmd[i] then Kit.place(D.cmd[i], x0, y0, x1, y1) end
                if F.wells then
                    Kit.place(F.wells[i + 1], x0 - 0.002, y0 - 0.002, x1 + 0.002, y1 + 0.002)
                    Kit.show(F.wells[i + 1], true)
                end
            end
        end
        placeBars(mode ~= "row")
    end

    local function placeTop()
        local cx, top = 0.4, 0.6
        local cl, cr = cx - L.CLOCK_W / 2, cx + L.CLOCK_W / 2
        Kit.place(F.clockBg, cl, top - L.CLOCK_H, cr, top)
        Kit.placeText(F.clock, cl, top - L.CLOCK_H, cr, top)
        Kit.place(F.dayIcon, cx - 0.008, top - L.CLOCK_H - 0.016, cx + 0.008, top - L.CLOCK_H)
        -- hero portraits right-aligned to the clock; they shrink if the menu
        -- buttons (top-left) leave less room
        local right = cl - 0.004
        local left = (G.menuR or 0.0) + 0.004
        local w = math.max(0.02, math.min(L.HERO_W, (right - left - 4 * L.HERO_GAP) / 5))
        local h = L.HERO_H * w / L.HERO_W
        local x0 = right - (5 * w + 4 * L.HERO_GAP)
        Kit.place(F.topBg, x0 - 0.004, top - h - 0.012, right + 0.003, top)
        for i = 1, 5 do
            local t = F.top[i]
            local x = x0 + (i - 1) * (w + L.HERO_GAP)
            local y1 = top - 0.002
            local y0 = y1 - h
            Kit.place(t.icon, x, y0, x + w, y1)
            Kit.place(t.dead, x, y0, x + w, y1)
            Kit.placeText(t.timer, x, y0, x + w, y1)
            Kit.placeText(t.label, x, y0, x + w, y1)
            Kit.place(t.hpBg, x, y0 - 0.0068, x + w, y0 - 0.0008)
            Kit.place(t.hp, x + 0.0005, y0 - 0.0038, x + w - 0.0005, y0 - 0.001)
            Kit.place(t.mp, x + 0.0005, y0 - 0.0066, x + w - 0.0005, y0 - 0.0043)
        end
        -- commander block right of the clock
        local c0 = cr + 0.004
        Kit.place(F.cmdBg, c0 - 0.003, top - 0.031, c0 + L.CMD_W, top)
        Kit.place(F.cmdIcon, c0, top - 0.026, c0 + 0.024, top - 0.002)
        Kit.placeText(F.cmdName, c0 + 0.027, top - 0.014, c0 + L.CMD_W, top - 0.002)
        Kit.placeText(F.cmdInfo, c0 + 0.027, top - 0.027, c0 + L.CMD_W, top - 0.014)
    end

    -- Inventory; re-applied with the command card, since the game can move
    -- these buttons again when the selection changes.
    local function placeInventory()
        if D.invBar then Kit.place(D.invBar, G.itemsL, 0.040, G.itemsR, L.PANEL_H - 0.003) end
        for i = 0, 5 do
            if D.items[i] then Kit.place(D.items[i], itemRect(i)) end
        end
    end

    -- Warcraft III frames the HUD keeps, moved into the Dota layout.
    local mapKey = nil
    local function placeDefaults()
        local P = L.PANEL_H
        local key = string.format("%.3f", G.mapX)
        if D.minimap and mapKey ~= key then
            -- placed once per layout: re-placing the minimap can break its clicks
            mapKey = key
            if G.edgeMap then
                reparent(D.minimap, D.backdrop)
                BlzFrameSetLevel(D.minimap, 2)
            end
            Kit.place(D.minimap, G.mapX, L.MAP_Y, G.mapR, L.MAP_Y + L.MAP)
            for i = 0, 4 do
                local f = D.mmButtons[i]
                if f then
                    local y1 = L.MAP_Y + L.MAP - i * 0.0165
                    if G.edgeMap then
                        Kit.place(f, G.mapR + 0.003, y1 - 0.015, G.mapR + 0.018, y1)
                    else
                        Kit.place(f, G.mapX - 0.017, y1 - 0.015, G.mapX - 0.002, y1)
                    end
                end
            end
        end
        if D.portrait then
            Kit.place(D.portrait, G.portL + 0.004, 0.016, G.portL + L.PORT_W - 0.004, P - 0.004)
        end
        placeInventory()
        if D.tooltip then
            BlzFrameClearAllPoints(D.tooltip)
            BlzFrameSetAbsPoint(D.tooltip, FRAMEPOINT_BOTTOM, G.abilCX, P + L.TOOLTIP_DY)
        end
        if D.buffBar and L.SHOW_BUFFS then
            BlzFrameClearAllPoints(D.buffBar)
            BlzFrameSetAbsPoint(D.buffBar, FRAMEPOINT_BOTTOMLEFT, G.abilL + 0.004, P + 0.004)
        end
    end

    -- The menu buttons (Quests, Menu, Allies, Log) keep the top-left corner:
    -- the screen's left edge on wide screens (SimpleFrames may leave 4:3),
    -- the 4:3 left edge otherwise. They are placed on every layout, so a
    -- resize back to 4:3 also brings them back. G.menuR is their right edge;
    -- the top bar's hero icons keep clear of it.
    local function placeMenu()
        local w, h = 0, 0
        if D.upper then w, h = BlzFrameGetWidth(D.upper), BlzFrameGetHeight(D.upper) end
        local known = w ~= nil and h ~= nil and w > 0.01 and h > 0.004
        local x = 0.0
        if known then
            -- the size is read before the points are cleared and set again
            -- (both anchors removed would leave the frame without a size)
            if L.MOVE_MENU_TO_EDGE and G.wide then x = S.L + 0.004 end
            BlzFrameClearAllPoints(D.upper)
            BlzFrameSetAbsPoint(D.upper, FRAMEPOINT_TOPLEFT, x, 0.6)
            BlzFrameSetSize(D.upper, w, h)
        end
        G.menuR = x + (known and w or L.MENU_W)
    end

    -- Hides the console art and the WC3 panels the HUD replaces. Local.
    local function applyDefaults()
        BlzEnableUIAutoPosition(false)
        -- Reforged 2.0: the art lives in ConsoleTopBar/ConsoleBottomBar, which
        -- also hold the command card, inventory and tooltip; move those out
        -- first (frames inside the bars are SimpleFrames, like ConsoleUI)
        for _, k in ipairs({"cmdBar", "invBar", "tooltip", "buffBar", "portrait"}) do
            if D.inBars[k] and (k ~= "buffBar" or L.SHOW_BUFFS) then reparent(D[k], D.consoleUI) end
        end
        if D.keepBars then
            Log.warn("dota_hud: a kept frame is still inside the console bars; the WC3 console art stays")
        else
            hide(D.topBar)
            hide(D.bottomBar)
            hide(D.bottomOverlay)
        end
        hide(D.resource)          -- gold/lumber/food/upkeep
        hide(D.clock)             -- WC3 day/night clock (the top bar has one)
        hide(D.deadzone)          -- invisible click blocker of the old command card
        if D.invCover then BlzFrameSetAlpha(D.invCover, 0) end
        if D.world and D.gameUI then BlzFrameSetAllPoints(D.world, D.gameUI) end
        if D.backdrop then
            -- the black strip turns invisible; it still keeps clicks off the panel
            BlzFrameSetAlpha(D.backdrop, 0)
            if L.BLOCK_BOTTOM_CLICKS then
                BlzFrameClearAllPoints(D.backdrop)
                BlzFrameSetAbsPoint(D.backdrop, FRAMEPOINT_BOTTOMLEFT, S.L, 0)
                BlzFrameSetAbsPoint(D.backdrop, FRAMEPOINT_TOPRIGHT, S.R, L.PANEL_H)
            else
                BlzFrameSetSize(D.backdrop, 0, 0.0001)
            end
            BlzFrameSetAlpha(F.bgRoot, 255)
        end
    end

    -- Everything that depends on the local screen; re-run on aspect changes.
    local function layout()
        if view ~= "dota" then return end
        geometry()
        placeMenu()
        placeDefaults()
        placeBottom()
        applyCommands(S.mode or "grid", S.key)
        if D.backdrop and L.BLOCK_BOTTOM_CLICKS then
            BlzFrameClearAllPoints(D.backdrop)
            BlzFrameSetAbsPoint(D.backdrop, FRAMEPOINT_BOTTOMLEFT, S.L, 0)
            BlzFrameSetAbsPoint(D.backdrop, FRAMEPOINT_TOPRIGHT, S.R, L.PANEL_H)
        end
        placeTop()
    end

    ---------------------------------------------------------------- updates (local)

    local function focusUnit(lp)
        -- the unit Tab made active, while it stays selected
        if S.tabFocus and GetUnitTypeId(S.tabFocus) ~= 0 and IsUnitSelected(S.tabFocus, lp) then
            return S.tabFocus
        end
        local best, rank = nil, 0
        GroupClear(selGroup)
        GroupEnumUnitsSelected(selGroup, lp, nil)
        for i = 0, BlzGroupGetSize(selGroup) - 1 do
            local u = BlzGroupUnitAt(selGroup, i)
            if u then
                local r = 1
                if GetOwningPlayer(u) == lp then r = heroKeyOf(u) and 3 or 2 end
                if r > rank then best, rank = u, r end
            end
        end
        GroupClear(selGroup)
        return best or heroes().bySlot[GetPlayerId(lp)]
    end

    local function alive(u)
        return u ~= nil and GetUnitTypeId(u) ~= 0 and not IsUnitType(u, UNIT_TYPE_DEAD)
    end

    local function primaryOf(key)
        local info = key and use("data.heroes")[key]
        local p = info and info.stats and info.stats.AttributePrimary or ""
        if string.find(p, "STRENGTH") then return 4 end
        if string.find(p, "AGILITY") then return 5 end
        return 6
    end

    local function attr(u, i, bonus)
        if i == 4 then return GetHeroStr(u, bonus) end
        if i == 5 then return GetHeroAgi(u, bonus) end
        return GetHeroInt(u, bonus)
    end

    local function updateStats(u, key, hero)
        local Mods = use("mods")
        local prim = hero and primaryOf(key) or 0
        local base = BlzGetUnitBaseDamage(u, 0) + BlzGetUnitDiceNumber(u, 0) * (BlzGetUnitDiceSides(u, 0) + 1) / 2
        local bonus = Mods.sum(u, "damage")
        if hero then
            local b, t = attr(u, prim, false), attr(u, prim, true)
            base, bonus = base + b, bonus + (t - b)
        end
        local dmg = Kit.int(base)
        if math.abs(bonus) >= 0.5 then dmg = dmg .. Kit.color(GREEN, " +" .. Kit.int(bonus)) end
        Kit.setText(F.statTexts[1], dmg)
        Kit.setText(F.statTexts[2], string.format("%.1f", BlzGetUnitArmor(u)))
        Kit.setText(F.statTexts[3], Kit.int(GetUnitMoveSpeed(u)))
        for i = 1, 3 do              -- hidden while nothing was focused
            Kit.show(F.statIcons[i], true)
            Kit.show(F.statTexts[i].box, true)
        end
        for i = 4, 6 do
            Kit.show(F.statIcons[i], hero)
            Kit.show(F.statTexts[i].box, hero)
            if hero then
                local b, t = attr(u, i, false), attr(u, i, true)
                local s = (i == prim) and Kit.color(GOLD, tostring(b)) or tostring(b)
                if t ~= b then s = s .. Kit.color(GREEN, " +" .. (t - b)) end
                Kit.setText(F.statTexts[i], s)
            end
        end
    end

    local function updateBars(u, key, hero)
        local Mods = use("mods")
        local life, maxLife = GetWidgetLife(u), BlzGetUnitMaxHP(u)
        local mana, maxMana = GetUnitState(u, UNIT_STATE_MANA), BlzGetUnitMaxMana(u)
        Kit.setValue(F.hp, maxLife > 0 and life / maxLife or 0)
        Kit.setText(F.hpText, Kit.int(math.max(0, life)) .. " / " .. Kit.int(maxLife))
        local hpr = BlzGetUnitRealField(u, UNIT_RF_HIT_POINTS_REGENERATION_RATE)
            + Mods.sum(u, "hp_regen") * (1 + Mods.sum(u, "heal_amp"))
        local mpr = BlzGetUnitRealField(u, UNIT_RF_MANA_REGENERATION) + Mods.sum(u, "mana_regen")
        if hero then
            hpr = hpr + GetHeroStr(u, true) * STR_REGEN
            mpr = mpr + GetHeroInt(u, true) * INT_REGEN
        end
        Kit.setText(F.hpRegen, Kit.color(GREEN, string.format("+%.1f", hpr)))
        local hasMana = maxMana > 0
        Kit.show(F.mp, hasMana)
        Kit.show(F.mpBg, hasMana)
        Kit.show(F.mpText.box, hasMana)
        Kit.show(F.mpRegen.box, hasMana)
        if hasMana then
            Kit.setValue(F.mp, mana / maxMana)
            Kit.setText(F.mpText, Kit.int(mana) .. " / " .. Kit.int(maxMana))
            Kit.setText(F.mpRegen, Kit.color(BLUE, string.format("+%.1f", mpr)))
        end
        -- level and experience
        local level = hero and GetHeroLevel(u) or GetUnitLevel(u)
        Kit.setText(F.level, Kit.color(GOLD, tostring(level)))
        Kit.show(F.xp, hero)
        Kit.show(F.xpBg, hero)
        if hero then
            local lo = NEED_XP[level - 1] or 0
            local hi = NEED_XP[level]
            Kit.setValue(F.xp, hi and (GetHeroXP(u) - lo) / math.max(1, hi - lo) or 1)
        end
        Kit.setText(F.name, GetUnitName(u) or "")
    end

    local function updateRow(u, key, lp)
        local row = rowOf(key) or {}
        local H = heroes()
        local main = H.bySlot[GetPlayerId(lp)]
        local own = GetOwningPlayer(u) == lp and main ~= nil and heroKeyOf(main) == key
        local points = own and GetHeroSkillPoints(main) or 0
        for k = 1, ROW_MAX do
            local e = row[k]
            Kit.show(F.learn[k], e ~= nil and points > 0 and canLearn(main, e))
            local id = e and e.id
            local level = id and GetUnitAbilityLevel(u, id) or 0
            for j = 1, PIPS do
                local on = e ~= nil and j <= e.max and e.max > 1
                Kit.show(F.pips[k][j], on)
                if on then
                    Kit.setTex(F.pips[k][j], j <= level and Kit.tex("pip_on", Kit.C.gold) or Kit.tex("pip_off", Kit.C.dark))
                end
            end
            local cost = (id and level > 0) and BlzGetUnitAbilityManaCost(u, id, level - 1) or 0
            Kit.show(F.mana[k].box, cost > 0)
            if cost > 0 then Kit.setText(F.mana[k], Kit.color(BLUE, tostring(cost))) end
            -- seconds left, over WC3's own cooldown sweep
            local cd = (id and level > 0) and BlzGetUnitAbilityCooldownRemaining(u, id) or 0
            Kit.show(F.cd[k].box, cd > 0.05)
            if cd > 0.05 then Kit.setText(F.cd[k], Kit.color("ffffff", tostring(math.ceil(cd)))) end
        end
    end

    local function hideRowExtras()
        for k = 1, ROW_MAX do
            Kit.show(F.learn[k], false)
            Kit.show(F.mana[k].box, false)
            Kit.show(F.cd[k].box, false)
            for j = 1, PIPS do Kit.show(F.pips[k][j], false) end
        end
    end

    -- Item buttons drawn from the unit's items: the native item buttons show
    -- no icons and take no clicks or hotkeys once the console bars are hidden
    -- (2026-10-10); using items goes through dota_items.
    local function updateItems(u)
        for i = 0, 5 do
            local it = u and UnitItemInSlot(u, i) or nil
            local path = it and BlzGetItemIconPath(it) or ""
            Kit.show(F.itemBtns[i], path ~= "")
            if path ~= "" then Kit.setTex(F.itemIcons[i], path) end
            local n = (it and path ~= "") and GetItemCharges(it) or 0
            Kit.setText(F.itemCharges[i], n > 0 and tostring(n) or "")
        end
    end

    -- Dota's bar of selected units above the ability row, shown while the
    -- player has two or more of their own units selected (Meepos, summons).
    local selList = {}
    -- own selected units in a stable order (by handle id), so the bar and Tab
    -- cycling do not jump when the selection is rebuilt
    local function ownSelection(lp, out)
        local n = 0
        GroupClear(selGroup)
        GroupEnumUnitsSelected(selGroup, lp, nil)
        for i = 0, BlzGroupGetSize(selGroup) - 1 do
            local u = BlzGroupUnitAt(selGroup, i)
            if u and GetOwningPlayer(u) == lp and n < SEL_MAX then
                n = n + 1
                out[n] = u
            end
        end
        GroupClear(selGroup)
        for i = n + 1, SEL_MAX do out[i] = nil end
        table.sort(out, function(a, b) return GetHandleId(a) < GetHandleId(b) end)
        return n
    end

    local function updateSelection(lp, focus)
        local n = ownSelection(lp, selList)
        local size, gap = L.SEL_SIZE, 0.003
        local x = G.abilCX - (n * size + (n - 1) * gap) / 2
        local y0 = L.PANEL_H + 0.008
        for i = 1, SEL_MAX do
            local s, u = F.sel[i], selList[i]
            local on = n >= 2 and u ~= nil
            Kit.show(s.b, on)
            Kit.show(s.hpBg, on)
            Kit.show(s.hp, on)
            if on then
                local x0 = x + (i - 1) * (size + gap)
                Kit.place(s.b, x0, y0 + 0.005, x0 + size, y0 + 0.005 + size)
                local key = heroKeyOf(u)
                local icon = key and (Kit.dota and Kit.btn("BTNDota_hero_" .. key) or Kit.btn("BTNHeroPaladin"))
                    or Kit.btn("BTNFootman")
                Kit.setTex(s.img, icon)
                BlzFrameSetAlpha(s.img, u == focus and 255 or 140)   -- the unit Tab made active
                local frac = math.max(0, math.min(1, GetWidgetLife(u) / math.max(1, BlzGetUnitMaxHP(u))))
                Kit.place(s.hpBg, x0, y0, x0 + size, y0 + 0.004)
                Kit.place(s.hp, x0, y0, x0 + math.max(0.0005, size * frac), y0 + 0.004)
            end
        end
    end
    Hud.selected = selList

    local function updateBottom(lp, now)
        local u = focusUnit(lp)
        if BUILD_TEST_MODE and u ~= S.lastFocus then
            -- local log of each new focus, flushed at once: names the unit if a crash follows
            S.lastFocus = u
            Log.info("hud focus " .. (u and (GetUnitName(u) .. " " .. GetUnitTypeId(u)) or "none"))
            Log.flush()
        end
        local key = heroKeyOf(u)
        local mode = key and "row" or "grid"
        S.ticks = S.ticks + 1
        if mode ~= S.mode or key ~= S.key or S.dirty or S.ticks % 30 == 0 then
            applyCommands(mode, key)
            placeInventory()
            S.dirty = false
        end
        local has = u ~= nil and GetUnitTypeId(u) ~= 0
        for _, f in ipairs({F.hp, F.hpBg, F.hpText.box, F.hpRegen.box, F.name.box, F.level.box, F.levelBg}) do
            Kit.show(f, has)
        end
        if has then
            local hero = IsUnitType(u, UNIT_TYPE_HERO)
            updateBars(u, key, hero)
            updateStats(u, key, hero)
            local isDead = IsUnitType(u, UNIT_TYPE_DEAD)
            Kit.show(F.dead, isDead)
            Kit.show(F.deadText.box, isDead)
            if isDead then
                local main = heroes().bySlot[GetPlayerId(GetOwningPlayer(u))]
                local at = respawnAt[u] or (main and respawnAt[main])
                Kit.setText(F.deadText, at and Kit.color("ff7070", tostring(math.max(0, math.ceil(at - now)))) or "")
            end
        else
            for i = 1, 6 do
                Kit.show(F.statIcons[i], false)
                Kit.show(F.statTexts[i].box, false)
            end
            Kit.show(F.xp, false)
            Kit.show(F.xpBg, false)
            Kit.show(F.dead, false)
            Kit.show(F.deadText.box, false)
            Kit.show(F.mp, false)
            Kit.show(F.mpBg, false)
            Kit.show(F.mpText.box, false)
            Kit.show(F.mpRegen.box, false)
        end
        if mode == "row" and has then updateRow(u, key, lp) else hideRowExtras() end
        Kit.setText(F.gold, Kit.color(GOLD, tostring(GetPlayerState(lp, PLAYER_STATE_RESOURCE_GOLD))))
        updateItems(has and u or nil)
        updateSelection(lp, u)
    end

    local RACE_ICON = {human = "BTNTownHall", orc = "BTNGreathall", undead = "BTNNecropolis", nightelf = "BTNTreeOfLife"}
    local RACE_NAME = {human = "Human", orc = "Orc", undead = "Undead", nightelf = "Night Elf"}

    local function updateTop(now)
        local H = heroes()
        local slots = Roles.heroSlots or {}
        for i = 1, 5 do
            local t = F.top[i]
            local slot = slots[i]
            local u = slot and H.bySlot[slot]
            local key = u and H.keyOf[u]
            if key ~= t.key then
                t.key = key
                if key and Kit.dota then
                    Kit.setTex(t.icon, Kit.btn("BTNDota_hero_" .. key))
                    Kit.setText(t.label, "")
                else
                    Kit.setTex(t.icon, key and Kit.btn("BTNHeroPaladin") or Kit.C.dark)
                    local title = key and use("data.heroes")[key] and use("data.heroes")[key].title or ""
                    Kit.setText(t.label, string.sub(title, 1, 5))
                end
            end
            local up = alive(u)
            Kit.show(t.hp, up)
            Kit.show(t.mp, up)
            if up then
                Kit.setValue(t.hp, GetWidgetLife(u) / math.max(1, BlzGetUnitMaxHP(u)))
                local mm = BlzGetUnitMaxMana(u)
                Kit.setValue(t.mp, mm > 0 and GetUnitState(u, UNIT_STATE_MANA) / mm or 0)
            end
            local down = u ~= nil and not up
            Kit.show(t.dead, down or u == nil)
            Kit.show(t.timer.box, down)
            if down then
                local at = respawnAt[u]
                Kit.setText(t.timer, at and Kit.color("ffffff", tostring(math.max(0, math.ceil(at - now)))) or "")
            end
        end
        Kit.setText(F.clock, Kit.clock(use("world").clock()))   -- Dota's 0:00 is world.init()
        local tod = GetFloatGameState(GAME_STATE_TIME_OF_DAY)
        local day = tod >= 6 and tod < 18
        Kit.setTex(F.dayIcon, day and Kit.tex("icon_sun", Kit.btn("BTNOrbOfFire")) or Kit.tex("icon_moon", Kit.btn("BTNMoonStone")))
        -- commander
        local race = use("commander").raceKey
        Kit.setTex(F.cmdIcon, Kit.btn(RACE_ICON[race] or "BTNTownHall"))
        local name = "Commander"
        if Roles.commander ~= nil then
            name = Roles.commanderIsAI and "Commander (AI)" or GetPlayerName(Player(Roles.commander))
        end
        Kit.setText(F.cmdName, Kit.color(RED, name))
        Kit.setText(F.cmdInfo, Kit.color(GRAY, (RACE_NAME[race] or "") .. "  halls " .. halls))
    end

    local lastW, lastH = -1, -1
    local function update()
        if view ~= "dota" then return end
        local now = Timer.now()
        local w, h = BlzGetLocalClientWidth(), BlzGetLocalClientHeight()
        if w ~= lastW or h ~= lastH then
            lastW, lastH = w, h
            layout()
        end
        local lp = GetLocalPlayer()
        updateBottom(lp, now)
        use("dota_shop").update(lp)
        updateTop(now)
    end
    Hud.tick = update

    ---------------------------------------------------------------- views

    -- "dota" for hero players; nil (Warcraft III UI) for the commander,
    -- observers and everyone else.
    function Hud.viewOf(p)
        if IsPlayerObserver(p) then return nil end
        local id = GetPlayerId(p)
        if id ~= SLOT_ANCIENTS and Roles.side(id) == "dota" then return "dota" end
        return nil
    end

    -- Local: shows this client's HUD and reshapes the WC3 UI for hero players.
    local function applyView()
        if view == "dota" then
            applyDefaults()
            Kit.show(F.bgRoot, true)
            Kit.show(F.fgRoot, true)
            Kit.show(F.simBottom, true)
            Kit.show(F.simTop, true)
            layout()
        end
        use("dota_shop").applyView(view)
    end
    Hud.applyView = applyView

    ---------------------------------------------------------------- synced events

    local function onLearn(k)
        local p = GetTriggerPlayer()
        local H = heroes()
        local hero = H.bySlot[GetPlayerId(p)]
        if hero then
            local e = (rowOf(H.keyOf[hero]) or {})[k]
            if e and GetHeroSkillPoints(hero) > 0 and canLearn(hero, e) then
                SelectHeroSkill(hero, e.id)
            end
        end
        if p == GetLocalPlayer() then
            -- give the keyboard back to the game (a clicked button keeps focus)
            BlzFrameSetEnable(Kit.hit(F.learn[k]), false)
            BlzFrameSetEnable(Kit.hit(F.learn[k]), true)
            S.dirty = true
        end
    end
    Hud.onLearn = onLearn

    local function registerEvents()
        for k = 1, ROW_MAX do
            local trig = CreateTrigger()
            -- labelled buttons take clicks on their click layer (Kit.hit)
            BlzTriggerRegisterFrameEvent(trig, Kit.hit(F.learn[k]), FRAMEEVENT_CONTROL_CLICK)
            TriggerAddAction(trig, function() Safe.call(onLearn, k) end)
        end
        Kit.probe(F.shopBtn, "hud shop button")
        for k in pairs(F.learn) do Kit.probe(F.learn[k], "hud learn " .. k) end
        -- items: click a slot or press Z X C V B N (dota_items)
        local Use = use("dota_items")
        for i = 0, 5 do
            local hit = Kit.hit(F.itemBtns[i])
            Kit.probe(F.itemBtns[i], "item slot " .. i)
            local trig = CreateTrigger()
            BlzTriggerRegisterFrameEvent(trig, hit, FRAMEEVENT_CONTROL_CLICK)
            TriggerAddAction(trig, function()
                Safe.call(function()
                    local p = GetTriggerPlayer()
                    Use.use(p, i)
                    if p == GetLocalPlayer() then
                        BlzFrameSetEnable(hit, false)
                        BlzFrameSetEnable(hit, true)
                    end
                end)
            end)
        end
        local dotaSlots = {}
        for slot = 0, SLOT_DOTA_MAX do dotaSlots[#dotaSlots + 1] = slot end
        Use.init(dotaSlots)
        -- Tab as in Dota: the next of the selected units becomes the active one.
        -- WC3's own Tab only steps between unit types, so all Meepos stayed put.
        local tabList = {}
        local tabTrig = CreateTrigger()
        for slot = 0, bj_MAX_PLAYERS - 1 do
            BlzTriggerRegisterPlayerKeyEvent(tabTrig, Player(slot), OSKEY_TAB, 0, true)
        end
        TriggerAddAction(tabTrig, function()
            Safe.call(function()
                local lp = GetTriggerPlayer()
                if lp ~= GetLocalPlayer() or view ~= "dota" then return end
                local n = ownSelection(lp, tabList)
                if n < 2 then return end
                local cur, idx = focusUnit(lp), 0
                for i = 1, n do if tabList[i] == cur then idx = i end end
                local nextU = tabList[idx % n + 1]
                S.tabFocus = nextU
                -- reselect with the new active unit first (selection is local)
                ClearSelection()
                SelectUnit(nextU, true)
                for i = 1, n do
                    if tabList[i] ~= nextU then SelectUnit(tabList[i], true) end
                end
                S.dirty = true
            end)
        end)
        -- a click on a unit of the selected-units bar selects just that unit
        for i = 1, SEL_MAX do
            local hit = Kit.hit(F.sel[i].b)
            local trig = CreateTrigger()
            BlzTriggerRegisterFrameEvent(trig, hit, FRAMEEVENT_CONTROL_CLICK)
            TriggerAddAction(trig, function()
                Safe.call(function()
                    if GetTriggerPlayer() ~= GetLocalPlayer() then return end
                    local u = selList[i]
                    if u and GetUnitTypeId(u) ~= 0 then
                        ClearSelection()
                        SelectUnit(u, true)
                    end
                    BlzFrameSetEnable(hit, false)
                    BlzFrameSetEnable(hit, true)
                end)
            end)
        end
        local shopTrig = CreateTrigger()
        BlzTriggerRegisterFrameEvent(shopTrig, Kit.hit(F.shopBtn), FRAMEEVENT_CONTROL_CLICK)
        TriggerAddAction(shopTrig, function()
            Safe.call(function()
                local p = GetTriggerPlayer()
                if p == GetLocalPlayer() then
                    BlzFrameSetEnable(Kit.hit(F.shopBtn), false)
                    BlzFrameSetEnable(Kit.hit(F.shopBtn), true)
                end
                use("dota_shop").toggle(p)
            end)
        end)
        local H = heroes()
        Events.on("death", function(dying)
            if H.keyOf[dying] then respawnAt[dying] = Timer.now() + H.respawnTime(GetHeroLevel(dying)) end
        end)
        Events.on("hero_respawned", function(u) respawnAt[u] = nil end)
        Events.on("hero_level", function() S.dirty = true end)
        Events.on("hero_skill", function() S.dirty = true end)
        -- commander town halls, counted for every player (creates a group)
        Timer.every(1, function()
            local Cmd = use("commander")
            if Cmd.player then halls = Cmd.halls() end
        end)
    end

    ---------------------------------------------------------------- init

    function Hud.init()
        if Hud.started then return end
        Hud.started = true
        Kit.detect()
        for key in pairs(use("data.heroes")) do
            local code = use("data.ids").heroes[key]
            if code then keyByType[FourCC(code)] = key end
        end
        selGroup = CreateGroup()
        acquire()
        build()
        use("dota_shop").init({fg = F.fgRoot, bg = F.bgRoot, D = D})
        registerEvents()
        view = Hud.viewOf(GetLocalPlayer())
        Safe.call(applyView)
        -- One timer for everyone; the work inside is local. An error never
        -- stops the shared timer (that would destroy a handle on one client
        -- only); after a few errors this client just stops updating the HUD.
        Timer.every(L.TICK, function()
            if view and failures < 5 then
                if not Safe.call(update) then failures = failures + 1 end
            end
        end)
        local found = 0
        for i = 0, 11 do if D.cmd[i] then found = found + 1 end end
        local items = 0
        for i = 0, 5 do if D.items[i] then items = items + 1 end end
        local moved = {}
        for _, k in ipairs({"cmdBar", "invBar", "tooltip", "buffBar", "portrait"}) do
            if D.inBars[k] then moved[#moved + 1] = k end
        end
        Log.info(string.format("dota_hud: view %s, dota art %s, cmd %d/12, items %d/6, portrait %s, minimap %s, "
            .. "bars %s/%s, tooltip %s, backdrop %s, clock %s, deadzone %s, menu %s, out of the bars: %s%s",
            tostring(view), tostring(Kit.dota), found, items,
            tostring(D.portrait ~= nil), tostring(D.minimap ~= nil), tostring(D.topBar ~= nil),
            tostring(D.bottomBar ~= nil), tostring(D.tooltip ~= nil), tostring(D.backdrop ~= nil),
            tostring(D.clock ~= nil), tostring(D.deadzone ~= nil), tostring(D.upper ~= nil),
            #moved > 0 and table.concat(moved, " ") or "none", D.keepBars and " (bars kept)" or ""))
    end

    Hud.D, Hud.F, Hud.S = D, F, S
    function Hud.view() return view end
    return Hud
end)
