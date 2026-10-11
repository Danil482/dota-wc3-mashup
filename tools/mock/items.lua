-- Offline exercise for the Dota items (src/game/items.lua, item_actives.lua,
-- item_passives.lua, src/ai/item_builds.lua). Adds an inventory model to the
-- mock WC3 API, then at 6 s of game time (before the draft) makes test heroes
-- the bot players' main heroes at the home shop (never a human's: the music
-- director binds a human's hero once) and buys, combines, stacks and
-- sells items, runs every active handler once, holds Dota's cooldowns on
-- every item use path, fires the attack procs and the periodic loops, and
-- lets a bot shop. The storage rules (backpack, stash,
-- TP slot, courier) are tools/mock/inventory.lua's. Failed checks and Lua
-- errors become ERROR log lines, which fail the mock run. Test units stand at
-- the home shop and are removed afterwards; the main heroes are restored.

-- ------------------------------------------------------------ inventory model
do
    local function slots(u)
        u.inv = u.inv or {}
        return u.inv
    end

    local function detach(it)
        local u = it.holder
        if not u then return end
        local s = slots(u)
        for i = 0, 5 do
            if s[i] == it then s[i] = nil end
        end
        it.holder = nil
    end

    function CreateItem(id, x, y)
        local it = __handle("item")
        it.typeId, it.charges, it.x, it.y = id, 0, x or 0, y or 0
        return it
    end
    function RemoveItem(it)
        if it then
            detach(it)
            it.typeId = 0
        end
    end
    function GetItemTypeId(it) return it and it.typeId or 0 end
    function GetItemCharges(it) return it and it.charges or 0 end
    function SetItemCharges(it, n) if it then it.charges = n end end
    function GetItemX(it) return it and it.x or 0 end
    function GetItemY(it) return it and it.y or 0 end
    function SetItemPosition(it, x, y) detach(it) it.x, it.y = x, y end
    function SetItemVisible(it, on) if it then it.hidden = not on end end
    function IsItemVisible(it) return it ~= nil and not it.hidden end
    function UnitInventorySize(u) return 6 end
    function UnitItemInSlot(u, i) return slots(u)[i] end
    function UnitHasItem(u, it) return it ~= nil and it.holder == u and it.typeId ~= 0 end
    function UnitAddItem(u, it)
        local s = slots(u)
        for i = 0, 5 do
            if s[i] == nil then
                detach(it)
                s[i], it.holder = it, u
                return true
            end
        end
        return false
    end
    function UnitAddItemById(u, id)
        local it = CreateItem(id, u.x, u.y)
        UnitAddItem(u, it)
        return it
    end
    function UnitRemoveItem(u, it) SetItemPosition(it, u.x, u.y) end
    function UnitDropItemSlot(u, it, slot)
        local s = slots(u)
        for i = 0, 5 do
            if s[i] == it then
                s[i], s[slot] = s[slot], it
                return true
            end
        end
        return false
    end
    -- orders in the game (walk, then drop or give); the mock records them
    __mock.dropOrders = {}
    function UnitDropItemPoint(u, it, x, y)
        if not UnitHasItem(u, it) then return false end
        __mock.dropOrders[#__mock.dropOrders + 1] = {u = u, it = it, x = x, y = y}
        return true
    end
    function UnitDropItemTarget(u, it, target)
        if not UnitHasItem(u, it) then return false end
        __mock.dropOrders[#__mock.dropOrders + 1] = {u = u, it = it, target = target}
        return true
    end
    function UnitUseItem(u, it) return it ~= nil and it.holder == u end
    function UnitUseItemTarget(u, it, t) return it ~= nil and it.holder == u end
    function UnitUseItemPoint(u, it, x, y) return it ~= nil and it.holder == u end
end

-- ------------------------------------------------------------ exercise
do
    local function exercise()
        local Items = use("items")
        local Inv = use("inventory")
        local Actives = use("item_actives")
        local Passives = use("item_passives")
        local Builds = use("item_builds")
        local H = use("heroes")
        local Mods = use("mods")
        local Log = use("log")
        local Timer = use("timer")
        local ids = use("data.ids")
        local catalog = use("data.items")
        local data = catalog.items
        Items.init()
        Inv.init()

        local failures = 0
        local function check(name, ok, detail)
            if not ok then
                failures = failures + 1
                Log.error("items exercise: " .. name .. (detail and (" - " .. tostring(detail)) or ""))
            end
        end

        -- every active has an object and a handler; every shop entry has a token
        for name in pairs(ids.item_abilities) do check("handler for " .. name, Actives.handlers[name] ~= nil) end
        for name in pairs(Actives.handlers) do check("ability for " .. name, ids.item_abilities[name] ~= nil) end
        for _, shop in ipairs(catalog.shops) do
            for _, name in ipairs(shop.items) do check("token for " .. name, ids.item_tokens[name] ~= nil) end
        end
        local spots = #(use("data.mapdata").side_shops or {})
        check("home shops placed", #Items.shops == #catalog.shops - (spots > 0 and 1 or 0), #Items.shops)
        check("a Secret Shop at each of the map's spots", #Items.secretShops == spots, #Items.secretShops)
        for _, s in ipairs(Items.secretShops) do
            check("Secret Shops away from the fountain", not Items.nearHome(s))
        end
        -- item orders are unique and never answer a hero ability's order
        local heroOrders, seen = {}, {}
        for name, order in pairs(ids.orders) do
            if not ids.item_abilities[name] then heroOrders[order] = name end
        end
        for name in pairs(ids.item_abilities) do
            local order = ids.orders[name]
            check("order of " .. name, order ~= nil and heroOrders[order] == nil and not seen[order], order)
            if order then seen[order] = true end
        end

        -- test heroes are the players' main heroes for now, at the home shop
        local heroType = FourCC(ids.heroes.pudge)
        local creepType = FourCC(ids.units.human_melee)
        local s1 = Items.shops[1]
        local hx, hy = GetUnitX(s1) + 150, GetUnitY(s1)
        local mains, testUnits = {}, {}
        local function newHero(slot, x, y, main)
            local u = CreateUnit(Player(slot), heroType, x, y, 0)
            u.hero, u.maxLife, u.life = true, 1000, 500
            testUnits[#testUnits + 1] = u
            if main then
                if mains[slot] == nil then mains[slot] = {was = H.bySlot[slot]} end
                H.bySlot[slot] = u
            end
            return u
        end
        local p0 = Player(1)
        local function gold(p) return GetPlayerState(p or p0, PLAYER_STATE_RESOURCE_GOLD) end
        local hero = newHero(1, hx, hy, true)
        local ally = newHero(2, hx + 100, hy)
        local foeHero = newHero(SLOT_WARCRAFT_AI, hx + 200, hy + 100)
        local foe = CreateUnit(Player(SLOT_HORDE), creepType, hx + 200, hy, 0)
        local fodder = CreateUnit(Player(SLOT_HORDE), creepType, hx + 250, hy - 50, 0)
        testUnits[#testUnits + 1] = foe
        testUnits[#testUnits + 1] = fodder
        SetPlayerState(p0, PLAYER_STATE_RESOURCE_GOLD, 200000)
        check("the test hero is at the home shop", Inv.atHome(p0))

        -- a shop sale: WC3 takes the token's price, then the hero picks it up
        local function shop(u, name)
            local p = GetOwningPlayer(u)
            SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, gold(p) - data[name].cost)
            local token = CreateItem(FourCC(ids.item_tokens[name]), u.x, u.y)
            Items.pickup(u, token)
            check("token " .. name .. " consumed", GetItemTypeId(token) == 0)
        end
        local function wipe(p)
            for _, where in ipairs({"main", "bag", "stash", "tp", "cour"}) do
                for i = 0, Inv.size(where) - 1 do
                    local it = Inv.take(p, where, i)
                    if it then Items.remove(nil, it) end
                end
            end
            local u = H.bySlot[GetPlayerId(p)]
            if u then Items.refresh(u) end
        end
        local function has(u, name) return Items.find(u, name) ~= nil end
        local function count(u) return #Items.carried(u) end
        -- an item made for unit u's player, straight into its main inventory
        -- (a WC3 inventory for units that are not a player's main hero)
        local function hand(u, name)
            local p = GetOwningPlayer(u)
            local it = Items.make(name, GetPlayerId(p))
            if H.bySlot[GetPlayerId(p)] == u then
                check("room for " .. name, Inv.put(p, it, "main"))
            else
                SetItemVisible(it, true)
                check("room for " .. name, UnitAddItem(u, it))
            end
            return it
        end

        -- recipe from parts plus scroll, all at the home shop
        local g = gold()
        shop(hero, "item_mithril_hammer")
        shop(hero, "item_ogre_axe")
        shop(hero, "item_recipe_black_king_bar")
        check("BKB combined", has(hero, "item_black_king_bar") and count(hero) == 1, count(hero))
        check("BKB cost", g - gold() == data.item_black_king_bar.cost, g - gold())
        local props = (Mods.get(hero, "dota_items") or {props = {}}).props
        check("BKB stats", props.str == 10 and props.damage == 24, tostring(props.str) .. "/" .. tostring(props.damage))
        check("BKB belongs to its buyer", Items.ownerOf(Items.find(hero, "item_black_king_bar")) == 1)

        -- an upgrade bought outright reuses an owned part and refunds it
        wipe(p0)
        g = gold()
        shop(hero, "item_boots")
        shop(hero, "item_phase_boots")
        check("Phase Boots bought", has(hero, "item_phase_boots") and not has(hero, "item_boots"))
        check("Phase Boots price", g - gold() == data.item_phase_boots.cost, g - gold())

        -- Power Treads keep the attribute of the variant used
        wipe(p0)
        shop(hero, "item_robe")
        shop(hero, "item_power_treads")
        local treads = Items.find(hero, "item_power_treads")
        check("Treads from Robe", treads and Items.istate(treads).attr == "int")
        props = Mods.get(hero, "dota_items").props
        check("Treads stats", props.int == 10 and props.attack_speed == 25 and props.move_flat == 55,
            tostring(props.int) .. "/" .. tostring(props.move_flat))

        -- boots do not stack: Phase Boots' 50 beat Boots of Speed's 45
        wipe(p0)
        shop(hero, "item_boots")
        shop(hero, "item_boots")
        shop(hero, "item_chainmail")
        shop(hero, "item_blades_of_attack")
        check("Phase Boots combined", has(hero, "item_phase_boots") and has(hero, "item_boots"))
        check("boots stacking", Mods.get(hero, "dota_items").props.move_flat == 50,
            Mods.get(hero, "dota_items").props.move_flat)

        -- consumables stack into one slot
        wipe(p0)
        shop(hero, "item_tango")
        shop(hero, "item_tango")
        local tango = Items.find(hero, "item_tango")
        check("Tango stack", count(hero) == 1 and GetItemCharges(tango) == 6, GetItemCharges(tango))

        -- a full main inventory: the scroll completes the Wand from the backpack
        wipe(p0)
        for _ = 1, 3 do shop(hero, "item_gauntlets") end
        shop(hero, "item_magic_stick")
        shop(hero, "item_branches")
        shop(hero, "item_branches")
        check("six slots", count(hero) == 6, count(hero))
        Items.setCharges(Items.find(hero, "item_magic_stick"), 7)
        shop(hero, "item_recipe_magic_wand")
        local wand = Items.find(hero, "item_magic_wand")
        check("Wand from scroll with a full inventory", wand ~= nil and count(hero) == 4
            and #Inv.list(p0, "bag") == 0, count(hero))
        check("Stick charges kept", wand and Items.charges(wand) == 7, wand and Items.charges(wand))
        -- a basic part that completes an upgrade with a full inventory
        shop(hero, "item_boots")
        shop(hero, "item_gloves")
        check("full again", count(hero) == 6, count(hero))
        shop(hero, "item_belt_of_strength")
        local belted = Items.find(hero, "item_power_treads")
        check("Treads completed with a full inventory", belted ~= nil and count(hero) == 5
            and #Inv.list(p0, "bag") == 0 and Items.istate(belted).attr == "str", count(hero))

        -- selling: the full cost within 10 s of the purchase, half later
        g = gold()
        local gauntlets = Items.find(hero, "item_gauntlets")
        Items.sell(hero, gauntlets)
        check("sell right after buying gives it all back", gold() - g == data.item_gauntlets.cost, gold() - g)
        g = gold()
        local old = Items.find(hero, "item_gauntlets")
        Items.istate(old).boughtAt = Timer.now() - Items.SELLBACK - 1
        Items.sell(hero, old)
        check("sell later at 50 %", gold() - g == math.floor(data.item_gauntlets.cost * 0.5 + 0.5), gold() - g)

        -- an item another player bought gives no stats (Dota: it is muted)
        wipe(p0)
        local foreign = Items.make("item_black_king_bar", 2)
        Inv.put(p0, foreign, "main")
        Items.refresh(hero)
        check("another player's BKB gives no stats", Mods.get(hero, "dota_items") == nil)
        check("another player's BKB cannot be activated",
            Actives.run("onChannel", hero, FourCC(ids.item_abilities.item_black_king_bar), nil, 0, 0) == false)
        Items.istate(foreign).owner = 1
        Items.refresh(hero)
        check("an own BKB does", (Mods.get(hero, "dota_items") or {props = {}}).props.str == 10)

        -- every active handler once
        local function ctxFor(name, target, x, y)
            return Actives.context(hero, FourCC(ids.item_abilities[name]), target, x or hero.x + 300, y or hero.y)
        end
        local TARGETS = {item_flask = ally, item_clarity = ally, item_force_staff = foe, item_cyclone = foeHero,
                         item_dagon = foeHero, item_hand_of_midas = fodder, item_sheepstick = foeHero}
        local names = {}
        for name in pairs(Actives.handlers) do names[#names + 1] = name end
        table.sort(names)
        for _, name in ipairs(names) do
            wipe(p0)
            hero.life = 500
            local it = name ~= "item_tpscroll" and hand(hero, name) or nil
            if it and (name == "item_magic_stick" or name == "item_magic_wand" or name == "item_hand_of_midas") then
                Items.setCharges(it, 2)
            end
            local h = Actives.handlers[name]
            local c = ctxFor(name, TARGETS[name])
            check("context " .. name, c ~= nil and c.item == it)
            local g0 = gold()
            if c and name ~= "item_tpscroll" then
                if h.onChannel then h.onChannel(c) end
                if h.onCast then h.onCast(c) end
                if h.onEndCast then h.onEndCast(c) end
            end
            if name == "item_hand_of_midas" then
                check("Midas gold", gold() - g0 == Items.val(name, "bonus_gold"), gold() - g0)
                check("Midas kill", IsUnitType(fodder, UNIT_TYPE_DEAD))
                check("Midas charge used", it and Items.charges(it) == 1, it and Items.charges(it))
            elseif name == "item_magic_wand" then
                check("Wand emptied", it and Items.charges(it) == 0 and hero.life > 500, hero.life)
            elseif name == "item_black_king_bar" then
                check("BKB immunity", Mods.has(hero, "item_black_king_bar") and Items.istate(it).bkb == 2)
            end
        end
        wipe(p0)

        -- Dota's cooldowns hold on every use path: a HUD click or item key, a
        -- waiting item's target click, the TP slot, and the cast start (bots
        -- and the rest); open again once they end (1 s here). Quick cast is
        -- tools/mock/inventory.lua's (it needs the local player's hero); the
        -- mouse model is tools/mock/dota_settings.lua's.
        local Use, T = use("dota_items"), __mockSettings
        local blink = hand(hero, "item_blink")
        shop(hero, "item_tpscroll")
        local tpScroll = Inv.get(p0, "tp", 0)
        local bslot = 0
        for i = 0, 5 do
            if UnitItemInSlot(hero, i) == blink then bslot = i end
        end
        local blinkAbil = FourCC(ids.item_abilities.item_blink)
        local points = {}
        local usePoint = UnitUseItemPoint
        UnitUseItemPoint = function(u, it, x, y)
            points[#points + 1] = it
            return usePoint(u, it, x, y)
        end
        local function orders() return __mock.calls.IssuePointOrder or 0 end
        -- every path while ready, a Blink left waiting, the cooldowns start
        check("a ready Blink waits for its target", Use.use(p0, bslot) and Use.pending[p0] ~= nil)
        if T then
            T.mouse(p0, "down", hx + 300, hy, MOUSE_BUTTON_TYPE_LEFT)
            check("its target click uses it", #points == 1 and points[1] == blink)
            Use.use(p0, bslot)
        end
        local o = orders()
        Inv.teleport(p0, hx - 2000, hy)
        check("a ready TP slot orders the teleport", orders() == o + 1)
        check("a ready cast starts", Actives.run("onChannel", hero, blinkAbil, nil, hx + 300, hy) ~= false)
        local saved = {data.item_blink.cooldown, data.item_tpscroll.cooldown}
        data.item_blink.cooldown, data.item_tpscroll.cooldown = 1, 1
        Items.used(hero, blink, "item_blink")
        Items.used(hero, tpScroll, "item_tpscroll")
        data.item_blink.cooldown, data.item_tpscroll.cooldown = saved[1], saved[2]
        -- while they recharge
        if T then
            T.mouse(p0, "down", hx + 300, hy, MOUSE_BUTTON_TYPE_LEFT)
            check("a waiting item's target click is refused while it recharges", #points == 1 and Use.pending[p0] == nil)
        end
        Use.pending[p0] = nil
        check("a HUD click or item key is refused while it recharges", not Use.use(p0, bslot) and Use.pending[p0] == nil)
        o = orders()
        Inv.teleport(p0, hx - 2000, hy)
        check("the TP slot is refused while it recharges", orders() == o and not Use.useTp(p0) and Use.pending[p0] == nil)
        check("the cast start is refused while it recharges",
            Actives.run("onChannel", hero, blinkAbil, nil, hx + 300, hy) == false)
        -- and once they ended
        Timer.after(1.1, function()
            use("safe").call(function()
                check("Blink again after its cooldown", Use.use(p0, bslot) and Use.pending[p0] ~= nil)
                if T then
                    T.mouse(p0, "down", hx + 300, hy, MOUSE_BUTTON_TYPE_LEFT)
                    check("its target click again", #points == 2)
                end
                Use.pending[p0] = nil
                UnitUseItemPoint = usePoint
                local n = orders()
                Inv.teleport(p0, hx - 2000, hy)
                check("the TP slot again", orders() == n + 1)
                check("the cast start again", Actives.run("onChannel", hero, blinkAbil, nil, hx + 300, hy) ~= false)
            end)
        end)

        -- the Town Portal: bought into the TP slot, cast by the hero's own
        -- TP ability, spent after the channel
        local p1 = Player(3)
        local traveler = newHero(3, hx - 100, hy - 100, true)
        SetPlayerState(p1, PLAYER_STATE_RESOURCE_GOLD, 1000)
        shop(traveler, "item_tpscroll")
        local tpItem = Inv.get(p1, "tp", 0)
        check("the scroll fills the TP slot", tpItem ~= nil and count(traveler) == 0)
        local tpCtx = Actives.context(traveler, FourCC(ids.item_abilities.item_tpscroll), nil, -7000, -7000)
        check("the TP ability finds the TP slot's scroll", tpCtx ~= nil and tpCtx.item == tpItem)
        local tp = Actives.handlers.item_tpscroll
        tp.onChannel(tpCtx)
        tp.onCast(tpCtx)

        -- passive procs, auras and loops with a full kit
        local carrier = newHero(2, hx + 50, hy + 150)
        for _, name in ipairs({"item_bfury", "item_greater_crit", "item_basher", "item_monkey_king_bar",
                               "item_desolator", "item_assault"}) do
            hand(carrier, name)
        end
        Items.refresh(carrier)
        check("kit carried", count(carrier) == 6, count(carrier))
        local st = Items.state[carrier]
        check("proc state", st and st.cleave and st.bash and st.pierce and st.corruption and #st.crits == 1)
        for _ = 1, 20 do
            local info = {amount = 100, attack = true}
            Passives.damaging(carrier, foe, info)
            Passives.damaged(carrier, foe, info.amount, info)
        end
        Passives.damaged(foeHero, carrier, 50, {attack = true})
        local holder = newHero(4, hx - 50, hy + 150)
        for _, name in ipairs({"item_radiance", "item_heart", "item_shivas_guard", "item_mekansm", "item_buckler",
                               "item_magic_wand"}) do
            hand(holder, name)
        end
        Items.refresh(holder)
        Passives.auras()
        Passives.burn()
        Passives.regen()
        Passives.recharge()
        Passives.spellCast(foeHero, FourCC("AHtb"))
        Passives.death(foeHero, carrier)
        check("aura applied", Mods.has(foe, "aura_assault_minus") and Mods.has(carrier, "aura_assault"))
        check("Desolator stack", Items.istate(Items.find(carrier, "item_desolator")).kills ==
            Items.val("item_desolator", "bonus_damage_per_kill"))
        check("wand charge", Items.charges(Items.find(holder, "item_magic_wand")) == 1)
        Passives.castRange(holder, 225)
        Passives.castRange(holder, 0)

        -- a bot shops along its build at the home shop; Secret Shop parts
        -- reach a bot there (Dota's bots send their courier for them)
        local bot = newHero(4, hx, hy - 150, true)
        SetPlayerState(Player(4), PLAYER_STATE_RESOURCE_GOLD, 30000)
        local bought, sticks = {}, 0
        for _ = 1, 60 do
            local name = Builds.shop(bot, "pudge")
            if name then bought[#bought + 1] = name end
            if name == "item_magic_stick" then sticks = sticks + 1 end
            Inv.arrange(Player(4))
        end
        local kit = {}
        for _, c in ipairs(Items.owned(bot)) do kit[#kit + 1] = c.name end
        check("bot shopping", Items.covers(bot, "item_blink") and Items.covers(bot, "item_black_king_bar")
            and Items.covers(bot, "item_phase_boots") and Items.covers(bot, "item_refresher") and sticks == 1,
            table.concat(bought, ",") .. " | " .. table.concat(kit, ","))
        check("bot keeps its stash empty", #Inv.list(Player(4), "stash") == 0, #Inv.list(Player(4), "stash"))
        Items.autoUse(bot)

        local function finish()
            for slot in pairs(mains) do wipe(Player(slot)) end
            for _, u in ipairs(testUnits) do RemoveUnit(u) end
            for slot, m in pairs(mains) do H.bySlot[slot] = m.was end
        end
        Timer.after(3.2, function()
            use("safe").call(function()
                tp.onEndCast(tpCtx)
                check("TP moved", math.abs(traveler.x + 7000) < 900 and math.abs(traveler.y + 7000) < 900,
                    traveler.x .. "," .. traveler.y)
                check("TP spent", Inv.get(p1, "tp", 0) == nil)
                finish()
                Log.info("items exercise: teleport done, " .. failures .. " failed checks in total")
            end)
        end)

        Log.info("items exercise: " .. #names .. " handlers, bot bought " .. #bought .. " parts, "
            .. failures .. " failed checks")
    end

    -- Run with mock-only overrides: hero, enemy and visibility answers that
    -- the generic stubs cannot give.
    local function run()
        if not defined or not defined("items") then return end
        local saved = {IsUnitType, IsUnitEnemy, IsUnitAlly, IsUnitVisible}
        local function side(p)
            local id = GetPlayerId(p)
            return (id <= SLOT_DOTA_MAX or id == SLOT_ANCIENTS) and 1 or 2
        end
        IsUnitType = function(u, t)
            if t == UNIT_TYPE_HERO then return u.hero == true end
            if t == UNIT_TYPE_MELEE_ATTACKER then return true end
            return saved[1](u, t)
        end
        IsUnitEnemy = function(u, p) return side(GetOwningPlayer(u)) ~= side(p) end
        IsUnitAlly = function(u, p) return side(GetOwningPlayer(u)) == side(p) end
        IsUnitVisible = function() return true end
        use("safe").call(exercise)
        IsUnitType, IsUnitEnemy, IsUnitAlly, IsUnitVisible = saved[1], saved[2], saved[3], saved[4]
    end

    TimerStart(CreateTimer(), 6.0, false, run)
end
