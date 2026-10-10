"""Unit models from the player's Dota 2 install: export with VRF (glTF),
convert to Warcraft III MDX + BLP textures, cache per Dota build.

Naming contract with the map (tools/gen_objects.py reads specs/models.json):
  war3mapImported\\Dota\\<key>.mdx          the unit model
  war3mapImported\\Dota\\<key>_portrait.mdx its static portrait model, for
                                           units flagged "portrait" in units.py
  war3mapImported\\Dota\\<key>_<name>.blp   its textures
Units with the same Dota model (tower1..tower4) get their own .mdx and share
the first unit's textures, unless units.py swaps one ("textures": the
sentry ward is the observer ward with the sentry's material group).

Cold path, once per Dota build and converter version (about a minute):
  1. VRF prints the sequence (ASEQ) and mesh (MDAT) blocks of every main
     model: clip names with their Dota activities, and attachments.
  2. The clips of each unit are chosen (units.py table, then activity, then
     name pattern).
  3. VRF exports every model and cosmetic item as .glb with those clips.
  4. mdx.convert builds each model; the files go into the cache folder
     with a manifest of SHA256 hashes. Later runs read them back.
Any failure raises ModelError: the launcher stops rather than write a map
whose units reference a missing model.
"""
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import time
from pathlib import Path

from . import vpkdir, vrf
from .mdx import CONVERTER_VERSION, convert, gltf, kv3, textures, units, writer

MAP_DIR = "war3mapImported\\Dota\\"
VPK_PREFIXES = ("models/heroes/", "models/creeps/", "models/props_structures/", "models/props_gameplay/",
                "materials/models/props_gameplay/")
CACHE_PREFIX = "models-"
# Portrait models use palette BLP1 textures of at most this many pixels a side.
PORTRAIT_TEXTURE = 256
# Model textures: "palette" (the 256-colour BLP1 the icons use) or "jpeg"
# (BLP1 JPEG content). Palette files are about 3.8x bigger on disk but a
# little smaller in the map, whose zlib sectors cannot shrink JPEG data
# (7.7 vs 8.2 MiB for all 126 textures; palette PSNR 34.6 dB at worst).
# Palette since 2026-10-10: the game hung, at random, when a neutral with a
# converted model was clicked, and this keeps BLP1 JPEG out of the picture.
TEXTURE_ENCODING = "palette"
# Sequences of cosmetic, event or menu variants: never picked by the fallbacks.
VARIANT_MARKERS = re.compile(r"arcana|persona|loadout|portrait|capture|versus|taunt|statue|effigy|ti\d|ftp_|hh_|"
                             r"trapper|harpoon|whalehook|injured|_alt_|frostivus|diretide|crimson|immortal",
                             re.IGNORECASE)


class ModelError(Exception):
    pass


def load_keys(models_json_path):
    """Unit keys the map expects, from specs/models.json (map paths checked)."""
    try:
        with open(models_json_path, encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        return []
    keys = []
    for key, entry in data.items():
        if key not in units.UNITS:
            raise ModelError(f"specs/models.json lists {key}, which the converter does not know")
        if entry.get("model") != f"{MAP_DIR}{key}.mdx":
            raise ModelError(f"specs/models.json: {key} must use {MAP_DIR}{key}.mdx")
        portrait = entry.get("portrait")
        if isinstance(portrait, str) and portrait.startswith(MAP_DIR) and (
                portrait != portrait_path(key) or not units.resolve(key).get("portrait")):
            raise ModelError(f"specs/models.json: {key} has no portrait model {portrait}")
        keys.append(key)
    return keys


def portrait_path(key):
    return f"{MAP_DIR}{key}_portrait.mdx"


def inputs_digest(keys):
    table = {k: units.UNITS[k] for k in keys}
    for k in keys:
        base = units.UNITS[k].get("same_as")
        if base:
            table[base] = units.UNITS[base]
    blob = json.dumps({"converter": CONVERTER_VERSION, "keys": keys, "units": table,
                       "sequences": units.SEQUENCES, "fallbacks": units.FALLBACKS,
                       "texture": [TEXTURE_ENCODING, textures.JPEG_QUALITY, textures.MAX_SIZE, PORTRAIT_TEXTURE]},
                      sort_keys=True)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def glb_path(root, vmdl):
    """Where VRF writes the .glb of models/x/y.vmdl."""
    return Path(root) / (vmdl[:-len(".vmdl")] + ".glb")


# ------------------------------------------------------------------ planning

def plan(listing, keys):
    """{key: {"unit", "model": vmdl, "items": [vmdl present in the VPK]}}"""
    out = {}
    for key in keys:
        unit = units.resolve(key)
        if units.compiled(unit["model"]) not in listing:
            raise ModelError(f"{key}: {unit['model']} is not in your Dota 2 files")
        items = [i for i in unit["items"] if units.compiled(i) in listing]
        out[key] = {"unit": unit, "model": unit["model"], "items": items,
                    "missing_items": [i for i in unit["items"] if i not in items]}
    return out


def parse_sequences(block_text):
    """ASEQ block -> {name: {"act": first activity, "mods": has modifiers, "weight": int, "loop": bool}}"""
    data = kv3.loads(block_text)
    out = {}
    for s in data.get("m_localS1SeqDescArray") or []:
        acts = s.get("m_activityArray") or []
        name = s.get("m_sName")
        if not name or not acts:
            continue
        out[name] = {"act": acts[0].get("m_name", ""), "mods": len(acts) > 1,
                     "weight": acts[0].get("m_nWeight", 1),
                     "loop": bool((s.get("m_flags") or {}).get("m_bLooping"))}
    return out


def parse_attachments(blocks):
    """MDAT blocks -> {attachment name: (bone name, offset)}"""
    out = {}
    for text in blocks:
        data = kv3.loads(text)
        for a in data.get("m_attachments") or []:
            v = a.get("value") or {}
            if v.get("m_nInfluences", 0) >= 1 and v.get("m_name"):
                out.setdefault(v["m_name"], (v["m_influenceNames"][0], tuple(v["m_vInfluenceOffsets"][0])))
    return out


def _activity_match(act, pattern):
    return act.startswith(pattern[:-1]) if pattern.endswith("*") else act == pattern


def select_clips(unit, sequences):
    """{WC3 sequence: Dota clip name or None} and notes on fallbacks."""
    notes = []
    chosen = {}
    if unit["kind"] == units.STRUCTURE:
        specs = [(n, {"Stand": ["ACT_DOTA_IDLE"], "Attack": ["ACT_DOTA_ATTACK"]}.get(n, []), [])
                 for n in units.STRUCTURE_SEQUENCES]
    else:
        specs = [(s[0], s[1], s[2]) for s in units.SEQUENCES]
    plain = {n: s for n, s in sequences.items() if not s["mods"] and not VARIANT_MARKERS.search(n)}
    for name, acts, patterns in specs:
        taken = {chosen.get("Attack")} if name == "Attack - 2" else set()
        want = unit["anims"].get(name)
        if want and want in sequences and want not in taken:
            chosen[name] = want
            continue
        pick = None
        for act in acts:
            cands = sorted((n for n, s in plain.items() if _activity_match(s["act"], act) and n not in taken),
                           key=lambda n: (-plain[n]["weight"], n))
            if cands:
                pick = cands[0]
                break
        if pick is None and want:
            for pat in patterns:
                rx = re.compile(pat, re.IGNORECASE)
                cands = sorted(n for n in plain if rx.search(n) and n not in taken)
                if cands:
                    pick = cands[0]
                    break
        if want and pick != want:
            notes.append(f"{name}: clip {want} missing, using {pick or 'a fallback'}")
        chosen[name] = pick
    return chosen, notes


# ------------------------------------------------------------------ VRF

def _run_vrf(vrf_exe, args, work_dir, log, what):
    env = dict(os.environ)
    env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
    Path(work_dir).mkdir(parents=True, exist_ok=True)
    try:
        proc = subprocess.run([str(vrf_exe)] + args, cwd=str(work_dir), env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              creationflags=vrf.CREATE_NO_WINDOW, timeout=1800)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise ModelError(f"VRF could not run ({what}): {e}") from e
    text = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != 0:
        tail = "\n".join(text.splitlines()[-15:])
        raise ModelError(f"VRF failed ({what}), exit code {proc.returncode}:\n{tail}")
    return text


def dump_blocks(vrf_exe, vpk, paths, block, work_dir, log):
    text = _run_vrf(vrf_exe, ["-i", str(vpk), "-b", block, "-f", ",".join(sorted(paths))], work_dir, log,
                    f"{block} dump")
    return kv3.split_dump(text)


def export_glb(vrf_exe, vpk, paths, clips, out_dir, work_dir, log, threads=4):
    def run(n):
        args = ["-i", str(vpk), "-d", "-o", str(out_dir), "--threads", str(n),
                "--gltf_export_format", "glb", "--gltf_export_animations", "--gltf_export_materials",
                "--gltf_textures_adapt", "--gltf_compose_additive",
                "--gltf_animation_list", ",".join(sorted(clips) or ["none"]), "-f", ",".join(sorted(paths))]
        _run_vrf(vrf_exe, args, work_dir, log, "model export")

    try:
        run(threads)
    except ModelError as e:
        # VRF 20.0 now and then crashes (access violation, about 1 run in 4
        # here) exporting a hundred models in parallel: retry once, serially.
        log(f"models: {e}; retrying with one thread")
        run(1)


# ------------------------------------------------------------------ conversion

def texture_stem(image):
    """Name part of a Dota texture in the map: .../observer_ward_color_psd_f9140241.png -> observer_ward."""
    stem = re.sub(r"_(psd|tga|png|jpg|tif)_[0-9a-f]+$", "", Path(image).stem, flags=re.IGNORECASE)
    stem = re.sub(r"_color$", "", stem)
    return re.sub(r"[^A-Za-z0-9_]", "_", stem)[:40] or "tex"


def texture_namer(key, files, encoding=None, limit=None):
    """texture_path_for() callback for convert: names, converts and dedupes
    the textures of one unit (at most `limit` pixels a side). files collects
    {map path: bytes}."""
    by_image = {}
    encoding = encoding or TEXTURE_ENCODING
    limit = limit or textures.MAX_SIZE

    def name_for(image, mat, alpha_mode):
        if image is not None and not Path(image).is_file():
            image = None
        if image is None:
            ident = ("placeholder", alpha_mode)
            stem = "missing"
        else:
            ident = (str(Path(image).resolve()).lower(), alpha_mode)
            stem = texture_stem(image)
        if ident not in by_image:
            path = f"{MAP_DIR}{key}_{stem}.blp"
            n = 2
            while path in files:
                path = f"{MAP_DIR}{key}_{stem}_{n}.blp"
                n += 1
            files[path] = textures.placeholder(encoding=encoding) if image is None else textures.convert(
                image, alpha_mode, limit=limit, encoding=encoding)
            by_image[ident] = path
        return by_image[ident], alpha_mode

    return name_for


def blp_info(data):
    """(compression: 0 JPEG / 1 palette, width, height) of BLP1 bytes."""
    compression, _alpha_bits, width, height = struct.unpack_from("<IIII", data, 4)
    return compression, width, height


def portrait_namer(key, files, world):
    """texture_path_for() of the portrait model: the unit's own texture when
    it is a palette BLP1 of at most PORTRAIT_TEXTURE a side, else a palette
    copy that small (<key>_portrait_<name>.blp)."""
    own = texture_namer(f"{key}_portrait", files, encoding="palette", limit=PORTRAIT_TEXTURE)

    def name_for(image, mat, alpha_mode):
        path, mode = world(image, mat, alpha_mode)
        compression, width, height = blp_info(files[path])
        if compression == 1 and max(width, height) <= PORTRAIT_TEXTURE:
            return path, mode
        return own(image, mat, alpha_mode)

    return name_for


def retexture(mdx, paths):
    """Copy of an MDX whose TEXS chunk points at other files ({old: new})."""
    at = mdx.index(b"TEXS")
    size = struct.unpack_from("<I", mdx, at + 4)[0]
    out = bytearray(mdx)
    for pos in range(at + 8, at + 8 + size, 268):
        old = bytes(out[pos + 4:pos + 264]).split(b"\0", 1)[0].decode("ascii")
        if old in paths:
            raw = paths[old].encode("ascii")[:259]
            out[pos + 4:pos + 264] = raw + b"\0" * (260 - len(raw))
    return bytes(out)


def convert_unit(key, entry, glb_root, clips, attachments, log):
    """-> ({map path: bytes}, info)"""
    unit = entry["unit"]
    main = glb_path(glb_root, entry["model"])
    if not main.is_file():
        raise ModelError(f"{key}: VRF did not export {entry['model']}")
    items = []
    for item in entry["items"]:
        p = glb_path(glb_root, item)
        if p.is_file():
            items.append(p)
        else:
            log(f"model {key}: cosmetic {item} was not exported, skipped")
    files = {}
    try:
        conv = convert.Converter(key, unit, main, items, clips, attachments, log)
        world = texture_namer(key, files, limit=unit.get("max_texture"))
        model, info = conv.convert(world, portrait_namer(key, files, world) if unit.get("portrait") else None)
        files[f"{MAP_DIR}{key}.mdx"] = writer.write(model)
        if conv.portrait is not None:
            files[portrait_path(key)] = writer.write(conv.portrait)
    except (convert.ConvertError, gltf.GltfError, ValueError, KeyError, IndexError, OSError) as e:
        raise ModelError(f"{key}: conversion failed: {e}") from e
    return files, info


def _hash(data):
    return hashlib.sha256(data).hexdigest()


def read_cache(folder):
    """Files of a complete cache folder, or None."""
    try:
        manifest = json.loads((folder / "manifest.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    files = {}
    for name, digest in manifest.get("files", {}).items():
        try:
            data = (folder / "files" / name.replace("\\", "/")).read_bytes()
        except OSError:
            return None
        if _hash(data) != digest:
            return None
        files[name] = data
    return files, manifest


def write_cache(folder, files, info):
    tmp = folder.with_name(folder.name + f".tmp{os.getpid()}")
    shutil.rmtree(tmp, ignore_errors=True)
    for name, data in files.items():
        p = tmp / "files" / name.replace("\\", "/")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    manifest = {"converter": CONVERTER_VERSION, "files": {n: _hash(d) for n, d in sorted(files.items())},
                "units": info}
    (tmp / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True), encoding="utf-8")
    shutil.rmtree(folder, ignore_errors=True)
    os.replace(tmp, folder)


def prune(build_dir, keep, stale_after=3600):
    """Drop finished caches other than `keep`, and work or .tmp folders a
    killed launcher left behind (untouched for `stale_after` seconds). Those
    of a launcher converting at the same time (models-work-<pid>,
    ...tmp<pid>) are left alone: deleting them made that run fail."""
    finished = re.compile(re.escape(CACHE_PREFIX) + r"\d+-[0-9a-f]{16}")
    for d in build_dir.glob(CACHE_PREFIX + "*"):
        if not d.is_dir() or d.name == keep:
            continue
        try:
            stale = time.time() - d.stat().st_mtime > stale_after
        except OSError:
            continue
        if finished.fullmatch(d.name) or stale:
            shutil.rmtree(d, ignore_errors=True)


def model_files(keys):
    """Map paths of the MDX files `keys` need: models and portrait models."""
    return ({f"{MAP_DIR}{k}.mdx" for k in keys}
            | {portrait_path(k) for k in keys if units.resolve(k).get("portrait")})


def swap_textures(key, other, files, glb_root, log):
    """Textures of `other`, a copy of `key`'s model whose units.py entry
    swaps some ("textures": {stem: (Dota .vtex path, glTF alpha mode)}):
    converted like the ones they replace (size, encoding) into files.
    Returns {old map path: new map path}."""
    out = {}
    for stem, (vtex, alpha_mode) in sorted(units.UNITS[other].get("textures", {}).items()):
        png = Path(glb_root) / vrf.output_path(units.compiled(vtex))
        if not png.is_file():
            log(f"model {other}: texture {vtex} was not exported, keeps {key}'s")
            continue
        for prefix in (key, f"{key}_portrait"):
            old = f"{MAP_DIR}{prefix}_{stem}.blp"
            if old in files:
                compression, width, height = blp_info(files[old])
                new = f"{MAP_DIR}{other}{prefix[len(key):]}_{texture_stem(png)}.blp"
                files[new] = textures.convert(png, alpha_mode, limit=max(width, height),
                                              encoding="palette" if compression == 1 else "jpeg")
                out[old] = new
    return out


def prepare(vpk, vrf_exe, build_dir, keys, log, threads=4):
    """Map files ({map path: bytes}) of every unit model in `keys`, from the
    cache of this Dota build when it is complete. Raises ModelError."""
    if not keys:
        return {}
    # VRF runs in a scratch working directory: give it absolute paths.
    vpk, vrf_exe, build_dir = Path(vpk).resolve(), Path(vrf_exe).resolve(), Path(build_dir).resolve()
    digest = inputs_digest(keys)
    folder = Path(build_dir) / f"{CACHE_PREFIX}{CONVERTER_VERSION}-{digest[:16]}"
    cached = read_cache(folder)
    expected = model_files(keys)
    if cached is not None:
        files, _manifest = cached
        if expected <= set(files):
            log(f"models: cache complete ({len(files)} files, {folder.name})")
            return files
    t0 = time.perf_counter()
    try:
        listing = vpkdir.read_tree(vpk, VPK_PREFIXES)
    except (OSError, vpkdir.VpkError) as e:
        raise ModelError(f"Dota 2 game data could not be read: {e}") from e
    groups = {}
    for key in keys:
        groups.setdefault(units.resolve(key)["model"], []).append(key)
    entries = plan(listing, [ks[0] for ks in groups.values()])
    for key, entry in entries.items():
        for item in entry["missing_items"]:
            log(f"model {key}: cosmetic {item} not in this Dota build, skipped")

    work = Path(build_dir) / f"models-work-{os.getpid()}"
    glb_root = work / "glb"
    shutil.rmtree(work, ignore_errors=True)
    try:
        mains = sorted({units.compiled(e["model"]) for e in entries.values()})
        aseq = dump_blocks(vrf_exe, vpk, mains, "ASEQ", work / "vrf", log)
        mdat = dump_blocks(vrf_exe, vpk, mains, "MDAT", work / "vrf", log)
        clips, attachments = {}, {}
        for key, entry in entries.items():
            path = units.compiled(entry["model"])
            try:
                sequences = parse_sequences(aseq[path][0]) if path in aseq else {}
                attachments[key] = parse_attachments(mdat.get(path, []))
            except (kv3.Kv3Error, KeyError, IndexError, TypeError) as e:
                raise ModelError(f"{key}: could not read the sequences or attachments of {path}: {e}") from e
            if entry["unit"]["anims"] and not sequences:
                raise ModelError(f"{key}: VRF listed no animations for {path}")
            clips[key], notes = select_clips(entry["unit"], sequences)
            for n in notes:
                log(f"model {key}: {n}")
        t1 = time.perf_counter()
        all_clips = {c for cs in clips.values() for c in cs.values() if c}
        paths = sorted({units.compiled(p) for e in entries.values() for p in [e["model"]] + e["items"]})
        swaps = sorted({units.compiled(vtex) for k in keys
                        for vtex, _mode in units.UNITS[k].get("textures", {}).values()})
        for p in swaps:
            if p not in listing:
                log(f"models: texture {p} not in this Dota build, the copy keeps its model's texture")
        export_glb(vrf_exe, vpk, paths + [p for p in swaps if p in listing], all_clips, glb_root, work / "vrf", log,
                   threads)
        t2 = time.perf_counter()
        log(f"models: VRF dumps {t1 - t0:.1f} s, glTF export of {len(paths)} models {t2 - t1:.1f} s")

        files, info = {}, {}
        for key, entry in entries.items():
            t = time.perf_counter()
            unit_files, unit_info = convert_unit(key, entry, glb_root, clips[key], attachments[key], log)
            files.update(unit_files)
            info[key] = unit_info
            log(f"model {key}: {unit_info['vertices']} vertices, {unit_info['bones']} bones, "
                f"{len(unit_info['sequences'])} sequences, {time.perf_counter() - t:.1f} s")
            for note in unit_info["notes"]:
                log(f"model {key}: {note}")
            for other in groups[entry["model"]][1:]:
                swap = swap_textures(key, other, files, glb_root, log)
                files[f"{MAP_DIR}{other}.mdx"] = retexture(rename_model(files[f"{MAP_DIR}{key}.mdx"], other), swap)
                if portrait_path(key) in files:
                    files[portrait_path(other)] = retexture(
                        rename_model(files[portrait_path(key)], f"{other}_portrait"), swap)
                info[other] = {"same_as": key}
        log(f"models: converted {len(keys)} units in {time.perf_counter() - t2:.1f} s "
            f"({sum(len(d) for d in files.values()) / 1048576:.1f} MB)")
    finally:
        shutil.rmtree(work, ignore_errors=True)
    missing = sorted(expected - set(files))
    if missing:
        raise ModelError(f"no model produced for {', '.join(missing)}")
    try:
        write_cache(folder, files, info)
    except OSError as e:
        raise ModelError(f"could not write the model cache {folder}: {e}") from e
    prune(Path(build_dir), folder.name)
    return files


def rename_model(mdx, name):
    """Copy of an MDX with another model name (MODL chunk name field)."""
    at = mdx.index(b"MODL") + 8
    raw = name.encode("ascii")[:79]
    return mdx[:at] + raw + b"\0" * (80 - len(raw)) + mdx[at + 80:]
