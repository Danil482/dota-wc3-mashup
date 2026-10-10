-- Offline exercise for the Tinker module (heroes C: tinker, rubick, morphling).
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

__mockC.list[#__mockC.list + 1] = {name = "tinker", fn = function(C)
    local A, Events, Mods, U = use("abilities"), use("events"), use("mods"), use("util")
    local T = use("hero_tinker")
    local ids = use("data.ids")
    local X, Y = 25000, -25000
    local id = function(name) return A.id(name) end

    local tinker = C.unit(0, ids.heroes.tinker, X, Y, {hero = true, int = 60, mana = 3000})
    tinker.abilities[id("tinker_keen_teleport")] = 1
    tinker.abilities[id("tinker_eureka")] = 1
    local foe = C.unit(7, "hfoo", X + 300, Y)
    local mk = C.unit(7, "Hmkg", X + 450, Y + 60, {hero = true})
    local tower = C.unit(6, "hgtw", X - 1600, Y, {structure = true})
    for _, n in ipairs({"tinker_laser", "tinker_march_of_the_machines", "tinker_deploy_turrets"}) do
        C.learn(tinker, n, 4)
    end

    -- Laser: pure damage and a blind that zeroes the target's attacks.
    C.cast(tinker, "tinker_laser", mk)
    C.check(mk.taken >= 299.9 and Mods.has(mk, "tinker_laser_blind"), "tinker laser pure damage and blind")
    C.check(C.fireDamage(mk, tinker, 50, true) == 0, "tinker blinded attack misses")
    C.check(C.fireDamage(mk, tinker, 50, false) == 50, "tinker blind does not stop spells")

    -- March of the Machines: robots sweep the square around Tinker.
    local before = foe.taken + mk.taken
    C.cast(tinker, "tinker_march_of_the_machines", nil, X + 200, Y)
    C.advance(7.0)
    C.check(foe.taken + mk.taken > before, "tinker march robots explode on enemies")

    -- Deploy Turrets: impact damage and knockback, three turrets, rockets.
    foe.x, foe.y, mk.x, mk.y = X + 320, Y, X + 450, Y + 60
    before = foe.taken
    C.cast(tinker, "tinker_deploy_turrets", nil, X + 300, Y)
    C.advance(0.6)
    C.check(foe.taken > before, "tinker turret drop damage")
    C.check(foe.x > X + 400, "tinker turret drop knockback " .. foe.x)
    local code, turrets = FourCC(ids.units.tinker_turret), {}
    for _, u in ipairs(__mock.units) do
        if u.typeId == code and not u.dead and U.dist(u.x, u.y, X + 300, Y) < 100 then turrets[#turrets + 1] = u end
    end
    C.check(#turrets == 3, "tinker three turrets " .. #turrets)
    before = foe.taken + mk.taken
    C.advance(2.0)
    C.check(foe.taken + mk.taken > before, "tinker turret rockets hit")
    for _, t in ipairs(turrets) do KillUnit(t) end

    -- Keen Conveyance: channel, then land next to the closest allied structure.
    tinker.x, tinker.y = X, Y
    C.cast(tinker, "tinker_keen_teleport", nil, X - 1500, Y)
    C.advance(3.1)
    C.endcast(tinker, "tinker_keen_teleport")
    C.check(U.dist(tinker.x, tinker.y, tower.x, tower.y) <= 801, "tinker keen conveyance lands at the tower")

    -- Rearm: its level drives Keen Conveyance; a full channel resets abilities
    -- and item cooldowns, an interrupted one does nothing.
    C.learn(tinker, "tinker_rearm", 3)
    C.check(GetUnitAbilityLevel(tinker, id("tinker_keen_teleport")) == 3, "tinker keen conveyance follows rearm")
    local potion = FourCC("AIh2")
    tinker.items[1] = {hCitem = true, abils = {potion}}
    T.register(tinker)
    C.advance(0.6)
    C.check(not T.anyOnCooldown(tinker), "tinker rearm hint withheld while nothing is on cooldown")
    BlzStartUnitAbilityCooldown(tinker, id("tinker_laser"), 16)
    BlzStartUnitAbilityCooldown(tinker, potion, 30)
    C.advance(0.6)
    C.check(T.anyOnCooldown(tinker), "tinker rearm hint offered after a spell")
    C.cast(tinker, "tinker_rearm")
    C.advance(0.5)
    C.endcast(tinker, "tinker_rearm")
    C.check(BlzGetUnitAbilityCooldownRemaining(tinker, id("tinker_laser")) > 0, "tinker interrupted rearm does nothing")
    C.cast(tinker, "tinker_rearm")
    C.advance(1.3)
    C.endcast(tinker, "tinker_rearm")
    C.check(BlzGetUnitAbilityCooldownRemaining(tinker, id("tinker_laser")) == 0, "tinker rearm resets abilities")
    C.check(BlzGetUnitAbilityCooldownRemaining(tinker, potion) == 0, "tinker rearm resets items")
    C.advance(0.6)
    C.check(not T.anyOnCooldown(tinker), "tinker rearm hint withdrawn after rearm")

    -- Eureka!: 60 Intelligence = 20 % item cooldown reduction after a use.
    BlzStartUnitAbilityCooldown(tinker, potion, 10)
    Events.emit("item_use", tinker, tinker.items[1])
    C.advance(0.05)
    local left = BlzGetUnitAbilityCooldownRemaining(tinker, potion)
    C.check(left > 7 and left < 8.1, "tinker eureka item cooldown " .. left)
    C.check(math.abs(T.itemCdr(tinker) - 0.2) < 1e-6, "tinker eureka percent")
    C.advance(0.5)
end}
