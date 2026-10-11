-- Dota 2 style shop panel for the hero players: BASICS / UPGRADES tabs with
-- the item categories of data.items (one column each), item icons with
-- prices (dimmed while unaffordable), a details pane for the hovered item
-- (cost, what you pay with the parts you carry, description, stats, recipe
-- parts with the carried ones dimmed) and a sell row for the hero's
-- inventory. Click an icon to buy. Open with the SHOP button or F4, close
-- with F4, Esc or X.
--
-- Rules are those of items.lua: buying and selling need the hero alive and
-- within Items.SHOP_RANGE of a shop (the fountain shops, secret shop
-- included); Items.purchase pays only for missing parts and refuses a full
-- inventory; selling is Items.sell (50 %). Items with a Dota stock (wards,
-- smoke, ...) keep a shared team stock here.
--
-- Multiplayer: clicks are synced frame events and keys synced key events;
-- purchases run in that synced code for the clicking player's hero. Opening,
-- tabs and hovering are local.
define("dota_shop", function()
    local Kit = use("hud_kit")
    local Safe = use("safe")
    local Timer = use("timer")
    local Shop = {}

    -- Panel geometry (4:3 screen units, see dota_hud.lua). The panel sits on
    -- the right, above the item block.
    local L = {
        RIGHT = 0.798, BOTTOM = 0.116,   -- bottom-right corner of the panel
        W = 0.372, H = 0.356,            -- panel size
        HEADER_H = 0.026,                -- title, tabs, range hint, close
        COL_TITLE_H = 0.013,             -- category name above each column
        ICON_W = 0.0275, ICON_H = 0.023, -- item icon cell (2 per column row)
        ICON_GAP = 0.0025,
        DETAIL_H = 0.120,                -- details of the hovered item
        SELL_H = 0.034,                  -- sell row
        COLUMNS = 6,                     -- categories per tab
        PARTS = 6,                       -- recipe part icons in the details
        KEY = OSKEY_F4,                  -- toggle key (Dota default)
    }
    Shop.L = L

    -- Built-in icons when the Dota item icons are not in the map.
    local CAT_ICON = {
        consumables = "BTNPotionGreenSmall", attributes = "BTNGauntletsOfOgrePower",
        equipment = "BTNThoriumMelee", misc = "BTNBootsOfSpeed", secret = "BTNOrbOfDarkness",
        relics = "BTNClawsOfAttack", accessories = "BTNRingGreen", support = "BTNMedalionOfCourage",
        magical = "BTNWand", armor = "BTNHelmutPurple", weapons = "BTNDaggerOfEscape",
        artifacts = "BTNRunedBracers",
    }
    local STAT_NAME = {
        str = "Strength", agi = "Agility", int = "Intelligence", damage = "Damage", armor = "Armor",
        attack_speed = "Attack Speed", hp_regen = "HP Regeneration", mana_regen = "Mana Regeneration",
        max_hp = "Health", max_mana = "Mana", move_flat = "Movement Speed", boots_ms = "Movement Speed",
        magic_resist = "Magic Resistance", evasion = "Evasion", spell_amp = "Spell Amplification",
        lifesteal = "Lifesteal",
    }
    local GOLD, GREEN, RED, GRAY = "ffcc00", "40ff40", "ff5050", "a0a0a0"

    local F = {}
    local cells = {}            -- every item button: {b, img, text, proxy, name, tab, ...}
    local sells = {}            -- 6 sell buttons
    local stock = {}            -- item name -> {count, at} (synced)
    -- local view state
    local open, tab, hovered, lastGold, view, ticks = false, 1, nil, -1, nil, 0
    local started = false
    Shop.F, Shop.cells, Shop.sells = F, cells, sells

    local function Items() return use("items") end
    local function data(name) return Items().data(name) end

    local function iconOf(name)
        local e = data(name)
        if Kit.dota then return Items().icon(e and e.result and "item_recipe" or name) end
        if e and e.result then return Kit.btn("BTNSnazzyScroll") end
        return Kit.btn(CAT_ICON[e and e.shop or ""] or "BTNChestOfGold")
    end
    Shop.iconOf = iconOf

    ---------------------------------------------------------------- stock (synced state)

    -- Available count right now, without changing the stored state.
    local function available(name, now)
        local st = (data(name) or {}).stock
        if not st then return nil end
        local max, t = st.max or 1, st.time or 0
        local s = stock[name]
        if not s then return math.min(max, st.initial or max) end
        if t <= 0 then return max end
        return math.min(max, s.count + math.floor((now - s.at) / t))
    end

    -- Synced only: settle the restock and take one.
    local function takeStock(name, now)
        local st = (data(name) or {}).stock
        if not st then return true end
        local max, t = st.max or 1, st.time or 0
        local s = stock[name]
        if not s then
            s = {count = math.min(max, st.initial or max), at = now}
            stock[name] = s
        end
        if t > 0 then
            local gained = math.floor((now - s.at) / t)
            if gained > 0 then
                s.count = math.min(max, s.count + gained)
                s.at = s.at + gained * t
            end
        else
            s.count = max
        end
        if s.count < 1 then return false end
        if s.count >= max then s.at = now end      -- restock timer starts below max
        s.count = s.count - 1
        return true
    end

    ---------------------------------------------------------------- synced actions

    local function heroOf(p)
        return use("heroes").bySlot[GetPlayerId(p)]
    end

    local function alive(u)
        return u ~= nil and GetUnitTypeId(u) ~= 0 and not IsUnitType(u, UNIT_TYPE_DEAD)
    end

    local function msg(p, s) Items().msg(p, s) end

    function Shop.buy(p, name)
        local e = data(name)
        local hero = heroOf(p)
        if BUILD_TEST_MODE then
            use("log").info(string.format("shop buy %s by %d: data %s, hero %s, near %s", tostring(name),
                GetPlayerId(p), tostring(e ~= nil), tostring(hero ~= nil),
                tostring(hero ~= nil and Items().nearShop(hero))))
            use("log").flush()
        end
        if not e or not hero then return false end
        if not alive(hero) then msg(p, "|cffff6060Your hero is dead.|r") return false end
        if not Items().nearShop(hero) then
            msg(p, "|cffff6060Too far from a shop|r - buy at the fountain.")
            return false
        end
        if e.stock and (available(name, Timer.now()) or 0) < 1 then
            msg(p, "|cffff6060" .. e.title .. " is out of stock.|r")
            return false
        end
        local ok, why = Items().purchase(hero, name)
        if ok then
            takeStock(name, Timer.now())
        elseif why == "gold" then
            msg(p, "|cffff6060Not enough gold|r for " .. e.title .. " (" .. Items().price(hero, name) .. ").")
        elseif why == "full" then
            msg(p, "|cffff6060Inventory full.|r")
        end
        return ok
    end

    function Shop.sell(p, slot)
        local hero = heroOf(p)
        if not hero or not alive(hero) then return 0 end
        if not Items().nearShop(hero) then
            msg(p, "|cffff6060Too far from a shop|r to sell.")
            return 0
        end
        local it = UnitItemInSlot(hero, slot)
        if not it or not Items().nameOf(it) then return 0 end
        local title = data(Items().nameOf(it)).title
        local before = GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD)
        Items().sell(hero, it)
        local gold = GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD) - before
        msg(p, "Sold " .. title .. " for |cffffcc00" .. gold .. "|r gold.")
        return gold
    end

    ---------------------------------------------------------------- local view

    local function show(on)
        open = on and view == "dota"
        Kit.show(F.root, open)
        lastGold = -1
    end

    function Shop.isOpen() return open end

    -- Called from synced click/key events: only the clicking player's screen changes.
    function Shop.toggle(p)
        if p == GetLocalPlayer() then show(not open) end
    end

    function Shop.close(p)
        if p == GetLocalPlayer() then show(false) end
    end

    local function setTab(i)
        tab = i
        for _, c in ipairs(cells) do Kit.show(c.b, c.tab == tab) end
        for t, list in ipairs(F.colTitles) do
            for _, tx in ipairs(list) do Kit.show(tx.box, t == tab) end
        end
        for t = 1, 2 do
            Kit.setAlpha(F.tabImg[t], t == tab and 255 or 110)
        end
        hovered, lastGold = nil, -1
    end

    function Shop.applyView(v)
        view = v
        show(false)
        if v == "dota" then setTab(1) end
    end

    local function sellValue(it)
        local name = Items().nameOf(it)
        local e = name and data(name)
        if not e then return 0 end
        local value = e.cost * 0.5
        if e.consumable then value = value * GetItemCharges(it) / math.max(1, e.charges or 1) end
        return math.floor(value + 0.5)     -- rounded like items.lua pays it
    end

    local function statLines(e)
        local out = {}
        local keys = {}
        for k in pairs(e.stats or {}) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = e.stats[k]
            if type(v) == "number" and v ~= 0 and #out < 4 then
                local label = STAT_NAME[k] or string.gsub(k, "_", " ")
                local num = (math.floor(v) == v) and tostring(math.floor(v)) or string.format("%.1f", v)
                out[#out + 1] = Kit.color(GREEN, "+" .. num) .. " " .. label
            end
        end
        return table.concat(out, "|n")
    end

    -- Gold this hero would pay now (upgrades reuse carried parts). Local reads.
    local function priceFor(hero, name)
        local e = data(name)
        if not e then return math.huge end
        if hero and e.recipe then return Items().price(hero, name) end
        return e.cost
    end

    local function details(name, hero, gold)
        local e = data(name)
        if not e then return end
        Kit.setTex(F.dIcon, iconOf(name))
        Kit.setText(F.dName, Kit.color(GOLD, e.title))
        local cost = "Cost " .. Kit.color(GOLD, tostring(e.cost))
        local pay = priceFor(hero, name)
        if pay < e.cost then cost = cost .. "   you pay " .. Kit.color(gold >= pay and GREEN or RED, tostring(pay)) end
        local n = available(name, Timer.now())
        if n then cost = cost .. "   stock " .. Kit.color(n > 0 and "ffffff" or RED, tostring(n)) end
        Kit.setText(F.dCost, cost)
        Kit.setText(F.dDesc, (e.desc or "") .. ((e.stats and next(e.stats)) and ("|n" .. statLines(e)) or ""))
        -- recipe parts (first variant) and scroll; the ones carried are dimmed
        local parts = {}
        local r = e.recipe
        if r and r.parts and r.parts[1] then
            for _, part in ipairs(r.parts[1]) do parts[#parts + 1] = part end
        end
        if r and r.scroll then parts[#parts + 1] = r.scroll end
        local carried = {}
        if hero then
            for _, c in ipairs(Items().carried(hero)) do carried[c.name] = (carried[c.name] or 0) + 1 end
        end
        for i = 1, L.PARTS do
            local part = parts[i]
            Kit.show(F.parts[i], part ~= nil)
            if part then
                Kit.setTex(F.parts[i], iconOf(part))
                local have = (carried[part] or 0) > 0
                if have then carried[part] = carried[part] - 1 end
                Kit.setAlpha(F.parts[i], have and 90 or 255)
            end
        end
        Shop.detail = {name = name, parts = parts}
        Kit.show(F.partsLabel.box, #parts > 0)
        if e.result then
            Kit.setText(F.dParts, Kit.color(GRAY, "Recipe for " .. ((data(e.result) or {}).title or "")))
        else
            Kit.setText(F.dParts, "")
        end
    end

    -- Local, every HUD tick while open.
    function Shop.update(lp)
        if not open then return end
        local hero = heroOf(lp)
        local gold = GetPlayerState(lp, PLAYER_STATE_RESOURCE_GOLD)
        local now = Timer.now()
        -- hovered item: its tooltip proxy is visible while the mouse is on it
        for _, c in ipairs(cells) do
            if c.tab == tab and BlzFrameIsVisible(c.proxy) then
                if hovered ~= c then
                    hovered = c
                    lastGold = -1
                    Kit.place(F.hover, c.x0 - 0.0015, c.y0 - 0.0015, c.x1 + 0.0015, c.y1 + 0.0015)
                end
                break
            end
        end
        Kit.show(F.hover, hovered ~= nil and hovered.tab == tab)
        -- affordability and details: on gold changes, and each second for
        -- inventory changes and restocks
        ticks = ticks + 1
        if gold ~= lastGold or ticks % 10 == 0 then
            lastGold = gold
            for _, c in ipairs(cells) do
                if c.tab == tab then Kit.setAlpha(c.img, gold >= priceFor(hero, c.name) and 255 or 110) end
            end
            if hovered then details(hovered.name, hero, gold) end
        end
        Kit.show(F.detail, hovered ~= nil)
        -- stock counts on the icons
        for _, c in ipairs(cells) do
            if c.tab == tab and c.stocked then
                local n = available(c.name, now) or 0
                Kit.setText(c.text, Kit.color(n > 0 and "ffffff" or RED, tostring(n)) .. "|n" .. c.priceText)
            end
        end
        -- range hint
        local near = hero ~= nil and alive(hero) and Items().nearShop(hero)
        Kit.setText(F.range, near and Kit.color(GREEN, "shop in range")
            or Kit.color(RED, hero and alive(hero) and "go to the fountain to buy" or "hero is dead"))
        -- sell row
        for i = 0, 5 do
            local s = sells[i]
            local it = hero and UnitItemInSlot(hero, i)
            local name = it and Items().nameOf(it)
            Kit.show(s.b, name ~= nil)
            if name then
                -- the item's own icon follows Power Treads' attribute
                local path = Kit.dota and BlzGetItemIconPath(it) or ""
                Kit.setTex(s.img, path ~= "" and path or iconOf(name))
                Kit.setText(s.text, Kit.color(GOLD, tostring(sellValue(it))))
            end
        end
    end

    ---------------------------------------------------------------- building (all players)

    local function event(frame, fn, label)
        Kit.probe(frame, "shop " .. (label or "?"))
        frame = Kit.hit(frame)          -- a labelled button's click layer
        local trig = CreateTrigger()
        BlzTriggerRegisterFrameEvent(trig, frame, FRAMEEVENT_CONTROL_CLICK)
        TriggerAddAction(trig, function()
            Safe.call(function()
                local p = GetTriggerPlayer()
                fn(p)
                if p == GetLocalPlayer() then
                    -- a clicked button keeps the keyboard focus: hand it back
                    BlzFrameSetEnable(frame, false)
                    BlzFrameSetEnable(frame, true)
                end
            end)
        end)
    end

    local function build(parents)
        local C = Kit.C
        local x1, y0 = L.RIGHT, L.BOTTOM
        local x0, y1 = x1 - L.W, y0 + L.H
        -- The panel itself blocks clicks on its empty space (Kit.blocker). An
        -- unrelated full-panel catcher took every hover and click from the
        -- item buttons and tabs in game (UI probe log, 2026-10-10); as the
        -- parent of every button here, the blocker leaves them the mouse.
        F.root = Kit.blocker(parents.fg)
        Kit.place(F.root, x0, y0, x1, y1)
        BlzFrameSetVisible(F.root, false)
        Kit.probe(F.root, "shop blocker", true)
        F.bg = Kit.backdrop(F.root, Kit.tex("shop_bg", C.dark), Kit.dota and 245 or 235)
        Kit.place(F.bg, x0, y0, x1, y1)

        -- header: title, tabs, range hint, close
        local hy0 = y1 - L.HEADER_H
        F.title = Kit.text(F.root, 1.1, TEXT_JUSTIFY_LEFT)
        Kit.placeText(F.title, x0 + 0.008, hy0, x0 + 0.06, y1)
        Kit.setText(F.title, Kit.color(GOLD, "SHOP"))
        F.tab, F.tabImg = {}, {}
        local names = {"BASICS", "UPGRADES"}
        for t = 1, 2 do
            local tx0 = x0 + 0.062 + (t - 1) * 0.068
            F.tab[t], F.tabImg[t] = Kit.button(F.root, Kit.tex("shop_button", C.gray))
            Kit.place(F.tab[t], tx0, hy0 + 0.004, tx0 + 0.064, y1 - 0.004)
            Kit.setText(Kit.label(F.tab[t], 0.8), names[t])
            event(F.tab[t], function(p)
                if p == GetLocalPlayer() then setTab(t) end
            end, "tab" .. t)
        end
        F.range = Kit.text(F.root, 0.7, TEXT_JUSTIFY_RIGHT)
        Kit.placeText(F.range, x0 + 0.2, hy0, x1 - 0.026, y1)
        F.close = Kit.button(F.root, C.red)
        Kit.place(F.close, x1 - 0.022, y1 - 0.022, x1 - 0.004, y1 - 0.004)
        Kit.setText(Kit.label(F.close, 0.9), "X")
        event(F.close, function(p) Shop.close(p) end)

        -- categories: first half BASICS, second half UPGRADES
        local shops = use("data.items").shops or {}
        local half = math.ceil(#shops / 2)
        F.colTitles = {{}, {}}
        local gx0 = x0 + 0.006
        local colW = (L.W - 0.012) / L.COLUMNS
        local gy1 = hy0 - 0.003
        for ci, s in ipairs(shops) do
            local t = ci <= half and 1 or 2
            local col = (ci - 1) % half
            if col < L.COLUMNS then
                local cx0 = gx0 + col * colW
                local title = Kit.text(F.root, 0.62)
                Kit.placeText(title, cx0, gy1 - L.COL_TITLE_H, cx0 + colW, gy1)
                Kit.setText(title, Kit.color(GOLD, s.title or s.key or ""))
                F.colTitles[t][#F.colTitles[t] + 1] = title
                local iy1 = gy1 - L.COL_TITLE_H - 0.002
                local pad = (colW - 2 * L.ICON_W - L.ICON_GAP) / 2
                for k, name in ipairs(s.items or {}) do
                    local e = data(name)
                    if e then
                        local r, c = (k - 1) // 2, (k - 1) % 2
                        local bx0 = cx0 + pad + c * (L.ICON_W + L.ICON_GAP)
                        local by1 = iy1 - r * (L.ICON_H + L.ICON_GAP)
                        local b, img = Kit.button(F.root, iconOf(name))
                        Kit.place(b, bx0, by1 - L.ICON_H, bx0 + L.ICON_W, by1)
                        local text = Kit.label(b, 0.55, TEXT_JUSTIFY_RIGHT, TEXT_JUSTIFY_BOTTOM)
                        local short = Kit.dota and "" or (string.sub(e.title, 1, 7) .. "|n")
                        local priceText = Kit.color(GOLD, tostring(e.cost))
                        Kit.setText(text, short .. priceText)
                        local proxy = Kit.frame(F.root)
                        BlzFrameSetTooltip(Kit.hit(b), proxy)
                        local cell = {b = b, img = img, text = text, proxy = proxy, name = name, tab = t,
                                      cost = e.cost, stocked = e.stock ~= nil, priceText = short .. priceText,
                                      x0 = bx0, y0 = by1 - L.ICON_H, x1 = bx0 + L.ICON_W, y1 = by1}
                        cells[#cells + 1] = cell
                        event(b, function(p) Shop.buy(p, name) end, name)
                    end
                end
            end
        end
        F.hover = Kit.backdrop(F.root, Kit.tex("shop_border", C.gold), Kit.dota and 255 or 90)
        Kit.show(F.hover, false)

        -- details of the hovered item
        local dy1 = y0 + L.SELL_H + L.DETAIL_H
        local dy0 = y0 + L.SELL_H + 0.002
        F.detail = Kit.frame(F.root)
        local dbg = Kit.backdrop(F.detail, Kit.tex("tooltip_bg", C.dark), Kit.dota and 255 or 200)
        Kit.place(dbg, x0 + 0.004, dy0, x1 - 0.004, dy1)
        F.dIcon = Kit.backdrop(F.detail, C.dark)
        Kit.place(F.dIcon, x0 + 0.008, dy1 - 0.036, x0 + 0.050, dy1 - 0.004)
        F.dName = Kit.text(F.detail, 0.95, TEXT_JUSTIFY_LEFT)
        Kit.placeText(F.dName, x0 + 0.055, dy1 - 0.017, x1 - 0.008, dy1 - 0.003)
        F.dCost = Kit.text(F.detail, 0.72, TEXT_JUSTIFY_LEFT)
        Kit.placeText(F.dCost, x0 + 0.055, dy1 - 0.031, x1 - 0.008, dy1 - 0.017)
        F.dDesc = Kit.text(F.detail, 0.68, TEXT_JUSTIFY_LEFT, TEXT_JUSTIFY_TOP)
        Kit.placeText(F.dDesc, x0 + 0.008, dy0 + 0.026, x1 - 0.008, dy1 - 0.039)
        F.partsLabel = Kit.text(F.detail, 0.68, TEXT_JUSTIFY_LEFT)
        Kit.placeText(F.partsLabel, x0 + 0.008, dy0 + 0.004, x0 + 0.05, dy0 + 0.022)
        Kit.setText(F.partsLabel, Kit.color(GRAY, "Parts:"))
        F.parts = {}
        for i = 1, L.PARTS do
            F.parts[i] = Kit.backdrop(F.detail, C.dark)
            local px = x0 + 0.05 + (i - 1) * 0.026
            Kit.place(F.parts[i], px, dy0 + 0.004, px + 0.023, dy0 + 0.023)
        end
        F.dParts = Kit.text(F.detail, 0.68, TEXT_JUSTIFY_LEFT)
        Kit.placeText(F.dParts, x0 + 0.008, dy0 + 0.004, x1 - 0.008, dy0 + 0.022)
        Kit.show(F.detail, false)

        -- sell row
        local sl = Kit.text(F.root, 0.7, TEXT_JUSTIFY_LEFT)
        Kit.placeText(sl, x0 + 0.008, y0 + 0.004, x0 + 0.07, y0 + L.SELL_H - 0.004)
        Kit.setText(sl, Kit.color(GRAY, "Sell (50%):"))
        for i = 0, 5 do
            local sx0 = x0 + 0.072 + i * 0.048
            local b, img = Kit.button(F.root, C.dark)
            Kit.place(b, sx0, y0 + 0.005, sx0 + 0.026, y0 + L.SELL_H - 0.005)
            -- sale price right of the icon (child of the button: hides with it)
            local text = Kit.text(b, 0.65, TEXT_JUSTIFY_LEFT)
            Kit.placeText(text, sx0 + 0.028, y0 + 0.005, sx0 + 0.047, y0 + L.SELL_H - 0.005)
            sells[i] = {b = b, img = img, text = text}
            event(b, function(p) Shop.sell(p, i) end)
        end
    end

    local function keys()
        local trig = CreateTrigger()
        local esc = CreateTrigger()
        for slot = 0, SLOT_COMMANDER do
            BlzTriggerRegisterPlayerKeyEvent(trig, Player(slot), L.KEY, 0, false)
            BlzTriggerRegisterPlayerKeyEvent(esc, Player(slot), OSKEY_ESCAPE, 0, false)
        end
        TriggerAddAction(trig, function() Safe.call(function()
            if BUILD_TEST_MODE then use("log").info("shop key toggle") end
            Shop.toggle(GetTriggerPlayer())
        end) end)
        TriggerAddAction(esc, function() Safe.call(function() Shop.close(GetTriggerPlayer()) end) end)
    end

    -- parents = {fg = frame}; called once by dota_hud.init for every player.
    function Shop.init(parents)
        if started then return end
        started = true
        Items().setup()
        build(parents)
        keys()
    end

    return Shop
end)
