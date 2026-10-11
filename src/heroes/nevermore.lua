-- Shadow Fiend (npc_dota_hero_nevermore): Shadowraze x3, Feast of Souls
-- (nevermore_frenzy), Presence of the Dark Lord, Requiem of Souls and the
-- innate Necromastery, using the Dota 2 values from data.heroes. Values are
-- read with the caster, so its talents, Aghanim's Scepter (Requiem lines fly
-- back and heal) and Aghanim's Shard (Shadowraze slow and cooldown) apply
-- (src/game/talents.lua).
-- WC3 objects: specs/heroes/nevermore.json.
define("hero_nevermore", function()
    local A = use("abilities")
    local Mods = use("mods")
    local Damage = use("damage")
    local Timer = use("timer")
    local Events = use("events")
    local U = use("util")
    local Bots = use("bots")
    local M = {units = {}}

    local RAZES = {"nevermore_shadowraze1", "nevermore_shadowraze2", "nevermore_shadowraze3"}
    local FEAST, PRESENCE = "nevermore_frenzy", "nevermore_dark_lord"
    local REQUIEM, NECRO = "nevermore_requiem", "nevermore_necromastery"

    -- Requiem's damage per line is the KV's AbilityDamage, which data.heroes
    -- does not carry; used when A.value finds nothing.
    local REQUIEM_DAMAGE = {80, 120, 160}
    -- Necromastery damage per soul rises by this much every SOUL_LEVELS hero
    -- levels (Dota "hero_levelup"/"levelup_interval", not in data.heroes).
    local SOUL_DAMAGE_STEP, SOUL_LEVELS = 0.8, 6
    local UNIT_CAST_POINT = 0.3       -- "ucpt" of every hero, see gen_objects.py

    local Fx = use("fx")
    local FX = {
        raze = Fx.model("nevermore_shadowraze", "Abilities\\Spells\\Other\\Doom\\DoomDeath.mdl"),
        soul = "Abilities\\Weapons\\AvengerMissile\\AvengerMissile.mdl",
        feast = "Abilities\\Spells\\Undead\\UnholyFrenzy\\UnholyFrenzyTarget.mdl",
        charge = "Abilities\\Spells\\Undead\\DarkRitual\\DarkRitualCaster.mdl",
        burst = Fx.model("nevermore_requiem", "Abilities\\Spells\\Other\\HowlOfTerror\\HowlCaster.mdl"),
        line = "Abilities\\Spells\\Undead\\CarrionSwarm\\CarrionSwarmMissile.mdl",
        fear = "Abilities\\Spells\\Other\\HowlOfTerror\\HowlTarget.mdl",
    }

    local loc = Location(0, 0)
    local function groundZ(x, y)
        MoveLocation(loc, x, y)
        return GetLocationZ(loc)
    end

    local function level(u, name)
        return A.level(u, name)
    end

    local function botOwned(u)
        return use("roles").isBot(GetPlayerId(GetOwningPlayer(u)))
    end

    -- Souls -----------------------------------------------------------------------
    -- souls: Necromastery stacks (capped); linger: Feast souls kept after the
    -- feast for a while; feast: souls held during an active Feast of Souls.
    local state = {}

    local function st(u)
        local s = state[u]
        if not s then
            s = {souls = 0, linger = 0, lingering = {}}
            state[u] = s
        end
        return s
    end

    local function feastSouls(s)
        local n = 0
        if s.feast then
            for _, it in ipairs(s.feast.list) do n = n + it.n end
        end
        return n
    end

    function M.souls(u)
        local s = state[u]
        if not s then return 0 end
        return s.souls + s.linger + feastSouls(s)
    end

    local function maxSouls(u)
        return A.value(NECRO, "necromastery_max_souls", 1, u)
    end

    local function damagePerSoul(u)
        return A.value(NECRO, "necromastery_damage_per_soul", 1, u)
            + SOUL_DAMAGE_STEP * math.floor(GetHeroLevel(u) / SOUL_LEVELS)
    end

    local function refreshSouls(u)
        if not U.alive(u) or not M.units[u] then return end
        local bonus = M.souls(u) * damagePerSoul(u)
        local m = Mods.get(u, "nevermore_necromastery")
        if m and m.props.damage == bonus then return end
        Mods.add(u, "nevermore_necromastery", {source = u, persist = true, dispel = "none", props = {damage = bonus}})
    end

    -- A soul flying from (x, y) into Shadow Fiend.
    local function soulTo(x, y, u)
        local fx = AddSpecialEffect(FX.soul, x, y)
        Timer.onFrame(function(dt)
            if not U.alive(u) then
                DestroyEffect(fx)
                return true
            end
            local tx, ty = GetUnitX(u), GetUnitY(u)
            local step = 1000 * dt
            if U.dist(x, y, tx, ty) <= step + 24 then
                DestroyEffect(fx)
                return true
            end
            local a = U.angle(x, y, tx, ty)
            x, y = U.polar(x, y, step, a)
            BlzSetSpecialEffectPosition(fx, x, y, groundZ(x, y) + 80)
            BlzSetSpecialEffectYaw(fx, a)
            return false
        end)
    end

    local function gainSouls(u, n)
        if level(u, NECRO) <= 0 or Mods.flag(u, "break") then return false end
        local s = st(u)
        local cap = maxSouls(u)
        if s.souls >= cap then return false end
        s.souls = math.min(cap, s.souls + n)
        refreshSouls(u)
        return true
    end

    -- Feast of Souls -----------------------------------------------------------------
    local function endFeast(u, s, dropAll)
        local f = s.feast
        if not f then return end
        s.feast = nil
        f.timer:stop()
        if not dropAll then
            local kept = 0
            for _, it in ipairs(f.list) do
                if not U.alive(it.unit) then kept = kept + it.n end
            end
            if kept > 0 then
                local entry = {}
                s.lingering[entry] = true
                s.linger = s.linger + kept
                Timer.after(f.linger, function()
                    if not s.lingering[entry] then return end
                    s.lingering[entry] = nil
                    s.linger = s.linger - kept
                    s.souls = math.min(maxSouls(u), s.souls + kept)
                    refreshSouls(u)
                end)
            end
        end
        refreshSouls(u)
    end

    local function collect(u, s, f)
        if not U.alive(u) or s.feast ~= f then return end
        local owner = GetOwningPlayer(u)
        local x, y = GetUnitX(u), GetUnitY(u)
        local cands = {}
        for _, e in ipairs(U.enemiesOf(owner, x, y, f.radius)) do
            if not f.seen[e] and IsUnitVisible(e, owner) then
                cands[#cands + 1] = {unit = e, hero = IsUnitType(e, UNIT_TYPE_HERO),
                                     d = U.dist(x, y, GetUnitX(e), GetUnitY(e))}
            end
        end
        table.sort(cands, function(a, b)
            if a.hero ~= b.hero then return a.hero end
            return a.d < b.d
        end)
        local picked = 0
        for _, c in ipairs(cands) do
            if picked >= f.perInterval or f.count >= f.max then break end
            f.seen[c.unit] = true
            f.count = f.count + 1
            picked = picked + 1
            f.list[#f.list + 1] = {unit = c.unit, n = c.hero and f.perHero or f.perCreep}
            soulTo(GetUnitX(c.unit), GetUnitY(c.unit), u)
        end
        if picked > 0 then refreshSouls(u) end
    end

    -- Level 25 talent: Feast of Souls raises cast speed to cast_speed_pct %.
    -- SIMPLIFIED: heroes here share one unit cast point instead of Dota's
    -- per-ability ones; it shrinks by the same share.
    local function castSpeed(u, pct)
        local s = st(u)
        local cp = UNIT_CAST_POINT * 100 / math.max(1, pct)
        if (s.castPoint or UNIT_CAST_POINT) ~= cp then
            s.castPoint = cp
            BlzSetUnitRealField(u, UNIT_RF_CAST_POINT, cp)
        end
    end
    M.castPoint = function(u) return st(u).castPoint or UNIT_CAST_POINT end

    A.define(FEAST, {
        onCast = function(ctx)
            local u = ctx.caster
            M.register(u)
            local s = st(u)
            local dur = ctx.v("duration")
            Mods.add(u, "nevermore_frenzy", {duration = dur, source = u, effect = FX.feast, attach = "chest",
                                             props = {attack_speed = ctx.v("bonus_attack_speed"),
                                                      move_pct = ctx.v("bonus_move_speed") / 100},
                                             onRemove = function(mod) castSpeed(mod.unit, 100) end})
            castSpeed(u, ctx.v("cast_speed_pct"))
            endFeast(u, s, false)
            local f = {list = {}, seen = {}, count = 0, max = ctx.v("max_collection_count"),
                       radius = ctx.v("soul_collection_radius"), perInterval = ctx.v("soul_collection_per_interval"),
                       perHero = ctx.v("soul_collection_per_hero"), perCreep = ctx.v("soul_collection_per_creep"),
                       linger = ctx.v("linger_duration")}
            f.timer = Timer.every(math.max(0.1, ctx.v("soul_collection_interval")), function()
                if s.feast ~= f then return true end
                if not Mods.has(u, "nevermore_frenzy") then
                    endFeast(u, s, false)          -- expired or dispelled
                    return true
                end
                collect(u, s, f)
                return false
            end)
            s.feast = f
            collect(u, s, f)
        end,
    })

    -- Shadowraze ---------------------------------------------------------------------
    -- Average attack damage: base, dice, agility (primary) and green bonuses.
    local function attackDamage(u)
        return BlzGetUnitBaseDamage(u, 0) + BlzGetUnitDiceNumber(u, 0) * (BlzGetUnitDiceSides(u, 0) + 1) / 2
            + GetHeroAgi(u, true) + Mods.sum(u, "damage")
    end

    -- Aghanim's Shard (Dota 7.41): every stack also slows by
    -- movement_speed_debuff %, and each enemy hero hit takes
    -- cooldown_reduction_on_hero_hit seconds off this raze's cooldown.
    -- Level 25 talent (procs_attack): the raze also deals Shadow Fiend's
    -- attack damage. SIMPLIFIED: as physical damage, without attack effects.
    local function raze(ctx)
        local u = ctx.caster
        M.register(u)
        local x, y = U.polar(GetUnitX(u), GetUnitY(u), ctx.v("shadowraze_range"), math.rad(GetUnitFacing(u)))
        DestroyEffect(AddSpecialEffect(FX.raze, x, y))
        local base = ctx.v("shadowraze_damage") + ctx.v("damage_per_soul") * M.souls(u)
        local per, dur = ctx.v("stack_bonus_damage"), ctx.v("duration")
        local slow, attack = ctx.v("movement_speed_debuff") / 100, ctx.v("procs_attack") > 0
        local heroes = 0
        for _, e in ipairs(U.enemiesOf(ctx.owner, x, y, ctx.v("shadowraze_radius"))) do
            if not U.isMagicImmune(e) then
                local m = Mods.get(e, "nevermore_shadowraze")
                local n = m and m.stacks or 0
                Damage.deal(u, e, base + per * n, Damage.MAGICAL)
                if attack and U.alive(e) then Damage.deal(u, e, attackDamage(u), Damage.PHYSICAL, {noAmp = true}) end
                Mods.add(e, "nevermore_shadowraze", {duration = dur, stacks = n + 1, source = u, debuff = true,
                                                     props = slow > 0 and {move_pct = -slow * (n + 1)} or nil})
                if U.isHero(e) then heroes = heroes + 1 end
            end
        end
        local cut = ctx.v("cooldown_reduction_on_hero_hit") * heroes
        if cut > 0 then
            local id, li = ctx.castId or ctx.def.id, ctx.level - 1
            -- after the engine starts the cooldown of this cast
            Timer.after(0, function()
                BlzStartUnitAbilityCooldown(u, id, math.max(0, BlzGetUnitAbilityCooldown(u, id, li) - cut))
            end)
        end
    end

    -- Bots cannot aim a raze, so a bot-owned Shadow Fiend turns at cast start
    -- toward the enemy that best fits this raze's distance (heroes first).
    local function aim(ctx)
        local u = ctx.caster
        if not botOwned(u) then return end
        local range, r = ctx.v("shadowraze_range"), ctx.v("shadowraze_radius")
        local x, y = GetUnitX(u), GetUnitY(u)
        local best, bestScore = nil, math.huge
        for _, e in ipairs(U.enemiesOf(ctx.owner, x, y, range + r)) do
            if IsUnitVisible(e, ctx.owner) then
                local score = math.abs(U.dist(x, y, GetUnitX(e), GetUnitY(e)) - range)
                if score > r * 0.8 then score = score + 2000 end
                if IsUnitType(e, UNIT_TYPE_HERO) then score = score - 1000 end
                if score < bestScore then best, bestScore = e, score end
            end
        end
        if best then
            BlzSetUnitFacingEx(u, math.deg(U.angle(x, y, GetUnitX(best), GetUnitY(best))))
        end
    end

    -- One learnable raze (the first); the other two follow its level, as in
    -- Dota where the three buttons share one ability. WC3 heroes can learn at
    -- most five abilities, so this also makes room for Requiem.
    local function syncRazes(u)
        local lvl = level(u, RAZES[1])
        for i = 2, 3 do
            local id = A.id(RAZES[i])
            if id and GetUnitAbilityLevel(u, id) > 0 then
                if lvl > 0 then
                    SetUnitAbilityLevel(u, id, lvl)
                    BlzUnitHideAbility(u, id, false)
                    BlzUnitDisableAbility(u, id, false, false)
                else
                    BlzUnitDisableAbility(u, id, true, true)
                end
            end
        end
    end

    A.define(RAZES[1], {onChannel = aim, onCast = raze, onLearn = function(u) syncRazes(u) end})
    for i = 2, 3 do
        A.define(RAZES[i], {onChannel = aim, onCast = raze})
    end
    use("events").on("hero_spawned", function(u, key)
        if key == "nevermore" then syncRazes(u) end
    end)

    -- Presence of the Dark Lord (aura) ---------------------------------------------
    local function presence(u)
        local lvl = level(u, PRESENCE)
        if lvl <= 0 or not U.alive(u) or Mods.flag(u, "break") then return end
        local armor = A.value(PRESENCE, "presence_armor_reduction", lvl, u)
        local until_ = Timer.now() + 0.5
        for _, e in ipairs(U.enemiesOf(GetOwningPlayer(u), GetUnitX(u), GetUnitY(u),
                                       A.value(PRESENCE, "presence_radius", lvl, u))) do
            local m = Mods.get(e, "nevermore_presence")
            if m and m.props.armor == armor then
                m.expires = until_
            else
                Mods.add(e, "nevermore_presence", {duration = 0.5, source = u, debuff = true, dispel = "none",
                                                   props = {armor = armor}})
            end
        end
    end

    A.define(PRESENCE, {onLearn = function(u) M.register(u) end})

    -- Requiem of Souls ------------------------------------------------------------------
    local fearing = {}        -- feared unit -> Shadow Fiend it runs from
    local fearLoop = nil

    -- SIMPLIFIED: WC3 has no fear. Feared units are silenced and disarmed and
    -- re-ordered every 0.2 s to run away from Shadow Fiend.
    local function fear(e, src, dur, ms, mres)
        local m = Mods.get(e, "nevermore_requiem")
        if m and m.expires and m.expires >= Timer.now() + dur then return end
        Mods.add(e, "nevermore_requiem", {duration = dur, source = src, debuff = true, effect = FX.fear,
                                          attach = "overhead",
                                          props = {silence = true, disarm = true, move_pct = ms, magic_resist = mres}})
        fearing[e] = src
        if fearLoop then return end
        fearLoop = Timer.every(0.2, function()
            for t, from in pairs(fearing) do
                if not U.alive(t) or not Mods.has(t, "nevermore_requiem") then
                    fearing[t] = nil
                    if U.alive(t) then IssueImmediateOrder(t, "stop") end
                else
                    local a = U.angle(GetUnitX(from), GetUnitY(from), GetUnitX(t), GetUnitY(t))
                    local x, y = U.polar(GetUnitX(t), GetUnitY(t), 300, a)
                    IssuePointOrder(t, "move", x, y)
                end
            end
        end)
    end

    local function requiemDamage(u, lvl)
        local d = A.value(REQUIEM, "AbilityDamage", lvl, u)
        if d > 0 then return d end
        return REQUIEM_DAMAGE[math.max(1, math.min(#REQUIEM_DAMAGE, lvl))]
    end

    -- Aghanim's Scepter (Dota 7.41): the lines fly back into Shadow Fiend,
    -- each hitting a unit once more for requiem_damage_pct_scepter % of the
    -- damage, and heal him for requiem_heal_pct_scepter % of what they deal.
    -- Not confirmed from Dota's code: the way back does not fear, and a
    -- release on death does not come back.
    local function flyBack(u, set, radius, speed, w0, w1, dmg, heal)
        local owner = GetOwningPlayer(u)
        Timer.onFrame(function(dt)
            local ux, uy = GetUnitX(u), GetUnitY(u)
            local far = 0
            for _, ln in ipairs(set) do
                if not ln.done then far = math.max(far, U.dist(ln.x, ln.y, ux, uy)) end
            end
            local cands = U.enemiesOf(owner, ux, uy, far + w1)
            local left = 0
            for _, ln in ipairs(set) do
                if not ln.done then
                    local d, step = U.dist(ln.x, ln.y, ux, uy), speed * dt
                    if d <= step or not U.alive(u) then
                        ln.done = true
                        DestroyEffect(ln.fx)
                    else
                        local a = U.angle(ln.x, ln.y, ux, uy)
                        ln.x, ln.y = U.polar(ln.x, ln.y, step, a)
                        BlzSetSpecialEffectPosition(ln.fx, ln.x, ln.y, groundZ(ln.x, ln.y) + 60)
                        BlzSetSpecialEffectYaw(ln.fx, a)
                        local r = w0 + (w1 - w0) * math.min(1, d / radius)
                        for _, e in ipairs(cands) do
                            if not ln.hit[e] and U.alive(e) and U.dist(ln.x, ln.y, GetUnitX(e), GetUnitY(e)) <= r then
                                ln.hit[e] = true
                                local dealt = Damage.deal(u, e, dmg, Damage.MAGICAL)
                                if dealt > 0 and heal > 0 then Damage.heal(u, dealt * heal) end
                            end
                        end
                        left = left + 1
                    end
                end
            end
            return left == 0
        end)
    end

    -- Lines fan out evenly from Shadow Fiend; each hits a unit at most once,
    -- so units close to him are caught by several lines.
    local function release(u, lvl, lines, onDeath)
        if lines <= 0 or lvl <= 0 then return end
        local owner = GetOwningPlayer(u)
        local x0, y0 = GetUnitX(u), GetUnitY(u)
        local radius = math.max(1, A.value(REQUIEM, "requiem_radius", lvl, u))
        local speed = math.max(100, A.value(REQUIEM, "requiem_line_speed", lvl, u))
        local w0 = A.value(REQUIEM, "requiem_line_width_start", lvl, u)
        local w1 = A.value(REQUIEM, "requiem_line_width_end", lvl, u)
        local dmg = requiemDamage(u, lvl)
        local ms = A.value(REQUIEM, "requiem_reduction_ms", lvl, u) / 100
        local mres = A.value(REQUIEM, "requiem_reduction_mres", lvl, u) / 100
        local per = A.value(REQUIEM, "requiem_slow_duration", lvl, u)
        local cap = A.value(REQUIEM, "requiem_slow_duration_max", lvl, u)
        local back = onDeath and 0 or A.value(REQUIEM, "requiem_damage_pct_scepter", lvl, u) / 100
        local heal = A.value(REQUIEM, "requiem_heal_pct_scepter", lvl, u) / 100
        local face = math.rad(GetUnitFacing(u))
        local set = {}
        for i = 1, lines do
            local a = face + (i - 1) * 2 * math.pi / lines
            local fx = AddSpecialEffect(FX.line, x0, y0)
            BlzSetSpecialEffectYaw(fx, a)
            set[i] = {a = a, fx = fx, hit = {}}
        end
        DestroyEffect(AddSpecialEffect(FX.burst, x0, y0))
        local hits, dist = {}, 0
        Timer.onFrame(function(dt)
            dist = math.min(radius, dist + speed * dt)
            -- SIMPLIFIED: the KV line width is used as the projectile radius,
            -- as Dota's linear projectiles do
            local r = w0 + (w1 - w0) * dist / radius
            local cands = U.enemiesOf(owner, x0, y0, dist + r)
            for _, ln in ipairs(set) do
                local hx, hy = U.polar(x0, y0, dist, ln.a)
                ln.x, ln.y = hx, hy
                BlzSetSpecialEffectPosition(ln.fx, hx, hy, groundZ(hx, hy) + 60)
                for _, e in ipairs(cands) do
                    if not ln.hit[e] and U.alive(e) and U.dist(hx, hy, GetUnitX(e), GetUnitY(e)) <= r then
                        ln.hit[e] = true
                        Damage.deal(u, e, dmg, Damage.MAGICAL)
                        if not onDeath and U.alive(e) and not U.isMagicImmune(e) then
                            hits[e] = (hits[e] or 0) + 1
                            fear(e, u, math.min(cap, per * hits[e]), ms, mres)
                        end
                    end
                end
            end
            if dist >= radius then
                if back > 0 and U.alive(u) then
                    for _, ln in ipairs(set) do ln.hit = {} end
                    flyBack(u, set, radius, speed, w0, w1, dmg * back, heal)
                else
                    for _, ln in ipairs(set) do DestroyEffect(ln.fx) end
                end
                return true
            end
            return false
        end)
    end

    local function clearCharge(u)
        local s = state[u]
        if s and s.charge then
            DestroyEffect(s.charge)
            s.charge = nil
        end
    end

    A.define(REQUIEM, {
        onChannel = function(ctx)
            local u = ctx.caster
            M.register(u)
            clearCharge(u)
            local s = st(u)
            local fx = AddSpecialEffectTarget(FX.charge, u, "origin")
            s.charge = fx
            Timer.after(2.5, function()
                if s.charge == fx then clearCharge(u) end
            end)
        end,
        onCast = function(ctx)
            local u = ctx.caster
            clearCharge(u)
            local per = math.max(1, ctx.v("requiem_soul_conversion"))
            local lines = math.min(ctx.v("max_soul_release"), math.floor(M.souls(u) / per))
            release(u, ctx.level, lines, false)
        end,
        onEndCast = function(ctx)
            clearCharge(ctx.caster)
        end,
    })

    -- Necromastery (innate) and death -------------------------------------------------
    local function onOwnDeath(u)
        local s = st(u)
        local lvl = level(u, REQUIEM)
        local total = M.souls(u)
        if lvl > 0 and total > 0 then
            local lines = math.floor(math.min(total, A.value(REQUIEM, "max_soul_release", lvl, u))
                                     * A.value(REQUIEM, "soul_death_release", lvl, u))
            release(u, lvl, lines, true)
        end
        endFeast(u, s, true)
        s.lingering, s.linger = {}, 0
        s.souls = math.floor(s.souls * A.value(NECRO, "necromastery_soul_release", 1, u))
        clearCharge(u)
    end

    Events.on("death", function(dying, killer)
        if M.units[dying] then onOwnDeath(dying) end
        if killer and killer ~= dying and M.units[killer] and not IsUnitType(dying, UNIT_TYPE_STRUCTURE)
            and not IsUnitIllusion(dying) then
            local n = IsUnitType(dying, UNIT_TYPE_HERO) and A.value(NECRO, "souls_per_hero_kill", 1, killer)
                or A.value(NECRO, "souls_per_kill", 1, killer)
            if gainSouls(killer, n) then soulTo(GetUnitX(dying), GetUnitY(dying), killer) end
        end
    end)

    Events.on("hero_respawned", function(u)
        if M.units[u] then refreshSouls(u) end
    end)

    Events.on("hero_level", function(u)
        if M.units[u] then refreshSouls(u) end
    end)

    A.define(NECRO, {})

    -- Registration ------------------------------------------------------------------------
    local loop = nil
    function M.register(u)
        if not u or M.units[u] then return end
        M.units[u] = true
        st(u)
        -- Dota hides Necromastery; hiding it also frees the command card cell
        -- it would share with Presence of the Dark Lord.
        -- SIMPLIFIED: no soul counter in the UI; souls show as green damage.
        local necro = A.id(NECRO)
        if necro and GetUnitAbilityLevel(u, necro) > 0 then BlzUnitHideAbility(u, necro, true) end
        refreshSouls(u)
        if not loop then
            loop = Timer.every(0.25, function()
                for unit in pairs(M.units) do presence(unit) end
            end)
        end
    end

    Events.on("hero_spawned", function(u, key)
        if key == "nevermore" then M.register(u) end
    end)
    for u, key in pairs(use("heroes").keyOf) do
        if key == "nevermore" then M.register(u) end
    end

    -- Bot hints ------------------------------------------------------------------------------
    Bots.hint(RAZES[1], {target = "none", radius = 400})
    Bots.hint(RAZES[2], {target = "none", radius = 650})
    Bots.hint(RAZES[3], {target = "none", radius = 900})
    Bots.hint(FEAST, {target = "none", radius = 600})
    Bots.hint(REQUIEM, {target = "none", radius = 500, ultimate = true})

    return M
end)
