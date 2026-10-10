-- Offline exercise for the Dota world systems (src/game/world*.lua). At 12 s
-- of mock time it starts the world clock, jumps it forward with World.skip
-- and drives camps, stacking, leash, runes, Roshan (bash, slam, spell block,
-- drops, respawn), the Aegis (reincarnation, real death, expiry), lane creep
-- upgrades and the tower rules. Natives the generic stubs cannot answer are
-- overridden for the exercise's own units only (flag u.wx) and restored
-- afterwards. Failed checks become ERROR lines, which fail the mock run.
do
    local saved = {}
    local function stub(name, fn)
        if saved[name] == nil then saved[name] = _G[name] end
        _G[name] = fn
    end
    local function orig(name) return saved[name] or _G[name] end
    local function ours(u) return type(u) == "table" and u.wx == true end

    local ev = {damage = 0, attack = false, set = nil}
    local rec = {orders = {}, cooldowns = {}}

    -- own item model when tools/mock/items.lua did not install one
    local function ensureItems()
        local probe = CreateItem(FourCC("rspd"), 0, 0)
        if GetItemTypeId(probe) == FourCC("rspd") then
            RemoveItem(probe)
            return
        end
        local function slots(u) u.inv = u.inv or {} return u.inv end
        local function detach(it)
            local u = it.holder
            if not u then return end
            local s = slots(u)
            for i = 0, 5 do if s[i] == it then s[i] = nil end end
            it.holder = nil
        end
        stub("CreateItem", function(id, x, y)
            local it = __handle("item")
            it.typeId, it.x, it.y = id, x or 0, y or 0
            return it
        end)
        stub("RemoveItem", function(it) if it then detach(it) it.typeId = 0 end end)
        stub("GetItemTypeId", function(it) return it and it.typeId or 0 end)
        stub("GetItemX", function(it) return it and it.x or 0 end)
        stub("GetItemY", function(it) return it and it.y or 0 end)
        stub("UnitInventorySize", function() return 6 end)
        stub("UnitHasItem", function(u, it) return it ~= nil and it.holder == u and it.typeId ~= 0 end)
        stub("UnitAddItem", function(u, it)
            local s = slots(u)
            for i = 0, 5 do
                if s[i] == nil then s[i], it.holder = it, u return true end
            end
            return false
        end)
        stub("UnitRemoveItem", function(u, it) detach(it) it.x, it.y = u.x, u.y end)
    end

    local function side(p)
        local id = GetPlayerId(p)
        if id <= SLOT_DOTA_MAX or id == SLOT_ANCIENTS then return "dota" end
        if id == PLAYER_NEUTRAL_AGGRESSIVE then return "neutral" end
        return "commander"
    end

    local function install()
        stub("IsUnitType", function(u, t)
            if not ours(u) then return orig("IsUnitType")(u, t) end
            if t == UNIT_TYPE_DEAD then return u.dead == true end
            if t == UNIT_TYPE_HERO then return u.hero == true end
            if t == UNIT_TYPE_STRUCTURE then return u.structure == true end
            if t == UNIT_TYPE_MELEE_ATTACKER then return u.melee ~= false end
            return false
        end)
        stub("IsUnitEnemy", function(u, p) return side(GetOwningPlayer(u)) ~= side(p) end)
        stub("IsUnitAlly", function(u, p) return side(GetOwningPlayer(u)) == side(p) end)
        stub("IsUnitVisible", function() return true end)
        stub("IsUnitIllusion", function(u) return ours(u) and u.illusion == true end)
        stub("BlzSetUnitMaxHP", function(u, hp) u.maxLife = hp end)
        stub("BlzGetUnitBaseDamage", function(u) return u.baseDamage or 0 end)
        stub("BlzSetUnitBaseDamage", function(u, v) u.baseDamage = v end)
        stub("BlzGetUnitArmor", function(u) return u.armor or 0 end)
        stub("BlzSetUnitArmor", function(u, v) u.armor = v end)
        stub("BlzGetUnitMaxMana", function(u) return u.maxMana or 0 end)
        stub("GetUnitState", function(u, s)
            if s == UNIT_STATE_MANA then return u.mana or 0 end
            if s == UNIT_STATE_MAX_MANA then return u.maxMana or 0 end
            if s == UNIT_STATE_LIFE then return u.life or 0 end
            return 0.0
        end)
        stub("SetUnitState", function(u, s, v)
            if s == UNIT_STATE_MANA then u.mana = math.min(v, u.maxMana or v) end
        end)
        stub("SetWidgetLife", function(u, v) u.life = math.min(v, u.maxLife or v) end)
        stub("UnitDamageTarget", function(src, tgt, amount)
            tgt.life = math.max(0, (tgt.life or 0) - amount)
            return true
        end)
        stub("GetEventDamage", function() return ev.damage end)
        stub("BlzGetEventIsAttack", function() return ev.attack end)
        stub("BlzSetEventDamage", function(v) ev.set = v end)
        stub("IssuePointOrder", function(u, order, x, y)
            rec.orders[#rec.orders + 1] = {u = u, order = order}
            if ours(u) or u.wx_walk then u.x, u.y = x, y end    -- arrives at once
            return true
        end)
        stub("BlzGetUnitAbilityCooldown", function() return 20.0 end)
        stub("BlzGetUnitAbilityManaCost", function() return 100 end)
        stub("BlzGetUnitAbilityCooldownRemaining", function() return 20.0 end)
        stub("BlzStartUnitAbilityCooldown", function(u, a, cd) rec.cooldowns[#rec.cooldowns + 1] = {u = u, cd = cd} end)
    end

    local function restore()
        for name, fn in pairs(saved) do _G[name] = fn end
        saved = {}
    end

    -- Same loop as __mock.advance; local so wrappers of it are not re-entered.
    local function advance(seconds)
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

    local function exercise()
        local W = use("world")
        local Log, Mods, Events, U = use("log"), use("mods"), use("events"), use("util")
        local ids = use("data.ids")
        local failures = 0
        local function check(name, ok, detail)
            if not ok then
                failures = failures + 1
                Log.error("world exercise: " .. name .. (detail and (" - " .. tostring(detail)) or ""))
            end
        end
        local made = {}
        local function unit(slot, typeCode, x, y, o)
            o = o or {}
            local id = type(typeCode) == "string" and FourCC(typeCode) or typeCode
            local u = CreateUnit(Player(slot), id, x, y, 0)
            u.wx, u.hero, u.melee = true, o.hero or false, o.melee
            u.life, u.maxLife = o.hp or 1000, o.hp or 1000
            u.mana, u.maxMana = o.mana or 500, o.mana or 500
            u.baseDamage, u.armor = o.damage or 50, o.armor or 0
            made[#made + 1] = u
            return u
        end
        local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
        local function gold(slot) return GetPlayerState(Player(slot), PLAYER_STATE_RESOURCE_GOLD) end

        W.init()
        check("world started", W.started)
        local Camps, Runes, Ro, Towers = use("world_camps"), use("world_runes"), use("world_roshan"), use("world_towers")

        -- 0:00: bounty runes at 6 jungle spots and both river spots, Roshan up
        check("bounty spots", #Runes.spots.bounty == 6, #Runes.spots.bounty)
        check("runes at 0:00", count(Runes.ground) == 8, count(Runes.ground))
        check("roshan spawned", U.alive(Ro.unit))
        for _, spot in ipairs(Runes.spots.bounty) do
            local near = false
            for _, c in pairs(use("data.mapdata").camps) do
                if U.dist(spot.x, spot.y, c.x, c.y) < 1100 then near = true end
            end
            check("bounty spot near a camp", near, spot.x .. "," .. spot.y)
        end

        -- camp types from names
        check("camp types", Camps.typeOf("d_ancient") == "ancient" and Camps.typeOf("c_small") == "small"
            and Camps.typeOf("o_top1") == "medium" and Camps.typeOf("o_bot2") == "large")

        -- 1:00 first spawn everywhere
        W.skip(60)
        check("14 camps", #Camps.camps == 14, #Camps.camps)
        for _, camp in ipairs(Camps.camps) do
            check("camp " .. camp.name .. " spawned", Camps.count(camp) >= 2, Camps.count(camp))
        end
        local anyCreep, anyCamp = nil, Camps.find("d_small")
        for u, c in pairs(Camps.creeps) do if c.camp == anyCamp then anyCreep = u end end
        local g, xp = W.bountyOf(anyCreep)
        check("camp creep bounty", g and g > 0 and xp and xp > 0, tostring(g) .. "/" .. tostring(xp))
        check("camp creeps are neutral", anyCreep and GetOwningPlayer(anyCreep) == Player(PLAYER_NEUTRAL_AGGRESSIVE))

        -- 2:00: occupied boxes do not spawn; water runes on the river
        local total = Camps.count()
        W.skip(60)
        check("full camps wait", Camps.count() == total, Camps.count() .. " vs " .. total)
        local water = 0
        for _, r in pairs(Runes.ground) do if r.kind == "water" then water = water + 1 end end
        check("water runes at 2:00", water == 2, water)

        install()

        -- stacking: creeps pulled out of the box, the next minute adds a set
        local large = Camps.find("d_large")
        local before = Camps.count(large)
        for u, c in pairs(Camps.creeps) do
            if c.camp == large then SetUnitPosition(u, large.x + 520, large.y) end
        end
        W.skip(60)
        check("stacked camp", Camps.count(large) > before, Camps.count(large) .. " vs " .. before)

        -- leash: dragged away, walks home and heals
        local dragged, info = nil, nil
        for u, c in pairs(Camps.creeps) do if c.camp == large then dragged, info = u, c end end
        dragged.wx_walk = true
        SetUnitPosition(dragged, large.x + 1200, large.y)
        dragged.life, dragged.maxLife = 10, 900
        Camps.leash()
        check("leash returns", info.returning and math.abs(GetUnitX(dragged) - info.hx) < 1, GetUnitX(dragged))
        Camps.leash()
        check("leash heals", not info.returning and dragged.life == 900, dragged.life)

        -- runes: walking over a bounty rune pays every Dota hero player
        local spot = Runes.spots.bounty[1]
        local hero = unit(0, ids.heroes.pudge, spot.x, spot.y, {hero = true, hp = 1000, mana = 400})
        local g0, g1 = gold(0), gold(1)
        Runes.scan()
        local expect = math.floor(Runes.BOUNTY_GOLD + Runes.BOUNTY_PER_MINUTE * W.minutes())
        check("bounty gold to picker", gold(0) - g0 == expect, gold(0) - g0)
        check("bounty gold to team", gold(1) - g1 == expect, gold(1) - g1)
        check("bounty rune gone", spot.item == nil)

        -- illusions cannot take runes
        local river = Runes.spots.river[1]
        local fake = unit(0, ids.heroes.pudge, river.x, river.y, {hero = true})
        fake.illusion = true
        local it = Runes.place(river, "haste")
        check("illusion refused", not Runes.activate(fake, it) and river.item ~= nil and river.item ~= it)
        RemoveUnit(fake)

        -- every power rune once, plus water
        SetUnitPosition(hero, river.x + 2000, river.y)
        local dummies = 0
        local dummyType = FourCC(ids.world.units.dummy)
        for _, u in ipairs(__mock.units) do if u.typeId == dummyType then dummies = dummies + 1 end end
        for _, kind in ipairs({"doubledamage", "haste", "illusion", "invisibility", "regeneration", "arcane",
                               "shield", "water"}) do
            local r = Runes.place(river, kind)
            hero.life, hero.mana = 500, 100
            check("rune " .. kind .. " taken", Runes.activate(hero, r))
        end
        check("amplify damage", Mods.has(hero, "rune_doubledamage"))
        check("haste", Mods.has(hero, "rune_haste") and Mods.get(hero, "rune_haste").props.move_flat > 0)
        local after = 0
        for _, u in ipairs(__mock.units) do if u.typeId == dummyType then after = after + 1 end end
        check("illusion casters", after - dummies == 2, after - dummies)
        check("invisibility fades in", Mods.has(hero, "rune_invis_fade"))
        check("shield barrier", Runes.shieldOf(hero) == 500, Runes.shieldOf(hero))
        check("water", hero.life == 540 and hero.mana == 180, hero.life .. "/" .. hero.mana)
        advance(2.2)
        check("invisible after fade", Mods.has(hero, "rune_invisibility") and Mods.flag(hero, "invisible"))
        check("regeneration heals", hero.life > 540, hero.life)
        local foe = unit(SLOT_HORDE, ids.units.human_melee, hero.x + 100, hero.y)
        Events.emit("attacked", hero, foe)
        check("attacking breaks invisibility", not Mods.has(hero, "rune_invisibility"))
        -- shield soaks damage after armor
        ev.damage, ev.attack, ev.set = 120, true, nil
        Events.emit("damaged", foe, hero)
        check("shield soaks", ev.set == 0 and Runes.shieldOf(hero) == 380, tostring(ev.set) .. "/" .. tostring(Runes.shieldOf(hero)))
        ev.damage, ev.attack = 0, false
        -- arcane: cooldown -25%, 30% mana back
        local abil = FourCC("AHtb")
        hero.abilities[abil] = 1
        Mods.remove(hero, "rune_regeneration")
        hero.mana = 100
        rec.cooldowns = {}
        Events.emit("spell_effect", hero, abil, foe, 0, 0)
        advance(0.05)
        check("arcane cooldown", #rec.cooldowns > 0 and math.abs(rec.cooldowns[#rec.cooldowns].cd - 15) < 0.01)
        check("arcane mana", math.abs(hero.mana - 130) < 0.01, hero.mana)

        -- 6:00 and later: one power rune on a river spot
        W.skip(240)
        local power = 0
        for _, r in pairs(Runes.ground) do
            for _, k in ipairs(Runes.POWER) do if r.kind == k then power = power + 1 end end
        end
        check("one power rune", power == 1, power)

        -- Roshan: growth, bounty, bash, slam, spell block, leash
        local rosh = Ro.unit
        local growth = Mods.get(rosh, "roshan_growth")
        check("roshan growth", growth and growth.props.max_hp == 130 * math.floor(W.minutes()),
            growth and growth.props.max_hp)
        local rg, rx = W.bountyOf(rosh)
        check("roshan bounty", rg and rg >= 200 and rg <= 290 and rx == 400, tostring(rg))
        local pit = use("data.mapdata").roshan
        SetUnitPosition(hero, pit.x + 150, pit.y)
        rosh.wx = true
        rosh.life, rosh.maxLife = 6000, 6000
        ev.damage, ev.attack = 75, true
        for _ = 1, 200 do
            Events.emit("damaging", rosh, hero)
            Events.emit("damaged", rosh, hero)
            if Mods.has(hero, "roshan_bash") then break end
        end
        ev.damage, ev.attack = 0, false
        check("roshan bash", Mods.has(hero, "roshan_bash"))
        hero.life = 1000
        Ro.slam()
        advance(0.6)
        check("roshan slam", Mods.has(hero, "roshan_slam") and hero.life < 1000, hero.life)
        rec.cooldowns = {}
        check("spell block", Ro.spellBlock(hero, abil, rosh))
        check("spell block cooldown", not Ro.spellBlock(hero, abil, rosh))
        advance(0.05)
        check("blocked spell still on cooldown", #rec.cooldowns == 1)
        rosh.wx_walk = true
        SetUnitPosition(rosh, pit.x + 1200, pit.y)
        Ro.think()
        Ro.think()
        check("roshan leash", U.dist(GetUnitX(rosh), GetUnitY(rosh), pit.x, pit.y) < 1)

        -- three kills: Aegis, + Cheese, + nothing more (no Shard or Blessing in data.items)
        local aegisType = FourCC(ids.world.items.aegis)
        local cheeseType = FourCC(ids.world.items.cheese)
        local function kill()
            local r = Ro.unit
            r.wx = true
            KillUnit(r)
            Events.emit("death", r, hero)
            local wait = Ro.respawnAt - W.clock()
            check("respawn in 8-11 min", wait >= 480 and wait <= 660, wait)
            local drops = Ro.lastDrops
            W.skip(661)
            Ro.think()
            check("roshan respawned", U.alive(Ro.unit) and Ro.unit ~= r)
            return drops
        end
        local d1 = kill()
        check("1st kill drops Aegis", #d1 == 1 and GetItemTypeId(d1[1]) == aegisType, #d1)
        local d2 = kill()
        check("2nd kill adds Cheese", #d2 == 2 and GetItemTypeId(d2[2]) == cheeseType, #d2)
        local d3 = kill()
        check("3rd kill without Shard/Blessing", #d3 == 2 and Ro.kills == 3, #d3)

        -- Aegis: reincarnation revives in place and fires hero_respawned once
        local respawns = 0
        Events.on("hero_respawned", function(u) if u == hero then respawns = respawns + 1 end end)
        use("heroes").keyOf[hero] = "pudge"
        UnitAddItem(hero, d1[1])
        Events.emit("item_pickup", hero, d1[1])
        check("aegis tracked", Ro.aegisOf(d1[1]) ~= nil)
        hero.dead = true
        RemoveItem(d1[1])                 -- WC3 spends the Ankh charge
        Ro.aegisTick()
        hero.dead, hero.life = false, 1
        Ro.aegisTick()
        check("aegis revive", respawns == 1 and hero.life == hero.maxLife, respawns)
        Ro.aegisTick()
        check("no second revive", respawns == 1, respawns)
        -- a real death (no reincarnation) leaves revives to heroes.lua
        UnitAddItem(hero, d2[1])
        Events.emit("item_pickup", hero, d2[1])
        hero.dead = true
        Events.emit("death", hero, foe)
        Ro.aegisTick()
        hero.dead = false
        Ro.aegisTick()
        check("real death is not an Aegis revive", respawns == 1, respawns)
        -- expiry after 5 minutes heals over 5 s
        Ro.aegisOf(d2[1]).expires = 0
        Ro.aegisTick()
        check("aegis expires", GetItemTypeId(d2[1]) == 0 and Mods.has(hero, "aegis_expire"))
        -- non-heroes cannot keep it
        local courier = unit(1, "hfoo", hero.x, hero.y)
        UnitAddItem(courier, d3[1])
        Events.emit("item_pickup", courier, d3[1])
        check("only heroes carry the Aegis", not UnitHasItem(courier, d3[1]) and Ro.aegisOf(d3[1]) == nil)
        use("heroes").keyOf[hero] = nil

        -- lane creep upgrades
        local n = W.laneLevel()
        check("lane level", n == math.min(30, math.floor(W.clock() / 450)), n)
        local melee = unit(SLOT_ANCIENTS, ids.units.dota_melee, -6000, -2000, {hp = 550, damage = 18})
        W.scaleCreep(melee, "dota_melee")
        check("melee upgrade", melee.maxLife == 550 + 12 * n and melee.baseDamage == 18 + n,
            melee.maxLife .. "/" .. melee.baseDamage)
        local mg, mx = W.bountyOf(melee)
        check("melee bounty", mg >= 34 + n and mg <= 39 + n and mx == 57, mg)
        local siege = unit(SLOT_HORDE, ids.units.human_siege, -6000, -2100, {hp = 935, damage = 34})
        W.scaleCreep(siege, "human_siege")
        check("siege does not scale", siege.maxLife == 935)

        -- towers: true sight, tier 1 aura, backdoor protection
        local S = use("structures")
        local t1, t2 = S.towers.mid[1], S.towers.mid[2]
        check("true sight", GetUnitAbilityLevel(t1, FourCC(ids.world.abilities.truesight)) > 0)
        local guard = unit(0, ids.heroes.pudge, GetUnitX(t1) + 200, GetUnitY(t1), {hero = true})
        Towers.update()
        check("tier 1 aura", Mods.has(guard, "tower_protection")
            and Mods.get(guard, "tower_protection").props.armor == 5)
        check("backdoor on", Towers.isProtected(t2) and not Towers.isProtected(t1))
        ev.damage, ev.set = 100, nil
        Events.emit("damaging", foe, t2)
        check("backdoor reduces damage", ev.set and math.abs(ev.set - 60) < 0.01, ev.set)
        SetWidgetLife(t2, 50)
        Events.emit("damaged", foe, t2)
        Towers.update()
        check("backdoor regenerates", GetWidgetLife(t2) > 50, GetWidgetLife(t2))
        local creep = unit(SLOT_HORDE, ids.units.human_melee, GetUnitX(t2) + 300, GetUnitY(t2))
        Towers.update()
        check("lane creeps lift it", not Towers.isProtected(t2))
        ev.set = nil
        Events.emit("damaging", foe, t2)
        check("full damage with creeps", ev.set == 100, ev.set)
        RemoveUnit(creep)
        Towers.protected[t2].lastCreep = -1000
        local invader = unit(SLOT_HORDE, ids.units.human_melee, -5000, -5200)
        Towers.update()
        check("base invasion lifts base protection", not Towers.isProtected(S.ancient) and Towers.isProtected(t2))
        RemoveUnit(invader)
        ev.damage, ev.set = 0, nil

        for _, u in ipairs(made) do RemoveUnit(u) end
        Log.info("world exercise: " .. failures .. " failed checks")
    end

    local function run()
        if not defined or not defined("world") then return end
        ensureItems()
        local ok, err = xpcall(exercise, debug and debug.traceback or tostring)
        restore()
        if not ok then use("log").error("world exercise crashed: " .. tostring(err)) end
        use("log").flush()
    end

    TimerStart(CreateTimer(), 12.0, false, run)
end
