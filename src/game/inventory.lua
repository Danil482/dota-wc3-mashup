-- Dota's item storage around the hero's six WC3 inventory slots: the
-- backpack (3 slots, inactive), the stash (6 slots, reachable while the hero
-- is in range of the home shop), the TP scroll slot and the courier's six
-- slots. Stored items are real WC3 items hidden in a map corner, so they keep
-- their charges and their Lua state (items.lua istate: cooldown, charges,
-- Power Treads' attribute, ...).
--
-- Slot numbers are Dota's: 0-5 the main inventory (the hero's WC3 inventory),
-- 6-8 the backpack, 9-14 the stash, 15 the TP scroll; the courier's slots are
-- the location "cour", 0-5.
--
-- Rules (resource/localization/dota_english.txt, DOTA_Glossary_Items_*): an
-- item bought while the hero is at the home shop goes to the main inventory,
-- then the backpack, then the stash; bought elsewhere, to the stash; with the
-- stash full it drops in the fountain. TP scrolls fill the TP slot. Items in
-- the backpack are inactive (no passives, no use); one moved from the
-- backpack to the main inventory gets DOTA_ITEM_BACKPACK_SWAP_COOLDOWN (the
-- value is in the game binary; 6 s on the Dota 2 wiki). The stash can only be
-- exchanged with while the hero is at the home shop.
--
-- Multiplayer: everything here runs in synced code (frame, key and mouse
-- events, timers, unit events) and creates handles for every client alike.
--
-- NOT WIRED YET (2026-10-11): nothing calls this module. game.lua does not
-- call Inv.init, items.lua's purchases still go to the main inventory only,
-- and the HUD shows no backpack, stash or TP slot. See the inventory agent's
-- report for the remaining steps.
define("inventory", function()
    local Events = use("events")
    local U = use("util")
    local Inv = {SWAP_COOLDOWN = 6, TP = 15, BAG = 6, STASH = 9}

    local SIZE = {main = 6, bag = 3, stash = 6, cour = 6, tp = 1}
    local kits = {}             -- player id -> {bag = {}, stash = {}, cour = {}, tp = item}
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

    -- The player's main hero within range of the home shop (alive).
    function Inv.atHome(p)
        local h = Inv.hero(p)
        return h ~= nil and U.alive(h) and I().nearShop(h)
    end

    -- (location, index) of a Dota slot number, or nil.
    function Inv.where(slot)
        if type(slot) ~= "number" then return nil end
        if slot >= 0 and slot < 6 then return "main", slot end
        if slot >= Inv.BAG and slot < Inv.BAG + 3 then return "bag", slot - Inv.BAG end
        if slot >= Inv.STASH and slot < Inv.STASH + 6 then return "stash", slot - Inv.STASH end
        if slot == Inv.TP then return "tp", 0 end
        return nil
    end

    function Inv.slot(where, i)
        if where == "main" then return i end
        if where == "bag" then return Inv.BAG + i end
        if where == "stash" then return Inv.STASH + i end
        if where == "tp" then return Inv.TP end
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

    -- Items of a location: list of {item, name, where, i}.
    function Inv.list(p, where)
        local out = {}
        for i = 0, (SIZE[where] or 0) - 1 do
            local it = Inv.get(p, where, i)
            if it then out[#out + 1] = {item = it, name = I().nameOf(it), where = where, i = i} end
        end
        return out
    end

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
        for _, where in ipairs({"main", "bag", "stash", "cour", "tp"}) do
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
            I().restoreCooldown(it, hero)
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
        if where == "tp" then Inv.kit(p).tp = it else Inv.kit(p)[where][i] = it end
        return true
    end

    -- Takes the item out of a location slot; it stays loose and hidden.
    function Inv.take(p, where, i)
        local it = Inv.get(p, where, i)
        if not it then return nil end
        if where == "main" then
            fromMain(Inv.hero(p), it)
        elseif where == "tp" then
            Inv.kit(p).tp = nil
        else
            Inv.kit(p)[where][i] = nil
        end
        return it
    end

    local function sameIn(p, where, name)
        for i = 0, SIZE[where] - 1 do
            local it = Inv.get(p, where, i)
            if it and I().nameOf(it) == name then return it end
        end
        return nil
    end

    -- Adds the charges of a TP scroll to the TP slot (or puts it there).
    local function toTp(p, it)
        local have = Inv.get(p, "tp", 0)
        if have and have ~= it then
            SetItemCharges(have, GetItemCharges(have) + math.max(1, GetItemCharges(it)))
            I().remove(nil, it)
            return true
        end
        return Inv.put(p, it, "tp", 0)
    end

    -- Hands a loose item to player p by Dota's rules. `atHand`: the hero is
    -- where items reach it (the home shop, a Secret Shop for its items).
    -- Returns the location used ("ground": dropped in the fountain).
    function Inv.receive(p, it, atHand)
        local name = I().nameOf(it)
        local e = name and I().data(name) or {}
        local hero = Inv.hero(p)
        local hand = atHand and hero ~= nil and U.alive(hero)
        if name == "item_tpscroll" and hand and toTp(p, it) then return "tp" end
        local order = hand and {"main", "bag", "stash"} or {"stash"}
        if e.stack then
            for _, where in ipairs(order) do
                local same = sameIn(p, where, name)
                if same then
                    SetItemCharges(same, GetItemCharges(same) + GetItemCharges(it))
                    I().remove(nil, it)
                    return where
                end
            end
        end
        for _, where in ipairs(order) do
            if name ~= "item_tpscroll" or where == "stash" then
                if Inv.put(p, it, where) then return where end
            end
        end
        local f = use("data.mapdata").dota.fountain
        SetItemPosition(it, f.x, f.y)
        SetItemVisible(it, true)
        return "ground"
    end

    local function swapCooldown(it, hero)
        if I().abilityId(I().nameOf(it)) then I().startCooldown(it, Inv.SWAP_COOLDOWN, hero) end
    end

    -- Moves the item in slot `from` to slot `to` (Dota slot numbers),
    -- swapping with the item there. Returns true, or false and Dota's reason.
    function Inv.move(p, from, to)
        local fw, fi = Inv.where(from)
        local tw, ti = Inv.where(to)
        local hero = Inv.hero(p)
        if not fw or not tw or from == to or not hero then return false end
        local a, b = Inv.get(p, fw, fi), Inv.get(p, tw, ti)
        if not a then return false end
        local tpA, tpB = I().nameOf(a) == "item_tpscroll", b ~= nil and I().nameOf(b) == "item_tpscroll"
        if (tw == "tp" and not tpA) or (fw == "tp" and b and not tpB) then
            return false, "Only Town Portal Scrolls fit there"
        end
        if (tpA and (tw == "main" or tw == "bag")) or (tpB and (fw == "main" or fw == "bag")) then
            return false, "Town Portal Scrolls stay in their own slot"
        end
        if (fw == "stash") ~= (tw == "stash") and not Inv.atHome(p) then
            return false, tw == "stash" and "Can't Move To Stash" or "Not in Range of Stash"
        end
        if fw == "main" and tw == "main" then
            I().quiet(hero, function() UnitDropItemSlot(hero, a, ti) end)
            return true
        end
        if tw == "tp" and b then
            -- a scroll onto the TP slot joins its stack
            Inv.take(p, fw, fi)
            toTp(p, a)
            I().changed(hero)
            return true
        end
        Inv.take(p, fw, fi)
        if b then Inv.take(p, tw, ti) end
        Inv.put(p, a, tw, ti)
        if b then Inv.put(p, b, fw, fi) end
        if fw == "bag" and tw == "main" then swapCooldown(a, hero) end
        if b and tw == "bag" and fw == "main" then swapCooldown(b, hero) end
        I().changed(hero)
        return true
    end

    -- Dota's "Grab All": every stash item to the hero (main inventory, then
    -- backpack; TP scrolls to their slot) while it is at the home shop.
    -- Returns the number moved, or 0 and the reason.
    function Inv.grabAll(p)
        local hero = Inv.hero(p)
        if not Inv.atHome(p) then return 0, "Not in Range of Stash" end
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
        if n > 0 then I().changed(hero) end
        if n == 0 and #Inv.list(p, "stash") == 0 then return 0, "No Items To Retrieve From Stash" end
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
    -- casting it spends a charge of the scroll in the TP slot.
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
        if not Inv.get(p, "tp", 0) then return false, "No Town Portal Scroll" end
        return IssuePointOrder(hero, order, x, y)
    end

    -- ------------------------------------------------------------ init

    function Inv.init()
        local id = Inv.tpAbility()
        Events.on("hero_spawned", function(u)
            if id and GetUnitAbilityLevel(u, id) == 0 then
                UnitAddAbility(u, id)
                UnitMakeAbilityPermanent(u, true, id)
            end
        end)
    end

    return Inv
end)
