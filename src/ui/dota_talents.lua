-- Dota's talent tree and Aghanim's sign around the ability row of the hero
-- players' HUD (dota_hud.lua):
--   left   the talent tree button. Its branches light up for the talents
--          taken, and it glows while one can be taken. Hovering shows the
--          tree; a click opens it for picking (another click or Esc closes
--          it, and so does the last pick). Below the four tiers sits the
--          Attribute Bonus.
--   right  Aghanim's Scepter (top) and Shard (bottom), lit when the hero has
--          them; hovering lists the hero's upgrades (data.heroes "upgrades").
-- The tree shows the focused unit's hero; picks act on the clicking player's
-- own hero only (the buttons are switched off for anyone else's tree).
-- Multiplayer: every frame is made for every player in init(); clicks and
-- keys are synced events that run talents.lua; the rest is local view state.
-- Start right after use("dota_hud").init(): use("dota_talents").init().
define("dota_talents", function()
    local Kit = use("hud_kit")
    local Safe = use("safe")
    local Timer = use("timer")
    local Log = use("log")
    local DT = {started = false}

    local L = {
        TICK = 0.1,
        PANEL_W = 0.270,                 -- the tree panel above the ability area
        ROW_H = 0.027, ROW_GAP = 0.003,  -- one tier: left talent | level | right talent
        BADGE = 0.022, PAD = 0.006,
        ATTR_H = 0.024,                  -- Attribute Bonus row under the tiers
        TIP_W = 0.230, TIP_H = 0.100,    -- Aghanim's upgrades tooltip
        SIDES = {"left", "right"},
    }
    DT.L = L
    local GOLD, GRAY, WHITE, GREEN = "ffcc00", "a0a0a0", "ffffff", "40ff40"

    local F = {}
    -- local view: the hero shown, whether the tree is pinned open, the
    -- placed layout and the glow's phase
    local V = {pinned = false, hero = nil, placed = nil, phase = 0, failures = 0}
    DT.F, DT.V = F, V

    local function T() return use("talents") end
    local function Hud() return use("dota_hud") end

    local function talentAt(key, tier, side)
        for _, t in ipairs(T().list(key)) do
            if t.tier == tier and t.side == side then return t end
        end
        return nil
    end
    DT.talentAt = talentAt

    ---------------------------------------------------------------- building (all players)

    local function build(parent)
        local C = Kit.C
        -- the glow: Dota's lit button over the tree, or a gold rim behind it
        F.rim = Kit.backdrop(parent, C.gold, 200)
        F.tree, F.treeImg = Kit.button(parent, Kit.tex("talent_button", Kit.btn("BTNSkillz")))
        -- marks and the glow are the button's children: they never take its mouse
        F.marks = {}
        for tier = 1, 4 do
            F.marks[tier] = {}
            for _, side in ipairs(L.SIDES) do F.marks[tier][side] = Kit.backdrop(F.tree, C.gold) end
        end
        F.glow = Kit.backdrop(F.tree, Kit.tex("talent_glow", C.gold), 160)
        F.treeHover = Kit.frame(parent)
        BlzFrameSetTooltip(F.tree, F.treeHover)

        F.panel = Kit.blocker(parent)
        F.panelBg = Kit.backdrop(F.panel, Kit.tex("talent_bg", C.dark), Kit.dota and 245 or 230)
        F.rows = {}
        for tier = 1, 4 do
            local r = {}
            for _, side in ipairs(L.SIDES) do
                local b, img = Kit.button(F.panel, Kit.tex("talent_" .. side, C.dark))
                r[side] = {b = b, img = img, text = Kit.label(b, 0.6)}
            end
            r.badge = Kit.backdrop(F.panel, Kit.tex("level_bg", C.dark))
            r.level = Kit.text(F.panel, 0.78)
            F.rows[tier] = r
        end
        F.attr, F.attrImg = Kit.button(F.panel, Kit.tex("talent_attr", C.dark))
        F.attrText = Kit.label(F.attr, 0.62, TEXT_JUSTIFY_LEFT)
        F.attrPips = {}
        for i = 1, 7 do F.attrPips[i] = Kit.backdrop(F.attr, Kit.tex("pip_off", C.dark)) end

        F.scepter, F.scepterImg = Kit.button(parent, Kit.tex("aghs_scepter_off", Kit.btn("BTNScepterOfMastery")))
        F.shard, F.shardImg = Kit.button(parent, Kit.tex("aghs_shard_off", Kit.btn("BTNGem")))
        F.scepterHover, F.shardHover = Kit.frame(parent), Kit.frame(parent)
        BlzFrameSetTooltip(F.scepter, F.scepterHover)
        BlzFrameSetTooltip(F.shard, F.shardHover)
        F.tip = Kit.frame(parent)
        F.tipBg = Kit.backdrop(F.tip, Kit.tex("aghs_tooltip_bg", C.dark), 240)
        F.tipText = Kit.text(F.tip, 0.66, TEXT_JUSTIFY_LEFT, TEXT_JUSTIFY_TOP)

        for _, f in ipairs({F.rim, F.tree, F.panel, F.scepter, F.shard, F.tip}) do Kit.show(f, false) end
    end

    ---------------------------------------------------------------- placement (local)

    -- Around the ability row: dota_hud reserves L.TREE_W on its left and
    -- L.AGHS_W on its right (rowRects).
    local function layout()
        local H = Hud()
        local G, HL = H.G, H.L
        local r = H.S.rects and H.S.rects[1]
        local y0 = r and r[2] or HL.BTN_Y
        local y1 = r and r[4] or (HL.BTN_Y + HL.BTN)
        local key = string.format("%.4f:%.4f:%.4f", G.abilL or 0, G.abilR or 0, y1)
        if V.placed == key or not G.abilL then return end
        V.placed = key
        local h = y1 - y0
        local tx0 = G.abilL + 0.006
        local tx1 = tx0 + HL.TREE_W
        Kit.place(F.tree, tx0, y0, tx1, y1)
        Kit.place(F.glow, tx0, y0, tx1, y1)
        Kit.place(F.rim, tx0 - 0.002, y0 - 0.002, tx1 + 0.002, y1 + 0.002)
        local w = tx1 - tx0
        for tier = 1, 4 do
            local my0 = y0 + h * (0.08 + 0.22 * (tier - 1))
            local my1 = my0 + h * 0.1
            Kit.place(F.marks[tier].left, tx0 + w * 0.12, my0, tx0 + w * 0.44, my1)
            Kit.place(F.marks[tier].right, tx0 + w * 0.56, my0, tx0 + w * 0.88, my1)
        end
        local ax1 = G.abilR - 0.006
        local ax0 = ax1 - HL.AGHS_W
        Kit.place(F.scepter, ax0, y0 + h * 0.4, ax1, y1)
        Kit.place(F.shard, ax0, y0, ax1, y0 + h * 0.36)
        local P = HL.PANEL_H
        Kit.place(F.tip, ax1 - L.TIP_W, P + 0.004, ax1, P + 0.004 + L.TIP_H)
        Kit.place(F.tipBg, ax1 - L.TIP_W, P + 0.004, ax1, P + 0.004 + L.TIP_H)
        Kit.placeText(F.tipText, ax1 - L.TIP_W + 0.008, P + 0.010, ax1 - 0.008, P + L.TIP_H - 0.002)

        local px0, px1 = G.abilL, G.abilL + L.PANEL_W
        local py0 = P + 0.004
        local py1 = py0 + 2 * L.PAD + L.ATTR_H + L.ROW_GAP + 4 * (L.ROW_H + L.ROW_GAP)
        Kit.place(F.panel, px0, py0, px1, py1)
        Kit.place(F.panelBg, px0, py0, px1, py1)
        local cw = (L.PANEL_W - 2 * L.PAD - L.BADGE - 0.008) / 2
        for tier = 1, 4 do
            local ry1 = py1 - L.PAD - (4 - tier) * (L.ROW_H + L.ROW_GAP)
            local ry0 = ry1 - L.ROW_H
            local row = F.rows[tier]
            Kit.place(row.left.b, px0 + L.PAD, ry0, px0 + L.PAD + cw, ry1)
            local bx0 = px0 + L.PAD + cw + 0.004
            local by0 = ry0 + (L.ROW_H - L.BADGE) / 2
            Kit.place(row.badge, bx0, by0, bx0 + L.BADGE, by0 + L.BADGE)
            Kit.placeText(row.level, bx0, by0, bx0 + L.BADGE, by0 + L.BADGE)
            Kit.place(row.right.b, bx0 + L.BADGE + 0.004, ry0, px1 - L.PAD, ry1)
        end
        local ay0 = py0 + L.PAD
        Kit.place(F.attr, px0 + L.PAD, ay0, px1 - L.PAD, ay0 + L.ATTR_H)
        local pw = 0.007
        for i = 1, 7 do
            local x = px1 - L.PAD - 0.006 - (8 - i) * (pw + 0.002)
            Kit.place(F.attrPips[i], x, ay0 + 0.008, x + pw, ay0 + 0.016)
        end
    end

    ---------------------------------------------------------------- updates (local)

    local function texOf(name, on, fallback)
        if Kit.dota then return Kit.tex(name .. (on and "_on" or "_off"), fallback) end
        return fallback
    end

    local function fillPanel(hero, key, own)
        local Tal = T()
        for tier = 1, 4 do
            local row = F.rows[tier]
            Kit.setText(row.level, Kit.color(GOLD, tostring(Tal.TIER_LEVELS[tier])))
            for _, side in ipairs(L.SIDES) do
                local t = talentAt(key, tier, side)
                local c = row[side]
                Kit.show(c.b, t ~= nil)
                if t then
                    local picked = Tal.picked(hero, t.name)
                    local can = own and Tal.canPick(hero, t.name)
                    Kit.setText(c.text, Kit.color(picked and GOLD or (can and WHITE or GRAY), t.label))
                    Kit.setAlpha(c.img, picked and 255 or (can and 170 or 70))
                    BlzFrameSetEnable(Kit.hit(c.b), can)
                end
            end
        end
        local d = (use("data.heroes")[key] or {}).attribute_bonus
        local lvl = Tal.attrLevel(hero)
        local can = own and Tal.canLevelAttr(hero)
        local per = d and use("util").levelValue(d.value, 1) or 0
        Kit.setText(F.attrText, Kit.color(can and GREEN or GRAY, can and "+ " or "  ")
            .. Kit.color(WHITE, "Attribute Bonus") .. Kit.color(GRAY, string.format("  +%g All Attributes", per)))
        Kit.setAlpha(F.attrImg, can and 230 or 120)
        BlzFrameSetEnable(Kit.hit(F.attr), can)
        for i = 1, 7 do
            local on = d ~= nil and i <= d.max
            Kit.show(F.attrPips[i], on)
            if on then Kit.setTex(F.attrPips[i], i <= lvl and Kit.tex("pip_on", Kit.C.gold) or Kit.tex("pip_off", Kit.C.dark)) end
        end
    end

    local function tipText(hero, key)
        local Tal = T()
        local function part(title, on, text)
            local state = on and Kit.color(GREEN, " (owned)") or ""
            return Kit.color(on and GOLD or GRAY, title) .. state .. "|n" .. Kit.color(on and WHITE or GRAY, text)
        end
        return part("Aghanim's Scepter", Tal.hasScepter(hero), Tal.upgradeText(key, "scepter")) .. "|n|n"
            .. part("Aghanim's Shard", Tal.hasShard(hero), Tal.upgradeText(key, "shard"))
    end

    local function hideAll()
        for _, f in ipairs({F.rim, F.tree, F.panel, F.scepter, F.shard, F.tip}) do Kit.show(f, false) end
        V.pinned, V.hero = false, nil
    end

    local function update()
        local H = Hud()
        if H.view() ~= "dota" then return end
        local Tal = T()
        local u = H.S.unit
        local hero = nil
        if H.S.mode == "row" and u ~= nil and GetUnitTypeId(u) ~= 0 then hero = Tal.ownerOf(u) end
        local key = hero and Tal.keyOf(hero)
        if not key then
            hideAll()
            return
        end
        if hero ~= V.hero then
            V.hero, V.pinned = hero, false
        end
        layout()
        Kit.show(F.tree, true)
        Kit.show(F.scepter, true)
        Kit.show(F.shard, true)
        local lp = GetLocalPlayer()
        local own = use("heroes").bySlot[GetPlayerId(lp)] == hero
        for tier = 1, 4 do
            for _, side in ipairs(L.SIDES) do
                local t = talentAt(key, tier, side)
                Kit.show(F.marks[tier][side], t ~= nil and Tal.picked(hero, t.name))
            end
        end
        local glow = own and (Tal.available(hero) > 0 or Tal.canLevelAttr(hero))
        local lit = Kit.dota and F.glow or F.rim
        Kit.show(F.glow, glow and Kit.dota)
        Kit.show(F.rim, glow and not Kit.dota)
        if glow then
            V.phase = (V.phase + L.TICK) % 1.2
            Kit.setAlpha(lit, math.floor(120 + 135 * math.abs(math.sin(V.phase * math.pi / 1.2))))
        end
        local scep, shard = Tal.hasScepter(hero), Tal.hasShard(hero)
        Kit.setTex(F.scepterImg, texOf("aghs_scepter", scep, Kit.btn("BTNScepterOfMastery")))
        Kit.setTex(F.shardImg, texOf("aghs_shard", shard, Kit.btn("BTNGem")))
        if not Kit.dota then
            Kit.setAlpha(F.scepterImg, scep and 255 or 90)
            Kit.setAlpha(F.shardImg, shard and 255 or 90)
        end
        local tipOn = BlzFrameIsVisible(F.scepterHover) or BlzFrameIsVisible(F.shardHover)
        Kit.show(F.tip, tipOn)
        if tipOn then Kit.setText(F.tipText, tipText(hero, key)) end
        local open = V.pinned or BlzFrameIsVisible(F.treeHover)
        Kit.show(F.panel, open)
        if open then fillPanel(hero, key, own) end
    end
    DT.update = update

    ---------------------------------------------------------------- synced events

    local function ownHero(p) return use("heroes").bySlot[GetPlayerId(p)] end

    -- A clicked button keeps the keyboard focus: hand it back to the game.
    local function release(frame)
        BlzFrameSetEnable(frame, false)
        BlzFrameSetEnable(frame, true)
    end

    local function onClick(frame, fn)
        local hit = Kit.hit(frame)
        local trig = CreateTrigger()
        BlzTriggerRegisterFrameEvent(trig, hit, FRAMEEVENT_CONTROL_CLICK)
        TriggerAddAction(trig, function()
            Safe.call(function()
                local p = GetTriggerPlayer()
                fn(p)
                if p == GetLocalPlayer() then
                    release(hit)
                    update()
                end
            end)
        end)
    end

    function DT.pick(p, tier, side)
        local hero = ownHero(p)
        local key = hero and T().keyOf(hero)
        local t = key and talentAt(key, tier, side)
        if t and T().pick(hero, t.name) and p == GetLocalPlayer() then
            if T().available(hero) == 0 then V.pinned = false end
        end
    end

    local function registerEvents()
        onClick(F.tree, function(p)
            if p == GetLocalPlayer() then V.pinned = not V.pinned end
        end)
        for tier = 1, 4 do
            for _, side in ipairs(L.SIDES) do
                onClick(F.rows[tier][side].b, function(p) DT.pick(p, tier, side) end)
            end
        end
        onClick(F.attr, function(p)
            local hero = ownHero(p)
            if hero then T().levelAttr(hero) end
        end)
        local esc = CreateTrigger()
        for slot = 0, SLOT_DOTA_MAX do BlzTriggerRegisterPlayerKeyEvent(esc, Player(slot), OSKEY_ESCAPE, 0, true) end
        TriggerAddAction(esc, function()
            Safe.call(function()
                if GetTriggerPlayer() == GetLocalPlayer() then V.pinned = false end
            end)
        end)
        Kit.probe(F.tree, "talent tree")
        Kit.probe(F.scepter, "aghanim's scepter sign")
    end

    ---------------------------------------------------------------- init

    function DT.init()
        if DT.started then return end
        local H = Hud()
        if not H.started or not H.F.fgBottom then return end
        DT.started = true
        build(H.F.fgBottom)
        registerEvents()
        -- One timer for everyone; the work inside is local. After a few
        -- errors this client stops updating the tree.
        Timer.every(L.TICK, function()
            if V.failures < 5 and not Safe.call(update) then V.failures = V.failures + 1 end
        end)
        Log.info("dota_talents ready")
    end

    return DT
end)
