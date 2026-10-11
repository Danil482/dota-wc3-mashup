-- Gold and experience the Dota way: passive gold for hero players, last-hit
-- bounties (the gold popup for the killer only), shared XP for heroes near a
-- death, denies, hero kill gold and buyback. Native WC3 XP is switched off in
-- gameplay constants, so the Warcraft player's own heroes get XP here as well.
define("economy", function()
    local Events = use("events")
    local Timer = use("timer")
    local Roles = use("roles")
    local U = use("util")
    local E = {}

    local CREEP_GOLD = {dota_melee = 36, dota_ranged = 45, dota_siege = 73}
    local CREEP_XP = {dota_melee = 57, dota_ranged = 69, dota_siege = 88}
    local XP_RANGE = 1500

    -- Hero kills (https://liquipedia.net/dota2/Gold, the newest explicit
    -- formula, patch 7.31): 125 + 8 x the victim's level to the killer. Not
    -- here yet: the kill-streak bounty and the area assist gold, which Dota
    -- splits by relative net worth.
    E.HERO_GOLD = {base = 125, perLevel = 8}
    -- Denies (https://liquipedia.net/dota2/Deny): the denier gets nothing;
    -- enemy heroes near a denied non-hero unit share half its XP. One page
    -- gives a 1500 radius, another 1200; 1500 is also the shared XP radius.
    E.DENY_XP = 0.5
    E.DENY_RANGE = 1500
    -- Buyback (https://teamsmurf.com/buyback-math-when-2-500-gold-saves-the-game/,
    -- 2026-08-21, patch 7.41): 200 + net worth / 13 gold, 480 s cooldown from
    -- the purchase. Dota's own files: modifier_buyback_gold_penalty, "all
    -- gold earnings reduced by 60%" (here until the skipped respawn would
    -- have ended), and DOTA_Glossary_Death_Buyback: the first death after a
    -- buyback respawns later (by 25 s on the teamsmurf page).
    E.BUYBACK = {base = 200, divisor = 13, cooldown = 480, goldPenalty = 0.6, respawnPenalty = 25}
    E.BOT_BUYBACK = {minWait = 20, alarm = 5}  -- bots: skip at least this long a respawn, base hit this recently

    local creepKey = {}
    local frac = {}            -- slot -> earned gold fractions not paid yet
    local penaltyEnds = {}     -- slot -> game time the buyback gold penalty ends
    local buybackAt = {}       -- slot -> game time buyback is ready again

    local function lookup()
        for key, code in pairs(use("data.ids").units) do
            local side, kind = key:match("^(%a+)_(%a+)$")
            if side and side ~= "rax" and CREEP_GOLD["dota_" .. kind] then
                creepKey[FourCC(code)] = "dota_" .. kind
            end
        end
    end

    local function gold(p) return GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD) end

    local function addGold(p, amount)
        SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, gold(p) + math.floor(amount))
    end

    function E.goldFactor(p)
        local ends = penaltyEnds[GetPlayerId(p)]
        if ends and Timer.now() < ends then return 1 - E.BUYBACK.goldPenalty end
        return 1
    end

    -- Gold a hero player earns (bounties, passive gold), less while the
    -- buyback penalty lasts; fractions carry over. Returns the gold paid.
    function E.earn(p, amount)
        local slot = GetPlayerId(p)
        local total = (frac[slot] or 0) + amount * E.goldFactor(p)
        local whole = math.floor(total)
        frac[slot] = total - whole
        if whole ~= 0 then addGold(p, whole) end
        return whole
    end

    -- The last-hit gold popup: every client creates it, only the killer's
    -- player sees it (Dota shows it to the killer alone).
    local function bountyText(u, amount, p)
        local t = CreateTextTag()
        SetTextTagText(t, "+" .. amount, 0.023)
        SetTextTagPos(t, GetUnitX(u), GetUnitY(u), 60)
        SetTextTagColor(t, 255, 220, 0, 255)
        SetTextTagVelocity(t, 0, 0.03)
        SetTextTagPermanent(t, false)
        SetTextTagLifespan(t, 2)
        SetTextTagFadepoint(t, 1)
        SetTextTagVisibility(t, GetLocalPlayer() == p)
    end

    local function valueOf(dying)
        local wg, wx = use("world").bountyOf(dying)
        if wg then return wg, wx end
        local key = creepKey[GetUnitTypeId(dying)]
        if key then return CREEP_GOLD[key], CREEP_XP[key] end
        if IsUnitType(dying, UNIT_TYPE_HERO) then
            local lvl = GetHeroLevel(dying)
            return E.HERO_GOLD.base + E.HERO_GOLD.perLevel * lvl, 100 + 25 * lvl
        end
        if IsUnitType(dying, UNIT_TYPE_STRUCTURE) then
            return 150, 0
        end
        local lvl = GetUnitLevel(dying)
        return 10 + 8 * lvl, 20 + 15 * lvl
    end
    E.valueOf = valueOf

    local function shareXp(dying, xp, side, range)
        local x, y = GetUnitX(dying), GetUnitY(dying)
        local heroes = U.enum(x, y, range, function(u)
            return IsUnitType(u, UNIT_TYPE_HERO) and Roles.side(GetPlayerId(GetOwningPlayer(u))) == side
        end)
        if #heroes == 0 then return end
        for _, h in ipairs(heroes) do
            AddHeroXP(h, math.floor(xp / #heroes), true)
        end
    end

    local function opposite(side) return side == "dota" and "warcraft" or "dota" end

    local function onDeath(dying, killer)
        if not killer or killer == dying then return end
        local deadSide = Roles.side(GetPlayerId(GetOwningPlayer(dying)))
        local killerSlot = GetPlayerId(GetOwningPlayer(killer))
        local killerSide = Roles.side(killerSlot)
        if killerSide == "none" then return end
        local bounty, xp = valueOf(dying)
        if killerSide == deadSide then
            if xp > 0 and not IsUnitType(dying, UNIT_TYPE_HERO) then
                shareXp(dying, xp * E.DENY_XP, opposite(deadSide), E.DENY_RANGE)
            end
            return
        end
        if killerSide == "dota" then
            -- last hits by hero players (towers and creeps earn nothing)
            if Roles.isHeroSlot(killerSlot) and bounty > 0 then
                local p = Player(killerSlot)
                local paid = E.earn(p, bounty)
                if paid > 0 then bountyText(dying, paid, p) end
            end
        elseif killerSide == "warcraft" then
            -- The Warcraft player earns half the bounty of his side's kills
            addGold(Player(Roles.warcraft), bounty * 0.5)
        end
        if xp > 0 then shareXp(dying, xp, killerSide, XP_RANGE) end
    end

    -- ------------------------------------------------------------ buyback

    -- Gold plus the cost of the player's Dota items: the hero's inventory,
    -- and the backpack, stash, TP slot and courier once inventory.lua runs.
    function E.netWorth(p)
        local Items = use("items")
        local total = gold(p)
        local Inv = defined("inventory") and use("inventory") or nil
        if Inv and Inv.started and Inv.entries then
            for _, e in ipairs(Inv.entries(p, {"main", "bag", "stash", "tp", "cour"})) do
                total = total + Items.data(e.name).cost
            end
            return total
        end
        local hero = use("heroes").bySlot[GetPlayerId(p)]
        if hero then
            for _, c in ipairs(Items.carried(hero)) do total = total + Items.data(c.name).cost end
        end
        return total
    end

    function E.buybackCost(p)
        return E.BUYBACK.base + math.floor(E.netWorth(p) / E.BUYBACK.divisor)
    end

    function E.buybackLeft(p)
        return math.max(0, (buybackAt[GetPlayerId(p)] or 0) - Timer.now())
    end

    -- The player's hero while it is dead and waits for its fountain respawn
    -- (not while the Aegis revives it), else nil.
    function E.deadHero(p)
        local H = use("heroes")
        local hero = H.bySlot[GetPlayerId(p)]
        if hero and H.respawnAt[hero] and not U.alive(hero) then return hero end
        return nil
    end

    -- Buys the player's dead hero back: pays, starts the cooldown and the
    -- penalties, plays the buyback music and revives it at the fountain.
    -- Refusals show Dota's error line. Synced code only.
    function E.buyback(p)
        local slot = GetPlayerId(p)
        local hero = E.deadHero(p)
        if not hero or not Roles.isHeroSlot(slot) then return false end
        local Lane = use("lane")
        if E.buybackLeft(p) > 0 then
            Lane.error(p, "DOTA_Hud_BuybackOnCooldown")
            return false
        end
        local cost = E.buybackCost(p)
        if gold(p) < cost then
            Lane.error(p, "dota_hud_error_not_enough_gold")
            return false
        end
        local H = use("heroes")
        addGold(p, -cost)
        buybackAt[slot] = Timer.now() + E.BUYBACK.cooldown
        penaltyEnds[slot] = H.respawnAt[hero]
        H.respawnPenalty[hero] = E.BUYBACK.respawnPenalty
        if defined("music") then use("safe").call(function() use("music").buyback(hero) end) end
        H.revive(hero)
        Lane.chat("DOTA_Chat_BuyBack", GetPlayerName(p))
        use("log").info(string.format("slot %d bought back for %d gold", slot, cost))
        Events.emit("buyback", hero, p, cost)
        return true
    end

    -- Bots buy back when their base is under attack, they can pay and the
    -- respawn they skip is long enough to matter.
    local function botBuybacks()
        local H = use("heroes")
        for _, slot in ipairs(Roles.heroSlots) do
            local p = Player(slot)
            local hero = Roles.isBot(slot) and E.deadHero(p)
            if hero and H.respawnAt[hero] - Timer.now() >= E.BOT_BUYBACK.minWait and E.buybackLeft(p) == 0
                and gold(p) >= E.buybackCost(p) and use("structures").baseUnderAttack(E.BOT_BUYBACK.alarm) then
                E.buyback(p)
            end
        end
    end

    function E.init()
        lookup()
        Timer.every(0.6, function()
            for _, slot in ipairs(Roles.heroSlots) do
                E.earn(Player(slot), 1)
            end
        end)
        Events.on("death", onDeath)
        Timer.every(1, botBuybacks)
    end

    return E
end)
