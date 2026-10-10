-- Runes as WC3 power-up items (tools/gen_objects.py world(), "ipow"): a hero
-- takes one by walking over it (checked here every 0.1 s) or by clicking it.
-- River spots (mapdata "runes"): bounty runes at 0:00, water runes at 2:00
-- and 4:00, then one power rune of a random type at a random spot every two
-- minutes from 6:00. Bounty runes at 0:00 and every 3 minutes at the jungle
-- bounty spots: mapdata "bounty_runes" if present, otherwise two per jungle,
-- each the midpoint of two neighbouring camps on a jungle path (layout.py
-- JUNGLE_PATHS), so it is open ground near the camps:
--   Dota jungle  d_medium2+d_ancient, d_medium1+d_large
--   Commander    c_medium2+c_ancient, c_medium1+c_large
--   outer        o_top1+o_top2, o_bot1+o_bot2 (one per side jungle)
-- A new spawn removes the unclaimed rune it replaces. Rune numbers are the
-- patch's own tooltips (Amplify Damage +80% base damage and +15% spell amp,
-- Arcane -25% cooldowns and -30% mana costs, ...).
-- SIMPLIFIED: no Bottle in use("data.items"), so runes cannot be bottled;
-- Arcane refunds 30% of the mana after the cast instead of lowering the cost.
define("world_runes", function()
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Mods = use("mods")
    local Damage = use("damage")
    local U = use("util")
    local R = {spots = {river = {}, bounty = {}}, ground = {}}

    R.PICK_RADIUS = 125
    R.POWER = {"doubledamage", "haste", "illusion", "invisibility", "regeneration", "arcane", "shield"}
    R.TITLE = {doubledamage = "Amplify Damage", haste = "Haste", illusion = "Illusion", invisibility = "Invisibility",
               regeneration = "Regeneration", arcane = "Arcane", shield = "Shield", water = "Water", bounty = "Bounty"}
    R.COLOR = {doubledamage = "|cff82caff", haste = "|cfff62817", illusion = "|cffffd700", invisibility = "|cffa028c8",
               regeneration = "|cff7fff00", arcane = "|cfffd3afb", shield = "|cffc8c8c8", water = "|cff74a7f7",
               bounty = "|cffff7800"}
    R.BOUNTY_GOLD, R.BOUNTY_PER_MINUTE = 40, 1.2      -- each hero of the team
    R.WATER_HP, R.WATER_MANA = 40, 80
    R.DD = {duration = 45, damage = 0.8, spell_amp = 0.15}
    R.HASTE = {duration = 22}
    R.ILLUSION = {count = 2}                           -- 75 s, 35% damage: gen_objects "illusion"
    R.INVIS = {fade = 2, duration = 45}
    R.REGEN = {duration = 30, pct = 0.06, hurt_pct = 0.01, hurt_time = 3}
    R.ARCANE = {duration = 50, cooldown = 0.25, mana = 0.30}
    R.SHIELD = {duration = 75, pct = 0.5}
    local BOUNTY_PAIRS = {
        {"d_medium2", "d_ancient"}, {"d_medium1", "d_large"},
        {"c_medium2", "c_ancient"}, {"c_medium1", "c_large"},
        {"o_top1", "o_top2"}, {"o_bot1", "o_bot2"},
    }
    local FX = {              -- buff visuals
        doubledamage = "Abilities\\Spells\\Human\\InnerFire\\InnerFireTarget.mdl",
        haste = "Abilities\\Spells\\Orc\\Bloodlust\\BloodlustTarget.mdl",
        regeneration = "Abilities\\Spells\\NightElf\\Rejuvenation\\RejuvenationTarget.mdl",
        arcane = "Abilities\\Spells\\Other\\Charm\\CharmTarget.mdl",
        shield = "Abilities\\Spells\\Undead\\AntiMagicShell\\AntiMagicShell.mdl",
    }
    local FLASH = {           -- one-shot visuals on pickup
        invisibility = "Abilities\\Spells\\Human\\Invisibility\\InvisibilityTarget.mdl",
        water = "Abilities\\Spells\\Items\\AIre\\AIreTarget.mdl",
        bounty = "Abilities\\Spells\\Other\\Transmute\\PileofGold.mdl",
        illusion = "Abilities\\Spells\\Orc\\MirrorImage\\MirrorImageCaster.mdl",
    }
    local ILLUSION_ORDER = 852274     -- Wand of Illusion

    local W
    local kindOf = {}         -- item type id -> rune kind
    local shield = {}         -- unit -> barrier left
    local hurt = {}           -- unit -> time its Regeneration rune is slowed until
    local taken = {}          -- item -> true once activated (pickup and use events both fire)

    -- ------------------------------------------------------------ spots

    function R.bountySpots()
        local m = use("data.mapdata")
        local out = {}
        if m.bounty_runes then
            for _, p in ipairs(m.bounty_runes) do out[#out + 1] = {x = p.x, y = p.y} end
            return out
        end
        local camps = m.camps or {}
        for _, pair in ipairs(BOUNTY_PAIRS) do
            local a, b = camps[pair[1]], camps[pair[2]]
            if a and b then out[#out + 1] = {x = (a.x + b.x) / 2, y = (a.y + b.y) / 2} end
        end
        return out
    end

    local function clear(spot)
        local it = spot.item
        spot.item = nil
        if it then
            R.ground[it] = nil
            if GetItemTypeId(it) ~= 0 then RemoveItem(it) end
        end
    end

    -- Puts a rune of `kind` on a spot, replacing what lies there.
    function R.place(spot, kind)
        clear(spot)
        local code = W.code("items", "rune_" .. kind)
        if not code then return nil end
        local it = CreateItem(code, spot.x, spot.y)
        spot.item = it
        R.ground[it] = {kind = kind, spot = spot}
        return it
    end

    function R.bounty(at)
        for _, spot in ipairs(R.spots.bounty) do R.place(spot, "bounty") end
        if at == 0 then
            for _, spot in ipairs(R.spots.river) do R.place(spot, "bounty") end
        end
    end

    function R.water()
        for _, spot in ipairs(R.spots.river) do R.place(spot, "water") end
    end

    function R.power()
        for _, spot in ipairs(R.spots.river) do clear(spot) end
        if #R.spots.river == 0 then return end
        local spot = R.spots.river[GetRandomInt(1, #R.spots.river)]
        local kind = R.POWER[GetRandomInt(1, #R.POWER)]
        R.place(spot, kind)
        Log.info("world: " .. kind .. " rune")
    end

    -- ------------------------------------------------------------ effects

    local function breakInvis(u)
        Mods.remove(u, "rune_invis_fade")
        Mods.remove(u, "rune_invisibility")
    end

    local function illusions(u)
        local abil, dummy = W.code("abilities", "illusion"), W.code("units", "dummy")
        if not abil or not dummy then return end
        local ranged = not IsUnitType(u, UNIT_TYPE_MELEE_ATTACKER)
        for _ = 1, R.ILLUSION.count do
            local d = CreateUnit(GetOwningPlayer(u), dummy, GetUnitX(u), GetUnitY(u), 0)
            UnitAddAbility(d, abil)
            SetUnitAbilityLevel(d, abil, ranged and 2 or 1)
            IssueTargetOrderById(d, ILLUSION_ORDER, u)
            Timer.after(1.0, function() RemoveUnit(d) end)
        end
    end

    local function regenTick(m)
        local u = m.unit
        local rate = (hurt[u] or 0) > Timer.now() and R.REGEN.hurt_pct or R.REGEN.pct
        local maxHp, maxMana = BlzGetUnitMaxHP(u), BlzGetUnitMaxMana(u)
        SetWidgetLife(u, math.min(maxHp, GetWidgetLife(u) + maxHp * rate * m.tick))
        SetUnitState(u, UNIT_STATE_MANA, math.min(maxMana, GetUnitState(u, UNIT_STATE_MANA) + maxMana * rate * m.tick))
        if GetWidgetLife(u) >= maxHp and GetUnitState(u, UNIT_STATE_MANA) >= maxMana then
            Mods.remove(u, "rune_regeneration")
        end
    end

    local apply = {
        bounty = function(u)
            local gold = math.floor(R.BOUNTY_GOLD + R.BOUNTY_PER_MINUTE * W.minutes())
            for _, p in ipairs(W.teamPlayers(GetOwningPlayer(u))) do W.addGold(p, gold) end
            W.text(u, "+" .. gold)
        end,
        water = function(u)
            Damage.heal(u, R.WATER_HP)
            SetUnitState(u, UNIT_STATE_MANA, GetUnitState(u, UNIT_STATE_MANA) + R.WATER_MANA)
        end,
        doubledamage = function(u)
            Mods.add(u, "rune_doubledamage", {duration = R.DD.duration, effect = FX.doubledamage, attach = "overhead",
                props = {damage = math.floor(W.baseDamage(u) * R.DD.damage + 0.5), spell_amp = R.DD.spell_amp}})
        end,
        haste = function(u)
            -- the stats module caps speed at the 550 maximum, slows included
            Mods.add(u, "rune_haste", {duration = R.HASTE.duration, effect = FX.haste, attach = "chest",
                                       props = {move_flat = 1000}})
        end,
        illusion = illusions,
        invisibility = function(u)
            Mods.add(u, "rune_invis_fade", {duration = R.INVIS.fade, onRemove = function(m, expired)
                if expired and U.alive(u) then
                    Mods.add(u, "rune_invisibility", {duration = R.INVIS.duration, props = {invisible = true}})
                end
            end})
        end,
        regeneration = function(u)
            Mods.add(u, "rune_regeneration", {duration = R.REGEN.duration, tick = 0.25, onTick = regenTick,
                                              effect = FX.regeneration, attach = "chest"})
        end,
        arcane = function(u)
            Mods.add(u, "rune_arcane", {duration = R.ARCANE.duration, effect = FX.arcane, attach = "overhead"})
        end,
        shield = function(u)
            Mods.add(u, "rune_shield", {duration = R.SHIELD.duration, effect = FX.shield, attach = "chest",
                                        onRemove = function() shield[u] = nil end})
            shield[u] = BlzGetUnitMaxHP(u) * R.SHIELD.pct
        end,
    }

    function R.canTake(u)
        return U.alive(u) and IsUnitType(u, UNIT_TYPE_HERO) and not IsUnitIllusion(u) and UnitInventorySize(u) > 0
    end

    -- A rune taken by u (walked over, clicked or reported by the item events).
    function R.activate(u, it)
        local r = it and R.ground[it]
        if not r or taken[it] then return false end
        taken[it] = true
        R.ground[it] = nil
        if r.spot.item == it then r.spot.item = nil end
        if GetItemTypeId(it) ~= 0 then RemoveItem(it) end
        if not R.canTake(u) then
            R.place(r.spot, r.kind)       -- illusions and the like cannot use runes
            return false
        end
        if FLASH[r.kind] then DestroyEffect(AddSpecialEffectTarget(FLASH[r.kind], u, "origin")) end
        apply[r.kind](u)
        if r.kind ~= "bounty" and r.kind ~= "water" then
            W.announce(W.playerName(u) .. " activated " .. R.COLOR[r.kind] .. R.TITLE[r.kind] .. "|r rune.")
        end
        Events.emit("rune_activated", u, r.kind)
        return true
    end

    -- Walking over a rune takes it. Spots are scanned in a fixed order so
    -- every client creates rune effects (illusions) in the same sequence.
    function R.scan()
        for _, list in ipairs({R.spots.river, R.spots.bounty}) do
            for _, spot in ipairs(list) do
                local it = spot.item
                if it and GetItemTypeId(it) == 0 then
                    spot.item, R.ground[it] = nil, nil
                elseif it then
                    local x, y = GetItemX(it), GetItemY(it)
                    local best = U.nearest(U.enum(x, y, R.PICK_RADIUS, R.canTake), x, y)
                    if best then R.activate(best, it) end
                end
            end
        end
    end

    -- Arcane: after any cast the cooldown left drops by 25% and 30% of the
    -- mana cost comes back.
    local function arcane(caster, abil)
        if not Mods.has(caster, "rune_arcane") then return end
        local lvl = GetUnitAbilityLevel(caster, abil)
        if lvl <= 0 then return end
        local refund = BlzGetUnitAbilityManaCost(caster, abil, lvl - 1) * R.ARCANE.mana
        Timer.after(0, function()
            if not U.alive(caster) then return end
            local left = BlzGetUnitAbilityCooldownRemaining(caster, abil)
            if left > 0 then BlzStartUnitAbilityCooldown(caster, abil, left * (1 - R.ARCANE.cooldown)) end
            if refund > 0 then
                SetUnitState(caster, UNIT_STATE_MANA, GetUnitState(caster, UNIT_STATE_MANA) + refund)
            end
        end)
    end

    -- Shield: the barrier soaks damage after armor (the damaged event).
    local function soak(source, target)
        local left = shield[target]
        if not left then return end
        local amount = GetEventDamage()
        if amount <= 0 then return end
        local absorbed = math.min(left, amount)
        BlzSetEventDamage(amount - absorbed)
        if left - absorbed <= 0 then
            Mods.remove(target, "rune_shield")
        else
            shield[target] = left - absorbed
        end
    end

    function R.shieldOf(u) return shield[u] end

    function R.init(world)
        W = world
        for _, kind in ipairs(R.POWER) do
            local code = W.code("items", "rune_" .. kind)
            if code then kindOf[code] = kind end
        end
        for _, kind in ipairs({"water", "bounty"}) do
            local code = W.code("items", "rune_" .. kind)
            if code then kindOf[code] = kind end
        end
        for _, p in ipairs(use("data.mapdata").runes or {}) do
            R.spots.river[#R.spots.river + 1] = {x = p.x, y = p.y}
        end
        R.spots.bounty = R.bountySpots()
        W.at(0, 180, R.bounty)
        W.at(120, nil, R.water)
        W.at(240, nil, R.water)
        W.at(360, 120, R.power)
        Timer.every(0.1, R.scan)
        local function picked(u, it)
            if it and kindOf[GetItemTypeId(it)] then R.activate(u, it) end
        end
        Events.on("item_pickup", picked)
        Events.on("item_use", picked)
        Events.on("attacked", function(attacker) if attacker then breakInvis(attacker) end end)
        Events.on("spell_effect", function(caster, abil)
            breakInvis(caster)
            arcane(caster, abil)
        end)
        Events.on("damaged", soak)
        Damage.onDamaged(function(source, target, amount)
            if amount > 0 and source and Mods.has(target, "rune_regeneration") and IsUnitType(source, UNIT_TYPE_HERO)
                and IsUnitEnemy(source, GetOwningPlayer(target)) then
                hurt[target] = Timer.now() + R.REGEN.hurt_time
            end
        end)
        Timer.every(30, function()
            for it in pairs(taken) do
                if GetItemTypeId(it) == 0 then taken[it] = nil end
            end
            for u, t in pairs(hurt) do
                if t < Timer.now() then hurt[u] = nil end
            end
        end)
        Log.info("world: runes at " .. #R.spots.river .. " river and " .. #R.spots.bounty .. " bounty spots")
    end

    return R
end)
