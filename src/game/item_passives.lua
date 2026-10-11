-- Item passives: Dota stacking rules for item stats, attack procs (evasion,
-- pierce, quell, crits, bash, corruption, cleave), auras, the Radiance burn,
-- Heart regeneration, Magic Stick charges, Hand of Midas charge restore,
-- Desolator kill stacks, the Blink damage lock and the cast range bonus.
-- Modifier props read here, usable by any module: evasion (0.25 = 25 %,
-- stacks multiplicatively) on the target and miss (blind chance) on the attacker.
define("item_passives", function()
    local Events = use("events")
    local Timer = use("timer")
    local Mods = use("mods")
    local Damage = use("damage")
    local U = use("util")
    local P = {}

    local IMMOLATION = "Abilities\\Spells\\Other\\ImmolationRed\\ImmolationRedTarget.mdl"
    local BASH_FX = "Abilities\\Spells\\Human\\Thunderclap\\ThunderclapTarget.mdl"
    local CLEAVE_FX = "Abilities\\Spells\\Other\\Cleave\\CleaveDamageTarget.mdl"
    local PIERCE_FX = "Abilities\\Weapons\\Bolt\\BoltImpact.mdl"

    local function I() return use("items") end
    local function v(name, key) return I().val(name, key) end

    local function aura(st, key, radius, props, power, enemies, structures)
        st.auras[#st.auras + 1] = {key = key, radius = radius, props = props, power = power,
                                   enemies = enemies or false, structures = structures or false}
    end

    local function corruption(st, name)
        local armor = v(name, "corruption_armor")
        if not st.corruption or armor < st.corruption.armor then
            st.corruption = {armor = armor, duration = v(name, "corruption_duration")}
        end
    end

    local function pierce(st, name)
        local chance = v(name, "bonus_chance") / 100
        if not st.pierce or chance > st.pierce.chance then
            st.pierce = {chance = chance, damage = v(name, "bonus_chance_damage")}
        end
    end

    local function crit(st, name)
        st.crits[#st.crits + 1] = {chance = v(name, "crit_chance") / 100, mult = v(name, "crit_multiplier") / 100}
    end

    -- Per-item proc and aura state; `add` adds to the item modifier's props.
    local SPECIAL = {
        item_power_treads = function(st, c, add)
            add(I().istate(c.item).attr or "str", v("item_power_treads", "bonus_stat"))
        end,
        item_desolator = function(st, c, add)
            add("damage", I().istate(c.item).kills or 0)
            corruption(st, "item_desolator")
        end,
        item_blight_stone = function(st) corruption(st, "item_blight_stone") end,
        item_quelling_blade = function(st, c, add, melee)
            local q = melee and v("item_quelling_blade", "damage_bonus") or v("item_quelling_blade", "damage_bonus_ranged")
            st.quell = math.max(st.quell or 0, q)
        end,
        item_bfury = function(st, c, add, melee)
            local q = melee and v("item_bfury", "quelling_bonus") or v("item_bfury", "quelling_bonus_ranged")
            st.quell = math.max(st.quell or 0, q)
            if melee then
                st.cleave = {hero = v("item_bfury", "cleave_damage_percent") / 100,
                             creep = v("item_bfury", "cleave_damage_percent_creep") / 100,
                             distance = v("item_bfury", "cleave_distance"),
                             start = v("item_bfury", "cleave_starting_width"),
                             finish = v("item_bfury", "cleave_ending_width")}
            end
        end,
        item_lesser_crit = function(st) crit(st, "item_lesser_crit") end,
        item_greater_crit = function(st) crit(st, "item_greater_crit") end,
        item_basher = function(st)
            st.bash = {melee = v("item_basher", "bash_chance_melee") / 100,
                       ranged = v("item_basher", "bash_chance_ranged") / 100,
                       duration = v("item_basher", "bash_duration"), damage = v("item_basher", "bonus_chance_damage"),
                       cooldown = v("item_basher", "bash_cooldown")}
        end,
        item_javelin = function(st) pierce(st, "item_javelin") end,
        item_monkey_king_bar = function(st) pierce(st, "item_monkey_king_bar") end,
        item_radiance = function(st)
            st.radiance = {damage = v("item_radiance", "aura_damage"), radius = v("item_radiance", "aura_radius")}
            st.effect = IMMOLATION
        end,
        item_assault = function(st)
            local r = v("item_assault", "aura_radius")
            aura(st, "aura_assault", r, {attack_speed = v("item_assault", "aura_attack_speed"),
                                         armor = v("item_assault", "aura_positive_armor")}, 1, false, true)
            aura(st, "aura_assault_minus", r, {armor = v("item_assault", "aura_negative_armor")}, 1, true, true)
        end,
        item_shivas_guard = function(st)
            aura(st, "aura_shiva", v("item_shivas_guard", "aura_radius"),
                 {attack_speed = v("item_shivas_guard", "aura_attack_speed")}, 1, true)
        end,
        item_headdress = function(st)
            local regen = v("item_headdress", "aura_health_regen")
            aura(st, "aura_regen", v("item_headdress", "aura_radius"), {hp_regen = regen}, regen)
        end,
        item_mekansm = function(st)
            local regen = v("item_mekansm", "aura_health_regen")
            aura(st, "aura_regen", v("item_mekansm", "aura_radius"), {hp_regen = regen}, regen)
        end,
        item_ring_of_basilius = function(st)
            local regen = v("item_ring_of_basilius", "aura_mana_regen")
            aura(st, "aura_mana", v("item_ring_of_basilius", "aura_radius"), {mana_regen = regen}, regen)
        end,
        item_arcane_boots = function(st)
            local regen = v("item_arcane_boots", "aura_mana_regen")
            aura(st, "aura_mana", v("item_arcane_boots", "aura_radius"), {mana_regen = regen}, regen)
        end,
        item_buckler = function(st)
            local armor = v("item_buckler", "bonus_aoe_armor")
            aura(st, "aura_buckler", v("item_buckler", "bonus_aoe_radius"), {armor = armor}, armor)
        end,
        item_heart = function(st)
            st.heart = {max = v("item_heart", "hp_regen") / 100, missing = v("item_heart", "missing_health_regen") / 100}
        end,
        item_blink = function(st) st.blink = true end,
        item_magic_stick = function(st) st.stick = true end,
        item_magic_wand = function(st) st.stick = true end,
        item_hand_of_midas = function(st) st.midas = true end,
    }

    -- Props of the unit's item modifier and its proc state. Dota rules: only
    -- the fastest boots and the best Wind Lace item count, Yasha-family
    -- movement percent does not stack, magic resistance and evasion multiply;
    -- percentage bonuses become flat numbers from the hero's current stats.
    function P.compute(u, carried)
        local props, st = {}, {crits = {}, auras = {}, names = {}}
        local melee = IsUnitType(u, UNIT_TYPE_MELEE_ATTACKER)
        local best = {boots = 0, lace = 0, yasha = 0, as_pct = 0, mana_pct = 0, hp_amp = 0, mana_amp = 0, cast = 0}
        local keepMagic, keepEvade = 1, 1
        local function add(k, val) props[k] = (props[k] or 0) + val end
        for _, c in ipairs(carried) do
            local name = c.name
            st.names[name] = (st.names[name] or 0) + 1
            local s = I().data(name).stats or {}
            for k, val in pairs(s) do
                if k == "boots_ms" then
                    best.boots = math.max(best.boots, melee and s.boots_ms_melee or val)
                elseif k == "lace_ms" then
                    best.lace = math.max(best.lace, val)
                elseif k == "yasha_pct" then
                    best.yasha = math.max(best.yasha, val)
                elseif k == "magic_resist" then
                    keepMagic = keepMagic * (1 - val)
                elseif k == "evasion" then
                    keepEvade = keepEvade * (1 - val)
                elseif k == "damage_melee" then
                    if melee then add("damage", val) end
                elseif k == "damage_ranged" then
                    if not melee then add("damage", val) end
                elseif k == "attack_speed_pct" then
                    best.as_pct = math.max(best.as_pct, val)
                elseif k == "max_mana_pct" then
                    best.mana_pct = math.max(best.mana_pct, val)
                elseif k == "hp_regen_amp" then
                    best.hp_amp = math.max(best.hp_amp, val)
                elseif k == "mana_regen_amp" then
                    best.mana_amp = math.max(best.mana_amp, val)
                elseif k == "cast_range" then
                    best.cast = math.max(best.cast, val)
                elseif k ~= "boots_ms_melee" then
                    add(k, val)
                end
            end
            local special = SPECIAL[name]
            if special then special(st, c, add, melee) end
        end
        if best.boots > 0 then add("move_flat", best.boots) end
        if best.lace > 0 then add("move_flat", best.lace) end
        if best.yasha > 0 then add("move_pct", best.yasha) end
        if keepMagic < 1 then props.magic_resist = 1 - keepMagic end
        if keepEvade < 1 then props.evasion = 1 - keepEvade end
        if IsUnitType(u, UNIT_TYPE_HERO) then
            if best.as_pct > 0 then
                add("attack_speed", best.as_pct * (100 + GetHeroAgi(u, true) + (props.attack_speed or 0)))
            end
            if best.mana_pct > 0 then add("max_mana", best.mana_pct * (75 + 12 * GetHeroInt(u, true))) end
            if best.hp_amp > 0 then add("hp_regen", best.hp_amp * ((props.hp_regen or 0) + 0.1 * GetHeroStr(u, true))) end
            if best.mana_amp > 0 then
                add("mana_regen", best.mana_amp * ((props.mana_regen or 0) + 0.05 * GetHeroInt(u, true)))
            end
        end
        st.castRange = best.cast
        return props, st
    end

    -- ------------------------------------------------------------ cast range

    local rangeBonus = {}     -- unit -> bonus last applied

    -- Aether Lens / Dagon: adds `bonus` to the cast range of the unit's hero
    -- abilities, as the "items" source of abilities.lua's range bonuses
    -- (talents and hero passives add theirs there too).
    function P.castRange(u, bonus)
        if bonus == (rangeBonus[u] or 0) and bonus == 0 then return end
        rangeBonus[u] = bonus
        local A = use("abilities")
        for _, code in pairs(use("data.ids").abilities) do
            local id = FourCC(code)
            if GetUnitAbilityLevel(u, id) > 0 and A.rangeBonus(u, id, "items") ~= bonus then
                A.setRangeBonus(u, id, "items", bonus)
            end
        end
    end

    -- ------------------------------------------------------------ attacks

    local pending = nil       -- effects decided in damaging, applied in damaged
    local bashReady = {}      -- attacker -> time its bash is ready
    local blinkLock = {}      -- unit -> time its Blink unlocks

    local function roll(chance) return chance > 0 and GetRandomReal(0, 1) < chance end

    local function dodged(source, target)
        -- "no_evade" on the target: attacks on it always hit (Meepo's Earthbind talent)
        if Mods.flag(target, "no_evade") then return false end
        local keep = 1
        for _, e in ipairs(Mods.values(target, "evasion")) do keep = keep * (1 - e) end
        for _, m in ipairs(Mods.values(source, "miss")) do keep = keep * (1 - m) end
        return roll(1 - keep)
    end

    function P.lockBlink(u)
        local lock = v("item_blink", "blink_damage_cooldown")
        blinkLock[u] = Timer.now() + lock
        local it = I().find(u, "item_blink")
        if it then I().startCooldown(it, lock, u) end
    end

    function P.blinkLocked(u)
        return (blinkLock[u] or 0) > Timer.now()
    end

    -- Cone behind the target, widening from start to finish over distance.
    local function cleave(source, target, raw, c)
        local sx, sy = GetUnitX(source), GetUnitY(source)
        local a = U.angle(sx, sy, GetUnitX(target), GetUnitY(target))
        local ca, sa = math.cos(a), math.sin(a)
        for _, e in ipairs(U.enemiesOf(GetOwningPlayer(source), sx, sy, c.distance + 50)) do
            if e ~= target then
                local dx, dy = GetUnitX(e) - sx, GetUnitY(e) - sy
                local along = dx * ca + dy * sa
                local side = math.abs(dy * ca - dx * sa)
                local half = (c.start + (c.finish - c.start) * along / c.distance) / 2
                if along > 0 and along <= c.distance and side <= half then
                    local pct = IsUnitType(e, UNIT_TYPE_HERO) and c.hero or c.creep
                    Damage.deal(source, e, raw * pct, Damage.PURE, {noAmp = true, tag = "cleave"})
                    DestroyEffect(AddSpecialEffectTarget(CLEAVE_FX, e, "chest"))
                end
            end
        end
    end

    function P.damaging(source, target, info)
        pending = nil
        if not info.attack or not source or not target then return end
        local st = I().state[source]
        local illusion = IsUnitIllusion(source)
        local pierced = st and not illusion and st.pierce and roll(st.pierce.chance)
        if not pierced and dodged(source, target) then
            info.amount = 0
            info.missed = true
            I().text(target, "miss", 200, 200, 200)
            return
        end
        if not st or illusion then return end
        local structure = IsUnitType(target, UNIT_TYPE_STRUCTURE)
        local melee = IsUnitType(source, UNIT_TYPE_MELEE_ATTACKER)
        if st.quell and not structure and not IsUnitType(target, UNIT_TYPE_HERO) then
            info.amount = info.amount + st.quell
        end
        local mult = 0
        for _, c in ipairs(st.crits) do
            if c.mult > mult and roll(c.chance) then mult = c.mult end
        end
        if mult > 0 then info.amount = info.amount * mult end
        local b = st.bash
        if b and not structure and (bashReady[source] or 0) <= Timer.now() and roll(melee and b.melee or b.ranged) then
            bashReady[source] = Timer.now() + b.cooldown
            info.amount = info.amount + b.damage
            Mods.add(target, "item_bash", {duration = b.duration, props = {stun = true}, debuff = true, dispel = "strong",
                                           effect = BASH_FX, attach = "overhead"})
        end
        if st.corruption then
            Mods.add(target, "item_corruption", {duration = st.corruption.duration,
                                                 props = {armor = st.corruption.armor}, debuff = true})
        end
        pending = {source = source, target = target, crit = mult > 0, pierce = pierced and st.pierce.damage or nil,
                   cleave = (st.cleave and melee and not structure) and info.amount or nil, st = st}
    end

    function P.damaged(source, target, amount, info)
        if source and target and amount > 0 and IsUnitType(source, UNIT_TYPE_HERO)
            and IsUnitEnemy(source, GetOwningPlayer(target)) then
            local st = I().state[target]
            if st and st.blink then P.lockBlink(target) end
            Mods.remove(target, "item_flask")
            Mods.remove(target, "item_clarity")
        end
        local p = pending
        if not p or p.source ~= source or p.target ~= target then return end
        pending = nil
        if p.crit then I().text(target, math.floor(amount) .. "!", 255, 50, 40) end
        if p.pierce and U.alive(target) then
            DestroyEffect(AddSpecialEffectTarget(PIERCE_FX, target, "chest"))
            Damage.deal(source, target, p.pierce, Damage.MAGICAL, {noAmp = true, tag = "pierce"})
        end
        if p.cleave and p.st.cleave then cleave(source, target, p.cleave, p.st.cleave) end
    end

    -- ------------------------------------------------------------ loops

    -- Auras of the same kind do not stack: each unit gets the strongest.
    function P.auras()
        local best = {}
        for u, st in pairs(I().state) do
            if st.auras and #st.auras > 0 and U.alive(u) then
                local owner = GetOwningPlayer(u)
                local x, y = GetUnitX(u), GetUnitY(u)
                for _, a in ipairs(st.auras) do
                    local list = a.enemies and U.enemiesOf(owner, x, y, a.radius, a.structures)
                        or U.alliesOf(owner, x, y, a.radius)
                    local slot = best[a.key] or {}
                    best[a.key] = slot
                    for _, t in ipairs(list) do
                        if (a.structures or not IsUnitType(t, UNIT_TYPE_STRUCTURE))
                            and (slot[t] == nil or a.power > slot[t].power) then
                            slot[t] = a
                        end
                    end
                end
            end
        end
        for key, slot in pairs(best) do
            for t, a in pairs(slot) do
                Mods.add(t, key, {duration = 1.0, props = a.props, debuff = a.enemies, dispel = "none"})
            end
        end
    end

    function P.burn()
        for u, st in pairs(I().state) do
            local r = st.radiance
            if r and U.alive(u) then
                for _, e in ipairs(U.enemiesOf(GetOwningPlayer(u), GetUnitX(u), GetUnitY(u), r.radius)) do
                    Damage.deal(u, e, r.damage, Damage.MAGICAL, {tag = "radiance"})
                end
            end
        end
    end

    local REGEN_STEP = 0.25

    function P.regen()
        for u, st in pairs(I().state) do
            local h = st.heart
            if h and U.alive(u) then
                local max, life = BlzGetUnitMaxHP(u), GetWidgetLife(u)
                SetWidgetLife(u, life + (h.max * max + h.missing * math.max(0, max - life)) * REGEN_STEP)
            end
        end
    end

    -- Hand of Midas: one charge back every charge_restore seconds, up to the cap.
    function P.recharge()
        local Items = I()
        local now = Timer.now()
        local restore = v("item_hand_of_midas", "charge_restore")
        local cap = v("item_hand_of_midas", "charges_max")
        for u, st in pairs(Items.state) do
            if st.midas then
                for _, c in ipairs(Items.carried(u)) do
                    if c.name == "item_hand_of_midas" then
                        local s = Items.istate(c.item)
                        local n = Items.charges(c.item)
                        if n >= cap then
                            s.restoreAt = nil
                        else
                            s.restoreAt = s.restoreAt or (now + restore)
                            if now >= s.restoreAt then
                                Items.setCharges(c.item, n + 1)
                                s.restoreAt = (n + 1 < cap) and (now + restore) or nil
                            end
                        end
                    end
                end
            end
        end
    end

    -- Magic Stick / Wand: a charge when a visible enemy hero nearby casts a
    -- spell (item abilities do not count).
    function P.spellCast(caster, abil)
        local Items = I()
        if not caster or Items.abilityItem(abil) or not IsUnitType(caster, UNIT_TYPE_HERO) then return end
        local x, y = GetUnitX(caster), GetUnitY(caster)
        for u, st in pairs(Items.state) do
            local p = st.stick and U.alive(u) and GetOwningPlayer(u)
            if p and IsUnitEnemy(caster, p) and IsUnitVisible(caster, p) then
                for _, c in ipairs(Items.carried(u)) do
                    if (c.name == "item_magic_stick" or c.name == "item_magic_wand")
                        and U.dist(x, y, GetUnitX(u), GetUnitY(u)) <= v(c.name, "charge_radius") then
                        Items.setCharges(c.item, math.min(v(c.name, "max_charges"), Items.charges(c.item) + 1))
                    end
                end
            end
        end
    end

    -- Desolator: bonus damage for each enemy hero its carrier kills, capped.
    function P.death(dying, killer)
        if not killer or not IsUnitType(dying, UNIT_TYPE_HERO) or IsUnitIllusion(dying) then return end
        local Items = I()
        local st = Items.state[killer]
        if not st or not st.names.item_desolator or not IsUnitEnemy(dying, GetOwningPlayer(killer)) then return end
        local it = Items.find(killer, "item_desolator")
        if not it then return end
        local s = Items.istate(it)
        s.kills = math.min(v("item_desolator", "max_damage"), (s.kills or 0) + v("item_desolator", "bonus_damage_per_kill"))
        SetItemCharges(it, math.floor(s.kills))
        Items.refresh(killer)
    end

    function P.init()
        Damage.onDamaging(P.damaging)
        Damage.onDamaged(P.damaged)
        Timer.every(0.5, P.auras)
        Timer.every(1.0, P.burn)
        Timer.every(REGEN_STEP, P.regen)
        Timer.every(1.0, P.recharge)
        Events.on("spell_effect", P.spellCast)
        Events.on("death", P.death)
        Events.on("hero_skill", function(u)
            local st = I().state[u]
            if st and (st.castRange or 0) > 0 then P.castRange(u, st.castRange) end
        end)
    end

    return P
end)
