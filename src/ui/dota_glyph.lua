-- Dota's Glyph and Scan buttons by the minimap's top right, the buyback
-- button (with its cost) while the hero is dead, and Dota's red error line,
-- for the Dota players' HUD (dota_hud.lua). Buttons live under the HUD's
-- bottom click blocker; clicks, Scan targeting (the next left click on the
-- ground, right click cancels) and tooltips run on synced events. The team
-- state is structures.lua's (Glyph), lane.lua's (Scan) and economy.lua's
-- (buyback); this module only shows it.
--
-- Start after use("dota_hud").init(): use("dota_glyph").init().
define("dota_glyph", function()
    local Kit = use("hud_kit")
    local Log = use("log")
    local Timer = use("timer")
    local Roles = use("roles")
    local Safe = use("safe")
    local G = {started = false}

    G.L = {
        TICK = 0.1,
        BTN = 0.022, GAP = 0.002, PAD = 0.008,  -- Glyph over Scan, right of the minimap's top
        BUY_W = 0.074, BUY_H = 0.022, BUY_Y = 0.034,   -- buyback: above the item block's right end and its stash row
        ERR_W = 0.42, ERR_H = 0.022, ERR_Y = 0.21, ERR_TIME = 3,
        TIP_W = 0.2, TIP_H = 0.07,
    }
    local GOLD, GRAY, RED = "ffcc00", "a0a0a0", "ff4040"

    local F = {}
    G.F = F
    G.armed = {}             -- slot -> true while the player picks a Scan target (synced)
    local errUntil = 0       -- local: the error line hides at this time
    local tipFor = nil       -- local: the button whose tooltip shows
    local placedKey = nil    -- local: geometry the buttons were placed for

    local function hud() return use("dota_hud") end

    local function build()
        local Hud = hud()
        local parent, root = Hud.F.fgBottom, Hud.F.fgRoot
        F.glyph = Kit.button(parent, Kit.btn("BTNGlyph"))
        F.glyphCd = Kit.sweep(F.glyph)
        -- an empty label for its click layer: the sweep's seconds text would take the mouse
        Kit.label(F.glyph, 0.7)
        F.scan = Kit.button(parent, Kit.btn("BTNReveal"))
        F.scanCd = Kit.sweep(F.scan)
        F.scanArmed = Kit.backdrop(F.scan, Kit.C.gold, 110)
        BlzFrameSetAllPoints(F.scanArmed, F.scan)
        F.scanCharges = Kit.label(F.scan, 0.7, TEXT_JUSTIFY_RIGHT, TEXT_JUSTIFY_BOTTOM)
        F.buy = Kit.button(parent, Kit.C.dark)
        F.buyText = Kit.label(F.buy, 0.8)
        F.err = Kit.text(root, 1.1)
        F.tipBg = Kit.backdrop(root, Kit.C.dark, 235)
        F.tip = Kit.text(root, 0.75, TEXT_JUSTIFY_LEFT, TEXT_JUSTIFY_TOP)
        for _, f in ipairs({F.scanArmed, F.buy, F.err.box, F.tipBg, F.tip.box}) do Kit.show(f, false) end
    end

    ---------------------------------------------------------------- local display

    -- Dota's error line for one player: every client runs it, one shows it.
    function G.error(p, msg)
        if p ~= GetLocalPlayer() then return end
        Kit.setText(F.err, Kit.color(RED, msg))
        errUntil = Timer.now() + G.L.ERR_TIME
        Kit.show(F.err.box, true)
    end

    -- The same line in white, for hints.
    function G.hint(p, msg)
        if p ~= GetLocalPlayer() then return end
        Kit.setText(F.err, msg)
        errUntil = Timer.now() + G.L.ERR_TIME
        Kit.show(F.err.box, true)
    end

    local function place()
        local Hud = hud()
        local g, L = Hud.G, Hud.L
        local s, x0, top = G.L.BTN, g.mapR + G.L.PAD, L.MAP_Y + L.MAP
        Kit.place(F.glyph, x0, top - s, x0 + s, top)
        Kit.placeSweep(F.glyphCd, x0, top - s, x0 + s, top)
        local y1 = top - s - G.L.GAP
        Kit.place(F.scan, x0, y1 - s, x0 + s, y1)
        Kit.placeSweep(F.scanCd, x0, y1 - s, x0 + s, y1)
        local y0 = L.PANEL_H + G.L.BUY_Y
        Kit.place(F.buy, g.itemsR - G.L.BUY_W, y0, g.itemsR, y0 + G.L.BUY_H)
        Kit.placeText(F.err, 0.4 - G.L.ERR_W / 2, G.L.ERR_Y, 0.4 + G.L.ERR_W / 2, G.L.ERR_Y + G.L.ERR_H)
    end

    local function cooldownLine(left)
        local Lane = use("lane")
        if left <= 0 then return Kit.color("80ff80", Lane.text("DOTA_Tooltip_glyph_cooldown_ready")) end
        return Kit.color(GRAY, Lane.text("DOTA_Tooltip_glyph_cooldown", Kit.clock(left)))
    end

    -- Tooltip text and the rectangle of the button it belongs to.
    local function tooltip(lp)
        local Lane, E, S = use("lane"), use("economy"), use("structures")
        if tipFor == F.glyph then
            return Kit.color(GOLD, Lane.text("DOTA_Tooltip_ability_fountain_glyph")) .. "|n"
                .. Lane.text("DOTA_Tooltip_ability_fountain_glyph_Description") .. "|n" .. cooldownLine(S.glyphLeft())
        elseif tipFor == F.scan then
            local left = Lane.scanLeft()
            return Kit.color(GOLD, Lane.text("DOTA_Tooltip_ability_radar")) .. "  " .. Lane.scanCharges .. "|n"
                .. Lane.text("DOTA_Tooltip_ability_radar_Description") .. "|n"
                .. cooldownLine(Lane.scanCharges > 0 and 0 or left)
        elseif tipFor == F.buy then
            return Kit.color(GOLD, Lane.text("DOTA_Tooltip_ability_fountain_buyback")) .. "|n"
                .. Lane.text("DOTA_Tooltip_ability_fountain_buyback_Description") .. "|n"
                .. Lane.text("DOTA_StatTooltip_Buyback", E.buybackCost(lp)) .. "|n"
                .. Kit.color(GRAY, Lane.text("DOTA_Tooltip_modifier_buyback_gold_penalty_Description"))
        end
        return nil
    end

    local function updateTip(lp)
        local text = tipFor and tooltip(lp)
        Kit.show(F.tipBg, text ~= nil)
        Kit.show(F.tip.box, text ~= nil)
        if not text then return end
        Kit.setText(F.tip, text)
        local g, L = hud().G, hud().L
        local x0, y0
        if tipFor == F.buy then
            x0, y0 = g.itemsR - G.L.TIP_W, L.PANEL_H + G.L.BUY_Y + G.L.BUY_H + 0.004
        else
            x0, y0 = g.mapR + G.L.PAD, L.MAP_Y + L.MAP + 0.004
        end
        Kit.place(F.tipBg, x0, y0, x0 + G.L.TIP_W, y0 + G.L.TIP_H)
        Kit.placeText(F.tip, x0 + 0.005, y0 + 0.004, x0 + G.L.TIP_W - 0.005, y0 + G.L.TIP_H - 0.004)
    end

    local function update()
        local Hud = hud()
        if Hud.view() ~= "dota" then return end
        local key = string.format("%.4f %.4f", Hud.G.mapR or 0, Hud.G.itemsR or 0)
        if key ~= placedKey then
            placedKey = key
            place()
        end
        local lp = GetLocalPlayer()
        local S, Lane, E = use("structures"), use("lane"), use("economy")
        Kit.setSweep(F.glyphCd, S.glyphLeft(), S.glyphTotal())
        local left, total = Lane.scanLeft()
        Kit.setSweep(F.scanCd, Lane.scanCharges > 0 and 0 or left, total)
        Kit.setText(F.scanCharges, Lane.scanCharges > 0 and Kit.color("ffffff", tostring(Lane.scanCharges)) or "")
        Kit.show(F.scanArmed, G.armed[GetPlayerId(lp)] == true)
        local dead = E.deadHero(lp) ~= nil
        Kit.show(F.buy, dead)
        if dead then
            local cd = E.buybackLeft(lp)
            if cd > 0 then
                Kit.setText(F.buyText, Kit.color(GRAY, Lane.text("DOTA_StatTooltip_Buyback_Cooldown", Kit.clock(cd))))
            else
                local cost = E.buybackCost(lp)
                local afford = GetPlayerState(lp, PLAYER_STATE_RESOURCE_GOLD) >= cost
                Kit.setText(F.buyText, Kit.color(afford and GOLD or GRAY, Lane.text("DOTA_Buyback") .. "  " .. cost))
            end
        elseif tipFor == F.buy then
            tipFor = nil
        end
        if errUntil > 0 and Timer.now() >= errUntil then
            errUntil = 0
            Kit.show(F.err.box, false)
        end
        updateTip(lp)
    end
    G.tick = update

    ---------------------------------------------------------------- synced events

    local function onClick(frame, fn)
        local hit = Kit.hit(frame)
        local trig = CreateTrigger()
        BlzTriggerRegisterFrameEvent(trig, hit, FRAMEEVENT_CONTROL_CLICK)
        TriggerAddAction(trig, function()
            Safe.call(function()
                local p = GetTriggerPlayer()
                if p == GetLocalPlayer() then
                    -- give the keyboard back to the game (a clicked button keeps focus)
                    BlzFrameSetEnable(hit, false)
                    BlzFrameSetEnable(hit, true)
                end
                fn(p)
            end)
        end)
    end

    local function onHover(frame)
        local hit = Kit.hit(frame)
        local trig = CreateTrigger()
        BlzTriggerRegisterFrameEvent(trig, hit, FRAMEEVENT_MOUSE_ENTER)
        BlzTriggerRegisterFrameEvent(trig, hit, FRAMEEVENT_MOUSE_LEAVE)
        TriggerAddAction(trig, function()
            Safe.call(function()
                if GetTriggerPlayer() ~= GetLocalPlayer() then return end
                if BlzGetTriggerFrameEvent() == FRAMEEVENT_MOUSE_ENTER then
                    tipFor = frame
                elseif tipFor == frame then
                    tipFor = nil
                end
                updateTip(GetLocalPlayer())
            end)
        end)
    end

    -- Scan: the button arms targeting, the next left click on the ground
    -- scans there, a right click (or the button again) cancels.
    function G.armScan(p)
        local slot = GetPlayerId(p)
        if G.armed[slot] then
            G.armed[slot] = nil
            return
        end
        if use("lane").scanCharges <= 0 then
            use("lane").error(p, "dota_hud_error_cant_radar")
            return
        end
        G.armed[slot] = true
        G.hint(p, use("lane").text("dvc_scan_target"))
    end

    -- A mouse button of an armed player: x, y are 0, 0 over the HUD.
    function G.mouse(p, button, x, y)
        local slot = GetPlayerId(p)
        if not G.armed[slot] then return false end
        if button == MOUSE_BUTTON_TYPE_RIGHT then
            G.armed[slot] = nil
            return false
        end
        if x == 0 and y == 0 then return false end
        G.armed[slot] = nil
        return use("lane").scan(p, x, y)
    end

    local function registerEvents()
        onClick(F.glyph, function(p) use("structures").glyph(p) end)
        onClick(F.scan, G.armScan)
        onClick(F.buy, function(p) use("economy").buyback(p) end)
        for _, f in ipairs({F.glyph, F.scan, F.buy}) do onHover(f) end
        Kit.probe(F.glyph, "glyph button")
        Kit.probe(F.scan, "scan button")
        Kit.probe(F.buy, "buyback button")
        -- mouse events only after the game started (they crash while the map loads)
        local trig = CreateTrigger()
        for _, slot in ipairs(Roles.heroSlots) do
            if Roles.humans[slot] then TriggerRegisterPlayerEvent(trig, Player(slot), EVENT_PLAYER_MOUSE_DOWN) end
        end
        TriggerAddAction(trig, function()
            Safe.call(function()
                G.mouse(GetTriggerPlayer(), BlzGetTriggerPlayerMouseButton(),
                    BlzGetTriggerPlayerMouseX(), BlzGetTriggerPlayerMouseY())
            end)
        end)
    end

    function G.init()
        if G.started then return end
        local Hud = hud()
        if not Hud.started or not Hud.F.fgBottom then
            Log.warn("dota_glyph: start it after dota_hud")
            return
        end
        G.started = true
        build()
        registerEvents()
        -- one shared timer; its work is local, an error stops only this client's display
        local failures = 0
        Timer.every(G.L.TICK, function()
            if failures < 5 and not Safe.call(update) then failures = failures + 1 end
        end)
        Log.info("dota_glyph: Glyph, Scan and buyback buttons")
    end

    return G
end)
