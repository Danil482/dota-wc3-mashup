"""Run war3map.lua offline against the mock WC3 API and report errors.

Usage: mock_run.py <war3map.lua> [seconds]
Calls config() and main(), advances simulated time, then prints the in-game
log (from Preload output) and fails on any Lua error or FAIL check.
"""
import json
import os
import sys

from lupa import lua53

TOOLS = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(TOOLS)


def main(script_path, seconds):
    lua = lua53.LuaRuntime(unpack_returned_tuples=True)
    natives = os.path.join(os.path.dirname(os.path.abspath(script_path)), "mock_natives.lua")
    if not os.path.exists(natives):
        natives = os.path.join(ROOT, "build", "mock_natives.lua")
    with open(script_path, encoding="utf-8") as f:
        script_text = f.read()
    with open(os.path.join(ROOT, "src", "data", "heroes.json"), encoding="utf-8") as f:
        hero_keys = set(json.load(f))
    # per-hero exercises only run when that hero's module is in this build
    extensions = sorted(os.path.join(TOOLS, "mock", n) for n in os.listdir(os.path.join(TOOLS, "mock"))
                        if n.endswith(".lua") and (f'define("hero_{n[:-4]}"' in script_text
                                                   or (n[:-4] not in hero_keys and f'define("{n[:-4]}"' in script_text)))
    for path in (natives, os.path.join(TOOLS, "mock_runtime.lua"), *extensions, script_path):
        with open(path, encoding="utf-8") as f:
            lua.execute(f.read())
    run = lua.eval("""function(seconds)
        local ok, err = pcall(function()
            config()
            main()
            __mock.advance(seconds)
        end)
        local log = __mock.files["DotaVsCommander\\\\log.txt"] or ""
        return ok, tostring(err), log, table.concat(__mock.printed, "\\n")
    end""")
    ok, err, log, printed = run(seconds)
    print(log)
    failed = (not ok) or ("ERROR" in log)   # FAIL checks need the real game
    if not ok:
        print("LUA ERROR:", err)
    print("MOCK RESULT:", "FAILED" if failed else "OK")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else 10))
