-- Timers. One shared 1/32 s loop drives per-frame work (projectiles, motion,
-- auras); one-shot and periodic timers wrap native timers with error capture.
define("timer", function()
    local Safe = use("safe")
    local Timer = {}

    Timer.TICK = 1 / 32

    local clock = CreateTimer()
    TimerStart(clock, 1000000, false, nil)

    function Timer.now()
        return TimerGetElapsed(clock)
    end

    function Timer.after(seconds, fn)
        local t = CreateTimer()
        TimerStart(t, math.max(0, seconds), false, function()
            PauseTimer(t)
            DestroyTimer(t)
            Safe.call(fn)
        end)
    end

    -- fn returns true to stop. Returns a handle with :stop().
    function Timer.every(seconds, fn)
        local t = CreateTimer()
        local handle = {}
        function handle:stop()
            if t then
                PauseTimer(t)
                DestroyTimer(t)
                t = nil
            end
        end
        TimerStart(t, seconds, true, function()
            local ok, stop = Safe.call(fn)
            if not ok or stop then
                handle:stop()
            end
        end)
        return handle
    end

    -- Per-frame callbacks: fn(dt) returns true to unregister.
    local frame = {}
    local loop = CreateTimer()
    TimerStart(loop, Timer.TICK, true, function()
        local i = 1
        while i <= #frame do
            local ok, stop = Safe.call(frame[i], Timer.TICK)
            if not ok or stop then
                frame[i] = frame[#frame]
                frame[#frame] = nil
            else
                i = i + 1
            end
        end
    end)

    function Timer.onFrame(fn)
        frame[#frame + 1] = fn
    end

    return Timer
end)
