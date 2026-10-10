-- Event bus. Native player-unit events for every player slot are funnelled
-- into named Lua events; handlers run under Safe.call so one failing handler
-- cannot break the others.
define("events", function()
    local Safe = use("safe")
    local Events = {}
    local handlers = {}

    function Events.on(name, fn)
        local list = handlers[name]
        if not list then
            list = {}
            handlers[name] = list
        end
        list[#list + 1] = fn
    end

    function Events.emit(name, ...)
        local list = handlers[name]
        if list then
            for i = 1, #list do
                Safe.call(list[i], ...)
            end
        end
    end

    local function playerUnitEvent(event, name, collect)
        local trig = CreateTrigger()
        for i = 0, bj_MAX_PLAYER_SLOTS - 1 do
            TriggerRegisterPlayerUnitEvent(trig, Player(i), event, nil)
        end
        TriggerAddAction(trig, function()
            Safe.call(function()
                Events.emit(name, collect())
            end)
        end)
    end

    local function spell()
        return GetTriggerUnit(), GetSpellAbilityId(), GetSpellTargetUnit(), GetSpellTargetX(), GetSpellTargetY()
    end

    function Events.init()
        playerUnitEvent(EVENT_PLAYER_UNIT_SPELL_CHANNEL, "spell_channel", spell)
        playerUnitEvent(EVENT_PLAYER_UNIT_SPELL_EFFECT, "spell_effect", spell)
        playerUnitEvent(EVENT_PLAYER_UNIT_SPELL_ENDCAST, "spell_endcast", spell)
        playerUnitEvent(EVENT_PLAYER_UNIT_DEATH, "death", function()
            return GetTriggerUnit(), GetKillingUnit()
        end)
        playerUnitEvent(EVENT_PLAYER_HERO_LEVEL, "hero_level", function()
            return GetTriggerUnit()
        end)
        playerUnitEvent(EVENT_PLAYER_HERO_SKILL, "hero_skill", function()
            return GetTriggerUnit(), GetLearnedSkill()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_PICKUP_ITEM, "item_pickup", function()
            return GetTriggerUnit(), GetManipulatedItem()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_DROP_ITEM, "item_drop", function()
            return GetTriggerUnit(), GetManipulatedItem()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_USE_ITEM, "item_use", function()
            return GetTriggerUnit(), GetManipulatedItem()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_ISSUED_ORDER, "order", function()
            return GetTriggerUnit(), GetIssuedOrderId(), nil, nil, nil
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_ISSUED_POINT_ORDER, "order", function()
            return GetTriggerUnit(), GetIssuedOrderId(), nil, GetOrderPointX(), GetOrderPointY()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_ISSUED_TARGET_ORDER, "order", function()
            return GetTriggerUnit(), GetIssuedOrderId(), GetOrderTargetUnit(), nil, nil
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_ATTACKED, "attacked", function()
            return GetAttacker(), GetTriggerUnit()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_TRAIN_FINISH, "trained", function()
            return GetTriggerUnit(), GetTrainedUnit()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_CONSTRUCT_START, "construct_start", function()
            return GetConstructingStructure()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_CONSTRUCT_FINISH, "construct_finish", function()
            return GetConstructedStructure()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_RESEARCH_FINISH, "research_finish", function()
            return GetTriggerUnit(), GetResearched()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_UPGRADE_FINISH, "upgrade_finish", function()
            return GetTriggerUnit()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_SUMMON, "summon", function()
            return GetSummoningUnit(), GetSummonedUnit()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_DAMAGING, "damaging", function()
            return GetEventDamageSource(), BlzGetEventDamageTarget()
        end)
        playerUnitEvent(EVENT_PLAYER_UNIT_DAMAGED, "damaged", function()
            return GetEventDamageSource(), BlzGetEventDamageTarget()
        end)

        local enter = CreateTrigger()
        local world = CreateRegion()
        RegionAddRect(world, GetWorldBounds())
        TriggerRegisterEnterRegion(enter, world, nil)
        TriggerAddAction(enter, function()
            Safe.call(function()
                Events.emit("unit_enter", GetTriggerUnit())
            end)
        end)

        local leave = CreateTrigger()
        for i = 0, bj_MAX_PLAYERS - 1 do
            TriggerRegisterPlayerEvent(leave, Player(i), EVENT_PLAYER_LEAVE)
        end
        TriggerAddAction(leave, function()
            Safe.call(function()
                Events.emit("player_leave", GetTriggerPlayer())
            end)
        end)
    end

    return Events
end)
