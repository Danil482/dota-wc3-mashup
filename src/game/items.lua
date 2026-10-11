-- Dota 2 items. The fountain shops sell power-up "tokens" (tools/gen_objects.py);
-- buying one gives the real item here, using the components the buyer carries
-- (their cost is refunded, so only missing parts are paid for) and combining
-- recipes the Dota way: an upgrade forms as soon as its parts (and recipe
-- scroll, if it has one) are in the inventory. Buying a recipe scroll alone
-- also works. Passive stats go through one persistent modifier per unit
-- (item_passives.lua: Dota stacking rules, procs, auras); actives are
-- item_actives.lua. Selling back is WC3's native pawn at 50 %.
-- SIMPLIFIED: the 6 WC3 inventory slots are the only storage (no backpack,
-- stash or courier); a purchase with no room is refunded.
-- Start with use("items").init() after use("structures").create().
define("items", function()
    local Events = use("events")
    local Timer = use("timer")
    local Mods = use("mods")
    local U = use("util")
    local Log = use("log")
    local Items = {started = false, shops = {}, state = {}, SHOP_RANGE = 900}

    local DATA                 -- use("data.items").items
    local IDS                  -- use("data.ids")
    local nameOf = {}          -- inventory item type id -> Dota name
    local tokenOf = {}         -- shop token type id -> Dota name
    local abilOf = {}          -- item ability id -> Dota name
    local realId, abilId = {}, {}
    local upgrades = {}        -- recipe items, most expensive first (combine order)
    local within = {}          -- name -> {upgrade = true} for every upgrade built from it
    local busy = {}            -- unit -> true while this module edits its inventory
    local istate = {}          -- item -> per-item state (charges, BKB level, Treads attribute, ...)
    local ICON = "ReplaceableTextures\\CommandButtons\\BTNDota_%s.blp"

    -- ------------------------------------------------------------ lookups

    function Items.setup()
        if DATA then return end
        DATA = use("data.items").items
        IDS = use("data.ids")
        for name, code in pairs(IDS.items or {}) do
            realId[name] = FourCC(code)
            nameOf[FourCC(code)] = name
        end
        for name, code in pairs(IDS.item_tokens or {}) do tokenOf[FourCC(code)] = name end
        for name, code in pairs(IDS.item_abilities or {}) do
            abilId[name] = FourCC(code)
            abilOf[FourCC(code)] = name
        end
        local function mark(top, name)
            local r = DATA[name] and DATA[name].recipe
            if not r then return end
            for _, alt in ipairs(r.parts) do
                for _, p in ipairs(alt) do
                    within[p] = within[p] or {}
                    within[p][top] = true
                    mark(top, p)
                end
            end
        end
        for name, e in pairs(DATA) do
            if e.recipe then
                upgrades[#upgrades + 1] = name
                mark(name, name)
            end
        end
        table.sort(upgrades, function(a, b)
            if DATA[a].cost ~= DATA[b].cost then return DATA[a].cost > DATA[b].cost end
            return a < b
        end)
    end

    function Items.data(name) return DATA[name] end
    function Items.nameOf(item) return item and nameOf[GetItemTypeId(item)] end
    function Items.tokenName(item) return item and tokenOf[GetItemTypeId(item)] end
    function Items.abilityItem(abil) return abilOf[abil] end
    function Items.abilityId(name) return abilId[name] end
    function Items.icon(key) return string.format(ICON, key) end

    -- Dota value of an item at a level (default 1); 0 when absent.
    function Items.val(name, key, level)
        local e = DATA[name]
        local raw = e and e.values and e.values[key]
        if raw == nil then return 0 end
        return U.levelValue(raw, level or 1)
    end

    function Items.istate(item)
        local s = istate[item]
        if not s then
            s = {}
            istate[item] = s
        end
        return s
    end

    -- Lua-side charges (Magic Stick, Magic Wand, Hand of Midas), shown as item charges.
    function Items.charges(item)
        local s = istate[item]
        return s and s.charges or 0
    end

    function Items.setCharges(item, n)
        n = math.max(0, math.floor(n))
        Items.istate(item).charges = n
        SetItemCharges(item, n)
    end

    -- ------------------------------------------------------------ cooldowns
    -- As in Dota, a cooldown belongs to the item and travels with it. WC3's
    -- remaining-cooldown read can return 0 for Channel-based abilities, so each
    -- use is timed here too; once the read returned a positive value after a
    -- use, it is trusted for that item while a main inventory holds it (it
    -- then also follows Refresher, Rearm and cooldown reductions).

    -- Seconds left and the full length of the item's cooldown; pass the unit
    -- whose main inventory holds the item to include WC3's own value.
    function Items.cdLeft(it, holder)
        local s = it and istate[it]
        if not s or not s.cdEnd then return 0, 0 end
        local left = s.cdEnd - Timer.now()
        if holder and s.native then
            local id = abilId[nameOf[GetItemTypeId(it)]]
            if id then left = BlzGetUnitAbilityCooldownRemaining(holder, id) end
        end
        if left <= 0.01 then return 0, s.cdDur end
        return left, math.max(s.cdDur, left)
    end

    -- Puts the item on cooldown for at least `seconds` (Blink's damage lock,
    -- the backpack swap); `holder` carries it in a main inventory, if any.
    -- Such a lock is also enforced in Lua (Items.locked), in case WC3 does not
    -- take a started cooldown on an item ability.
    function Items.startCooldown(it, seconds, holder)
        local s = Items.istate(it)
        local now = Timer.now()
        s.lockEnd = math.max(s.lockEnd or 0, now + seconds)
        if Items.cdLeft(it, holder) >= seconds then return end
        s.cdEnd, s.cdDur, s.native = now + seconds, seconds, false
        local id = abilId[nameOf[GetItemTypeId(it)]]
        if holder and id then BlzStartUnitAbilityCooldown(holder, id, seconds) end
    end

    -- Seconds left of a lock set by Items.startCooldown.
    function Items.locked(it)
        local s = it and istate[it]
        return s and s.lockEnd and math.max(0, s.lockEnd - Timer.now()) or 0
    end

    -- An item active was used (item_actives.lua, at the effect).
    function Items.used(u, it, name)
        local id, e = abilId[name], DATA[name]
        local dur = (e and e.cooldown) or 0
        if not it or not id or dur <= 0 then return end
        local s = Items.istate(it)
        s.cdEnd, s.cdDur, s.native = Timer.now() + dur, dur, false
        Timer.after(0, function()
            if GetItemTypeId(it) ~= 0 and BlzGetUnitAbilityCooldownRemaining(u, id) > 0 then s.native = true end
        end)
    end

    -- Before an item leaves a main inventory: WC3's value becomes the timed one.
    function Items.settleCooldown(it, holder)
        local s = istate[it]
        if not s or not s.cdEnd then return end
        local left = Items.cdLeft(it, holder)
        s.cdEnd, s.native = Timer.now() + left, false
    end

    -- After an item entered a main inventory: WC3 gets the time left.
    function Items.restoreCooldown(it, holder)
        local left = Items.cdLeft(it)
        local id = abilId[nameOf[GetItemTypeId(it)]]
        if left > 0.05 and id then BlzStartUnitAbilityCooldown(holder, id, left) end
    end

    -- ------------------------------------------------------------ inventory

    -- Dota items the unit carries: list of {item, name, slot}.
    function Items.carried(u)
        local out = {}
        for i = 0, UnitInventorySize(u) - 1 do
            local it = UnitItemInSlot(u, i)
            local name = it and nameOf[GetItemTypeId(it)]
            if name then out[#out + 1] = {item = it, name = name, slot = i} end
        end
        return out
    end

    function Items.find(u, name)
        for i = 0, UnitInventorySize(u) - 1 do
            local it = UnitItemInSlot(u, i)
            if it and nameOf[GetItemTypeId(it)] == name then return it end
        end
        return nil
    end

    function Items.freeSlots(u)
        local n = 0
        for i = 0, UnitInventorySize(u) - 1 do
            local it = UnitItemInSlot(u, i)
            if it == nil or GetItemTypeId(it) == 0 then n = n + 1 end
        end
        return n
    end

    -- True when `name` appears anywhere in the recipe tree of `goal`.
    function Items.partOf(name, goal)
        return within[name] ~= nil and within[name][goal] == true
    end

    -- Bot helper: uses one carried active if a simple rule fits (item_actives.lua).
    function Items.autoUse(u)
        return use("item_actives").autoUse(u)
    end

    -- True when the unit carries `name` or an upgrade built from it.
    function Items.covers(u, name)
        for _, c in ipairs(Items.carried(u)) do
            if c.name == name or (within[name] and within[name][c.name]) then return true end
        end
        return false
    end

    local function gold(p) return GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD) end

    local function addGold(p, n)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, gold(p) + math.floor(n + 0.5))
    end

    function Items.msg(p, text)
        DisplayTimedTextToPlayer(p, 0, 0, 4, text)
    end

    function Items.text(u, s, r, g, b)
        local t = CreateTextTag()
        SetTextTagText(t, s, 0.024)
        SetTextTagPos(t, GetUnitX(u), GetUnitY(u), 90)
        SetTextTagColor(t, r, g, b, 255)
        SetTextTagVelocity(t, 0, 0.035)
        SetTextTagPermanent(t, false)
        SetTextTagLifespan(t, 1.5)
        SetTextTagFadepoint(t, 0.8)
    end

    -- A fresh Dota item in the unit's inventory (the caller checked for room).
    local function give(u, name)
        busy[u] = true
        local it = UnitAddItemById(u, realId[name])
        busy[u] = nil
        if not it then return nil end
        local e = DATA[name]
        if e.consumable then SetItemCharges(it, e.charges or 1) end
        if name == "item_hand_of_midas" then
            Items.setCharges(it, 1)
            Items.istate(it).restoreAt = Timer.now() + Items.val(name, "charge_restore")
        elseif name == "item_magic_stick" or name == "item_magic_wand" then
            Items.setCharges(it, 0)
        end
        return it
    end

    local function take(u, it)
        local was = u and busy[u]
        if u then busy[u] = true end
        istate[it] = nil
        RemoveItem(it)
        if u then busy[u] = was end
    end
    Items.remove = take

    -- Runs fn with the unit's item events ignored (moves made by Lua itself).
    function Items.quiet(u, fn)
        local was = busy[u]
        busy[u] = true
        local ok, err = pcall(fn)
        busy[u] = was
        if not ok then error(err, 0) end
    end

    local TREADS = {str = "Strength", agi = "Agility", int = "Intelligence"}

    function Items.setTreads(it, attr)
        Items.istate(it).attr = attr
        BlzSetItemName(it, "Power Treads (" .. TREADS[attr] .. ")")
        BlzSetItemIconPath(it, Items.icon("item_power_treads_" .. attr))
    end

    -- Carries state into a freshly combined item: stick charges into the wand,
    -- the attribute of Power Treads from the variant used.
    local function combined(it, name, alt, stickCharges)
        if not it then return end
        if name == "item_magic_wand" then
            Items.setCharges(it, math.min(stickCharges, math.floor(Items.val(name, "max_charges"))))
        elseif name == "item_power_treads" then
            local attr = "str"
            for _, p in ipairs(alt or {}) do
                if p == "item_robe" then attr = "int" elseif p == "item_boots_of_elves" then attr = "agi" end
            end
            Items.setTreads(it, attr)
        end
    end

    -- Takes `parts` (names, duplicates allowed) out of `pool`; returns the
    -- matched entries, or nil when one is missing (pool is left untouched).
    local function match(pool, parts)
        local used, taken = {}, {}
        for _, p in ipairs(parts) do
            local found = nil
            for i, c in ipairs(pool) do
                if not taken[i] and c.name == p then
                    found = i
                    break
                end
            end
            if not found then return nil end
            taken[found] = true
            used[#used + 1] = pool[found]
        end
        return used
    end

    local function consume(u, used)
        local stick = 0
        for _, c in ipairs(used) do
            if c.name == "item_magic_stick" then stick = stick + Items.charges(c.item) end
            take(u, c.item)
        end
        return stick
    end

    -- Forms one upgrade whose parts the unit carries; returns true if it did.
    local function combineOnce(u)
        local pool = Items.carried(u)
        for _, name in ipairs(upgrades) do
            local r = DATA[name].recipe
            for _, alt in ipairs(r.parts) do
                local parts = {}
                for _, p in ipairs(alt) do parts[#parts + 1] = p end
                if r.scroll then parts[#parts + 1] = r.scroll end
                local used = match(pool, parts)
                if used then
                    local stick = consume(u, used)
                    combined(give(u, name), name, alt, stick)
                    return true
                end
            end
        end
        return false
    end

    function Items.combine(u)
        local guard = 0
        while guard < 8 and combineOnce(u) do guard = guard + 1 end
    end

    -- The recipe variant whose parts the pool covers best (Power Treads has three).
    local function variant(r, pool)
        local best, score = r.parts[1], -1
        for _, alt in ipairs(r.parts) do
            local s = 0
            for _, p in ipairs(alt) do
                for _, c in ipairs(pool) do
                    if c.name == p then
                        s = s + DATA[p].cost
                        break
                    end
                end
            end
            if s > score then best, score = alt, s end
        end
        return best
    end

    -- Removes one `n` from the pool; returns the entry or nil.
    local function grab(pool, n)
        for i, c in ipairs(pool) do
            if c.name == n then return table.remove(pool, i) end
        end
        return nil
    end

    -- Gold still to pay for `name` and the carried items its recipe would use,
    -- reusing owned components at any depth. Returns cost, used, chosen variant.
    local function plan(u, name)
        local pool = Items.carried(u)
        local used, cost = {}, 0
        local function need(n, top)
            if not top then
                local c = grab(pool, n)
                if c then
                    used[#used + 1] = c
                    return nil
                end
            end
            local r = DATA[n].recipe
            if not r then
                cost = cost + DATA[n].cost
                return nil
            end
            local alt = variant(r, pool)
            for _, p in ipairs(alt) do need(p, false) end
            if r.scroll then
                local c = grab(pool, r.scroll)
                if c then used[#used + 1] = c else cost = cost + r.cost end
            end
            return alt
        end
        local alt = need(name, true)
        return cost, used, alt
    end

    -- The carried parts that complete `result` together with its scroll.
    local function scrollParts(u, result)
        local pool = Items.carried(u)
        for _, alt in ipairs(DATA[result].recipe.parts) do
            local used = match(pool, alt)
            if used then return used, alt end
        end
        return nil
    end

    -- An upgrade that a new `name` completes with carried items (so it needs
    -- no free slot): returns upgrade, the carried entries it uses, variant.
    local function completion(u, name)
        local pool = Items.carried(u)
        local fresh = {name = name}
        pool[#pool + 1] = fresh
        for _, up in ipairs(upgrades) do
            local r = DATA[up].recipe
            for _, alt in ipairs(r.parts) do
                local parts = {}
                for _, p in ipairs(alt) do parts[#parts + 1] = p end
                if r.scroll then parts[#parts + 1] = r.scroll end
                local used = match(pool, parts)
                if used then
                    local carried, withFresh = {}, false
                    for _, c in ipairs(used) do
                        if c == fresh then withFresh = true else carried[#carried + 1] = c end
                    end
                    if withFresh then return up, carried, alt end
                end
            end
        end
        return nil
    end

    -- Gold a purchase of `name` costs this unit right now.
    function Items.price(u, name)
        local e = DATA[name]
        if not e then return math.huge end
        if e.result or not e.recipe then return e.cost end
        return (plan(u, name))
    end

    -- Whether buying `name` would find room in the inventory.
    function Items.canReceive(u, name)
        local e = DATA[name]
        if not e then return false end
        if Items.freeSlots(u) > 0 then return true end
        if e.stack and Items.find(u, name) then return true end
        if e.result then return scrollParts(u, e.result) ~= nil end
        if e.recipe then
            local _, used = plan(u, name)
            if #used > 0 then return true end
        end
        return completion(u, name) ~= nil
    end

    local function refuse(u, name, paid, why)
        local p = GetOwningPlayer(u)
        if paid > 0 then addGold(p, paid) end
        Items.msg(p, "|cffff6060" .. why .. "|r - " .. DATA[name].title .. " refunded.")
        return false
    end

    -- Delivers `name` to `u` after `paid` gold was taken (shop token or bot).
    function Items.buy(u, name, paid)
        local e = DATA[name]
        if not e then return false end
        local p = GetOwningPlayer(u)
        if e.result then
            local used, alt = scrollParts(u, e.result)
            if used then
                local stick = consume(u, used)
                combined(give(u, e.result), e.result, alt, stick)
            elseif Items.freeSlots(u) > 0 then
                give(u, name)
            else
                return refuse(u, name, paid, "Inventory full")
            end
            Items.changed(u)
            return true
        end
        if e.stack then
            local it = Items.find(u, name)
            if it then
                SetItemCharges(it, GetItemCharges(it) + (e.charges or 1))
                return true
            end
        end
        local cost, used, alt = plan(u, name)
        if #used == 0 and Items.freeSlots(u) == 0 then
            -- no room, unless the new item completes an upgrade right away
            local up, parts, variantUsed = completion(u, name)
            if not up then return refuse(u, name, paid, "Inventory full") end
            local stick = consume(u, parts)
            combined(give(u, up), up, variantUsed, stick)
            if paid ~= cost then addGold(p, paid - cost) end
            Items.changed(u)
            return true
        end
        local stick = consume(u, used)
        combined(give(u, name), name, alt, stick)
        local refund = paid - cost
        if refund ~= 0 then addGold(p, refund) end
        if refund > 0 then
            Items.msg(p, "Carried parts used: |cffffcc00" .. math.floor(refund) .. "|r gold refunded.")
        end
        Items.changed(u)
        return true
    end

    -- Bot purchase (no shop click): pays the current price and delivers.
    function Items.purchase(u, name)
        local e = DATA[name]
        if not e or not U.alive(u) then return false, "unknown" end
        local p = GetOwningPlayer(u)
        local cost = Items.price(u, name)
        if gold(p) < cost then return false, "gold" end
        if not Items.canReceive(u, name) then return false, "full" end
        addGold(p, -cost)
        return Items.buy(u, name, cost), "ok"
    end

    -- Bot sale: 50 % of the cost, scaled by charges left for consumables.
    function Items.sell(u, it)
        local name = Items.nameOf(it)
        if not name then return 0 end
        local e = DATA[name]
        local value = e.cost * 0.5
        if e.consumable then value = value * GetItemCharges(it) / math.max(1, e.charges or 1) end
        take(u, it)
        addGold(GetOwningPlayer(u), value)
        Items.changed(u)
        return math.floor(value)
    end

    -- The next thing to buy on the way to `target`: a missing basic item or
    -- recipe scroll (parts combine on their own). Returns name, price or nil.
    function Items.nextPart(u, target)
        if not DATA[target] then return nil end
        local pool = Items.carried(u)
        local function walk(n)
            if grab(pool, n) then return nil end
            local r = DATA[n].recipe
            if not r then return n end
            for _, p in ipairs(variant(r, pool)) do
                local missing = walk(p)
                if missing then return missing end
            end
            if r.scroll and not grab(pool, r.scroll) then return r.scroll end
            return nil
        end
        local part = walk(target)
        if part then return part, Items.price(u, part) end
        return nil
    end

    function Items.nearShop(u, range)
        range = range or Items.SHOP_RANGE
        for _, s in ipairs(Items.shops) do
            if U.alive(s) and U.unitDist(u, s) <= range then return true end
        end
        return false
    end

    -- ------------------------------------------------------------ stats

    -- Recomputes the unit's item modifier, proc state and cast range bonus.
    function Items.refresh(u)
        if not U.alive(u) or IsUnitIllusion(u) then return end
        local P = use("item_passives")
        local props, st = P.compute(u, Items.carried(u))
        Items.state[u] = st
        if next(props) then
            Mods.add(u, "dota_items", {props = props, persist = true, dispel = "none", effect = st.effect,
                                       attach = "origin"})
        else
            Mods.remove(u, "dota_items")
        end
        P.castRange(u, st.castRange or 0)
    end

    function Items.changed(u)
        Items.combine(u)
        Items.refresh(u)
    end

    -- An item arrived by other means (ground, ally): merge consumable stacks.
    local function arrived(u, it)
        local name = Items.nameOf(it)
        if not name or not UnitHasItem(u, it) then return end
        local e = DATA[name]
        if e.stack then
            for _, c in ipairs(Items.carried(u)) do
                if c.name == name and c.item ~= it then
                    SetItemCharges(c.item, GetItemCharges(c.item) + GetItemCharges(it))
                    take(u, it)
                    break
                end
            end
        end
        Items.changed(u)
    end

    -- EVENT_PLAYER_UNIT_PICKUP_ITEM: tokens become purchases.
    function Items.pickup(u, it)
        if busy[u] or not it then return end
        local tid = GetItemTypeId(it)
        local token = tokenOf[tid]
        if token then
            busy[u] = true
            RemoveItem(it)
            busy[u] = nil
            if IsUnitIllusion(u) then
                refuse(u, token, DATA[token].cost, "Illusions cannot shop")
            else
                Items.buy(u, token, DATA[token].cost)
            end
        elseif nameOf[tid] and not IsUnitIllusion(u) then
            Timer.after(0, function() arrived(u, it) end)
        end
    end

    function Items.drop(u, it)
        if busy[u] or not it or not nameOf[GetItemTypeId(it)] or IsUnitIllusion(u) then return end
        Timer.after(0, function() Items.changed(u) end)
    end

    -- ------------------------------------------------------------ shops

    -- The structures module places the first shop; the others stand on an arc
    -- south-west of the fountain, away from the base exits.
    local function createShops()
        local S = use("structures")
        local f = use("data.mapdata").dota.fountain
        Items.shops = {}
        if S.shop then Items.shops[1] = S.shop end
        local shops = use("data.items").shops
        for i = 2, #shops do
            local code = IDS.units["shop" .. i]
            if code then
                local a = math.rad(300 - (i - 2) * 18)
                Items.shops[#Items.shops + 1] = CreateUnit(Player(SLOT_ANCIENTS), FourCC(code),
                    f.x + 820 * math.cos(a), f.y + 820 * math.sin(a), 270)
            end
        end
    end

    local function cleanup()
        for it in pairs(istate) do
            if GetItemTypeId(it) == 0 then istate[it] = nil end
        end
        for u in pairs(Items.state) do
            if GetUnitTypeId(u) == 0 then Items.state[u] = nil end
        end
    end

    function Items.init()
        if Items.started then return end
        Items.started = true
        Items.setup()
        createShops()
        Events.on("item_pickup", Items.pickup)
        Events.on("item_drop", Items.drop)
        -- fallback: a power-up token reported as used instead of picked up
        Events.on("item_use", function(u, it)
            if it and tokenOf[GetItemTypeId(it)] then Items.pickup(u, it) end
        end)
        Events.on("hero_spawned", function(u) Items.refresh(u) end)
        Events.on("hero_respawned", function(u) Items.refresh(u) end)
        Events.on("hero_level", function(u)
            if Items.state[u] then Items.refresh(u) end
        end)
        use("item_actives").init()
        use("item_passives").init()
        Timer.every(30, cleanup)
        local n = 0
        for _ in pairs(realId) do n = n + 1 end
        Log.info("items: " .. n .. " Dota items, " .. #Items.shops .. " shops")
    end

    return Items
end)
