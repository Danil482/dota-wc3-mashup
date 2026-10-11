"""Run the launcher's model pipeline against a local Dota 2 install and write
the map files into a folder, for checks and renders (tools/check_mdx.js,
tools/render_models.js). Uses the launcher code unchanged; the cache goes to
<out>/cache so the player's cache is untouched.

Usage: python tools/convert_models.py --dota "<Dota 2 root>" --out build/models [--keys a,b] [--cold]
Prints timings and writes <out>/files/war3mapImported/Dota/*, <out>/report.json.
"""
import argparse
import json
import shutil
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "launcher"))

from dvw_launcher import installs, models  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dota", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--keys", help="comma-separated unit keys (default: specs/models.json, else all)")
    ap.add_argument("--vrf", default=str(ROOT / "launcher" / "vendor" / "vrf" / "Source2Viewer-CLI.exe"))
    ap.add_argument("--cold", action="store_true", help="delete the cache first")
    args = ap.parse_args()
    out = Path(args.out).resolve()
    dota = installs.dota_root(args.dota)
    vpk = installs.dota_vpk(dota)
    if args.keys:
        keys = args.keys.split(",")
    else:
        keys = models.load_keys(ROOT / "specs" / "models.json") or list(models.units.UNITS)
    cache = out / "cache"
    if args.cold:
        shutil.rmtree(cache, ignore_errors=True)
    cache.mkdir(parents=True, exist_ok=True)
    lines = []

    def log(msg):
        lines.append(msg)
        print(msg, flush=True)

    t = time.perf_counter()
    files = models.prepare(vpk, Path(args.vrf), cache, keys, log)
    elapsed = time.perf_counter() - t
    target = out / "files"
    shutil.rmtree(target, ignore_errors=True)
    for name, data in files.items():
        p = target / name.replace("\\", "/")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    folder = next(cache.glob(models.CACHE_PREFIX + "*"))
    manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    report = {"seconds": round(elapsed, 1), "files": len(files), "bytes": sum(len(d) for d in files.values()),
              "units": manifest["units"], "log": lines}
    (out / "report.json").write_text(json.dumps(report, indent=1), encoding="utf-8")
    print(f"{len(files)} files, {report['bytes'] / 1048576:.1f} MB, {elapsed:.1f} s")


if __name__ == "__main__":
    main()
