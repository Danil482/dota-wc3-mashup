-- Dota's talents, Attribute Bonus, Aghanim's Scepter and Aghanim's Shard for
-- the Dota heroes. Rules from the current Dota 2 (Liquipedia, patch 7.41):
--   Talents (https://liquipedia.net/dota2/Talents): four tiers open at hero
--   levels 10/15/20/25, one of two talents each; the other one opens when the
--   tier opens again at 27/28/29/30. Talents have picks of their own: they
--   cost no ability point.
--   Attribute Bonus (https://liquipedia.net/dota2/Attributes): +2 to all
--   attributes per level (data.heroes attribute_bonus), paid with ability
--   points; it takes a point by itself when nothing else can be learned.
--   Aghanim's Scepter: carried in the main inventory. Aghanim's Shard
--   (https://liquipedia.net/dota2/Aghanim%27s_Shard): consumed when bought,
--   once per hero.
--   Meepo clones get the main Meepo's talents but not his Attribute Bonus or
--   attribute talents (https://liquipedia.net/dota2/Meepo); Rubick's stolen
--   and Morphling's morphed spells get the caster's Scepter and Shard upgrades,
--   never the original hero's talents.
-- Ability values read through A.value(name, key, level, unit) or ctx.v() get
-- every bonus of the unit; cooldowns, mana costs, channel times and cast
-- ranges of the unit's abilities follow them (T.sync).
-- Events: "talent" (hero, name), "attribute_bonus" (hero, level),
-- "scepter" (hero, on), "shard" (hero).
-- Start with use("talents").init() after use("items").init().
define("talents", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Events = use("events")
    local Timer = use("timer")
    local Log = use("log")
    local U = use("util")
    local T = {started = false}

    T.TIER_LEVELS = {10, 15, 20, 25}
    T.SECOND_LEVELS = {27, 28, 29, 30}
    T.SCEPTER, T.SHARD = "item_ultimate_scepter", "item_aghanims_shard"

    local picked = {}         -- hero -> {talent name -> true}
    local sources = {}        -- hero -> {talent name | "scepter" | "shard" -> true}
    local attrs = {}          -- hero -> Attribute Bonus level
    local members = {}        -- hero -> {unit -> true}: Meepo clones
    local granted = {}        -- unit -> {abilId -> cooldown end, when taken away}
    local manual = {}         -- ability name -> true: added by its hero module, not on grant
    local channelBase = {}    -- unit -> {abilId -> {levelIndex -> object channel time}}

    local function heroes() return use("heroes") end
    local function info(key) return key and use("data.heroes")[key] end

    function T.keyOf(hero) return heroes().keyOf[hero] end

    function T.list(key)
        local i = info(key)
        return i and i.talents or {}
    end

    function T.find(key, name)
        for _, t in ipairs(T.list(key)) do
            if t.name == name then return t end
        end
        return nil
    end

    -- The hero whose talents and items count for u: itself, or the main hero
    -- of the same type its owner plays (Meepo clones, illusions).
    function T.ownerOf(u)
        if not u then return nil end
        local H = heroes()
        if H.keyOf[u] then return u end
        local main = H.bySlot[GetPlayerId(GetOwningPlayer(u))]
        if main and GetUnitTypeId(main) == GetUnitTypeId(u) then return main end
        return u
    end

    function T.sources(u)
        return sources[T.ownerOf(u)]
    end

    function T.has(u, name)
        local s = T.sources(u)
        return s ~= nil and s[name] == true
    end

    function T.hasScepter(u) return T.has(u, "scepter") end
    function T.hasShard(u) return T.has(u, "shard") end
    function T.picked(hero, name) return (picked[hero] or {})[name] == true end
    function T.attrLevel(hero) return attrs[hero] or 0 end

    -- Hero modules add some granted abilities themselves (MegaMeepo Fling).
    function T.manual(name) manual[name] = true end

    local function state(hero)
        if not picked[hero] then
            picked[hero], sources[hero], attrs[hero], members[hero] = {}, {}, 0, {}
        end
    end

    ---------------------------------------------------------------- abilities

    local function levelsOf(ab)
        if ab.Innate == "1" or string.find(ab.name, "innate") then return 1 end
        if ab.MaxLevel then return tonumber(ab.MaxLevel) or 4 end
        return string.find(ab.AbilityType or "", "ULTIMATE") and 3 or 4
    end

    local function isGrant(ab) return ab.IsGrantedByScepter == "1" or ab.IsGrantedByShard == "1" end

    -- Learnable abilities of a hero key: {name, id, max, ult, rl, lb}.
    local learnables = {}
    local function learnable(key)
        local list = learnables[key]
        if list then return list end
        list = {}
        local ids = use("data.ids")
        local innate = {}
        for _, code in ipairs(ids.heroes[key .. "_innates"] or {}) do innate[code] = true end
        for _, ab in ipairs((info(key) or {}).abilities or {}) do
            local code = ids.abilities[ab.name]
            if code and not innate[code] and not isGrant(ab) then
                local v = ab.values or {}
                list[#list + 1] = {name = ab.name, id = FourCC(code), max = levelsOf(ab),
                                   ult = string.find(ab.AbilityType or "", "ULTIMATE") ~= nil,
                                   rl = tonumber(v.required_level), lb = tonumber(v.levels_between_upgrades)}
            end
        end
        learnables[key] = list
        return list
    end

    -- Hero level needed for the next level of e (Dota: basics 1/3/5/7,
    -- ultimates 6/12/18, data overrides such as Divided We Stand's).
    local function required(e, cur)
        if e.rl and e.lb then return e.rl + cur * e.lb end
        if e.ult then return 6 + 6 * cur end
        return 1 + 2 * cur
    end

    function T.abilityLearnable(hero)
        for _, e in ipairs(learnable(T.keyOf(hero))) do
            local cur = GetUnitAbilityLevel(hero, e.id)
            if cur < e.max and GetHeroLevel(hero) >= required(e, cur) then return true end
        end
        return false
    end

    local function spent(hero)
        local n = 0
        for _, e in ipairs(learnable(T.keyOf(hero))) do n = n + GetUnitAbilityLevel(hero, e.id) end
        return n
    end

    ---------------------------------------------------------------- stats

    local ATTRIBUTE = {str = true, agi = true, int = true}

    -- Generic talents (and the Attribute Bonus) as one modifier per unit.
    local function statProps(hero, forClone)
        local props = {}
        local key = T.keyOf(hero)
        for _, t in ipairs(T.list(key)) do
            if t.stat and picked[hero][t.name] then
                for prop, v in pairs(t.stat) do
                    if not (forClone and ATTRIBUTE[prop]) then props[prop] = (props[prop] or 0) + v end
                end
            end
        end
        local lvl = attrs[hero] or 0
        if lvl > 0 and not forClone then
            local per = U.levelValue(info(key).attribute_bonus.value, lvl)
            for prop in pairs(ATTRIBUTE) do props[prop] = (props[prop] or 0) + per end
        end
        return props
    end

    local function applyStats(u, props)
        if next(props) then
            Mods.add(u, "dota_talents", {props = props, persist = true, dispel = "none"})
        else
            Mods.remove(u, "dota_talents")
        end
    end

    function T.refreshStats(hero)
        if not picked[hero] then return end
        applyStats(hero, statProps(hero, false))
        local clone = statProps(hero, true)
        for c in pairs(members[hero]) do
            if GetUnitTypeId(c) ~= 0 then applyStats(c, clone) else members[hero][c] = nil end
        end
    end

    -- A Meepo clone: takes the hero's talents (not its attribute bonuses) and
    -- its Shard abilities.
    function T.addMember(hero, u)
        state(hero)
        members[hero][u] = true
        applyStats(u, statProps(hero, true))
        if sources[hero].shard then T.grant(u, "shard", true) end
        T.sync(u)
    end

    ---------------------------------------------------------------- object sync

    local function syncAbility(u, name, id)
        local ab = BlzGetUnitAbility(u, id)
        if not ab then return end
        local cdr = Mods.sum(u, "cooldown_reduction")
        local manaCut = Mods.sum(u, "mana_reduction")
        local levels = math.max(1, BlzGetAbilityIntegerField(ab, ABILITY_IF_LEVELS), GetUnitAbilityLevel(u, id))
        for li = 0, levels - 1 do
            local L = li + 1
            local cdDelta = A.value(name, "AbilityCooldown", L, u) - A.value(name, "AbilityCooldown", L)
            local cd = math.max(0, (BlzGetAbilityCooldown(id, li) + cdDelta) * (1 - cdr))
            if math.abs(BlzGetUnitAbilityCooldown(u, id, li) - cd) > 0.01 then BlzSetUnitAbilityCooldown(u, id, li, cd) end
            local manaDelta = A.value(name, "AbilityManaCost", L, u) - A.value(name, "AbilityManaCost", L)
            local mana = math.max(0, math.floor((BlzGetAbilityManaCost(id, li) + manaDelta) * (1 - manaCut) + 0.5))
            if BlzGetUnitAbilityManaCost(u, id, li) ~= mana then BlzSetUnitAbilityManaCost(u, id, li, mana) end
            local chDelta = A.value(name, "AbilityChannelTime", L, u) - A.value(name, "AbilityChannelTime", L)
            local per = channelBase[u] and channelBase[u][id]
            if chDelta ~= 0 or per then
                if not per then
                    channelBase[u] = channelBase[u] or {}
                    per = {}
                    channelBase[u][id] = per
                end
                if per[li] == nil then per[li] = BlzGetAbilityRealLevelField(ab, ABILITY_RLF_FOLLOW_THROUGH_TIME, li) end
                BlzSetAbilityRealLevelField(ab, ABILITY_RLF_FOLLOW_THROUGH_TIME, li, math.max(0, per[li] + chDelta))
            end
        end
        local range = A.value(name, "AbilityCastRange", 1, u) - A.value(name, "AbilityCastRange", 1)
            + Mods.sum(u, "cast_range")
        if range ~= A.rangeBonus(u, id, "talents") then A.setRangeBonus(u, id, "talents", range) end
    end

    -- Writes the unit's upgrades into the cooldown, mana cost, channel time
    -- and cast range of every Dota hero ability it has.
    function T.sync(u)
        if not u or GetUnitTypeId(u) == 0 then return end
        for hero, list in pairs(use("data.heroes")) do
            for _, ab in ipairs(list.abilities) do
                local id = A.id(ab.name)
                if id and GetUnitAbilityLevel(u, id) > 0 then syncAbility(u, ab.name, id) end
            end
        end
    end

    local function syncAll(hero)
        T.sync(hero)
        for c in pairs(members[hero] or {}) do T.sync(c) end
    end

    local function hudDirty()
        if defined("dota_hud") and use("dota_hud").started then use("dota_hud").S.dirty = true end
    end

    ---------------------------------------------------------------- talents

    -- True when hero can take talent `name` now.
    function T.canPick(hero, name)
        local key = T.keyOf(hero)
        local t = T.find(key, name)
        if not t or not picked[hero] or picked[hero][name] then return false end
        local taken = 0
        for _, o in ipairs(T.list(key)) do
            if o.tier == t.tier and picked[hero][o.name] then taken = taken + 1 end
        end
        local need = taken == 0 and T.TIER_LEVELS[t.tier] or T.SECOND_LEVELS[t.tier]
        return GetHeroLevel(hero) >= need
    end

    -- Number of talents hero can take right now.
    function T.available(hero)
        local n = 0
        for _, t in ipairs(T.list(T.keyOf(hero))) do
            if T.canPick(hero, t.name) then n = n + 1 end
        end
        return n
    end

    -- Synced: takes talent `name` for hero. Returns true if it was taken.
    function T.pick(hero, name)
        if not T.canPick(hero, name) then return false end
        picked[hero][name] = true
        sources[hero][name] = true
        T.refreshStats(hero)
        syncAll(hero)
        hudDirty()
        Log.info("talent " .. name .. " for " .. tostring(T.keyOf(hero)))
        Events.emit("talent", hero, name)
        return true
    end

    ---------------------------------------------------------------- attribute bonus

    local function attrData(hero) return (info(T.keyOf(hero)) or {}).attribute_bonus end

    -- Ability points the hero has left by Dota's count (one per level):
    -- Warcraft's own count stops once every learnable level is paid for.
    function T.points(hero)
        return math.max(0, GetHeroLevel(hero) - spent(hero) - (attrs[hero] or 0))
    end

    function T.canLevelAttr(hero)
        local d = attrData(hero)
        if not d or not attrs[hero] then return false end
        local lvl = attrs[hero]
        return lvl < d.max and GetHeroLevel(hero) >= d.required + lvl * d.between and T.points(hero) > 0
    end

    -- Synced: one more level of the Attribute Bonus.
    function T.levelAttr(hero)
        if not T.canLevelAttr(hero) then return false end
        attrs[hero] = attrs[hero] + 1
        if GetHeroSkillPoints(hero) > 0 then UnitModifySkillPoints(hero, -1) end
        T.refreshStats(hero)
        hudDirty()
        Events.emit("attribute_bonus", hero, attrs[hero])
        return true
    end

    -- Dota levels the Attribute Bonus by itself when a point has nowhere else to go.
    function T.autoAttr(hero)
        local guard = 0
        while guard < 8 and T.canLevelAttr(hero)
            and (GetHeroSkillPoints(hero) <= 0 or not T.abilityLearnable(hero)) do
            guard = guard + 1
            T.levelAttr(hero)
        end
    end

    ---------------------------------------------------------------- Scepter and Shard

    -- Abilities a hero gets from kind ("scepter" | "shard"), by data flag.
    local grants = {}
    local function grantsOf(key, kind)
        grants[key] = grants[key] or {}
        local list = grants[key][kind]
        if list then return list end
        list = {}
        local flag = kind == "scepter" and "IsGrantedByScepter" or "IsGrantedByShard"
        for _, ab in ipairs((info(key) or {}).abilities or {}) do
            if ab[flag] == "1" and not manual[ab.name] and A.id(ab.name) then list[#list + 1] = A.id(ab.name) end
        end
        grants[key][kind] = list
        return list
    end

    -- Adds (on) or takes away the abilities kind grants to u. A taken
    -- ability keeps its cooldown for when it comes back.
    function T.grant(u, kind, on)
        local key = T.keyOf(T.ownerOf(u))
        local mem = granted[u]
        if not mem then mem = {}; granted[u] = mem end
        for _, id in ipairs(grantsOf(key, kind)) do
            local has = GetUnitAbilityLevel(u, id) > 0
            if on and not has then
                UnitAddAbility(u, id)
                UnitMakeAbilityPermanent(u, true, id)
                local left = (mem[id] or 0) - Timer.now()
                if left > 0.05 then BlzStartUnitAbilityCooldown(u, id, left) end
                mem[id] = nil
            elseif not on and has then
                local left = BlzGetUnitAbilityCooldownRemaining(u, id)
                if left > 0 then mem[id] = Timer.now() + left end
                UnitRemoveAbility(u, id)
            end
        end
    end

    local function setScepter(hero, on)
        sources[hero].scepter = on or nil
        T.grant(hero, "scepter", on)
        syncAll(hero)
        hudDirty()
        Log.info("scepter " .. (on and "on" or "off") .. " for " .. tostring(T.keyOf(hero)))
        Events.emit("scepter", hero, on)
    end

    -- items.lua: a hero's inventory changed.
    function T.itemsChanged(u)
        if not picked[u] then return end
        local on = use("items").find(u, T.SCEPTER) ~= nil
        if on ~= (sources[u].scepter == true) then setScepter(u, on) end
    end

    function T.canConsumeShard(u)
        T.register(u)
        return picked[u] ~= nil and not sources[u].shard
    end

    -- Synced: u consumes an Aghanim's Shard. Returns false if it can't.
    function T.consumeShard(u)
        if not T.canConsumeShard(u) then return false end
        sources[u].shard = true
        T.grant(u, "shard", true)
        for c in pairs(members[u]) do
            if GetUnitTypeId(c) ~= 0 then T.grant(c, "shard", true) end
        end
        syncAll(u)
        hudDirty()
        Log.info("shard for " .. tostring(T.keyOf(u)))
        Events.emit("shard", u)
        return true
    end

    -- items.lua: a purchase of Aghanim's Shard by hero's player (the shop
    -- panel or a bot pays here; a shop token already took `paid`). It is
    -- sold from items.json's available_at on the game clock and consumed at
    -- once. Returns true, or false and the reason ("time", "shard", "gold").
    function T.buyShard(hero, e, paid)
        local p = GetOwningPlayer(hero)
        local gold = GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD)
        local why = nil
        if e.available_at and use("world").clock() < e.available_at then
            why = "time"
        elseif not T.canConsumeShard(hero) then
            why = "shard"
        elseif not paid and gold < e.cost then
            return false, "gold"
        end
        if why then
            if paid and paid > 0 then SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, gold + paid) end
            return false, why
        end
        SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, gold + (paid or 0) - e.cost)
        T.consumeShard(hero)
        return true, "ok"
    end

    ---------------------------------------------------------------- texts

    function T.upgradeText(key, kind)
        local i = info(key)
        return i and i.upgrades and i.upgrades[kind] or ""
    end

    ---------------------------------------------------------------- bots

    -- Bot talents: the one Valve's bot build names for the tier, else the
    -- first (right-hand) talent; the second talent of a tier when it opens.
    function T.botPick(hero, build)
        local key = T.keyOf(hero)
        local wanted = {}
        for _, name in ipairs(build or {}) do wanted[name] = true end
        for tier = 1, 4 do
            local choice = nil
            for _, t in ipairs(T.list(key)) do
                if t.tier == tier and T.canPick(hero, t.name) and (choice == nil or wanted[t.name]) then
                    choice = t.name
                end
            end
            if choice then T.pick(hero, choice) end
        end
    end

    ---------------------------------------------------------------- init

    function T.register(hero)
        if not hero or not T.keyOf(hero) then return end
        state(hero)
    end

    -- Drops a hero's talents, Attribute Bonus and Aghanim's upgrades (tests).
    function T.forget(hero)
        if not picked[hero] then return end
        T.grant(hero, "scepter", false)
        T.grant(hero, "shard", false)
        picked[hero], sources[hero], attrs[hero], members[hero] = nil, nil, nil, nil
        Mods.remove(hero, "dota_talents")
        T.register(hero)
        T.sync(hero)
    end

    function T.init()
        if T.started then return end
        T.started = true
        A.sourcesOf = T.sources
        Events.on("hero_spawned", function(u) T.register(u) end)
        for u in pairs(heroes().keyOf) do T.register(u) end
        Events.on("hero_level", function(u)
            if not picked[u] then return end
            -- after Warcraft hands out the level's skill point
            Timer.after(0, function() T.autoAttr(u) end)
            hudDirty()
        end)
        Events.on("hero_skill", function(u)
            if picked[u] then
                T.sync(u)
                Timer.after(0, function() T.autoAttr(u) end)
            elseif T.ownerOf(u) ~= u and sources[T.ownerOf(u)] then
                T.sync(u)
            end
        end)
        Events.on("items_changed", T.itemsChanged)
        local why = use("items").WHY
        if why then
            why.time = "Not in the shop yet"
            why.shard = "Aghanim's Shard is already consumed"
        end
        if BUILD_TEST_MODE then
            -- test builds: "-shard" gives the typing player's hero Aghanim's Shard before 15:00
            local trig = CreateTrigger()
            for slot = 0, SLOT_DOTA_MAX do TriggerRegisterPlayerChatEvent(trig, Player(slot), "-shard", true) end
            TriggerAddAction(trig, function()
                use("safe").call(function()
                    local hero = heroes().bySlot[GetPlayerId(GetTriggerPlayer())]
                    if hero then T.consumeShard(hero) end
                end)
            end)
        end
        Log.info("talents ready")
    end

    return T
end)
