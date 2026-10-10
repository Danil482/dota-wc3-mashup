"""DotaVsCommander.exe: build the personalized map from the player's Dota 2
install, then start Warcraft III.

DotaVsCommander.exe --game <WC3 folder> --dota <Dota 2 folder>
                    [--map <base .w3x>] [--out <map path>] [--prepare-only]
"""
import argparse
import hashlib
import json
import logging
import os
import shutil
import subprocess
import sys
import time
import traceback
from logging.handlers import RotatingFileHandler
from pathlib import Path

from . import (PLAN_VERSION, __version__, assets, dota_settings, installs, models, stormlib, terrain, vpkdir, vrf,
               winapi)

APP = "DotaVsCommander"
TITLE = "Dota vs Commander"
MAP_NAME = "DotaVsCommander.w3x"

EXIT_OK = 0
EXIT_INTERNAL = 1
EXIT_USAGE = 2
EXIT_DOTA_MISSING = 3
EXIT_VPK_MISSING = 4
EXIT_EXTRACT_FAILED = 5
EXIT_MAP_MISSING = 6
EXIT_WRITE_FAILED = 7
EXIT_WC3_FAILED = 8

log = logging.getLogger("dvc")


class LauncherError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class UsageError(Exception):
    pass


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise UsageError(message)


def parse_args(argv):
    p = _Parser(prog="DotaVsCommander.exe", add_help=False,
                description="Builds the Dota vs Commander map from your own Dota 2 install and starts "
                            "Warcraft III.")
    p.add_argument("--game", help="Warcraft III folder (contains _retail_\\x86_64\\Warcraft III.exe)")
    p.add_argument("--dota", help="Dota 2 folder (contains game\\dota\\pak01_dir.vpk)")
    p.add_argument("--map", help=f"base map (default: {MAP_NAME} next to the exe)")
    p.add_argument("--out", help="personalized map to write (default: Documents\\Warcraft III\\Maps\\"
                                 f"DotaVsCommander\\{MAP_NAME})")
    p.add_argument("--prepare-only", action="store_true", help="build the map but do not start the game")
    p.add_argument("--no-wait", action="store_true", help="exit right after starting the game")
    p.add_argument("--quiet", action="store_true", help="no message boxes (errors go to the log only)")
    p.add_argument("--vrf", help=argparse.SUPPRESS)
    p.add_argument("--stormlib", help=argparse.SUPPRESS)
    p.add_argument("-h", "--help", action="store_true")
    p.add_argument("--version", action="store_true")
    args = p.parse_args(argv)
    for key in ("game", "dota", "map", "out", "vrf", "stormlib"):
        value = getattr(args, key)
        if value:
            # A caller quoting "C:\folder\" leaves a stray quote at the end.
            setattr(args, key, value.strip().strip('"').strip())
    if args.help or args.version:
        return args, p.format_help()
    if not args.dota:
        raise UsageError("--dota is required")
    if not args.game and not args.prepare_only:
        raise UsageError("--game is required unless --prepare-only is given")
    return args, None


# ------------------------------------------------------------------ paths

def app_dir():
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parents[1]


def data_file(name):
    """Bundled data: next to the code when frozen, the repo files otherwise."""
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "data" / name
    repo = Path(__file__).resolve().parents[2]
    return {"heroes.json": repo / "src" / "data" / "heroes.json",
            "items.json": repo / "src" / "data" / "items.json",
            "vo_manifest.json": repo / "launcher" / "vo_manifest.json",
            "hud_assets.json": repo / "specs" / "hud_assets.json",
            "models.json": repo / "specs" / "models.json"}[name]


def default_vrf():
    if getattr(sys, "frozen", False):
        return app_dir() / "vrf" / "Source2Viewer-CLI.exe"
    return app_dir() / "vendor" / "vrf" / "Source2Viewer-CLI.exe"


def default_stormlib():
    if getattr(sys, "frozen", False):
        return app_dir() / "StormLib.dll"
    return app_dir() / "vendor" / "stormlib" / "x64" / "StormLib.dll"


def user_dir():
    return winapi.local_app_data_dir() / APP


def default_out():
    return winapi.documents_dir() / "Warcraft III" / "Maps" / "DotaVsCommander" / MAP_NAME


def setup_logging():
    log.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s %(levelname)-7s %(message)s")
    path = None
    for folder in (lambda: user_dir() / "logs", lambda: Path(os.environ.get("TEMP", ".")) / APP):
        try:
            d = folder()
            d.mkdir(parents=True, exist_ok=True)
            path = d / "launcher.log"
            handler = RotatingFileHandler(path, maxBytes=1_000_000, backupCount=1, encoding="utf-8")
            handler.setFormatter(fmt)
            log.addHandler(handler)
            break
        except OSError:
            path = None
    if sys.stderr is not None:
        stream = logging.StreamHandler(sys.stderr)
        stream.setFormatter(fmt)
        log.addHandler(stream)
    return path


# ------------------------------------------------------------------ cache

def _atomic_write(path, data):
    tmp = path.with_name(f"{path.name}.tmp{os.getpid()}")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def load_plan(build_dir, digest):
    try:
        plan = json.loads((build_dir / "plan.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if plan.get("plan_version") != PLAN_VERSION or plan.get("inputs") != digest:
        return None
    return plan


def cache_complete(plan, raw):
    failed = set(plan.get("failed", []))
    for source in plan["extract"]:
        if source in failed:
            continue
        p = raw / vrf.output_path(source)
        try:
            if p.stat().st_size == 0:
                return False
        except OSError:
            return False
    return True


def extract_missing(plan, vpk, raw, build_dir, vrf_exe):
    todo = []
    for source in plan["extract"]:
        p = raw / vrf.output_path(source)
        if not (p.is_file() and p.stat().st_size > 0):
            todo.append(source)
    if not todo:
        return
    staging = build_dir / f"staging-{os.getpid()}"
    work = build_dir / f"work-{os.getpid()}"
    shutil.rmtree(staging, ignore_errors=True)
    try:
        t = time.perf_counter()
        vrf.extract(vrf_exe, vpk, todo, staging, work, log.info, threads=min(4, os.cpu_count() or 1))
        log.info(f"VRF exported {len(todo)} files in {time.perf_counter() - t:.1f} s")
        for source in todo:
            rel = vrf.output_path(source)
            src = staging / rel
            if src.is_file() and src.stat().st_size > 0:
                dst = raw / rel
                dst.parent.mkdir(parents=True, exist_ok=True)
                os.replace(src, dst)
    finally:
        shutil.rmtree(staging, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)


def prune_old_builds(cache_root, keep):
    """Keep the current build and the newest other one."""
    try:
        others = [d for d in cache_root.iterdir() if d.is_dir() and d.name != keep]
        others.sort(key=lambda d: d.stat().st_mtime, reverse=True)
        for d in others[1:]:
            shutil.rmtree(d, ignore_errors=True)
            log.info(f"removed old cache {d.name}")
    except OSError:
        pass


def prepare_assets(dota, vpk, vrf_exe):
    """Plan, extract (cached per Dota build) and convert. Returns {map path: bytes}."""
    build, build_source = installs.dota_build_id(dota)
    if build:
        log.info(f"Dota 2 build {build} (from {build_source})")
    else:
        st = vpk.stat()
        build = "vpk-" + hashlib.sha256(f"{st.st_size}:{st.st_mtime_ns}".encode()).hexdigest()[:16]
        log.warning(f"Dota 2 build id not found; cache key {build}")
    roster = assets.roster_from_heroes(assets.load_json(data_file("heroes.json")))
    manifest = assets.load_json(data_file("vo_manifest.json"))
    item_icons = assets.load_json(data_file("items.json")).get("icons", [])
    try:
        hud = assets.load_hud_specs(data_file("hud_assets.json"))
    except ValueError as e:
        raise LauncherError(EXIT_INTERNAL, f"{e}\n\nReinstall the mod.") from e
    digest = assets.inputs_digest(roster, manifest, item_icons, hud)

    cache_root = user_dir() / "cache"
    build_dir = cache_root / build
    raw = build_dir / "raw"
    plan = load_plan(build_dir, digest)
    if plan and cache_complete(plan, raw):
        log.info(f"cache complete: {build_dir}")
    else:
        t = time.perf_counter()
        try:
            listing = vpkdir.read_tree(vpk, assets.vpk_prefixes(manifest, item_icons, hud))
        except (OSError, vpkdir.VpkError) as e:
            raise LauncherError(EXIT_VPK_MISSING, f"Dota 2 game data could not be read:\n{e}") from e
        plan = assets.make_plan(listing, roster, manifest, build, item_icons, hud)
        plan["inputs"] = digest
        plan["launcher"] = __version__
        log.info(f"VPK listing {len(listing)} entries, plan {len(plan['extract'])} files "
                 f"in {time.perf_counter() - t:.1f} s")
        build_dir.mkdir(parents=True, exist_ok=True)
        try:
            extract_missing(plan, vpk, raw, build_dir, vrf_exe)
        except vrf.VrfError as e:
            raise LauncherError(EXIT_EXTRACT_FAILED, f"Could not export assets from Dota 2:\n{e}") from e
        plan["failed"] = [s for s in plan["extract"] if not (raw / vrf.output_path(s)).is_file()]
        if plan["extract"] and len(plan["failed"]) == len(plan["extract"]):
            raise LauncherError(EXIT_EXTRACT_FAILED, "The asset exporter (VRF) produced no files.")
        for s in plan["failed"]:
            log.warning(f"not exported: {s}")
        _atomic_write(build_dir / "plan.json", json.dumps(plan, indent=1).encode("utf-8"))
        prune_old_builds(cache_root, build)

    for icon in plan["icons"]:
        if icon["note"] != "exact":
            log.info(f"icon {icon['key']}: {icon['note']}")
    for sound in plan["sounds"]:
        if sound["note"] != "manifest":
            log.warning(f"voice line {sound['target']}: {sound['note']}")
    t = time.perf_counter()
    files, report = assets.build_files(plan, raw, log.warning)
    log.info(f"converted {len(files)} files in {time.perf_counter() - t:.1f} s")
    for key, values in report.items():
        if values:
            log.warning(f"{key}: {', '.join(values)}")

    # Unit models: the map's object data points at war3mapImported\Dota\<key>.mdx
    # for every key in models.json, so each one must be produced or the run stops.
    t = time.perf_counter()
    try:
        keys = models.load_keys(data_file("models.json"))
        model_files = models.prepare(vpk, vrf_exe, build_dir, keys, log.info)
    except models.ModelError as e:
        raise LauncherError(EXIT_EXTRACT_FAILED, f"Could not convert the Dota 2 unit models:\n{e}\n\n"
                                                 "No map was written. If Dota 2 just updated, verify its "
                                                 "files in Steam and try again.") from e
    clash = sorted(set(files) & set(model_files))
    if clash:
        raise LauncherError(EXIT_INTERNAL, f"Asset name clash: {clash[:3]}")
    files.update(model_files)
    log.info(f"models: {len(keys)} units, {len(model_files)} files in {time.perf_counter() - t:.1f} s")
    return files


def prepare_terrain(dota, base_map, vrf_exe, stormlib_dll):
    """Dota's own map layout (terrain package): map files that replace the base
    map's terrain, trees, start locations and data.mapdata. On any failure the
    base map's own layout stays, with a warning: it is complete by itself."""
    t = time.perf_counter()
    try:
        out = terrain.prepare(dota, base_map, vrf_exe, stormlib_dll, user_dir() / "cache", log.info)
    except (terrain.TerrainError, OSError) as e:
        log.warning(f"terrain: keeping the base map's layout: {e}")
        return {}
    except Exception:  # noqa: BLE001 - the base layout is a complete map; never fail the run here
        log.warning(f"terrain: keeping the base map's layout after an error:\n{traceback.format_exc()}")
        return {}
    log.info(f"terrain: Dota's layout, {len(out)} map files in {time.perf_counter() - t:.1f} s")
    return out


def export_settings(dota, vpk):
    """The player's own Dota keys and settings, next to the map's log in
    CustomMapData and never inside the map: every player in a lobby needs the
    same map file. Without them the map uses Dota's defaults."""
    try:
        summary = dota_settings.export(dota, vpk, winapi.documents_dir() / "Warcraft III" / "CustomMapData" / APP)
    except Exception as e:  # noqa: BLE001 - optional; the message may hold the Steam account folder
        log.warning(f"Dota settings not exported: {getattr(e, 'strerror', None) or type(e).__name__}")
        return
    log.info(f"Dota settings: {summary}" if summary else "Dota settings not found; the map uses Dota's defaults")


def write_map(base_path, out_path, files, stormlib_dll, work_dir):
    t = time.perf_counter()
    try:
        storm = stormlib.StormLib(stormlib_dll)
    except stormlib.StormError as e:
        raise LauncherError(EXIT_INTERNAL, f"{e}\n\nReinstall the mod.") from e
    try:
        storm.SFileCloseArchive(storm.open_archive(base_path))
    except stormlib.StormError as e:
        raise LauncherError(EXIT_MAP_MISSING, f"The base map is damaged or not a Warcraft III map:\n"
                                              f"{base_path}\n{e}") from e
    try:
        data, copied = stormlib.build_archive(stormlib_dll, base_path, files, work_dir, log.info)
    except (stormlib.StormError, OSError) as e:
        raise LauncherError(EXIT_WRITE_FAILED, f"Could not build the map:\n{e}") from e
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)
    log.info(f"map built: {len(data)} bytes, {copied} base files + {len(files)} assets, "
             f"{time.perf_counter() - t:.1f} s, sha256 {hashlib.sha256(data).hexdigest()}")
    try:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        if out_path.is_file() and out_path.stat().st_size == len(data) and out_path.read_bytes() == data:
            log.info(f"map unchanged: {out_path}")
            return
        _atomic_write(out_path, data)
    except PermissionError as e:
        raise LauncherError(EXIT_WRITE_FAILED, f"The map file is in use or not writable:\n{out_path}\n"
                                               "Close Warcraft III and try again.") from e
    except OSError as e:
        raise LauncherError(EXIT_WRITE_FAILED, f"Could not write the map:\n{out_path}\n{e}") from e
    log.info(f"map written: {out_path}")


def launch(game, out_path, wait):
    exe = game / installs.WC3_EXE
    # Exact form: "<game>\_retail_\x86_64\Warcraft III.exe" -launch -windowmode windowed -loadfile "<map>"
    cmdline = f'"{exe}" -launch -windowmode windowed -loadfile "{out_path}"'
    log.info(f"starting: {cmdline} (cwd {game})")
    try:
        proc = subprocess.Popen(cmdline, cwd=str(game), close_fds=True)
    except OSError as e:
        raise LauncherError(EXIT_WC3_FAILED, f"Warcraft III could not be started:\n{exe}\n{e}") from e
    if wait:
        code = proc.wait()
        log.info(f"Warcraft III exited with code {code}")


def run(args):
    t0 = time.perf_counter()
    try:
        dota = installs.dota_root(args.dota)
        vpk = installs.dota_vpk(dota)
    except installs.InstallError as e:
        code = EXIT_VPK_MISSING if e.code == "vpk_missing" else EXIT_DOTA_MISSING
        raise LauncherError(code, f"{e}\n\nInstall Dota 2 from Steam (free); the map takes hero icons "
                                  "and voices from your own Dota 2 install.") from e
    game = None
    if args.game:
        try:
            game = installs.wc3_root(args.game)
        except installs.InstallError as e:
            if not args.prepare_only:
                raise LauncherError(EXIT_WC3_FAILED, str(e)) from e
            log.warning(str(e))
    base_map = Path(args.map) if args.map else app_dir() / MAP_NAME
    if not base_map.is_file():
        raise LauncherError(EXIT_MAP_MISSING, f"The base map was not found:\n{base_map}\n\n"
                                              "Reinstall the mod.")
    out_path = Path(args.out) if args.out else default_out()
    out_path = Path(os.path.abspath(out_path))
    for folder in (dota, game):
        if folder and installs.is_inside(out_path, folder):
            raise LauncherError(EXIT_WRITE_FAILED, f"--out must not point into a game folder:\n{out_path}")
    vrf_exe = Path(args.vrf) if args.vrf else default_vrf()
    stormlib_dll = Path(args.stormlib) if args.stormlib else default_stormlib()
    log.info(f"dota={dota} game={game} map={base_map} out={out_path} vrf={vrf_exe} stormlib={stormlib_dll}")

    files = prepare_assets(dota, vpk, vrf_exe)
    files.update(prepare_terrain(dota, base_map, vrf_exe, stormlib_dll))
    write_map(base_map, out_path, files, stormlib_dll, user_dir() / "work" / f"map-{os.getpid()}")
    export_settings(dota, vpk)
    log.info(f"prepared in {time.perf_counter() - t0:.1f} s")
    if args.prepare_only:
        return EXIT_OK
    launch(game, out_path, wait=not args.no_wait)
    return EXIT_OK


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    log_path = setup_logging()
    log.info(f"=== {TITLE} launcher {__version__} === args: {argv}")
    quiet = "--quiet" in argv

    def fail(code, message):
        log.error(message)
        if not quiet:
            winapi.message_box(f"{message}\n\nLog: {log_path}", TITLE)
        return code

    try:
        args, help_text = parse_args(argv)
        if help_text is not None:
            text = f"{TITLE} launcher {__version__}\n\n{help_text}"
            if sys.stdout is not None:
                print(text)
            elif not quiet:
                winapi.message_box(text, TITLE, error=False)
            return EXIT_OK
        return run(args)
    except UsageError as e:
        return fail(EXIT_USAGE, f"Wrong command line: {e}\n\nUsage: DotaVsCommander.exe --game <Warcraft III "
                                f"folder> --dota <Dota 2 folder> [--map <base map>] [--out <map path>] "
                                f"[--prepare-only]")
    except LauncherError as e:
        return fail(e.code, str(e))
    except Exception:  # noqa: BLE001 - last resort: log and tell the player
        log.error(traceback.format_exc())
        return fail(EXIT_INTERNAL, "Unexpected error while preparing the map.")
    finally:
        logging.shutdown()
