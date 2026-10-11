-- Dota 2 items. The fountain shops sell power-up "tokens" (tools/gen_objects.py);
-- buying one, or clicking an item in the Dota shop panel (dota_shop.lua), runs
-- a purchase the Dota way: the player pays only for the parts they do not own
-- yet (main inventory, backpack, stash, courier), every missing part (a basic
-- item or a recipe scroll) is delivered on its own through inventory.lua (to
-- the hero at the home shop, else to the stash; Secret Shop parts need the
-- hero or the courier at a Secret Shop) and upgrades form as soon as their
-- parts meet in one place. Passive stats go through one persistent modifier
-- per unit (item_passives.lua: Dota stacking rules, procs, auras); actives are
-- item_actives.lua. Items remember who bought them (istate.owner): an ally
-- may carry them, but only Dota's shareable items work for an ally.
-- Selling gives half the cost back, the full cost within 10 s of the purchase.
-- Start with use("items").init() after use("structures").create().
define("items", function()
    local Events = use("events")
    local Timer = use("timer")
    local Mods = use("mods")
    local U = use("util")
    local Log = use("log")
    local Items = {started = false, shops = {}, secretShops = {}, state = {}, SHOP_RANGE = 900}

    -- Dota 2 wiki, https://dota2.fandom.com/wiki/Module:Attribute_bonuses/data:
    -- "item sellback time window" 10 s (full price back), "backpack cooldown
    -- rate" 0.5 (https://dota2.fandom.com/wiki/Inventory: anywhere off the
    -- main inventory).
    Items.SELLBACK = 10
    Items.PARK_RATE = 0.5

    local DATA                 -- use("data.items").items
    local IDS                  -- use("data.ids")
    local nameOf = {}          -- inventory item type id -> Dota name
    local tokenOf = {}         -- shop token type id -> Dota name
    local abilOf = {}          -- item ability id -> Dota name
    local realId, abilId = {}, {}
    local upgrades = {}        -- recipe items, most expensive first (combine order)
    local within = {}          -- name -> {upgrade = true} for every upgrade built from it
    local busy = {}            -- unit -> true while this module edits its inventory
    local istate = {}          -- item -> per-item state (charges, BKB level, Treads attribute, owner, ...)
    local ICON = "ReplaceableTextures\\CommandButtons\\BTNDota_%s.blp"
    local OWNED = {"main", "bag", "stash", "cour"}
    local HELD = {"main", "bag"}

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

    -- The player's main hero (its items live in inventory.lua's places).
    local function mainHero(u)
        return u ~= nil and use("heroes").bySlot[GetPlayerId(GetOwningPlayer(u))] == u
    end
    Items.isMainHero = mainHero

    -- ------------------------------------------------------------ owners
    -- Dota: an item belongs to the player who bought it. Allies can carry
    -- it, but only shareable items work for them, and stacks of different
    -- owners stay apart (wards excepted).

    function Items.ownerOf(it) local s = istate[it] return s and s.owner end

    function Items.ownedBy(it, pid)
        local o = Items.ownerOf(it)
        return o == nil or o == pid
    end

    function Items.sameOwner(a, b)
        local name = Items.nameOf(a)
        if name == "item_ward_observer" or name == "item_ward_sentry" then return true end
        return Items.ownerOf(a) == Items.ownerOf(b)
    end

    -- Dota's free first Town Portal Scroll (and a stack it joined) cannot be sold.
    function Items.unsellable(it)
        local s = istate[it]
        return s ~= nil and s.unsellable == true
    end

    function Items.usableBy(it, u)
        if Items.ownedBy(it, GetPlayerId(GetOwningPlayer(u))) then return true end
        local e = DATA[Items.nameOf(it) or ""]
        return e ~= nil and e.shareable == true
    end

    -- ------------------------------------------------------------ cooldowns
    -- As in Dota, a cooldown belongs to the item and travels with it. WC3's
    -- remaining-cooldown read can return 0 for Channel abilities, so each use
    -- is timed here too; once the read returned a positive value after a use,
    -- it is trusted for that item while a main inventory holds it (it then
    -- also follows Refresher, Rearm and cooldown reductions). Off the main
    -- inventory (backpack, stash, courier) the item is "parked": its
    -- cooldown runs at PARK_RATE.

    local function parkedLeft(s, now)
        local k = s.park
        local gone = (now - k.at) * k.rate
        return k.left - gone, k.lock - gone
    end

    -- Seconds left and the full length of the item's cooldown; pass the unit
    -- whose main inventory holds the item to include WC3's own value.
    function Items.cdLeft(it, holder)
        local s = it and istate[it]
        if not s or not s.cdEnd then return 0, 0 end
        local left
        if s.park then
            left = parkedLeft(s, Timer.now())
        else
            left = s.cdEnd - Timer.now()
            if holder and s.native then
                local id = abilId[nameOf[GetItemTypeId(it)]]
                if id then left = BlzGetUnitAbilityCooldownRemaining(holder, id) end
            end
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
        if not s or not s.lockEnd then return 0 end
        if s.park then return math.max(0, select(2, parkedLeft(s, Timer.now()))) end
        return math.max(0, s.lockEnd - Timer.now())
    end

    -- An item active was used (item_actives.lua, at the effect).
    function Items.used(u, it, name)
        local id, e = abilId[name], DATA[name]
        local dur = (e and e.cooldown) or 0
        if not it or not id or dur <= 0 then return end
        local s = Items.istate(it)
        s.cdEnd, s.cdDur, s.native, s.swap = Timer.now() + dur, dur, false, nil
        Timer.after(0, function()
            if GetItemTypeId(it) == 0 then return end
            -- WC3 may not have started it (e.g. a move of the caster inside
            -- the cast's effect event, as Blink's, ends the cast first);
            -- started here, WC3's own checks and Tinker's Rearm see it too
            local wc3 = BlzGetUnitAbilityCooldownRemaining(u, id)
            if wc3 <= 0 and GetUnitAbilityLevel(u, id) > 0 then BlzStartUnitAbilityCooldown(u, id, dur) end
            local started = BlzGetUnitAbilityCooldownRemaining(u, id)
            if started > 0 then s.native = true end
            if BUILD_TEST_MODE then
                Log.info(string.format("item used %s: wc3 cooldown %.1f after the cast, %.1f after the start",
                    name, wc3, started))
                Log.flush()
            end
        end)
    end

    -- Dota's answer to a use while the item recharges: "Recharging..." in
    -- the red error line, the cooldown beep and the hero's "not yet".
    local RECHARGING = "dota_hud_error_item_in_cooldown"
    local function recharging(hero)
        local p = GetOwningPlayer(hero)
        if not use("roles").humans[GetPlayerId(p)] then return end
        local msg = use("data.strings")[RECHARGING] or RECHARGING
        if defined("dota_glyph") and use("dota_glyph").started then
            use("dota_glyph").error(p, msg)
        else
            Items.msg(p, "|cffff4040" .. msg .. "|r")
        end
        if defined("gamesounds") then use("gamesounds").castFail(hero, "cooldown") end
    end

    -- Whether `hero` may use `it` now, refused the Dota way while the item
    -- recharges. Every item use asks first: HUD clicks and keys, quick
    -- cast, the TP slot, and item_actives at cast start (bots, the rest).
    -- `via` names the path in the test-build trace, which also shows WC3's
    -- own remaining cooldown.
    function Items.ready(hero, it, via)
        local left, lock = Items.cdLeft(it, hero), Items.locked(it)
        local ok = math.max(left, lock) <= 0.05
        if not ok then recharging(hero) end
        if BUILD_TEST_MODE then
            local name = nameOf[GetItemTypeId(it)]
            local id = abilId[name]
            Log.info(string.format("item use %s via %s: cooldown %.1f, lock %.1f, wc3 %.1f -> %s", tostring(name),
                via, left, lock, id and BlzGetUnitAbilityCooldownRemaining(hero, id) or -1, ok and "ok" or "refused"))
            Log.flush()
        end
        return ok
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

    -- The item went off the main inventory: its cooldown and lock run at
    -- `rate` (default PARK_RATE) from now on.
    function Items.park(it, rate)
        local s = istate[it]
        if not s or (not s.cdEnd and not s.lockEnd) then return end
        local left, lock = Items.cdLeft(it), Items.locked(it)
        if left <= 0 and lock <= 0 then
            s.park = nil
            return
        end
        s.cdEnd, s.cdDur = s.cdEnd or Timer.now(), s.cdDur or 0
        s.park = {left = left, lock = lock, at = Timer.now(), rate = rate or Items.PARK_RATE}
        s.native = false
    end

    -- The item entered the hero's main inventory or TP slot: its cooldown
    -- runs at full speed again and WC3 gets the time left.
    function Items.unpark(it, holder)
        local s = istate[it]
        if s and s.park then
            local now = Timer.now()
            local left, lock = parkedLeft(s, now)
            s.park = nil
            s.cdEnd, s.lockEnd, s.native = now + math.max(0, left), now + math.max(0, lock), false
        end
        if holder then Items.restoreCooldown(it, holder) end
    end

    -- The backpack swap's cooldown: `seconds` unless the item's own cooldown
    -- is longer. A shop visit lifts it again (Items.clearSwap).
    function Items.swapLock(it, seconds, holder)
        local s = Items.istate(it)
        s.swap = {cdEnd = s.cdEnd, cdDur = s.cdDur, lockEnd = s.lockEnd, ends = Timer.now() + seconds}
        Items.startCooldown(it, seconds, holder)
    end

    function Items.clearSwap(it, holder)
        local s = istate[it]
        local w = s and s.swap
        if not w then return end
        s.swap = nil
        local now = Timer.now()
        if now >= w.ends then return end
        s.lockEnd, s.cdEnd, s.cdDur, s.native = w.lockEnd, w.cdEnd, w.cdDur, false
        local id = abilId[nameOf[GetItemTypeId(it)]]
        if holder and id then
            BlzEndUnitAbilityCooldown(holder, id)
            if s.cdEnd and s.cdEnd - now > 0.05 then BlzStartUnitAbilityCooldown(holder, id, s.cdEnd - now) end
        end
    end

    -- ------------------------------------------------------------ inventory

    -- Dota items in the unit's WC3 inventory (the main slots): list of {item, name, slot}.
    function Items.carried(u)
        local out = {}
        for i = 0, UnitInventorySize(u) - 1 do
            local it = UnitItemInSlot(u, i)
            local name = it and nameOf[GetItemTypeId(it)]
            if name then out[#out + 1] = {item = it, name = name, slot = i} end
        end
        return out
    end

    -- What the unit's player owns for purchases and recipes: for a main hero
    -- its main inventory, backpack, stash and courier; else the unit's items.
    function Items.owned(u)
        if not mainHero(u) then return Items.carried(u) end
        return use("inventory").entries(GetOwningPlayer(u), OWNED, true)
    end

    -- What the hero holds itself (main inventory and backpack).
    local function held(u)
        if not mainHero(u) then return Items.carried(u) end
        return use("inventory").entries(GetOwningPlayer(u), HELD, true)
    end

    function Items.find(u, name)
        for i = 0, UnitInventorySize(u) - 1 do
            local it = UnitItemInSlot(u, i)
            if it and nameOf[GetItemTypeId(it)] == name then return it end
        end
        return nil
    end

    -- The item an item ability of `u` belongs to: the main inventory, or the
    -- TP slot for the Town Portal Scroll.
    function Items.held(u, name)
        local it = Items.find(u, name)
        if not it and name == "item_tpscroll" then it = use("inventory").tpItem(u) end
        return it
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

    -- True when the unit's player owns `name` or an upgrade built from it.
    function Items.covers(u, name)
        for _, c in ipairs(Items.owned(u)) do
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

    local function initial(it, name)
        local e = DATA[name]
        if e.consumable then SetItemCharges(it, e.charges or 1) end
        if name == "item_hand_of_midas" then
            Items.setCharges(it, 1)
            Items.istate(it).restoreAt = Timer.now() + Items.val(name, "charge_restore")
        elseif name == "item_magic_stick" or name == "item_magic_wand" then
            Items.setCharges(it, 0)
        end
    end

    -- A fresh Dota item in the unit's WC3 inventory (the caller checked for room).
    local function give(u, name)
        busy[u] = true
        local it = UnitAddItemById(u, realId[name])
        busy[u] = nil
        if not it then return nil end
        initial(it, name)
        Items.istate(it).owner = GetPlayerId(GetOwningPlayer(u))
        return it
    end

    -- A fresh Dota item of player `pid`, hidden until inventory.lua places it.
    function Items.make(name, pid)
        local it = CreateItem(realId[name], 0, 0)
        use("inventory").hide(it)
        initial(it, name)
        Items.istate(it).owner = pid
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
    function Items.combined(it, name, alt, stickCharges)
        if not it then return end
        if name == "item_magic_wand" then
            Items.setCharges(it, math.min(stickCharges or 0, math.floor(Items.val(name, "max_charges"))))
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

    local function withScroll(r, alt)
        local parts = {}
        for _, p in ipairs(alt) do parts[#parts + 1] = p end
        if r.scroll then parts[#parts + 1] = r.scroll end
        return parts
    end

    -- The most expensive upgrade whose parts (and scroll) are all in
    -- `pool`: returns its name, the entries it uses and the variant.
    function Items.recipeIn(pool)
        for _, name in ipairs(upgrades) do
            local r = DATA[name].recipe
            for _, alt in ipairs(r.parts) do
                local used = match(pool, withScroll(r, alt))
                if used then return name, used, alt end
            end
        end
        return nil
    end

    -- Removes the items of `used` (entries); `hero` holds the main ones.
    -- Returns the Magic Stick charges they carried.
    function Items.consume(used, hero)
        local stick = 0
        for _, c in ipairs(used) do
            if c.name == "item_magic_stick" then stick = stick + Items.charges(c.item) end
            take((c.where == nil or c.where == "main") and hero or nil, c.item)
        end
        return stick
    end

    -- Units other than a player's main hero (illusions, clones) combine in
    -- their own WC3 inventory.
    function Items.combine(u)
        for _ = 1, 8 do
            local name, used, alt = Items.recipeIn(Items.carried(u))
            if not name then return end
            local stick = Items.consume(used, u)
            Items.combined(give(u, name), name, alt, stick)
        end
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

    -- What a purchase of `name` takes for this unit's player, reusing owned
    -- components at any depth: gold still to pay, the owned entries the
    -- recipe uses, the variant chosen and the parts to buy (basic items and
    -- recipe scrolls).
    local function plan(u, name)
        local pool = Items.owned(u)
        local used, buy, cost = {}, {}, 0
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
                buy[#buy + 1] = n
                return nil
            end
            local alt = variant(r, pool)
            for _, p in ipairs(alt) do need(p, false) end
            if r.scroll then
                local c = grab(pool, r.scroll)
                if c then
                    used[#used + 1] = c
                else
                    cost = cost + r.cost
                    buy[#buy + 1] = r.scroll
                end
            end
            return alt
        end
        local alt = need(name, true)
        return cost, used, alt, buy
    end

    -- Gold a purchase of `name` costs this unit's player right now.
    function Items.price(u, name)
        local e = DATA[name]
        if not e then return math.huge end
        if e.result or not e.recipe then return e.cost end
        return (plan(u, name))
    end

    -- An upgrade that a new `name` completes with held items (so it needs no
    -- free slot): returns the upgrade or nil.
    local function completes(pool, name)
        pool[#pool + 1] = {name = name, fresh = true}
        for _, up in ipairs(upgrades) do
            local r = DATA[up].recipe
            for _, alt in ipairs(r.parts) do
                local used = match(pool, withScroll(r, alt))
                if used then
                    for _, c in ipairs(used) do
                        if c.fresh then return up end
                    end
                end
            end
        end
        return nil
    end

    -- Whether buying `name` would end up on the hero itself (a free main or
    -- backpack slot, a stack, or an upgrade it completes). Bots shop by this.
    function Items.canReceive(u, name)
        local e = DATA[name]
        if not e then return false end
        local room = Items.freeSlots(u)
        if mainHero(u) then room = room + use("inventory").free(GetOwningPlayer(u), "bag") end
        if room > 0 then return true end
        local pool = held(u)
        if e.stack then
            for _, c in ipairs(pool) do
                if c.name == name then return true end
            end
        end
        if e.recipe then
            local _, used = plan(u, name)
            if #used > 0 then return true end
        end
        return completes(pool, name) ~= nil
    end

    -- Where a Secret Shop part bought now goes: "hero" or "cour" when one of
    -- them stands at a Secret Shop, else nil. Bots shop at the fountain
    -- only; Dota's bots send their courier for these, so here a bot at the
    -- home shop gets them in hand.
    function Items.secretHand(u)
        local p = GetOwningPlayer(u)
        local hero = use("heroes").bySlot[GetPlayerId(p)] or u
        if U.alive(hero) and Items.nearSecret(hero) then return "hero" end
        local c = use("inventory").courier(p)
        if c and Items.nearSecret(c) then return "cour" end
        if use("roles").isBot(GetPlayerId(p)) and use("inventory").atHome(p) then return "hero" end
        return nil
    end

    local WHY = {
        secret = "Buy it at a Secret Shop (the hero or the courier must stand there)",
        owned = "You already own every part of it",
        gold = "Not enough gold",
        unknown = "Cannot buy that",
    }
    Items.WHY = WHY

    local function refuse(u, name, paid, why)
        local p = GetOwningPlayer(u)
        if paid and paid > 0 then addGold(p, paid) end
        Items.msg(p, "|cffff6060" .. (WHY[why] or why) .. "|r - " .. DATA[name].title
            .. ((paid and paid > 0) and " refunded." or ""))
        return false, why
    end

    -- A purchase of `name` by unit u's player. `paid`: gold a WC3 shop token
    -- already took (the difference is refunded), nil to charge the price
    -- here. Each missing part goes to the hero at the home shop, a Secret
    -- Shop part to the hero or courier standing at a Secret Shop, everything
    -- else to the stash. Returns true, or false and the reason ("unknown",
    -- "owned", "secret", "gold").
    local function deliver(u, name, paid)
        local e = DATA[name]
        local p = GetOwningPlayer(u)
        local hero = use("heroes").bySlot[GetPlayerId(p)]
        if not e or not hero then
            if paid and paid > 0 then addGold(p, paid) end
            return false, "unknown"
        end
        if name == use("talents").SHARD then return use("talents").buyShard(hero, e, paid) end
        local cost, _, _, buy = plan(hero, name)
        if #buy == 0 then
            if paid and paid > 0 then addGold(p, paid) end
            return false, "owned"
        end
        local secret = nil
        for _, n in ipairs(buy) do
            if DATA[n].secret then
                secret = secret or Items.secretHand(hero)
                if not secret then
                    if paid and paid > 0 then addGold(p, paid) end
                    return false, "secret"
                end
            end
        end
        if paid then
            if paid ~= cost then addGold(p, paid - cost) end
        elseif gold(p) < cost then
            return false, "gold"
        else
            addGold(p, -cost)
        end
        local Inv = use("inventory")
        local home = Inv.atHome(p)
        local now = Timer.now()
        for _, n in ipairs(buy) do
            local it = Items.make(n, GetPlayerId(p))
            Items.istate(it).boughtAt = now
            local to = "stash"
            if home then
                to = "hero"
            elseif DATA[n].secret then
                to = secret
            end
            Inv.receive(p, it, to)
        end
        Inv.changed(p)
        if paid and paid > cost then
            Items.msg(p, "Owned parts used: |cffffcc00" .. math.floor(paid - cost) .. "|r gold refunded.")
        end
        return true, "ok"
    end

    -- Delivers `name` to `u` after `paid` gold was taken (a shop token).
    function Items.buy(u, name, paid)
        local ok, why = deliver(u, name, paid)
        if not ok then
            Items.msg(GetOwningPlayer(u), "|cffff6060" .. (WHY[why] or why) .. "|r - " .. DATA[name].title
                .. " refunded.")
        end
        return ok, why
    end

    -- A purchase from the shop panel or a bot: pays the current price and
    -- delivers. Returns true, or false and the reason.
    function Items.purchase(u, name)
        if not DATA[name] then return false, "unknown" end
        return deliver(u, name, nil)
    end

    -- Gold a sale of `it` gives: half the cost, the full cost within
    -- SELLBACK seconds of its purchase; consumables by charges left.
    function Items.sellValue(it)
        local name = Items.nameOf(it)
        local e = name and DATA[name]
        if not e then return 0 end
        local s = istate[it]
        local fresh = s ~= nil and s.boughtAt ~= nil and Timer.now() - s.boughtAt <= Items.SELLBACK
        local value = e.cost * (fresh and 1 or 0.5)
        if e.consumable then value = value * GetItemCharges(it) / math.max(1, e.charges or 1) end
        return math.floor(value + 0.5)
    end

    -- Sells `it` for unit u's player, wherever the player keeps it.
    function Items.sell(u, it)
        local name = Items.nameOf(it)
        if not name then return 0 end
        local value = Items.sellValue(it)
        local p = GetOwningPlayer(u)
        local Inv = use("inventory")
        local where, i = nil, nil
        if mainHero(u) then where, i = Inv.find(p, it) end
        if where and where ~= "main" then
            Inv.take(p, where, i)
            take(nil, it)
        else
            take(u, it)
        end
        addGold(p, value)
        Items.changed(u)
        return value
    end

    -- The next thing to buy on the way to `target`: a missing basic item or
    -- recipe scroll (parts combine on their own). Returns name, price or nil.
    function Items.nextPart(u, target)
        if not DATA[target] then return nil end
        local pool = Items.owned(u)
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

    local function near(list, u, range)
        for _, s in ipairs(list) do
            if U.alive(s) and U.unitDist(u, s) <= range then return true end
        end
        return false
    end

    -- In range of the home shops (the fountain).
    function Items.nearHome(u, range) return near(Items.shops, u, range or Items.SHOP_RANGE) end

    -- In range of a Secret Shop.
    function Items.nearSecret(u, range) return near(Items.secretShops, u, range or Items.SHOP_RANGE) end

    -- In range of any shop.
    function Items.nearShop(u, range)
        return Items.nearHome(u, range) or Items.nearSecret(u, range)
    end

    -- ------------------------------------------------------------ stats

    -- Recomputes the unit's item modifier, proc state and cast range bonus
    -- from the items in its main inventory that work for it.
    function Items.refresh(u)
        Events.emit("items_changed", u)          -- talents.lua: Aghanim's Scepter
        if not U.alive(u) or IsUnitIllusion(u) then return end
        local P = use("item_passives")
        local usable = {}
        for _, c in ipairs(Items.carried(u)) do
            if Items.usableBy(c.item, u) then usable[#usable + 1] = c end
        end
        local props, st = P.compute(u, usable)
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
        if mainHero(u) then
            use("inventory").changed(GetOwningPlayer(u))
            return
        end
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
                if c.name == name and c.item ~= it and Items.sameOwner(c.item, it) then
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

    -- The structures module places the first shop; the other home shops
    -- stand on an arc south-west of the fountain, away from the base exits.
    -- The Secret Shop's items sell at the map's Secret Shops
    -- (mapdata.side_shops); without them at the fountain too.
    local function createShops()
        local S = use("structures")
        local m = use("data.mapdata")
        local f = m.dota.fountain
        local spots = m.side_shops or {}
        Items.shops, Items.secretShops = {}, {}
        if S.shop then Items.shops[1] = S.shop end
        local shops = use("data.items").shops
        local k = 0
        for i = 2, #shops do
            local code = IDS.units["shop" .. i]
            if code then
                if shops[i].key == "secret" and #spots > 0 then
                    for _, pos in ipairs(spots) do
                        Items.secretShops[#Items.secretShops + 1] = CreateUnit(Player(SLOT_ANCIENTS), FourCC(code),
                            pos.x, pos.y, 270)
                    end
                else
                    local a = math.rad(300 - k * 18)
                    k = k + 1
                    Items.shops[#Items.shops + 1] = CreateUnit(Player(SLOT_ANCIENTS), FourCC(code),
                        f.x + 820 * math.cos(a), f.y + 820 * math.sin(a), 270)
                end
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
        Log.info("items: " .. n .. " Dota items, " .. #Items.shops .. " home shops, "
            .. #Items.secretShops .. " Secret Shops")
    end

    return Items
end)
