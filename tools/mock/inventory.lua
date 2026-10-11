-- Offline exercise for Dota's item storage (src/game/inventory.lua with
-- items.lua, dota_shop.lua, dota_items.lua and the HUD's item rows), on top
-- of the frame, key, mouse and sync models of tools/mock/dota_hud.lua and
-- tools/mock/dota_settings.lua. Runs after their exercises on Player(0)'s
-- hero and checks: purchases at the home shop fill the main inventory, the
-- backpack, the stash and then drop in the fountain; away or dead they go to
-- the stash; parts combine in the stash, and hero and stash only at home;
-- Secret Shop items need a Secret Shop and land in hand there while the
-- other parts wait in the stash; TP scrolls fill the TP slot; Grab All;
-- move rules (stash only at home, the TP slot, stacks, the backpack swap
-- cooldown and its end in shop range); cooldowns at half speed off the main
-- inventory and Refresher frozen in the backpack; selling from the
-- backpack, not another player's item; the HUD's backpack row, TP slot,
-- stash row and Grab All button; the TP slot's targeting and a frame click
-- that leaves a waiting item alone; drag and drop between slots, onto the
-- world and onto an allied hero; the courier (src/game/courier.lua): one for
-- the human, at the fountain and invulnerable there, Secret Shop purchases
-- on it, Deliver Items (stash, then the hero), back to the stash when the
-- hero dies, flying at hero level 4, Speed Burst at 10, six creep attacks to
-- kill, respawn with its items, the HUD's courier buttons and rows, and the
-- player's courier and Grab All keys. Failed checks are ERROR log lines,
-- which fail the mock run.
if __mockHud and __mockSettings and not __mockInventory then
    local M, T = __mockHud, __mockSettings
    __mockInventory = {}
    -- natives and functions the exercise replaces, put back even after an error
    local saved, restore = {}, {}

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
                Log.error("inventory exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
            end
        end
        local Items, Inv, Shop, Use, Hud, Kit, H = use("items"), use("inventory"), use("dota_shop"), use("dota_items"),
            use("dota_hud"), use("hud_kit"), use("heroes")
        local ids, Events = use("data.ids"), use("events")
        Items.init()
        Inv.init()
        local p0, p1 = Player(0), Player(1)
        local hero, ally = H.bySlot[0], H.bySlot[1]
        check("heroes of players 0 and 1", hero ~= nil and ally ~= nil)
        if not hero or not ally then return end
        local F = Hud.F
        hero.dead, ally.dead = false, false
        -- Dota: every hero starts with a free, unsellable scroll in its TP slot
        local first = Inv.get(p1, "tp", 0)
        check("a free first scroll in the TP slot", first ~= nil and Items.unsellable(first)
            and Items.ownerOf(first) == 1 and GetItemCharges(first) == 1)

        -- mock-only answers: sides, and the orders this exercise watches
        local function set(name, fn)
            if saved[name] == nil then saved[name] = _G[name] end
            _G[name] = fn
        end
        local function side(p)
            local id = GetPlayerId(p)
            return (id <= SLOT_DOTA_MAX or id == SLOT_ANCIENTS) and 1 or 2
        end
        local pointOrders = {}
        set("IsUnitAlly", function(u, p) return side(GetOwningPlayer(u)) == side(p) end)
        set("IsUnitEnemy", function(u, p) return side(GetOwningPlayer(u)) ~= side(p) end)
        set("IssuePointOrder", function(u, order, x, y)
            pointOrders[#pointOrders + 1] = {u = u, order = order, x = x, y = y}
            return true
        end)

        local made = {}
        local make = Items.make
        restore[#restore + 1] = function() Items.make = make end
        Items.make = function(name, pid)
            local it = make(name, pid)
            made[#made + 1] = it
            return it
        end

        local s1 = Items.shops[1]
        local function atHome(u) SetUnitPosition(u or hero, GetUnitX(s1) + 100, GetUnitY(s1)) end
        local function away(u) SetUnitPosition(u or hero, 0, 0) end
        local function atSecret(u)
            local s = Items.secretShops[1]
            SetUnitPosition(u or hero, GetUnitX(s) + 100, GetUnitY(s))
        end
        local function gold(p) return GetPlayerState(p or p0, PLAYER_STATE_RESOURCE_GOLD) end
        local function setGold(n, p) SetPlayerState(p or p0, PLAYER_STATE_RESOURCE_GOLD, n) end
        local function wipe(p)
            p = p or p0
            for _, where in ipairs({"main", "bag", "stash", "tp", "cour"}) do
                for i = 0, Inv.size(where) - 1 do
                    local it = Inv.take(p, where, i)
                    if it then Items.remove(nil, it) end
                end
            end
            Use.pending[p] = nil
        end
        local function names(where, p)
            local out = {}
            for _, c in ipairs(Inv.list(p or p0, where)) do out[#out + 1] = c.name end
            return table.concat(out, ",")
        end
        local function placeOf(name, p)
            for _, where in ipairs({"main", "bag", "tp", "stash", "cour"}) do
                for _, c in ipairs(Inv.list(p or p0, where)) do
                    if c.name == name then return where, c.i, c.item end
                end
            end
            return nil
        end
        local function cost(name) return Items.data(name).cost end
        -- the home watcher (inventory.lua, every 0.25 s) must see each move
        local function goAway() away() advance(0.3) end
        local function goHome() atHome() advance(0.3) end
        local function goSecret() atSecret() advance(0.3) end
        local function aliveHome()
            hero.dead = false
            atHome()
        end
        setGold(200000)

        ---------------------------------------------------------------- purchases
        wipe()
        aliveHome()
        check("the hero is at the home shop", Inv.atHome(p0))
        local g = gold()
        local before = #made
        for _ = 1, 16 do Shop.buy(p0, "item_gauntlets") end
        check("16 bought", g - gold() == 16 * cost("item_gauntlets"), g - gold())
        check("home: six in the main inventory", #Items.carried(hero) == 6, #Items.carried(hero))
        check("then three in the backpack", #Inv.list(p0, "bag") == 3, #Inv.list(p0, "bag"))
        check("then six in the stash", #Inv.list(p0, "stash") == 6, #Inv.list(p0, "stash"))
        local last = made[before + 16]
        local f = use("data.mapdata").dota.fountain
        check("the last one drops in the fountain", last ~= nil and Inv.find(p0, last) == nil and IsItemVisible(last)
            and GetItemX(last) == f.x and GetItemY(last) == f.y)
        RemoveItem(last)

        -- away from the fountain everything goes to the stash; parts combine there
        wipe()
        away()
        check("away: not at home", not Inv.atHome(p0))
        g = gold()
        Shop.buy(p0, "item_ogre_axe")
        Shop.buy(p0, "item_mithril_hammer")
        check("away: parts in the stash", names("stash") == "item_ogre_axe,item_mithril_hammer"
            and #Items.carried(hero) == 0, names("stash"))
        Shop.buy(p0, "item_recipe_black_king_bar")
        check("away: BKB forms in the stash", names("stash") == "item_black_king_bar", names("stash"))
        check("away: BKB paid in full", g - gold() == cost("item_black_king_bar"), g - gold())

        -- hero and stash combine only at the home shop
        wipe()
        aliveHome()
        Shop.buy(p0, "item_boots")
        goAway()
        g = gold()
        Shop.buy(p0, "item_phase_boots")
        check("owned boots lower the price", g - gold() == cost("item_phase_boots") - cost("item_boots"), g - gold())
        check("away: no Phase Boots yet", placeOf("item_phase_boots") == nil and placeOf("item_boots") == "main"
            and names("stash") == "item_chainmail,item_blades_of_attack", names("stash"))
        goHome()
        local w, i = placeOf("item_phase_boots")
        check("home: hero and stash combine", w == "main" and i == 0 and names("stash") == "", tostring(w))

        -- a dead hero's purchases wait in the stash
        wipe()
        hero.dead = true
        Shop.buy(p0, "item_gloves")
        check("dead: to the stash", placeOf("item_gloves") == "stash")
        hero.dead = false

        ---------------------------------------------------------------- Secret Shops
        wipe()
        aliveHome()
        g = gold()
        Shop.buy(p0, "item_hyperstone")
        check("a Secret Shop item is refused at the fountain", gold() == g and placeOf("item_hyperstone") == nil)
        check("Secret Shops stand away from the fountain", #Items.secretShops > 0 and not Items.nearHome(Items.secretShops[1]))
        goSecret()
        check("the hero at a Secret Shop", Items.nearSecret(hero) and not Inv.atHome(p0))
        g = gold()                          -- gold income runs while time passes
        Shop.buy(p0, "item_hyperstone")
        check("at a Secret Shop: in hand", placeOf("item_hyperstone") == "main" and g - gold() == cost("item_hyperstone"))
        -- an upgrade bought there: Secret Shop parts in hand, the rest in the stash
        wipe()
        g = gold()
        Shop.buy(p0, "item_assault")
        check("Assault Cuirass paid in full", g - gold() == cost("item_assault"), g - gold())
        check("secret parts in hand", names("main") == "item_hyperstone,item_platemail", names("main"))
        check("base parts in the stash, the Buckler formed there",
            names("stash") == "item_buckler,item_recipe_assault", names("stash"))
        goHome()
        w, i = placeOf("item_assault")
        check("home: the Assault Cuirass forms in the first slot", w == "main" and i == 0, tostring(w))

        ---------------------------------------------------------------- TP slot
        wipe()
        aliveHome()
        Shop.buy(p0, "item_tpscroll")
        Shop.buy(p0, "item_tpscroll")
        local tp = Inv.get(p0, "tp", 0)
        check("scrolls fill the TP slot", tp ~= nil and GetItemCharges(tp) == 2 and #Items.carried(hero) == 0,
            tp and GetItemCharges(tp))
        away()
        Shop.buy(p0, "item_tpscroll")
        check("away: a scroll waits in the stash", placeOf("item_tpscroll") == "tp" and names("stash") == "item_tpscroll")
        local n0, why = Inv.grabAll(p0)
        check("Grab All away from the shop is refused", n0 == 0 and why ~= nil)
        atHome()
        check("Grab All at home", Inv.grabAll(p0) == 1 and names("stash") == "" and GetItemCharges(tp) == 3)

        ---------------------------------------------------------------- moves
        wipe()
        aliveHome()
        Shop.buy(p0, "item_blink")
        Shop.buy(p0, "item_tpscroll")
        local blink = Items.find(hero, "item_blink")
        check("move main to stash at home", Inv.move(p0, 0, Inv.STASH) and placeOf("item_blink") == "stash")
        away()
        local ok, reason = Inv.move(p0, Inv.STASH, 0)
        check("stash to main refused away", not ok and reason ~= nil and placeOf("item_blink") == "stash")
        atHome()
        check("stash to main at home", Inv.move(p0, Inv.STASH, 2) and select(2, placeOf("item_blink")) == 2)
        ok = Inv.move(p0, 2, Inv.TP)
        check("only scrolls go in the TP slot", not ok and placeOf("item_blink") == "main")
        ok = Inv.move(p0, Inv.TP, 0)
        check("scrolls stay in their slot", not ok and placeOf("item_tpscroll") == "tp")
        -- backpack swaps: Dota's 6 s cooldown away from shops, none at a shop
        check("main to backpack", Inv.move(p0, 2, Inv.BAG + 1) and placeOf("item_blink") == "bag")
        away()
        check("backpack to main", Inv.move(p0, Inv.BAG + 1, 0) and placeOf("item_blink") == "main")
        local left = Items.cdLeft(blink, hero)
        check("away from shops a swap costs 6 s", math.abs(left - Inv.SWAP_COOLDOWN) < 0.01
            and Items.locked(blink) > 5.9, left)
        advance(0.3)
        goHome()
        check("walking into shop range ends it", Items.cdLeft(blink, hero) < 0.01 and Items.locked(blink) < 0.01,
            Items.cdLeft(blink, hero))
        Inv.move(p0, 0, Inv.BAG)
        Inv.move(p0, Inv.BAG, 0)
        check("no swap cooldown at a shop", Items.cdLeft(blink, hero) < 0.01)
        -- off the main inventory a cooldown runs at half speed
        Items.used(hero, blink, "item_blink")
        local full = Items.cdLeft(blink, hero)
        Inv.move(p0, 0, Inv.BAG)
        advance(4)
        local parked = Items.cdLeft(blink)
        check("half speed in the backpack", math.abs(parked - (full - 2)) < 0.1, parked .. " of " .. full)
        Inv.move(p0, Inv.BAG, 0)
        advance(2)
        check("full speed again in the main inventory", math.abs(Items.cdLeft(blink, hero) - (full - 4)) < 0.1,
            Items.cdLeft(blink, hero))
        -- a Refresher Orb's cooldown stands still in the backpack
        local refresher = Items.make("item_refresher", 0)
        Inv.put(p0, refresher, "main")
        Items.used(hero, refresher, "item_refresher")
        local rcd = Items.cdLeft(refresher, hero)
        Inv.move(p0, select(2, placeOf("item_refresher")), Inv.BAG + 2)
        advance(3)
        check("Refresher frozen in the backpack", math.abs(Items.cdLeft(refresher) - rcd) < 0.1, Items.cdLeft(refresher))
        -- a stack dropped on the same item joins it
        wipe()
        Shop.buy(p0, "item_tango")
        Shop.buy(p0, "item_branches")
        Inv.move(p0, 0, Inv.BAG)
        Shop.buy(p0, "item_tango")
        local tango = Inv.get(p0, "bag", 0)
        check("a new tango stack joins the one in the backpack", Items.find(hero, "item_tango") == nil
            and tango ~= nil and GetItemCharges(tango) == 6, names("bag"))

        ---------------------------------------------------------------- selling
        wipe()
        aliveHome()
        Shop.buy(p0, "item_gauntlets")
        Inv.move(p0, 0, Inv.BAG)
        g = gold()
        check("sell from the backpack", Shop.sell(p0, Inv.BAG) == cost("item_gauntlets") and gold() == g + cost("item_gauntlets"))
        local theirs = Items.make("item_gauntlets", 1)
        Inv.put(p0, theirs, "main")
        g = gold()
        check("another player's item cannot be sold", Shop.sell(p0, 0) == 0 and gold() == g)
        wipe()

        ---------------------------------------------------------------- HUD rows
        M.selection = {hero}
        aliveHome()
        Shop.buy(p0, "item_tpscroll")
        local bagItem = Items.make("item_gauntlets", 0)
        Inv.put(p0, bagItem, "bag", 1)
        local stashItem = Items.make("item_robe", 0)
        Inv.put(p0, stashItem, "stash", 3)
        Hud.tick()
        check("backpack row shows its item, dimmed", M.shown(F.bag[1].b) and F.bag[1].item == bagItem
            and F.bag[1].img.alpha < 255 and M.shown(F.bag[0].b) and not M.shown(F.bag[0].img))
        check("TP slot shows the scrolls", M.shown(F.tp.b) and F.tp.item == Inv.get(p0, "tp", 0))
        check("stash row shown with its item", M.shown(F.blockStash) and M.shown(F.stash[3].b)
            and F.stash[3].item == stashItem)
        local stashL = M.at(F.stash[0].b)
        local slot5x, slot5y = M.at(F.slots[5].b)
        check("stash row above the items", stashL ~= nil and select(2, M.at(F.stash[0].b)) > select(2, M.at(F.slots[0].b)))
        check("backpack row under the items", select(2, M.at(F.bag[0].b)) < slot5y, select(2, M.at(F.bag[0].b)))
        check("TP slot right of the items", M.at(F.tp.b) > slot5x)
        check("new slots under their blockers", M.under(Kit.hit(F.bag[0].b), F.fgBottom)
            and M.under(Kit.hit(F.tp.b), F.fgBottom) and M.under(Kit.hit(F.stash[0].b), F.blockStash))
        M.click(F.grab, p0)
        check("Grab All button", placeOf("item_robe") == "main" and Inv.list(p0, "stash")[1] == nil)
        away()
        Hud.tick()
        check("stash row hidden away with an empty stash", not M.shown(F.blockStash))
        atHome()
        Hud.tick()
        check("stash row shown at home", M.shown(F.blockStash))
        local h0 = M.handles
        for _ = 1, 4 do Hud.tick() Hud.tickSweeps() end
        check("no handles while drawing the rows", M.handles == h0, M.handles - h0)

        -- the TP slot: a click waits for the point, a frame click is ignored
        advance(0.2)
        M.click(F.tp.b, p0)
        check("TP slot click waits for a target", Use.pending[p0] ~= nil and Use.pending[p0].tp == true)
        local orders0 = #pointOrders
        T.mouse(p0, "down", 0, 0, MOUSE_BUTTON_TYPE_LEFT)
        check("a click on a frame (0, 0) leaves the TP waiting", Use.pending[p0] ~= nil and #pointOrders == orders0)
        T.mouse(p0, "down", -6000, -5000, MOUSE_BUTTON_TYPE_LEFT)
        local o = pointOrders[#pointOrders] or {}
        check("the world click teleports", #pointOrders == orders0 + 1 and o.u == hero
            and o.order == ids.orders.item_tpscroll and o.x == -6000 and o.y == -5000)
        -- a waiting point item ignores frame clicks too
        wipe()
        local blink2 = Items.make("item_blink", 0)
        Inv.put(p0, blink2, "main", 0)
        Use.use(p0, 0)
        T.mouse(p0, "down", 0, 0, MOUSE_BUTTON_TYPE_LEFT)
        check("a point item keeps waiting after a frame click", Use.pending[p0] ~= nil)
        Use.pending[p0] = nil

        ---------------------------------------------------------------- drag and drop
        local function frameEvent(f, ev, p)
            local hit = Kit.hitOf[f] or f
            for _, r in ipairs(M.regs) do
                if (r.frame == f or r.frame == hit) and r.event == ev then
                    M.trig = {player = p, frame = f, event = ev}
                    for _, a in ipairs(r.trig.actions or {}) do a() end
                end
            end
            M.trig = {}
        end
        local function enter(f, p) frameEvent(f, FRAMEEVENT_MOUSE_ENTER, p or p0) end
        local function leave(f, p) frameEvent(f, FRAMEEVENT_MOUSE_LEAVE, p or p0) end
        local function drag(from, to, x, y)
            enter(from)
            T.mouse(p0, "down", 0, 0, MOUSE_BUTTON_TYPE_LEFT)
            leave(from)
            if to then enter(to) end
            T.mouse(p0, "up", to and 0 or x, to and 0 or y, MOUSE_BUTTON_TYPE_LEFT)
            if to then
                M.click(to, p0)            -- in case the game reports a click on the target too
                leave(to)
            end
        end
        wipe()
        aliveHome()
        Hud.tick()
        advance(0.2)
        local trail = {}
        for _, m in ipairs(T.sync) do
            if m.prefix == "dvcview" then trail[#trail + 1] = GetPlayerId(m.player) .. ":" .. m.data end
        end
        check("the HUD shows the hero's items to every client", Use.view[p0] == "hero",
            tostring(Use.view[p0]) .. " after " .. table.concat(trail, " "))
        local a = Items.make("item_blink", 0)
        local b = Items.make("item_gauntlets", 0)
        Inv.put(p0, a, "main", 0)
        Inv.put(p0, b, "main", 4)
        drag(F.slots[0].b, F.slots[4].b)
        check("drag swaps two main slots", UnitItemInSlot(hero, 4) == a and UnitItemInSlot(hero, 0) == b)
        check("a drop is not a click", Use.pending[p0] == nil)
        drag(F.slots[4].b, F.bag[2].b)
        check("drag into the backpack", Inv.get(p0, "bag", 2) == a)
        drag(F.bag[2].b, F.stash[5].b)
        check("drag into the stash at home", Inv.get(p0, "stash", 5) == a)
        away()
        Hud.tick()
        drag(F.stash[5].b, F.slots[1].b)
        check("drag out of the stash refused away", Inv.get(p0, "stash", 5) == a)
        atHome()
        Hud.tick()
        drag(F.stash[5].b, F.slots[1].b)
        check("drag out of the stash at home", UnitItemInSlot(hero, 1) == a)
        -- a click on a slot still uses its item
        enter(F.slots[1].b)
        T.mouse(p0, "down", 0, 0, MOUSE_BUTTON_TYPE_LEFT)
        T.mouse(p0, "up", 0, 0, MOUSE_BUTTON_TYPE_LEFT)
        advance(0.6)
        M.click(F.slots[1].b, p0)
        leave(F.slots[1].b)
        check("a press and release on one slot is a click", Use.pending[p0] ~= nil and Use.pending[p0].item == a)
        Use.pending[p0] = nil
        -- onto the world: the hero walks there and drops it
        local drops = #__mock.dropOrders
        drag(F.slots[1].b, nil, GetUnitX(hero) + 400, GetUnitY(hero))
        local d = __mock.dropOrders[#__mock.dropOrders] or {}
        check("drag a main item onto the world orders a drop there", #__mock.dropOrders == drops + 1 and d.it == a
            and d.x == GetUnitX(hero) + 400 and d.target == nil)
        -- onto an allied hero: given
        SetUnitPosition(ally, GetUnitX(hero) + 300, GetUnitY(hero) + 100)
        drag(F.slots[1].b, nil, GetUnitX(ally) + 20, GetUnitY(ally))
        d = __mock.dropOrders[#__mock.dropOrders] or {}
        check("drag onto an allied hero gives it", d.it == a and d.target == ally)
        -- backpack items walk there first, then land on the ground or with the ally
        Inv.move(p0, 1, Inv.BAG)
        local tx, ty = GetUnitX(hero) + 500, GetUnitY(hero) - 200
        drag(F.bag[0].b, nil, tx, ty)
        advance(0.3)
        check("a backpack item waits for the walk", Inv.get(p0, "bag", 0) == a)
        SetUnitPosition(hero, tx + 30, ty)
        advance(0.3)
        check("then lands on the ground", Inv.find(p0, a) == nil and IsItemVisible(a) and GetItemX(a) == tx)
        Inv.put(p0, a, "bag", 0)
        wipe(p1)
        drag(F.bag[0].b, nil, GetUnitX(ally), GetUnitY(ally) + 20)
        SetUnitPosition(ally, GetUnitX(hero) + 100, GetUnitY(hero))
        advance(0.3)
        check("a backpack item given to an ally", Inv.find(p1, a) ~= nil and Inv.find(p0, a) == nil)
        check("a given item stays its buyer's", Items.ownerOf(a) == 0 and not Items.usableBy(a, ally))
        wipe(p1)
        atHome(ally)

        ---------------------------------------------------------------- courier
        local Courier, Mods, U = use("courier"), use("mods"), use("util")
        local cid = ids.courier
        check("courier objects in the build", cid ~= nil and cid.units.courier ~= nil and cid.units.courier_flying ~= nil
            and cid.abilities.courier_burst ~= nil and cid.orders.courier_shield ~= nil)
        local casts = {}
        set("IssueImmediateOrder", function(u, o)
            casts[#casts + 1] = {u = u, order = o}
            return true
        end)
        set("ClearSelection", function() M.selection = {} end)
        set("SelectUnit", function(u, on) if on then M.selection[#M.selection + 1] = u end end)
        wipe()
        aliveHome()
        hero.level = 1
        Courier.init()
        Courier.add(p0)
        local cu = Courier.of(p0)
        check("a courier for the human player", cu ~= nil and GetOwningPlayer(cu) == p0
            and GetUnitTypeId(cu) == FourCC(cid.units.courier))
        check("it starts at the fountain", cu ~= nil and U.dist(GetUnitX(cu), GetUnitY(cu), f.x, f.y) < 600)
        check("no courier for a bot", Courier.of(p1) == nil)
        advance(0.3)
        check("invulnerable in the fountain's aura", Mods.has(cu, "courier_fountain"))
        check("level 1 speed", Mods.get(cu, "courier_level") ~= nil and Mods.get(cu, "courier_level").props.move_flat == 0)
        Hud.tick()
        check("courier buttons shown", M.shown(F.courBtn) and M.shown(F.deliverBtn))
        -- a Secret Shop purchase lands on the courier standing there
        local ss = Items.secretShops[1]
        SetUnitPosition(cu, GetUnitX(ss) + 100, GetUnitY(ss))
        away()
        g = gold()
        Shop.buy(p0, "item_platemail")
        check("the courier at a Secret Shop takes the purchase", placeOf("item_platemail") == "cour"
            and g - gold() == cost("item_platemail"), placeOf("item_platemail"))
        -- Deliver Items: the stash first, then to the hero
        Inv.put(p0, Items.make("item_gauntlets", 0), "stash")
        SetUnitPosition(cu, GetUnitX(s1) + 200, GetUnitY(s1))
        check("deliver", Courier.deliver(p0))
        local cr = Courier.record(p0)
        check("deliver takes the stash", names("stash") == "" and #Inv.list(p0, "cour") == 2 and cr.task == "transfer",
            tostring(cr.task))
        advance(0.3)
        check("on its way while the hero is far", cr.task == "transfer")
        SetUnitPosition(cu, GetUnitX(hero) + 100, GetUnitY(hero))
        advance(0.3)
        check("hands everything to the hero", #Inv.list(p0, "cour") == 0 and placeOf("item_gauntlets") == "main"
            and placeOf("item_platemail") == "main" and cr.task == "home", tostring(cr.task))
        -- the hero dies on the way: the items go back to the stash
        Inv.put(p0, Items.make("item_robe", 0), "cour")
        SetUnitPosition(cu, GetUnitX(hero) + 1000, GetUnitY(hero))
        check("transfer", Courier.deliver(p0) and cr.task == "transfer", tostring(cr.task))
        hero.dead = true
        advance(0.3)
        check("the hero died: back to the stash", cr.task == "return", tostring(cr.task))
        SetUnitPosition(cu, GetUnitX(s1) + 200, GetUnitY(s1))
        advance(0.3)
        check("items returned", placeOf("item_robe") == "stash" and cr.task == "home", tostring(cr.task))
        hero.dead = false
        -- levels: flying at 4, Speed Burst at 10
        hero.level = 4
        advance(0.3)
        local fly = Courier.of(p0)
        local function castsBy(u)
            local n = 0
            for _, c in ipairs(casts) do if c.u == u then n = n + 1 end end
            return n
        end
        check("flies from hero level 4", fly ~= cu and GetUnitTypeId(fly) == FourCC(cid.units.courier_flying)
            and GetUnitTypeId(cu) == 0)
        check("+10 speed per level", Mods.get(fly, "courier_level").props.move_flat == 30)
        check("Speed Burst locked before level 10", not Courier.cast(p0, "courier_burst") and castsBy(fly) == 0)
        hero.level = 10
        advance(0.3)
        check("Speed Burst at level 10", Courier.cast(p0, "courier_burst") and casts[#casts].u == fly
            and casts[#casts].order == cid.orders.courier_burst)
        Events.emit("spell_effect", fly, FourCC(cid.abilities.courier_burst), nil, 0, 0)
        advance(0.05)
        local b = Mods.get(fly, "courier_burst")
        check("Speed Burst: 50% faster", b ~= nil and b.props.move_pct == 0.5)
        check("Shield locked before level 20", not Courier.cast(p0, "courier_shield"))
        -- attacks to kill: six from creeps
        SetUnitPosition(fly, 0, 0)
        advance(3.5)
        check("the fountain's invulnerability ends outside", not Mods.has(fly, "courier_fountain"))
        local dealt = nil
        set("GetEventDamage", function() return 10 end)
        set("BlzGetEventIsAttack", function() return true end)
        set("BlzSetEventDamage", function(v) dealt = v end)
        local creep = CreateUnit(Player(SLOT_HORDE), FourCC("hfoo"), 50, 0, 0)
        for _ = 1, 5 do Events.emit("damaging", creep, fly) end
        check("five creep attacks leave it alive", dealt == 0 and GetWidgetLife(fly) > 0, dealt)
        Events.emit("damaging", creep, fly)
        check("the sixth kills it", dealt ~= nil and dealt >= BlzGetUnitMaxHP(fly), dealt)
        for _, n in ipairs({"GetEventDamage", "BlzGetEventIsAttack", "BlzSetEventDamage"}) do
            _G[n] = saved[n]
            saved[n] = nil
        end
        Inv.put(p0, Items.make("item_branches", 0), "cour")
        KillUnit(fly)
        Events.emit("death", fly, creep)
        RemoveUnit(creep)
        check("dead", cr.dead == true)
        Hud.tick()
        check("the courier button counts down", string.find(F.courText.t.text, "120", 1, true) ~= nil,
            F.courText.t.text)
        advance(121)
        local back = Courier.of(p0)
        check("respawns at the fountain after 60 + 6 s per level", back ~= fly and U.alive(back) and not cr.dead
            and U.dist(GetUnitX(back), GetUnitY(back), f.x, f.y) < 600)
        check("with its items", placeOf("item_branches") == "cour")
        -- keys: F2 selects it, F3 delivers, F9 grabs the stash
        M.selection = {hero}
        T.press(p0, 113)
        check("F2 selects the courier", #M.selection == 1 and M.selection[1] == back)
        Hud.tick()
        advance(0.2)
        check("the HUD shows the courier's items", Use.view[p0] == "cour" and F.slots[0].item ~= nil
            and Items.nameOf(F.slots[0].item) == "item_branches", Use.view[p0])
        drag(F.slots[0].b, F.bag[1].b)
        check("drag between the courier's slots", Items.nameOf(Inv.get(p0, "cour", 7)) == "item_branches")
        M.click(F.bag[1].b, p0)
        M.click(F.slots[2].b, p0)
        check("courier items are not used", Use.pending[p0] == nil)
        local rw, ri, robe = placeOf("item_robe")
        if robe then
            Inv.take(p0, rw, ri)
            Items.remove(nil, robe)
        end
        SetUnitPosition(back, GetUnitX(hero) + 100, GetUnitY(hero))
        T.press(p0, 114)
        advance(0.3)
        check("F3 delivers", placeOf("item_branches") == "main", placeOf("item_branches"))
        atHome()
        Inv.put(p0, Items.make("item_mantle", 0), "stash")
        T.press(p0, 120)
        check("F9 grabs the stash", placeOf("item_mantle") == "main")
        M.selection = {hero}
        Hud.tick()
        advance(0.2)

        wipe()
        aliveHome()
        Log.info("inventory exercise: " .. checks .. " checks, " .. failures .. " failed")
    end

    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("inventory") or not defined("dota_hud") then return end
        done = true
        use("safe").call(exercise)
        for name, fn in pairs(saved) do _G[name] = fn end
        for _, fn in ipairs(restore) do fn() end
        use("log").flush()
    end
end
