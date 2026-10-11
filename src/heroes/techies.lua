-- Techies: Sticky Bomb, Reactive Tazer (with its Detonate sub-ability),
-- Blast Off!, Proximity Mines and the M.A.D. innate; Aghanim's Scepter
-- Minefield Sign and Aghanim's Shard M.A.D. (plant and Detonate M.A.D.).
-- Values are read with the caster, so its talents and upgrades apply
-- (src/game/talents.lua).
define("hero_techies", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Safe = use("safe")
    local Log = use("log")
    local Bots = use("bots")
    local Fx = use("fx")
    local T = {}

    local STICKY, TAZER, BLAST = "techies_sticky_bomb", "techies_reactive_tazer", "techies_suicide"
    local MINES, MAD, DETONATE = "techies_land_mines", "techies_mutually_assured_destruction", "techies_tazer_detonate"
    local SIGN, PLANT, MAD_DETONATE = "techies_minefield_sign", "techies_mad_plant", "techies_mad_detonate"
    local UNIT_CAST_POINT = 0.3       -- "ucpt" of every hero, see gen_objects.py
    local MINE_CHARGES = 3            -- techies_land_mines AbilityCharges (Dota KV, not in heroes.json)
    local MAD_REGEN_PER_LEVEL = 0.01  -- bonus_mana_as_mana_regen "hero_levelup" (Dota KV)
    local MAD_CHARGE_HP = 200         -- npc_dota_techies_innate_mine StatusHealth (Dota npc_units)
    local SIGN_FX = "Abilities\\Spells\\Other\\TalkToMe\\TalkToMe.mdl"
    local BOMB = "Abilities\\Weapons\\Mortar\\MortarMissile.mdl"
    local BLAST_HEIGHT = 350
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

    local zloc = nil
    local function groundZ(x, y)
        if not zloc then zloc = Location(0, 0) end
        MoveLocation(zloc, x, y)
        return GetLocationZ(zloc)
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

    -- Keeps scripted movement inside the map (SetUnitX outside it crashes WC3).
    local function clampToMap(x, y)
        local b = use("data.mapdata").bounds
        local lo, hi = b.min + 192, b.max - 192
        return U.clamp(x, lo, hi), U.clamp(y, lo, hi)
    end

    ---------------------------------------------------------------- state
    local techies = {}        -- Techies seen (M.A.D. holders)
    local mines = {}          -- mine -> {techies, level, armAt, near, hidden}
    local charges = {}        -- Techies -> {n, nextAt}
    local tazers = {}         -- Techies -> {holder -> true}
    local blasting = {}       -- Techies -> pending Blast Off
    local loops = false
    local startLoops

    local function track(u)
        if u and not techies[u] then
            techies[u] = true
            startLoops()
        end
    end

    ---------------------------------------------------------------- Sticky Bomb
    local function stickyExplode(c, lvl, x, y, stuck)
        if stuck then Mods.remove(stuck, "techies_sticky_bomb") end
        fx(Fx.model("techies_mine_explode", "Abilities\\Spells\\Other\\Incinerate\\FireLordDeathExplode.mdl"), x, y)
        local dmg = A.value(STICKY, "damage", lvl, c)
        local slow = A.value(STICKY, "secondary_slow", lvl, c) / 100
        local duration = A.value(STICKY, "secondary_slow_duration", lvl, c)
        for _, t in ipairs(U.enemiesOf(GetOwningPlayer(c), x, y, A.value(STICKY, "explosion_radius", lvl, c))) do
            Damage.deal(c, t, dmg, "magical")
            if U.alive(t) and not U.isMagicImmune(t) then
                Mods.add(t, "techies_sticky_bomb_slow", {duration = duration, source = c, debuff = true,
                    props = {move_pct = -slow}})
            end
        end
    end

    -- Stuck to a hero: it slows the hero and blows up after the countdown.
    local function stick(c, lvl, e, hero)
        DestroyEffect(e)
        local countdown = A.value(STICKY, "countdown", lvl, c)
        Mods.add(hero, "techies_sticky_bomb", {duration = countdown + 0.1, source = c, debuff = true,
            props = {move_pct = -A.value(STICKY, "slow", lvl, c) / 100}, effect = BOMB, attach = "chest"})
        -- remember where the hero was last seen alive: the bomb blows up there
        local lx, ly = GetUnitX(hero), GetUnitY(hero)
        local done = false
        Timer.onFrame(function()
            if done then return true end
            if U.alive(hero) then lx, ly = GetUnitX(hero), GetUnitY(hero) end
            return false
        end)
        Timer.after(countdown, function()
            done = true
            if U.alive(hero) then lx, ly = GetUnitX(hero), GetUnitY(hero) end
            stickyExplode(c, lvl, lx, ly, hero)
        end)
    end

    -- Landed: chase the nearest enemy hero in range, else wait and explode.
    local function landed(c, lvl, e, x, y)
        local best = nil
        for _, h in ipairs(U.enemiesOf(GetOwningPlayer(c), x, y, A.value(STICKY, "radius", lvl, c))) do
            if U.isHero(h) and not U.isMagicImmune(h) then
                if not best or U.dist(x, y, GetUnitX(h), GetUnitY(h)) < U.dist(x, y, GetUnitX(best), GetUnitY(best)) then
                    best = h
                end
            end
        end
        if not best then
            Timer.after(A.value(STICKY, "countdown", lvl, c), function()
                DestroyEffect(e)
                stickyExplode(c, lvl, x, y, nil)
            end)
            return
        end
        local speed, accel = A.value(STICKY, "speed", lvl, c), A.value(STICKY, "acceleration", lvl, c)
        local wait, maxChase = A.value(STICKY, "pre_chase_time", lvl, c), A.value(STICKY, "max_chase_time", lvl, c)
        local bx, by, age = x, y, 0
        Timer.onFrame(function(dt)
            age = age + dt
            if age < wait then return false end
            if not U.alive(best) or age > wait + maxChase then
                DestroyEffect(e)
                stickyExplode(c, lvl, bx, by, nil)
                return true
            end
            speed = speed + accel * dt
            local hx, hy = GetUnitX(best), GetUnitY(best)
            local d, step = U.dist(bx, by, hx, hy), speed * dt
            if d <= step + 32 then
                stick(c, lvl, e, best)
                return true
            end
            local a = U.angle(bx, by, hx, hy)
            bx, by = bx + step * math.cos(a), by + step * math.sin(a)
            BlzSetSpecialEffectPosition(e, bx, by, groundZ(bx, by) + 20)
            return false
        end)
    end

    A.define(STICKY, {
        onCast = function(ctx)
            local c, lvl = ctx.caster, ctx.level
            track(c)
            local sx, sy, tx, ty = GetUnitX(c), GetUnitY(c), ctx.x, ctx.y
            local flight = math.max(0.1, ctx.v("duration"))
            local e = AddSpecialEffect(BOMB, sx, sy)
            local t = 0
            -- lobbed in an arc over `duration` seconds
            Timer.onFrame(function(dt)
                t = t + dt
                local p = math.min(1, t / flight)
                local x, y = sx + (tx - sx) * p, sy + (ty - sy) * p
                BlzSetSpecialEffectPosition(e, x, y, groundZ(x, y) + 20 + 4 * 300 * p * (1 - p))
                if p >= 1 then
                    landed(c, lvl, e, x, y)
                    return true
                end
                return false
            end)
        end,
    })

    ---------------------------------------------------------------- Reactive Tazer
    local function tazerExplode(m)
        local holder, c = m.unit, m.techies
        local x, y = GetUnitX(holder), GetUnitY(holder)
        fx("Abilities\\Spells\\Human\\Thunderclap\\ThunderClapCaster.mdl", x, y)
        for _, t in ipairs(U.enemiesOf(GetOwningPlayer(c), x, y, m.radius)) do
            Damage.deal(c, t, m.damage, "magical")
            if U.alive(t) and not U.isMagicImmune(t) then
                Mods.add(t, "techies_tazer_disarm", {duration = m.disarm, source = c, debuff = true,
                    props = {disarm = true},
                    effect = "Abilities\\Spells\\Orc\\Purge\\PurgeBuffTarget.mdl", attach = "overhead"})
            end
        end
    end

    local function tazerGone(c, holder)
        local list = tazers[c]
        if list and holder then list[holder] = nil end
        if not list or next(list) == nil then
            -- deferred: this may run inside Detonate's own cast event
            Timer.after(0, function()
                local id = A.id(DETONATE)
                if id and GetUnitAbilityLevel(c, id) > 0 and (tazers[c] == nil or next(tazers[c]) == nil) then
                    UnitRemoveAbility(c, id)
                    BlzUnitHideAbility(c, A.id(TAZER), false)
                end
            end)
        end
    end

    -- As in Dota, Detonate takes Tazer's button (W) while a charge is out.
    local function showDetonate(c)
        Timer.after(0, function()
            local id = A.id(DETONATE)
            if id and GetUnitAbilityLevel(c, id) == 0 and tazers[c] and next(tazers[c]) then
                UnitAddAbility(c, id)
                BlzUnitHideAbility(c, A.id(TAZER), true)
            end
        end)
    end

    A.define(TAZER, {
        onCast = function(ctx)
            local c, t = ctx.caster, ctx.target or ctx.caster
            track(c)
            local m = Mods.add(t, "techies_tazer", {duration = ctx.v("duration"), source = c,
                props = {move_pct = ctx.v("bonus_ms") / 100},
                effect = "Abilities\\Spells\\Orc\\LightningShield\\LightningShieldTarget.mdl", attach = "origin",
                -- expires or detonated: explode; a dispel just removes it
                onRemove = function(mod, expired)
                    if expired or mod.detonate then tazerExplode(mod) end
                    tazerGone(mod.techies, mod.unit)
                end})
            if not m then return end
            m.techies, m.detonate = c, false
            m.damage, m.disarm, m.radius = ctx.v("damage"), ctx.v("disarm_duration"), ctx.v("explosion_radius")
            tazers[c] = tazers[c] or {}
            tazers[c][t] = true
            showDetonate(c)
        end,
    })

    -- Detonate Tazer: blows up every charge this Techies has out right now.
    A.define(DETONATE, {
        onCast = function(ctx)
            local c = ctx.caster
            for holder in pairs(tazers[c] or {}) do
                local m = Mods.get(holder, "techies_tazer")
                if m and m.techies == c then
                    m.detonate = true
                    Mods.remove(holder, "techies_tazer")
                end
            end
            tazerGone(c, nil)
        end,
    })

    -- Enemies attacking a charged ally get zapped, disarmed and dispelled.
    Events.on("attacked", function(attacker, target)
        local m = Mods.get(target, "techies_tazer")
        if not m or not m.techies or not IsUnitEnemy(attacker, GetOwningPlayer(m.techies)) then return end
        if Mods.has(attacker, "techies_tazer_disarm") then return end
        fxOn("Abilities\\Spells\\Orc\\SpiritLink\\SpiritLinkZapTarget.mdl", attacker, "chest")
        Damage.deal(m.techies, attacker, m.damage, "magical")
        if U.alive(attacker) and not U.isMagicImmune(attacker) then
            Mods.dispel(attacker, {buffs = true})
            UnitRemoveBuffs(attacker, true, false)
            Mods.add(attacker, "techies_tazer_disarm", {duration = m.disarm, source = m.techies, debuff = true,
                props = {disarm = true},
                effect = "Abilities\\Spells\\Orc\\Purge\\PurgeBuffTarget.mdl", attach = "overhead"})
        end
    end)

    ---------------------------------------------------------------- Blast Off!
    -- Dota's 1 s cast point is a Channel follow-through; the leap starts once
    -- it completes and an interrupted cast is refunded.
    local function blastTime(c, lvl)
        return A.value(BLAST, "AbilityCastPoint", lvl, c) - UNIT_CAST_POINT
    end

    local function land(c, lvl, x, y)
        SetUnitFlyHeight(c, GetUnitDefaultFlyHeight(c), 0)
        Mods.remove(c, "techies_blast_off")
        SetUnitPosition(c, x, y)
        fx("Objects\\Spawnmodels\\Human\\HCancelDeath\\HCancelDeath.mdl", x, y)
        local radius = A.value(BLAST, "radius", lvl, c)
        local dmg, stun = A.value(BLAST, "damage", lvl, c), A.value(BLAST, "stun_duration", lvl, c)
        for _, t in ipairs(U.enemiesOf(GetOwningPlayer(c), x, y, radius)) do
            Damage.deal(c, t, dmg, "magical")
            if U.alive(t) and not U.isMagicImmune(t) then
                Mods.add(t, "techies_blast_off_stun", {duration = stun, source = c, debuff = true, dispel = "strong",
                    props = {stun = true},
                    effect = "Abilities\\Spells\\Human\\Thunderclap\\ThunderclapTarget.mdl", attach = "overhead"})
            end
        end
        -- only the landing spot is cleared of trees, not the whole blast radius
        for _, d in ipairs(treesIn(x, y, math.min(radius, 175))) do KillDestructable(d) end
        -- pure, non-lethal self damage from current health
        local hp = GetWidgetLife(c)
        SetWidgetLife(c, math.max(1, hp - hp * A.value(BLAST, "hp_cost", lvl, c) / 100))
    end

    local function leap(c, lvl, tx, ty)
        tx, ty = clampToMap(tx, ty)
        local sx, sy = GetUnitX(c), GetUnitY(c)
        local duration = math.max(0.1, A.value(BLAST, "duration", lvl, c))
        UnitAddAbility(c, FourCC("Amrf"))
        UnitRemoveAbility(c, FourCC("Amrf"))
        Mods.add(c, "techies_blast_off", {duration = duration + 0.25, dispel = "none", props = {stun = true}})
        local base = GetUnitDefaultFlyHeight(c)
        local t = 0
        Timer.onFrame(function(dt)
            if not U.alive(c) then
                SetUnitFlyHeight(c, base, 0)
                return true
            end
            t = t + dt
            local p = math.min(1, t / duration)
            SetUnitX(c, sx + (tx - sx) * p)
            SetUnitY(c, sy + (ty - sy) * p)
            SetUnitFlyHeight(c, base + 4 * BLAST_HEIGHT * p * (1 - p), 0)
            if p >= 1 then
                land(c, lvl, tx, ty)
                return true
            end
            return false
        end)
    end

    A.define(BLAST, {
        onChannel = function(ctx)
            if Mods.flag(ctx.caster, "root") then cancel(ctx.caster, "Rooted") end
        end,
        onCast = function(ctx)
            local c = ctx.caster
            track(c)
            blasting[c] = {start = Timer.now(), x = ctx.x, y = ctx.y}
        end,
        onEndCast = function(ctx)
            local c = ctx.caster
            local p = blasting[c]
            if not p then return end
            blasting[c] = nil
            if Timer.now() - p.start < blastTime(c, ctx.level) - 0.1 then
                refund(ctx)
                return
            end
            if U.alive(c) then leap(c, ctx.level, p.x, p.y) end
        end,
    })

    ---------------------------------------------------------------- Proximity Mines
    local function charge(c)
        local ch = charges[c]
        if not ch then
            ch = {n = MINE_CHARGES, nextAt = nil}
            charges[c] = ch
        end
        return ch
    end

    -- Aghanim's Scepter: + cast_range_scepter_bonus cast range.
    local function minesRange(c)
        local id = A.id(MINES)
        if id then
            A.setRangeBonus(c, id, "scepter", A.value(MINES, "cast_range_scepter_bonus", math.max(1, level(c, MINES)), c))
        end
    end

    ---------------------------------------------------------------- Minefield Sign
    -- Aghanim's Scepter (Dota 7.41 techies_minefield_sign): one sign per
    -- Techies for `lifetime` seconds. Proximity Mines within aura_radius of it
    -- are invulnerable and deal bonus_mine_damage_pct % more. An enemy hero
    -- within trigger_radius turns the area into a minefield for
    -- minefield_duration seconds: enemy heroes in it take scepter_move_damage
    -- for every scepter_move_amt units they move. Then the sign is gone.
    local signs = {}          -- Techies -> {unit, fx, x, y, endsAt, field = {hero -> {x, y, moved}}}

    local function removeSign(c)
        local s = signs[c]
        if not s then return end
        signs[c] = nil
        DestroyEffect(s.fx)
        if U.alive(s.unit) then RemoveUnit(s.unit) end
    end

    local function signCovers(c, x, y)
        local s = signs[c]
        return s ~= nil and U.alive(s.unit) and U.dist(x, y, s.x, s.y) <= A.value(SIGN, "aura_radius", 1, c)
    end

    A.define(SIGN, {
        onCast = function(ctx)
            local c = ctx.caster
            track(c)
            local code = use("data.ids").units.techies_mine
            if not code then return end
            removeSign(c)
            local sign = CreateUnit(ctx.owner, FourCC(code), ctx.x, ctx.y, 270)
            UnitRemoveAbility(sign, FourCC("Apiv"))      -- a sign stands in plain sight
            signs[c] = {unit = sign, fx = AddSpecialEffectTarget(SIGN_FX, sign, "overhead"), x = ctx.x, y = ctx.y,
                        endsAt = Timer.now() + ctx.v("lifetime")}
        end,
    })

    local function signTick(c, s, now)
        if not U.alive(s.unit) or now >= s.endsAt then
            removeSign(c)
            return
        end
        local owner = GetOwningPlayer(c)
        if not s.field then
            for _, h in ipairs(U.enemiesOf(owner, s.x, s.y, A.value(SIGN, "trigger_radius", 1, c))) do
                if U.isHero(h) then
                    s.field, s.endsAt = {}, now + A.value(SIGN, "minefield_duration", 1, c)
                    fx("Abilities\\Spells\\Human\\Thunderclap\\ThunderClapCaster.mdl", s.x, s.y)
                    break
                end
            end
            if not s.field then return end
        end
        local step, dmg = A.value(SIGN, "scepter_move_amt", 1, c), A.value(SIGN, "scepter_move_damage", 1, c)
        local inside = {}
        for _, h in ipairs(U.enemiesOf(owner, s.x, s.y, A.value(SIGN, "aura_radius", 1, c))) do
            if U.isHero(h) then
                inside[h] = true
                local hx, hy = GetUnitX(h), GetUnitY(h)
                local m = s.field[h]
                if m then
                    m.moved = m.moved + U.dist(m.x, m.y, hx, hy)
                    m.x, m.y = hx, hy
                    local n = step > 0 and math.floor(m.moved / step) or 0
                    if n > 0 then
                        m.moved = m.moved - n * step
                        Damage.deal(c, h, n * dmg, "magical")
                    end
                else
                    s.field[h] = {x = hx, y = hy, moved = 0}
                end
            end
        end
        for h in pairs(s.field) do
            if not inside[h] then s.field[h] = nil end
        end
    end

    ---------------------------------------------------------------- mines
    local function mineExplode(mine, info)
        mines[mine] = nil
        local lvl, c = info.level, info.techies
        local x, y = GetUnitX(mine), GetUnitY(mine)
        local radius, full = A.value(MINES, "radius", lvl, c), A.value(MINES, "min_distance", lvl, c)
        local outer = A.value(MINES, "outer_damage", lvl, c) / 100
        local dmg = A.value(MINES, "damage", lvl, c)
        if signCovers(c, x, y) then dmg = dmg * (1 + A.value(SIGN, "bonus_mine_damage_pct", 1, c) / 100) end
        local building = A.value(MINES, "building_damage_pct", lvl, c) / 100
        local mres, burn = A.value(MINES, "mres_reduction", lvl, c) / 100, A.value(MINES, "burn_duration", lvl, c)
        fx(Fx.model("techies_mine_explode", "Abilities\\Spells\\Other\\Incinerate\\FireLordDeathExplode.mdl"), x, y)
        for _, t in ipairs(U.enemiesOf(GetOwningPlayer(mine), x, y, radius, true)) do
            -- full damage near the mine, falling to outer_damage % at the edge
            local d = U.dist(x, y, GetUnitX(t), GetUnitY(t))
            local f = 1
            if d > full then f = 1 - (1 - outer) * (d - full) / math.max(1, radius - full) end
            if U.isStructure(t) then f = f * building end
            Damage.deal(c, t, dmg * f, "magical")
            if U.alive(t) and not U.isStructure(t) and not U.isMagicImmune(t) then
                Mods.add(t, "techies_mine_burn", {duration = burn, source = c, debuff = true,
                    props = {magic_resist = -mres}})
            end
        end
        KillUnit(mine)
    end

    local planted = {}        -- Techies -> planted M.A.D. charge (Aghanim's Shard)
    local madButtons, madDetonateNear

    local function mineTick()
        local now = Timer.now()
        local DT = 0.1
        for mine, info in pairs(mines) do
            if not U.alive(mine) then
                mines[mine] = nil
            else
                local guarded = signCovers(info.techies, GetUnitX(mine), GetUnitY(mine))
                if guarded ~= (info.guarded == true) then
                    info.guarded = guarded
                    SetUnitInvulnerable(mine, guarded)
                end
                if now >= info.armAt then
                    local lvl, c = info.level, info.techies
                    local near = #U.enemiesOf(GetOwningPlayer(mine), GetUnitX(mine), GetUnitY(mine),
                        A.value(MINES, "radius", lvl, c)) > 0
                    -- invisible unless an enemy is inside its radius
                    if near and info.hidden then
                        UnitRemoveAbility(mine, FourCC("Apiv"))
                        info.hidden = false
                    elseif not near and not info.hidden then
                        UnitAddAbility(mine, FourCC("Apiv"))
                        info.hidden = true
                    end
                    info.near = near and info.near + DT or 0
                    if info.near >= A.value(MINES, "proximity_threshold", lvl, c) - 0.01 then
                        mineExplode(mine, info)
                    end
                end
            end
        end
        -- charges come back one at a time
        for c, ch in pairs(charges) do
            if ch.nextAt and now >= ch.nextAt then
                ch.n = ch.n + 1
                local lvl = math.max(1, level(c, MINES))
                ch.nextAt = ch.n < MINE_CHARGES and now + A.value(MINES, "AbilityChargeRestoreTime", lvl, c) or nil
                local id = A.id(MINES)
                if ch.n == 1 and id then BlzEndUnitAbilityCooldown(c, id) end
            end
        end
        for c, s in pairs(signs) do signTick(c, s, now) end
        for c, m in pairs(planted) do
            if not U.alive(m) then
                planted[c] = nil
                madButtons(c)
            else
                madDetonateNear(c, m)
            end
        end
    end

    A.define(MINES, {
        onLearn = function(hero)
            track(hero)
            charge(hero)
            minesRange(hero)
        end,
        onChannel = function(ctx)
            local c = ctx.caster
            if charge(c).n <= 0 then
                cancel(c, "No mine charges")
                return
            end
            local r = ctx.v("placement_radius")
            for mine in pairs(mines) do
                if U.alive(mine) and U.dist(ctx.x, ctx.y, GetUnitX(mine), GetUnitY(mine)) < r then
                    cancel(c, "Too close to another mine")
                    return
                end
            end
        end,
        onCast = function(ctx)
            local c = ctx.caster
            track(c)
            local code = use("data.ids").units.techies_mine
            if not code then return end
            local mine = CreateUnit(ctx.owner, FourCC(code), ctx.x, ctx.y, 270)
            mines[mine] = {techies = c, level = ctx.level, armAt = Timer.now() + ctx.v("activation_delay"),
                near = 0, hidden = true}
            local ch = charge(c)
            ch.n = ch.n - 1
            if not ch.nextAt then ch.nextAt = Timer.now() + ctx.v("AbilityChargeRestoreTime") end
            if ch.n <= 0 then
                -- the engine sets its own (zero) cooldown after this event
                Timer.after(0, function()
                    BlzStartUnitAbilityCooldown(c, ctx.def.id, math.max(0.1, ch.nextAt - Timer.now()))
                end)
            end
        end,
    })

    Events.on("scepter", function(hero)
        if techies[hero] then minesRange(hero) end
    end)

    ---------------------------------------------------------------- M.A.D.
    local madRegen = {}

    local function madTick()
        for u in pairs(techies) do
            if U.alive(u) and level(u, MAD) > 0 then
                local pct = A.value(MAD, "bonus_mana_as_mana_regen", 1, u) + MAD_REGEN_PER_LEVEL * GetHeroLevel(u)
                local regen = BlzGetUnitMaxMana(u) * pct / 100
                if madRegen[u] ~= regen then
                    madRegen[u] = regen
                    Mods.add(u, "techies_mad", {persist = true, dispel = "none", props = {mana_regen = regen}})
                end
            end
        end
    end

    -- base_damage + max_mana_pct_as_damage % of Techies' max mana (+10 % with
    -- the Shard, through the value lookup).
    local function madDamage(c)
        return A.value(MAD, "base_damage", 1, c)
            + BlzGetUnitMaxMana(c) * A.value(MAD, "max_mana_pct_as_damage", 1, c) / 100
    end

    local function madBlast(c, owner, x, y, dmg)
        fx("Objects\\Spawnmodels\\Human\\HCancelDeath\\HCancelDeath.mdl", x, y)
        for _, t in ipairs(U.enemiesOf(owner, x, y, A.value(MAD, "radius", 1, c))) do
            Damage.deal(c, t, dmg, "magical")
        end
    end

    -- Dying leaves a barrel that blows up a moment later.
    Events.on("death", function(dying)
        if not techies[dying] or level(dying, MAD) <= 0 or IsUnitIllusion(dying) then return end
        local x, y = GetUnitX(dying), GetUnitY(dying)
        local dmg, owner = madDamage(dying), GetOwningPlayer(dying)
        local barrel = AddSpecialEffect("Units\\Other\\TNTBarrel\\TNTBarrel.mdl", x, y)
        Timer.after(A.value(MAD, "explosion_delay", 1, dying), function()
            DestroyEffect(barrel)
            madBlast(dying, owner, x, y, dmg)
        end)
    end)

    -- Aghanim's Shard (Dota 7.41): M.A.D. turns active, with the cooldown and
    -- cast range of its Shard values, and plants one charge
    -- (npc_dota_techies_innate_mine) that Detonate M.A.D. sets off. Detonate
    -- takes M.A.D.'s button while the charge is out. Not confirmed from Dota's
    -- code: the planted charge goes off at once, without the death barrel's
    -- explosion_delay, and stays invisible like a Proximity Mine.
    madButtons = function(c)
        local mad, plant, det = A.id(MAD), A.id(PLANT), A.id(MAD_DETONATE)
        if not (mad and plant and det) or level(c, MAD) <= 0 or not use("talents").hasShard(c) then return end
        if GetUnitAbilityLevel(c, plant) == 0 then
            UnitAddAbility(c, plant)
            UnitMakeAbilityPermanent(c, true, plant)
            BlzSetUnitAbilityCooldown(c, plant, 0, A.value(MAD, "AbilityCooldown", 1, c))
            local ab = BlzGetUnitAbility(c, plant)
            if ab then BlzSetAbilityRealLevelField(ab, ABILITY_RLF_CAST_RANGE, 0, A.value(MAD, "AbilityCastRange", 1, c)) end
            BlzUnitHideAbility(c, mad, true)
        end
        local out = planted[c] ~= nil
        if out and GetUnitAbilityLevel(c, det) == 0 then
            UnitAddAbility(c, det)
            UnitMakeAbilityPermanent(c, true, det)
            BlzUnitHideAbility(c, plant, true)
        elseif not out and GetUnitAbilityLevel(c, det) > 0 then
            UnitRemoveAbility(c, det)
            BlzUnitHideAbility(c, plant, false)
        end
    end

    local function isBotOwned(u)
        local slot = GetPlayerId(GetOwningPlayer(u))
        return slot <= SLOT_WARCRAFT and use("roles").isBot(slot)
    end

    -- Bots set their charge off once an enemy hero stands in its radius.
    madDetonateNear = function(c, m)
        local det = A.id(MAD_DETONATE)
        if not det or GetUnitAbilityLevel(c, det) == 0 or not U.alive(c) or not isBotOwned(c) then return end
        for _, h in ipairs(U.enemiesOf(GetOwningPlayer(c), GetUnitX(m), GetUnitY(m), A.value(MAD, "radius", 1, c))) do
            if U.isHero(h) then
                IssueImmediateOrder(c, use("data.ids").orders[MAD_DETONATE] or "")
                return
            end
        end
    end

    A.define(PLANT, {
        onCast = function(ctx)
            local c = ctx.caster
            track(c)
            local code = use("data.ids").units.techies_mine
            if not code then return end
            local old = planted[c]
            if old and U.alive(old) then RemoveUnit(old) end
            local m = CreateUnit(ctx.owner, FourCC(code), ctx.x, ctx.y, 270)
            BlzSetUnitMaxHP(m, MAD_CHARGE_HP)
            SetWidgetLife(m, MAD_CHARGE_HP)
            planted[c] = m
            -- deferred: hiding a button inside its own cast event is unsafe
            Timer.after(0, function() madButtons(c) end)
        end,
    })

    A.define(MAD_DETONATE, {
        onCast = function(ctx)
            local c = ctx.caster
            local m = planted[c]
            planted[c] = nil
            if m and U.alive(m) then
                madBlast(c, GetOwningPlayer(c), GetUnitX(m), GetUnitY(m), madDamage(c))
                RemoveUnit(m)
            end
            Timer.after(0, function() madButtons(c) end)
        end,
    })

    Events.on("shard", function(hero)
        if techies[hero] then madButtons(hero) end
    end)

    Events.on("hero_spawned", function(u, key)
        if key == "techies" then track(u) end
    end)

    startLoops = function()
        if loops then return end
        loops = true
        Timer.every(0.1, mineTick)
        Timer.every(1.0, madTick)
    end

    ---------------------------------------------------------------- bots
    Bots.hint(STICKY, {target = "enemyHero", point = true})
    Bots.hint(TAZER, {target = "self", radius = 500, minEnemies = 1})
    Bots.hint(BLAST, {target = "enemyHero", point = true})
    Bots.hint(MINES, {target = "point"})
    Bots.hint(DETONATE, {target = "none", radius = 400, minEnemies = 2})
    Bots.hint(SIGN, {target = "point"})
    Bots.hint(PLANT, {target = "enemyHero", point = true})

    -- exposed for tests
    T.mines, T.charges, T.mineTick, T.madTick, T.leap, T.mineExplode = mines, charges, mineTick, madTick, leap, mineExplode
    T.signs, T.planted = signs, planted
    return T
end)
