-- Offline exercise for src/game/talents.lua and the upgrade lookup in
-- src/core/abilities.lua: talent tiers and their second opening, generic and
-- linked talents (add, set, multiply, share of the base), the Attribute
-- Bonus and its own pick when nothing else can be learned, Aghanim's Scepter
-- (carried) and Shard (bought once, from 15:00), the abilities they grant,
-- the cooldowns, mana costs and channel times written into the unit's
-- abilities, Meepo clones and illusions, and the bots' picks. Test heroes
-- stand in slots 10 and 11, far outside the map; failed checks are ERROR
-- lines, which fail the mock run.
if not __mockTalents then
    __mockTalents = {}
    local MT = __mockTalents

    local function ours(u) return type(u) == "table" and rawget(u, "tal") == true end
    local function wrap(name, fn)
        local prev = _G[name]
        _G[name] = function(...) return fn(prev, ...) end
    end

    wrap("IsUnitType", function(prev, u, t)
        if ours(u) then
            if t == UNIT_TYPE_DEAD then return u.dead == true end
            if t == UNIT_TYPE_HERO then return u.hero == true end
            return false
        end
        return prev(u, t)
    end)
    wrap("IsUnitIllusion", function(prev, u)
        if ours(u) then return u.illusion == true end
        return prev(u)
    end)
    wrap("GetHeroSkillPoints", function(prev, u)
        if ours(u) then return u.points or 0 end
        return prev(u)
    end)
    wrap("UnitModifySkillPoints", function(prev, u, d)
        if ours(u) then
            u.points = math.max(0, (u.points or 0) + d)
            return true
        end
        return prev(u, d)
    end)
    wrap("SelectHeroSkill", function(prev, u, id)
        if ours(u) then
            if (u.points or 0) > 0 then
                u.points = u.points - 1
                u.abilities[id] = (u.abilities[id] or 0) + 1
            end
            return
        end
        return prev(u, id)
    end)

    -- per-unit ability instances: four levels, object values from the data
    local nameOfId = nil
    local function dataName(id)
        if not nameOfId then
            nameOfId = {}
            for name, code in pairs(use("data.ids").abilities) do nameOfId[FourCC(code)] = name end
        end
        return nameOfId[id]
    end
    local function objectValue(id, key, li)
        local name = dataName(id)
        return name and use("abilities").value(name, key, li + 1) or 0
    end
    local function inst(u, id)
        u.inst = u.inst or {}
        local a = u.inst[id]
        if not a then
            a = {talAbility = true, unit = u, id = id, cd = {}, mana = {}, real = {}}
            u.inst[id] = a
        end
        return a
    end
    wrap("BlzGetUnitAbility", function(prev, u, id)
        if ours(u) then return (u.abilities[id] or 0) > 0 and inst(u, id) or nil end
        return prev(u, id)
    end)
    wrap("BlzGetAbilityIntegerField", function(prev, ab, f)
        if type(ab) == "table" and rawget(ab, "talAbility") then return 4 end
        return prev(ab, f)
    end)
    wrap("BlzGetAbilityRealLevelField", function(prev, ab, f, li)
        if type(ab) == "table" and rawget(ab, "talAbility") then
            local key = f == ABILITY_RLF_FOLLOW_THROUGH_TIME and "AbilityChannelTime" or "AbilityCastRange"
            local v = ab.real[tostring(f) .. ":" .. li]
            if v == nil then v = objectValue(ab.id, key, li) end
            return v
        end
        return prev(ab, f, li)
    end)
    wrap("BlzSetAbilityRealLevelField", function(prev, ab, f, li, v)
        if type(ab) == "table" and rawget(ab, "talAbility") then
            ab.real[tostring(f) .. ":" .. li] = v
            return true
        end
        return prev(ab, f, li, v)
    end)
    wrap("BlzGetAbilityCooldown", function(prev, id, li) return objectValue(id, "AbilityCooldown", li) end)
    wrap("BlzGetAbilityManaCost", function(prev, id, li) return math.floor(objectValue(id, "AbilityManaCost", li)) end)
    wrap("BlzGetUnitAbilityCooldown", function(prev, u, id, li)
        if ours(u) then
            local v = inst(u, id).cd[li]
            if v == nil then v = objectValue(id, "AbilityCooldown", li) end
            return v
        end
        return prev(u, id, li)
    end)
    wrap("BlzSetUnitAbilityCooldown", function(prev, u, id, li, v)
        if ours(u) then inst(u, id).cd[li] = v return end
        return prev(u, id, li, v)
    end)
    wrap("BlzGetUnitAbilityManaCost", function(prev, u, id, li)
        if ours(u) then
            local v = inst(u, id).mana[li]
            if v == nil then v = math.floor(objectValue(id, "AbilityManaCost", li)) end
            return v
        end
        return prev(u, id, li)
    end)
    wrap("BlzSetUnitAbilityManaCost", function(prev, u, id, li, v)
        if ours(u) then inst(u, id).mana[li] = v return end
        return prev(u, id, li, v)
    end)

    function MT.unit(slot, key, opts)
        local code = use("data.ids").heroes[key]
        local u = CreateUnit(Player(slot), FourCC(code), 42000 + slot * 500, 42000, 0)
        u.tal, u.hero, u.level, u.points = true, true, 1, 0
        for k, v in pairs(opts or {}) do u[k] = v end
        return u
    end

    -- learns `name` up to `lvl` the way Warcraft does (one point each)
    function MT.learn(u, name, lvl)
        local id = use("abilities").id(name)
        while (u.abilities[id] or 0) < lvl do
            u.points = (u.points or 0) + 1
            SelectHeroSkill(u, id)
            use("events").emit("hero_skill", u, id)
        end
    end

    MT.checks, MT.failures = 0, 0
    function MT.check(name, ok, detail)
        MT.checks = MT.checks + 1
        if not ok then
            MT.failures = MT.failures + 1
            use("log").error("talents exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
        end
    end

    local function near(a, b) return math.abs(a - b) < 1e-6 end

    local function exercise()
        local A = use("abilities")
        local T = use("talents")
        local Mods = use("mods")
        local Items = use("items")
        local Events = use("events")
        local H = use("heroes")
        local check = MT.check
        if not T.started then T.init() end

        local saved = {}
        local function hero(slot, key, opts)
            saved[slot] = saved[slot] or {main = H.bySlot[slot]}
            local u = MT.unit(slot, key, opts)
            H.keyOf[u], H.bySlot[slot] = key, u
            T.register(u)
            return u
        end

        ---------------------------------------------------------------- data
        local list = T.list("pudge")
        check("pudge has 8 talents", #list == 8, #list)
        local tiers = {}
        for _, t in ipairs(list) do tiers[t.tier] = (tiers[t.tier] or 0) + 1 end
        check("two talents per tier", tiers[1] == 2 and tiers[2] == 2 and tiers[3] == 2 and tiers[4] == 2)
        check("first of a pair is the right one", list[1].side == "right" and list[2].side == "left")
        check("generic talent carries its stat", list[1].stat and list[1].stat.armor == 5)
        check("labels are filled in", list[2].label == "+10% Rot Slow", list[2].label)
        check("morphling talents start at 15", T.list("morphling")[1].name == "special_bonus_magic_resistance_15")

        ---------------------------------------------------------------- picks
        local pudge = hero(10, "pudge", {level = 9})
        check("no talent before 10", T.available(pudge) == 0 and not T.canPick(pudge, "special_bonus_armor_5"))
        pudge.level = 10
        check("tier 1 opens at 10", T.canPick(pudge, "special_bonus_armor_5")
            and T.canPick(pudge, "special_bonus_unique_pudge_4") and not T.canPick(pudge, "special_bonus_unique_pudge_7"))
        check("talents cost no skill point", T.pick(pudge, "special_bonus_unique_pudge_4") and pudge.points == 0)
        check("the other talent locks", not T.canPick(pudge, "special_bonus_armor_5"))
        check("rot slow +-10 adds", near(A.value("pudge_rot", "rot_slow", 4, pudge), -42), A.value("pudge_rot", "rot_slow", 4, pudge))
        check("value without a unit stays Dota's base", near(A.value("pudge_rot", "rot_slow", 4), -32))
        pudge.level = 26
        check("second talent still locked at 26", not T.canPick(pudge, "special_bonus_armor_5"))
        pudge.level = 27
        check("second talent opens at 27", T.canPick(pudge, "special_bonus_armor_5"))
        T.pick(pudge, "special_bonus_armor_5")
        check("armor talent goes through mods", near(Mods.sum(pudge, "armor"), 5), Mods.sum(pudge, "armor"))
        check("hook damage +150", not T.picked(pudge, "special_bonus_unique_pudge_7")
            and near(A.value("pudge_meat_hook", "damage", 4, pudge), 360))
        T.pick(pudge, "special_bonus_unique_pudge_7")
        check("ctx value gets the talent", near(A.value("pudge_meat_hook", "damage", 4, pudge), 510))
        T.pick(pudge, "special_bonus_unique_pudge_3")
        check("x1.5 multiplies", near(A.value("pudge_dismember", "dismember_damage", 3, pudge), 180))
        check("x1.8 multiplies", near(A.value("pudge_dismember", "strength_damage", 3, pudge), 0.9 * 1.8))

        ---------------------------------------------------------------- written into the ability
        MT.learn(pudge, "pudge_meat_hook", 4)
        local hook = A.id("pudge_meat_hook")
        check("no talent: object cooldown", near(BlzGetUnitAbilityCooldown(pudge, hook, 3), 12))
        T.pick(pudge, "special_bonus_unique_pudge_5")
        check("cooldown talent written", near(BlzGetUnitAbilityCooldown(pudge, hook, 3), 8)
            and near(BlzGetUnitAbilityCooldown(pudge, hook, 0), 14), BlzGetUnitAbilityCooldown(pudge, hook, 3))
        MT.learn(pudge, "pudge_dismember", 3)
        pudge.level = 29
        check("second tier-3 talent at 29", T.pick(pudge, "special_bonus_unique_pudge_6"))
        local ab = BlzGetUnitAbility(pudge, A.id("pudge_dismember"))
        check("channel time talent written", near(BlzGetAbilityRealLevelField(ab, ABILITY_RLF_FOLLOW_THROUGH_TIME, 2), 3.5),
            BlzGetAbilityRealLevelField(ab, ABILITY_RLF_FOLLOW_THROUGH_TIME, 2))

        ---------------------------------------------------------------- percent of the base
        local morph = hero(11, "morphling", {level = 25})
        check("morphling tier 4 open", T.canPick(morph, "special_bonus_unique_morphling_waveform_cooldown"))
        T.pick(morph, "special_bonus_unique_morphling_waveform_cooldown")
        check("-40% of the base", near(A.value("morphling_waveform", "AbilityCooldown", 1, morph), 21 * 0.6),
            A.value("morphling_waveform", "AbilityCooldown", 1, morph))
        T.pick(morph, "special_bonus_attack_range_75")
        check("attack range talent summed", near(Mods.sum(morph, "attack_range"), 75))
        check("pudge talents never reach morphling", near(A.value("pudge_meat_hook", "damage", 4, morph), 360))

        ---------------------------------------------------------------- Aghanim's Scepter
        check("no scepter", not T.hasScepter(pudge) and near(A.value("pudge_rot", "rot_radius", 1, pudge), 250))
        local code = use("data.ids").items.item_ultimate_scepter
        local scepter = code and CreateItem(FourCC(code), 0, 0)
        if scepter and UnitAddItem then
            UnitAddItem(pudge, scepter)
            Items.refresh(pudge)
            check("scepter carried", T.hasScepter(pudge), tostring(Items.find(pudge, T.SCEPTER)))
            check("scepter rot radius", near(A.value("pudge_rot", "rot_radius", 1, pudge), 450))
            check("scepter-only value", near(A.value("pudge_rot", "scepter_rot_regen_reduction_pct", 1, pudge), 20)
                and near(A.value("pudge_rot", "scepter_rot_regen_reduction_pct", 1), 0))
            UnitRemoveItem(pudge, scepter)
            Items.refresh(pudge)
            check("scepter dropped", not T.hasScepter(pudge))
        else
            use("log").warn("talents exercise: no item natives, Scepter checks skipped")
        end

        ---------------------------------------------------------------- Aghanim's Shard
        local tinker = hero(10, "tinker", {level = 12})
        local flare = A.id("tinker_warp_grenade")
        local p = Player(10)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, 5000)
        local e = Items.data(T.SHARD)
        local was = e.available_at
        check("shard sold from 15:00", was == 900, tostring(was))
        e.available_at = use("world").clock() + 100
        local ok, why = Items.purchase(tinker, T.SHARD)
        check("shard not before its time", not ok and why == "time"
            and GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD) == 5000, tostring(why))
        e.available_at = use("world").clock() - 1
        ok, why = Items.purchase(tinker, T.SHARD)
        check("shard bought and consumed", ok and T.hasShard(tinker)
            and GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD) == 5000 - e.cost, tostring(why))
        check("shard grants warp flare", flare ~= nil and GetUnitAbilityLevel(tinker, flare) == 1)
        ok, why = Items.purchase(tinker, T.SHARD)
        check("second shard refused", not ok and why == "shard", tostring(why))
        e.available_at = was

        ---------------------------------------------------------------- granted by the Scepter
        local ogre = hero(11, "ogre_magi", {level = 12})
        local unrefined = A.id("ogre_magi_unrefined_fireblast")
        T.itemsChanged(ogre)
        check("no scepter ability yet", unrefined ~= nil and GetUnitAbilityLevel(ogre, unrefined) == 0)
        local ocode = use("data.ids").items.item_ultimate_scepter
        local os = ocode and UnitAddItem and CreateItem(FourCC(ocode), 0, 0)
        if os then
            UnitAddItem(ogre, os)
            Items.refresh(ogre)
            check("scepter grants unrefined fireblast", GetUnitAbilityLevel(ogre, unrefined) == 1)
            MT.learn(ogre, "ogre_magi_fireblast", 4)
            local fb = A.id("ogre_magi_fireblast")
            check("scepter fireblast cooldown", near(BlzGetUnitAbilityCooldown(ogre, fb, 3), 7),
                BlzGetUnitAbilityCooldown(ogre, fb, 3))
            UnitRemoveItem(ogre, os)
            Items.refresh(ogre)
            check("scepter ability goes with the scepter", GetUnitAbilityLevel(ogre, unrefined) == 0)
            check("cooldown back without the scepter", near(BlzGetUnitAbilityCooldown(ogre, fb, 3), 8))
        end

        ---------------------------------------------------------------- Attribute Bonus
        local am = hero(10, "antimage", {level = 15})
        MT.learn(am, "antimage_mana_break", 4)
        MT.learn(am, "antimage_blink", 4)
        MT.learn(am, "antimage_counterspell", 4)
        MT.learn(am, "antimage_mana_void", 2)
        am.points = 1
        check("one point left by Dota's count", T.points(am) == 1, T.points(am))
        Events.emit("hero_level", am)
        use("timer").after(0.05, function()
            use("safe").call(function()
                check("attribute bonus takes the point", T.attrLevel(am) == 1 and am.points == 0,
                    T.attrLevel(am) .. " " .. am.points)
                check("+2 all attributes", near(Mods.sum(am, "str"), 2) and near(Mods.sum(am, "agi"), 2)
                    and near(Mods.sum(am, "int"), 2))
                am.level = 18
                am.points = 1
                Events.emit("hero_level", am)
            end)
        end)
        use("timer").after(0.1, function()
            use("safe").call(function()
                check("an ability that can be learned keeps the point", T.attrLevel(am) == 1 and am.points == 1)
                MT.learn(am, "antimage_mana_void", 3)
                am.level = 19
                am.points = 0
                -- levels 16, 17 and 19 passed without a level-up event here
                check("Warcraft stops at the abilities, Dota does not", T.points(am) == 3 and T.canLevelAttr(am),
                    T.points(am))
                T.autoAttr(am)
                check("attribute bonus without a Warcraft point", T.attrLevel(am) == 4 and T.points(am) == 0,
                    T.attrLevel(am))
            end)
        end)

        ---------------------------------------------------------------- clones, illusions, bots
        local meepo = hero(11, "meepo", {level = 20})
        T.pick(meepo, "special_bonus_strength_7")
        T.pick(meepo, "special_bonus_unique_meepo_2")
        local clone = MT.unit(11, "meepo", {level = 20})
        T.addMember(meepo, clone)
        check("clone reads the main meepo's talents", near(A.value("meepo_poof", "poof_damage", 1, clone), 50 + 40))
        check("clone has no attribute talents", near(Mods.sum(clone, "str"), 0) and near(Mods.sum(meepo, "str"), 7))
        T.consumeShard(meepo)
        local dig = A.id("meepo_petrify")
        check("shard digs for the clone too", dig ~= nil and GetUnitAbilityLevel(meepo, dig) == 1
            and GetUnitAbilityLevel(clone, dig) == 1)
        local image = MT.unit(11, "meepo", {level = 20, illusion = true})
        check("illusions read their hero's talents", near(A.value("meepo_poof", "poof_damage", 1, image), 90))

        local bot = hero(10, "pudge", {level = 15})
        T.botPick(bot, use("data.heroes").pudge.bot.build)
        check("bot takes Valve's talents", T.picked(bot, "special_bonus_unique_pudge_4")
            and T.picked(bot, "special_bonus_spell_lifesteal_8"))
        local fur = hero(11, "furion", {level = 10})
        T.botPick(fur, {})
        check("bot without a build takes the right talent", T.picked(fur, "special_bonus_unique_furion_6"))

        use("timer").after(0.5, function()
            use("safe").call(function()
                for slot, s in pairs(saved) do H.bySlot[slot] = s.main end
                for u, key in pairs(H.keyOf) do
                    if ours(u) then H.keyOf[u] = nil end
                end
                use("log").info("talents exercise: " .. MT.checks .. " checks, " .. MT.failures .. " failed")
            end)
        end)
    end

    -- after the main mock run: the game has started and every module is up
    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("talents") then return end
        done = true
        use("safe").call(exercise)
        prev(1)
        use("log").flush()
    end
end
