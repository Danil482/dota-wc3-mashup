-- Dota's gameplay sounds around the heroes (data.audio.sfx and the hero
-- responses of data.sounds, from the player's own Dota 2): the coin of a
-- last hit for the hero's player, the deny sound, level-up and skill-learn
-- sounds, rune pickups (each rune's own sound where it was taken, and the
-- hero's rune line for its player), the Aegis (the hero's line on pickup,
-- the reincarnation stinger on the revive). Hooks for the modules that own
-- the shop, ability keys and the Town Portal: buy, sell, combine, error,
-- castFail, tpStart and tpEnd. At the start of the game it loads every
-- effect file (sound.lua S.warmup) and mutes Warcraft's interface sounds for
-- Dota players.
define("gamesounds", function()
    local Timer = use("timer")
    local Events = use("events")
    local Roles = use("roles")
    local Sound = use("sound")
    local Log = use("log")
    local G = {started = false}

    G.COIN_GAP = 0.15           -- one coin at a time per player (Dota: General.Coins, limiter 1)
    G.LINE_GAP = 4              -- seconds between a hero's "not yet" / "no mana" lines
    G.LEVEL_GAP = 1             -- several level-ups at once ring once
    G.MUTE_WC3_UI = true        -- Warcraft's interface sounds are muted for Dota players

    local lastCoin, lastLevel, lastLearn, lastLine = {}, {}, {}, {}
    local aegisCode = nil
    local aegisHolder = {}      -- item -> hero that picked it up last
    local tps = {}              -- unit -> {origin, dest, ox, oy, x, y}

    local function now() return Timer.now() end
    local function isDotaHero(u) return defined("heroes") and use("heroes").keyOf[u] ~= nil end

    -- Last hits pay a coin to the killer's player; denies make Dota's deny
    -- sound at the unit. The same rule as economy.lua: hero players' kills of
    -- anything not on the Dota side pay.
    local function onDeath(dying, killer)
        if not dying or not killer or dying == killer then return end
        local kp = GetOwningPlayer(killer)
        local slot = GetPlayerId(kp)
        if slot == SLOT_ANCIENTS or Roles.side(slot) ~= "dota" then return end
        if Roles.side(GetPlayerId(GetOwningPlayer(dying))) == "dota" then
            if not IsUnitType(dying, UNIT_TYPE_HERO) then
                Sound.sfx("deny", "dota", GetUnitX(dying), GetUnitY(dying), 1, {near = 600, far = 2500})
            end
            return
        end
        if IsUnitIllusion(dying) then return end
        local t = now()
        if t - (lastCoin[slot] or -1) < G.COIN_GAP then return end
        lastCoin[slot] = t
        Sound.sfx("coins", kp, nil, nil, 1, {why = "lasthit"})
    end

    local function onLevel(u)
        if not isDotaHero(u) then return end
        local t = now()
        if t - (lastLevel[u] or -10) < G.LEVEL_GAP then return end
        lastLevel[u] = t
        Sound.sfx("levelup", GetOwningPlayer(u))
    end

    local function onLearn(u)
        if not isDotaHero(u) then return end
        local t = now()
        if t - (lastLearn[u] or -10) < 0.05 then return end
        lastLearn[u] = t
        Sound.sfx("learn", GetOwningPlayer(u))
    end

    -- Each rune's own pickup sound where it was taken (everyone near hears
    -- it, as in Dota) and the hero's rune line for its player.
    local function onRune(u, kind)
        if not u or not kind then return end
        Sound.sfx("rune_" .. kind, nil, GetUnitX(u), GetUnitY(u), 1, {near = 800, far = 3500})
        Sound.vo(u, "rune_" .. kind, 1, true)
    end

    local function onPickup(u, it)
        if not it or not aegisCode or GetItemTypeId(it) ~= aegisCode then return end
        if not IsUnitType(u, UNIT_TYPE_HERO) or IsUnitIllusion(u) or aegisHolder[it] == u then return end
        aegisHolder[it] = u
        Sound.vo(u, "aegis", 1, false)
    end

    local function onAegisUsed(u)
        if u then Sound.sfx("reincarnate", nil, GetUnitX(u), GetUnitY(u), 1, {near = 1000, far = 4000}) end
    end

    -- ------------------------------------------------------------ hooks

    -- Shop feedback for one player: a purchase, a sale, a finished recipe,
    -- Dota's "no" click (not enough gold, no stock, out of range).
    function G.buy(p) if p then Sound.sfx("buy", p) end end
    function G.sell(p) if p then Sound.sfx("coins", p, nil, nil, 1, {why = "sell"}) end end
    function G.combine(p) if p then Sound.sfx("combine", p) end end
    function G.error(p) if p then Sound.sfx("error", p) end end

    -- A cast that cannot happen: reason "cooldown" or "mana". Dota's beep for
    -- the hero's player every time, the hero's "not yet" / "no mana" line at
    -- most every LINE_GAP seconds.
    function G.castFail(hero, reason)
        if not hero then return end
        local mana = reason == "mana"
        Sound.sfx(mana and "fail_mana" or "fail_cooldown", GetOwningPlayer(hero))
        local t = now()
        if t - (lastLine[hero] or -100) >= G.LINE_GAP then
            lastLine[hero] = t
            Sound.vo(hero, mana and "nomana" or "notyet", 1, true)
        end
    end

    -- A synced key press of an ability (dota_settings.lua onKey, never its
    -- local part): the cast-fail sounds when the ability is on cooldown or the
    -- hero lacks the mana. Returns true when the ability is ready.
    function G.checkCast(hero, abil)
        if not hero or not abil then return true end
        local level = GetUnitAbilityLevel(hero, abil)
        if level <= 0 then return true end
        if BlzGetUnitAbilityCooldownRemaining(hero, abil) > 0 then
            G.castFail(hero, "cooldown")
            return false
        end
        if GetUnitState(hero, UNIT_STATE_MANA) < BlzGetUnitAbilityManaCost(hero, abil, level - 1) then
            G.castFail(hero, "mana")
            return false
        end
        return true
    end

    -- Town Portal: the portal hums at the hero and at the target while the
    -- scroll channels (everyone near hears both, as in Dota); tpEnd stops
    -- them, and with done = true plays the departure and the arrival.
    function G.tpStart(unit, x, y)
        if not unit then return end
        G.tpEnd(unit, false)
        local ox, oy = GetUnitX(unit), GetUnitY(unit)
        local loop = {looping = true, near = 600, far = 2500}
        tps[unit] = {ox = ox, oy = oy, x = x, y = y,
                     origin = Sound.sfx("tp_loop_origin", nil, ox, oy, 1, loop),
                     dest = Sound.sfx("tp_loop_dest", nil, x, y, 1, loop)}
    end

    function G.tpEnd(unit, done)
        local tp = unit and tps[unit]
        if not tp then return end
        tps[unit] = nil
        if tp.origin then StopSound(tp.origin, true, true) end
        if tp.dest then StopSound(tp.dest, true, true) end
        if done then
            Sound.sfx("tp_disappear", nil, tp.ox, tp.oy, 1, {near = 600, far = 2500})
            Sound.sfx("tp_appear", nil, tp.x, tp.y, 1, {near = 600, far = 2500})
        end
    end

    -- ------------------------------------------------------------ Warcraft's own sounds

    -- Warcraft's interface sounds (sound channel 8, volume group UI): the
    -- advisor's "inventory is full", "not enough gold" / "mana", "under
    -- attack", "your hero has fallen", the error click, item pickup and drop,
    -- minimap pings, quest, hint and chat sounds. Dota players hear none of
    -- them; the Warcraft player keeps them all. Our sounds play on channel 0,
    -- outside that group. Only the volume is per client; no handles.
    local uiMuted = {}          -- slot -> true while the player's Warcraft UI sounds are muted

    function G.muteWarcraftUi(p, on)
        uiMuted[GetPlayerId(p)] = on or nil
        if GetLocalPlayer() == p then VolumeGroupSetVolume(SOUND_VOLUMEGROUP_UI, on and 0 or 1) end
    end

    function G.warcraftUiMuted(p)
        return uiMuted[GetPlayerId(p)] == true
    end

    -- Test builds: "-sfx <key>" plays an effect for the typing player ("-sfx
    -- <key> 3d": at their hero, for everyone near), "-sfxch N" moves our
    -- sounds to Warcraft channel N, "-wc3ui" switches the player's Warcraft
    -- interface sounds on or off. Each logs what it did.
    local function testCommands()
        local trig = CreateTrigger()
        for i = 0, SLOT_WARCRAFT do
            TriggerRegisterPlayerChatEvent(trig, Player(i), "-sfx", false)
            TriggerRegisterPlayerChatEvent(trig, Player(i), "-wc3ui", true)
        end
        TriggerAddAction(trig, function()
            use("safe").call(function()
                local p, msg = GetTriggerPlayer(), GetEventPlayerChatString()
                local slot = GetPlayerId(p)
                local ch = string.match(msg, "^%-sfxch%s+(%d+)")
                local key, mode = string.match(msg, "^%-sfx%s+(%S+)%s*(%S*)")
                if msg == "-wc3ui" then
                    G.muteWarcraftUi(p, not G.warcraftUiMuted(p))
                    Log.info("sound: Warcraft UI sounds " .. (G.warcraftUiMuted(p) and "muted" or "on") .. " for player " .. slot)
                elseif ch then
                    Sound.CHANNEL = tonumber(ch)
                    Log.info("sound: our sounds now use channel " .. Sound.CHANNEL)
                elseif key and mode == "3d" then
                    local hero = defined("heroes") and use("heroes").bySlot[slot] or nil
                    Sound.sfx(key, nil, hero and GetUnitX(hero) or 0, hero and GetUnitY(hero) or 0, 1,
                              {near = 800, far = 3500, why = "test"})
                elseif key then
                    Sound.sfx(key, p, nil, nil, 1, {why = "test"})
                end
                Log.flush()
            end)
        end)
    end

    function G.init()
        if G.started then return end
        G.started = true
        Sound.warmup()
        if G.MUTE_WC3_UI then
            for _, slot in ipairs(Roles.heroSlots) do
                if Roles.humans[slot] and Roles.side(slot) == "dota" then G.muteWarcraftUi(Player(slot), true) end
            end
        end
        if BUILD_TEST_MODE then testCommands() end
        if defined("world") then aegisCode = use("world").code("items", "aegis") end
        Events.on("death", onDeath)
        Events.on("hero_level", onLevel)
        Events.on("hero_skill", onLearn)
        Events.on("rune_activated", onRune)
        Events.on("item_pickup", onPickup)
        Events.on("aegis_used", onAegisUsed)
    end

    return G
end)
