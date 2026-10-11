-- Dota's item storage around the hero's six WC3 inventory slots: the
-- backpack (3 slots, inactive), the stash (6 slots, at the home shop), the
-- TP scroll slot and the courier's nine slots (6 + a 3-slot backpack, all
-- inactive). Stored items are real WC3 items hidden in a map corner, so they
-- keep their charges and their Lua state (items.lua istate: cooldown,
-- charges, Power Treads' attribute, owner, ...).
--
-- Slot numbers are Dota's: 0-5 the main inventory (the hero's WC3
-- inventory), 6-8 the backpack, 9-14 the stash, 15 the TP scroll; the
-- courier's slots are 20-28 here.
--
-- Rules (Dota's glossary, resource/localization/dota_english.txt
-- DOTA_Glossary_Items_*, and https://dota2.fandom.com/wiki/Inventory):
--   * a purchase at the home shop goes to the main inventory, then the
--     backpack, then the stash; elsewhere to the stash; with the stash full
--     it drops in the fountain. Town Portal Scrolls fill the TP slot.
--   * items in the backpack are inactive. One moved from the backpack to
--     the main inventory is on cooldown for 6 s unless the hero is near a
--     shop, and walking into shop range clears that cooldown (the wiki page
--     above; https://dota2.fandom.com/wiki/Module:Attribute_bonuses/data,
--     "backpack penalty cooldown" 6). Off the main inventory cooldowns run
--     at half speed (items.lua Items.park).
--   * the stash trades with the hero only while the hero is in range of the
--     home shop. Items combine within one place (the hero's main inventory
--     and backpack, the stash, the courier); the hero's items and the stash
--     together only while the hero is at the home shop.
--
-- Multiplayer: everything here runs in synced code (frame, key and mouse
-- events, timers, unit events) and creates handles for every client alike.
-- Start with use("inventory").init() right after use("items").init().
define("inventory", function()
    local Events = use("events")
    local Timer = use("timer")
    local U = use("util")
    local Inv = {SWAP_COOLDOWN = 6, TP = 15, BAG = 6, STASH = 9, COUR = 20, started = false}

    local SIZE = {main = 6, bag = 3, stash = 6, tp = 1, cour = 9}
    local RANK = {main = 0, bag = 1, tp = 2, stash = 3, cour = 4}    -- slot order of "the first consumed slot"
    local ROUTE = {hero = {"main", "bag", "stash"}, cour = {"cour", "stash"}, stash = {"stash"}}
    local kits = {}             -- player id -> {bag = {}, stash = {}, cour = {}, tp = item, home, shop}
    local store = nil           -- where hidden items wait

    local function I() return use("items") end

    local function valid(it) return it ~= nil and GetItemTypeId(it) ~= 0 end

    function Inv.size(where) return SIZE[where] or 0 end

    function Inv.kit(p)
        local id = GetPlayerId(p)
        local k = kits[id]
        if not k then
            k = {bag = {}, stash = {}, cour = {}}
            kits[id] = k
        end
        return k
    end

    function Inv.hero(p) return use("heroes").bySlot[GetPlayerId(p)] end

    -- The player's courier while it is alive, else nil.
    function Inv.courier(p)
        local c = defined("courier") and use("courier").of(p) or nil
        return U.alive(c) and c or nil
    end

    -- The player's main hero, alive and within range of the home shop.
    function Inv.atHome(p)
        local h = Inv.hero(p)
        return h ~= nil and U.alive(h) and I().nearHome(h)
    end

    -- (location, index) of a slot number, or nil.
    function Inv.where(slot)
        if type(slot) ~= "number" then return nil end
        if slot >= 0 and slot < 6 then return "main", slot end
        if slot >= Inv.BAG and slot < Inv.BAG + 3 then return "bag", slot - Inv.BAG end
        if slot >= Inv.STASH and slot < Inv.STASH + 6 then return "stash", slot - Inv.STASH end
        if slot == Inv.TP then return "tp", 0 end
        if slot >= Inv.COUR and slot < Inv.COUR + 9 then return "cour", slot - Inv.COUR end
        return nil
    end

    function Inv.slot(where, i)
        if where == "main" then return i end
        if where == "bag" then return Inv.BAG + i end
        if where == "stash" then return Inv.STASH + i end
        if where == "tp" then return Inv.TP end
        if where == "cour" then return Inv.COUR + i end
        return nil
    end

    -- The item in a location slot of player p, nil when empty (used-up and
    -- sold items read as empty).
    function Inv.get(p, where, i)
        if where == "main" then
            local h = Inv.hero(p)
            local it = h and UnitItemInSlot(h, i) or nil
            return valid(it) and it or nil
        end
        local k = Inv.kit(p)
        if where == "tp" then
            if k.tp and not valid(k.tp) then k.tp = nil end
            return k.tp
        end
        local list = k[where]
        local it = list and list[i]
        if it ~= nil and not valid(it) then
            list[i] = nil
            it = nil
        end
        return it
    end

    function Inv.item(p, slot)
        local where, i = Inv.where(slot)
        return where and Inv.get(p, where, i) or nil
    end

    -- Dota items of player p in the given places, in slot order: list of
    -- {item, name, where, i}. `mine`: only the items p bought.
    function Inv.entries(p, wheres, mine)
        local out = {}
        local pid = GetPlayerId(p)
        for _, where in ipairs(wheres) do
            for i = 0, SIZE[where] - 1 do
                local it = Inv.get(p, where, i)
                local name = it and I().nameOf(it)
                if name and (not mine or I().ownedBy(it, pid)) then
                    out[#out + 1] = {item = it, name = name, where = where, i = i}
                end
            end
        end
        return out
    end

    function Inv.list(p, where) return Inv.entries(p, {where}) end

    function Inv.free(p, where)
        local n = 0
        for i = 0, (SIZE[where] or 0) - 1 do
            if Inv.get(p, where, i) == nil then n = n + 1 end
        end
        return n
    end

    local function freeIndex(p, where)
        for i = 0, (SIZE[where] or 0) - 1 do
            if Inv.get(p, where, i) == nil then return i end
        end
        return nil
    end

    -- Location and index of an item of player p, or nil.
    function Inv.find(p, it)
        if not valid(it) then return nil end
        for _, where in ipairs({"main", "bag", "tp", "stash", "cour"}) do
            for i = 0, SIZE[where] - 1 do
                if Inv.get(p, where, i) == it then return where, i end
            end
        end
        return nil
    end

    -- ------------------------------------------------------------ moving items

    function Inv.hide(it)
        if not store then
            local b = use("data.mapdata").bounds
            store = {x = b.min + 64, y = b.min + 64}
        end
        SetItemPosition(it, store.x, store.y)
        SetItemVisible(it, false)
    end

    -- A loose item into the hero's WC3 inventory, slot i if given.
    local function toMain(hero, it, i)
        SetItemVisible(it, true)
        local ok = false
        I().quiet(hero, function()
            ok = UnitAddItem(hero, it)
            if ok and i and UnitItemInSlot(hero, i) ~= it then UnitDropItemSlot(hero, it, i) end
        end)
        if ok then
            I().unpark(it, hero)
        else
            Inv.hide(it)
        end
        return ok
    end

    local function fromMain(hero, it)
        I().settleCooldown(it, hero)
        I().quiet(hero, function() UnitRemoveItem(hero, it) end)
        Inv.hide(it)
    end

    -- Puts a loose item into a free slot of a location (index i, else the
    -- first free one). Returns true on success.
    function Inv.put(p, it, where, i)
        if not valid(it) or not SIZE[where] then return false end
        i = i or freeIndex(p, where)
        if i == nil or Inv.get(p, where, i) ~= nil then return false end
        if where == "main" then
            local h = Inv.hero(p)
            return h ~= nil and toMain(h, it, i)
        end
        Inv.hide(it)
        if where == "tp" then
            Inv.kit(p).tp = it
            I().unpark(it, Inv.hero(p))
        else
            Inv.kit(p)[where][i] = it
            -- Dota: a Refresher Orb's cooldown stands still in the backpack (Inventory wiki page)
            I().park(it, (where == "bag" and I().nameOf(it) == "item_refresher") and 0 or nil)
        end
        return true
    end

    -- Takes the item out of a location slot; it stays loose and hidden.
    function Inv.take(p, where, i)
        local it = Inv.get(p, where, i)
        if not it then return nil end
        if where == "main" then
            fromMain(Inv.hero(p), it)
        elseif where == "tp" then
            I().settleCooldown(it, Inv.hero(p))
            Inv.kit(p).tp = nil
        else
            Inv.kit(p)[where][i] = nil
        end
        return it
    end

    -- A stack in `where` that `it` (same item, same owner) may join.
    local function stackIn(p, where, it, name)
        for i = 0, SIZE[where] - 1 do
            local s = Inv.get(p, where, i)
            if s and s ~= it and I().nameOf(s) == name and I().sameOwner(s, it) then return s end
        end
        return nil
    end

    -- Dota: an unsellable scroll makes its whole stack unsellable.
    local function join(stack, it)
        SetItemCharges(stack, GetItemCharges(stack) + math.max(1, GetItemCharges(it)))
        if I().unsellable(it) then I().istate(stack).unsellable = true end
        I().remove(nil, it)
    end

    -- A Town Portal Scroll into the TP slot, joining the scrolls there.
    local function toTp(p, it)
        local have = Inv.get(p, "tp", 0)
        if have and have ~= it then
            join(have, it)
            return true
        end
        return Inv.put(p, it, "tp", 0)
    end

    -- The first place of `route` that takes the item: a stack of the same
    -- item and owner it joins, else a free slot. Returns the place or nil.
    local function place(p, it, route)
        local name = I().nameOf(it)
        if (I().data(name or "") or {}).stack then
            for _, where in ipairs(route) do
                local s = stackIn(p, where, it, name)
                if s then
                    join(s, it)
                    return where
                end
            end
        end
        for _, where in ipairs(route) do
            if Inv.put(p, it, where) then return where end
        end
        return nil
    end

    -- Hands a loose item to player p by Dota's rules. `to`: "hero" (the hero
    -- is where the shop hands items over), "cour" (the courier at a Secret
    -- Shop) or "stash". Returns the location used ("ground": dropped in the
    -- fountain).
    function Inv.receive(p, it, to)
        if to == "hero" and not U.alive(Inv.hero(p)) then to = "stash" end
        if to == "cour" and not Inv.courier(p) then to = "stash" end
        if I().nameOf(it) == "item_tpscroll" and to == "hero" and toTp(p, it) then return "tp" end
        local got = place(p, it, ROUTE[to] or ROUTE.stash)
        if got then return got end
        local f = use("data.mapdata").dota.fountain
        SetItemPosition(it, f.x, f.y)
        SetItemVisible(it, true)
        return "ground"
    end

    -- An item an ally hands over: into the main inventory or the backpack
    -- (a Town Portal Scroll into the TP slot), joining a stack of the same
    -- owner. Returns the place, or nil when there is no room.
    function Inv.give(p, it)
        if I().nameOf(it) == "item_tpscroll" then
            local have = Inv.get(p, "tp", 0)
            if not have then return Inv.put(p, it, "tp", 0) and "tp" or nil end
            if I().sameOwner(have, it) then
                join(have, it)
                return "tp"
            end
            return nil
        end
        return place(p, it, {"main", "bag"})
    end

    -- ------------------------------------------------------------ combining

    local function before(a, b)
        if RANK[a.where] ~= RANK[b.where] then return RANK[a.where] < RANK[b.where] end
        return a.i < b.i
    end

    -- Forms the upgrades whose parts p owns in the places `wheres`; each
    -- result takes the first consumed slot. Returns true if one formed.
    local function combineIn(p, wheres)
        local formed = false
        for _ = 1, 8 do
            local name, used, alt = I().recipeIn(Inv.entries(p, wheres, true))
            if not name then break end
            local first = used[1]
            for _, c in ipairs(used) do
                if before(c, first) then first = c end
            end
            local stick = I().consume(used, Inv.hero(p))
            local it = I().make(name, GetPlayerId(p))
            I().combined(it, name, alt, stick)
            if not Inv.put(p, it, first.where, first.i) then Inv.receive(p, it, "stash") end
            formed = true
        end
        return formed
    end

    function Inv.combine(p)
        local formed = combineIn(p, {"main", "bag"})
        formed = combineIn(p, {"stash"}) or formed
        formed = combineIn(p, {"cour"}) or formed
        if Inv.atHome(p) then formed = combineIn(p, {"main", "bag", "stash"}) or formed end
        return formed
    end

    -- After any change to p's items: upgrades form (with Dota's combine
    -- sound for the player), the hero's stats follow.
    function Inv.changed(p)
        if Inv.combine(p) and defined("gamesounds") then use("gamesounds").combine(p) end
        local hero = Inv.hero(p)
        if hero then I().refresh(hero) end
    end

    -- ------------------------------------------------------------ moves

    -- The Dota cooldown of a backpack swap, unless the hero is near a shop.
    local function swapPenalty(it, hero)
        if not I().nearShop(hero) then I().swapLock(it, Inv.SWAP_COOLDOWN, hero) end
    end

    -- Moves the item in slot `from` to slot `to` (slot numbers), swapping
    -- with the item there; a stack dropped on the same item joins it.
    -- Returns true, or false and the reason to show.
    function Inv.move(p, from, to)
        local fw, fi = Inv.where(from)
        local tw, ti = Inv.where(to)
        local hero = Inv.hero(p)
        if not fw or not tw or from == to or not hero then return false end
        local a, b = Inv.get(p, fw, fi), Inv.get(p, tw, ti)
        if not a then return false end
        if (fw == "cour") ~= (tw == "cour") then return false, "The courier hands its items over by delivering them" end
        local nameA, nameB = I().nameOf(a), b and I().nameOf(b)
        local tpA, tpB = nameA == "item_tpscroll", nameB == "item_tpscroll"
        if (tw == "tp" and not tpA) or (fw == "tp" and b and not tpB) then
            return false, "Only Town Portal Scrolls go in that slot"
        end
        if (tpA and (tw == "main" or tw == "bag")) or (tpB and (fw == "main" or fw == "bag")) then
            return false, "Town Portal Scrolls stay in their own slot"
        end
        if (fw == "stash") ~= (tw == "stash") and not Inv.atHome(p) then
            return false, tw == "stash" and "Items go into the stash only at the home shop"
                or "The stash is only in reach at the home shop"
        end
        if b and nameA == nameB and (I().data(nameA) or {}).stack and I().sameOwner(a, b) then
            Inv.take(p, fw, fi)
            join(b, a)
            Inv.changed(p)
            return true
        end
        if fw == "main" and tw == "main" then
            I().quiet(hero, function() UnitDropItemSlot(hero, a, ti) end)
            return true
        end
        Inv.take(p, fw, fi)
        if b then Inv.take(p, tw, ti) end
        Inv.put(p, a, tw, ti)
        if b then Inv.put(p, b, fw, fi) end
        if fw == "bag" and tw == "main" then swapPenalty(a, hero) end
        if b and tw == "bag" and fw == "main" then swapPenalty(b, hero) end
        Inv.changed(p)
        return true
    end

    -- Dota's "Grab All": every stash item to the hero (main inventory, then
    -- backpack; Town Portal Scrolls to their slot) while it is at the home
    -- shop. Returns the number moved, or 0 and the reason.
    function Inv.grabAll(p)
        if not Inv.atHome(p) then return 0, "The stash is only in reach at the home shop" end
        local n = 0
        for i = 0, SIZE.stash - 1 do
            local it = Inv.get(p, "stash", i)
            if it then
                if I().nameOf(it) == "item_tpscroll" then
                    Inv.take(p, "stash", i)
                    toTp(p, it)
                    n = n + 1
                else
                    local where = (freeIndex(p, "main") and "main") or (freeIndex(p, "bag") and "bag")
                    if where then
                        Inv.take(p, "stash", i)
                        Inv.put(p, it, where)
                        n = n + 1
                    end
                end
            end
        end
        if n > 0 then Inv.changed(p) end
        if n == 0 and #Inv.list(p, "stash") == 0 then return 0, "The stash is empty" end
        return n
    end

    -- Bots keep their best items active: a backpack item that costs more than
    -- the cheapest main item swaps with it (once per call, so each swap gets
    -- its cooldown like a player's would).
    function Inv.arrange(p)
        local cheap, cheapCost = nil, math.huge
        for i = 0, SIZE.main - 1 do
            local it = Inv.get(p, "main", i)
            local e = it and I().data(I().nameOf(it))
            if not it then
                cheap, cheapCost = i, -1
                break
            elseif e and e.cost < cheapCost then
                cheap, cheapCost = i, e.cost
            end
        end
        local best, bestCost = nil, cheapCost
        for i = 0, SIZE.bag - 1 do
            local it = Inv.get(p, "bag", i)
            local e = it and I().data(I().nameOf(it))
            if e and e.cost > bestCost then best, bestCost = i, e.cost end
        end
        if best and cheap then return Inv.move(p, Inv.BAG + best, cheap) end
        return false
    end

    -- ------------------------------------------------------------ TP scroll slot

    -- The hero carries the TP scroll's ability as a hidden unit ability
    -- (tools/gen_objects.py item ability, order ids.orders.item_tpscroll);
    -- casting it spends a charge of the scroll in the TP slot. As an
    -- ability of the hero its cooldown is shared by every scroll (Dota:
    -- AbilitySharedCooldown "teleport").
    function Inv.tpAbility()
        local code = (use("data.ids").item_abilities or {}).item_tpscroll
        return code and FourCC(code) or nil
    end

    function Inv.tpItem(hero)
        if not hero then return nil end
        local p = GetOwningPlayer(hero)
        if Inv.hero(p) ~= hero then return nil end
        return Inv.get(p, "tp", 0)
    end

    -- Synced: teleports the player's hero toward (x, y) with the TP slot.
    function Inv.teleport(p, x, y)
        local hero = Inv.hero(p)
        local order = (use("data.ids").orders or {}).item_tpscroll
        if not hero or not U.alive(hero) or not order then return false end
        local tp = Inv.get(p, "tp", 0)
        if not tp then return false, "No Town Portal Scroll" end
        if not I().ready(hero, tp, "tp") then return false end
        return IssuePointOrder(hero, order, x, y)
    end

    -- ------------------------------------------------------------ init

    -- Each hero player's place: entering the home shop's range joins the
    -- hero's items and the stash; entering any shop's range ends backpack
    -- swap cooldowns.
    local function watch()
        for _, slot in ipairs(use("roles").heroSlots or {}) do
            local p = Player(slot)
            local hero = Inv.hero(p)
            if hero then
                local k = Inv.kit(p)
                local up = U.alive(hero)
                local home = up and I().nearHome(hero)
                local shop = up and (home or I().nearSecret(hero))
                if home and not k.home then Inv.changed(p) end
                if shop and not k.shop then
                    for i = 0, SIZE.main - 1 do
                        local it = Inv.get(p, "main", i)
                        if it then I().clearSwap(it, hero) end
                    end
                end
                k.home, k.shop = home, shop
            end
        end
    end

    -- Dota: a hero starts with a free, unsellable Town Portal Scroll, on a
    -- 100 s cooldown (https://dota2.fandom.com/wiki/Town_Portal_Scroll).
    Inv.FIRST_TP_COOLDOWN = 100

    function Inv.init()
        if Inv.started then return end
        Inv.started = true
        local id = Inv.tpAbility()
        Events.on("hero_spawned", function(u, _, slot)
            if not id or GetUnitAbilityLevel(u, id) > 0 then return end
            UnitAddAbility(u, id)
            UnitMakeAbilityPermanent(u, true, id)
            BlzUnitHideAbility(u, id, true)
            local p = Player(slot)
            if Inv.hero(p) ~= u or Inv.get(p, "tp", 0) then return end
            local tp = I().make("item_tpscroll", slot)
            I().istate(tp).unsellable = true
            Inv.put(p, tp, "tp", 0)
            I().startCooldown(tp, Inv.FIRST_TP_COOLDOWN, u)
        end)
        Timer.every(0.25, watch)
    end

    return Inv
end)
