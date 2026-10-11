-- Roshan in his pit (mapdata "roshan"), Neutral Hostile, attacked by anyone.
-- Dota numbers from world.json plus his per-minute growth (game code: +130
-- health, +0.375 armor, +6 attack damage per minute), 55% magic resistance,
-- Bash (15%: +50 magical damage, 1.65 s stun), Slam (350 AoE, 70 + 10 per
-- minute magical, double against creeps, 50% slow for 4 s, every 10 s while
-- fighting) and Spell Block (one targeted spell every 15 s: the cast is
-- stopped but still costs its cooldown and mana, like Dota's Linken rule).
-- He walks back to the pit when dragged past the leash and respawns 8 to 11
-- minutes after a kill. Drops: Aegis; plus Cheese from the 2nd kill; plus a
-- Refresher Shard or Aghanim's Blessing from the 3rd if use("data.items")
-- has them (day: Shard, night: Blessing; none today, so they are skipped).
-- Aegis: WC3's own reincarnation (an Ankh-style item, 5 s, full health and
-- mana) revives the holder where it fell. A reincarnating hero fires no death
-- event, so heroes.lua never queues a fountain respawn and economy.lua pays
-- no bounty: there is no double revive. Lua adds the rest: heroes only,
-- 5 minutes after pickup it expires and heals over 5 s (broken by damage),
-- and after the revive "hero_respawned" fires so modules restore passives.
define("world_roshan", function()
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Mods = use("mods")
    local Damage = use("damage")
    local U = use("util")
    local Ro = {unit = nil, kills = 0, respawnAt = nil}

    Ro.GROWTH = {hp = 130, armor = 0.375, damage = 6}   -- per minute
    Ro.RESPAWN = {480, 660}
    Ro.LEASH = 650            -- beyond this from the pit he walks back
    Ro.ENGAGE = 5             -- seconds he counts as fighting after an attack
    local SLAM_FX = "Abilities\\Spells\\Orc\\WarStomp\\WarStompCaster.mdl"
    local SLOW_FX = "Abilities\\Spells\\Human\\slow\\slowtarget.mdl"
    local BASH_FX = "Abilities\\Spells\\Human\\Thunderclap\\ThunderclapTarget.mdl"
    local BLOCK_FX = "Abilities\\Spells\\Items\\SpellShieldAmulet\\SpellShieldCaster.mdl"
    local REVIVE_FX = "Abilities\\Spells\\Human\\Resurrect\\ResurrectTarget.mdl"
    local HEAL_FX = "Abilities\\Spells\\Human\\Heal\\HealTarget.mdl"
    local DROP_FX = "Abilities\\Spells\\Human\\HolyBolt\\HolyBoltSpecialArt.mdl"

    local W, data
    local pit
    local MOVE = nil
    local code = nil          -- Roshan's unit type
    local returning = false
    local engagedUntil, slamReady, blockReady = 0, 0, 0
    local bashing = nil       -- target bashed by the attack being resolved
    local aegis = {}          -- list of {item, holder, expires, dead, realDeath} (a list: fixed order)

    local function neutral() return Player(PLAYER_NEUTRAL_AGGRESSIVE) end

    -- ------------------------------------------------------------ Roshan

    function Ro.grow()
        local u = Ro.unit
        if not U.alive(u) then return end
        local m = math.floor(W.minutes())
        Mods.add(u, "roshan_growth", {dispel = "none", props = {
            max_hp = Ro.GROWTH.hp * m, armor = Ro.GROWTH.armor * m, damage = Ro.GROWTH.damage * m}})
    end

    function Ro.spawn()
        if not code or U.alive(Ro.unit) then return end
        local u = CreateUnit(neutral(), code, pit.x, pit.y, 270)
        UnitAddSleepPerm(u, false)
        Ro.unit, Ro.respawnAt, returning = u, nil, false
        engagedUntil, slamReady, blockReady = 0, 0, 0
        Mods.add(u, "roshan_devotion", {dispel = "none", props = {magic_resist = data.magic_resist / 100}})
        Ro.grow()
        SetWidgetLife(u, BlzGetUnitMaxHP(u))
        Log.info("world: Roshan spawned")
        return u
    end

    function Ro.slam()
        local u = Ro.unit
        local s = data.slam
        slamReady = Timer.now() + s.cooldown
        SetUnitAnimation(u, "spell")
        QueueUnitAnimation(u, "stand")
        Timer.after(s.cast_point, function()
            if not U.alive(u) then return end
            local x, y = GetUnitX(u), GetUnitY(u)
            DestroyEffect(AddSpecialEffect(SLAM_FX, x, y))
            local dmg = s.damage + s.damage_growth * math.floor(W.minutes())
            for _, e in ipairs(U.enemiesOf(neutral(), x, y, s.radius)) do
                local amount = IsUnitType(e, UNIT_TYPE_HERO) and dmg or dmg * (1 + s.damage_bonus_creeps / 100)
                Damage.deal(u, e, amount, Damage.MAGICAL)
                Mods.add(e, "roshan_slam", {duration = s.slow_duration, debuff = true, effect = SLOW_FX,
                    props = {move_pct = -s.slow_amount / 100, attack_speed = -s.slow_amount}})
            end
        end)
    end

    local function enemyNear(u, x, y, r)
        for _, e in ipairs(U.enemiesOf(neutral(), x, y, r)) do
            if IsUnitVisible(e, neutral()) then return e end
        end
        return nil
    end

    -- Leash, Slam and keeping the fight inside the pit.
    function Ro.think()
        local u = Ro.unit
        if not U.alive(u) then
            if Ro.respawnAt and W.clock() >= Ro.respawnAt then Ro.spawn() end
            return
        end
        local x, y = GetUnitX(u), GetUnitY(u)
        local d = U.dist(x, y, pit.x, pit.y)
        if returning then
            if d <= 100 then
                returning = false
                IssueImmediateOrder(u, "stop")
            elseif GetUnitCurrentOrder(u) ~= MOVE then
                IssuePointOrder(u, "move", pit.x, pit.y)
            end
            return
        end
        if d > Ro.LEASH then
            returning = true
            IssuePointOrder(u, "move", pit.x, pit.y)
            return
        end
        local now = Timer.now()
        if now < engagedUntil and now >= slamReady and enemyNear(u, x, y, data.slam.radius) then
            Ro.slam()
        end
    end

    local function attacked(attacker, target)
        local u = Ro.unit
        if not attacker or not U.alive(u) then return end
        if attacker == u then
            engagedUntil = Timer.now() + Ro.ENGAGE
        elseif target == u then
            engagedUntil = Timer.now() + Ro.ENGAGE
            if not returning and GetUnitCurrentOrder(u) == 0
                and U.dist(GetUnitX(attacker), GetUnitY(attacker), pit.x, pit.y) <= Ro.LEASH then
                IssueTargetOrder(u, "attack", attacker)
            end
        end
    end

    -- Bash: decided before the hit lands, the magical bonus after it.
    local function damaging(source, target, info)
        if source ~= Ro.unit or source == nil or not info.attack or not target
            or IsUnitType(target, UNIT_TYPE_STRUCTURE) then return end
        local b = data.bash
        if GetRandomInt(1, 100) <= b.bash_chance then
            bashing = target
            Mods.add(target, "roshan_bash", {duration = b.stun_duration, props = {stun = true}, debuff = true,
                                              dispel = "strong", effect = BASH_FX, attach = "overhead"})
        end
    end

    local function damaged(source, target)
        if bashing and source == Ro.unit and target == bashing then
            bashing = nil
            Damage.deal(source, target, data.bash.bonus_damage, Damage.MAGICAL)
        end
    end

    -- Spell Block: a spell aimed at Roshan is stopped before it takes
    -- effect; the caster still pays its cooldown and mana.
    function Ro.spellBlock(caster, abil, target)
        local u = Ro.unit
        if target ~= u or caster == u or not U.alive(u) or not caster then return false end
        if Timer.now() < blockReady or not IsUnitEnemy(caster, neutral()) then return false end
        blockReady = Timer.now() + data.spell_block.cooldown
        local lvl = math.max(1, GetUnitAbilityLevel(caster, abil))
        local cd = BlzGetUnitAbilityCooldown(caster, abil, lvl - 1)
        local mana = BlzGetUnitAbilityManaCost(caster, abil, lvl - 1)
        PauseUnit(caster, true)
        IssueImmediateOrder(caster, "stop")
        PauseUnit(caster, false)
        Timer.after(0, function()
            if cd > 0 then BlzStartUnitAbilityCooldown(caster, abil, cd) end
            if mana > 0 then
                SetUnitState(caster, UNIT_STATE_MANA, math.max(0, GetUnitState(caster, UNIT_STATE_MANA) - mana))
            end
        end)
        DestroyEffect(AddSpecialEffectTarget(BLOCK_FX, u, "origin"))
        return true
    end

    -- ------------------------------------------------------------ drops

    -- data.items name of the 3rd-kill bonus, or nil (day: Shard, night: Blessing).
    function Ro.thirdItem()
        local catalog = defined("data.items") and use("data.items").items or {}
        local codes = use("data.ids").items or {}
        local have = {}
        for _, name in ipairs({"item_refresher_shard", "item_ultimate_scepter_roshan"}) do
            if catalog[name] and codes[name] then have[#have + 1] = name end
        end
        if #have < 2 then return have[1] end
        local hour = GetFloatGameState(GAME_STATE_TIME_OF_DAY)
        return (hour >= 6 and hour < 18) and have[1] or have[2]
    end

    -- Item type for a drop: Dota items from data.items when they exist there.
    local function dropCode(key)
        local dota = key == "cheese" and "item_cheese" or key
        local codes = use("data.ids").items or {}
        if codes[dota] and defined("data.items") and use("data.items").items[dota] then return FourCC(codes[dota]) end
        return W.code("items", key)
    end

    function Ro.drops(n)
        local list = {"aegis"}
        if n >= 2 then list[#list + 1] = "cheese" end
        if n >= 3 then list[#list + 1] = Ro.thirdItem() end
        return list
    end

    local function drop(x, y, n)
        local made = {}
        for i, key in ipairs(Ro.drops(n)) do
            local itemCode = dropCode(key)
            if itemCode then
                local ix, iy = U.polar(x, y, i == 1 and 0 or 90, 2 * math.pi * i / 3)
                made[#made + 1] = CreateItem(itemCode, ix, iy)
                DestroyEffect(AddSpecialEffect(DROP_FX, ix, iy))
            end
        end
        return made
    end

    local function died(dying, killer)
        if dying ~= Ro.unit or dying == nil then return end
        Ro.kills = Ro.kills + 1
        Ro.lastDrops = drop(GetUnitX(dying), GetUnitY(dying), Ro.kills)
        Ro.respawnAt = W.clock() + GetRandomReal(Ro.RESPAWN[1], Ro.RESPAWN[2])
        local by = killer and use("roles").side(GetPlayerId(GetOwningPlayer(killer))) or "none"
        W.announce("|cffff8000Roshan|r has been slain" .. (by == "dota" and " by the Dota heroes"
            or by == "warcraft" and " by the Warcraft side" or "") .. ". The Aegis lies in the pit.")
        Log.info("world: Roshan kill " .. Ro.kills)
    end

    function Ro.bountyOf(u)
        if code and GetUnitTypeId(u) == code then
            return GetRandomInt(data.gold_min, data.gold_max), data.xp
        end
        return nil
    end

    -- ------------------------------------------------------------ Aegis

    local function aegisCode() return W.code("items", "aegis") end

    function Ro.aegisOf(it)
        for _, a in ipairs(aegis) do
            if a.item == it then return a end
        end
        return nil
    end

    function Ro.aegisPicked(u, it)
        if not it or GetItemTypeId(it) ~= aegisCode() then return end
        if not IsUnitType(u, UNIT_TYPE_HERO) or IsUnitIllusion(u) then
            UnitRemoveItem(u, it)         -- only real heroes carry the Aegis
            return
        end
        local a = Ro.aegisOf(it)
        if not a then
            a = {item = it, expires = Timer.now() + W.data().aegis.disappear_time}
            aegis[#aegis + 1] = a
            W.announce(W.playerName(u) .. " has picked up the |cffffd700Aegis of the Immortal|r.")
        end
        a.holder, a.dead, a.realDeath = u, false, false
    end

    local function revived(u)
        DestroyEffect(AddSpecialEffectTarget(REVIVE_FX, u, "origin"))
        SetWidgetLife(u, BlzGetUnitMaxHP(u))
        SetUnitState(u, UNIT_STATE_MANA, BlzGetUnitMaxMana(u))
        use("stats").refresh(u)
        W.announce(W.playerName(u) .. " has used the |cffffd700Aegis of the Immortal|r.")
        local key = defined("heroes") and use("heroes").keyOf[u]
        if key then Events.emit("hero_respawned", u, key, GetPlayerId(GetOwningPlayer(u))) end
        Events.emit("aegis_used", u)
    end

    local function expire(u)
        local d = W.data().aegis
        W.announce("The |cffffd700Aegis|r of " .. W.playerName(u) .. " has expired.")
        local per = 1 / 5
        Mods.add(u, "aegis_expire", {duration = 5, tick = 0.25, effect = HEAL_FX, attach = "origin",
            onTick = function(m)
                SetWidgetLife(m.unit, GetWidgetLife(m.unit) + BlzGetUnitMaxHP(m.unit) * per * m.tick)
                SetUnitState(m.unit, UNIT_STATE_MANA,
                    GetUnitState(m.unit, UNIT_STATE_MANA) + BlzGetUnitMaxMana(m.unit) * per * m.tick)
            end})
        Log.info("world: Aegis expired after " .. d.disappear_time .. " s")
    end

    -- Reincarnation shows as dead-then-alive without a death event.
    function Ro.aegisTick()
        local now = Timer.now()
        local keep, revive, expired = {}, {}, {}
        for _, a in ipairs(aegis) do
            local u, it = a.holder, a.item
            local done = true
            if GetUnitTypeId(u) == 0 then
                -- holder removed from the game
            elseif not U.alive(u) then
                if not a.realDeath then a.dead = true end
                done = false
            elseif a.dead then
                revive[#revive + 1] = u
            elseif a.realDeath then
                a.realDeath = false           -- respawned at the fountain, Aegis still held
                done = false
            elseif GetItemTypeId(it) == 0 or not UnitHasItem(u, it) then
                -- gone some other way
            elseif now >= a.expires then
                expired[#expired + 1] = a
            else
                done = false
            end
            if not done then keep[#keep + 1] = a end
        end
        aegis = keep
        for _, a in ipairs(expired) do
            RemoveItem(a.item)
            expire(a.holder)
        end
        for _, u in ipairs(revive) do revived(u) end
    end

    function Ro.init(world)
        W = world
        data = W.data().roshan
        pit = use("data.mapdata").roshan
        code = W.code("units", "roshan")
        MOVE = OrderId("move")
        if not pit or not code then
            Log.warn("world: no Roshan pit or unit")
            return
        end
        W.addBounty(Ro.bountyOf)
        W.at(0, nil, Ro.spawn)
        W.at(60, 60, Ro.grow)
        Timer.every(0.25, Ro.think)
        Timer.every(0.25, Ro.aegisTick)
        Events.on("attacked", attacked)
        Events.on("death", died)
        Events.on("death", function(dying)
            for _, a in ipairs(aegis) do
                if a.holder == dying then a.realDeath, a.dead = true, false end
            end
        end)
        Events.on("spell_channel", Ro.spellBlock)
        Events.on("item_pickup", Ro.aegisPicked)
        Damage.onDamaging(damaging)
        Damage.onDamaged(damaged)
        Damage.onDamaged(function(source, target, amount)
            if amount > 0 and source ~= target and Mods.has(target, "aegis_expire") then
                Mods.remove(target, "aegis_expire")
            end
        end)
    end

    return Ro
end)
