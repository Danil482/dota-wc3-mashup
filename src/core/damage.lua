-- Dota-style damage. Spell damage is computed here (magic resistance, armor,
-- spell amplification) and dealt as chaos/universal so WC3's own tables add
-- nothing on top. Attack modifiers (crits, bashes, mana burn, damage block,
-- lifesteal) hook into the native damage events.
define("damage", function()
    local Events = use("events")
    local U = use("util")
    local Damage = {PHYSICAL = "physical", MAGICAL = "magical", PURE = "pure"}

    local current = nil       -- set while Damage.deal() runs UnitDamageTarget
    local attackHooks = {}    -- fn(source, target, info) before armor; may edit info.amount
    local afterHooks = {}     -- fn(source, target, amount, info) after reductions

    local function mods()
        return use("mods")
    end

    function Damage.armorFactor(armor)
        return 1 - (0.06 * armor) / (1 + 0.06 * math.abs(armor))
    end

    -- Heroes start at 25 %, intelligence adds 0.1 % per point, and every
    -- "magic_resist" modifier stacks multiplicatively.
    function Damage.magicResist(u)
        local keep = 1.0
        if IsUnitType(u, UNIT_TYPE_HERO) then
            keep = keep * 0.75 * (1 - 0.001 * GetHeroInt(u, true))
        end
        for _, v in ipairs(mods().values(u, "magic_resist")) do
            keep = keep * (1 - v)
        end
        return 1 - keep
    end

    -- Returns the damage actually dealt. opts: {pierce = true} ignores spell
    -- immunity, {noAmp = true} skips spell amplification, {tag = "..."} is
    -- passed to the after-damage hooks.
    function Damage.deal(source, target, amount, kind, opts)
        if not U.alive(target) or amount <= 0 then
            return 0
        end
        opts = opts or {}
        if kind == Damage.MAGICAL then
            if IsUnitType(target, UNIT_TYPE_MAGIC_IMMUNE) and not opts.pierce then
                return 0
            end
            amount = amount * (1 - Damage.magicResist(target))
        elseif kind == Damage.PHYSICAL then
            amount = amount * Damage.armorFactor(BlzGetUnitArmor(target))
        end
        if source and not opts.noAmp then
            amount = amount * (1 + mods().sum(source, "spell_amp"))
        end
        local before = GetWidgetLife(target)
        current = {kind = kind, source = source, opts = opts}
        UnitDamageTarget(source, target, amount, false, false, ATTACK_TYPE_CHAOS, DAMAGE_TYPE_UNIVERSAL, WEAPON_TYPE_WHOKNOWS)
        current = nil
        return math.max(0, before - GetWidgetLife(target))
    end

    -- Heals scale with the target's "heal_amp" modifiers, as in Dota.
    function Damage.heal(target, amount)
        if U.alive(target) and amount > 0 then
            amount = amount * (1 + mods().sum(target, "heal_amp"))
            SetWidgetLife(target, GetWidgetLife(target) + amount)
        end
    end

    -- fn(source, target, info): info.amount may be changed; info.attack is
    -- true for basic attacks; info.spell holds Damage.deal's context.
    function Damage.onDamaging(fn)
        attackHooks[#attackHooks + 1] = fn
    end

    function Damage.onDamaged(fn)
        afterHooks[#afterHooks + 1] = fn
    end

    function Damage.init()
        Events.on("damaging", function(source, target)
            local info = {
                amount = GetEventDamage(),
                attack = BlzGetEventIsAttack() and current == nil,
                spell = current,
            }
            for i = 1, #attackHooks do
                attackHooks[i](source, target, info)
            end
            -- Damage block applies to basic attacks only, after other hooks
            if info.attack then
                local block = mods().max(target, "damage_block")
                if block > 0 then
                    info.amount = math.max(0, info.amount - block)
                end
            end
            BlzSetEventDamage(info.amount)
        end)
        Events.on("damaged", function(source, target)
            local amount = GetEventDamage()
            local info = {attack = BlzGetEventIsAttack() and current == nil, spell = current}
            if info.attack and source then
                local ls = mods().sum(source, "lifesteal")
                if ls > 0 and not IsUnitType(target, UNIT_TYPE_STRUCTURE) then
                    Damage.heal(source, amount * ls)
                end
            elseif info.spell and source then
                local sls = mods().sum(source, "spell_lifesteal")
                if sls > 0 then
                    Damage.heal(source, amount * sls * (IsUnitType(target, UNIT_TYPE_HERO) and 1 or 0.2))
                end
            end
            for i = 1, #afterHooks do
                afterHooks[i](source, target, amount, info)
            end
        end)
    end

    return Damage
end)
