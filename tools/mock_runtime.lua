-- Behaviour for the natives the map leans on, layered over the generated stubs.
-- Simulates players, timers, triggers, groups, units and Preload file output.
bj_MAX_PLAYERS = 24
bj_MAX_PLAYER_SLOTS = 28
bj_PLAYER_NEUTRAL_VICTIM = 25
bj_PLAYER_NEUTRAL_EXTRA = 26
PLAYER_NEUTRAL_AGGRESSIVE = 24
PLAYER_NEUTRAL_PASSIVE = 27

function FourCC(s) return string.unpack(">I4", s) end

local players = {}
function Player(i)
    local p = players[i]
    if not p then
        p = __handle("player")
        p.id = i
        p.state = {}
        players[i] = p
    end
    return p
end
function GetPlayerId(p) return p.id end
__mock.humans = {[0] = true}
function GetPlayerController(p)
    if p.id <= 5 then return MAP_CONTROL_USER end
    return MAP_CONTROL_COMPUTER
end
function GetPlayerSlotState(p)
    if __mock.humans[p.id] then return PLAYER_SLOT_STATE_PLAYING end
    return PLAYER_SLOT_STATE_EMPTY
end
function GetPlayerState(p, s) return p.state[s] or 0 end
function SetPlayerState(p, s, v) p.state[s] = v end

-- Timers
__mock.now = 0
__mock.timers = {}
function CreateTimer() return __handle("timer") end
function TimerStart(t, timeout, periodic, fn)
    t.active, t.timeout, t.periodic, t.fn = true, timeout, periodic, fn
    t.start, t.due = __mock.now, __mock.now + timeout
    __mock.timers[t] = true
end
function PauseTimer(t) t.active = false end
function DestroyTimer(t) t.active = false; __mock.timers[t] = nil end
function TimerGetElapsed(t) return __mock.now - (t.start or __mock.now) end
function __mock.advance(seconds)
    local target = __mock.now + seconds
    while true do
        local nextT, nextDue = nil, math.huge
        for t in pairs(__mock.timers) do
            if t.active and t.due <= target and t.due < nextDue then
                nextT, nextDue = t, t.due
            end
        end
        if not nextT then break end
        __mock.now = nextDue
        if nextT.periodic then nextT.due = nextT.due + math.max(nextT.timeout, 0.001) else nextT.active = false end
        if nextT.fn then nextT.fn() end
    end
    __mock.now = target
end

-- Triggers keep their actions so tests can fire synthetic events
__mock.triggers = {}
function CreateTrigger()
    local t = __handle("trigger")
    t.actions, t.events = {}, {}
    __mock.triggers[#__mock.triggers + 1] = t
    return t
end
function TriggerAddAction(t, fn) t.actions[#t.actions + 1] = fn return __handle("triggeraction") end
function TriggerRegisterPlayerUnitEvent(t, p, ev, f) t.events[#t.events + 1] = ev return __handle("event") end

-- Preload file output
__mock.files, __mock.preload = {}, {}
function PreloadGenClear() __mock.preload = {} end
function Preload(s) __mock.preload[#__mock.preload + 1] = s end
function PreloadGenEnd(path) __mock.files[path] = table.concat(__mock.preload, "\n") end

__mock.printed = {}
function print(...)
    local t = {}
    for i = 1, select("#", ...) do t[#t + 1] = tostring(select(i, ...)) end
    __mock.printed[#__mock.printed + 1] = table.concat(t, " ")
end

-- Units: a minimal table model good enough for init code paths
__mock.units = {}
function CreateUnit(p, id, x, y, face)
    local u = __handle("unit")
    u.owner, u.typeId, u.x, u.y, u.face = p, id, x, y, face
    u.life, u.maxLife, u.mana, u.abilities = 100, 100, 0, {}
    __mock.units[#__mock.units + 1] = u
    return u
end
function GetUnitTypeId(u) return u and u.typeId or 0 end
function GetOwningPlayer(u) return u.owner end
function GetUnitX(u) return u.x end
function GetUnitY(u) return u.y end
function SetUnitX(u, x) u.x = x end
function SetUnitY(u, y) u.y = y end
function SetUnitPosition(u, x, y) u.x, u.y = x, y end
function IsUnitType(u, t) return t == UNIT_TYPE_DEAD and u.dead == true end
function KillUnit(u) u.dead = true end
function RemoveUnit(u) u.dead = true; u.typeId = 0 end
function UnitAddAbility(u, a) u.abilities[a] = 1 return true end
function UnitRemoveAbility(u, a) u.abilities[a] = nil return true end
function GetUnitAbilityLevel(u, a) return u.abilities[a] or 0 end
function SetUnitAbilityLevel(u, a, l) u.abilities[a] = l return l end

function CreateGroup() local g = __handle("group"); g.units = {} return g end
function GroupEnumUnitsInRange(g, x, y, r, f)
    g.units = {}
    for _, u in ipairs(__mock.units) do
        if not u.dead and (u.x - x) ^ 2 + (u.y - y) ^ 2 <= r * r then g.units[#g.units + 1] = u end
    end
end
function BlzGroupGetSize(g) return #g.units end
function BlzGroupUnitAt(g, i) return g.units[i + 1] end
function GroupClear(g) g.units = {} end

math.randomseed(1)
function GetRandomInt(a, b) return math.random(a, b) end
function GetRandomReal(a, b) return a + (b - a) * math.random() end
function GetHeroLevel(u) return u.level or 1 end
function BlzGetUnitMaxHP(u) return u.maxLife or 100 end
function GetWidgetLife(u) return u.life or 0 end
function SetWidgetLife(u, v) u.life = v end
function GetPlayerController(p)
    if p.id <= 5 then return MAP_CONTROL_USER end
    return MAP_CONTROL_COMPUTER
end

function GetHeroSkillPoints(u) return 0 end
function OrderId(s) return 0 end
function GetUnitCurrentOrder(u) return 0 end
function GetHeroXP(u) return u.xp or 0 end
function BlzSetHeroProperName(u, n) u.name = n end
function BlzSetUnitName(u, n) u.name = n end
function BlzGetUnitAbilityByIndex(u, i) return nil end
