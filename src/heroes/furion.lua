-- Nature's Prophet: Sprout, Teleportation, Nature's Call, Curse of the
-- Oldgrowth, Wrath of Nature and the Spirit of the Forest innate. The map's
-- WC3 trees are real Dota trees here: Sprout grows tree destructables,
-- Nature's Call turns trees in an area into Treants.
define("hero_furion", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Safe = use("safe")
    local Log = use("log")
    local Bots = use("bots")
    local F = {}

    local SPROUT, TELEPORT, CALL = "furion_sprout", "furion_teleportation", "furion_force_of_nature"
    local CURSE, SPIRIT, WRATH = "furion_curse_of_the_forest", "furion_spirit_of_the_forest", "furion_wrath_of_nature"
    local UNIT_CAST_POINT = 0.3          -- "ucpt" of every hero, see gen_objects.py
    local SPROUT_TREE = "LTlt"           -- the map's own tree type
    local SPROUT_TREES, SPROUT_RING = 8, 150
    local SPIRIT_RADIUS_PER_LEVEL = 10   -- radius_base "hero_levelup" (Dota KV, not in heroes.json)
    local TREANT_MAGIC_RESIST = 0.25     -- npc_dota_furion_treant MagicalResistance
    local TREE_TYPES = {"ATtr", "BTtw", "CTtr", "FTtw", "LTlt", "NTtw", "WTtw", "WTst", "YTct", "YTwt",
                        "YTst", "YTft", "VTlt", "DTsh", "ZTtw", "ITtw", "ATtc", "OTtw", "KTtw", "JTct",
                        "JTtw", "GTsh", "BTtc", "CTtc", "NTtc", "ZTtc", "ITtc"}

    ---------------------------------------------------------------- helpers
    local function fx(model, x, y)
        DestroyEffect(AddSpecialEffect(model, x, y))
    end

    local function fxOn(model, u, attach)
        DestroyEffect(AddSpecialEffectTarget(model, u, attach or "origin"))
    end

    local function cancel(u, msg)
        PauseUnit(u, true)
        IssueImmediateOrder(u, "stop")
        PauseUnit(u, false)
        if msg then
            DisplayTimedTextToPlayer(GetOwningPlayer(u), 0, 0, 2, "|cffffcc00" .. msg .. "|r")
        end
    end

    local function refund(ctx)
        local cost = BlzGetUnitAbilityManaCost(ctx.caster, ctx.def.id, math.max(0, ctx.level - 1))
        SetUnitState(ctx.caster, UNIT_STATE_MANA, GetUnitState(ctx.caster, UNIT_STATE_MANA) + cost)
        BlzEndUnitAbilityCooldown(ctx.caster, ctx.def.id)
    end

    local function level(u, name)
        return A.level(u, name)
    end

    local treeType = nil
    local rect = nil
    -- Alive trees within r of (x, y).
    local function treesIn(x, y, r)
        if not treeType then
            treeType = {}
            for _, c in ipairs(TREE_TYPES) do treeType[FourCC(c)] = true end
        end
        if not rect then rect = Rect(0, 0, 0, 0) end
        SetRect(rect, x - r, y - r, x + r, y + r)
        local out = {}
        EnumDestructablesInRect(rect, nil, function()
            Safe.call(function()
                local d = GetEnumDestructable()
                if treeType[GetDestructableTypeId(d)] and GetDestructableLife(d) > 0
                    and U.dist(x, y, GetDestructableX(d), GetDestructableY(d)) <= r then
                    out[#out + 1] = d
                end
            end)
        end)
        return out
    end

    -- White damage, the base that Spirit of the Forest's percentage scales.
    local function baseDamage(u)
        local d = BlzGetUnitBaseDamage(u, 0) + BlzGetUnitDiceNumber(u, 0) * (BlzGetUnitDiceSides(u, 0) + 1) / 2
        if IsUnitType(u, UNIT_TYPE_HERO) then
            d = d + GetHeroInt(u, true)   -- gen_objects gives universal heroes INT as primary
        end
        return d
    end

    ---------------------------------------------------------------- state
    local prophets = {}       -- Nature's Prophets seen (Spirit of the Forest holders)
    local treants = {}        -- treant -> {owner = Furion, bonus = hero damage}
    local spiritBonus = {}    -- unit -> damage currently granted
    local teleporting = {}    -- Furion -> pending Teleportation
    local loops = false
    local startLoops

    local function track(furion)
        if furion and not prophets[furion] then
            prophets[furion] = true
            startLoops()
        end
    end

    local function treantsOf(furion)
        local list = {}
        for t, info in pairs(treants) do
            if info.owner == furion and U.alive(t) then list[#list + 1] = t end
        end
        return list
    end

    ---------------------------------------------------------------- Sprout
    A.define(SPROUT, {
        onCast = function(ctx)
            local c = ctx.caster
            track(c)
            local x, y = ctx.x, ctx.y
            if ctx.target then x, y = GetUnitX(ctx.target), GetUnitY(ctx.target) end
            local duration = ctx.v("duration")
            local trees = {}
            local typ = FourCC(SPROUT_TREE)
            for i = 0, SPROUT_TREES - 1 do
                local tx, ty = U.polar(x, y, SPROUT_RING, i * 2 * math.pi / SPROUT_TREES)
                trees[#trees + 1] = CreateDestructable(typ, tx, ty, GetRandomReal(0, 360), 0.8, GetRandomInt(0, 9))
            end
            fx("Abilities\\Spells\\NightElf\\EntanglingRoots\\EntanglingRootsTarget.mdl", x, y)
            local dmg = ctx.v("sprout_damage")
            for _, t in ipairs(U.enemiesOf(ctx.owner, x, y, ctx.v("sprout_damage_radius"))) do
                Damage.deal(c, t, dmg, "magical")
            end
            local fog = CreateFogModifierRadius(ctx.owner, FOG_OF_WAR_VISIBLE, x, y, ctx.v("vision_range"), true, false)
            FogModifierStart(fog)
            Timer.after(duration, function()
                for _, d in ipairs(trees) do RemoveDestructable(d) end
                FogModifierStop(fog)
                DestroyFogModifier(fog)
            end)
        end,
    })

    ---------------------------------------------------------------- Teleportation
    -- Dota's 3 s cast point is a Channel follow-through; cost and cooldown are
    -- refunded when it is interrupted, as in Dota.
    local function teleportTime(lvl)
        return A.value(TELEPORT, "AbilityCastPoint", lvl) - UNIT_CAST_POINT
    end

    A.define(TELEPORT, {
        onChannel = function(ctx)
            if Mods.flag(ctx.caster, "root") then cancel(ctx.caster, "Rooted") end
        end,
        onCast = function(ctx)
            local c = ctx.caster
            track(c)
            local old = teleporting[c]
            if old then
                DestroyEffect(old.mark)
                DestroyEffect(old.glow)
            end
            -- the destination is marked for everyone, as in Dota
            teleporting[c] = {start = Timer.now(), x = ctx.x, y = ctx.y,
                mark = AddSpecialEffect("Abilities\\Spells\\NightElf\\Tranquility\\TranquilityTarget.mdl", ctx.x, ctx.y),
                glow = AddSpecialEffectTarget("Abilities\\Spells\\Human\\MassTeleport\\MassTeleportTarget.mdl", c, "origin")}
        end,
        onEndCast = function(ctx)
            local c = ctx.caster
            local p = teleporting[c]
            if not p then return end
            teleporting[c] = nil
            DestroyEffect(p.mark)
            DestroyEffect(p.glow)
            if Timer.now() - p.start < teleportTime(ctx.level) - 0.1 then
                refund(ctx)
                return
            end
            if not U.alive(c) then return end
            fx("Abilities\\Spells\\Human\\MassTeleport\\MassTeleportCaster.mdl", GetUnitX(c), GetUnitY(c))
            SetUnitPosition(c, p.x, p.y)
            fx("Abilities\\Spells\\Human\\MassTeleport\\MassTeleportTo.mdl", GetUnitX(c), GetUnitY(c))
            local m = Mods.add(c, "furion_teleport_barrier", {duration = ctx.v("buff_duration"), source = c,
                effect = "Abilities\\Spells\\NightElf\\Barkskin\\BarkSkinTarget.mdl", attach = "chest"})
            if m then m.shield = ctx.v("barrier") end
        end,
    })

    -- The barrier soaks damage of any type until it is used up.
    Damage.onDamaging(function(source, target, info)
        if target == nil or info.amount <= 0 then return end
        local m = Mods.get(target, "furion_teleport_barrier")
        if not m or (m.shield or 0) <= 0 then return end
        -- attacks arrive before armor: compare the barrier with what armor lets through
        local factor = info.attack and Damage.armorFactor(BlzGetUnitArmor(target)) or 1
        if factor <= 0 then factor = 1 end
        local final = info.amount * factor
        local absorbed = math.min(m.shield, final)
        m.shield = m.shield - absorbed
        info.amount = (final - absorbed) / factor
        if m.shield <= 0 then Mods.remove(target, "furion_teleport_barrier") end
    end)

    ---------------------------------------------------------------- Nature's Call
    local function spawnTreant(furion, x, y, lvl)
        local code = use("data.ids").units.furion_treant
        if not code then return nil end
        local u = CreateUnit(GetOwningPlayer(furion), FourCC(code), x, y, GetUnitFacing(furion))
        local hp = math.floor(A.value(CALL, "treant_health", lvl))
        BlzSetUnitMaxHP(u, hp)
        SetWidgetLife(u, hp)
        -- object data has 1 die of 1 side: base + 1 = Dota damage
        BlzSetUnitBaseDamage(u, math.floor(A.value(CALL, "treant_damage", lvl)) - 1, 0)
        Mods.add(u, "furion_treant", {persist = true, dispel = "none", props = {
            magic_resist = TREANT_MAGIC_RESIST,
            move_flat = A.value(CALL, "treant_movespeed", lvl) - GetUnitDefaultMoveSpeed(u),
        }})
        UnitApplyTimedLife(u, FourCC("BTLF"), A.value(CALL, "treant_duration", lvl))
        treants[u] = {owner = furion, bonus = A.value(CALL, "treant_bonus_hero_damage", lvl)}
        fx("Abilities\\Spells\\NightElf\\TreeofLifeUpgrade\\TreeofLifeUpgradeTargetArt.mdl", x, y)
        return u
    end

    A.define(CALL, {
        onCast = function(ctx)
            local c = ctx.caster
            track(c)
            local trees = treesIn(ctx.x, ctx.y, ctx.v("area_of_effect"))
            local count = math.min(#trees, math.floor(ctx.v("max_treants")))
            -- every tree in the area is used up; one Treant per tree up to the cap
            local spots = {}
            for i, d in ipairs(trees) do
                if i <= count then spots[#spots + 1] = {GetDestructableX(d), GetDestructableY(d)} end
                KillDestructable(d)
            end
            for _, p in ipairs(spots) do spawnTreant(c, p[1], p[2], ctx.level) end
            if count == 0 then
                fx("Abilities\\Spells\\NightElf\\EntanglingRoots\\EntanglingRootsTarget.mdl", ctx.x, ctx.y)
            end
        end,
    })

    -- Treants hit heroes harder.
    Damage.onDamaging(function(source, target, info)
        if not info.attack or source == nil or target == nil then return end
        local t = treants[source]
        if t and IsUnitType(target, UNIT_TYPE_HERO) then info.amount = info.amount + t.bonus end
    end)

    ---------------------------------------------------------------- Curse of the Oldgrowth
    local function curseCount(u, radius, furion)
        local x, y = GetUnitX(u), GetUnitY(u)
        local n = #treesIn(x, y, radius)
        for _, t in ipairs(treantsOf(furion)) do     -- Treants count as trees
            if U.dist(x, y, GetUnitX(t), GetUnitY(t)) <= radius then n = n + 1 end
        end
        return n
    end

    A.define(CURSE, {
        onCast = function(ctx)
            local c = ctx.caster
            track(c)
            local radius, dps, slow = ctx.v("radius"), ctx.v("damage_per_tree"), ctx.v("slow_per_tree")
            local TICK = 0.5
            for _, h in ipairs(U.enemiesOf(ctx.owner, GetUnitX(c), GetUnitY(c), ctx.v("range"))) do
                if U.isHero(h) and not U.isMagicImmune(h) then
                    local n = curseCount(h, radius, c)
                    local m = Mods.add(h, "furion_curse", {duration = ctx.v("duration"), source = c, debuff = true,
                        tick = TICK, props = {move_pct = -slow * n / 100},
                        effect = "Abilities\\Spells\\Undead\\Curse\\CurseTarget.mdl", attach = "overhead",
                        onTick = function(m)
                            local k = curseCount(h, radius, c)
                            m.props.move_pct = -slow * k / 100
                            use("stats").refresh(h)
                            if k > 0 then Damage.deal(c, h, dps * k * TICK, "magical") end
                        end,
                        onRemove = function() UnitShareVision(h, ctx.owner, false) end})
                    -- shown through the fog while cursed
                    if m then UnitShareVision(h, ctx.owner, true) end
                end
            end
        end,
    })

    ---------------------------------------------------------------- Wrath of Nature
    local function wrathTargets(owner)
        return function(u)
            return IsUnitVisible(u, owner) and not U.isMagicImmune(u)
        end
    end

    A.define(WRATH, {
        onCast = function(ctx)
            local c = ctx.caster
            track(c)
            local owner = ctx.owner
            local base, add = ctx.v("damage"), ctx.v("damage_percent_add") / 100
            local maxTargets, delay = math.floor(ctx.v("max_targets")), ctx.v("jump_delay")
            local ok = wrathTargets(owner)
            local hit, count = {}, 0
            local function nextFrom(x, y)
                local best, bd = nil, math.huge
                for _, u in ipairs(U.enemiesOf(owner, x, y, 100000)) do
                    if not hit[u] and ok(u) then
                        local d = U.dist(x, y, GetUnitX(u), GetUnitY(u))
                        if d < bd then best, bd = u, d end
                    end
                end
                return best
            end
            local strike
            strike = function(u)
                count = count + 1
                hit[u] = true
                fxOn("Abilities\\Spells\\NightElf\\Starfall\\StarfallTarget.mdl", u, "origin")
                -- each enemy hit after the first adds damage_percent_add of the base
                Damage.deal(c, u, base * (1 + add * (count - 1)), "magical")
                if count >= maxTargets then return end
                local x, y = GetUnitX(u), GetUnitY(u)
                Timer.after(delay, function()
                    local n = nextFrom(x, y)
                    if n then strike(n) end
                end)
            end
            local first = ctx.target
            if not (first and U.alive(first) and IsUnitEnemy(first, owner) and ok(first)
                    and not U.isStructure(first)) then
                first = nextFrom(ctx.target and GetUnitX(ctx.target) or ctx.x, ctx.target and GetUnitY(ctx.target) or ctx.y)
            end
            if first then strike(first) end
        end,
    })

    ---------------------------------------------------------------- Spirit of the Forest
    local function setSpirit(u, pct)
        local bonus = math.floor(baseDamage(u) * pct / 100 + 0.5)
        if spiritBonus[u] ~= bonus then
            spiritBonus[u] = bonus
            Mods.add(u, "furion_spirit_of_the_forest", {persist = true, dispel = "none", props = {damage = bonus}})
        end
    end

    -- Nature's Prophet: +pct per nearby tree and +pct x multiplier per living
    -- Treant anywhere. Treants: +pct per tree and multiplied per Treant near them.
    local function spiritAll()
        for furion in pairs(prophets) do
            local on = level(furion, SPIRIT) > 0 and not Mods.flag(furion, "break")
            local pct = A.value(SPIRIT, "damage_per_tree_pct", 1)
            local mult = A.value(SPIRIT, "multiplier", 1)
            local r = A.value(SPIRIT, "radius_base", 1) + SPIRIT_RADIUS_PER_LEVEL * GetHeroLevel(furion)
            local mine = treantsOf(furion)
            if U.alive(furion) then
                local n = on and (#treesIn(GetUnitX(furion), GetUnitY(furion), r) + mult * #mine) or 0
                setSpirit(furion, pct * n)
            end
            for _, t in ipairs(mine) do
                local x, y = GetUnitX(t), GetUnitY(t)
                local n = #treesIn(x, y, r)
                for _, o in ipairs(mine) do
                    if o ~= t and U.dist(x, y, GetUnitX(o), GetUnitY(o)) <= r then n = n + mult end
                end
                setSpirit(t, pct * n)
            end
        end
        for t in pairs(treants) do
            if not U.alive(t) then
                treants[t], spiritBonus[t] = nil, nil
            end
        end
    end

    -- Treants of a bot Nature's Prophet stay with him.
    local function follow()
        for t, info in pairs(treants) do
            local f = info.owner
            if U.alive(t) and U.alive(f) then
                local slot = GetPlayerId(GetOwningPlayer(f))
                if slot <= SLOT_COMMANDER and use("roles").isBot(slot)
                    and U.dist(GetUnitX(t), GetUnitY(t), GetUnitX(f), GetUnitY(f)) > 700 then
                    IssuePointOrder(t, "attack", GetUnitX(f), GetUnitY(f))
                end
            end
        end
    end

    startLoops = function()
        if loops then return end
        loops = true
        Timer.every(0.5, spiritAll)
        Timer.every(1.0, follow)
    end

    Events.on("hero_spawned", function(u, key)
        if key == "furion" then track(u) end
    end)

    ---------------------------------------------------------------- bots
    Bots.hint(SPROUT, {target = "enemyHero"})
    Bots.hint(TELEPORT, {target = "enemyHero", point = true, range = 2500})
    Bots.hint(CALL, {target = "point"})
    Bots.hint(CURSE, {target = "none", radius = 900, ultimate = true})
    Bots.hint(WRATH, {target = "enemyHero", range = 3000, ultimate = true})

    -- exposed for tests
    F.spawnTreant, F.spiritAll, F.follow, F.treesIn, F.treants = spawnTreant, spiritAll, follow, treesIn, treants
    return F
end)
