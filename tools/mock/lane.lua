-- Offline exercise for the lane rules: src/game/lane.lua (day and night,
-- denies, Scan, aggro), structures.lua's Glyph, economy.lua's deny XP, kill
-- gold and buyback, heroes.lua's early revive, creeps.lua's aggro, roles.lua's
-- buildings slot and src/ui/dota_glyph.lua. Runs after the main mock run and
-- after the HUD exercise (tools/mock/dota_hud.lua), whose frame model it
-- uses. Natives the generic stubs cannot answer are overridden and restored
-- afterwards; the exercise's own units carry the flag lx. Failed checks
-- become ERROR lines, which fail the mock run.
do
    local saved = {}
    local function stub(name, fn)
        if saved[name] == nil then saved[name] = _G[name] end
        _G[name] = fn
    end
    local function orig(name) return saved[name] or _G[name] end
    local function restore()
        for name, fn in pairs(saved) do _G[name] = fn end
        saved = {}
    end
    local function ours(u) return type(u) == "table" and rawget(u, "lx") == true end

    local rec, ev, state = {}, {damage = 0, attack = false}, {tod = 0}
    local function clear()
        rec = {stops = {}, targets = {}, points = {}, xp = {}, tags = {}, texts = {}, pings = {}, hits = {},
               invul = {}, alliance = {}, effects = {}, revived = 0}
    end

    -- Same loop as __mock.advance (local, so wrappers of it are not re-entered).
    local function advance(seconds)
        local target = __mock.now + seconds
        while true do
            local nextT, nextDue = nil, math.huge
            for t in pairs(__mock.timers) do
                if t.active and t.due <= target and t.due < nextDue then nextT, nextDue = t, t.due end
            end
            if not nextT then break end
            __mock.now = nextDue
            if nextT.periodic then nextT.due = nextT.due + math.max(nextT.timeout, 0.001) else nextT.active = false end
            if nextT.fn then nextT.fn() end
        end
        __mock.now = target
    end

    local function install()
        clear()
        local Roles = use("roles")
        local function sideOf(p)
            local id = GetPlayerId(p)
            if id == PLAYER_NEUTRAL_AGGRESSIVE then return "neutral" end
            return Roles.side(id)
        end
        stub("IsUnitType", function(u, t)
            if not ours(u) then return orig("IsUnitType")(u, t) end
            if t == UNIT_TYPE_DEAD then return u.dead == true end
            if t == UNIT_TYPE_HERO then return u.hero == true end
            if t == UNIT_TYPE_STRUCTURE then return u.structure == true end
            return false
        end)
        stub("IsUnitEnemy", function(u, p) return sideOf(GetOwningPlayer(u)) ~= sideOf(p) end)
        stub("IsUnitAlly", function(u, p) return sideOf(GetOwningPlayer(u)) == sideOf(p) end)
        stub("IsUnitVisible", function() return true end)
        stub("BlzIsUnitInvulnerable", function(u) return rec.invul[u] == true end)
        stub("SetUnitInvulnerable", function(u, on) rec.invul[u] = on end)
        stub("AddHeroXP", function(h, xp) rec.xp[#rec.xp + 1] = {u = h, xp = xp} end)
        stub("IssueImmediateOrderById", function(u, id)
            if id == 851972 then rec.stops[#rec.stops + 1] = u end
            return true
        end)
        stub("IssueTargetOrder", function(u, order, t)
            rec.targets[#rec.targets + 1] = {u = u, order = order, t = t}
            return true
        end)
        stub("IssuePointOrder", function(u, order, x, y)
            rec.points[#rec.points + 1] = {u = u, order = order}
            return true
        end)
        stub("CreateTextTag", function()
            local t = __handle("texttag")
            rec.tags[#rec.tags + 1] = t
            return t
        end)
        stub("SetTextTagText", function(t, s) t.text = s end)
        stub("SetTextTagVisibility", function(t, on) t.vis = on end)
        stub("DisplayTimedTextToPlayer", function(p, x, y, d, msg) rec.texts[#rec.texts + 1] = {p = p, msg = msg} end)
        stub("PingMinimapEx", function(x, y, d, r, g, b) rec.pings[#rec.pings + 1] = {r = r, g = g, b = b} end)
        stub("AddSpecialEffect", function(path, x, y)
            rec.effects[#rec.effects + 1] = path
            return __handle("effect")
        end)
        stub("GetFloatGameState", function(s)
            if s == GAME_STATE_TIME_OF_DAY then return state.tod end
            return orig("GetFloatGameState")(s)
        end)
        stub("SetFloatGameState", function(s, v) if s == GAME_STATE_TIME_OF_DAY then state.tod = v end end)
        stub("ReviveHero", function(u, x, y)
            u.dead, u.x, u.y = false, x, y
            rec.revived = rec.revived + 1
            return true
        end)
        stub("UnitDamageTarget", function(src, tgt, amount)
            rec.hits[#rec.hits + 1] = {src = src, tgt = tgt, amount = amount}
            tgt.life = math.max(0, (tgt.life or 0) - amount)
            return true
        end)
        stub("GetEventDamage", function() return ev.damage end)
        stub("BlzGetEventIsAttack", function() return ev.attack end)
        stub("BlzSetEventDamage", function(v) ev.set = v end)
        stub("SetPlayerAlliance", function(a, b, kind, on)
            rec.alliance[GetPlayerId(a) .. ">" .. GetPlayerId(b) .. ":" .. tostring(kind.__const)] = on
        end)
    end

    local function exercise()
        local Log, Events, Timer = use("log"), use("events"), use("timer")
        local Lane, S, E, H = use("lane"), use("structures"), use("economy"), use("heroes")
        local C, Roles, Mods, U = use("creeps"), use("roles"), use("mods"), use("util")
        local ids = use("data.ids")
        local failures, checks = 0, 0
        local function check(name, ok, detail)
            checks = checks + 1
            if not ok then
                failures = failures + 1
                Log.error("lane exercise: " .. name .. (detail ~= nil and (" - " .. tostring(detail)) or ""))
            end
        end
        local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
        local made = {}
        local function unit(slot, code, x, y, o)
            o = o or {}
            local u = CreateUnit(Player(slot), type(code) == "string" and FourCC(code) or code, x, y, 0)
            u.lx, u.hero, u.structure, u.level = true, o.hero == true, o.structure == true, o.level or 1
            u.life, u.maxLife = o.hp or 100, o.maxHp or 100
            made[#made + 1] = u
            return u
        end
        local function flag(u, o)
            rawset(u, "lx", true)
            for k, v in pairs(o or {}) do u[k] = v end
        end
        local function gold(slot) return GetPlayerState(Player(slot), PLAYER_STATE_RESOURCE_GOLD) end
        local function setGold(slot, n) SetPlayerState(Player(slot), PLAYER_STATE_RESOURCE_GOLD, n) end
        local function lastText() return rec.texts[#rec.texts] and rec.texts[#rec.texts].msg or "" end
        local function said(part)
            for _, t in ipairs(rec.texts) do
                if string.find(t.msg, part, 1, true) then return true end
            end
            return false
        end
        local function tagWith(text)
            for i = #rec.tags, 1, -1 do
                if rec.tags[i].text == text then return rec.tags[i] end
            end
            return nil
        end
        local p0, p1 = Player(0), Player(1)
        local ATTACK = 851983

        local Hud = use("dota_hud")
        local G = use("dota_glyph")
        local mockHud = __mockHud
        if Hud.started and not G.started then G.init() end
        local function errText()
            if G.started then return G.F.err.t.text end
            return lastText()
        end
        if not Lane.started then Lane.init() end
        clear()

        ---------------------------------------------------------------- buildings slot (pulls)
        check("buildings slot is Dota's", Roles.side(SLOT_BUILDINGS) == "dota")
        check("towers on the buildings slot", GetOwningPlayer(S.towers.mid[1]) == Player(SLOT_BUILDINGS))
        check("fountain on the buildings slot", GetOwningPlayer(S.fountain) == Player(SLOT_BUILDINGS))
        Roles.setupAlliances()
        local PASSIVE, VISION = tostring(ALLIANCE_PASSIVE.__const), tostring(ALLIANCE_SHARED_VISION.__const)
        local function ally(a, b, kind) return rec.alliance[a .. ">" .. b .. ":" .. (kind or PASSIVE)] end
        local N = PLAYER_NEUTRAL_AGGRESSIVE
        check("neutrals leave the buildings alone", ally(N, SLOT_BUILDINGS) == true and ally(SLOT_BUILDINGS, N) == true)
        check("lane creeps fight neutrals", ally(N, SLOT_ANCIENTS) == false and ally(SLOT_ANCIENTS, N) == false
            and ally(N, SLOT_HORDE) == false)
        check("buildings allied with the heroes", ally(SLOT_BUILDINGS, 0) == true and ally(0, SLOT_BUILDINGS) == true
            and ally(SLOT_BUILDINGS, 0, VISION) == true)
        check("buildings hostile to the Warcraft player", ally(SLOT_BUILDINGS, Roles.warcraft) == false)
        check("buildings leave the test dummies alone", ally(SLOT_BUILDINGS, 9) == true and ally(9, SLOT_BUILDINGS) == true)

        ---------------------------------------------------------------- day and night
        check("dawn with the horn", near(Lane.timeOfDay(0), 6))
        check("dusk at 5:00", near(Lane.timeOfDay(300), 18))
        check("dawn again at 10:00", near(Lane.timeOfDay(600), 6))
        check("night before the horn", near(Lane.timeOfDay(-30), 4.8))
        check("clock follows the horn", near(Lane.clock(), Timer.now() - C.firstAt))

        ---------------------------------------------------------------- denies
        local X, Y = 8000, -8000
        local dh = unit(0, ids.heroes.pudge, X, Y, {hero = true, level = 3})
        local mate = unit(1, ids.heroes.tinker, X + 100, Y, {hero = true})
        local foe = unit(Roles.warcraft, "Hpal", X + 300, Y, {hero = true, level = 5})
        local melee = FourCC(ids.units.dota_melee)
        local creep80 = unit(SLOT_ANCIENTS, melee, X + 50, Y + 50, {hp = 80})
        local creep40 = unit(SLOT_ANCIENTS, melee, X + 60, Y + 60, {hp = 40})
        local ward = unit(0, ids.units.wardobserver, X + 70, Y, {hp = 100})
        check("creep at 80% not deniable", Lane.denyError(creep80) == "dota_hud_error_cant_deny_health_too_high")
        check("creep at 40% deniable", Lane.denyError(creep40) == nil)
        check("hero not deniable", Lane.denyError(mate) == "dota_hud_error_hero_cant_be_denied")
        check("ward deniable at full health", Lane.denyError(ward) == nil)
        local t1, t2 = S.towers.mid[1], S.towers.mid[2]
        flag(t1, {structure = true})
        flag(t2, {structure = true})
        flag(S.ancient, {structure = true})
        t1.life, t1.maxLife = 50, 100
        check("tower at 50% not deniable", Lane.denyError(t1) == "dota_hud_error_cant_deny_health_too_high")
        t1.life = 5
        check("tower at 5% deniable", Lane.denyError(t1) == nil)
        S.ancient.life, S.ancient.maxLife = 5, 100
        check("the Ancient is never deniable", Lane.denyError(S.ancient) == "dota_hud_error_target_cant_be_denied")
        t1.life, S.ancient.life = 100, 100

        Events.emit("order", dh, ATTACK, creep80)
        advance(0.01)
        check("refused deny stops the hero", rec.stops[1] == dh, #rec.stops)
        check("refused deny says why", string.find(errText(), Lane.text("dota_hud_error_cant_deny_health_too_high"), 1, true) ~= nil,
            errText())
        Events.emit("order", dh, ATTACK, creep40)
        advance(0.01)
        check("allowed deny is not stopped", #rec.stops == 1, #rec.stops)
        Events.emit("order", dh, ATTACK, mate)
        advance(0.01)
        check("ally hero refused", #rec.stops == 2 and string.find(errText(), Lane.text("dota_hud_error_hero_cant_be_denied"), 1, true) ~= nil,
            errText())
        Events.emit("order", dh, ATTACK, ward)
        Events.emit("order", foe, ATTACK, dh)       -- the Warcraft player keeps Warcraft's rules
        advance(0.01)
        check("ward and enemy orders untouched", #rec.stops == 2, #rec.stops)
        -- the swing guard: however the attack was ordered, it stops as it starts
        Events.emit("attacked", dh, creep80)
        check("a swing at a creep at 80% stops", #rec.stops == 3 and rec.stops[3] == dh, #rec.stops)
        Events.emit("attacked", dh, creep40)
        check("a swing at a creep at 40% goes on", #rec.stops == 3, #rec.stops)
        Events.emit("attacked", dh, mate)
        check("a swing at an allied hero stops", #rec.stops == 4, #rec.stops)
        Events.emit("attacked", dh, t1)
        check("a swing at an own tower at full health stops", #rec.stops == 5, #rec.stops)
        advance(0.01)

        -- a deny: "!" for everyone, no gold, half the XP to the enemy heroes near it
        local g0 = gold(0)
        creep40.dead = true
        Events.emit("death", creep40, dh)
        local mark = nil
        for _, t in ipairs(rec.tags) do if t.text == "!" then mark = t end end
        check("deny mark", mark ~= nil and mark.vis == nil)
        check("no gold for a deny", gold(0) == g0, gold(0) - g0)
        local share = 0
        for _, x in ipairs(rec.xp) do if x.u == foe then share = share + x.xp end end
        check("half XP to the enemy hero", share == math.floor(57 * E.DENY_XP), share)

        ---------------------------------------------------------------- kill gold
        rec.tags = {}
        g0 = gold(0)
        foe.dead = true
        Events.emit("death", foe, dh)
        local bounty = E.HERO_GOLD.base + E.HERO_GOLD.perLevel * 5
        check("hero kill gold", gold(0) - g0 == bounty, gold(0) - g0)
        local popup = tagWith("+" .. bounty)
        check("gold popup for the killer", popup ~= nil and popup.vis == true)
        foe.dead = false
        local creep2 = unit(Roles.warcraft, "hfoo", X + 400, Y, {hp = 10})
        rec.tags = {}
        creep2.dead = true
        Events.emit("death", creep2, mate)
        popup = nil
        for _, t in ipairs(rec.tags) do if string.sub(t.text or "", 1, 1) == "+" then popup = t end end
        check("another player's popup hidden here", popup ~= nil and popup.vis == false)
        local g10 = GetPlayerState(Player(SLOT_BUILDINGS), PLAYER_STATE_RESOURCE_GOLD)
        local creep3 = unit(Roles.warcraft, "hfoo", X + 400, Y, {hp = 10})
        creep3.dead = true
        Events.emit("death", creep3, t1)
        check("towers earn no gold", GetPlayerState(Player(SLOT_BUILDINGS), PLAYER_STATE_RESOURCE_GOLD) == g10)

        ---------------------------------------------------------------- aggro
        local horde = C.near(SLOT_HORDE)
        local dota = C.near(SLOT_ANCIENTS)
        if #horde >= 2 and #dota >= 1 then
            local h1, h2, d1 = horde[1], horde[2], dota[1]
            SetUnitPosition(h1, X + 200, Y - 100)
            SetUnitPosition(h2, X - 200, Y + 100)
            rec.targets, rec.points = {}, {}
            local n = Lane.aggro(dh, foe)
            local function targeted(u, t)
                for _, r in ipairs(rec.targets) do if r.u == u and r.t == t and r.order == "attack" then return true end end
                return false
            end
            check("enemy creeps turn on the hero", n >= 2 and targeted(h1, dh) and targeted(h2, dh), n)
            check("aggro has a cooldown", Lane.aggro(dh, foe) == 0)
            check("aggroed creep is held", C.aggroed(h1))
            advance(Lane.AGGRO.duration + 0.05)
            local back1, back2 = false, false
            for _, r in ipairs(rec.points) do
                if r.u == h1 then back1 = true end
                if r.u == h2 then back2 = true end
            end
            check("creeps go back to the lane", back1 and back2 and not C.aggroed(h1))
            -- the Warcraft player's hero hits a Dota hero under a tower (its
            -- aggro cooldown from the order in the deny checks has run out)
            advance(Lane.AGGRO.cooldown)
            SetUnitPosition(dh, GetUnitX(t1) + 200, GetUnitY(t1))
            SetUnitPosition(foe, GetUnitX(t1) + 400, GetUnitY(t1))
            SetUnitPosition(d1, GetUnitX(t1) + 450, GetUnitY(t1))
            rec.targets = {}
            Lane.aggro(foe, dh)
            check("tower turns on the attacker", targeted(t1, foe))
            check("Dota creeps turn on the attacker", targeted(d1, foe))
            check("lane creeps draw no aggro", Lane.aggro(h1, dh) == 0)
            SetUnitPosition(h1, GetUnitX(dh) + 100, GetUnitY(dh))
            rec.targets = {}
            Events.emit("order", dh, ATTACK, foe)
            check("an attack order draws aggro", targeted(h1, dh))
            SetUnitPosition(dh, X, Y)
            SetUnitPosition(foe, X + 300, Y)
        else
            Log.warn("lane exercise: no lane creeps, aggro checks skipped")
        end

        ---------------------------------------------------------------- Glyph
        local dc = C.near(SLOT_ANCIENTS)[1]
        S.glyphAt = Timer.now() + 100
        check("glyph refused on cooldown", S.glyph(p0) == false)
        check("glyph refusal says why", string.find(errText(), Lane.text("dota_hud_error_cant_glyph"), 1, true) ~= nil,
            errText())
        S.glyphAt = Timer.now()
        rec.invul = {}
        check("glyph used", S.glyph(p0) == true and S.glyphActive())
        check("glyph protects towers", rec.invul[t1] == true and rec.invul[t2] == true)
        check("glyph cooldown", near(S.glyphLeft(), S.GLYPH.cooldown, 0.01), S.glyphLeft())
        if dc then check("glyph protects lane creeps", Mods.has(dc, "glyph") and Mods.flag(dc, "invulnerable")) end
        -- multishot: a tier 2 tower's attack hits 5 more enemies, a tier 1 none
        local victims = {}
        for i = 1, 7 do
            victims[i] = unit(Roles.warcraft, "hfoo", GetUnitX(t2) + 100 + 20 * i, GetUnitY(t2), {hp = 500, maxHp = 500})
        end
        rec.hits = {}
        ev.damage, ev.attack = 100, true
        Events.emit("damaging", t2, victims[1])
        Events.emit("damaging", t1, victims[1])
        ev.damage, ev.attack = 0, false
        advance(0.01)
        local fromT2, fromT1 = 0, 0
        for _, h in ipairs(rec.hits) do
            if h.src == t2 then fromT2 = fromT2 + 1 end
            if h.src == t1 then fromT1 = fromT1 + 1 end
        end
        check("tier 2 multishot hits 5 more", fromT2 == S.GLYPH.extra, fromT2)
        check("tier 1 has no multishot", fromT1 == 0, fromT1)
        advance(S.GLYPH.buildings + 0.05)
        check("glyph ends", not S.glyphActive() and rec.invul[t1] == false, tostring(rec.invul[t1]))
        check("tier protection outlasts the glyph", rec.invul[t2] == true)
        if dc then check("creeps lose the glyph", not Mods.has(dc, "glyph")) end
        -- the first tier 2 tower to fall makes it ready, the next one does not
        local b2, top2 = S.towers.bot[2], S.towers.top[2]
        flag(b2, {structure = true})
        flag(top2, {structure = true})
        S.glyphAt = Timer.now() + 100
        b2.dead = true
        Events.emit("death", b2, foe)
        check("first tier 2 refreshes the glyph", S.glyphLeft() == 0, S.glyphLeft())
        S.glyphAt = Timer.now() + 100
        top2.dead = true
        Events.emit("death", top2, foe)
        check("second tier 2 does not", S.glyphLeft() > 0, S.glyphLeft())

        ---------------------------------------------------------------- Scan
        foe.x, foe.y = X + 300, Y
        rec.pings, rec.effects = {}, {}
        Lane.scanCharges, Lane.scanRestoreAt = 1, Timer.now() + Lane.SCAN.restore
        check("scan used", Lane.scan(p0, X, Y) == true and Lane.scanCharges == 0)
        local red = 0
        for _, pg in ipairs(rec.pings) do if pg.r == 255 and pg.g < 100 then red = red + 1 end end
        check("scan finds the enemy hero", red >= 1, red)
        check("scan sweep shown to the Dota player", rec.effects[1] ~= nil and rec.effects[1] ~= "", rec.effects[1])
        check("no charge, no scan", Lane.scan(p0, X, Y) == false
            and string.find(errText(), Lane.text("dota_hud_error_cant_radar"), 1, true) ~= nil, errText())
        advance(Lane.SCAN.duration + 0.1)
        Lane.scanRestoreAt = Timer.now()
        local left = Lane.scanLeft()
        check("charge restores", Lane.scanCharges == 1 and left > 0, Lane.scanCharges)
        if G.started then
            G.armScan(p0)
            check("scan button arms targeting", G.armed[0] == true)
            check("a click on the HUD keeps it armed", G.mouse(p0, MOUSE_BUTTON_TYPE_LEFT, 0, 0) == false and G.armed[0])
            check("a ground click scans", G.mouse(p0, MOUSE_BUTTON_TYPE_LEFT, X, Y) == true and Lane.scanCharges == 0)
            check("disarmed after the scan", not G.armed[0])
            Lane.scanCharges = 1
            G.armScan(p0)
            G.mouse(p0, MOUSE_BUTTON_TYPE_RIGHT, X, Y)
            check("right click cancels", not G.armed[0] and Lane.scanCharges == 1)
        end

        ---------------------------------------------------------------- buyback
        local hero = H.bySlot[0]
        local kept = {}
        for _, h in pairs({hero, H.bySlot[1]}) do kept[h] = h.level end
        if hero then
            flag(hero, {hero = true, level = 10, dead = false})
            local respawns = 0
            Events.on("hero_respawned", function(u) if u == hero then respawns = respawns + 1 end end)
            hero.dead = true
            Events.emit("death", hero, foe)
            local wait = H.respawnTime(10)
            check("respawn scheduled", H.respawnAt[hero] and near(H.respawnAt[hero] - Timer.now(), wait, 0.01))
            check("dead hero found", E.deadHero(p0) == hero)
            if G.started then
                G.tick()
                check("buyback button while dead", mockHud.shown(G.F.buy)
                    and string.find(G.F.buyText.t.text, tostring(E.buybackCost(p0)), 1, true) ~= nil, G.F.buyText.t.text)
            end
            setGold(0, 100)
            check("buyback needs the gold", E.buyback(p0) == false
                and string.find(errText(), Lane.text("dota_hud_error_not_enough_gold"), 1, true) ~= nil, errText())
            setGold(0, 5000)
            local worth = E.netWorth(p0)
            local cost = E.buybackCost(p0)
            check("buyback cost", worth >= 5000 and cost == 200 + math.floor(worth / 13), cost)
            local skipped = H.respawnAt[hero]
            check("buyback", E.buyback(p0) == true)
            check("buyback paid", gold(0) == 5000 - cost, gold(0))
            check("bought back at once", not hero.dead and respawns == 1 and H.respawnAt[hero] == nil, respawns)
            check("buyback cooldown", near(E.buybackLeft(p0), E.BUYBACK.cooldown, 0.01))
            check("buyback chat line", said(Lane.text("DOTA_Chat_BuyBack", "")), lastText())
            check("gold penalty", near(E.goldFactor(p0), 1 - E.BUYBACK.goldPenalty))
            local paid = E.earn(p0, 100)
            check("penalised earnings", paid >= 40 and paid <= 41, paid)
            advance(skipped - Timer.now() + 0.1)
            check("the skipped respawn never comes", respawns == 1, respawns)
            check("penalty ends with the skipped respawn", E.goldFactor(p0) == 1)
            if G.started then
                G.tick()
                check("no buyback button while alive", not mockHud.shown(G.F.buy))
                local h0 = mockHud.handles
                for _ = 1, 3 do G.tick() end
                check("no handles in local code", mockHud.handles == h0, mockHud.handles - h0)
            end
            hero.dead = true
            Events.emit("death", hero, foe)
            check("next death respawns later", near(H.respawnAt[hero] - Timer.now(), wait + E.BUYBACK.respawnPenalty, 0.01),
                H.respawnAt[hero] - Timer.now())
            check("buyback on cooldown", E.buyback(p0) == false
                and string.find(errText(), Lane.text("DOTA_Hud_BuybackOnCooldown"), 1, true) ~= nil, errText())
            advance(wait + E.BUYBACK.respawnPenalty + 0.1)
            check("fountain respawn", respawns == 2 and not hero.dead, respawns)
            hero.dead = true
            Events.emit("death", hero, foe)
            check("the penalty counts once", near(H.respawnAt[hero] - Timer.now(), wait, 0.01))
            advance(wait + 0.1)
            check("respawned again", respawns == 3, respawns)
            -- a bot buys back while its base is under attack
            local bot = H.bySlot[1]
            if bot and Roles.isBot(1) then
                flag(bot, {hero = true, level = 10, dead = true})
                Events.emit("death", bot, foe)
                setGold(1, 5000)
                local t3 = S.towers.mid[3]
                flag(t3, {structure = true})
                ev.damage = 10
                Events.emit("damaged", foe, t3)
                ev.damage = 0
                advance(1.1)
                check("bot buys back", not bot.dead and E.buybackLeft(p1) > 0, tostring(bot.dead))
            end
        else
            Log.warn("lane exercise: no hero in slot 0, buyback checks skipped")
        end

        ---------------------------------------------------------------- HUD buttons
        if G.started then
            local F, g, L = G.F, Hud.G, Hud.L
            G.tick()
            local gx, gy = mockHud.at(F.glyph)
            check("glyph button right of the minimap", gx and gx >= g.mapR and gy + G.L.BTN <= L.MAP_Y + L.MAP + 1e-6,
                tostring(gx) .. "," .. tostring(gy))
            local sx, sy = mockHud.at(F.scan)
            check("scan button under the glyph", sx == gx and sy < gy)
            check("buttons under the bottom blocker", mockHud.under(use("hud_kit").hit(F.glyph), Hud.F.fgBottom)
                and mockHud.under(use("hud_kit").hit(F.scan), Hud.F.fgBottom)
                and mockHud.under(use("hud_kit").hit(F.buy), Hud.F.fgBottom))
            check("buttons inside 4:3", gx >= 0 and gx + G.L.BTN <= 0.8 and sy >= 0)
            local bx, by = mockHud.at(F.buy)
            check("buyback above the stash row", bx and bx + G.L.BUY_W <= g.itemsR + 1e-6
                and by >= L.PANEL_H + 0.009 + (L.STASH_H or 0) - 1e-6, tostring(bx) .. "," .. tostring(by))
            S.glyphAt = Timer.now() + 50
            mockHud.click(F.glyph, p0)
            G.tick()
            check("glyph click on cooldown shows the error", mockHud.shown(F.err.box))
            check("glyph sweep while recharging", mockHud.shown(F.glyphCd.box) or mockHud.shown(F.glyphCd.wipe))
            S.glyphAt = Timer.now()
            mockHud.click(F.glyph, p0)
            check("glyph click", S.glyphActive())
            advance(S.GLYPH.buildings + 0.05)
            Lane.scanCharges = 1
            mockHud.click(F.scan, p0)
            check("scan click arms", G.armed[0] == true)
            G.mouse(p0, MOUSE_BUTTON_TYPE_RIGHT, 0, 0)
        end

        for _, u in ipairs(made) do u.dead = true end
        for h, level in pairs(kept) do h.level, h.dead = level, false end
        for _, u in ipairs({t1, t2, S.ancient, S.towers.bot[2], S.towers.top[2], S.towers.mid[3], hero, H.bySlot[1]}) do
            if u then rawset(u, "lx", nil) end
        end
        Log.info("lane exercise: " .. checks .. " checks, " .. failures .. " failed")
    end

    local prev = __mock.advance
    local done = false
    function __mock.advance(seconds)
        prev(seconds)
        if done or not defined("lane") then return end
        done = true
        install()
        local ok, err = xpcall(exercise, debug and debug.traceback or tostring)
        restore()
        if not ok then use("log").error("lane exercise crashed: " .. tostring(err)) end
        use("log").flush()
    end
end
