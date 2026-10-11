-- Offline exercise for the Morphling module (heroes C: tinker, rubick, morphling).
-- The prelude below is shared by tools/mock/{morphling,rubick,tinker}.lua;
-- whichever loads first installs it. Natives are wrapped only for test units
-- (u.hC = true) placed far outside the map, so other mock runs see the stock
-- stubs. The exercises run once, after the normal mock run, with their own
-- clock (C.advance) so per-frame code (missiles, waves, shifts) really runs.
if not __mockC then
    local C = {list = {}, done = false}
    __mockC = C

    -- Field constants the generated stubs leave nil (Convert...('xxxx') forms).
    for _, name in ipairs({
        "ABILITY_BF_HERO_ABILITY", "ABILITY_BF_ITEM_ABILITY", "ABILITY_IF_REQUIRED_LEVEL",
        "ABILITY_ILF_TARGET_TYPE", "ABILITY_ILF_OPTIONS", "ABILITY_RLF_FOLLOW_THROUGH_TIME",
        "ABILITY_RLF_CAST_RANGE", "ABILITY_RLF_AREA_OF_EFFECT", "ABILITY_SLF_BASE_ORDER_ID_NCL6",
        "UNIT_IF_PRIMARY_ATTRIBUTE", "UNIT_WEAPON_RF_ATTACK_RANGE", "ITEM_IF_COOLDOWN_GROUP",
    }) do
        if _G[name] == nil then _G[name] = __const("hC_" .. name) end
    end

    local function mine(u) return type(u) == "table" and u.hC == true end
    local function fake(ab) return type(ab) == "table" and ab.hCab == true end
    local function wrap(name, fn)
        local prev = _G[name]
        _G[name] = function(...) return fn(prev, ...) end
    end
    local function side(p) return (p.id <= 4 or p.id == 6) and "dota" or "cmd" end

    wrap("IsUnitEnemy", function(prev, u, p)
        if mine(u) then return side(u.owner) ~= side(p) end
        return prev(u, p)
    end)
    wrap("IsUnitAlly", function(prev, u, p)
        if mine(u) then return side(u.owner) == side(p) end
        return prev(u, p)
    end)
    wrap("IsUnitType", function(prev, u, t)
        if mine(u) then
            if t == UNIT_TYPE_DEAD then return u.dead == true end
            if t == UNIT_TYPE_HERO then return u.hero == true end
            if t == UNIT_TYPE_STRUCTURE then return u.structure == true end
            if t == UNIT_TYPE_MAGIC_IMMUNE then return u.immune == true end
            return false
        end
        return prev(u, t)
    end)
    for _, name in ipairs({"GetHeroStr", "GetHeroAgi", "GetHeroInt"}) do
        local key = ({GetHeroStr = "str", GetHeroAgi = "agi", GetHeroInt = "int"})[name]
        wrap(name, function(prev, u, bonus)
            if mine(u) then return u[key] or 0 end
            return prev(u, bonus)
        end)
    end
    for _, name in ipairs({"SetHeroStr", "SetHeroAgi", "SetHeroInt"}) do
        local key = ({SetHeroStr = "str", SetHeroAgi = "agi", SetHeroInt = "int"})[name]
        wrap(name, function(prev, u, v, permanent)
            if mine(u) then u[key] = v return end
            return prev(u, v, permanent)
        end)
    end
    wrap("GetUnitState", function(prev, u, s)
        if mine(u) then
            if s == UNIT_STATE_MANA then return u.mana or 0 end
            if s == UNIT_STATE_LIFE then return u.life or 0 end
            return 0
        end
        return prev(u, s)
    end)
    wrap("SetUnitState", function(prev, u, s, v)
        if mine(u) then
            if s == UNIT_STATE_MANA then u.mana = v end
            if s == UNIT_STATE_LIFE then u.life = v end
            return
        end
        return prev(u, s, v)
    end)
    wrap("GetUnitFacing", function(prev, u)
        if mine(u) then return u.face or 0 end
        return prev(u)
    end)
    wrap("SetUnitFacing", function(prev, u, a)
        if mine(u) then u.face = a return end
        return prev(u, a)
    end)
    wrap("IssueImmediateOrder", function(prev, u, order)
        if mine(u) then u.orders[#u.orders + 1] = order return true end
        return prev(u, order)
    end)
    wrap("BlzGetUnitSkin", function(prev, u)
        if mine(u) then return u.skin or u.typeId end
        return prev(u)
    end)
    wrap("BlzSetUnitSkin", function(prev, u, skin)
        if mine(u) then u.skin = skin return end
        return prev(u, skin)
    end)
    wrap("BlzGetUnitIntegerField", function(prev, u, f)
        if mine(u) then return u.ufields[f] or 1 end
        return prev(u, f)
    end)
    wrap("BlzSetUnitIntegerField", function(prev, u, f, v)
        if mine(u) then u.ufields[f] = v return true end
        return prev(u, f, v)
    end)
    wrap("UnitInventorySize", function(prev, u)
        if mine(u) then return 6 end
        return prev(u)
    end)
    wrap("UnitItemInSlot", function(prev, u, slot)
        if mine(u) then return u.items[slot + 1] end
        return prev(u, slot)
    end)

    -- Abilities of test units: u.abilities (mock levels) plus u.meta[id] =
    -- {hero, item, req, order, targetType, range} for the instanced fields.
    local function instance(u, id)
        u.inst[id] = u.inst[id] or {hCab = true, id = id, unit = u, ints = {}, reals = {}}
        return u.inst[id]
    end
    local function meta(ab) return ab.unit and ab.unit.meta[ab.id] or ab.meta or {} end
    wrap("BlzGetUnitAbility", function(prev, u, id)
        if mine(u) then return GetUnitAbilityLevel(u, id) > 0 and instance(u, id) or nil end
        return prev(u, id)
    end)
    wrap("BlzGetUnitAbilityByIndex", function(prev, u, i)
        if not mine(u) then return prev(u, i) end
        local ids = {}
        for id in pairs(u.abilities) do ids[#ids + 1] = id end
        table.sort(ids)
        return ids[i + 1] and instance(u, ids[i + 1]) or nil
    end)
    wrap("BlzGetAbilityId", function(prev, ab)
        if fake(ab) then return ab.id end
        return prev(ab)
    end)
    wrap("BlzGetAbilityBooleanField", function(prev, ab, f)
        if not fake(ab) then return prev(ab, f) end
        if f == ABILITY_BF_HERO_ABILITY then return meta(ab).hero == true end
        if f == ABILITY_BF_ITEM_ABILITY then return meta(ab).item == true end
        return false
    end)
    wrap("BlzGetAbilityIntegerField", function(prev, ab, f)
        if not fake(ab) then return prev(ab, f) end
        if f == ABILITY_IF_REQUIRED_LEVEL then return meta(ab).req or 1 end
        return 0
    end)
    wrap("BlzGetAbilityIntegerLevelField", function(prev, ab, f, li)
        if not fake(ab) then return prev(ab, f, li) end
        local v = ab.ints[f] and ab.ints[f][li]
        if v ~= nil then return v end
        if f == ABILITY_ILF_TARGET_TYPE then return meta(ab).targetType or 1 end
        if f == ABILITY_ILF_OPTIONS then return 1 end
        return 0
    end)
    wrap("BlzSetAbilityIntegerLevelField", function(prev, ab, f, li, v)
        if not fake(ab) then return prev(ab, f, li, v) end
        ab.ints[f] = ab.ints[f] or {}
        ab.ints[f][li] = v
        return true
    end)
    wrap("BlzGetAbilityRealLevelField", function(prev, ab, f, li)
        if not fake(ab) then return prev(ab, f, li) end
        local v = ab.reals[f] and ab.reals[f][li]
        if v ~= nil then return v end
        if f == ABILITY_RLF_CAST_RANGE then return meta(ab).range or 600.0 end
        return 0.0
    end)
    wrap("BlzSetAbilityRealLevelField", function(prev, ab, f, li, v)
        if not fake(ab) then return prev(ab, f, li, v) end
        ab.reals[f] = ab.reals[f] or {}
        ab.reals[f][li] = v
        return true
    end)
    wrap("BlzGetAbilityStringLevelField", function(prev, ab, f, li)
        if not fake(ab) then return prev(ab, f, li) end
        if f == ABILITY_SLF_BASE_ORDER_ID_NCL6 then return meta(ab).order or "" end
        return ""
    end)
    -- Items: {hCitem = true, abils = {id, ...}, group = id}
    wrap("BlzGetItemAbilityByIndex", function(prev, item, i)
        if type(item) == "table" and item.hCitem then
            local id = item.abils[i + 1]
            return id and {hCab = true, id = id, meta = {item = true}, ints = {}, reals = {}} or nil
        end
        return prev(item, i)
    end)
    wrap("BlzGetItemAbility", function(prev, item, id)
        if type(item) == "table" and item.hCitem then
            for _, a in ipairs(item.abils) do
                if a == id then return {hCab = true, id = id, meta = {item = true}, ints = {}, reals = {}} end
            end
            return nil
        end
        return prev(item, id)
    end)
    wrap("BlzGetItemIntegerField", function(prev, item, f)
        if type(item) == "table" and item.hCitem then return item.group or 0 end
        return prev(item, f)
    end)
    -- Cooldowns and costs per test unit.
    wrap("BlzStartUnitAbilityCooldown", function(prev, u, id, cd)
        if mine(u) then u.cd[id] = __mock.now + cd return end
        return prev(u, id, cd)
    end)
    wrap("BlzEndUnitAbilityCooldown", function(prev, u, id)
        if mine(u) then u.cd[id] = nil return end
        return prev(u, id)
    end)
    wrap("BlzGetUnitAbilityCooldownRemaining", function(prev, u, id)
        if mine(u) then return math.max(0, (u.cd[id] or 0) - __mock.now) end
        return prev(u, id)
    end)
    wrap("BlzGetUnitAbilityCooldown", function(prev, u, id, li)
        if mine(u) then return u.cdBase[id] or 10.0 end
        return prev(u, id, li)
    end)
    wrap("BlzSetUnitAbilityCooldown", function(prev, u, id, li, cd)
        if mine(u) then u.cdBase[id] = cd return end
        return prev(u, id, li, cd)
    end)
    -- Damage to a test unit runs the damaging hooks like the engine does.
    function C.fireDamage(src, tgt, amount, attack)
        local d, a, s = GetEventDamage, BlzGetEventIsAttack, BlzSetEventDamage
        local final = amount
        GetEventDamage = function() return amount end
        BlzGetEventIsAttack = function() return attack end
        BlzSetEventDamage = function(v) final = v end
        local ok, err = pcall(use("events").emit, "damaging", src, tgt)
        GetEventDamage, BlzGetEventIsAttack, BlzSetEventDamage = d, a, s
        if not ok then error(err, 0) end
        return final
    end
    wrap("UnitDamageTarget", function(prev, src, tgt, amount, ...)
        if not mine(tgt) then return prev(src, tgt, amount, ...) end
        if tgt.dead then return false end
        local final = C.fireDamage(src, tgt, amount, false)
        tgt.life = tgt.life - final
        tgt.taken = tgt.taken + final
        if tgt.life <= 0 then
            tgt.life, tgt.dead = 0, true
            use("events").emit("death", tgt, src)
        end
        return true
    end)

    -- Same loop as __mock.advance; local so wrappers of it are not re-entered.
    function C.advance(seconds)
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

    function C.unit(owner, code, x, y, opts)
        local u = CreateUnit(Player(owner), type(code) == "string" and FourCC(code) or code, x, y, 0)
        u.hC, u.face = true, 0
        u.meta, u.inst, u.cd, u.cdBase, u.ufields, u.items, u.orders = {}, {}, {}, {}, {}, {}, {}
        u.mana, u.str, u.agi, u.int = 500, 20, 20, 20
        u.maxLife, u.life = 2000, 2000                  -- CreateUnit's mock default is 100
        for k, v in pairs(opts or {}) do u[k] = v end
        u.life = math.min(u.life, u.maxLife)
        u.taken = 0
        return u
    end

    function C.learn(u, name, lvl)
        local A = use("abilities")
        local id = A.id(name)
        assert(id, "no ability object for " .. name)
        u.abilities[id] = lvl
        use("events").emit("hero_skill", u, id)
        return id
    end

    function C.cast(u, name, target, x, y)
        local id = type(name) == "number" and name or use("abilities").id(name)
        assert(id, "no ability object for " .. tostring(name))
        x = x or (target and GetUnitX(target)) or GetUnitX(u)
        y = y or (target and GetUnitY(target)) or GetUnitY(u)
        use("events").emit("spell_channel", u, id, target, x, y)
        use("events").emit("spell_effect", u, id, target, x, y)
        return id
    end

    function C.endcast(u, name)
        local id = type(name) == "number" and name or use("abilities").id(name)
        use("events").emit("spell_endcast", u, id, nil, GetUnitX(u), GetUnitY(u))
    end

    function C.check(ok, msg)
        if not ok then error("check failed: " .. msg, 2) end
        use("log").check("heroesC " .. msg, true)
    end

    local prev = __mock.advance
    function __mock.advance(seconds)
        prev(seconds)
        if C.done then return end
        C.done = true
        for _, ex in ipairs(C.list) do
            local ok, err = xpcall(ex.fn, debug and debug.traceback or tostring, C)
            if not ok then
                use("log").error("heroes-C mock exercise '" .. ex.name .. "': " .. tostring(err))
                use("log").flush()
                error("heroes-C mock exercise '" .. ex.name .. "': " .. tostring(err), 0)
            end
            use("log").info("mock exercise " .. ex.name .. " ok")
        end
        use("log").flush()
    end
end

__mockC.list[#__mockC.list + 1] = {name = "morphling", fn = function(C)
    local A, Events, Mods = use("abilities"), use("events"), use("mods")
    local M = use("hero_morphling")
    local ids = use("data.ids")
    local X, Y = 21000, -21000
    local id = function(name) return A.id(name) end
    local function near(a, b) return math.abs(a - b) < 0.01 end

    local morph = C.unit(0, ids.heroes.morphling, X, Y, {hero = true, str = 16, agi = 33, int = 19, mana = 600})
    local foe = C.unit(7, "hfoo", X + 400, Y)
    local mk = C.unit(7, "Hmkg", X + 500, Y + 100, {hero = true, str = 30, agi = 15, int = 15})
    for code, m in pairs({AHtb = {hero = true}, AHtc = {hero = true}, AHbh = {hero = true},
                          AHav = {hero = true, req = 6}, AInv = {}}) do
        mk.abilities[FourCC(code)] = (code == "AHtb") and 2 or 1
        mk.meta[FourCC(code)] = m
    end
    morph.abilities[id("morphling_ebb_and_flow")] = 1
    M.register(morph)

    -- Learning: Agility and Strength Gain are linked.
    C.learn(morph, "morphling_waveform", 4)
    C.learn(morph, "morphling_adaptive_strike_agi", 4)
    C.learn(morph, "morphling_morph_agi", 1)
    C.check(GetUnitAbilityLevel(morph, id("morphling_morph_str")) == 1, "morphling str gain follows agi gain")
    morph.abilities[id("morphling_morph_str")] = 2
    Events.emit("hero_skill", morph, id("morphling_morph_str"))
    C.check(GetUnitAbilityLevel(morph, id("morphling_morph_agi")) == 2, "morphling agi gain follows str gain")

    -- Ebb and Flow: move speed from Agility.
    C.advance(0.3)
    local ebbMod = Mods.get(morph, "morphling_ebb")
    C.check(ebbMod ~= nil and near(ebbMod.props.move_flat, 5.0), "morphling ebb and flow move speed")

    -- Waveform: invulnerable surge that hits the footman on the way.
    C.cast(morph, "morphling_waveform", nil, X + 1500, Y)
    C.check(Mods.has(morph, "morphling_waveform"), "morphling waveform invulnerable")
    C.advance(1.2)
    C.check(foe.taken > 0, "morphling waveform damage " .. foe.taken)
    C.check(not Mods.has(morph, "morphling_waveform") and morph.x > X + 800, "morphling waveform moved " .. morph.x)
    C.check(M.session(morph) == nil, "morphling no session yet")

    -- Adaptive Strike: projectile, damage from Agility, stun from Strength.
    morph.x, morph.y = X, Y
    local before = mk.taken
    C.cast(morph, "morphling_adaptive_strike_agi", mk)
    C.advance(0.6)                                        -- 510 range at 1150: hit at ~0.45 s, 0.5 s stun
    C.check(mk.taken > before and Mods.has(mk, "morphling_adaptive_strike"), "morphling adaptive strike")
    C.advance(0.4)
    local dmg, stun, push = M.strikeNumbers(morph, function(k) return A.value("morphling_adaptive_strike_agi", k, 4) end)
    C.check(dmg > 110 and stun >= 0.5 and push >= 50, "morphling adaptive strike numbers")

    -- Attribute Shift: the Immolation toggle moves Strength into Agility.
    local str0, agi0, mana0 = morph.str, morph.agi, morph.mana
    Events.emit("order", morph, 852177)                   -- immolation (on)
    C.check(M.shifting(morph) == "agi", "morphling agi shift on")
    C.advance(1.0)
    C.check(morph.str < str0 and morph.agi > agi0 and morph.mana < mana0,
        "morphling agi shift moves points " .. morph.str .. "/" .. morph.agi)
    Events.emit("order", morph, OrderId("manashieldon"))  -- strength toggle
    C.advance(0.1)
    C.check(M.shifting(morph) == "str", "morphling str shift replaces agi shift")
    local found = false
    for _, o in ipairs(morph.orders) do if o == "unimmolation" then found = true end end
    C.check(found, "morphling agi toggle turned off")
    C.advance(0.5)
    M.shiftOff(morph, "str")
    Events.emit("order", morph, 852178)                   -- unimmolation: no-op now
    C.advance(0.1)
    C.check(M.shifting(morph) == nil, "morphling shift off")

    -- Morph into the Mountain King: basic WC3 spells copied, ultimate not.
    C.learn(morph, "morphling_replicate", 1)
    C.cast(morph, "morphling_replicate", mk)
    C.advance(0.1)
    local s = M.session(morph)
    C.check(s ~= nil and s.form == "target", "morphling morphed")
    C.check(GetUnitAbilityLevel(morph, FourCC("AHtb")) == 2 and GetUnitAbilityLevel(morph, FourCC("AHbh")) == 1,
        "morphling copied storm bolt and bash")
    C.check(GetUnitAbilityLevel(morph, FourCC("AHav")) == 0 and GetUnitAbilityLevel(morph, FourCC("AInv")) == 0,
        "morphling did not copy ultimate or non-hero ability")
    C.check(GetUnitAbilityLevel(morph, id("morphling_waveform")) == 0, "morphling own spells stashed")
    C.check(GetUnitAbilityLevel(morph, id("morphling_replicate")) == 0
        and GetUnitAbilityLevel(morph, id("morphling_morph_swap")) == 1, "morphling morph button swapped")
    C.check(BlzGetUnitSkin(morph) == mk.typeId, "morphling model copied")

    -- A hex that ends restores the base model; the tick puts the copy back.
    morph.skin = morph.typeId
    M.ebbTick(morph)
    C.check(BlzGetUnitSkin(morph) == mk.typeId, "morphling model restored after hex")

    -- Learning a stashed ability while morphed banks the point.
    morph.abilities[id("morphling_adaptive_strike_agi")] = 1
    Events.emit("hero_skill", morph, id("morphling_adaptive_strike_agi"))
    C.check(GetUnitAbilityLevel(morph, id("morphling_adaptive_strike_agi")) == 0, "morphling learn while morphed")

    -- Morph Replicate swaps forms; cooldowns of the stashed set keep running.
    BlzStartUnitAbilityCooldown(morph, FourCC("AHtb"), 9)
    C.cast(morph, "morphling_morph_swap")
    C.check(s.form == "own" and GetUnitAbilityLevel(morph, id("morphling_waveform")) == 4
        and GetUnitAbilityLevel(morph, FourCC("AHtb")) == 0, "morphling swap back to own form")
    C.check(BlzGetUnitSkin(morph) == morph.typeId, "morphling own model back")
    C.advance(2.0)
    C.cast(morph, "morphling_morph_swap")
    C.check(s.form == "target" and BlzGetUnitAbilityCooldownRemaining(morph, FourCC("AHtb")) > 5,
        "morphling swap keeps copied cooldowns")

    -- Morph ends: own form, Morph back on cooldown, swap button gone.
    M.endMorph(morph)
    C.check(M.session(morph) == nil and GetUnitAbilityLevel(morph, id("morphling_replicate")) == 1
        and GetUnitAbilityLevel(morph, id("morphling_morph_swap")) == 0
        and GetUnitAbilityLevel(morph, FourCC("AHtb")) == 0, "morphling morph ends")
    C.check(GetUnitAbilityLevel(morph, id("morphling_adaptive_strike_agi")) == 4, "morphling own levels kept")
    C.check(BlzGetUnitAbilityCooldownRemaining(morph, id("morphling_replicate")) > 0, "morphling morph cooldown")

    -- Morph into an allied Dota hero (Tinker): our Lua abilities are copied too.
    use("hero_tinker")
    local tinker = C.unit(1, ids.heroes.tinker, X + 200, Y + 200, {hero = true})
    for _, n in ipairs({"tinker_laser", "tinker_march_of_the_machines", "tinker_rearm"}) do
        tinker.abilities[id(n)] = 2
        tinker.meta[id(n)] = {hero = true, req = (n == "tinker_rearm") and 6 or 1}
    end
    BlzEndUnitAbilityCooldown(morph, id("morphling_replicate"))
    C.cast(morph, "morphling_replicate", tinker)
    C.advance(0.1)
    C.check(GetUnitAbilityLevel(morph, id("tinker_laser")) == 2 and GetUnitAbilityLevel(morph, id("tinker_rearm")) == 0,
        "morphling copied tinker basics")
    before = foe.taken
    foe.x, foe.y = X + 300, Y
    C.cast(morph, "tinker_laser", foe)
    C.check(foe.taken > before, "morphling casts copied laser")
    -- Death ends Morph.
    Events.emit("death", morph, nil)
    C.check(M.session(morph) == nil and GetUnitAbilityLevel(morph, id("tinker_laser")) == 0, "morphling death ends morph")

    -- A fresh Morphling learns Attribute Shift while morphed: both shifts are
    -- banked and appear (linked, level 1) only when he is back in his form.
    local m2 = C.unit(0, ids.heroes.morphling, X - 300, Y - 300, {hero = true})
    M.register(m2)
    C.learn(m2, "morphling_replicate", 1)
    C.cast(m2, "morphling_replicate", mk)
    C.advance(0.1)
    m2.abilities[id("morphling_morph_agi")] = 1          -- what WC3 does on learn
    Events.emit("hero_skill", m2, id("morphling_morph_agi"))
    C.check(GetUnitAbilityLevel(m2, id("morphling_morph_agi")) == 0
        and GetUnitAbilityLevel(m2, id("morphling_morph_str")) == 0, "morphling new skill banked while morphed")
    C.cast(m2, "morphling_morph_swap")
    C.check(GetUnitAbilityLevel(m2, id("morphling_morph_agi")) == 1
        and GetUnitAbilityLevel(m2, id("morphling_morph_str")) == 1, "morphling banked skill linked on swap back")
    M.endMorph(m2)
    C.advance(0.5)

    -- Talents (Waveform reach) and Aghanim's Shard (Attribute Shift at half the mana)
    local Tal, H = use("talents"), use("heroes")
    if not Tal.started then Tal.init() end
    local m3 = C.unit(0, ids.heroes.morphling, X, Y - 600, {hero = true, mana = 3000})
    H.keyOf[m3] = "morphling"
    Tal.register(m3)
    M.register(m3)
    C.learn(m3, "morphling_waveform", 4)
    C.learn(m3, "morphling_morph_agi", 4)
    m3.level = 25
    C.cast(m3, "morphling_waveform", nil, X + 3000, Y - 600)
    C.advance(1.5)
    local reach = m3.x - X
    m3.x = X
    C.check(Tal.pick(m3, "special_bonus_unique_morphling_1"), "morphling waveform talent picked")
    C.cast(m3, "morphling_waveform", nil, X + 3000, Y - 600)
    C.advance(1.5)
    C.check(math.abs((m3.x - X) - (reach + 250)) < 5, "morphling waveform reaches 250 farther " .. (m3.x - X))
    m3.mana = 3000
    Events.emit("order", m3, 852177)
    C.advance(1.0)
    local drain = 3000 - m3.mana
    Events.emit("order", m3, 852178)
    C.advance(0.1)
    Tal.consumeShard(m3)
    m3.mana, m3.str, m3.agi = 3000, 20, 20
    Events.emit("order", m3, 852177)
    C.advance(1.0)
    C.check(drain > 0 and math.abs((3000 - m3.mana) - drain / 2) < drain * 0.1,
        "morphling shard halves the shift's mana " .. drain .. " -> " .. (3000 - m3.mana))
    Events.emit("order", m3, 852178)
    C.advance(0.1)
    Tal.forget(m3)
    H.keyOf[m3] = nil
end}
