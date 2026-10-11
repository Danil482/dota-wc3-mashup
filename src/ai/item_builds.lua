-- Bot item builds. Each hero has a role and a buy list of Dota item names
-- (src/data/items.json); the bot buys the next missing part of the first
-- unfinished entry, so upgrades are assembled from components (and recipe
-- scrolls) and combine on their own. Consumables at the top of a list are
-- bought once, at the start.
-- Bot side, when the hero stands near a shop: use("item_builds").shop(u, heroKey)
-- makes at most one purchase (or sells a leftover to make room) and returns
-- the item bought. use("items").autoUse(u) lets the bot use what it carries.
define("item_builds", function()
    local B = {}

    B.roles = {
        antimage = "carry", morphling = "carry", meepo = "carry",
        nevermore = "mid", tinker = "mid",
        pudge = "offlane", furion = "offlane",
        rubick = "support", chen = "support", ogre_magi = "support", techies = "support",
    }

    B.byRole = {
        carry = {"item_tango", "item_flask", "item_quelling_blade", "item_branches", "item_magic_stick",
                 "item_power_treads", "item_magic_wand", "item_bfury", "item_manta", "item_black_king_bar",
                 "item_basher", "item_butterfly", "item_satanic"},
        mid = {"item_tango", "item_faerie_fire", "item_branches", "item_magic_stick", "item_power_treads",
               "item_magic_wand", "item_black_king_bar", "item_desolator", "item_greater_crit", "item_satanic",
               "item_butterfly"},
        offlane = {"item_tango", "item_flask", "item_branches", "item_magic_stick", "item_phase_boots",
                   "item_magic_wand", "item_blink", "item_black_king_bar", "item_assault", "item_heart",
                   "item_shivas_guard"},
        support = {"item_tango", "item_clarity", "item_ward_observer", "item_ward_sentry", "item_magic_stick",
                   "item_arcane_boots", "item_magic_wand", "item_force_staff", "item_mekansm", "item_cyclone",
                   "item_aether_lens", "item_sheepstick"},
    }

    -- Hero-specific lists win over the role list.
    B.byHero = {
        -- Aghanim's Scepter: in Valve's bot loadout for Pudge (data.heroes bot.loadout)
        pudge = {"item_tango", "item_flask", "item_boots", "item_magic_stick", "item_magic_wand", "item_phase_boots",
                 "item_blink", "item_black_king_bar", "item_heart", "item_shivas_guard", "item_refresher",
                 "item_ultimate_scepter"},
        antimage = {"item_tango", "item_flask", "item_quelling_blade", "item_branches", "item_power_treads",
                    "item_bfury", "item_manta", "item_basher", "item_butterfly", "item_black_king_bar",
                    "item_satanic"},
        morphling = {"item_tango", "item_flask", "item_branches", "item_magic_stick", "item_power_treads",
                     "item_magic_wand", "item_yasha", "item_manta", "item_lesser_crit", "item_black_king_bar",
                     "item_greater_crit", "item_butterfly", "item_satanic"},
        meepo = {"item_tango", "item_branches", "item_wraith_band", "item_power_treads", "item_blink",
                 "item_sheepstick", "item_heart", "item_butterfly"},
        nevermore = {"item_tango", "item_faerie_fire", "item_branches", "item_magic_stick", "item_power_treads",
                     "item_magic_wand", "item_desolator", "item_black_king_bar", "item_satanic", "item_greater_crit",
                     "item_butterfly"},
        tinker = {"item_tango", "item_clarity", "item_null_talisman", "item_magic_stick", "item_magic_wand",
                  "item_blink", "item_kaya", "item_shivas_guard", "item_sheepstick", "item_aether_lens"},
        furion = {"item_tango", "item_flask", "item_magic_stick", "item_power_treads", "item_hand_of_midas",
                  "item_desolator", "item_black_king_bar", "item_monkey_king_bar", "item_sheepstick"},
        ogre_magi = {"item_tango", "item_flask", "item_ward_observer", "item_magic_stick", "item_hand_of_midas",
                     "item_phase_boots", "item_magic_wand", "item_aether_lens", "item_force_staff", "item_blink",
                     "item_refresher"},
        chen = {"item_tango", "item_clarity", "item_ward_observer", "item_ward_sentry", "item_arcane_boots",
                "item_mekansm", "item_force_staff", "item_cyclone", "item_assault"},
    }

    local bought = {}         -- unit -> {name = true} consumables already bought
    local retired = {}        -- unit -> {name = true} goals sold to make room, never rebought

    function B.list(heroKey)
        return B.byHero[heroKey] or B.byRole[B.roles[heroKey] or "carry"]
    end

    local function done(u, name)
        local I = use("items")
        local e = I.data(name)
        if not e then return true end
        if e.consumable then return (bought[u] or {})[name] == true end
        return I.covers(u, name) or (retired[u] or {})[name] == true
    end

    -- Next purchase for the build: part name, its price and the goal item.
    function B.next(u, heroKey)
        local I = use("items")
        for _, goal in ipairs(B.list(heroKey) or {}) do
            if not done(u, goal) then
                local part, price = I.nextPart(u, goal)
                if part then return part, price, goal end
                if I.data(goal).consumable then return goal, I.price(u, goal), goal end
            end
        end
        return nil
    end

    local KEEP_COST = 2000    -- finished build items this expensive are never sold for room

    -- Sells a carried item no unfinished goal needs: leftovers and consumables
    -- first, then the cheapest finished early item (never boots or items worth
    -- KEEP_COST). A goal sold this way, and the goals it covered, is retired.
    local function makeRoom(u, heroKey)
        local I = use("items")
        local list = B.list(heroKey) or {}
        local open, inList = {}, {}
        for _, goal in ipairs(list) do
            inList[goal] = true
            if not done(u, goal) then open[goal] = true end
        end
        local worst, cost = nil, math.huge
        for _, c in ipairs(I.carried(u)) do
            local needed = open[c.name]
            for goal in pairs(open) do
                if I.partOf(c.name, goal) then needed = true end
            end
            local e = I.data(c.name)
            local finished = inList[c.name] and not e.consumable
            local score = e.cost + (finished and 100000 or 0)
            if not needed and not (e.stats and e.stats.boots_ms) and not (finished and e.cost >= KEEP_COST)
                and score < cost and I.ownedBy(c.item, GetPlayerId(GetOwningPlayer(u))) then
                worst, cost = c, score
            end
        end
        if not worst then return false end
        retired[u] = retired[u] or {}
        for _, goal in ipairs(list) do
            if goal == worst.name or I.partOf(goal, worst.name) then retired[u][goal] = true end
        end
        I.sell(u, worst.item)
        return true
    end

    -- One shopping step for a bot near a shop. Returns the bought item name.
    -- With no room for the next part, the goal itself is bought when carried
    -- parts make room for it (paying only what is missing).
    function B.shop(u, heroKey)
        local I = use("items")
        if not I.nearShop(u) then return nil end
        local part, price, goal = B.next(u, heroKey)
        if not part then return nil end
        local gold = GetPlayerState(GetOwningPlayer(u), PLAYER_STATE_RESOURCE_GOLD)
        if gold < price then return nil end
        if not I.canReceive(u, part) then
            if goal ~= part and I.canReceive(u, goal) and gold >= I.price(u, goal) then
                part = goal
            elseif not (makeRoom(u, heroKey) and I.canReceive(u, part)) then
                return nil
            end
        end
        if not I.purchase(u, part) then return nil end
        if I.data(part).consumable then
            bought[u] = bought[u] or {}
            bought[u][part] = true
        end
        return part
    end

    return B
end)
