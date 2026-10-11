-- Item actives: Lua effects of the Channel abilities on Dota items (targeting
-- in ITEM_ACTIVES, tools/gen_objects.py). Handlers get a context {caster,
-- owner, name, target, x, y, item}; onChannel runs before the cast and may
-- return false to cancel it (no cooldown or mana spent), onCast at the
-- effect, onEndCast when a channel ends. As in Dota, silence does not stop
-- items; hex does. Also offers a simple item-use routine for bots.
define("item_actives", function()
    local Events = use("events")
    local Timer = use("timer")
    local Mods = use("mods")
    local Damage = use("damage")
    local U = use("util")
    local A = {handlers = {}}
    local H = A.handlers

    local REGEN_FX = "Abilities\\Spells\\NightElf\\Rejuvenation\\RejuvenationTarget.mdl"
    local MANA_FX = "Abilities\\Spells\\Items\\AIma\\AImaTarget.mdl"
    local HEAL_FX = "Abilities\\Spells\\Items\\AIhe\\AIheTarget.mdl"
    local WAND_FX = "Abilities\\Spells\\Items\\AIre\\AIreTarget.mdl"
    local TP_FROM = "Abilities\\Spells\\Human\\MassTeleport\\MassTeleportCaster.mdl"
    local TP_TO = "Abilities\\Spells\\Human\\MassTeleport\\MassTeleportTarget.mdl"
    local BLINK_FROM = "Abilities\\Spells\\NightElf\\Blink\\BlinkCaster.mdl"
    local BLINK_TO = "Abilities\\Spells\\NightElf\\Blink\\BlinkTarget.mdl"
    local BKB_FX = "Abilities\\Spells\\Undead\\AntiMagicShell\\AntiMagicShell.mdl"
    local CYCLONE_FX = "Abilities\\Spells\\NightElf\\Cyclone\\CycloneTarget.mdl"
    local DAGON_FX = "Abilities\\Spells\\Human\\ManaFlare\\ManaFlareBoltImpact.mdl"
    local MIDAS_FX = "Abilities\\Spells\\Other\\Transmute\\PileofGold.mdl"
    local REFRESH_FX = "Abilities\\Spells\\Items\\TomeOfRetraining\\TomeOfRetrainingCaster.mdl"
    local HEX_FX = "Abilities\\Spells\\Human\\Polymorph\\PolyMorphTarget.mdl"
    local FROST_FX = "Abilities\\Spells\\Undead\\FrostArmor\\FrostArmorDamage.mdl"
    local SHIVA_FX = "Abilities\\Spells\\Undead\\FrostNova\\FrostNovaTarget.mdl"
    local SATANIC_FX = "Abilities\\Spells\\Undead\\VampiricAura\\VampiricAuraTarget.mdl"
    local MANTA_FX = "Abilities\\Spells\\Orc\\MirrorImage\\MirrorImageCaster.mdl"
    local PHASE_FX = "Abilities\\Spells\\Human\\Invisibility\\InvisibilityTarget.mdl"
    local DUST_FX = "Abilities\\Spells\\Human\\Flare\\FlareCaster.mdl"
    local FORCE_FX = "Abilities\\Spells\\NightElf\\Blink\\BlinkCaster.mdl"
    local MEK_FX = "Abilities\\Spells\\Human\\Heal\\HealTarget.mdl"
    local ILLUSION_ORDER = 852274     -- Wand of Illusion

    local function I() return use("items") end
    local function v(c, key, level) return I().val(c.name, key, level) end

    local function fx(path, x, y) DestroyEffect(AddSpecialEffect(path, x, y)) end
    local function fxOn(path, u, attach) DestroyEffect(AddSpecialEffectTarget(path, u, attach or "origin")) end

    local function addMana(u, n)
        SetUnitState(u, UNIT_STATE_MANA, GetUnitState(u, UNIT_STATE_MANA) + n)
    end

    -- Stops the cast before it costs cooldown or mana.
    local function cancel(c, text)
        PauseUnit(c.caster, true)
        IssueImmediateOrder(c.caster, "stop")
        PauseUnit(c.caster, false)
        if text then I().msg(c.owner, "|cffffcc00" .. text .. "|r") end
        return false
    end

    -- The carried copy of the used item with the most charges (Stick, Wand, Midas).
    local function charged(c)
        local best, n = nil, 0
        for _, e in ipairs(I().carried(c.caster)) do
            local k = e.name == c.name and I().charges(e.item) or 0
            if k > n then best, n = e.item, k end
        end
        return best
    end

    -- WC3 may count a use against the shown charges; show the Lua count again.
    local function resync(it)
        Timer.after(0, function()
            if GetItemTypeId(it) ~= 0 then I().setCharges(it, I().charges(it)) end
        end)
    end

    -- ------------------------------------------------------------ consumables

    H.item_tango = {onCast = function(c)
        local tree = GetSpellTargetDestructable()
        if tree then KillDestructable(tree) end
        Mods.add(c.caster, "item_tango", {duration = v(c, "buff_duration"), props = {hp_regen = v(c, "health_regen")},
                                          effect = REGEN_FX})
    end}

    H.item_flask = {onCast = function(c)
        local t = c.target or c.caster
        local regen = v(c, "health_regen") * (t == c.caster and 1 or 0.5)
        Mods.add(t, "item_flask", {duration = v(c, "buff_duration"), props = {hp_regen = regen}, effect = REGEN_FX})
    end}

    H.item_clarity = {onCast = function(c)
        local t = c.target or c.caster
        Mods.add(t, "item_clarity", {duration = v(c, "buff_duration"), props = {mana_regen = v(c, "mana_regen")},
                                     effect = MANA_FX})
    end}

    H.item_faerie_fire = {onCast = function(c)
        Damage.heal(c.caster, v(c, "hp_restore"))
        fxOn(HEAL_FX, c.caster)
    end}

    H.item_enchanted_mango = {onCast = function(c)
        addMana(c.caster, v(c, "replenish_amount"))
        fxOn(MANA_FX, c.caster)
    end}

    -- Town Portal: to the friendly Dota building nearest the target point.
    local teleports = {}      -- unit -> teleport in progress

    local function nearestBuilding(x, y)
        local S = use("structures")
        local list = {}
        local function put(u)
            if U.alive(u) then list[#list + 1] = u end
        end
        put(S.fountain)
        put(S.ancient)
        for _, group in pairs(S.towers or {}) do
            for _, t in ipairs(group) do put(t) end
        end
        for _, group in pairs(S.barracks or {}) do
            for _, b in ipairs(group) do put(b) end
        end
        return (U.nearest(list, x, y))
    end

    H.item_tpscroll = {
        onChannel = function(c)
            if Mods.flag(c.caster, "root") then return cancel(c, "Rooted") end
            if not nearestBuilding(c.x, c.y) then return cancel(c, "No friendly building") end
            teleports[c.caster] = {charges = c.item and GetItemCharges(c.item) or 1}
        end,
        onCast = function(c)
            local b = nearestBuilding(c.x, c.y)
            if not b then return end
            local tp = teleports[c.caster] or {charges = c.item and GetItemCharges(c.item) or 1}
            teleports[c.caster] = tp
            local bx, by = GetUnitX(b), GetUnitY(b)
            local tx, ty = c.x, c.y
            if U.dist(tx, ty, bx, by) > v(c, "maximum_distance") then
                tx, ty = U.polar(bx, by, 250, U.angle(bx, by, tx, ty))
            end
            tp.x, tp.y, tp.start = tx, ty, Timer.now()
            tp.fromFx = AddSpecialEffectTarget(TP_FROM, c.caster, "origin")
            tp.toFx = AddSpecialEffect(TP_TO, tx, ty)
        end,
        onEndCast = function(c)
            local tp = teleports[c.caster]
            teleports[c.caster] = nil
            if not tp or not tp.start then return end
            if tp.fromFx then DestroyEffect(tp.fromFx) end
            if tp.toFx then DestroyEffect(tp.toFx) end
            if Timer.now() - tp.start >= v(c, "AbilityChannelTime") - 0.1 and U.alive(c.caster) then
                SetUnitPosition(c.caster, tp.x, tp.y)
                fx(BLINK_TO, tp.x, tp.y)
                if GetLocalPlayer() == c.owner then PanCameraToTimed(tp.x, tp.y, 0.3) end
            end
            -- the scroll is spent once the channel started, finished or not
            local it = c.item
            if it and GetItemTypeId(it) ~= 0 then
                if (tp.charges or 1) <= 1 then I().remove(c.caster, it) else SetItemCharges(it, tp.charges - 1) end
            end
        end,
    }

    local function plantWard(c, key)
        local w = CreateUnit(c.owner, FourCC(use("data.ids").units[key]), c.x, c.y, 270)
        UnitApplyTimedLife(w, FourCC("BTLF"), v(c, "lifetime"))
    end

    H.item_ward_observer = {onCast = function(c) plantWard(c, "wardobserver") end}
    H.item_ward_sentry = {onCast = function(c) plantWard(c, "wardsentry") end}

    -- Dust: a true-sight dummy where the caster stood, slowing invisible heroes.
    H.item_dust = {onCast = function(c)
        local ids = use("data.ids")
        local x, y = GetUnitX(c.caster), GetUnitY(c.caster)
        local radius, slow = v(c, "radius"), v(c, "movespeed") / 100
        local ends = Timer.now() + v(c, "duration")
        local d = CreateUnit(c.owner, FourCC(ids.units.itemdummy), x, y, 0)
        UnitAddAbility(d, FourCC(ids.abilities.items_truesight))
        fx(DUST_FX, x, y)
        Timer.every(0.5, function()
            if Timer.now() >= ends then
                RemoveUnit(d)
                return true
            end
            for _, e in ipairs(U.enemiesOf(c.owner, x, y, radius)) do
                if IsUnitType(e, UNIT_TYPE_HERO) and (Mods.flag(e, "invisible") or IsUnitInvisible(e, c.owner)) then
                    Mods.add(e, "item_dust", {duration = 1.0, props = {move_pct = slow}, debuff = true})
                end
            end
        end)
    end}

    -- ------------------------------------------------------------ basic and early items

    local function chop()
        local tree = GetSpellTargetDestructable()
        if tree then KillDestructable(tree) end
    end

    H.item_quelling_blade = {onCast = chop}
    H.item_bfury = {onCast = chop}

    local energy = {
        onChannel = function(c)
            if not charged(c) then return cancel(c, "No charges") end
        end,
        onCast = function(c)
            local it = charged(c)
            if not it then return end
            local amount = I().charges(it) * v(c, "restore_per_charge")
            Damage.heal(c.caster, amount)
            addMana(c.caster, amount)
            I().setCharges(it, 0)
            resync(it)
            fxOn(WAND_FX, c.caster)
        end,
    }
    H.item_magic_stick = energy
    H.item_magic_wand = energy

    local NEXT_ATTR = {str = "int", int = "agi", agi = "str"}

    H.item_power_treads = {onCast = function(c)
        if not c.item then return end
        I().setTreads(c.item, NEXT_ATTR[I().istate(c.item).attr or "str"])
        I().refresh(c.caster)
    end}

    local ghosted = {}        -- unit -> true while Phase Boots added unit walk-through

    H.item_phase_boots = {onCast = function(c)
        local u = c.caster
        local GHOST = FourCC("Aeth")
        local melee = IsUnitType(u, UNIT_TYPE_MELEE_ATTACKER)
        local pct = (melee and v(c, "phase_movement_speed") or v(c, "phase_movement_speed_range")) / 100
        if not ghosted[u] and GetUnitAbilityLevel(u, GHOST) == 0 then
            UnitAddAbility(u, GHOST)
            ghosted[u] = true
        end
        Mods.add(u, "item_phase_boots", {duration = v(c, "phase_duration"), props = {move_pct = pct}, effect = PHASE_FX,
                                         onRemove = function()
                                             if ghosted[u] then
                                                 UnitRemoveAbility(u, GHOST)
                                                 ghosted[u] = nil
                                             end
                                         end})
    end}

    H.item_arcane_boots = {onCast = function(c)
        local u = c.caster
        for _, a in ipairs(U.alliesOf(c.owner, GetUnitX(u), GetUnitY(u), v(c, "replenish_radius"))) do
            if not IsUnitType(a, UNIT_TYPE_STRUCTURE) and BlzGetUnitMaxMana(a) > 0 then
                addMana(a, v(c, "replenish_amount"))
                fxOn(MANA_FX, a)
            end
        end
    end}

    -- ------------------------------------------------------------ upgrades

    H.item_blink = {
        onChannel = function(c)
            if Mods.flag(c.caster, "root") then return cancel(c, "Rooted") end
            if use("item_passives").blinkLocked(c.caster) then return cancel(c, "Blink is locked after hero damage") end
        end,
        onCast = function(c)
            local u = c.caster
            local x, y = GetUnitX(u), GetUnitY(u)
            local tx, ty = c.x or x, c.y or y
            if U.dist(x, y, tx, ty) > v(c, "blink_range") then
                tx, ty = U.polar(x, y, v(c, "blink_range_clamp"), U.angle(x, y, tx, ty))
            end
            fx(BLINK_FROM, x, y)
            SetUnitPosition(u, tx, ty)
            fx(BLINK_TO, GetUnitX(u), GetUnitY(u))
        end,
    }

    -- BKB: each use of the same bar is one level shorter, down to max_level.
    H.item_black_king_bar = {onCast = function(c)
        local s = c.item and I().istate(c.item) or {}
        local level = s.bkb or 1
        s.bkb = math.min(level + 1, v(c, "max_level"))
        Mods.dispel(c.caster, {debuffs = true})
        Mods.add(c.caster, "item_black_king_bar", {duration = v(c, "duration", level), props = {magic_immune = true},
                                                   effect = BKB_FX, dispel = "none"})
    end}

    H.item_force_staff = {
        onChannel = function(c)
            local t = c.target
            if t and IsUnitEnemy(t, c.owner) and U.isMagicImmune(t) then return cancel(c, "Target is magic immune") end
        end,
        onCast = function(c)
            local t = c.target or c.caster
            if not U.alive(t) then return end
            local a = math.rad(GetUnitFacing(t))
            local distance = v(c, "push_length")
            local step = distance / math.max(0.05, v(c, "push_time")) * Timer.TICK
            local moved = 0
            fxOn(FORCE_FX, t)
            Timer.onFrame(function()
                if not U.alive(t) then return true end
                local nx, ny = U.polar(GetUnitX(t), GetUnitY(t), step, a)
                if moved >= distance or IsTerrainPathable(nx, ny, PATHING_TYPE_WALKABILITY) then
                    SetUnitPosition(t, GetUnitX(t), GetUnitY(t))
                    return true
                end
                SetUnitX(t, nx)
                SetUnitY(t, ny)
                moved = moved + step
            end)
        end,
    }

    H.item_cyclone = {onCast = function(c)
        local t = c.target or c.caster
        if not U.alive(t) then return end
        local enemy = IsUnitEnemy(t, c.owner)
        Mods.dispel(t, {buffs = enemy, debuffs = not enemy})
        local RAVEN = FourCC("Arav")
        if UnitAddAbility(t, RAVEN) then UnitRemoveAbility(t, RAVEN) end
        SetUnitFlyHeight(t, 350, 1200)
        Mods.add(t, "item_cyclone", {duration = v(c, "cyclone_duration"), props = {stun = true, invulnerable = true},
                                     effect = CYCLONE_FX, debuff = enemy, dispel = "none",
                                     onRemove = function()
                                         SetUnitFlyHeight(t, GetUnitDefaultFlyHeight(t), 2000)
                                         if enemy then Damage.deal(c.caster, t, v(c, "tooltip_drop_damage"), Damage.MAGICAL) end
                                     end})
    end}

    H.item_dagon = {onCast = function(c)
        local t = c.target
        if not U.alive(t) then return end
        local bolt = AddLightningEx("AFOD", true, GetUnitX(c.caster), GetUnitY(c.caster), 80, GetUnitX(t), GetUnitY(t), 60)
        Timer.after(0.3, function() DestroyLightning(bolt) end)
        fxOn(DAGON_FX, t, "chest")
        Damage.deal(c.caster, t, v(c, "damage"), Damage.MAGICAL)
    end}

    H.item_hand_of_midas = {
        onChannel = function(c)
            local t = c.target
            if not t or IsUnitType(t, UNIT_TYPE_HERO) or IsUnitType(t, UNIT_TYPE_ANCIENT)
                or IsUnitType(t, UNIT_TYPE_STRUCTURE) then
                return cancel(c, "Needs a non-hero, non-ancient creep")
            end
            if not charged(c) then return cancel(c, "No charges") end
        end,
        onCast = function(c)
            local it, t = charged(c), c.target
            if not it or not U.alive(t) then return end
            I().setCharges(it, I().charges(it) - 1)
            resync(it)
            local s = I().istate(it)
            s.restoreAt = s.restoreAt or (Timer.now() + v(c, "charge_restore"))
            local gold = math.floor(v(c, "bonus_gold"))
            SetPlayerState(c.owner, PLAYER_STATE_RESOURCE_GOLD, GetPlayerState(c.owner, PLAYER_STATE_RESOURCE_GOLD) + gold)
            I().text(t, "+" .. gold, 255, 220, 0)
            fx(MIDAS_FX, GetUnitX(t), GetUnitY(t))
            KillUnit(t)      -- no killer: no regular bounty or experience
        end,
    }

    -- Refresher Orb (this patch): hero abilities only; items keep their cooldowns.
    H.item_refresher = {onCast = function(c)
        for _, code in pairs(use("data.ids").abilities) do
            local id = FourCC(code)
            if GetUnitAbilityLevel(c.caster, id) > 0 then BlzEndUnitAbilityCooldown(c.caster, id) end
        end
        fxOn(REFRESH_FX, c.caster)
    end}

    H.item_sheepstick = {onCast = function(c)
        local t = c.target
        if not U.alive(t) then return end
        fx(HEX_FX, GetUnitX(t), GetUnitY(t))
        Mods.add(t, "item_sheepstick", {duration = v(c, "sheep_duration"), props = {hex = true}, debuff = true,
                                        dispel = "strong"})
    end}

    -- Arctic Blast: a ring growing at blast_speed hits each enemy once.
    H.item_shivas_guard = {onCast = function(c)
        local u = c.caster
        local x, y = GetUnitX(u), GetUnitY(u)
        local radius, speed = v(c, "blast_radius"), v(c, "blast_speed")
        local damage, slow, duration = v(c, "blast_damage"), v(c, "blast_movement_speed") / 100, v(c, "blast_debuff_duration")
        local hit, r = {}, 0
        fx(SHIVA_FX, x, y)
        Timer.onFrame(function(dt)
            r = math.min(radius, r + speed * dt)
            for _, e in ipairs(U.enemiesOf(c.owner, x, y, r)) do
                if not hit[e] then
                    hit[e] = true
                    Damage.deal(u, e, damage, Damage.MAGICAL)
                    if not U.isMagicImmune(e) then
                        Mods.add(e, "item_shivas_guard", {duration = duration, props = {move_pct = slow}, debuff = true,
                                                          effect = FROST_FX})
                    end
                end
            end
            return r >= radius
        end)
    end}

    H.item_satanic = {onCast = function(c)
        Mods.dispel(c.caster, {debuffs = true})
        Mods.add(c.caster, "item_satanic", {duration = v(c, "unholy_duration"),
                                            props = {lifesteal = v(c, "unholy_lifesteal_percent") / 100},
                                            effect = SATANIC_FX, attach = "chest"})
    end}

    -- Manta Style: the item dummy casts a Wand of Illusion copy (gen_objects
    -- "Zill", level 2 for ranged heroes) on the hero once per image.
    local images = {}         -- dummy -> {hero, index}

    H.item_manta = {onCast = function(c)
        local u = c.caster
        local ids = use("data.ids")
        local abil = FourCC(ids.abilities.items_illusion)
        local ranged = not IsUnitType(u, UNIT_TYPE_MELEE_ATTACKER)
        Mods.dispel(u, {debuffs = true})
        fxOn(MANTA_FX, u)
        for i = 1, math.floor(v(c, "images_count")) do
            local d = CreateUnit(c.owner, FourCC(ids.units.itemdummy), GetUnitX(u), GetUnitY(u), 0)
            UnitAddAbility(d, abil)
            SetUnitAbilityLevel(d, abil, ranged and 2 or 1)
            images[d] = {hero = u, index = i}
            IssueTargetOrderById(d, ILLUSION_ORDER, u)
            Timer.after(1.0, function()
                images[d] = nil
                RemoveUnit(d)
            end)
        end
    end}

    function A.summoned(summoner, summoned)
        local m = summoner and images[summoner]
        if not m or not U.alive(m.hero) then return end
        images[summoner] = nil
        local a = 2 * math.pi * m.index / 3 + GetRandomReal(0, 0.6)
        SetUnitPosition(summoned, U.polar(GetUnitX(m.hero), GetUnitY(m.hero), 110, a))
    end

    H.item_mekansm = {onCast = function(c)
        local u = c.caster
        fxOn(WAND_FX, u)
        for _, a in ipairs(U.alliesOf(c.owner, GetUnitX(u), GetUnitY(u), v(c, "heal_radius"))) do
            if not IsUnitType(a, UNIT_TYPE_STRUCTURE) then
                Damage.heal(a, v(c, "heal_amount"))
                fxOn(MEK_FX, a)
            end
        end
    end}

    -- ------------------------------------------------------------ dispatch

    function A.context(caster, abil, target, x, y)
        local name = I().abilityItem(abil)
        if not name or not caster then return nil end
        return {caster = caster, owner = GetOwningPlayer(caster), name = name, target = target, x = x, y = y,
                item = I().held(caster, name)}
    end

    function A.run(phase, caster, abil, target, x, y)
        local c = A.context(caster, abil, target, x, y)
        if not c then return nil end
        local h = H[c.name]
        if phase == "onChannel" then
            if Mods.flag(caster, "hex") then return cancel(c, "Muted") end
            -- Dota's cooldown and locks (backpack swap, Blink's damage lock),
            -- which WC3 does not always enforce itself (Items.ready)
            if c.item and not I().ready(caster, c.item, "cast") then return cancel(c) end
            -- Dota: another player's item works for an ally only if it is shareable
            if c.item and not I().usableBy(c.item, caster) then return cancel(c, "That item is not yours to use") end
        end
        local result = nil
        if h and h[phase] then result = h[phase](c) end
        if phase == "onCast" and c.item then I().used(caster, c.item, c.name) end
        return result
    end

    function A.init()
        Events.on("spell_channel", function(caster, abil, target, x, y) A.run("onChannel", caster, abil, target, x, y) end)
        Events.on("spell_effect", function(caster, abil, target, x, y) A.run("onCast", caster, abil, target, x, y) end)
        Events.on("spell_endcast", function(caster, abil, target, x, y) A.run("onEndCast", caster, abil, target, x, y) end)
        Events.on("summon", A.summoned)
    end

    -- ------------------------------------------------------------ bots

    local function frac(cur, max) return cur / math.max(1, max) end

    -- When to use each item: fn(u, item, s) -> true after issuing the order;
    -- s = {hp, mp, foes (visible enemy heroes within 1200), near (closest), dist}.
    local USE = {
        item_magic_stick = function(u, it, s) return s.hp < 0.35 and I().charges(it) >= 3 and UnitUseItem(u, it) end,
        item_faerie_fire = function(u, it, s) return s.hp < 0.2 and UnitUseItem(u, it) end,
        item_flask = function(u, it, s)
            return s.hp < 0.5 and not s.near and not Mods.has(u, "item_flask") and UnitUseItemTarget(u, it, u)
        end,
        item_clarity = function(u, it, s)
            return s.mp < 0.35 and not s.near and not Mods.has(u, "item_clarity") and UnitUseItemTarget(u, it, u)
        end,
        item_enchanted_mango = function(u, it, s) return s.mp < 0.2 and UnitUseItem(u, it) end,
        item_arcane_boots = function(u, it, s) return s.mp < 0.5 and UnitUseItem(u, it) end,
        item_mekansm = function(u, it, s) return s.hp < 0.6 and s.near ~= nil and UnitUseItem(u, it) end,
        item_black_king_bar = function(u, it, s) return #s.foes >= 2 and s.dist < 600 and UnitUseItem(u, it) end,
        item_satanic = function(u, it, s) return s.hp < 0.4 and s.dist < 300 and UnitUseItem(u, it) end,
        item_shivas_guard = function(u, it, s) return s.dist < 600 and UnitUseItem(u, it) end,
        item_manta = function(u, it, s) return s.dist < 500 and UnitUseItem(u, it) end,
        item_dagon = function(u, it, s) return s.dist < 640 and UnitUseItemTarget(u, it, s.near) end,
        item_sheepstick = function(u, it, s) return s.dist < 800 and UnitUseItemTarget(u, it, s.near) end,
        item_cyclone = function(u, it, s) return s.dist < 550 and UnitUseItemTarget(u, it, s.near) end,
        item_blink = function(u, it, s)
            return s.dist > 450 and s.dist < 1100 and s.hp > 0.6
                and UnitUseItemPoint(u, it, GetUnitX(s.near), GetUnitY(s.near))
        end,
        item_hand_of_midas = function(u, it, s)
            if I().charges(it) <= 0 then return false end
            local owner = GetOwningPlayer(u)
            for _, t in ipairs(U.enemiesOf(owner, GetUnitX(u), GetUnitY(u), 600)) do
                if not IsUnitType(t, UNIT_TYPE_HERO) and not IsUnitType(t, UNIT_TYPE_ANCIENT) then
                    return UnitUseItemTarget(u, it, t)
                end
            end
            return false
        end,
    }
    USE.item_magic_wand = USE.item_magic_stick

    -- One item use for a bot hero, if any rule fits; returns true when used.
    function A.autoUse(u)
        if not U.alive(u) or Mods.flag(u, "stun") or Mods.flag(u, "hex") then return false end
        local owner = GetOwningPlayer(u)
        local s = {hp = frac(GetWidgetLife(u), BlzGetUnitMaxHP(u)),
                   mp = frac(GetUnitState(u, UNIT_STATE_MANA), BlzGetUnitMaxMana(u)), foes = {}, dist = math.huge}
        for _, e in ipairs(U.enemiesOf(owner, GetUnitX(u), GetUnitY(u), 1200)) do
            if IsUnitType(e, UNIT_TYPE_HERO) and IsUnitVisible(e, owner) then s.foes[#s.foes + 1] = e end
        end
        s.near, s.dist = U.nearest(s.foes, GetUnitX(u), GetUnitY(u))
        for _, c in ipairs(I().carried(u)) do
            local rule = USE[c.name]
            local id = I().abilityId(c.name)
            local data = I().data(c.name)
            if rule and id and BlzGetUnitAbilityCooldownRemaining(u, id) <= 0 and I().cdLeft(c.item, u) <= 0
                and I().locked(c.item) <= 0
                and GetUnitState(u, UNIT_STATE_MANA) >= (data.mana or 0) and rule(u, c.item, s) then
                return true
            end
        end
        return false
    end

    return A
end)
