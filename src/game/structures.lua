-- Dota team buildings: towers, barracks, the Ancient, fountain and shop, all
-- owned by the buildings' slot outside the lobby (SLOT_BUILDINGS), which the
-- neutral camps leave alone (roles.lua). Dota's protection rules apply: a tower
-- stays invulnerable until the previous tier in its lane falls, barracks until
-- their tier-3 tower falls, tier-4 towers until any tier-3 tower falls, and the
-- Ancient until both tier-4 towers are down.
--
-- Glyph of Fortification, as Dota's own tooltip describes it
-- (DOTA_Tooltip_ability_fountain_glyph* in the player's abilities_english.txt):
-- the team's buildings turn invulnerable for 7 s and its lane creeps for 3 s,
-- towers past tier 1 hit 5 extra targets meanwhile, and the first tier 1
-- tower, the first tier 2 tower and the first melee barracks to fall each make
-- it ready at once. Cooldown 300 s, first ready 180 s after the horn
-- (https://teamsmurf.com/glyph-and-scan-micro-advantages-that-win-close-games/,
-- "verified for 7.41d"; these two are not in Dota's files).
define("structures", function()
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Damage = use("damage")
    local Mods = use("mods")
    local U = use("util")
    local S = {towers = {}, barracks = {}, ancient = nil, fountain = nil, shop = nil, glyphAt = nil, glyphEnds = 0}

    S.GLYPH = {buildings = 7, creeps = 3, extra = 5, cooldown = 300, first = 180}
    local GLYPH_FX = "Abilities\\Spells\\Human\\DivineShield\\DivineShieldTarget.mdl"
    local SHOT_FX = "Abilities\\Weapons\\GuardTowerMissile\\GuardTowerMissile.mdl"

    local kinds, tiers, lanes = {}, {}, {}   -- building -> "tower" | "rax" | "ancient", tower tier, lane
    local melee = {}          -- melee barracks -> true
    local locked = {}         -- building -> true while tier protection holds
    local guards = {}         -- building -> units that must die before it is vulnerable
    local hitAt = {}          -- building -> last time the commander's side damaged it
    local fallen = {}         -- "tower1" | "tower2" | "rax_melee" -> true once the first one fell
    local glyphFx = {}        -- building -> its Glyph shield effect
    local glyphGen = 0

    local function id(key) return FourCC(use("data.ids").units[key]) end

    local function create(key, pos, face)
        return CreateUnit(Player(SLOT_BUILDINGS), id(key), pos.x, pos.y, face or 225)
    end

    function S.glyphActive() return Timer.now() < S.glyphEnds end

    -- Invulnerable while tier protection holds or the Glyph lasts.
    local function apply(u)
        if U.alive(u) then SetUnitInvulnerable(u, locked[u] == true or S.glyphActive()) end
    end

    local function protect(u, deps)
        guards[u], locked[u] = deps, true
        apply(u)
    end

    local function open(u)
        guards[u], locked[u] = nil, nil
        apply(u)
    end

    local function refresh()
        for u, deps in pairs(guards) do
            for _, d in ipairs(deps) do
                if not U.alive(d) then
                    open(u)
                    break
                end
            end
        end
    end

    function S.kindOf(u) return u and kinds[u] end
    function S.tierOf(u) return u and tiers[u] end
    function S.laneOf(u) return u and lanes[u] end
    function S.isMeleeRax(u) return melee[u] == true end
    function S.lastHit(u) return hitAt[u] end

    -- Every tower, barracks and the Ancient, alive or not, in a fixed order.
    function S.buildings()
        local out = {}
        for _, lane in ipairs({"top", "mid", "bot", "base"}) do
            for _, t in ipairs(S.towers[lane] or {}) do out[#out + 1] = t end
            for _, b in ipairs(S.barracks[lane] or {}) do out[#out + 1] = b end
        end
        if S.ancient then out[#out + 1] = S.ancient end
        return out
    end

    -- The commander's side hit a base building (tier 3 or 4 tower, barracks,
    -- the Ancient) within the last `seconds`.
    function S.baseUnderAttack(seconds)
        local now = Timer.now()
        for _, u in ipairs(S.buildings()) do
            local base = kinds[u] ~= "tower" or (tiers[u] or 0) >= 3
            if base and hitAt[u] and now - hitAt[u] <= seconds and U.alive(u) then return true end
        end
        return false
    end

    function S.create()
        local m = use("data.mapdata").dota
        for _, lane in ipairs({"top", "mid", "bot"}) do
            local list = {}
            for tier, pos in ipairs(m.towers[lane]) do
                list[tier] = create("tower" .. tier, pos)
                kinds[list[tier]], tiers[list[tier]], lanes[list[tier]] = "tower", tier, lane
            end
            S.towers[lane] = list
            protect(list[2], {list[1]})
            protect(list[3], {list[2]})
            local rax = {create("rax_melee", m.barracks[lane][1], 270), create("rax_ranged", m.barracks[lane][2], 270)}
            S.barracks[lane] = rax
            for _, b in ipairs(rax) do kinds[b], lanes[b] = "rax", lane end
            melee[rax[1]] = true
            protect(rax[1], {list[3]})
            protect(rax[2], {list[3]})
        end
        local tier3 = {S.towers.top[3], S.towers.mid[3], S.towers.bot[3]}
        local t4 = {}
        for i, pos in ipairs(m.towers.base) do
            t4[i] = create("tower4", pos)
            kinds[t4[i]], tiers[t4[i]], lanes[t4[i]] = "tower", 4, "base"
            protect(t4[i], tier3)
        end
        S.towers.base = t4
        S.ancient = create("ancient", m.ancient, 225)
        kinds[S.ancient] = "ancient"
        locked[S.ancient] = true          -- opened by the tier-4 rule below, not by guards
        apply(S.ancient)
        S.fountain = create("fountain", m.fountain, 45)
        S.shop = create("shop", m.shop, 90)
        Events.on("death", function(dying)
            if guards[dying] then guards[dying] = nil end
            local key = (kinds[dying] == "tower" and (tiers[dying] == 1 or tiers[dying] == 2) and ("tower" .. tiers[dying]))
                or (melee[dying] and "rax_melee") or nil
            if key and not fallen[key] then
                fallen[key] = true
                S.glyphAt = Timer.now()
                Log.info("glyph ready again: the first " .. key .. " fell")
            end
            refresh()
            -- The Ancient opens once both tier-4 towers are dead
            if not U.alive(t4[1]) and not U.alive(t4[2]) and locked[S.ancient] then
                open(S.ancient)
                Log.info("ancient is now vulnerable")
            end
        end)
        Damage.onDamaged(function(source, target)
            if kinds[target] and source and use("roles").side(GetPlayerId(GetOwningPlayer(source))) == "commander" then
                hitAt[target] = Timer.now()
            end
        end)
        Damage.onDamaging(function(source, target, info)
            if info.attack and (tiers[source] or 0) >= 2 and S.glyphActive() then
                local amount = info.amount
                -- outside the damage event: nested damage would disturb the event's own numbers
                Timer.after(0, function() S.multishot(source, target, amount) end)
            end
        end)
        Log.info("structures created")
    end

    function S.count()
        local n = 0
        for _, lane in pairs(S.towers) do n = n + #lane end
        return n
    end

    -- ------------------------------------------------------------ Glyph

    local function readyAt()
        if S.glyphAt then return S.glyphAt end
        local horn = use("creeps").firstAt
        return horn and (horn + S.GLYPH.first) or math.huge
    end

    -- Seconds until the team's Glyph is ready (0: ready) and the full wait,
    -- for the HUD's cooldown sweep.
    function S.glyphLeft() return math.max(0, readyAt() - Timer.now()) end
    function S.glyphTotal() return math.max(S.glyphLeft(), S.glyphAt and S.GLYPH.cooldown or S.GLYPH.first) end

    -- The extra Glyph targets of a tower's attack: the 5 enemies nearest to
    -- it in its attack range, other than the one it hit.
    function S.multishot(tower, target, amount)
        if not U.alive(tower) or not S.glyphActive() then return 0 end
        local owner = GetOwningPlayer(tower)
        local x, y = GetUnitX(tower), GetUnitY(tower)
        local range = BlzGetUnitWeaponRealField(tower, UNIT_WEAPON_RF_ATTACK_RANGE, 0)
        if range <= 0 then range = use("data.world").towers["2"].range end
        local list = {}
        for _, e in ipairs(U.enemiesOf(owner, x, y, range)) do
            if e ~= target and IsUnitVisible(e, owner) then
                list[#list + 1] = {u = e, d = U.dist(x, y, GetUnitX(e), GetUnitY(e)), id = GetHandleId(e)}
            end
        end
        table.sort(list, function(a, b)
            if a.d ~= b.d then return a.d < b.d end
            return a.id < b.id
        end)
        local n = math.min(S.GLYPH.extra, #list)
        for i = 1, n do
            DestroyEffect(AddSpecialEffectTarget(SHOT_FX, list[i].u, "chest"))
            Damage.deal(tower, list[i].u, amount, Damage.PHYSICAL)
        end
        return n
    end

    -- A Dota hero player activates the team's Glyph. Synced code only.
    function S.glyph(p)
        if not use("roles").isHeroSlot(GetPlayerId(p)) then return false end
        local Lane = use("lane")
        if S.glyphLeft() > 0 then
            Lane.error(p, "dota_hud_error_cant_glyph")
            return false
        end
        local now = Timer.now()
        S.glyphAt = now + S.GLYPH.cooldown
        S.glyphEnds = now + S.GLYPH.buildings
        glyphGen = glyphGen + 1
        local gen = glyphGen
        for _, u in ipairs(S.buildings()) do
            if U.alive(u) then
                apply(u)
                if glyphFx[u] then DestroyEffect(glyphFx[u]) end
                glyphFx[u] = AddSpecialEffectTarget(GLYPH_FX, u, "origin")
            end
        end
        for _, c in ipairs(use("creeps").near(SLOT_ANCIENTS)) do
            Mods.add(c, "glyph", {duration = S.GLYPH.creeps, dispel = "none", props = {invulnerable = true},
                                  effect = GLYPH_FX, attach = "origin"})
        end
        Timer.after(S.GLYPH.buildings, function()
            if gen ~= glyphGen then return end
            S.glyphEnds = 0
            for _, u in ipairs(S.buildings()) do
                apply(u)
                if glyphFx[u] then
                    DestroyEffect(glyphFx[u])
                    glyphFx[u] = nil
                end
            end
        end)
        if defined("announcer") then use("announcer").say("fort_rad", 2) end
        Lane.chat("DOTA_Chat_GlyphUsedGood")
        Log.info("glyph used by slot " .. GetPlayerId(p))
        Events.emit("glyph", p)
        return true
    end

    return S
end)
