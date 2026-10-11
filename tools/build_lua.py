"""Concatenate src/**/*.lua into one war3map.lua and syntax-check it with Lua 5.3.

Usage: build_lua.py <out war3map.lua> [--test] [--data-override <dir>]
--test sets the autopilot flag the in-game test harness reads.
"""
import json
import os
import sys

from lupa import lua53

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "src")
FIRST = ["core/module.lua"]
LAST = ["main.lua"]


def lua_literal(v, indent=0):
    pad = " " * indent
    if isinstance(v, dict):
        items = []
        for k in sorted(v):
            key = k if k.isidentifier() else "[" + json.dumps(k) + "]"
            items.append(f"{pad} {key} = {lua_literal(v[k], indent + 1)}")
        return "{\n" + ",\n".join(items) + "\n" + pad + "}"
    if isinstance(v, list):
        return "{" + ", ".join(lua_literal(x, indent + 1) for x in v) + "}"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    return json.dumps("" if v is None else str(v), ensure_ascii=False)


def data_chunks(override=None):
    """Each src/data/<name>.json becomes a module: use("data.<name>").
    Files in the override folder replace same-named ones (per-build ids)."""
    chunks = []
    data_dir = os.path.join(SRC, "data")
    names = {n: os.path.join(data_dir, n) for n in os.listdir(data_dir) if n.endswith(".json")}
    if override:
        names.update({n: os.path.join(override, n) for n in os.listdir(override) if n.endswith(".json")})
    for n in sorted(names):
        if n.endswith(".json"):
            with open(names[n], encoding="utf-8") as f:
                data = json.load(f)
            module = "data." + n[:-5]
            chunk = f"define({json.dumps(module)}, function()\n    return {lua_literal(data, 4)}\nend)\n"
            # Marked, so the launcher can swap a module in the personalized map: it
            # replaces data.mapdata with Dota's layout (docs/FRAMEWORK.md, "Data modules").
            chunks.append(f"-- @dvw-data-begin {module}\n{chunk}-- @dvw-data-end {module}\n")
    return "\n".join(chunks)


def collect(only_heroes=None, exclude=()):
    """only_heroes: optional set of hero keys; other src/heroes/*.lua are left out.
    exclude: source paths relative to src/ without .lua (e.g. "game/items")."""
    files = []
    for dirpath, _, names in os.walk(SRC):
        for n in names:
            if n.endswith(".lua"):
                rel = os.path.relpath(os.path.join(dirpath, n), SRC).replace(os.sep, "/")
                if only_heroes is not None and rel.startswith("heroes/") and n[:-4] not in only_heroes:
                    continue
                if rel[:-4] in exclude:
                    continue
                files.append(rel)
    middle = sorted(f for f in files if f not in FIRST and f not in LAST)
    return FIRST + middle + LAST


def build(out_path, test_mode, override=None, only_heroes=None, exclude=()):
    parts = []
    for rel in collect(only_heroes, exclude):
        with open(os.path.join(SRC, rel), encoding="utf-8") as f:
            parts.append(f"-- ==== {rel} ====\n" + f.read())
    parts.insert(1, data_chunks(override))
    parts.insert(1, f"BUILD_TEST_MODE = {'true' if test_mode else 'false'}\n")
    script = "\n".join(parts)

    lua = lua53.LuaRuntime()
    ok, err = lua.execute("return function(s) local f, e = load(s, '=war3map.lua') return f ~= nil, e end")(script)
    if not ok:
        sys.exit(f"Lua syntax error: {err}")

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    with open(out_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(script)
    print(f"war3map.lua: {len(script)} bytes, {len(collect(only_heroes, exclude))} files")


if __name__ == "__main__":
    build(sys.argv[1], "--test" in sys.argv,
          sys.argv[sys.argv.index("--data-override") + 1] if "--data-override" in sys.argv else None,
          set(sys.argv[sys.argv.index("--heroes") + 1].split(",")) if "--heroes" in sys.argv else None,
          tuple(sys.argv[sys.argv.index("--exclude") + 1].split(",")) if "--exclude" in sys.argv else ())
