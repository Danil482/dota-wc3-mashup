"""Full map build: layout data, terrain, object data, script, then the .w3x.

Usage: build.py [--test] [--dota-models] [--work <dir>] [--no-mock] [--heroes a,b,c] [--exclude game/items,...]
--test   builds the autotest variant (BUILD_TEST_MODE) with WC3 stand-in models,
         unless --dota-models asks for the launcher's paths (specs/models.json).
--work   puts every output (ids, objects, script, map files, .w3x) in <dir> and
         leaves shared files alone, so several builds can run side by side.
         Without it the main build writes build/test or build/release and
         refreshes src/data/ids.json.
The script is run offline against the mock WC3 API unless --no-mock.
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PY = os.path.join(ROOT, ".venv", "Scripts", "python.exe")
TOOLS = os.path.join(ROOT, "tools")


def run(*cmd):
    print(">", " ".join(os.path.basename(c) if i == 1 else c for i, c in enumerate(cmd)), flush=True)
    subprocess.run(cmd, cwd=ROOT, check=True)


def arg(name):
    return sys.argv[sys.argv.index(name) + 1] if name in sys.argv else None


def main():
    if not all(os.path.isfile(os.path.join(ROOT, "research", p)) for p in ("jass/common.j", "slk/unitmetadata.slk")):
        sys.exit("research/ is incomplete: run .venv\\Scripts\\python.exe -I tools\\fetch_research.py first")
    test = "--test" in sys.argv
    name = "DotaVsWarcraft_test.w3x" if test else "DotaVsWarcraft.w3x"
    work = arg("--work")
    out_dir = os.path.abspath(work) if work else os.path.join(ROOT, "build", "test" if test else "release")
    os.makedirs(out_dir, exist_ok=True)
    out = os.path.join(out_dir, name)
    lua = os.path.join(out_dir, "war3map.lua")
    data_dir = os.path.join(out_dir, "data") if work else None
    objects = os.path.join(out_dir if work else os.path.join(ROOT, "build"), "objects.json")

    run(PY, "-I", os.path.join(TOOLS, "gen_mapdata.py"))
    run(PY, "-I", os.path.join(TOOLS, "gen_terrain.py"))
    standins = test and "--dota-models" not in sys.argv
    run(PY, "-I", os.path.join(TOOLS, "gen_objects.py"), *(["--out-dir", data_dir] if work else []),
        *(["--standins"] if standins else []))
    if work:
        os.replace(os.path.join(data_dir, "objects.json"), objects)
    run(PY, "-I", os.path.join(TOOLS, "gen_mock.py"), os.path.join(out_dir, "mock_natives.lua"))
    run(PY, "-I", os.path.join(TOOLS, "build_lua.py"), lua, *(["--test"] if test else []),
        *(["--data-override", data_dir] if work else []),
        *(["--heroes", arg("--heroes")] if arg("--heroes") else []),
        *(["--exclude", arg("--exclude")] if arg("--exclude") else []))
    if "--no-mock" not in sys.argv:
        run(PY, "-I", os.path.join(TOOLS, "mock_run.py"), lua, "40")
    folder = out[:-4] + "_files"
    run("node", os.path.join(TOOLS, "build_map.js"), folder, lua, objects)
    run(PY, "-I", os.path.join(TOOLS, "gen_minimap.py"), folder)
    run(PY, "-I", os.path.join(TOOLS, "mpq_pack.py"), out, folder)


if __name__ == "__main__":
    main()
