-- Dota's lane rules for the Dota side, around creeps.lua, structures.lua
-- (Glyph) and economy.lua (deny XP, kill gold, buyback): the day and night
-- clock, denies, Scan and creep and tower aggro. Player-facing strings come
-- from data.strings, keyed by Dota's localization tokens (English fallbacks in
-- our own words; the launcher may fill in the player's own localization).
--
-- Start with use("lane").init() right after use("creeps").start(...): the
-- horn, Dota's 0:00, is the first lane wave (creeps.firstAt).
define("lane", function()
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Roles = use("roles")
    local Sound = use("sound")
    local U = use("util")
    local Lane = {started = false}

    local ATTACK, STOP = 851983, 851972

    local function sideOf(u) return Roles.side(GetPlayerId(GetOwningPlayer(u))) end

    -- ------------------------------------------------------------ strings

    -- data.strings[token] with Dota's %s1, %s2 ... placeholders filled in.
    function Lane.text(token, ...)
        local s = use("data.strings")[token] or token
        local args = {...}
        return (string.gsub(s, "%%s(%d)", function(i) return tostring(args[tonumber(i)] or "") end))
    end

    -- Dota's red error line and error beep for one human player.
    function Lane.error(p, token, ...)
        if not Roles.humans[GetPlayerId(p)] then return end
        local msg = Lane.text(token, ...)
        if defined("dota_glyph") and use("dota_glyph").started then
            use("dota_glyph").error(p, msg)
        else
            DisplayTimedTextToPlayer(p, 0, 0, 2, "|cffff4040" .. msg .. "|r")
        end
        if defined("gamesounds") then use("gamesounds").error(p) end
    end

    -- A chat line for everyone, like Dota's DOTA_Chat_* lines.
    function Lane.chat(token, ...)
        DisplayTimedTextToPlayer(GetLocalPlayer(), 0, 0, 6, Lane.text(token, ...))
    end

    -- ------------------------------------------------------------ day and night
    -- Dota (https://liquipedia.net/dota2/Daytime): night until the horn,
    -- dawn with the horn, night at 5:00, day at 10:00, and so on. A full WC3
    -- day lasts DayLength = 600 s (tools/gen_objects.py MISC), so WC3's day
    -- (6:00 to 18:00) is Dota's 5 minutes. Units switch to their night sight
    -- (Dota's VisionNighttimeRange, through the object data) by themselves.

    Lane.DAY_LENGTH = 600
    Lane.DAWN = 6

    -- Game time of the horn (Dota's 0:00) and Dota's clock (negative before it).
    function Lane.hornAt() return use("creeps").firstAt or 0 end
    function Lane.clock() return Timer.now() - Lane.hornAt() end

    -- WC3 time of day `t` seconds after the horn.
    function Lane.timeOfDay(t)
        return (Lane.DAWN + t * 24 / Lane.DAY_LENGTH) % 24
    end

    function Lane.isDay()
        local tod = GetFloatGameState(GAME_STATE_TIME_OF_DAY)
        return tod >= 6 and tod < 18
    end

    local function startDay()
        SetFloatGameState(GAME_STATE_TIME_OF_DAY, Lane.timeOfDay(Lane.clock()))
        if Lane.clock() < 0 then
            Timer.after(-Lane.clock(), function() SetFloatGameState(GAME_STATE_TIME_OF_DAY, Lane.DAWN) end)
        end
        -- WC3's rooster at dawn and wolf at dusk are not Dota's: muted for Dota players
        if Sound.isDota(GetLocalPlayer()) then
            if bj_dawnSound then SetSoundVolume(bj_dawnSound, 0) end
            if bj_duskSound then SetSoundVolume(bj_duskSound, 0) end
        end
        if BUILD_TEST_MODE then
            local tod0 = GetFloatGameState(GAME_STATE_TIME_OF_DAY)
            Timer.after(10, function()
                local d = (GetFloatGameState(GAME_STATE_TIME_OF_DAY) - tod0) % 24
                Log.info(string.format("lane: time of day %.2f -> %.2f in 10 s, a full day takes %.0f s (want %d)",
                    tod0, GetFloatGameState(GAME_STATE_TIME_OF_DAY), d > 0 and 240 / d or -1, Lane.DAY_LENGTH))
            end)
        end
    end

    -- ------------------------------------------------------------ denies
    -- Dota (https://liquipedia.net/dota2/Deny; Dota's tutorial,
    -- DOTA_Tutorial_LastHit_DenyExplanation2: friendly creeps "below half"):
    -- allies may attack a non-hero unit below 50% health, a tower or barracks
    -- below 10% and a ward at any health; never a hero. A refused attack order
    -- is stopped with Dota's error line. Deny XP is economy.lua's.

    Lane.DENY_UNIT = 0.5
    Lane.DENY_BUILDING = 0.1
    local DENY_MARK = {r = 230, g = 230, b = 230}

    local wards = {}
    local function isWard(u) return wards[GetUnitTypeId(u)] == true end

    -- nil when its allies may deny `target`, else Dota's error token.
    function Lane.denyError(target)
        if IsUnitType(target, UNIT_TYPE_HERO) then return "dota_hud_error_hero_cant_be_denied" end
        if isWard(target) then return nil end
        local share = GetWidgetLife(target) / math.max(1, BlzGetUnitMaxHP(target))
        local limit = Lane.DENY_UNIT
        if IsUnitType(target, UNIT_TYPE_STRUCTURE) then
            local kind = use("structures").kindOf(target)
            if kind ~= "tower" and kind ~= "rax" then return "dota_hud_error_target_cant_be_denied" end
            limit = Lane.DENY_BUILDING
        end
        if share < limit then return nil end
        return "dota_hud_error_cant_deny_health_too_high"
    end

    local orderNo = {}      -- unit -> count of its orders: a deferred stop yields to a newer order

    local function checkDeny(u, target)
        local p = GetOwningPlayer(u)
        if not Roles.isHeroSlot(GetPlayerId(p)) then return end
        local err = Lane.denyError(target)
        if not err then return end
        local n = orderNo[u]
        -- an order given inside its own order event would be overridden
        Timer.after(0, function()
            if orderNo[u] == n and U.alive(u) then IssueImmediateOrderById(u, STOP) end
        end)
        Lane.error(p, err)
    end

    -- Dota's "!" over a denied unit, for everyone.
    function Lane.denyMark(u)
        local t = CreateTextTag()
        SetTextTagText(t, "!", 0.03)
        SetTextTagPos(t, GetUnitX(u), GetUnitY(u), 90)
        SetTextTagColor(t, DENY_MARK.r, DENY_MARK.g, DENY_MARK.b, 255)
        SetTextTagVelocity(t, 0, 0.02)
        SetTextTagPermanent(t, false)
        SetTextTagLifespan(t, 1.5)
        SetTextTagFadepoint(t, 1)
    end

    local function onDeath(dying, killer)
        if not dying or not killer or killer == dying or IsUnitType(dying, UNIT_TYPE_HERO) then return end
        local side = sideOf(killer)
        if side == "none" or side ~= sideOf(dying) then return end
        Lane.denyMark(dying)
        if use("structures").kindOf(dying) == "tower" then
            Lane.chat("DOTA_Chat_TowerDenied", GetPlayerName(GetOwningPlayer(killer)))
        end
    end

    -- ------------------------------------------------------------ aggro
    -- Creep and tower aggro, Dota's game code as third-party guides describe
    -- it (e.g. https://www.hotspawn.com/dota2/guide/how-does-creep-aggro-work-in-dota-2-creep-aggro-guide;
    -- unverified): a hero that attacks an enemy hero, or is ordered to, draws
    -- the enemy lane creeps within 500 of it for 2.3 s, at most once every 3 s;
    -- an enemy that attacks a hero inside a tower's range draws that tower.
    -- On the commander's side his heroes and his own army draw Dota creeps
    -- and towers; his creep waves draw nothing.

    Lane.AGGRO = {radius = 500, duration = 2.3, cooldown = 3}
    local aggroReady = {}   -- attacker -> game time it may draw aggro again

    local function canDraw(u)
        local slot = GetPlayerId(GetOwningPlayer(u))
        local side = Roles.side(slot)
        if IsUnitType(u, UNIT_TYPE_STRUCTURE) then return false end
        if side == "dota" then return IsUnitType(u, UNIT_TYPE_HERO) and slot ~= SLOT_ANCIENTS end
        return side == "commander" and slot ~= SLOT_HORDE
    end

    -- `attacker` attacks (or is ordered to attack) the hero `victim`.
    function Lane.aggro(attacker, victim)
        if not U.alive(attacker) or not U.alive(victim) or not IsUnitType(victim, UNIT_TYPE_HERO) then return 0 end
        local as, vs = sideOf(attacker), sideOf(victim)
        if as == vs or vs == "none" or not canDraw(attacker) then return 0 end
        local now = Timer.now()
        if (aggroReady[attacker] or 0) > now then return 0 end
        local C = use("creeps")
        local x, y = GetUnitX(attacker), GetUnitY(attacker)
        local n = 0
        for _, c in ipairs(C.near(vs == "dota" and SLOT_ANCIENTS or SLOT_HORDE, x, y, Lane.AGGRO.radius)) do
            if C.aggro(c, attacker, Lane.AGGRO.duration) then n = n + 1 end
        end
        if vs == "dota" then
            for _, t in ipairs(use("structures").buildings()) do
                if use("structures").kindOf(t) == "tower" and U.alive(t) and not BlzIsUnitInvulnerable(attacker) then
                    local range = BlzGetUnitWeaponRealField(t, UNIT_WEAPON_RF_ATTACK_RANGE, 0)
                    if range <= 0 then range = use("data.world").towers["1"].range end
                    if U.unitDist(t, attacker) <= range then
                        IssueTargetOrder(t, "attack", attacker)
                        n = n + 1
                    end
                end
            end
        end
        if n > 0 then aggroReady[attacker] = now + Lane.AGGRO.cooldown end
        return n
    end

    local function onOrder(u, order, target)
        orderNo[u] = (orderNo[u] or 0) + 1
        if order ~= ATTACK or not target or target == u then return end
        if sideOf(target) == sideOf(u) then
            checkDeny(u, target)
        else
            Lane.aggro(u, target)
        end
    end

    -- ------------------------------------------------------------ Scan
    -- Dota's tooltip (DOTA_Tooltip_ability_radar_Description): a 900 area for
    -- 8 s, telling whether enemy heroes are in it. Two team charges, each
    -- back 210 s after use, the first ready from the start
    -- (https://teamsmurf.com/glyph-and-scan-micro-advantages-that-win-close-games/;
    -- unverified; when the second charge first comes is not given: here it
    -- refills from the start like a used one). Seen by the Dota team only;
    -- enemy heroes inside show as red minimap pings.

    Lane.SCAN = {radius = 900, duration = 8, charges = 2, restore = 210, tick = 1}
    Lane.scanCharges = 1
    Lane.scanRestoreAt = nil      -- game time the next charge comes back
    local SCAN_FX = "Abilities\\Spells\\Human\\Flare\\FlareCaster.mdl"

    local function restoreCharges()
        while Lane.scanRestoreAt and Timer.now() >= Lane.scanRestoreAt do
            Lane.scanCharges = Lane.scanCharges + 1
            if Lane.scanCharges < Lane.SCAN.charges then
                Lane.scanRestoreAt = Lane.scanRestoreAt + Lane.SCAN.restore
            else
                Lane.scanRestoreAt = nil
            end
        end
    end

    -- Seconds until the next charge (0 when none is coming) and its full wait.
    function Lane.scanLeft()
        restoreCharges()
        if not Lane.scanRestoreAt then return 0, Lane.SCAN.restore end
        return math.max(0, Lane.scanRestoreAt - Timer.now()), Lane.SCAN.restore
    end

    -- Commander-side heroes inside a scanned area.
    function Lane.scanHits(x, y)
        return U.enum(x, y, Lane.SCAN.radius, function(u)
            return IsUnitType(u, UNIT_TYPE_HERO) and sideOf(u) == "commander"
        end)
    end

    local function ping(x, y, red)
        if Sound.isDota(GetLocalPlayer()) then
            PingMinimapEx(x, y, red and 1.5 or 3, 255, red and 40 or 255, red and 40 or 255, false)
        end
    end

    -- A Dota hero player scans (x, y). Synced code only.
    function Lane.scan(p, x, y)
        if not Roles.isHeroSlot(GetPlayerId(p)) then return false end
        restoreCharges()
        if Lane.scanCharges <= 0 then
            Lane.error(p, "dota_hud_error_cant_radar")
            return false
        end
        Lane.scanCharges = Lane.scanCharges - 1
        if not Lane.scanRestoreAt then Lane.scanRestoreAt = Timer.now() + Lane.SCAN.restore end
        local fx = AddSpecialEffect(Sound.isDota(GetLocalPlayer()) and SCAN_FX or "", x, y)
        ping(x, y, false)
        local ends = Timer.now() + Lane.SCAN.duration
        local function sweep()
            if Timer.now() >= ends - 0.01 then
                DestroyEffect(fx)
                return true
            end
            if #Lane.scanHits(x, y) > 0 then ping(x, y, true) end
        end
        sweep()
        Timer.every(Lane.SCAN.tick, sweep)
        if defined("announcer") then use("announcer").say("scan_rad", 2) end
        Lane.chat("DOTA_Chat_ScanUsedGood")
        Events.emit("scan", p, x, y)
        return true
    end

    -- ------------------------------------------------------------ bots
    -- With no human on the Dota side, bots use the Glyph for a building that
    -- is low, under fire and surrounded.
    Lane.BOT_GLYPH = {hp = 0.4, hit = 2, foes = 3, radius = 900}

    local function botGlyph()
        local S = use("structures")
        if S.glyphLeft() > 0 then return end
        local bot = nil
        for _, slot in ipairs(Roles.heroSlots) do
            if Roles.humans[slot] then return end
            bot = bot or slot
        end
        if not bot then return end
        local now = Timer.now()
        for _, u in ipairs(S.buildings()) do
            local hit = S.lastHit(u)
            if U.alive(u) and not BlzIsUnitInvulnerable(u) and hit and now - hit <= Lane.BOT_GLYPH.hit
                and GetWidgetLife(u) < BlzGetUnitMaxHP(u) * Lane.BOT_GLYPH.hp then
                local foes = U.enum(GetUnitX(u), GetUnitY(u), Lane.BOT_GLYPH.radius, function(e)
                    return sideOf(e) == "commander" and not IsUnitType(e, UNIT_TYPE_STRUCTURE)
                end)
                if #foes >= Lane.BOT_GLYPH.foes then
                    S.glyph(Player(bot))
                    return
                end
            end
        end
    end

    -- ------------------------------------------------------------ start

    function Lane.init()
        if Lane.started then return end
        Lane.started = true
        local units = use("data.ids").units
        for _, key in ipairs({"wardobserver", "wardsentry"}) do
            if units[key] then wards[FourCC(units[key])] = true end
        end
        Lane.scanCharges = 1
        Lane.scanRestoreAt = Timer.now() + Lane.SCAN.restore
        startDay()
        Events.on("order", onOrder)
        Events.on("attacked", function(attacker, target)
            if attacker and target then Lane.aggro(attacker, target) end
        end)
        Events.on("death", onDeath)
        Timer.every(1, botGlyph)
        Log.info(string.format("lane: horn in %.0f s, time of day %.2f", -Lane.clock(),
            GetFloatGameState(GAME_STATE_TIME_OF_DAY)))
    end

    return Lane
end)
