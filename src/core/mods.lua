-- Modifiers (buffs and debuffs). A modifier is a keyed bundle of properties on
-- a unit with an optional duration, tick and visual. Numeric properties are
-- summed into stats by the "stats" module; status properties (stun, silence,
-- root, disarm, hex, invisible, magic_immune, invulnerable, break) are
-- reference counted and applied to the unit when their count changes.
define("mods", function()
    local Timer = use("timer")
    local U = use("util")
    local Mods = {}

    local units = {}          -- unit -> {key -> mod}
    local counts = {}         -- unit -> {status -> n}
    local disabled = {}       -- unit -> list of ability ids disabled by silence

    local SHEEP = FourCC("nshe")
    local ATTACK = FourCC("Aatk")
    local INVIS = FourCC("Apiv")
    local IMMUNE = FourCC("ACmi")

    -- Abilities a silence disables: registered hero abilities on the unit.
    Mods.silenceable = function(u) return {} end

    local apply = {
        stun = function(u, on) BlzPauseUnitEx(u, on) end,
        silence = function(u, on)
            if on then
                local list = Mods.silenceable(u)
                disabled[u] = list
                for i = 1, #list do BlzUnitDisableAbility(u, list[i], true, false) end
            else
                local list = disabled[u] or {}
                for i = 1, #list do BlzUnitDisableAbility(u, list[i], false, false) end
                disabled[u] = nil
            end
        end,
        root = function(u, on)
            -- the setter takes radians, the default getter returns degrees
            SetUnitPropWindow(u, on and 0 or GetUnitDefaultPropWindow(u) * math.pi / 180)
        end,
        disarm = function(u, on) BlzUnitDisableAbility(u, ATTACK, on, false) end,
        hex = function(u, on) BlzSetUnitSkin(u, on and SHEEP or GetUnitTypeId(u)) end,
        invisible = function(u, on)
            if on then UnitAddAbility(u, INVIS) else UnitRemoveAbility(u, INVIS) end
        end,
        magic_immune = function(u, on)
            if on then UnitAddAbility(u, IMMUNE) else UnitRemoveAbility(u, IMMUNE) end
        end,
        invulnerable = function(u, on) SetUnitInvulnerable(u, on) end,
    }

    -- Hex also silences and disarms.
    local IMPLIED = {silence = "hex", disarm = "hex"}

    local function recount(u)
        local now = {}
        for _, m in pairs(units[u] or {}) do
            for k, v in pairs(m.props) do
                if v == true then now[k] = (now[k] or 0) + 1 end
            end
        end
        local before = counts[u] or {}
        for status, fn in pairs(apply) do
            local via = IMPLIED[status]
            local was = (before[status] or 0) > 0 or (via ~= nil and (before[via] or 0) > 0)
            local is = (now[status] or 0) > 0 or (via ~= nil and (now[via] or 0) > 0)
            if was ~= is then fn(u, is) end
        end
        counts[u] = now
        use("stats").refresh(u)
    end

    local function destroyVisual(m)
        if m.fx then
            DestroyEffect(m.fx)
            m.fx = nil
        end
    end

    -- spec: duration, source, props, effect, attach, tick, onTick(m),
    -- onRemove(m, expired), debuff, dispel ("basic" | "strong" | "none"),
    -- stacks. Re-adding a key replaces props and refreshes the duration.
    function Mods.add(u, key, spec)
        if not U.alive(u) then return nil end
        local list = units[u]
        if not list then
            list = {}
            units[u] = list
        end
        local m = list[key]
        if m then
            destroyVisual(m)
        else
            m = {key = key, unit = u}
            list[key] = m
        end
        m.source = spec.source
        m.props = spec.props or {}
        m.debuff = spec.debuff or false
        m.dispel = spec.dispel or "basic"
        m.stacks = spec.stacks or m.stacks or 1
        m.expires = spec.duration and (Timer.now() + spec.duration) or nil
        m.duration = spec.duration
        m.tick, m.onTick, m.onRemove = spec.tick, spec.onTick, spec.onRemove
        m.nextTick = spec.tick and (Timer.now() + spec.tick) or nil
        m.persist = spec.persist or false
        if spec.effect then
            m.fx = AddSpecialEffectTarget(spec.effect, u, spec.attach or "origin")
        end
        recount(u)
        return m
    end

    local function drop(u, key, expired)
        local list = units[u]
        local m = list and list[key]
        if not m then return end
        list[key] = nil
        destroyVisual(m)
        recount(u)
        if m.onRemove then m.onRemove(m, expired) end
    end

    function Mods.remove(u, key) drop(u, key, false) end

    -- Extend or reset a modifier's remaining time without touching its
    -- visual or properties. Returns false if the unit doesn't have it.
    function Mods.refresh(u, key, duration)
        local m = Mods.get(u, key)
        if not m then return false end
        m.duration = duration or m.duration
        m.expires = m.duration and (Timer.now() + m.duration) or nil
        return true
    end

    function Mods.get(u, key)
        local list = units[u]
        return list and list[key]
    end

    function Mods.has(u, key) return Mods.get(u, key) ~= nil end

    function Mods.remaining(u, key)
        local m = Mods.get(u, key)
        if not m then return 0 end
        return m.expires and math.max(0, m.expires - Timer.now()) or math.huge
    end

    function Mods.sum(u, prop)
        local total = 0
        for _, m in pairs(units[u] or {}) do
            local v = m.props[prop]
            if type(v) == "number" then total = total + v * (m.props.perStack and m.stacks or 1) end
        end
        return total
    end

    function Mods.max(u, prop)
        local best = 0
        for _, m in pairs(units[u] or {}) do
            local v = m.props[prop]
            if type(v) == "number" and v > best then best = v end
        end
        return best
    end

    function Mods.values(u, prop)
        local out = {}
        for _, m in pairs(units[u] or {}) do
            local v = m.props[prop]
            if type(v) == "number" then out[#out + 1] = v end
        end
        return out
    end

    function Mods.flag(u, status)
        return ((counts[u] or {})[status] or 0) > 0
    end

    -- Remove dispellable modifiers. opts: debuffs, buffs, strong
    function Mods.dispel(u, opts)
        local keys = {}
        for key, m in pairs(units[u] or {}) do
            local kindOk = (m.debuff and opts.debuffs) or (not m.debuff and opts.buffs)
            local levelOk = m.dispel == "basic" or (m.dispel == "strong" and opts.strong)
            if kindOk and levelOk then keys[#keys + 1] = key end
        end
        for _, key in ipairs(keys) do drop(u, key, false) end
    end

    function Mods.clear(u, keepPersistent)
        local keys = {}
        for key, m in pairs(units[u] or {}) do
            if not (keepPersistent and m.persist) then keys[#keys + 1] = key end
        end
        for _, key in ipairs(keys) do drop(u, key, false) end
    end

    function Mods.init()
        Timer.onFrame(function()
            local now = Timer.now()
            -- snapshot first: callbacks may add or remove modifiers anywhere
            local todo = {}
            for u in pairs(units) do todo[#todo + 1] = u end
            for _, u in ipairs(todo) do
                local list = units[u]
                if list then
                    local alive = U.alive(u)
                    local ticks, expired = {}, {}
                    for key, m in pairs(list) do
                        if not alive then
                            if not m.persist then expired[#expired + 1] = key end
                        else
                            if m.nextTick and now >= m.nextTick then ticks[#ticks + 1] = m end
                            if m.expires and now >= m.expires then expired[#expired + 1] = key end
                        end
                    end
                    for _, m in ipairs(ticks) do
                        m.nextTick = m.nextTick + m.tick
                        if m.onTick then m.onTick(m) end
                    end
                    for _, key in ipairs(expired) do drop(u, key, alive) end
                    if units[u] and next(units[u]) == nil then
                        units[u], counts[u] = nil, nil
                    end
                end
            end
        end)
    end

    return Mods
end)
