-- Offline exercise for the Rubick module (heroes C: tinker, rubick, morphling).
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

__mockC.list[#__mockC.list + 1] = {name = "rubick", fn = function(C)
    local A, Events, Mods, U = use("abilities"), use("events"), use("mods"), use("util")
    local R = use("hero_rubick")
    use("hero_tinker")                    -- supplies a Lua-driven Dota spell to steal
    local ids = use("data.ids")
    local X, Y = 23000, -23000
    local id = function(name) return A.id(name) end
    local STORM, ITEM = FourCC("AHtb"), FourCC("AItg")

    local rubick = C.unit(0, ids.heroes.rubick, X, Y, {hero = true, int = 30, mana = 1000})
    local foe = C.unit(7, "hfoo", X + 400, Y)
    local foe2 = C.unit(7, "hfoo", X + 600, Y + 100)
    local mk = C.unit(7, "Hmkg", X + 500, Y - 200, {hero = true})
    mk.abilities[STORM], mk.meta[STORM] = 2, {hero = true}
    mk.abilities[ITEM], mk.meta[ITEM] = 1, {item = true}
    local ally = C.unit(1, "hfoo", X - 200, Y)

    C.learn(rubick, "rubick_telekinesis", 4)
    C.learn(rubick, "rubick_fade_bolt", 4)
    C.learn(rubick, "rubick_arcane_supremacy", 4)
    C.learn(rubick, "rubick_spell_steal", 3)

    -- Arcane Supremacy: spell amp modifier and cast range on his abilities.
    local amp = Mods.get(rubick, "rubick_arcane_supremacy")
    C.check(amp ~= nil and math.abs(amp.props.spell_amp - 0.26) < 1e-6, "rubick arcane supremacy spell amp")
    local tk = BlzGetUnitAbility(rubick, id("rubick_telekinesis"))
    C.check(math.abs(BlzGetAbilityRealLevelField(tk, ABILITY_RLF_CAST_RANGE, 3) - 840) < 1,
        "rubick arcane supremacy cast range")
    C.check(math.abs(C.fireDamage(rubick, foe, 100, false) - 126) < 0.01, "rubick amplifies native spell damage")

    -- Telekinesis: lift, choose the landing point (clamped), land and stun.
    C.cast(rubick, "rubick_telekinesis", foe)
    C.advance(0.05)
    C.check(Mods.has(foe, "rubick_telekinesis") and GetUnitAbilityLevel(rubick, id("rubick_tk_land")) == 1,
        "rubick telekinesis lifts and grants land")
    C.cast(rubick, "rubick_tk_land", nil, X + 3000, Y)
    local s = R.lifts[rubick]
    C.check(s ~= nil and math.abs(U.dist(s.x0, s.y0, s.lx, s.ly) - 375) < 1, "rubick telekinesis land clamped")
    C.advance(2.0)
    C.check(not Mods.has(foe, "rubick_telekinesis") and Mods.has(foe, "rubick_telekinesis_stun"),
        "rubick telekinesis lands and stuns")
    C.check(math.abs(foe.x - (X + 775)) < 2, "rubick telekinesis moved the target " .. foe.x)
    C.check(GetUnitAbilityLevel(rubick, id("rubick_tk_land")) == 0, "rubick telekinesis land removed")

    -- Fade Bolt: jumps, weakens the damage the targets deal.
    foe.x, foe.y = X + 400, Y
    local t1, t2 = foe.taken, foe2.taken
    C.cast(rubick, "rubick_fade_bolt", foe)
    C.advance(0.8)
    C.check(foe.taken > t1 and foe2.taken > t2, "rubick fade bolt jumps")
    C.check(Mods.has(foe2, "rubick_fade_bolt"), "rubick fade bolt debuff")
    local weak = C.fireDamage(foe, rubick, 100, true)
    C.check(math.abs(weak - 76) < 0.01, "rubick fade bolt weakens attacks " .. weak)

    -- Spell Steal needs a recorded spell; items are never recorded.
    rubick.orders = {}
    Events.emit("spell_channel", rubick, id("rubick_spell_steal"), mk, GetUnitX(mk), GetUnitY(mk))
    C.check(rubick.orders[1] == "stop", "rubick spell steal refuses a hero with no spell")
    Events.emit("spell_effect", mk, ITEM, nil, 0, 0)
    C.check(R.lastSpell(mk) == nil, "rubick ignores item abilities")

    -- A Warcraft III hero spell: copied natively at the victim's level.
    Events.emit("spell_effect", mk, STORM, rubick, 0, 0)
    C.check(R.lastSpell(mk) ~= nil and R.lastSpell(mk).id == STORM, "rubick tracks storm bolt")
    local localPlayer = GetLocalPlayer
    GetLocalPlayer = function() return Player(0) end
    C.cast(rubick, "rubick_spell_steal", mk)
    C.advance(1.0)
    GetLocalPlayer = localPlayer
    -- Rubick gets the D-cell copy, so the stolen spell never shares his hotkeys
    local STORM_D = A.copyId(STORM)
    C.check(STORM_D ~= nil and GetUnitAbilityLevel(rubick, STORM) == 0 and GetUnitAbilityLevel(rubick, STORM_D) == 2,
        "rubick stole storm bolt at level 2 as its D-cell copy")
    C.check(math.abs((rubick.cdBase[STORM_D] or 0) - 7) < 0.01, "rubick stolen spell cooldown reduced")

    -- A Lua-driven Dota spell: goes into the unit-target slot, forwards casts.
    local enemyTinker = C.unit(7, ids.heroes.tinker, X + 300, Y + 300, {hero = true})
    local laser = id("tinker_laser")
    enemyTinker.abilities[laser] = 3
    enemyTinker.meta[laser] = {hero = true, order = ids.orders.tinker_laser, targetType = 1, range = 650}
    Events.emit("spell_effect", enemyTinker, laser, rubick, 0, 0)
    local rec = R.lastSpell(enemyTinker)
    C.check(rec ~= nil and rec.slot == "rubick_stolen_unit", "rubick dota spell uses the unit slot")
    C.cast(rubick, "rubick_spell_steal", enemyTinker)
    C.advance(1.0)
    local slot = id("rubick_stolen_unit")
    C.check(GetUnitAbilityLevel(rubick, STORM_D) == 0, "rubick previous stolen spell replaced")
    C.check(GetUnitAbilityLevel(rubick, slot) == 1 and R.stolen(rubick).slotId == slot, "rubick holds laser in a slot")
    local sab = BlzGetUnitAbility(rubick, slot)
    C.check(math.abs(BlzGetAbilityRealLevelField(sab, ABILITY_RLF_CAST_RANGE, 0) - 890) < 1, "rubick slot range")
    rubick.orders = {}
    Events.emit("spell_channel", rubick, slot, ally, GetUnitX(ally), GetUnitY(ally))
    C.check(rubick.orders[1] == "stop", "rubick slot refuses a target of the wrong team")
    local before = foe.taken
    C.cast(rubick, slot, foe)
    C.check(foe.taken - before > 280 and Mods.has(foe, "tinker_laser_blind"),
        "rubick casts the stolen laser at level 3 with spell amp " .. (foe.taken - before))
    C.endcast(rubick, slot)                               -- forwarded end of cast (no-op for Laser)

    -- Bot hint upkeep: Spell Steal is offered only if every enemy hero in
    -- range has a spell to steal.
    R.addRubick(rubick)
    C.advance(0.6)
    C.check(R.stealReady(rubick), "rubick steal hint offered when every hero has a spell")
    local fresh = C.unit(7, "Hpal", X + 100, Y + 100, {hero = true})
    C.check(not R.stealReady(rubick), "rubick steal hint withheld for a hero without a spell")
    fresh.dead = true

    -- Death ends the stolen spell.
    Events.emit("death", rubick, nil)
    C.check(R.stolen(rubick) == nil and GetUnitAbilityLevel(rubick, slot) == 0, "rubick loses the stolen spell on death")
    C.advance(0.5)
end}
