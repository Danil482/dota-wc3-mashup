-- Test and practice commands (test builds and solo games only), typed in chat:
--   -lvl N      set your hero to level N (default 30) and learn everything allowed
--   -gold N     add N gold (default 99999)
--   -refresh    full health and mana, all cooldowns reset
--   -wtf        toggle: no cooldowns and no mana costs
--   -respawn    revive your hero at the fountain now
--   -spells     toggle the enemy caster by the fountain (Storm Bolt at you)
-- In test builds a human's hero also starts at level 30 with every skill.
define("cheats", function()
    local Log = use("log")
    local Events = use("events")
    local Timer = use("timer")
    local Roles = use("roles")
    local C = {wtf = {}}

    local function abilityIds(heroKey)
        local ids = use("data.ids")
        local list = {}
        for _, ab in ipairs(use("data.heroes")[heroKey].abilities) do
            local code = ids.abilities[ab.name]
            if code then list[#list + 1] = FourCC(code) end
        end
        return list
    end

    function C.maxOut(hero, level)
        level = level or 30
        if GetHeroLevel(hero) < level then
            SetHeroLevel(hero, level, false)
        end
        local key = use("heroes").keyOf[hero]
        if not key then return end
        -- learn every ability as far as the level rules allow
        for _ = 1, 4 do
            for _, id in ipairs(abilityIds(key)) do
                if GetHeroSkillPoints(hero) > 0 then SelectHeroSkill(hero, id) end
            end
        end
        Log.info("cheat: " .. key .. " at level " .. GetHeroLevel(hero))
    end

    local function refresh(u)
        SetWidgetLife(u, BlzGetUnitMaxHP(u))
        SetUnitState(u, UNIT_STATE_MANA, BlzGetUnitMaxMana(u))
        UnitResetCooldown(u)
    end

    function C.enabled()
        return BUILD_TEST_MODE or Roles.humanCount == 1
    end

    function C.init()
        if not C.enabled() then return end
        local trig = CreateTrigger()
        for i = 0, bj_MAX_PLAYERS - 1 do
            TriggerRegisterPlayerChatEvent(trig, Player(i), "-", false)
        end
        TriggerAddAction(trig, function()
            use("safe").call(function()
                local p = GetTriggerPlayer()
                local msg = string.lower(GetEventPlayerChatString())
                local cmd, arg = string.match(msg, "^%-(%a+)%s*(%d*)")
                local hero = use("heroes").bySlot[GetPlayerId(p)]
                local n = tonumber(arg)
                if cmd == "gold" then
                    SetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD, GetPlayerState(p, PLAYER_STATE_RESOURCE_GOLD) + (n or 99999))
                elseif not hero then
                    return
                elseif cmd == "lvl" or cmd == "lvlup" or cmd == "level" then
                    C.maxOut(hero, math.min(30, n or 30))
                elseif cmd == "refresh" then
                    refresh(hero)
                elseif cmd == "wtf" then
                    C.wtf[hero] = not C.wtf[hero]
                    DisplayTimedTextToPlayer(p, 0, 0, 5, "WTF mode " .. (C.wtf[hero] and "on" or "off"))
                elseif cmd == "uiprobe" then
                    -- button variants for the mouse-input probe (created for all players)
                    local Kit = use("hud_kit")
                    Kit.probePanel()
                    if Kit.probeRoot and p == GetLocalPlayer() then
                        BlzFrameSetVisible(Kit.probeRoot, not BlzFrameIsVisible(Kit.probeRoot))
                    end
                elseif cmd == "spells" then
                    local on = use("dummy").toggleSpells()
                    DisplayTimedTextToPlayer(p, 0, 0, 5, "Enemy caster " .. (on and "on: Storm Bolt every 4 s within 700" or "off"))
                elseif cmd == "respawn" and IsUnitType(hero, UNIT_TYPE_DEAD) then
                    local f = use("data.mapdata").dota.fountain
                    ReviveHero(hero, f.x + 350, f.y + 350, true)
                end
            end)
        end)
        -- WTF: every cast is immediately free again
        Events.on("spell_effect", function(caster)
            if C.wtf[caster] then
                Timer.after(0.05, function()
                    UnitResetCooldown(caster)
                    SetUnitState(caster, UNIT_STATE_MANA, BlzGetUnitMaxMana(caster))
                end)
            end
        end)
        if BUILD_TEST_MODE then
            Events.on("hero_spawned", function(u, key, slot)
                if not Roles.isBot(slot) then
                    Timer.after(0.5, function() C.maxOut(u, 30) end)
                end
            end)
        end
        Log.info("cheats on: -lvl, -gold, -refresh, -wtf, -respawn, -spells")
    end

    return C
end)
