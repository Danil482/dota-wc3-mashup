-- Offline exercise for the Dota items (src/game/items.lua, item_actives.lua,
-- item_passives.lua, src/ai/item_builds.lua). Adds an inventory model to the
-- mock WC3 API, then at 6 s of game time buys, combines, stacks, refunds and
-- sells items, runs every active handler once, fires the attack procs and the
-- periodic loops, and lets a bot shop. Failed checks and Lua errors become
-- ERROR log lines, which fail the mock run. Test units stand in the empty
-- bottom-right corner so nothing else in the run notices them.

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
    function UnitInventorySize(u) return 6 end
    function UnitItemInSlot(u, i) return slots(u)[i] end
    function UnitHasItem(u, it) return it ~= nil and it.holder == u and it.typeId ~= 0 end
    function UnitAddItem(u, it)
        local s = slots(u)
        for i = 0, 5 do
            if s[i] == nil then
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
    function UnitUseItem(u, it) return it ~= nil and it.holder == u end
    function UnitUseItemTarget(u, it, t) return it ~= nil and it.holder == u end
    function UnitUseItemPoint(u, it, x, y) return it ~= nil and it.holder == u end
end

-- ------------------------------------------------------------ exercise
do
    local function exercise()
        local Items = use("items")
        local Actives = use("item_actives")
        local Passives = use("item_passives")
        local Builds = use("item_builds")
        local Mods = use("mods")
        local Log = use("log")
        local Timer = use("timer")
        local ids = use("data.ids")
        local catalog = use("data.items")
        local data = catalog.items
        Items.init()

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
        check("shops placed", #Items.shops == #catalog.shops, #Items.shops)
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

        local heroType = FourCC(ids.heroes.pudge)
        local creepType = FourCC(ids.units.human_melee)
        local p0 = Player(0)
        local function gold(p) return GetPlayerState(p or p0, PLAYER_STATE_RESOURCE_GOLD) end
        local function newHero(slot, x, y)
            local u = CreateUnit(Player(slot), heroType, x, y, 0)
            u.hero, u.maxLife, u.life = true, 1000, 500
            return u
        end
        local hero = newHero(0, 8000, -8000)
        local ally = newHero(1, 8100, -8000)
        local foeHero = newHero(SLOT_COMMANDER_AI, 8200, -7900)
        local foe = CreateUnit(Player(SLOT_HORDE), creepType, 8200, -8000, 0)
        local fodder = CreateUnit(Player(SLOT_HORDE), creepType, 8250, -8050, 0)
        local testUnits = {hero, ally, foeHero, foe, fodder}
        SetPlayerState(p0, PLAYER_STATE_RESOURCE_GOLD, 200000)

        -- a shop sale: WC3 takes the token's price, then the hero picks it up
        local function shop(u, name)
            local p = GetOwningPlayer(u)
            SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, gold(p) - data[name].cost)
            local token = CreateItem(FourCC(ids.item_tokens[name]), u.x, u.y)
            Items.pickup(u, token)
            check("token " .. name .. " consumed", GetItemTypeId(token) == 0)
        end
        local function clear(u)
            for _, c in ipairs(Items.carried(u)) do Items.remove(u, c.item) end
            Items.refresh(u)
        end
        local function has(u, name) return Items.find(u, name) ~= nil end
        local function count(u) return #Items.carried(u) end

        -- recipe from parts plus scroll
        local g = gold()
        shop(hero, "item_mithril_hammer")
        shop(hero, "item_ogre_axe")
        shop(hero, "item_recipe_black_king_bar")
        check("BKB combined", has(hero, "item_black_king_bar") and count(hero) == 1, count(hero))
        check("BKB cost", g - gold() == data.item_black_king_bar.cost, g - gold())
        local props = (Mods.get(hero, "dota_items") or {props = {}}).props
        check("BKB stats", props.str == 10 and props.damage == 24, tostring(props.str) .. "/" .. tostring(props.damage))

        -- upgrade bought outright reuses a carried part and refunds it
        clear(hero)
        g = gold()
        shop(hero, "item_claymore")
        shop(hero, "item_greater_crit")
        check("Daedalus bought", has(hero, "item_greater_crit") and not has(hero, "item_claymore"))
        check("Daedalus price", g - gold() == data.item_greater_crit.cost, g - gold())

        -- Power Treads keep the attribute of the variant used
        clear(hero)
        shop(hero, "item_robe")
        shop(hero, "item_power_treads")
        local treads = Items.find(hero, "item_power_treads")
        check("Treads from Robe", treads and Items.istate(treads).attr == "int")
        props = Mods.get(hero, "dota_items").props
        check("Treads stats", props.int == 10 and props.attack_speed == 25 and props.move_flat == 55,
            tostring(props.int) .. "/" .. tostring(props.move_flat))

        -- boots do not stack: Phase Boots' 50 beat Boots of Speed's 45
        clear(hero)
        shop(hero, "item_boots")
        shop(hero, "item_boots")
        shop(hero, "item_chainmail")
        shop(hero, "item_blades_of_attack")
        check("Phase Boots combined", has(hero, "item_phase_boots") and has(hero, "item_boots"))
        check("boots stacking", Mods.get(hero, "dota_items").props.move_flat == 50,
            Mods.get(hero, "dota_items").props.move_flat)

        -- consumables stack into one slot
        clear(hero)
        shop(hero, "item_tango")
        shop(hero, "item_tango")
        local tango = Items.find(hero, "item_tango")
        check("Tango stack", count(hero) == 1 and GetItemCharges(tango) == 6, GetItemCharges(tango))

        -- full inventory: a basic item is refunded, a finishing scroll still works
        clear(hero)
        for _ = 1, 3 do shop(hero, "item_gauntlets") end
        shop(hero, "item_magic_stick")
        shop(hero, "item_branches")
        shop(hero, "item_branches")
        check("six slots", count(hero) == 6, count(hero))
        g = gold()
        shop(hero, "item_platemail")
        check("full inventory refund", gold() == g and not has(hero, "item_platemail"), g - gold())
        Items.setCharges(Items.find(hero, "item_magic_stick"), 7)
        shop(hero, "item_recipe_magic_wand")
        local wand = Items.find(hero, "item_magic_wand")
        check("Wand from scroll with full inventory", wand ~= nil and count(hero) == 4, count(hero))
        check("Stick charges kept", wand and Items.charges(wand) == 7, wand and Items.charges(wand))

        -- a basic part that completes an upgrade needs no free slot
        shop(hero, "item_boots")
        shop(hero, "item_gloves")
        check("full again", count(hero) == 6, count(hero))
        shop(hero, "item_belt_of_strength")
        local belted = Items.find(hero, "item_power_treads")
        check("Treads completed with full inventory", belted ~= nil and count(hero) == 5
            and Items.istate(belted).attr == "str", count(hero))

        -- selling back gives half
        g = gold()
        Items.sell(hero, Items.find(hero, "item_gauntlets"))
        check("sell at 50 %", gold() - g == data.item_gauntlets.cost // 2, gold() - g)

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
            clear(hero)
            hero.life = 500
            shop(hero, name)
            local it = Items.find(hero, name)
            check("carry " .. name, it ~= nil)
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
        -- the Town Portal channel on its own unit: spent after the channel
        local traveler = newHero(1, 7900, -8300)
        testUnits[#testUnits + 1] = traveler
        SetPlayerState(Player(1), PLAYER_STATE_RESOURCE_GOLD, 1000)
        shop(traveler, "item_tpscroll")
        local tpCtx = Actives.context(traveler, FourCC(ids.item_abilities.item_tpscroll), nil, -7000, -7000)
        local tp = Actives.handlers.item_tpscroll
        tp.onChannel(tpCtx)
        tp.onCast(tpCtx)
        Timer.after(3.2, function()
            use("safe").call(function()
                tp.onEndCast(tpCtx)
                check("TP moved", math.abs(traveler.x + 7000) < 900 and math.abs(traveler.y + 7000) < 900,
                    traveler.x .. "," .. traveler.y)
                check("TP spent", Items.find(traveler, "item_tpscroll") == nil)
                for _, u in ipairs(testUnits) do RemoveUnit(u) end
                Log.info("items exercise: teleport done, " .. failures .. " failed checks in total")
            end)
        end)

        -- passive procs, auras and loops with a full kit
        local carrier = newHero(2, 7800, -8100)
        testUnits[#testUnits + 1] = carrier
        SetPlayerState(Player(2), PLAYER_STATE_RESOURCE_GOLD, 100000)
        for _, name in ipairs({"item_bfury", "item_greater_crit", "item_basher", "item_monkey_king_bar",
                               "item_desolator", "item_assault"}) do
            shop(carrier, name)
        end
        check("kit carried", count(carrier) == 6, count(carrier))
        local st = Items.state[carrier]
        check("proc state", st and st.cleave and st.bash and st.pierce and st.corruption and #st.crits == 1)
        for _ = 1, 20 do
            local info = {amount = 100, attack = true}
            Passives.damaging(carrier, foe, info)
            Passives.damaged(carrier, foe, info.amount, info)
        end
        Passives.damaged(foeHero, carrier, 50, {attack = true})
        local holder = newHero(3, 7700, -8200)
        testUnits[#testUnits + 1] = holder
        SetPlayerState(Player(3), PLAYER_STATE_RESOURCE_GOLD, 100000)
        for _, name in ipairs({"item_radiance", "item_heart", "item_shivas_guard", "item_mekansm", "item_buckler",
                               "item_magic_wand"}) do
            shop(holder, name)
        end
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

        -- a bot shops along its build next to the first shop
        local s1 = Items.shops[1]
        local bot = newHero(4, GetUnitX(s1) + 150, GetUnitY(s1))
        testUnits[#testUnits + 1] = bot
        SetPlayerState(Player(4), PLAYER_STATE_RESOURCE_GOLD, 30000)
        local bought, sticks = {}, 0
        for _ = 1, 60 do
            local name = Builds.shop(bot, "pudge")
            if name then bought[#bought + 1] = name end
            if name == "item_magic_stick" then sticks = sticks + 1 end
        end
        local kit = {}
        for _, c in ipairs(Items.carried(bot)) do kit[#kit + 1] = c.name end
        check("bot shopping", Items.covers(bot, "item_blink") and Items.covers(bot, "item_black_king_bar")
            and Items.covers(bot, "item_phase_boots") and Items.covers(bot, "item_refresher") and sticks == 1,
            table.concat(bought, ",") .. " | " .. table.concat(kit, ","))
        Items.autoUse(bot)

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
