-- Dota 2 settings of the hero players, imported by the launcher: keys for the
-- abilities, items, TP scroll, shop and hero selection; quick cast and
-- double-tap self cast; camera distance and zoom lock; auto attack and
-- right-clicks on allies. Also Dota's right-click hold, which keeps moving
-- toward the cursor while the button is held and shows the holder a move
-- marker at each repeated move.
--
-- File: Documents\Warcraft III\CustomMapData\DotaVsCommander\dota_settings.txt,
-- written per PC by launcher\dvc_launcher\dota_settings.py (format there). It
-- is a Preload script that puts one "key=value;..." string into the tooltip of
-- the unused ability STASH; Preloader runs it here, after loading (never while
-- the map loads). Hero players without the file get Dota's defaults.
--
-- Multiplayer: the file stays on each PC. A hero player's client sends its key
-- fields with BlzSendSyncData; every client then registers the same key events
-- for that player and keeps the same key state. Item, TP and shop keys act in
-- those synced events (items through dota_items.lua, whose default Z X C V B N
-- then skip the player). Ability and select-hero keys are local UI on the
-- presser's client: ForceUIKey on the ability's own Warcraft hotkey,
-- selection; Dota's failed-cast sounds for an ability key are synced. Quick
-- casts and double-tap self casts of abilities are orders sent back with
-- BlzSendSyncData. Camera fields are local; auto attack and the right-click
-- hold act in synced code only.
--
-- The cursor: Reforged 2.0.1 has no native for the world point under the local
-- cursor (its game binary has no BlzGetMouseWorldX/Y), so every client keeps
-- each hero player's cursor from the synced mouse events. They are registered
-- here, after the start: mouse events crash while the map loads. Quick casts
-- at a point use that cursor; quick casts at a unit use the unit under the
-- local cursor (BlzGetMouseFocusUnit).
--
-- Warcraft's own ability hotkeys (Dota's defaults by command card cell,
-- CELL_KEYS in tools/gen_objects.py) cannot be switched off from Lua, so a key
-- that belongs to another cell or to a Warcraft command (M S H A P O) is
-- skipped and the native key keeps working.
--
-- Start in game.lua begin(), after the HUD: use("dota_settings").init()
define("dota_settings", function()
    local Log = use("log")
    local Timer = use("timer")
    local Events = use("events")
    local Roles = use("roles")
    local Safe = use("safe")
    local S = {started = false}

    local FILE = "DotaVsCommander\\dota_settings.txt"
    local STASH = FourCC("ANdc")            -- Dark Conversion: not in this map
    local EMPTY = "dvc-no-settings"
    local SYNC, CAST, SEL = "dvcset", "dvccast", "dvcsel"
    local VERSION = "1"
    -- Dota's keybind template ARROW and game defaults; cd is Dota's camera distance.
    S.DEFAULTS = "v=1;a1=81;a2=87;a3=69;a4=68;a5=70;a6=82;i1=90;i2=88;i3=67;i4=86;i5=66;i6=78;tp=84;"
        .. "sh=115;hs=112;aa=1;as=-1;ds=0;ta=0;fr=0;dt=1;di=1;to=0.6;qd=1;zl=0;rs=0;cd=1134"

    -- Warcraft's order ids
    local SMART, STOP, ATTACK, MOVE, AIMOVE, PATROL, HOLD = 851971, 851972, 851983, 851986, 851988, 851990, 851993
    local STOP_KEY = 0x53                   -- Warcraft's Stop hotkey (S)
    local HOLD_REPEAT = 0.15                -- seconds between the moves of a right-click hold
    local HOLD_MIN_MOVE = 16                -- ... and only once the cursor moved this far
    local CONFIRM_FX = "UI\\Feedback\\Confirmation\\Confirmation.mdl"   -- WC3's move marker
    local CONFIRM_TIME = 0.6                -- seconds a held-move marker stays: a short trail

    -- Synced iteration order. Abilities: Dota's slots Q W E D F R by their
    -- Warcraft cell (y * 4 + x) and native hotkey letter.
    local ACTIONS = {
        {field = "a1", kind = "ability", cell = 8, letter = "Q"},
        {field = "a2", kind = "ability", cell = 9, letter = "W"},
        {field = "a3", kind = "ability", cell = 10, letter = "E"},
        {field = "a4", kind = "ability", cell = 5, letter = "D"},
        {field = "a5", kind = "ability", cell = 6, letter = "F"},
        {field = "a6", kind = "ability", cell = 11, letter = "R"},
        {field = "i1", kind = "item", slot = 0},
        {field = "i2", kind = "item", slot = 1},
        {field = "i3", kind = "item", slot = 2},
        {field = "i4", kind = "item", slot = 3},
        {field = "i5", kind = "item", slot = 4},
        {field = "i6", kind = "item", slot = 5},
        {field = "tp", kind = "tp"},
        {field = "sh", kind = "shop", handled = 0x73},  -- dota_shop.lua registers F4 itself
        {field = "hs", kind = "hero", handled = 0x70},  -- Warcraft's F1 selects the hero
    }
    local NATIVE = {}
    for _, c in ipairs({"Q", "W", "E", "R", "D", "F", "G", "M", "S", "H", "A", "P", "O"}) do
        NATIVE[string.byte(c)] = true
    end

    local players = {}       -- slot -> settings and key state (synced)
    local cursor = {}        -- slot -> {x, y}: the world point under the player's cursor (synced)
    local hold = {}          -- slot -> {on, at, x, y}: right button held, last move (synced)
    local chosen = {}        -- slot -> the player's own selected units (synced through SEL)
    local mine = nil         -- local: this PC's settings
    local abilityLast = {}   -- local: ability field -> time of the last press
    local armed = {}         -- local: ability field -> quick cast waiting for the key release
    local sentSelection = "" -- local: the selection last sent
    local group, localGroup, acquireTrig = nil, nil, nil
    local behavior = nil

    local function heroes() return use("heroes") end

    local function alive(u)
        return u ~= nil and GetUnitTypeId(u) ~= 0 and not IsUnitType(u, UNIT_TYPE_DEAD)
    end

    local function isHeroHuman(slot)
        return Roles.humans[slot] == true and slot ~= SLOT_ANCIENTS and Roles.side(slot) == "dota"
    end

    local function clamp(v, lo, hi, def)
        v = tonumber(v)
        if not v then return def end
        return math.max(lo, math.min(hi, v))
    end

    local function round(v) return math.floor(v + 0.5) end

    -- Test builds: what a key or an order decided, written to the log at once.
    local function trace(fmt, ...)
        if BUILD_TEST_MODE then
            Log.info("dota_settings: " .. string.format(fmt, ...))
            Log.flush()
        end
    end

    ---------------------------------------------------------------- format

    function S.parse(s)
        local t = {}
        for k, v in string.gmatch(s or "", "(%w+)=([%w%.%-]*)") do t[k] = v end
        return t
    end

    -- "<vk>[-<meta>][q]" -> vk, meta, quick; nil when unbound or invalid.
    function S.binding(v)
        local vk, meta, q = string.match(v or "", "^(%d+)%-?(%d*)(q?)$")
        vk, meta = tonumber(vk), tonumber(meta) or 0
        if not vk or vk < 8 or vk > 254 or vk == 0x0D or vk == 0x1B or meta > 15 then return nil end
        return vk, meta, q == "q"
    end

    local function merged(raw)
        local t = S.parse(S.DEFAULTS)
        local got = S.parse(raw)
        if got.v == VERSION then
            for k, v in pairs(got) do t[k] = v end
        end
        return t
    end

    -- What every client needs: keys, auto attack, item double tap, quick cast edge.
    local function syncPayload(t)
        local out = {"v=" .. VERSION}
        for _, a in ipairs(ACTIONS) do out[#out + 1] = a.field .. "=" .. (t[a.field] or "") end
        for _, k in ipairs({"aa", "as", "ds", "ta", "fr", "di", "to", "qd"}) do
            out[#out + 1] = k .. "=" .. (t[k] or "")
        end
        return table.concat(out, ";")
    end

    local function mode(v, allowed, def)
        v = math.tointeger(tonumber(v))
        return (v ~= nil and allowed[v]) and v or def
    end

    ---------------------------------------------------------------- file and camera (local)

    local function readFile()
        local old = BlzGetAbilityTooltip(STASH, 0)
        BlzSetAbilityTooltip(STASH, EMPTY, 0)
        Preloader(FILE)
        local s = BlzGetAbilityTooltip(STASH, 0)
        BlzSetAbilityTooltip(STASH, old, 0)
        if s == nil or s == "" or s == EMPTY then return nil end
        return s
    end

    local function localSettings(raw)
        local t = merged(raw)
        return {raw = t, dt = t.dt == "1", to = clamp(t.to, 0, 2, 0.6), qd = t.qd ~= "0", zl = t.zl == "1",
                rs = t.rs == "1", cd = clamp(t.cd, 600, 2500, 1134)}
    end

    local function applyCamera()
        if mine then SetCameraField(CAMERA_FIELD_TARGET_DISTANCE, mine.cd, 0) end
    end

    local function lockZoom()
        if mine and mine.zl and math.abs(GetCameraField(CAMERA_FIELD_TARGET_DISTANCE) - mine.cd) > 1 then
            SetCameraField(CAMERA_FIELD_TARGET_DISTANCE, mine.cd, 0.2)
        end
    end

    ---------------------------------------------------------------- casting

    local function flags(name)
        if not behavior then
            behavior = {}
            for _, info in pairs(use("data.heroes")) do
                for _, ab in ipairs(info.abilities or {}) do behavior[ab.name] = ab.AbilityBehavior or "" end
            end
        end
        return behavior[name] or ""
    end

    -- Build data of a hero ability (tools/gen_objects.py): its order string
    -- (ids.orders) and Channel target kind (ids.ability_targets: 0 none,
    -- 1 unit, 2 point, 3 unit or point).
    local nameById = nil
    local function abilityName(id)
        if not nameById then
            nameById = {}
            for name, code in pairs(use("data.ids").abilities or {}) do nameById[FourCC(code)] = name end
        end
        return nameById[id]
    end

    local function buildKind(name)
        return name and (use("data.ids").ability_targets or {})[name]
    end

    -- unit target, point target
    local function targets(e)
        if not e then return false, false end
        local k = buildKind(e.name)
        if k then return k == 1 or k == 3, k == 2 or k == 3 end
        local f = flags(e.name)
        return string.find(f, "UNIT_TARGET") ~= nil, string.find(f, "POINT") ~= nil
    end

    -- The hero's own ability in `cell` (y * 4 + x) by the build data's cell
    -- (ids.ability_cells): the same on every client, so synced code may ask.
    -- Warcraft's button positions can be local (Rubick moves a stolen spell's
    -- button for its owner only).
    local function abilityAt(hero, cell)
        local key = heroes().keyOf[hero]
        local cells = use("data.ids").ability_cells or {}
        for _, e in ipairs(key and use("dota_hud").rowOf(key) or {}) do
            if e.id and cells[e.name] == cell and GetUnitAbilityLevel(hero, e.id) > 0 then return e end
        end
        return nil
    end

    local function hovered()
        local u = BlzGetMouseFocusUnit()
        if alive(u) then return u end
        return nil
    end

    local function itemTarget(it)
        local name = use("items").nameOf(it)
        return name and (use("data.ids").item_targets or {})[name] or "none"
    end

    local function tpSlot(hero)
        for i = 0, 5 do
            local it = UnitItemInSlot(hero, i)
            if it and use("items").nameOf(it) == "item_tpscroll" then return i end
        end
        return nil
    end

    -- Local: ask every client for a cast order at unit u.
    local function send(kind, what, u)
        BlzSendSyncData(CAST, string.format("%s|%d|%d|%d|%d", kind, what, GetHandleId(u),
            round(GetUnitX(u)), round(GetUnitY(u))))
    end

    local function findUnit(hid, x, y)
        local found = nil
        GroupEnumUnitsInRange(group, x, y, 600, nil)
        for i = 0, BlzGroupGetSize(group) - 1 do
            local u = BlzGroupUnitAt(group, i)
            if GetHandleId(u) == hid then
                found = u
                break
            end
        end
        GroupClear(group)
        return found
    end

    -- A hero ability cast by order, from the build data's order string and
    -- target kind; the Channel fields read at run time (Ncl6, Ncl2) are only
    -- a fallback. String orders go first, the way the bots cast (hero_bot.lua):
    -- the run-time path alone refused every quick cast in game (2026-10-11).
    -- Without a target unit the cast goes to x, y.
    local function castAbility(hero, id, target, x, y)
        local level = GetUnitAbilityLevel(hero, id)
        local name = abilityName(id)
        local order, kind = name and use("data.ids").orders[name], buildKind(name)
        local from = (order and "build" or "field") .. "/" .. (kind and "build" or "field")
        if level >= 1 and not (order and kind) then
            local ab = BlzGetUnitAbility(hero, id)
            if ab and not order then order = BlzGetAbilityStringLevelField(ab, ABILITY_SLF_BASE_ORDER_ID_NCL6, level - 1) end
            if ab and not kind then kind = BlzGetAbilityIntegerLevelField(ab, ABILITY_ILF_TARGET_TYPE, level - 1) end
        end
        if order == "" then order = nil end
        local ok, how = false, "no cast"
        if level >= 1 and order then
            if target and (kind == 1 or kind == 3) then
                ok, how = IssueTargetOrder(hero, order, target), "unit order by string"
                if not ok then ok, how = IssueTargetOrderById(hero, OrderId(order), target), "unit order by id" end
            elseif kind == 2 or kind == 3 then
                if target then x, y = GetUnitX(target), GetUnitY(target) end
                ok, how = IssuePointOrder(hero, order, x, y), "point order by string"
                if not ok then ok, how = IssuePointOrderById(hero, OrderId(order), x, y), "point order by id" end
            end
        end
        if BUILD_TEST_MODE then
            trace("cast %s level %d: order %s (id %d), kind %s, from %s, cooldown %.1f, mana %d of %d, %s -> %s",
                tostring(name), level, tostring(order), order and OrderId(order) or 0, tostring(kind), from,
                BlzGetUnitAbilityCooldownRemaining(hero, id), math.floor(GetUnitState(hero, UNIT_STATE_MANA)),
                level >= 1 and BlzGetUnitAbilityManaCost(hero, id, level - 1) or 0, how, tostring(ok))
        end
        return ok
    end

    -- An item waiting for its target (dota_items) takes the unit instead.
    local function castItem(p, hero, slot, target)
        local Items = use("dota_items")
        local pend = Items.pending[p]
        if not pend or pend.slot ~= slot or UnitItemInSlot(hero, slot) ~= pend.item then return false end
        Items.pending[p] = nil
        if pend.target == "unit" then return UnitUseItemTarget(hero, pend.item, target) end
        if pend.target == "point" then return UnitUseItemPoint(hero, pend.item, GetUnitX(target), GetUnitY(target)) end
        return false
    end

    -- "<kind>|<ability or item slot>|<unit handle>|<x>|<y>": qa quick cast at a
    -- unit, qp quick cast at the point x, y, sa self cast, qi item at a unit.
    local function onCast()
        local p = GetTriggerPlayer()
        local hero = heroes().bySlot[GetPlayerId(p)]
        local kind, what, hid, x, y = string.match(BlzGetTriggerSyncData() or "",
            "^(%a%a)|(%d+)|(%d+)|(%-?%d+)|(%-?%d+)$")
        if not kind or not alive(hero) then return end
        what, hid, x, y = math.tointeger(tonumber(what)), math.tointeger(tonumber(hid)), tonumber(x), tonumber(y)
        local ok = false
        if kind == "qp" then
            ok = castAbility(hero, what, nil, x, y)
        else
            local target = kind == "sa" and hero or findUnit(hid, x, y)
            if not target or not (target == hero or IsUnitVisible(target, p)) then return end
            if kind == "qa" or kind == "sa" then
                ok = castAbility(hero, what, target)
            elseif kind == "qi" and what <= 5 then
                ok = castItem(p, hero, what, target)
            end
        end
        trace("player %d %s order at %d,%d: %s", GetPlayerId(p), kind, x, y, ok and "issued" or "refused")
    end

    ---------------------------------------------------------------- keys

    -- Local: sends a quick cast at the cursor and closes Warcraft's targeting
    -- cursor if the key opened it. Returns what it aimed at, nil when nothing fits.
    local function quickCast(e, unitT, pointT, opened)
        local u = unitT and hovered()
        local c = cursor[GetPlayerId(GetLocalPlayer())] or {}
        local what
        if u then
            send("qa", e.id, u)
            what = string.format("the hovered unit at %d,%d", round(GetUnitX(u)), round(GetUnitY(u)))
        elseif pointT and c.x then
            BlzSendSyncData(CAST, string.format("qp|%d|0|%d|%d", e.id, round(c.x), round(c.y)))
            what = string.format("the cursor point %d,%d", round(c.x), round(c.y))
        else
            return nil
        end
        if opened then ForceUICancel() end
        return what
    end

    -- Local, on the presser's client. Dota: a quick-cast key casts a target
    -- ability at the cursor, on key press or release (dota_quickcast_onkeydown).
    -- Other presses open Warcraft's targeting cursor; only those count as the
    -- first tap of a double tap.
    local function pressAbility(p, hero, b)
        local now = Timer.now()
        local double = abilityLast[b.field] ~= nil and now - abilityLast[b.field] <= mine.to
        abilityLast[b.field] = now
        armed[b.field] = nil
        local e = alive(hero) and IsUnitSelected(hero, p) and abilityAt(hero, b.cell)
        local unitT, pointT = targets(e)
        local quick = b.quick and (unitT or pointT)
        local what
        if double and mine.dt and unitT then
            abilityLast[b.field] = nil
            ForceUICancel()
            send("sa", e.id, hero)
            what = "double tap, self cast"
        elseif quick and not mine.qd then
            armed[b.field] = {e = e, unitT = unitT, pointT = pointT}
            if not b.native then ForceUIKey(b.letter) end
            what = "quick cast on the key release"
        else
            what = quick and quickCast(e, unitT, pointT, b.native)
            local why = quick and "no hovered unit or cursor point, " or ""
            if what then
                abilityLast[b.field] = nil
                what = "quick cast at " .. what
            elseif not b.native then
                ForceUIKey(b.letter)
                what = why .. "Warcraft's targeting through " .. b.letter
            else
                what = why .. "Warcraft's own key " .. b.letter
            end
        end
        trace("key %s press: %s%s%s, quick %s -> %s", b.field, e and e.name or "no ability of the selected hero",
            unitT and " (unit)" or "", pointT and " (point)" or "", tostring(b.quick), what)
    end

    local function releaseAbility(b)
        local a = armed[b.field]
        if not a then return end
        armed[b.field] = nil
        local what = quickCast(a.e, a.unitT, a.pointT, true)
        if what then abilityLast[b.field] = nil end
        trace("key %s release: %s -> %s", b.field, a.e.name,
            what and ("quick cast at " .. what) or "nothing under the cursor, the targeting cursor stays")
    end

    -- Synced. A double tap uses a unit-target item on the hero. Quick cast:
    -- a point item fires at the cursor; a unit item takes the hovered unit
    -- once it waits for its target.
    local function pressItem(p, hero, b, st, double)
        local slot = b.slot
        if b.kind == "tp" then slot = alive(hero) and tpSlot(hero) end
        local it = slot and alive(hero) and UnitItemInSlot(hero, slot)
        if not it then
            st.last[b.field] = nil
            return
        end
        local kind = itemTarget(it)
        local Items = use("dota_items")
        if double and st.di and kind == "unit" then
            st.last[b.field] = nil
            Items.pending[p] = nil
            UnitUseItemTarget(hero, it, hero)
            return
        end
        local c = cursor[GetPlayerId(p)]
        if b.quick and kind == "point" and c and c.x then
            Items.pending[p] = nil
            UnitUseItemPoint(hero, it, c.x, c.y)
            return
        end
        Items.use(p, slot)
        if b.quick and kind == "unit" and p == GetLocalPlayer() then
            local u = hovered()
            if u then send("qi", slot, u) end
        end
    end

    -- Synced: the hero is one of the player's own selected units as last sent
    -- through SEL; until the first report it counts as selected.
    local function selected(slot, hero)
        local list = chosen[slot]
        if not list then return true end
        for _, u in ipairs(list) do
            if u == hero then return true end
        end
        return false
    end

    -- Synced. A key acts when pressed, with the modifiers held at that moment.
    -- A held key repeats its key-down event; it acts again only after its
    -- release, which is registered without modifiers so it always arrives.
    local function onKey(slot, b)
        local st = players[slot]
        local p = Player(slot)
        if not BlzGetTriggerPlayerIsKeyDown() then
            st.held[b.vk] = nil
            if b.kind == "ability" and p == GetLocalPlayer() then releaseAbility(b) end
            return
        end
        if st.held[b.vk] or BlzGetTriggerPlayerMetaKey() ~= b.meta then return end
        st.held[b.vk] = true
        local now = Timer.now()
        local double = st.last[b.field] ~= nil and now - st.last[b.field] <= st.to
        st.last[b.field] = now
        local hero = heroes().bySlot[slot]
        if b.kind == "shop" then
            use("dota_shop").toggle(p)
        elseif b.kind == "hero" then
            if hero and p == GetLocalPlayer() then
                ClearSelection()
                SelectUnit(hero, true)
                if double then PanCameraToTimed(GetUnitX(hero), GetUnitY(hero), 0) end
            end
        elseif b.kind == "ability" then
            -- Dota's failed-cast sounds (gamesounds), on every client alike
            local e = alive(hero) and selected(slot, hero) and abilityAt(hero, b.cell)
            if e and defined("gamesounds") then
                local ready = use("gamesounds").checkCast(hero, e.id)
                trace("player %d key %s: %s %s", slot, b.field, e.name,
                    ready and "ready" or "not ready, failed-cast sound")
            end
            if p == GetLocalPlayer() and mine then pressAbility(p, hero, b) end
        else
            pressItem(p, hero, b, st, double)
        end
    end

    local function register(slot, b)
        local trig, p, key = CreateTrigger(), Player(slot), ConvertOsKeyType(b.vk)
        BlzTriggerRegisterPlayerKeyEvent(trig, p, key, b.meta, true)
        BlzTriggerRegisterPlayerKeyEvent(trig, p, key, 0, false)
        TriggerAddAction(trig, function() Safe.call(onKey, slot, b) end)
    end

    -- Synced: the bindings that need a key event, in ACTIONS order.
    function S.bindings(t)
        local list, used, skipped = {}, {}, {}
        for _, a in ipairs(ACTIONS) do
            local vk, meta, quick = S.binding(t[a.field])
            if vk then
                local combo = vk * 16 + meta
                local own = a.kind == "ability" and meta == 0 and vk == string.byte(a.letter)
                if used[combo] or (not own and NATIVE[vk] and meta <= 1) then
                    skipped[#skipped + 1] = a.field
                elseif not (a.handled == vk and meta == 0) then
                    used[combo] = true
                    list[#list + 1] = {field = a.field, kind = a.kind, cell = a.cell, letter = a.letter,
                                       slot = a.slot, vk = vk, meta = meta, quick = quick, native = own}
                end
            end
        end
        return list, skipped
    end

    ---------------------------------------------------------------- auto attack (synced)
    -- Dota's options, as its settings panel describes them:
    --   Auto Attack (aa, for the hero and other player units) and Summoned Unit
    --   Auto Attack (as; -1 same as the hero):
    --     0 Never: never attack a new target without explicitly targeting it;
    --     1 Standard: attack any nearby target unless the unit has just moved,
    --       denied a creep, or pressed the stop or hold key;
    --     2 Always: attack any enemy in range.
    --   ds: while the Stop key is held, the units do not auto attack.
    --   ta: Hold forces Never and Stop forces Always until an attack order.
    --   fr: right-click on a friendly unit: 0 follow it, 1 attack it, 2 deny it
    --       if deniable, else follow (in this map 1 also follows a unit that
    --       cannot be denied).
    -- Warcraft's worker type carries the result: workers never take a target
    -- on their own, yet attack, deny and attack-move when told to. A unit
    -- that may not auto attack is made a worker and loses the type when it
    -- may again. The acquisition range did not hold: right after
    -- SetUnitAcquireRange(u, 0) and the range field set to 0 the hero still
    -- read 600 and kept running off to targets (log 2026-10-11). Units whose
    -- unit type is a worker (a persuaded acolyte) are left alone. The
    -- type is set again on the next tick of every order and twice a second.
    -- A unit that still takes a new target while it may not is stopped by the
    -- guard at once and again on the next tick unless a newer order came
    -- meanwhile: a stop inside the acquisition event can be overridden like
    -- one inside an order event.
    local units = {}         -- unit -> slot: the Dota players' units under these settings
    local lastOrder = {}     -- unit -> move, follow, stop, hold, deny, attack, amove or other
    local aim = {}           -- unit -> the target it was told to attack
    local forced = {}        -- unit -> the mode Hold or Stop forced (ta)
    local worker = {}        -- unit -> true: a worker by its own type, never changed here
    local orderNo = {}       -- unit -> count of its orders: a deferred stop yields to a newer one
    local QUIET = {move = true, follow = true, stop = true, hold = true, deny = true}
    local cancelling = nil   -- the unit the acquisition guard is stopping
    local holding = false    -- the right-click hold is issuing its moves
    local guardLogged = {}   -- unit -> time of the last guard trace

    local function modeOf(u, st)
        if forced[u] then return forced[u] end
        if st.as ~= -1 and not IsUnitType(u, UNIT_TYPE_HERO) then return st.as end
        return st.aa
    end

    local function mayAcquire(u, st)
        if st.stopHeld then return false end
        local m, last = modeOf(u, st), lastOrder[u]
        if m == 2 then return true end
        if m == 0 then return last == "amove" end
        return not QUIET[last]
    end

    local function refresh(u)
        local st = players[units[u]]
        if not st or GetUnitTypeId(u) == 0 or worker[u] then return end
        local quiet = not mayAcquire(u, st)
        if IsUnitType(u, UNIT_TYPE_PEON) ~= quiet then
            if quiet then UnitAddType(u, UNIT_TYPE_PEON) else UnitRemoveType(u, UNIT_TYPE_PEON) end
        end
    end

    local function refreshSoon(u)
        Timer.after(0, function() refresh(u) end)
    end

    local function track(u)
        if units[u] then
            refresh(u)
            return
        end
        local slot = GetPlayerId(GetOwningPlayer(u))
        if not players[slot] then return end
        units[u] = slot
        -- by the unit type, not the unit: an illusion may copy the added type
        worker[u] = IsUnitIdType(GetUnitTypeId(u), UNIT_TYPE_PEON) or nil
        TriggerRegisterUnitEvent(acquireTrig, u, EVENT_UNIT_ACQUIRED_TARGET)
        refresh(u)
    end

    -- Twice a second: every tracked unit's type again; removed units leave.
    local function reassert()
        for u in pairs(units) do
            if GetUnitTypeId(u) == 0 then
                units[u], lastOrder[u], aim[u], forced[u], worker[u], orderNo[u] = nil, nil, nil, nil, nil, nil
            else
                refresh(u)
            end
        end
    end

    local function classify(u, order, target)
        if order == STOP then return "stop" end
        if order == HOLD then return "hold" end
        if order == MOVE or order == AIMOVE then return "move" end
        if order == PATROL then return "amove" end
        if order == SMART or order == ATTACK then
            if not target then return order == ATTACK and "amove" or "move" end
            if IsUnitEnemy(target, GetOwningPlayer(u)) then return "attack" end
            return order == ATTACK and "deny" or "follow"
        end
        return "other"
    end

    -- Dota: allied creeps and summons below 50% health, buildings below 10%;
    -- heroes only under a few debuffs, left out here.
    local function deniable(u, t)
        if t == u or not alive(t) or IsUnitType(t, UNIT_TYPE_HERO) then return false end
        local share = GetWidgetLife(t) / math.max(1, BlzGetUnitMaxHP(t))
        return share < (IsUnitType(t, UNIT_TYPE_STRUCTURE) and 0.1 or 0.5)
    end

    local function onOrder(u, order, target)
        local slot = units[u]
        if not slot or u == cancelling then return end
        orderNo[u] = (orderNo[u] or 0) + 1
        local st = players[slot]
        local kind = classify(u, order, target)
        if kind == "follow" and st.fr > 0 and deniable(u, target) then
            -- an order given inside its own order event would be overridden
            Timer.after(0, function()
                if alive(u) and alive(target) then IssueTargetOrderById(u, ATTACK, target) end
            end)
        end
        if st.ta then
            if kind == "hold" then
                forced[u] = 0
            elseif kind == "stop" then
                forced[u] = 2
            elseif kind == "attack" or kind == "amove" or kind == "deny" then
                forced[u] = nil
            end
        end
        lastOrder[u] = kind
        aim[u] = (kind == "attack" or kind == "deny") and target or nil
        refresh(u)
        refreshSoon(u)
        local h = hold[slot]
        if h and h.on and not holding and order ~= SMART and order ~= MOVE and order ~= AIMOVE then
            h.on = false
            trace("player %d right-click hold ended by a new order", slot)
        end
    end

    local function stopUnit(u)
        cancelling = u
        IssueImmediateOrderById(u, STOP)
        cancelling = nil
        refresh(u)
    end

    local function onAcquire()
        local u, t = GetTriggerUnit(), GetEventTargetUnit()
        local st = players[units[u] or -1]
        if not st or u == cancelling or t == aim[u] or mayAcquire(u, st) then return end
        local wasWorker = IsUnitType(u, UNIT_TYPE_PEON)
        stopUnit(u)
        local slot, n, now = units[u], orderNo[u], Timer.now()
        local logIt = now - (guardLogged[u] or -10) > 2
        if logIt then
            guardLogged[u] = now
            trace("player %d unit took a new target after %s (mode %d, worker %s, target %.0f away): stopped",
                slot, tostring(lastOrder[u]), modeOf(u, st), tostring(wasWorker),
                t and math.sqrt((GetUnitX(t) - GetUnitX(u)) ^ 2 + (GetUnitY(t) - GetUnitY(u)) ^ 2) or -1)
        end
        Timer.after(0, function()
            if orderNo[u] ~= n or not alive(u) or mayAcquire(u, st) then return end
            if logIt then
                trace("player %d unit stopped again on the next tick, its order was %d", slot, GetUnitCurrentOrder(u))
            end
            stopUnit(u)
        end)
    end

    -- ds: Warcraft's Stop key held
    local function onStopKey(slot)
        local st = players[slot]
        local down = BlzGetTriggerPlayerIsKeyDown()
        if st.stopHeld == down then return end
        st.stopHeld = down
        for u, s in pairs(units) do
            if s == slot then refresh(u) end
        end
    end

    ---------------------------------------------------------------- mouse (synced)

    local function onMouseMove()
        local c = cursor[GetPlayerId(GetTriggerPlayer())]
        local x, y = BlzGetTriggerPlayerMouseX(), BlzGetTriggerPlayerMouseY()
        if c and (x ~= 0 or y ~= 0) then c.x, c.y = x, y end    -- 0, 0: over an opaque UI frame
        return c
    end

    -- Warcraft orders the click itself; while the button is held the hold
    -- repeats it as moves toward the cursor once the cursor moves on.
    local function onMouseButton(down)
        local slot = GetPlayerId(GetTriggerPlayer())
        local c, h = onMouseMove(), hold[slot]
        if not h or BlzGetTriggerPlayerMouseButton() ~= MOUSE_BUTTON_TYPE_RIGHT then return end
        local was = h.on
        h.on, h.at, h.x, h.y = down and c.x ~= nil, Timer.now(), c.x, c.y
        if h.on ~= was then trace("player %d right-click hold %s", slot, h.on and "started" or "released") end
    end

    -- The player's own selected units, else the hero.
    local function holdUnits(slot)
        local list = {}
        for _, u in ipairs(chosen[slot] or {}) do
            if alive(u) and GetOwningPlayer(u) == Player(slot) then list[#list + 1] = u end
        end
        local hero = heroes().bySlot[slot]
        if #list == 0 and alive(hero) then list[1] = hero end
        return list
    end

    -- Dota shows its move marker for every repeated right-click of a hold; here
    -- WC3's move confirmation, seen by the holder only: every client creates
    -- and frees the effect, the other players' with no model.
    local function marker(slot, x, y)
        local fx = AddSpecialEffect(Player(slot) == GetLocalPlayer() and CONFIRM_FX or "", x, y)
        Timer.after(CONFIRM_TIME, function() DestroyEffect(fx) end)
    end

    local function repeatHolds()
        local now = Timer.now()
        for _, slot in ipairs(Roles.heroSlots) do
            local h, c = hold[slot], cursor[slot]
            if h and h.on and now - h.at >= HOLD_REPEAT
                    and (math.abs(c.x - h.x) > HOLD_MIN_MOVE or math.abs(c.y - h.y) > HOLD_MIN_MOVE) then
                local list = holdUnits(slot)
                if #list == 0 then
                    h.on = false
                    trace("player %d right-click hold ended: no living unit", slot)
                else
                    h.at, h.x, h.y = now, c.x, c.y
                    holding = true
                    for _, u in ipairs(list) do IssuePointOrderById(u, MOVE, c.x, c.y) end
                    holding = false
                    marker(slot, c.x, c.y)
                end
            end
        end
    end

    local function onSelection()
        local p = GetTriggerPlayer()
        local want = {}
        for id in string.gmatch(BlzGetTriggerSyncData() or "", "%d+") do want[math.tointeger(tonumber(id))] = true end
        local list = {}
        GroupEnumUnitsOfPlayer(group, p, nil)
        for i = 0, BlzGroupGetSize(group) - 1 do
            local u = BlzGroupUnitAt(group, i)
            if want[GetHandleId(u)] then list[#list + 1] = u end
        end
        GroupClear(group)
        chosen[GetPlayerId(p)] = list
    end

    -- Local: the own selected units go to every client when they change.
    local function sendSelection()
        local lp = GetLocalPlayer()
        local ids = {}
        GroupEnumUnitsSelected(localGroup, lp, nil)
        for i = 0, BlzGroupGetSize(localGroup) - 1 do
            local u = BlzGroupUnitAt(localGroup, i)
            if u and GetOwningPlayer(u) == lp and #ids < 24 then ids[#ids + 1] = GetHandleId(u) end
        end
        GroupClear(localGroup)
        table.sort(ids)
        local s = table.concat(ids, ",")
        if s ~= sentSelection then
            sentSelection = s
            BlzSendSyncData(SEL, s == "" and "-" or s)
        end
    end

    ---------------------------------------------------------------- apply (synced)

    function S.apply(slot, payload)
        if players[slot] or not isHeroHuman(slot) then return end
        local t = merged(payload)
        local list, skipped = S.bindings(t)
        local st = {list = list, held = {}, last = {}, di = t.di == "1", to = clamp(t.to, 0, 2, 0.6),
                    aa = mode(t.aa, {[0] = true, true, true}, 1), as = mode(t.as, {[-1] = true, [0] = true, true, true}, -1),
                    ds = t.ds == "1", ta = t.ta == "1", fr = mode(t.fr, {[0] = true, true, true}, 0), stopHeld = false}
        players[slot] = st
        use("dota_items").custom[Player(slot)] = true
        for _, b in ipairs(list) do register(slot, b) end
        if st.ds then
            local trig, key = CreateTrigger(), ConvertOsKeyType(STOP_KEY)
            BlzTriggerRegisterPlayerKeyEvent(trig, Player(slot), key, 0, true)
            BlzTriggerRegisterPlayerKeyEvent(trig, Player(slot), key, 0, false)
            TriggerAddAction(trig, function() Safe.call(onStopKey, slot) end)
        end
        GroupEnumUnitsOfPlayer(group, Player(slot), nil)
        local own = {}
        for i = 0, BlzGroupGetSize(group) - 1 do own[#own + 1] = BlzGroupUnitAt(group, i) end
        GroupClear(group)
        for _, u in ipairs(own) do track(u) end
        local hero = heroes().bySlot[slot]
        if hero then track(hero) end
        Log.info(string.format("dota_settings: player %d, %d keys, auto attack %d, summons %d, stop held %s, "
            .. "toggle %s, right-click allies %d%s", slot, #list, st.aa, st.as, tostring(st.ds), tostring(st.ta), st.fr,
            #skipped > 0 and (", kept Warcraft's keys for " .. table.concat(skipped, " ")) or ""))
    end

    function S.applied(slot) return players[slot] and players[slot].list end
    function S.mine() return mine end
    function S.cursor(slot) return cursor[slot] end
    function S.holding(slot) return hold[slot] ~= nil and hold[slot].on end

    function S.init()
        if S.started then return end
        S.started = true
        group, localGroup = CreateGroup(), CreateGroup()
        local syncTrig, castTrig, selTrig = CreateTrigger(), CreateTrigger(), CreateTrigger()
        local downTrig, upTrig, moveTrig = CreateTrigger(), CreateTrigger(), CreateTrigger()
        acquireTrig = CreateTrigger()
        for _, slot in ipairs(Roles.heroSlots) do
            if isHeroHuman(slot) then
                local p = Player(slot)
                BlzTriggerRegisterPlayerSyncEvent(syncTrig, p, SYNC, false)
                BlzTriggerRegisterPlayerSyncEvent(castTrig, p, CAST, false)
                BlzTriggerRegisterPlayerSyncEvent(selTrig, p, SEL, false)
                TriggerRegisterPlayerEvent(downTrig, p, EVENT_PLAYER_MOUSE_DOWN)
                TriggerRegisterPlayerEvent(upTrig, p, EVENT_PLAYER_MOUSE_UP)
                TriggerRegisterPlayerEvent(moveTrig, p, EVENT_PLAYER_MOUSE_MOVE)
                cursor[slot], hold[slot] = {}, {on = false, at = 0}
            end
        end
        TriggerAddAction(syncTrig, function()
            Safe.call(function() S.apply(GetPlayerId(GetTriggerPlayer()), BlzGetTriggerSyncData()) end)
        end)
        TriggerAddAction(castTrig, function() Safe.call(onCast) end)
        TriggerAddAction(selTrig, function() Safe.call(onSelection) end)
        TriggerAddAction(downTrig, function() Safe.call(onMouseButton, true) end)
        TriggerAddAction(upTrig, function() Safe.call(onMouseButton, false) end)
        TriggerAddAction(moveTrig, function() Safe.call(onMouseMove) end)
        TriggerAddAction(acquireTrig, function() Safe.call(onAcquire) end)
        Events.on("order", onOrder)
        Events.on("unit_enter", track)
        Events.on("hero_spawned", function(u, _, slot)
            track(u)
            if Player(slot) == GetLocalPlayer() then applyCamera() end
        end)
        Events.on("hero_respawned", function(u, _, slot)
            refresh(u)
            if Player(slot) == GetLocalPlayer() and mine and mine.rs then
                PanCameraToTimed(GetUnitX(u), GetUnitY(u), 0)
            end
        end)
        Timer.every(0.25, lockZoom)
        Timer.every(0.5, reassert)
        local ticks = 0
        Timer.every(0.05, function()
            repeatHolds()
            ticks = ticks + 1
            if mine and ticks % 2 == 0 then sendSelection() end
        end)
        -- a client that never reports (dropped, failed) leaves its player on the defaults
        Timer.after(10, function()
            for _, slot in ipairs(Roles.heroSlots) do
                if isHeroHuman(slot) and not players[slot] then S.apply(slot, "") end
            end
        end)

        local lp = GetLocalPlayer()
        if not isHeroHuman(GetPlayerId(lp)) then return end
        local ok, raw = Safe.call(readFile)
        raw = ok and raw or nil
        if raw and S.parse(raw).v ~= VERSION then
            Log.warn("dota_settings: the settings file has another format, using Dota's defaults")
            raw = nil
        end
        Log.info("dota_settings: " .. (raw and "settings from the launcher" or "no settings file, Dota's defaults"))
        mine = localSettings(raw)
        applyCamera()
        BlzSendSyncData(SYNC, syncPayload(mine.raw))
    end

    return S
end)
