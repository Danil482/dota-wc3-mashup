"""Effect models from the player's Dota 2 particles: attack projectiles and
signature spell effects listed in specs/effects.json, converted by
mdx/particles.py into classic MDX 800 with palette BLP1 textures and cached
per Dota build.

Naming contract with the map:
  war3mapImported\\Dota\\fx\\<key>.mdx      the effect model
  war3mapImported\\Dota\\fx\\<texture>.blp  its textures (shared between effects)

"missiles": tools/gen_objects.py points the attack missile art (ua1m) of the
listed units at the model in release and --dota-models builds, like the unit
models. Every one of them is written: a missile whose particles could not be
converted gets a plain glow drawn here, never an invisible projectile.
"effects": the Lua picks spell effects at run time through data.effects
(src/core/fx.lua). The base map ships an empty table and the hero files keep
their WC3 fallbacks; patch_lua fills the table between the
"-- @dvw-data-begin/end data.effects" markers of war3map.lua with the
effects actually converted, so a failed one keeps its WC3 look.

Cold path, once per Dota build and converter version (a few seconds):
  1. VRF prints the DATA block (KV3) of every root system, then of the
     children they name, until the trees are complete.
  2. VRF exports the textures the renderers use (PNG) and prints their sheet
     data; sheet frames are repacked into WC3 grids (mdx/fxtextures.py).
  3. mdx/particles.py builds each model.
"""
import hashlib
import json
import os
import re
import shutil
import time
from pathlib import Path

from . import models, stormlib, vrf
from .mdx import fxtextures, kv3, particles
from .terrain import w3x

FX_DIR = "war3mapImported\\Dota\\fx\\"
CACHE_PREFIX = "effects-"
USAGES = ("missile", "attached", "oneshot")
DATA_BEGIN = "-- @dvw-data-begin data.effects"
DATA_END = "-- @dvw-data-end data.effects"
MAX_ROUNDS = 8
FALLBACK_COLOR = (255, 230, 170)


class EffectError(Exception):
    pass


def model_path(key):
    return f"{FX_DIR}{key}.mdx"


def load_spec(path):
    """specs/effects.json -> {key: entry}; each entry has "source", "usage"
    and the optional "units", "fallback", "scale", "drop"."""
    with open(path, encoding="utf-8") as f:
        raw = json.load(f)
    out = {}
    for section, usage in (("missiles", "missile"), ("effects", None)):
        for key, entry in (raw.get(section) or {}).items():
            if not re.fullmatch(r"[a-z0-9_]+", key):
                raise ValueError(f"effects.json: bad key {key!r}")
            if key in out:
                raise ValueError(f"effects.json: {key} listed twice")
            e = dict(entry)
            e["section"] = section
            e["usage"] = usage or e.get("usage", "oneshot")
            if e["usage"] not in USAGES or not str(e.get("source", "")).endswith(".vpcf"):
                raise ValueError(f"effects.json: {key} needs a .vpcf source and a usage in {USAGES}")
            out[key] = e
    return out


def inputs_digest(spec):
    blob = json.dumps({"particles": particles.VERSION, "spec": spec,
                       "textures": [fxtextures.SPRITE_LIMIT, fxtextures.SHEET_LIMIT, fxtextures.MAX_FRAMES]},
                      sort_keys=True)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def expected_files(spec):
    """Map paths that must exist after prepare: every missile model."""
    return {model_path(k) for k, e in spec.items() if e["section"] == "missiles"}


# ------------------------------------------------------------------ VRF

def _dump(vrf_exe, vpk, paths, block, work_dir, log):
    try:
        text = models._run_vrf(vrf_exe, ["-i", str(vpk), "-b", block, "-f", ",".join(sorted(paths))],
                               work_dir, log, f"{block} dump")
    except models.ModelError as e:
        raise EffectError(str(e)) from e
    return kv3.split_dump(text)


def collect(vrf_exe, vpk, roots, work_dir, log):
    """{vpcf_c path: definition} of every system under `roots`."""
    tree, wanted, missing = {}, {particles.compiled(r) for r in roots}, set()
    for _round in range(MAX_ROUNDS):
        todo = sorted(wanted - set(tree) - missing)
        if not todo:
            break
        dumps = _dump(vrf_exe, vpk, todo, "DATA", work_dir, log)
        for path in todo:
            blocks = dumps.get(path)
            if not blocks:
                missing.add(path)
                continue
            try:
                d = kv3.loads(blocks[0])
            except kv3.Kv3Error as e:
                log(f"effects: {path} could not be read: {e}")
                missing.add(path)
                continue
            tree[path] = d
            for child in d.get("m_Children", []) or []:
                if isinstance(child, dict) and child.get("m_ChildRef"):
                    wanted.add(particles.compiled(child["m_ChildRef"]))
    for path in sorted(missing):
        log(f"effects: {path} not in this Dota build")
    return tree


def texture_name(vtex, sequence, sheet, stretched):
    stem = vtex.rsplit("/", 1)[-1].replace(".vtex_c", "")
    stem = re.sub(r"[^a-z0-9_]", "_", stem.lower())
    return f"{FX_DIR}{stem}{f'_s{sequence}' if sheet else ''}{'_t' if stretched else ''}.blp"


# ------------------------------------------------------------------ conversion

def fallback_model(key):
    """A plain glowing missile (texture drawn by fxtextures.glow)."""
    e = particles.Emitter("Glow", "pre2")
    e.flags = particles.F_PRE2 | particles.F_UNSHADED | particles.F_MODEL_SPACE
    e.filter = particles.P_ADD
    e.life, e.rate = particles.SUSTAIN_LIFE, 8.0
    e.scaling = (28.0, 28.0, 28.0)
    e.alphas = (255, 255, 255)
    layout = particles.Layout("missile")
    e.tracks.append(("KP2V", particles._visibility(layout, {"stand", "birth"}), 0))
    return particles.write(key, [e], layout, [f"{FX_DIR}dvw_glow.blp"])


def convert_effect(key, entry, tree, texture_files, tex_dir, log):
    """(MDX bytes, {map path: BLP bytes}, info) of one effect, or None."""
    nodes = particles.walk(tree, entry["source"], entry["usage"], log, drop=tuple(entry.get("drop", ())),
                           cps=entry.get("cp"))
    if not nodes:
        log(f"effects: {key}: nothing WC3 can draw in {entry['source']}")
        return None
    paths, lookup, own = [], {}, {}
    for n in nodes:
        stretched = n.spec.kind in ("trail", "rope")
        pair = (n.spec.texture, n.spec.sequence, stretched)
        if pair in lookup:
            continue
        sources = fxtextures.source(tex_dir, n.spec.texture, n.spec.sequence)
        if not sources:
            lookup[pair] = None
            continue
        sheet = not sources[0].name.endswith(n.spec.texture.rsplit("/", 1)[-1].replace(".vtex_c", ".png"))
        name = texture_name(n.spec.texture, n.spec.sequence, sheet, stretched)
        if name not in texture_files:
            try:
                texture_files[name] = fxtextures.convert(sources, stretched)
            except (OSError, ValueError) as e:
                log(f"effects: {key}: texture {n.spec.texture}: {e}")
                lookup[pair] = None
                continue
        data, rows, cols, count = texture_files[name]
        own[name] = data
        if name not in paths:
            paths.append(name)
        lookup[pair] = (paths.index(name), rows, cols, count)
    lookup = {k: v for k, v in lookup.items() if v is not None}
    if entry["usage"] in ("attached", "missile") and not any(
            n.phase == "stand" and (n.spec.texture, n.spec.sequence, n.spec.kind in ("trail", "rope")) in lookup
            for n in nodes):
        # Only a launch or endcap part converts (the rest are models or lights):
        # nothing would show while the effect lasts, so the WC3 one stays.
        log(f"effects: {key}: nothing to show while it lasts, not converted")
        return None
    emitters, layout = particles.build_emitters(nodes, entry["usage"], lookup, log,
                                                scale=float(entry.get("scale", 1.0)))
    if not emitters:
        return None
    mdx = particles.write(key, emitters, layout, paths)
    info = {"emitters": len(emitters), "systems": len(nodes), "textures": len(paths),
            "sequences": [s[0] for s in layout.seqs]}
    return mdx, own, info


def prepare(vpk, vrf_exe, build_dir, spec, log):
    """Map files ({map path: bytes}) of the effects in `spec`, from the cache
    of this Dota build when it is complete. Raises EffectError only when not
    even the fallback missiles can be written."""
    if not spec:
        return {}
    vpk, vrf_exe, build_dir = Path(vpk).resolve(), Path(vrf_exe).resolve(), Path(build_dir).resolve()
    digest = inputs_digest(spec)
    folder = build_dir / f"{CACHE_PREFIX}{particles.VERSION}-{digest[:16]}"
    cached = models.read_cache(folder)
    if cached is not None and expected_files(spec) <= set(cached[0]):
        log(f"effects: cache complete ({len(cached[0])} files, {folder.name})")
        return cached[0]
    t0 = time.perf_counter()
    work = build_dir / f"effects-work-{os.getpid()}"
    shutil.rmtree(work, ignore_errors=True)
    files, info = {}, {}
    try:
        try:
            tree = collect(vrf_exe, vpk, [e["source"] for e in spec.values()], work / "vrf", log)
            vtex = sorted({n.spec.texture for e in spec.values()
                           for n in particles.walk(tree, e["source"], e["usage"], drop=tuple(e.get("drop", ())))})
            if vtex:
                vrf.extract(vrf_exe, vpk, vtex, work / "tex", work / "vrf", log)
        except (EffectError, vrf.VrfError, OSError) as e:
            log(f"effects: Dota particles could not be read: {e}")
            tree = {}
        t1 = time.perf_counter()
        textures = {}
        for key, entry in sorted(spec.items()):
            result = None
            if tree:
                try:
                    result = convert_effect(key, entry, tree, textures, work / "tex", log)
                except Exception as e:  # noqa: BLE001 - one odd particle system never stops the launcher
                    log(f"effects: {key}: not converted: {type(e).__name__}: {e}")
            if result is None:
                if entry["section"] == "missiles":
                    files[model_path(key)] = fallback_model(key)
                    files[f"{FX_DIR}dvw_glow.blp"] = fxtextures.glow(FALLBACK_COLOR)
                    info[key] = {"fallback": True}
                    log(f"effects: {key}: plain glow missile")
                continue
            mdx, own, info[key] = result
            files[model_path(key)] = mdx
            files.update(own)
        size = sum(len(d) for d in files.values())
        log(f"effects: VRF {t1 - t0:.1f} s, converted {sum(1 for i in info.values() if 'fallback' not in i)}"
            f"/{len(spec)} effects in {time.perf_counter() - t1:.1f} s ({size / 1048576:.2f} MB)")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    missing = sorted(expected_files(spec) - set(files))
    if missing:
        raise EffectError(f"no model produced for {', '.join(missing)}")
    try:
        models.write_cache(folder, files, info)
    except OSError as e:
        log(f"effects: cache not written: {e}")
    prune(build_dir, folder.name)
    return files


def prune(build_dir, keep):
    for d in Path(build_dir).glob(CACHE_PREFIX + "*"):
        if d.is_dir() and d.name != keep and re.fullmatch(re.escape(CACHE_PREFIX) + r"\d+-[0-9a-f]{16}", d.name):
            shutil.rmtree(d, ignore_errors=True)


# ------------------------------------------------------------------ war3map.lua

def converted(spec, files):
    """{key: model path} of the spell effects (not missiles) present in files."""
    return {k: model_path(k) for k, e in sorted(spec.items())
            if e["section"] == "effects" and model_path(k) in files}


def patch_lua(script, table):
    """war3map.lua with the data.effects block replaced by `table`; the
    markers stay. None when the script has no such block (a base map built
    before src/data/effects.json existed)."""
    pattern = re.compile(re.escape(DATA_BEGIN) + r"\n.*?" + re.escape(DATA_END), re.S)
    if len(pattern.findall(script)) != 1:
        return None
    chunk = f"define({json.dumps('data.effects')}, function()\n    return {w3x.lua_literal(table, 4)}\nend)\n"
    return pattern.sub(lambda _m: f"{DATA_BEGIN}\n{chunk}{DATA_END}", script)


def lua_files(base_map, stormlib_dll, files, spec, log):
    """{"war3map.lua": bytes} with data.effects listing the converted spell
    effects, patched into the script `files` already holds (the terrain step
    patches it too) or the base map's; {} when nothing can be patched, which
    keeps every WC3 fallback."""
    table = converted(spec, files)
    script = files.get("war3map.lua")
    if script is None:
        try:
            storm = stormlib.StormLib(stormlib_dll)
            h = storm.open_archive(base_map)
            try:
                script = storm.read_file(h, b"war3map.lua")
            finally:
                storm.SFileCloseArchive(h)
        except (stormlib.StormError, OSError) as e:
            log(f"effects: war3map.lua not read, WC3 spell effects stay: {e}")
            return {}
    try:
        patched = patch_lua(script.decode("utf-8"), table)
    except UnicodeDecodeError as e:
        log(f"effects: war3map.lua not patched: {e}")
        return {}
    if patched is None:
        log("effects: the base map has no data.effects block, WC3 spell effects stay")
        return {}
    log(f"effects: {len(table)} Dota spell effects in data.effects")
    return {"war3map.lua": patched.encode("utf-8")}
