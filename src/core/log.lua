-- Logging to Documents\Warcraft III\CustomMapData\<FILE> through the Preload
-- natives, the only file output a map has. The whole buffer is rewritten on
-- every flush, so it keeps the last MAX_LINES lines.
define("log", function()
    local Log = {}
    local FILE = "DotaVsWarcraft\\log.txt"
    local MAX_LINES = 600
    local CHUNK = 200

    local buffer, dirty = {}, false
    Log.debug = false
    Log.clock = function() return 0 end
    -- Neither print() nor Preload may run while the map is loading: either
    -- makes the game refuse the map. Game.start sets ready once it runs from
    -- a timer after loading; until then lines are only buffered.
    Log.ready = false

    local function push(level, msg)
        local line = string.format("[%7.2f] %s %s", Log.clock(), level, tostring(msg))
        buffer[#buffer + 1] = line
        if #buffer > MAX_LINES then
            table.remove(buffer, 1)
        end
        dirty = true
        if Log.ready and (Log.debug or level == "ERROR") then
            DisplayTimedTextToPlayer(GetLocalPlayer(), 0, 0, 20, line)
        end
    end

    function Log.info(msg) push("INFO ", msg) end
    function Log.warn(msg) push("WARN ", msg) end
    function Log.error(msg) push("ERROR", msg) end

    -- Structured test assertions read back by tools/run_test.ps1
    function Log.check(name, ok, detail)
        push(ok and "PASS " or "FAIL ", name .. (detail and (" - " .. tostring(detail)) or ""))
    end

    function Log.flush()
        if not dirty or not Log.ready then
            return
        end
        dirty = false
        PreloadGenClear()
        PreloadGenStart()
        for i = 1, #buffer do
            local s = string.gsub(buffer[i], '"', "'")
            local pos = 1
            repeat
                Preload(string.sub(s, pos, pos + CHUNK - 1))
                pos = pos + CHUNK
            until pos > #s
        end
        PreloadGenEnd(FILE)
    end

    return Log
end)

define("safe", function()
    local Log = use("log")
    local Safe = {}

    local function handler(err)
        if debug and debug.traceback then
            return debug.traceback(tostring(err), 2)
        end
        return tostring(err)
    end

    -- Runs fn(...) and logs any error instead of silently killing the thread.
    -- Returns ok followed by fn's first result.
    function Safe.call(fn, ...)
        local ok, res = xpcall(fn, handler, ...)
        if not ok then
            Log.error(res)
            Log.flush()
        end
        return ok, res
    end

    function Safe.wrap(fn)
        return function(...)
            local _, res = Safe.call(fn, ...)
            return res
        end
    end

    return Safe
end)
