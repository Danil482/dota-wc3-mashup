"""Fill the git-ignored inputs of tools/build.py, so a fresh clone can build the map.

Usage: fetch_research.py [--wc3 <root>] [--dota [<dota 2 beta>]] [--force]

  research/jass/         common.j, blizzard.j, common.ai: jassdoc's annotated copies
                         (lep/jassdoc at a pinned commit) for the offline mock
  research/slk/          SLK tables and *func.txt from the local Warcraft III
                         Reforged CASC storage (war3.w3mod:units/, tools/casc.py)
  tools/vendor/stormlib/ StormLib.dll, x64, from the StormLib 9.40 release zip
                         that launcher/build.ps1 pins
  tools/node_modules/    npm ci from tools/package-lock.json, without
                         puppeteer's browser (the build does not use it)
  --dota                 also research/dota_data/ (extract_dota_data.py, from the
                         player's pak01_dir.vpk) and research/heroes.json
                         (summarize_heroes.py), for the data-refresh tools

The installs are found through the registry and Steam's library folders when the
flags are missing. Downloads are pinned and SHA-256 checked. Whatever exists is
kept unless --force. Every output path is git-ignored.
"""
import argparse
import hashlib
import http.client
import importlib.metadata
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.request
import winreg
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(ROOT, "tools")
RESEARCH = os.path.join(ROOT, "research")
sys.path.insert(0, TOOLS)
sys.path.insert(0, os.path.join(ROOT, "launcher"))

import casc  # noqa: E402
from dvw_launcher import installs  # noqa: E402

JASSDOC_COMMIT = "8610958b3b77b8213f9db45ab664458650a07294"
JASSDOC = f"https://raw.githubusercontent.com/lep/jassdoc/{JASSDOC_COMMIT}/"
JASS_FILES = {  # file in research/jass: (file in jassdoc, SHA-256)
    "common.j": ("common.j", "8389b79cd6001e0b681c0ceae346ad6fd5e8d5c0b15a26837abd033490370bfd"),
    "blizzard.j": ("Blizzard.j", "65e986a4847dc9d122da4455cd3fc2b5c92dd334f4617e3babff3db658f74848"),
    "common.ai": ("common.ai", "e4a330dd81686f420b8941d638516ab7cc9f291256004c1fc7ad8181ace58694"),
}
STORMLIB_URL = "https://github.com/ladislav-zezula/StormLib/releases/download/v9.40/stormlib_dll.zip"
STORMLIB_SHA256 = "b2c9635e7b63edee1bd7c82e7dc180d739f3accb2b8994804c7774e464ce89ae"
STORMLIB_DLL = os.path.join(TOOLS, "vendor", "stormlib", "StormLib.dll")
SLK_FILES = (
    "abilitybuffdata.slk", "abilitybuffmetadata.slk", "abilitydata.slk", "abilitymetadata.slk",
    "destructabledata.slk", "itemdata.slk", "miscmetadata.slk", "unitabilities.slk", "unitbalance.slk",
    "unitdata.slk", "unitmetadata.slk", "unitui.slk", "unitweapons.slk", "upgrademetadata.slk",
    "commonabilityfunc.txt", "humanabilityfunc.txt", "itemabilityfunc.txt", "neutralabilityfunc.txt",
    "nightelfabilityfunc.txt", "orcabilityfunc.txt", "undeadabilityfunc.txt", "itemfunc.txt",
    "humanunitfunc.txt", "neutralunitfunc.txt", "nightelfunitfunc.txt", "orcunitfunc.txt", "undeadunitfunc.txt",
)
UNINSTALL_KEYS = (
    (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
    (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"),
    (winreg.HKEY_CURRENT_USER, r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"),
)


class FetchError(Exception):
    pass


def write(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path + ".part", "wb") as f:
        f.write(data)
    os.replace(path + ".part", path)


def download(url, sha256):
    for attempt in (1, 2, 3):
        try:
            with urllib.request.urlopen(url, timeout=60) as response:
                data = response.read()
            got = hashlib.sha256(data).hexdigest()
            if got == sha256:
                return data
            error = f"SHA-256 is {got}, expected {sha256}"
        except (OSError, http.client.HTTPException) as e:
            error = str(e)
        if attempt < 3:
            time.sleep(5 * attempt)
    raise FetchError(f"download failed after 3 tries: {url}\n{error}")


def registry_value(hive, path, name):
    try:
        with winreg.OpenKey(hive, path) as key:
            return winreg.QueryValueEx(key, name)[0]
    except OSError:
        return None


def installed_locations(match):
    """InstallLocation of the programs whose (uninstall key, DisplayName) match."""
    found = []
    for hive, path in UNINSTALL_KEYS:
        try:
            programs = winreg.OpenKey(hive, path)
        except OSError:
            continue
        with programs:
            for i in range(winreg.QueryInfoKey(programs)[0]):
                key = winreg.EnumKey(programs, i)
                name = registry_value(programs, key, "DisplayName") or ""
                location = registry_value(programs, key, "InstallLocation")
                if location and match(key, name):
                    found.append(location)
    return found


def steam_libraries():
    steam = registry_value(winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam", "SteamPath") \
        or os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"), "Steam")
    libraries = [steam]
    try:
        with open(os.path.join(steam, "steamapps", "libraryfolders.vdf"), encoding="utf-8") as f:
            libraries += [p.replace("\\\\", "\\") for p in re.findall(r'"path"\s+"([^"]+)"', f.read())]
    except OSError:
        pass
    return libraries


def wc3_candidates():
    return installed_locations(lambda key, name: name.startswith("Warcraft III")) + [
        os.path.join(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)"), "Warcraft III"),
        os.path.join(os.environ.get("ProgramFiles", r"C:\Program Files"), "Warcraft III")]


def dota_candidates():
    return installed_locations(lambda key, name: key == "Steam App 570") + [
        os.path.join(library, "steamapps", "common", "dota 2 beta") for library in steam_libraries()]


def dota_install(path):
    root = installs.dota_root(path)
    installs.dota_vpk(root)
    return root


def find_install(given, validate, candidates, missing):
    """The given folder if it is valid, else the first valid candidate."""
    for candidate in [given] if given else candidates():
        try:
            return validate(candidate)
        except installs.InstallError as e:
            if given:
                raise FetchError(str(e)) from None
    raise FetchError(missing)


def python_packages(args):
    pins = []
    with open(os.path.join(TOOLS, "requirements.txt"), encoding="utf-8") as f:
        for line in f:
            spec = line.split("#")[0].strip()
            if spec:
                pins.append(spec.split("=="))
    wrong = []
    for name, version in pins:
        try:
            have = importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            have = "missing"
        if have != version:
            wrong.append(f"{name} {have} (pinned {version})")
    if wrong:
        raise FetchError(f"{', '.join(wrong)}: run {sys.executable} -m pip install -r tools\\requirements.txt")
    return ", ".join(f"{name} {version}" for name, version in pins)


def jass(args):
    out_dir = os.path.join(RESEARCH, "jass")
    wanted = [n for n in JASS_FILES if args.force or not os.path.isfile(os.path.join(out_dir, n))]
    if not wanted:
        return f"kept {len(JASS_FILES)}"
    for name in wanted:
        source, sha256 = JASS_FILES[name]
        write(os.path.join(out_dir, name), download(JASSDOC + source, sha256))
    kept = len(JASS_FILES) - len(wanted)
    return f"{len(wanted)} from jassdoc {JASSDOC_COMMIT[:8]}, SHA-256 OK" + (f", kept {kept}" if kept else "")


def slk(args):
    out_dir = os.path.join(RESEARCH, "slk")
    wanted = [n for n in SLK_FILES if args.force or not os.path.isfile(os.path.join(out_dir, n))]
    if not wanted:
        return f"kept {len(SLK_FILES)}"
    root = find_install(args.wc3, installs.wc3_root, wc3_candidates,
                        "Warcraft III Reforged not found: pass --wc3 <folder> (the one holding _retail_ and Data)")
    try:
        storage = casc.Storage(str(root))
        for name in wanted:
            write(os.path.join(out_dir, name), storage.read("war3.w3mod:units/" + name))
    except (OSError, casc.CascError) as e:
        raise FetchError(f"cannot read the CASC storage of {root}: {e}") from None
    kept = len(SLK_FILES) - len(wanted)
    return f"{len(wanted)} from Warcraft III {storage.version} ({root})" + (f", kept {kept}" if kept else "")


def stormlib(args):
    if not args.force and os.path.isfile(STORMLIB_DLL):
        return "kept"
    with zipfile.ZipFile(io.BytesIO(download(STORMLIB_URL, STORMLIB_SHA256))) as z:
        write(STORMLIB_DLL, z.read("x64/StormLib.dll"))
    return "StormLib 9.40 x64 from stormlib_dll.zip, SHA-256 OK"


def node_modules(args):
    if not args.force and os.path.isdir(os.path.join(TOOLS, "node_modules", "mdx-m3-viewer")):
        return "kept"
    npm = shutil.which("npm")
    if not npm:
        raise FetchError("npm not found: install Node.js 22.12 or newer")
    result = subprocess.run([npm, "ci", "--no-audit", "--no-fund"], cwd=TOOLS, capture_output=True, text=True,
                            env=dict(os.environ, PUPPETEER_SKIP_DOWNLOAD="true"))
    if result.returncode:
        raise FetchError("npm ci failed:\n" + (result.stderr or result.stdout).strip()[-1500:])
    return "npm ci from package-lock.json (integrity checked), puppeteer's browser skipped"


def dota(args):
    data_dir = os.path.join(RESEARCH, "dota_data")
    heroes = os.path.join(RESEARCH, "heroes.json")
    if not args.force and os.path.isdir(data_dir) and os.path.isfile(heroes):
        return "kept"
    root = find_install(args.dota, dota_install, dota_candidates,
                        "Dota 2 not found: pass --dota <folder> (the 'dota 2 beta' folder)")
    for tool, *tool_args in (("extract_dota_data.py", str(root), data_dir), ("summarize_heroes.py", data_dir, heroes)):
        result = subprocess.run([sys.executable, "-I", os.path.join(TOOLS, tool), *tool_args],
                                cwd=ROOT, capture_output=True, text=True)
        missing = [line for line in result.stdout.splitlines() if line.startswith("MISSING")]
        if result.returncode or missing:
            raise FetchError(f"{tool} failed:\n" + "\n".join(missing or [result.stderr.strip()[-1500:]]))
    with open(heroes, encoding="utf-8") as f:
        count = len(json.load(f))
    return f"dota_data and heroes.json ({count} heroes) from {root}"


def main():
    p = argparse.ArgumentParser(description="Fill research/, tools/vendor/ and tools/node_modules/ for tools/build.py.")
    p.add_argument("--wc3", help="Warcraft III Reforged folder (found automatically if omitted)")
    p.add_argument("--dota", nargs="?", const="", metavar="DIR",
                   help="also extract Dota 2 data for the data-refresh tools (folder found automatically if omitted)")
    p.add_argument("--force", action="store_true", help="fetch everything again, even what exists")
    args = p.parse_args()

    steps = [("python packages", python_packages), ("research/jass", jass), ("research/slk", slk),
             ("StormLib.dll", stormlib), ("tools/node_modules", node_modules)]
    if args.dota is not None:
        steps.append(("research/dota_data", dota))
    failed = 0
    for name, step in steps:
        t = time.perf_counter()
        try:
            result = step(args)
        except FetchError as e:
            failed += 1
            result = f"FAILED: {e}"
        print(f"{name:19} {time.perf_counter() - t:5.1f} s  {result}", flush=True)
    if failed:
        sys.exit(f"fetch_research: {failed} step(s) failed")
    print("fetch_research: OK. Build with .venv\\Scripts\\python.exe -I tools\\build.py --test --work build\\work_dev")


if __name__ == "__main__":
    main()
