"""End-to-end test of the packaged launcher (dist/DotaVsCommander/).

Runs DotaVsCommander.exe --prepare-only against a snapshot of the test map and
checks the output map. Never starts Warcraft III, Dota 2 or Steam.

Usage: python launcher/tests/test_dist.py --dota "<Dota 2 root>" --game "<WC3 root>"
                                          --work <scratch folder> [--base <map.w3x>]
Needs: mpyq (pip), node + tools/node_modules, ffprobe/ffmpeg on PATH.
"""
import argparse
import hashlib
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "launcher"))

import mpyq  # noqa: E402
from PIL import Image, ImageChops, ImageStat  # noqa: E402

from dvc_launcher import assets, blp, cli, models, stormlib, terrain, vrf  # noqa: E402

DIST = ROOT / "dist" / "DotaVsCommander"
EXE = DIST / "DotaVsCommander.exe"
DLL = DIST / "StormLib.dll"
CACHE = cli.user_dir() / "cache"
LOG = cli.user_dir() / "logs" / "launcher.log"
SAMPLE_ICONS = ["pudge_meat_hook", "nevermore_requiem", "hero_rubick", "item_tpscroll"]
OBJECT_FILES = ("war3map.w3u", "war3map.w3t", "war3map.w3a", "war3map.w3b", "war3map.w3d", "war3map.w3h",
                "war3map.w3q")
# Voice lines per event (tools/select_vo.py); cast_<ability> events get VO_CAST_CAP.
VO_CAPS = {"move": 8, "attack": 8, "kill": 4, "death": 4, "levelup": 4, "laugh": 4, "spawn": 4,
           "respawn": 2, "battlebegins": 1, "notyet": 2, "nomana": 2, "firstblood": 1, "aegis": 1,
           "rune_doubledamage": 1, "rune_haste": 1, "rune_illusion": 1, "rune_invisibility": 1,
           "rune_regeneration": 1, "rune_arcane": 1, "rune_bounty": 1}
VO_CAST_CAP = 3

results = {}
failures = []


def check(name, ok, detail=""):
    results[name] = {"ok": bool(ok), "detail": detail}
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(name)


def run_exe(args, timeout=900):
    t = time.perf_counter()
    proc = subprocess.run([str(EXE)] + args, timeout=timeout)
    return proc.returncode, time.perf_counter() - t


def sha(data):
    return hashlib.sha256(data).hexdigest()


def storm_read_all(storm, path):
    """{name: bytes} for every file StormLib lists (internal files included)."""
    h = storm.open_archive(path)
    try:
        return {n.decode(): storm.read_file(h, n, loc) for n, loc, _ in storm.list_files(h)}
    finally:
        storm.SFileCloseArchive(h)


def mpyq_check(path, expected):
    """Read every file with mpyq. Files mpyq gets wrong are checked for raw
    (incompressible) sectors before the last one: mpyq 0.2.5 decompresses every
    non-final sector, while Storm stores an incompressible sector raw."""
    # (listfile) is encrypted, as in Blizzard's own maps; mpyq cannot decrypt
    # it, so the names come from StormLib's listing.
    archive = mpyq.MPQArchive(str(path), listfile=False)
    sector = 512 << archive.header["sector_size_shift"]
    ok, explained, unexplained = 0, 0, []
    raw = Path(path).read_bytes()
    for name, data in expected.items():
        try:
            got = archive.read_file(name)
        except Exception:  # noqa: BLE001 - mpyq raises plain RuntimeError/struct.error
            got = None
        if got == data:
            ok += 1
            continue
        entry = archive.get_hash_table_entry(name)
        block = archive.block_table[entry.block_table_index]
        count = (block.size + sector - 1) // sector
        start = archive.header["offset"] + block.offset
        offsets = struct.unpack_from(f"<{count + 1}I", raw, start)
        sizes = [offsets[i + 1] - offsets[i] for i in range(count)]
        if block.flags & 0x200 and any(s == sector for s in sizes[:-1]):
            explained += 1
        else:
            unexplained.append(name)
    return ok, explained, unexplained


def mdx_texture_paths(data):
    """Texture paths in an MDX (TEXS chunk: replaceable id, path[260], flags)."""
    pos, out = 4, []
    while pos + 8 <= len(data):
        tag, size = data[pos:pos + 4], struct.unpack_from("<I", data, pos + 4)[0]
        if tag == b"TEXS":
            for at in range(pos + 8, pos + 8 + size, 268):
                path = data[at + 4:at + 264].split(bytes(1), 1)[0].decode("ascii")
                if path:
                    out.append(path)
        pos += 8 + size
    return out


def psnr(a, b):
    diff = ImageChops.difference(a.convert("RGB"), b.convert("RGB"))
    mse = sum(v * v for v in ImageStat.Stat(diff).rms) / 3
    return 99.0 if mse == 0 else 10 * math.log10(255 * 255 / mse)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dota", required=True)
    ap.add_argument("--game", required=True)
    ap.add_argument("--work", required=True)
    ap.add_argument("--base", default=str(ROOT / "build" / "test" / "DotaVsCommander_test.w3x"))
    args = ap.parse_args()
    # -I ignores PYTHONIOENCODING: keep the non-ASCII --out path printable on a cp1252 stdout.
    sys.stdout.reconfigure(errors="backslashreplace")
    work = Path(args.work)
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    base = work / "base.w3x"
    shutil.copyfile(args.base, base)       # snapshot: the map may be rebuilt meanwhile
    common = ["--dota", args.dota, "--game", args.game, "--map", str(base), "--prepare-only", "--quiet"]

    # 1. cold cache, 2. warm cache, 3. cold again, 4. non-ASCII output path
    shutil.rmtree(CACHE, ignore_errors=True)
    code1, t_cold = run_exe(common + ["--out", str(work / "run1" / "DotaVsCommander.w3x")])
    check("cold run exit code 0", code1 == 0, f"{t_cold:.1f} s")
    code2, t_warm = run_exe(common + ["--out", str(work / "run2" / "DotaVsCommander.w3x")])
    check("warm run exit code 0", code2 == 0, f"{t_warm:.1f} s")
    shutil.rmtree(CACHE, ignore_errors=True)
    code3, t_cold2 = run_exe(common + ["--out", str(work / "run3" / "DotaVsCommander.w3x")])
    check("second cold run exit code 0", code3 == 0, f"{t_cold2:.1f} s")
    unicode_out = work / "Документы тест" / "Карты" / "DotaVsCommander.w3x"
    code4, _ = run_exe(common + ["--out", str(unicode_out)])
    out = work / "run1" / "DotaVsCommander.w3x"
    data = out.read_bytes()
    check("warm output byte-identical to cold output",
          data == (work / "run2" / "DotaVsCommander.w3x").read_bytes(), sha(data))
    check("second cold output byte-identical", data == (work / "run3" / "DotaVsCommander.w3x").read_bytes())
    check("non-ASCII --out path works", code4 == 0 and unicode_out.read_bytes() == data, str(unicode_out))
    results["timing"] = {"cold_s": round(t_cold, 1), "warm_s": round(t_warm, 1), "cold2_s": round(t_cold2, 1)}
    results["map"] = {"bytes": len(data), "sha256": sha(data)}

    # Expected contents
    roster = assets.roster_from_heroes(assets.load_json(ROOT / "src" / "data" / "heroes.json"))
    manifest = assets.load_json(ROOT / "launcher" / "vo_manifest.json")
    sounds = assets.load_json(ROOT / "src" / "data" / "sounds.json")
    item_icons = assets.load_json(ROOT / "src" / "data" / "items.json").get("icons", [])
    hud = assets.load_hud_specs(ROOT / "specs" / "hud_assets.json")
    expected_assets = assets.expected_map_files(roster, manifest, item_icons, hud)
    sound_paths = [p for hero in sounds.values() for paths in hero.values() for p in paths]
    check("sounds.json paths match vo_manifest.json", sorted(sound_paths) == sorted(manifest["files"]))
    over = [f"{h}.{e}={len(p)}" for h, ev in sounds.items() for e, p in ev.items()
            if len(p) > VO_CAPS.get(e, VO_CAST_CAP) or not (e in VO_CAPS or e.startswith("cast_"))]
    per_event = {e: sum(len(ev.get(e, [])) for ev in sounds.values()) for e in VO_CAPS}
    per_event["cast"] = sum(len(p) for ev in sounds.values() for e, p in ev.items() if e.startswith("cast_"))
    check("voice lines per event within the caps (8 move/attack, 4 others, 3 per cast)", not over,
          f"{len(sound_paths)} lines {per_event}" + (f", over {over[:3]}" if over else ""))
    few = [h for h, ev in sounds.items() if min(len(ev.get("move", [])), len(ev.get("attack", []))) <= 4]
    check("every hero has more than 4 move and 4 attack lines", not few, ", ".join(few))

    storm = stormlib.StormLib(DLL)
    out_files = storm_read_all(storm, out)
    base_files = storm_read_all(storm, base)
    missing = [p for p in expected_assets if p not in out_files]
    check("every expected asset path is in the map", not missing,
          f"{len(expected_assets) - len(missing)}/{len(expected_assets)}" + (f", missing {missing[:5]}" if missing else ""))
    # Item icons: BTN + DISBTN of every items.json icon, and every BTNDota icon the
    # object data of the map names (items, shop tokens, abilities, heroes) with its DISBTN.
    item_paths = [p for e in item_icons for p in assets.icon_paths(e["key"], "item")]
    missing_items = [p for p in item_paths if p not in out_files]
    check("every item icon of items.json is in the map (BTN + DISBTN)", item_icons and not missing_items,
          f"{len(item_paths) - len(missing_items)}/{len(item_paths)}" + (f", missing {missing_items[:3]}" if missing_items else ""))
    named = sorted({m.decode("ascii") for n in OBJECT_FILES if n in out_files
                    for m in re.findall(rb"ReplaceableTextures\\CommandButtons\\BTNDota_\w+\.blp", out_files[n])})
    needed = named + [p.replace("CommandButtons\\BTN", "CommandButtonsDisabled\\DISBTN") for p in named]
    missing_named = [p for p in needed if p not in out_files]
    named_items = [p for p in named if "BTNDota_item_" in p]
    check("every BTNDota icon the object data names is in the map with its DISBTN", named_items and not missing_named,
          f"{len(named)} icons ({len(named_items)} item icons)" + (f", missing {missing_named[:3]}" if missing_named else ""))
    results["item_icons"] = {"files": len(item_paths), "bytes": sum(len(out_files.get(p, b"")) for p in item_paths),
                             "named_by_object_data": len(named_items)}
    if hud:
        not_pot = []
        for e in hud:
            head = out_files.get(e["target"], b"")[:20].ljust(20, b"\0")
            magic, _content, alpha_bits, w, h = struct.unpack("<4sIIII", head)
            want = tuple(assets.pot_side(min(v, assets.HUD_MAX_SIDE)) for v in e["size"]) if e["size"] else (w, h)
            if magic != b"BLP1" or alpha_bits != 8 or not w or not h or w & (w - 1) or h & (h - 1) or (w, h) != want:
                not_pot.append(e["target"])
        check("every HUD image is in the map: BLP1, 8-bit alpha, power-of-two sides, requested size", not not_pot,
              f"{len(hud)} images" + (f", bad {not_pot[:3]}" if not_pot else ""))
        # The UI script asks for war3mapImported\Hud\<name>.blp through Kit.tex("<name>", fallback).
        ui_names = sorted({m for f in (ROOT / "src" / "ui").glob("*.lua")
                           for m in re.findall(r'Kit\.tex\("(\w+)"', f.read_text(encoding="utf-8"))})
        targets = {e["target"].lower() for e in hud}
        unlisted = [n for n in ui_names if f"war3mapimported\\hud\\{n}.blp".lower() not in targets]
        check("every HUD image the UI script names (Kit.tex) is a hud_assets.json target", not unlisted,
              f"{len(ui_names)} names" + (f", not listed {unlisted[:5]}" if unlisted else ""))
        results["hud"] = {"files": len(hud), "bytes": sum(len(out_files.get(e["target"], b"")) for e in hud)}
    else:
        print("[SKIP] HUD images: specs/hud_assets.json not present")
    internal = {"(listfile)", "(attributes)", "(signature)"}
    # Dota's map layout replaces these (launcher/tests/test_terrain.py checks them).
    layout = set(terrain.MAP_FILES)
    changed = [n for n, d in base_files.items() if n not in internal | layout and not terrain.is_terrain_asset(n)
               and out_files.get(n) != d]
    check("every base map file outside the map layout is byte-for-byte identical", not changed,
          f"{len([n for n in base_files if n not in internal])} files" + (f", changed {changed}" if changed else ""))
    relaid = sorted(n for n in layout if out_files.get(n) != base_files.get(n))
    check("Dota's map layout replaced the layout files", relaid == sorted(layout), ", ".join(relaid))
    # Unit models: every key of specs/models.json and its portrait model, plus the textures each MDX names.
    model_keys = models.load_keys(ROOT / "specs" / "models.json")
    mdx_names = sorted(models.model_files(model_keys))
    missing_mdx = [n for n in mdx_names if n not in out_files]
    check("every unit model of models.json is in the map", not missing_mdx,
          f"{len(mdx_names) - len(missing_mdx)}/{len(mdx_names)}" + (f", missing {missing_mdx[:3]}" if missing_mdx else ""))
    model_textures = sorted({t for n in mdx_names if n in out_files for t in mdx_texture_paths(out_files[n])})
    missing_tex = [t for t in model_textures if t not in out_files]
    check("every texture the models use is in the map", not missing_tex,
          f"{len(model_textures)} textures" + (f", missing {missing_tex[:3]}" if missing_tex else ""))
    model_dir = work / "models"
    for n in mdx_names + model_textures:
        if n in out_files:
            f = model_dir / n.replace("\\", "/")
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(out_files[n])
    node_mdx = subprocess.run(["node", str(ROOT / "tools" / "check_mdx.js")] + sorted(str(p) for p in model_dir.rglob("*.mdx")),
                              capture_output=True, text=True, cwd=str(ROOT))
    try:
        mdx_report = json.loads(node_mdx.stdout)
    except ValueError:
        mdx_report = {}
    mdx_bad = [Path(f).name for f, r in mdx_report.items() if not r["ok"]]
    check("mdx-m3-viewer reads every model from the map back byte for byte",
          mdx_report and not mdx_bad, f"{len(mdx_report)} models" + (f", bad {mdx_bad[:3]}" if mdx_bad else ""))
    model_bytes = sum(len(out_files[n]) for n in mdx_names + model_textures if n in out_files)
    results["models"] = {"files": len(mdx_names) + len(model_textures), "bytes": model_bytes}
    expected_assets = list(expected_assets) + mdx_names + model_textures

    extra = sorted(set(out_files) - set(base_files) - set(expected_assets) - internal)
    extra = [n for n in extra if not terrain.is_terrain_asset(n)]     # Dota's trees and tiles (test_terrain.py)
    check("no unexpected files", not extra, ", ".join(extra[:5]))
    h = storm.open_archive(out)
    try:
        bad = [n for n in out_files if n not in internal and not storm.verify_file(h, n.encode())]
        attributes = storm.read_file(h, b"(attributes)")
    finally:
        storm.SFileCloseArchive(h)
    version, flags = struct.unpack_from("<II", attributes)
    check("StormLib CRC32 check of every file", not bad, f"{len(out_files) - len(internal & set(out_files))} files")
    check("(attributes) present, CRC32 only", version == 100 and flags == 1, f"version {version}, flags {flags:#x}")

    # Independent readers
    listed = {n: d for n, d in out_files.items() if n not in internal}
    node = subprocess.run(["node", str(ROOT / "launcher" / "tests" / "verify_mpq.js"), str(out)],
                          capture_output=True, text=True, cwd=str(ROOT))
    node_files = json.loads(node.stdout)["files"] if node.returncode == 0 else {}
    node_ok = sum(1 for n, d in listed.items() if node_files.get(n, {}).get("sha256") == sha(d))
    check("mdx-m3-viewer (Node) reads every file identically", node_ok == len(listed), f"{node_ok}/{len(listed)}")
    m_ok, m_explained, m_bad = mpyq_check(out, listed)
    check("mpyq reads the archive", not m_bad,
          f"{m_ok}/{len(listed)} exact; {m_explained} have raw middle sectors that mpyq cannot decode"
          + (f"; unexplained {m_bad[:3]}" if m_bad else ""))

    # BLP vs source PNG
    plan = json.loads((CACHE / [d for d in os.listdir(CACHE)][0] / "plan.json").read_text(encoding="utf-8"))
    raw_dir = CACHE / plan["build"] / "raw"
    cmp_dir = work / "blp_compare"
    cmp_dir.mkdir()
    for key in SAMPLE_ICONS:
        icon = next(i for i in plan["icons"] if i["key"] == key)
        png = raw_dir / vrf.output_path(icon["sources"][0])
        source = assets.icon_image(png.read_bytes())
        row = []
        for path in assets.icon_paths(key, icon["kind"]):      # items have no PASBTN
            blp_image = Image.open(__import__("io").BytesIO(out_files[path]))
            blp_image.load()
            row.append(blp_image.convert("RGBA"))
        quality = psnr(row[0], source)
        sheet = Image.new("RGBA", (64 * 5 + 16, 64), (32, 32, 32, 255))
        diff = ImageChops.difference(row[0].convert("RGB"), source.convert("RGB")).point(lambda v: min(255, v * 4))
        for i, img in enumerate([source] + row + [diff.convert("RGBA")]):
            sheet.paste(img, (i * 68, 0))
        sheet = sheet.resize((sheet.width * 3, sheet.height * 3), Image.Resampling.NEAREST)
        sheet.save(cmp_dir / f"{key}.png")
        pas = f", PAS==BTN {row[2].tobytes() == row[0].tobytes()}" if len(row) > 2 else ""
        check(f"BLP {key} opens in Pillow and matches source", row[0].size == (64, 64) and quality > 30,
              f"PSNR {quality:.1f} dB, Pillow mode {row[0].mode}{pas}")

    # Item icons and HUD images come from Dota images, not placeholders; HUD images keep their alpha.
    item_plan = [i for i in plan["icons"] if i["kind"] == "item"]
    no_source = [i["key"] for i in item_plan if not i["sources"]]
    not_exact = [f"{i['key']} ({i['note']})" for i in item_plan if i["sources"] and i["note"] != "exact"]
    check("every item icon is converted from a Dota item image (no placeholders)", item_plan and not no_source,
          f"{len(item_plan) - len(no_source)}/{len(item_plan)}" + (f", placeholders {no_source[:3]}" if no_source else "")
          + (f", not exact {not_exact[:3]}" if not_exact else ""))
    hud_bad = []
    for e in plan.get("hud", []):
        if not e["sources"]:
            hud_bad.append(f"{e['target']} (placeholder)")
            continue
        got = blp.decode(out_files[e["target"]])
        want, _ = assets.hud_image(assets.load_rgba((raw_dir / vrf.output_path(e["sources"][0])).read_bytes()),
                                   e["size"], e["fit"])
        if got.size != want.size:
            hud_bad.append(f"{e['target']} ({got.size[0]}x{got.size[1]}, expected {want.size[0]}x{want.size[1]})")
            continue
        alpha_diff = ImageChops.difference(got.getchannel("A"), want.getchannel("A")).getextrema()[1]
        black = Image.new("RGBA", got.size, (0, 0, 0, 255))
        quality = psnr(Image.alpha_composite(black, got), Image.alpha_composite(black, want))
        if alpha_diff or quality <= 30:
            hud_bad.append(f"{e['target']} (alpha diff {alpha_diff}, PSNR {quality:.1f} dB)")
    if plan.get("hud"):
        check("every HUD image is converted from its Dota source with its alpha", not hud_bad,
              f"{len(plan['hud']) - len(hud_bad)}/{len(plan['hud'])}" + (f", bad {hud_bad[:3]}" if hud_bad else ""))

    # MP3s
    mp3_dir = work / "mp3"
    mp3_dir.mkdir()
    probe_bad, decode_bad, total_s = [], [], 0.0
    for n in manifest["files"]:
        f = mp3_dir / (n.replace("\\", "_"))
        f.write_bytes(out_files[n])
        p = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name:format=duration",
                            "-of", "json", str(f)], capture_output=True, text=True)
        info = json.loads(p.stdout or "{}")
        codec = (info.get("streams") or [{}])[0].get("codec_name")
        duration = float(info.get("format", {}).get("duration", 0) or 0)
        if p.returncode or codec != "mp3" or duration <= 0:
            probe_bad.append(n)
        total_s += duration
        d = subprocess.run(["ffmpeg", "-v", "error", "-i", str(f), "-f", "null", "-"], capture_output=True, text=True)
        if d.returncode or d.stderr.strip():
            decode_bad.append(n)
    vo_bytes = sum(len(out_files[n]) for n in manifest["files"])
    results["vo"] = {"lines": len(manifest["files"]), "bytes": vo_bytes, "seconds": round(total_s)}
    check("every MP3 probes as mp3 with a duration", not probe_bad,
          f"{len(manifest['files']) - len(probe_bad)}/{len(manifest['files'])}, {total_s:.0f} s of audio, "
          f"{vo_bytes / 1048576:.1f} MB")
    check("every MP3 decodes without errors (ffmpeg)", not decode_bad, ", ".join(decode_bad[:3]))
    # Each event keeps its full count of different lines: no silent fallback, no line repeated in place of a missing one.
    vo_data = [out_files[n] for n in manifest["files"]]
    silent_n = sum(1 for d in vo_data if d == assets.SILENT_MP3)
    distinct = len({sha(d) for d in vo_data})
    check("every voice line is a distinct Dota line (no silent fallbacks, no repeats)",
          not silent_n and distinct == len(vo_data), f"{distinct}/{len(vo_data)} distinct, {silent_n} silent")
    silent = mp3_dir / "silent.mp3"
    silent.write_bytes(assets.SILENT_MP3)
    d = subprocess.run(["ffmpeg", "-v", "error", "-i", str(silent), "-f", "null", "-"], capture_output=True, text=True)
    check("fallback silent MP3 decodes", d.returncode == 0 and not d.stderr.strip())

    # Failure paths: clear exit codes, no message boxes (--quiet)
    fake = work / "fake_dota"
    (fake / "game" / "dota").mkdir(parents=True)
    cases = [
        ("missing Dota folder -> 3", ["--dota", str(work / "nope"), "--game", args.game, "--map", str(base)], 3),
        ("folder that is not Dota -> 3", ["--dota", str(work), "--game", args.game, "--map", str(base)], 3),
        ("Dota without pak01_dir.vpk -> 4", ["--dota", str(fake), "--game", args.game, "--map", str(base)], 4),
        ("missing base map -> 6", ["--dota", args.dota, "--game", args.game, "--map", str(work / "none.w3x")], 6),
        ("missing --dota -> 2", ["--game", args.game], 2),
        ("WC3 folder without the game -> 8", ["--dota", args.dota, "--game", str(work), "--map", str(base)], 8),
        ("--out inside the Dota folder -> 7", ["--dota", args.dota, "--game", args.game, "--map", str(base),
                                              "--out", str(Path(args.dota) / "x.w3x")], 7),
    ]
    for label, extra_args, want in cases:
        # --prepare-only everywhere except the case that needs the launch path,
        # whose --game folder has no Warcraft III.exe to start.
        code, _ = run_exe(extra_args + ["--quiet"] + ([] if want == 8 else ["--prepare-only"]))
        check(f"error path: {label}", code == want, f"exit {code}")
    # A model conversion that fails must stop the launcher before a map is written:
    # drop the model cache (icons and voices stay cached) and point it at a missing VRF.
    if model_keys:
        for d in CACHE.glob(f"*/{models.CACHE_PREFIX}*"):
            shutil.rmtree(d, ignore_errors=True)
        no_map = work / "no_map" / "DotaVsCommander.w3x"
        code, _ = run_exe(common + ["--out", str(no_map), "--vrf", str(work / "missing" / "vrf.exe")])
        check("error path: model conversion fails -> 5, no map written", code == 5 and not no_map.exists(),
              f"exit {code}, map {'written' if no_map.exists() else 'not written'}")
    check("log file written", LOG.is_file(), str(LOG))
    check("default --out resolves via SHGetKnownFolderPath", True, str(cli.default_out()))

    size = sum(f.stat().st_size for f in DIST.rglob("*") if f.is_file())
    results["dist_bytes"] = size
    print(f"dist size: {size / 1048576:.1f} MB")
    (work / "results.json").write_text(json.dumps(results, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
