-- Generic Dota hero bot. Each bot gets a lane, follows its creep wave, fights
-- what it meets, casts abilities according to the hints hero modules register
-- (see bots.lua), learns skills as it levels and retreats to the fountain when
-- hurt. Thinks every half second.
define("hero_bot", function()
    local Timer = use("timer")
    local U = use("util")
    local A = use("abilities")
    local Mods = use("mods")
    local Log = use("log")
    local Bot = {}

    local bots = {}               -- unit -> state

    local function lanePath(lane)
        local m = use("data.mapdata")
        local path = {}
        for _, p in ipairs(m.lanes[lane]) do path[#path + 1] = p end
        path[#path + 1] = m.commander.start
        return path
    end

    -- Learnable abilities of a hero: ultimates first in priority when allowed.
    local function skillsOf(heroKey)
        local ids = use("data.ids")
        local innate = {}
        for _, code in ipairs(ids.heroes[heroKey .. "_innates"] or {}) do innate[code] = true end
        local basics, ults, granted = {}, {}, {}
        for _, ab in ipairs(use("data.heroes")[heroKey].abilities) do
            local code = ids.abilities[ab.name]
            if code and (ab.IsGrantedByScepter == "1" or ab.IsGrantedByShard == "1") then
                -- Aghanim's abilities are never learned, only cast once owned
                granted[#granted + 1] = {name = ab.name, id = FourCC(code)}
            elseif code and not innate[code] then
                local entry = {name = ab.name, id = FourCC(code)}
                if string.find(ab.AbilityType or "", "ULTIMATE") then
                    ults[#ults + 1] = entry
                else
                    basics[#basics + 1] = entry
                end
            end
        end
        return basics, ults, granted
    end

    local function learnable(u, ab, level, ult)
        local cur = GetUnitAbilityLevel(u, ab.id)
        if ult then return cur < 3 and level >= 6 * (cur + 1) end
        return cur < 4 and level >= 2 * cur + 1     -- Dota: basic level n needs hero level 2n-1
    end

    -- Follow Valve's own bot skill order from the player's Dota 2 when it
    -- names a learnable ability, otherwise ultimate first, then the lowest basic.
    local function learn(s)
        local u = s.unit
        local guard = 0
        while GetHeroSkillPoints(u) > 0 and guard < 5 do
            guard = guard + 1
            local level = GetHeroLevel(u) - GetHeroSkillPoints(u) + 1
            local picked = nil
            local wanted = s.build[level]
            for _, list in ipairs({s.ults, s.basics}) do
                for _, ab in ipairs(list) do
                    if ab.name == wanted and learnable(u, ab, GetHeroLevel(u), list == s.ults) then picked = ab end
                end
            end
            if not picked then
                for _, ab in ipairs(s.ults) do
                    if learnable(u, ab, GetHeroLevel(u), true) then picked = ab break end
                end
            end
            if not picked then
                local bestLevel = math.huge
                for _, ab in ipairs(s.basics) do
                    local cur = GetUnitAbilityLevel(u, ab.id)
                    if learnable(u, ab, GetHeroLevel(u), false) and cur < bestLevel then picked, bestLevel = ab, cur end
                end
            end
            if not picked then break end
            SelectHeroSkill(u, picked.id)
        end
        if defined("talents") and use("talents").started then use("talents").botPick(u, s.build) end
    end

    local function hpFrac(u)
        return GetWidgetLife(u) / math.max(1, BlzGetUnitMaxHP(u))
    end

    local function manaOk(u, id, level)
        return GetUnitState(u, UNIT_STATE_MANA) >= BlzGetUnitAbilityManaCost(u, id, level - 1)
    end

    local function enemiesNear(u, radius, heroesOnly)
        return U.enum(GetUnitX(u), GetUnitY(u), radius, function(t)
            return IsUnitEnemy(t, GetOwningPlayer(u)) and IsUnitVisible(t, GetOwningPlayer(u))
                and not BlzIsUnitInvulnerable(t) and not IsUnitType(t, UNIT_TYPE_STRUCTURE)
                and (not heroesOnly or IsUnitType(t, UNIT_TYPE_HERO))
        end)
    end

    local function lowest(list)
        local best, frac = nil, 2
        for _, t in ipairs(list) do
            local f = hpFrac(t)
            if f < frac then best, frac = t, f end
        end
        return best
    end

    -- Try one ability per think; returns true if an order was issued.
    local function cast(s)
        local u = s.unit
        if Mods.flag(u, "stun") or Mods.flag(u, "silence") then return false end
        local orders = use("data.ids").orders
        local hints = use("bots").hints
        for _, list in ipairs({s.ults, s.basics, s.granted or {}}) do
            for _, ab in ipairs(list) do
                local hint = hints[ab.name]
                local level = GetUnitAbilityLevel(u, ab.id)
                local order = orders[ab.name]
                if hint and hint.check and not hint.check(u, ab.name) then
                    -- the hero module vetoes this ability right now
                elseif hint and hint.toggle and level > 0 then
                    -- Toggles (e.g. Rot): on while enemies are close, off otherwise.
                    -- hint.onOrder/offOrder default to Immolation's orders.
                    local want = #enemiesNear(u, hint.radius or 400, false) >= (hint.minEnemies or 1)
                    if want ~= (s.toggled[ab.name] == true) then
                        s.toggled[ab.name] = want
                        IssueImmediateOrder(u, want and (hint.onOrder or "immolation") or (hint.offOrder or "unimmolation"))
                    end
                elseif hint and order and level > 0 and BlzGetUnitAbilityCooldownRemaining(u, ab.id) <= 0
                    and manaOk(u, ab.id, level) and (not hint.hpBelow or hpFrac(u) < hint.hpBelow) then
                    local range = hint.range or A.value(ab.name, "AbilityCastRange", level)
                    if range <= 0 then range = 600 end
                    local t = hint.target or "enemyHero"
                    local ok = false
                    if t == "enemyHero" or t == "enemy" then
                        local target = lowest(enemiesNear(u, range, t == "enemyHero"))
                        if target and (not hint.targetHpBelow or hpFrac(target) < hint.targetHpBelow)
                            and not (hint.ultimate and not IsUnitType(target, UNIT_TYPE_HERO)) then
                            if hint.point then
                                ok = IssuePointOrder(u, order, GetUnitX(target), GetUnitY(target))
                            else
                                ok = IssueTargetOrder(u, order, target)
                            end
                        end
                    elseif t == "point" then
                        local target = lowest(enemiesNear(u, range, false))
                        if target then ok = IssuePointOrder(u, order, GetUnitX(target), GetUnitY(target)) end
                    elseif t == "ally" or t == "allyHero" then
                        local allies = U.alliesOf(GetOwningPlayer(u), GetUnitX(u), GetUnitY(u), range)
                        local pick, frac = nil, 0.7
                        for _, a in ipairs(allies) do
                            if (t == "ally" or IsUnitType(a, UNIT_TYPE_HERO)) and hpFrac(a) < frac then pick, frac = a, hpFrac(a) end
                        end
                        if pick then ok = IssueTargetOrder(u, order, pick) end
                    elseif t == "self" or t == "none" then
                        local n = #enemiesNear(u, hint.radius or 400, hint.ultimate)
                        if n >= (hint.minEnemies or 1) then
                            if t == "self" then ok = IssueTargetOrder(u, order, u) else ok = IssueImmediateOrder(u, order) end
                        end
                    end
                    if ok then
                        s.castUntil = Timer.now() + 1.5
                        return true
                    end
                end
            end
        end
        return false
    end

    local function fountain() return use("data.mapdata").dota.fountain end

    local function moveTo(u, x, y)
        IssuePointOrder(u, "move", x, y)
    end

    -- Rough attack damage: base + average dice + the hero's best attribute.
    local function damageOf(u)
        local dmg = BlzGetUnitBaseDamage(u, 0) + BlzGetUnitDiceNumber(u, 0) * (BlzGetUnitDiceSides(u, 0) + 1) / 2
        if IsUnitType(u, UNIT_TYPE_HERO) then
            dmg = dmg + math.max(GetHeroStr(u, true), GetHeroAgi(u, true), GetHeroInt(u, true))
        end
        return dmg + Mods.sum(u, "damage")
    end

    local function alliedHeroesNear(u, radius)
        return U.enum(GetUnitX(u), GetUnitY(u), radius, function(t)
            return t ~= u and IsUnitType(t, UNIT_TYPE_HERO) and IsUnitAlly(t, GetOwningPlayer(u))
        end)
    end

    local function enemyTowerThreat(u)
        local towers = U.enum(GetUnitX(u), GetUnitY(u), 900, function(t)
            return IsUnitType(t, UNIT_TYPE_STRUCTURE) and IsUnitEnemy(t, GetOwningPlayer(u))
                and BlzGetUnitWeaponBooleanField(t, UNIT_WEAPON_BF_ATTACKS_ENABLED, 0)
        end)
        for _, t in ipairs(towers) do
            local tank = U.enum(GetUnitX(t), GetUnitY(t), 550, function(c)
                return not IsUnitType(c, UNIT_TYPE_HERO) and not IsUnitType(c, UNIT_TYPE_STRUCTURE)
                    and IsUnitAlly(c, GetOwningPlayer(u))
            end)
            if #tank == 0 then return t end
        end
        return nil
    end

    -- Where the bot should stand: just behind its lane's creep front, or by
    -- its own outermost living tower between waves.
    local function laneSpot(s)
        local front = use("creeps").front(s.lane, SLOT_ANCIENTS)
        local f = fountain()
        if front then
            local a = U.angle(GetUnitX(front), GetUnitY(front), f.x, f.y)
            return U.polar(GetUnitX(front), GetUnitY(front), 250, a)
        end
        for _, t in ipairs(use("structures").towers[s.lane] or {}) do
            if U.alive(t) then return GetUnitX(t), GetUnitY(t) end
        end
        return f.x, f.y
    end

    local function retreat(s)
        local f = fountain()
        s.retreating = true
        moveTo(s.unit, f.x + 200, f.y + 200)
    end

    local function think(s)
        local u = s.unit
        if not U.alive(u) then return end
        learn(s)
        -- shop while at the fountain (one purchase per think), take the
        -- stash and keep the best items out of the backpack, use items
        local f0 = fountain()
        if U.dist(GetUnitX(u), GetUnitY(u), f0.x, f0.y) < 900 and defined("item_builds") then
            use("item_builds").shop(u, s.hero)
            if defined("inventory") then
                local Inv = use("inventory")
                Inv.grabAll(GetOwningPlayer(u))
                Inv.arrange(GetOwningPlayer(u))
            end
        end
        if defined("items") and use("items").autoUse then use("items").autoUse(u) end
        if s.castUntil and Timer.now() < s.castUntil then return end
        local hp = hpFrac(u)
        if s.retreating then
            if hp > 0.9 then s.retreating = false else return retreat(s) end
        end
        local foes = enemiesNear(u, 1000, true)
        if hp < 0.35 or (#foes > #alliedHeroesNear(u, 1000) + 1 and hp < 0.6) then
            return retreat(s)
        end
        if cast(s) then return end

        -- Never tank an enemy tower without creeps in front.
        local tower = enemyTowerThreat(u)
        if tower then
            local a = U.angle(GetUnitX(tower), GetUnitY(tower), GetUnitX(u), GetUnitY(u))
            local x, y = U.polar(GetUnitX(u), GetUnitY(u), 450, a)
            return moveTo(u, x, y)
        end

        local dmg = damageOf(u)
        local reach = BlzGetUnitWeaponRealField(u, UNIT_WEAPON_RF_ATTACK_RANGE, 0) + 250
        -- 1. finish or pressure a weak enemy hero
        local hero = lowest(foes)
        if hero and U.unitDist(u, hero) < reach + 200 and (hpFrac(hero) < 0.4 or hpFrac(hero) < hp - 0.2) then
            return IssueTargetOrder(u, "attack", hero)
        end
        -- 2. last hit: an enemy creep this hit would kill
        local creeps = U.enum(GetUnitX(u), GetUnitY(u), reach, function(t)
            return IsUnitEnemy(t, GetOwningPlayer(u)) and not IsUnitType(t, UNIT_TYPE_HERO)
                and not IsUnitType(t, UNIT_TYPE_STRUCTURE) and IsUnitVisible(t, GetOwningPlayer(u))
        end)
        for _, c in ipairs(creeps) do
            if GetWidgetLife(c) <= dmg * 1.1 then
                return IssueTargetOrder(u, "attack", c)
            end
        end
        -- 2b. deny: an allied lane creep that may be denied and this hit would kill
        local Lane, C = use("lane"), use("creeps")
        for _, c in ipairs(C.near(SLOT_ANCIENTS, GetUnitX(u), GetUnitY(u), reach)) do
            if GetWidgetLife(c) <= dmg * 1.1 and not Lane.denyError(c) then
                return IssueTargetOrder(u, "attack", c)
            end
        end
        -- 3. stand behind the wave; hit anything that comes close
        local x, y = laneSpot(s)
        if U.dist(GetUnitX(u), GetUnitY(u), x, y) > 300 then
            return IssuePointOrder(u, "attack", x, y)
        end
        if #creeps > 0 and GetUnitCurrentOrder(u) == 0 then
            local weakest = lowest(creeps)
            if weakest and GetWidgetLife(weakest) <= dmg * 2.5 then
                IssueTargetOrder(u, "attack", weakest)
            end
        end
    end

    -- Lane from Valve's bot role data: solo heroes mid, carries and supports
    -- the safe lane (bottom for this side), the rest the long top lane.
    local taken = {mid = 0, bot = 0, top = 0}
    local function pickLane(heroKey)
        local bot = use("data.heroes")[heroKey].bot or {}
        local role = bot.heroType or ""
        local solo = tonumber((bot.laning or {}).SoloDesire or "0") or 0
        local wish
        if solo >= 2 and taken.mid == 0 then
            wish = "mid"
        elseif string.find(role, "CARRY") or string.find(role, "SUPPORT") then
            wish = "bot"
        else
            wish = "top"
        end
        local cap = {mid = 1, bot = 2, top = 2}
        if taken[wish] >= cap[wish] then
            for _, l in ipairs({"top", "bot", "mid"}) do
                if taken[l] < cap[l] then wish = l break end
            end
        end
        taken[wish] = taken[wish] + 1
        return wish
    end

    function Bot.add(unit, heroKey)
        local lane = pickLane(heroKey)
        local basics, ults, granted = skillsOf(heroKey)
        local build = (use("data.heroes")[heroKey].bot or {}).build or {}
        bots[unit] = {unit = unit, hero = heroKey, lane = lane, path = lanePath(lane), index = 1,
                      basics = basics, ults = ults, granted = granted, build = build, toggled = {}}
        Log.info("bot " .. heroKey .. " takes " .. lane)
    end

    function Bot.init()
        local Events = use("events")
        Events.on("hero_respawned", function(u)
            local s = bots[u]
            if s then
                s.index, s.retreating = 1, false
            end
        end)
        Timer.every(0.5, function()
            for _, s in pairs(bots) do
                use("safe").call(think, s)
            end
        end)
    end

    function Bot.count()
        local n = 0
        for _ in pairs(bots) do n = n + 1 end
        return n
    end

    return Bot
end)
