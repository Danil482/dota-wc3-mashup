"""Tests of the Dota -> MDX model converter (launcher/dvc_launcher/mdx, models.py).

Offline part (no Dota 2 needed): a small skinned glTF is generated, converted
and checked: coordinates, pivots, skinning groups, root-motion removal,
sequences, byte-identical output on repeat, BLP JPEG layout, KV3 parsing and
clip selection. Every MDX is read back with mdx-m3-viewer (tools/check_mdx.js)
when node is available.

With --dota, the real pipeline also runs on the local Dota 2 install: every
unit of specs/models.json is converted twice into a scratch cache (cold, then
from a fresh cold cache again) and must come out byte-identical, a third run
must hit the cache, and every MDX must pass check_mdx.js.

Usage: python launcher/tests/test_models.py [--dota "<Dota 2 root>"] [--work <scratch folder>]
Never starts Warcraft III, Dota 2 or Steam.
"""
import argparse
import io
import json
import shutil
import struct
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "launcher"))

from PIL import Image  # noqa: E402

from dvc_launcher import models  # noqa: E402
from dvc_launcher.mdx import convert, kv3, textures, units, writer  # noqa: E402

failures = []
K = 1.0 / 0.0254


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(name)


# ------------------------------------------------------------------ fixtures

def make_glb(folder):
    """Two-joint skinned triangle strip with two clips, as VRF would write it
    (Y up, metres): 'idle' bends the child joint, 'run' moves the root 1 m
    forward (+Z) per second (root motion)."""
    folder.mkdir(parents=True, exist_ok=True)
    Image.new("RGBA", (8, 4), (200, 40, 20, 255)).save(folder / "body_color_psd_1234abcd.png")
    blobs, views, accessors = [], [], []

    def add(fmt, values, comp, kind, count, extra=None):
        data = b"".join(struct.pack("<" + fmt, *v) if isinstance(v, tuple) else struct.pack("<" + fmt, v)
                        for v in values)
        offset = sum(len(b) for b in blobs)
        pad = (-len(data)) % 4
        blobs.append(data + b"\0" * pad)
        views.append({"buffer": 0, "byteOffset": offset, "byteLength": len(data)})
        acc = {"bufferView": len(views) - 1, "componentType": comp, "count": count, "type": kind}
        acc.update(extra or {})
        accessors.append(acc)
        return len(accessors) - 1

    pos = [(0.0, 0.0, 0.0), (0.5, 0.0, 0.0), (0.0, 1.0, 0.0), (0.5, 1.0, 0.0), (0.0, 2.0, 0.0)]
    a_pos = add("3f", pos, 5126, "VEC3", 5, {"min": [0, 0, 0], "max": [0.5, 2, 0]})
    a_nrm = add("3f", [(0.0, 0.0, 1.0)] * 5, 5126, "VEC3", 5)
    a_uv = add("2f", [(0, 0), (1, 0), (0, 0.5), (1, 0.5), (0, 1)], 5126, "VEC2", 5)
    a_jnt = add("4B", [(0, 0, 0, 0), (0, 0, 0, 0), (0, 1, 0, 0), (0, 1, 0, 0), (1, 0, 0, 0)], 5121, "VEC4", 5)
    a_wgt = add("4f", [(1, 0, 0, 0), (1, 0, 0, 0), (0.7, 0.3, 0, 0), (0.5, 0.5, 0, 0), (1, 0, 0, 0)], 5126, "VEC4", 5)
    a_idx = add("H", [0, 1, 2, 1, 3, 2, 2, 3, 4], 5123, "SCALAR", 9)
    ibm = [(1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1), (1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -1, 0, 1)]
    a_ibm = add("16f", ibm, 5126, "MAT4", 2)
    a_t = add("f", [0.0, 0.5, 1.0], 5126, "SCALAR", 3, {"min": [0], "max": [1]})
    # child rotation about Z: 0, 30 degrees, 0 (sin 15 = 0.258819, cos 15 = 0.965926)
    a_rot = add("4f", [(0, 0, 0, 1), (0, 0, 0.25881904510252074, 0.9659258262890683), (0, 0, 0, 1)],
                5126, "VEC4", 3)
    a_run = add("3f", [(0, 0, 0), (0, 0, 0.5), (0, 0, 1.0)], 5126, "VEC3", 3)
    gltf = {
        "asset": {"version": "2.0"},
        "scene": 0, "scenes": [{"nodes": [0, 3]}],
        "nodes": [{"name": "model", "children": [1]},
                  {"name": "root", "children": [2]},
                  {"name": "child", "translation": [0, 1, 0]},
                  {"name": "model.body", "mesh": 0, "skin": 0}],
        "skins": [{"joints": [1, 2], "inverseBindMatrices": a_ibm}],
        "meshes": [{"name": "model.body", "primitives": [{"attributes": {
            "POSITION": a_pos, "NORMAL": a_nrm, "TEXCOORD_0": a_uv, "JOINTS_0": a_jnt, "WEIGHTS_0": a_wgt},
            "indices": a_idx, "material": 0}]}],
        "materials": [{"name": "body", "alphaMode": "MASK", "pbrMetallicRoughness": {"baseColorTexture": {"index": 0}}}],
        "textures": [{"source": 0}], "images": [{"uri": "body_color_psd_1234abcd.png"}],
        "animations": [
            {"name": "idle", "samplers": [{"input": a_t, "output": a_rot}],
             "channels": [{"sampler": 0, "target": {"node": 2, "path": "rotation"}}]},
            {"name": "run", "samplers": [{"input": a_t, "output": a_run}],
             "channels": [{"sampler": 0, "target": {"node": 1, "path": "translation"}}]}],
        "accessors": accessors, "bufferViews": views,
    }
    binary = b"".join(blobs)
    gltf["buffers"] = [{"byteLength": len(binary)}]
    js = json.dumps(gltf).encode("utf-8")
    js += b" " * ((-len(js)) % 4)
    glb = struct.pack("<III", 0x46546C67, 2, 12 + 8 + len(js) + 8 + len(binary))
    glb += struct.pack("<II", len(js), 0x4E4F534A) + js + struct.pack("<II", len(binary), 0x004E4942) + binary
    path = folder / "model.glb"
    path.write_bytes(glb)
    return path


def read_back(files, work):
    """Run tools/check_mdx.js on {map path: bytes}; returns its JSON or None."""
    if shutil.which("node") is None:
        return None
    folder = work / "readback"
    shutil.rmtree(folder, ignore_errors=True)
    for name, data in files.items():
        p = folder / name.replace("\\", "/")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    mdx = sorted(str(p) for p in folder.rglob("*.mdx"))
    proc = subprocess.run(["node", str(ROOT / "tools" / "check_mdx.js")] + mdx, capture_output=True, text=True)
    try:
        return json.loads(proc.stdout)
    except ValueError:
        return {"node": {"ok": False, "problems": [proc.stderr[-500:]]}}


# ------------------------------------------------------------------ offline tests

def test_synthetic(work):
    glb = make_glb(work / "glb")
    unit = {"kind": units.HERO, "anims": {"Stand": "idle", "Walk": "run"}}
    attach = {"attach_hitloc": ("root", (0.0, 0.0, 0.0)), "attach_head": ("child", (0.0, 10.0, 0.0))}

    def build():
        files = {}
        conv = convert.Converter("hero_test", unit, glb, [], {"Stand": "idle", "Walk": "run"}, attach)
        model, info = conv.convert(models.texture_namer("hero_test", files))
        files["war3mapImported\\Dota\\hero_test.mdx"] = writer.write(model)
        return model, info, files

    model, info, files = build()
    _m2, _i2, files2 = build()
    check("synthetic: same input gives the same bytes", files == files2)
    b = {bone.name: bone for bone in model.bones}
    check("synthetic: both joints are bones", set(b) == {"root", "child"})
    check("synthetic: child pivot at 1 m up = (0, 0, 39.37)",
          max(abs(x - y) for x, y in zip(b["child"].pivot, (0.0, 0.0, K))) < 1e-4, str(b["child"].pivot))
    verts = sorted(v for g in model.geosets for v in g.vertices)
    check("synthetic: glTF (0.5, 0, 0) -> WC3 (0, 19.685, 0)",
          any(max(abs(x - y) for x, y in zip(v, (0.0, 0.5 * K, 0.0))) < 1e-4 for v in verts))
    groups = sorted({tuple(model.bones[i].name for i in grp) for g in model.geosets for grp in g.matrix_groups})
    check("synthetic: 0.7/0.3 and 0.5/0.5 weights become quarter groups",
          ("root", "root", "root", "child") in groups and ("root", "child") in groups, str(groups))
    seqs = {s.name: s for s in model.sequences}
    need = ["Stand", "Stand Ready", "Walk", "Attack", "Spell", "Spell Channel", "Death", "Birth",
            "Stand Victory", "Decay Flesh", "Decay Bone"]
    check("synthetic: every required sequence exists", all(n in seqs for n in need), str(sorted(seqs)))
    check("synthetic: Stand and Walk loop, Death does not",
          seqs["Stand"].looping and seqs["Walk"].looping and not seqs["Death"].looping)
    walk = seqs["Walk"]
    root_t = [k for t in b["root"].tracks if t.tag == "KGTR" for k in t.keys if walk.start <= k[0] <= walk.end]
    drift = max((abs(v[0]) for _f, v in root_t), default=0.0)
    check("synthetic: walk root motion removed (in place)", drift < 0.5, f"max drift {drift:.3f}")
    check("synthetic: walk move speed = 39.37 units/s", abs(walk.move_speed - K) < 0.1, f"{walk.move_speed:.2f}")
    child_r = [k for t in b["child"].tracks if t.tag == "KGRT" for k in t.keys
               if seqs["Stand"].start <= k[0] <= seqs["Stand"].end]
    # glTF rotation about +Z (forward) is a rotation about WC3 +X
    check("synthetic: Stand rotates the child joint about WC3 X",
          any(abs(v[0]) > 0.25 and abs(v[1]) < 1e-6 and abs(v[2]) < 1e-6 for _f, v in child_r), str(child_r[:3]))
    names = [a.name for a in model.attachments]
    check("synthetic: WC3 attachment points", all(n in names for n in ("Origin Ref", "Overhead Ref", "Head Ref",
                                                                        "Chest Ref")), str(names))
    tex = [n for n in files if n.endswith(".blp")]
    check("synthetic: texture named <key>_<stem>.blp", tex == ["war3mapImported\\Dota\\hero_test_body.blp"], str(tex))
    rb = read_back(files, work)
    if rb is None:
        print("[SKIP] mdx-m3-viewer read-back (node not found)")
    else:
        r = next(iter(rb.values()))
        check("synthetic: mdx-m3-viewer reads it back byte for byte", r["ok"], "; ".join(r["problems"][:3]))


def test_errors(work):
    try:
        models.plan({}, ["hero_pudge"])
        ok = False
    except models.ModelError as e:
        ok = "pudge.vmdl is not in your Dota 2 files" in str(e)
    check("errors: a missing Dota model stops the plan with a clear message", ok)
    bad = work / "models_bad.json"
    bad.write_text(json.dumps({"hero_nobody": {"model": models.MAP_DIR + "hero_nobody.mdx"}}), encoding="utf-8")
    try:
        models.load_keys(bad)
        ok = False
    except models.ModelError:
        ok = True
    check("errors: models.json with an unknown unit is refused", ok)
    check("errors: no models.json means no models", models.load_keys(work / "absent.json") == [])


def test_units():
    check("units: every Dota clip table names only known sequences",
          all(set(u.get("anims", {})) <= set(units.SEQUENCE_NAMES) | set(units.STRUCTURE_SEQUENCES)
              for u in units.UNITS.values()))
    data = json.loads((ROOT / "specs" / "models.json").read_text(encoding="utf-8"))
    check("models.json keys are all known units", set(data) <= set(units.UNITS), str(set(data) - set(units.UNITS)))
    check("models.json map paths follow war3mapImported\\Dota\\<key>.mdx",
          all(v["model"] == f"war3mapImported\\Dota\\{k}.mdx" for k, v in data.items()))
    check("models.json scales match the unit table",
          all(abs(v["scale"] - units.resolve(k)["scale"]) < 1e-9 for k, v in data.items()))


def test_quantize():
    q = convert._quantize
    check("quantize: single bone", q([(5, 1.0)]) == (5,))
    check("quantize: 0.7/0.3 -> 3:1", q([(1, 0.7), (2, 0.3)]) == (1, 1, 1, 2))
    check("quantize: 0.5/0.5 -> 1:1", q([(1, 0.5), (2, 0.5)]) == (1, 2))
    check("quantize: four equal -> four bones", q([(1, 0.25), (2, 0.25), (3, 0.25), (4, 0.25)]) == (1, 2, 3, 4))
    check("quantize: tiny weight dropped", q([(1, 0.95), (2, 0.05)]) == (1,))


def test_blp():
    img = Image.new("RGBA", (16, 8), (255, 0, 0, 255))
    data = textures.encode_jpeg(textures.mip_levels(img, False), False)
    magic, content, alpha, w, h, extra, mips = struct.unpack_from("<4sIIIIII", data)
    offsets = struct.unpack_from("<16I", data, 28)
    sizes = struct.unpack_from("<16I", data, 92)
    hsize = struct.unpack_from("<I", data, 156)[0]
    levels = sum(1 for s in sizes if s)
    check("BLP: BLP1 JPEG header", (magic, content, w, h, extra, mips) == (b"BLP1", 0, 16, 8, 5, 1))
    check("BLP: full mip chain to 1x1", levels == 5, str(levels))
    check("BLP: shared JPEG header <= 624 bytes", 0 < hsize <= 624, str(hsize))
    jpeg = data[160:160 + hsize] + data[offsets[0]:offsets[0] + sizes[0]]
    decoded = Image.open(io.BytesIO(jpeg))
    decoded.load()
    # Pillow reads 4-channel JPEGs as inverted CMYK; undo it to see the stored samples.
    stored = [255 - v for v in decoded.getpixel((4, 4))]
    check("BLP: samples are stored as B, G, R, A", stored[0] < 20 and stored[1] < 20 and stored[2] > 235
          and stored[3] > 235, str(stored))
    check("BLP: no Adobe APP14 segment", b"Adobe" not in jpeg)


def test_kv3_and_clips():
    text = '''<!-- kv3 encoding:text:version{e21c7f3c-8a33-41c5-9977-a76d3a32aa0d} format:generic:version{x} -->
{
	m_localS1SeqDescArray =
	[
		{ m_sName = "idle_a" m_flags = { m_bLooping = true } m_activityArray = [ { m_name = "ACT_DOTA_IDLE" m_nWeight = 1 }, ] },
		{ m_sName = "idle_rare" m_flags = { m_bLooping = true } m_activityArray = [ { m_name = "ACT_DOTA_IDLE_RARE" m_nWeight = 1 }, ] },
		{ m_sName = "run_haste" m_flags = { m_bLooping = true } m_activityArray = [ { m_name = "ACT_DOTA_RUN" m_nWeight = 1 }, { m_name = "haste" m_nWeight = 1 }, ] },
		{ m_sName = "run2" m_flags = { m_bLooping = true } m_activityArray = [ { m_name = "ACT_DOTA_RUN" m_nWeight = 1 }, ] },
		{ m_sName = "hit" m_flags = { m_bLooping = false } m_activityArray = [ { m_name = "ACT_DOTA_ATTACK" m_nWeight = 2 }, ] },
		{ m_sName = "hit2" m_flags = { m_bLooping = false } m_activityArray = [ { m_name = "ACT_DOTA_ATTACK" m_nWeight = 1 }, ] },
		{ m_sName = "cast_q" m_flags = { m_bLooping = false } m_activityArray = [ { m_name = "ACT_DOTA_CAST_ABILITY_2" m_nWeight = 1 }, ] },
	]
	m_attachments = [ { key = "attach_hitloc" value = { m_name = "attach_hitloc" m_influenceNames = [ "spine", "", "" ]
		m_vInfluenceOffsets = [ [ 1.0, 2.0, -3.5 ], [ 0.0, 0.0, 0.0 ], [ 0.0, 0.0, 0.0 ] ] m_nInfluences = 1 } } ]
}'''
    seqs = models.parse_sequences(text)
    check("kv3: sequences parsed", sorted(seqs) == ["cast_q", "hit", "hit2", "idle_a", "idle_rare", "run2",
                                                    "run_haste"], str(sorted(seqs)))
    att = models.parse_attachments([text])
    check("kv3: attachments parsed", att == {"attach_hitloc": ("spine", (1.0, 2.0, -3.5))}, str(att))
    unit = {"kind": units.HERO, "anims": {"Stand": "idle_a", "Walk": "renamed_run", "Attack": "hit"}}
    chosen, notes = models.select_clips(unit, seqs)
    check("clips: table entry used", chosen["Stand"] == "idle_a")
    check("clips: missing table clip falls back by activity, skipping modifier variants",
          chosen["Walk"] == "run2", str(chosen["Walk"]))
    check("clips: Attack - 2 differs from Attack", chosen["Attack - 2"] == "hit2", str(chosen["Attack - 2"]))
    check("clips: Spell by activity", chosen["Spell"] == "cast_q")
    check("clips: Stand - 2 from ACT_DOTA_IDLE_RARE", chosen["Stand - 2"] == "idle_rare")
    check("clips: fallback noted", any("renamed_run" in n for n in notes), str(notes))
    check("kv3: split_dump", list(kv3.split_dump('[1/2] a/b.vmdl_c\n--- Data for block "ASEQ" ---\n{ x = 1 }\n')) ==
          ["a/b.vmdl_c"])


# ------------------------------------------------------------------ Dota integration

def test_dota(dota, work):
    from dvc_launcher import installs
    root = installs.dota_root(dota)
    vpk = installs.dota_vpk(root)
    vrf_exe = ROOT / "launcher" / "vendor" / "vrf" / "Source2Viewer-CLI.exe"
    keys = models.load_keys(ROOT / "specs" / "models.json")
    runs = []
    for n in range(2):
        cache = work / f"dota{n}"
        shutil.rmtree(cache, ignore_errors=True)
        cache.mkdir(parents=True)
        t = time.perf_counter()
        files = models.prepare(vpk, vrf_exe, cache, keys, lambda m: None)
        runs.append((files, time.perf_counter() - t))
    check("Dota: two cold conversions are byte-identical", runs[0][0] == runs[1][0],
          f"{len(runs[0][0])} files, {runs[0][1]:.1f} s / {runs[1][1]:.1f} s")
    t = time.perf_counter()
    warm = models.prepare(vpk, vrf_exe, work / "dota1", keys, lambda m: None)
    check("Dota: warm run reads the cache", warm == runs[1][0], f"{time.perf_counter() - t:.2f} s")
    files = runs[0][0]
    check("Dota: every models.json key has its .mdx",
          all(f"war3mapImported\\Dota\\{k}.mdx" in files for k in keys))
    rb = read_back(files, work)
    if rb is not None:
        bad = {Path(f).name: r["problems"][:2] for f, r in rb.items() if not r["ok"]}
        check("Dota: every MDX passes mdx-m3-viewer read-back", not bad, str(bad)[:300])
        missing = []
        for f, r in rb.items():
            for t in r["summary"]["textures"]:
                if t not in files:
                    missing.append(t)
        check("Dota: every texture an MDX names is produced", not missing, str(missing[:3]))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dota")
    ap.add_argument("--work")
    args = ap.parse_args()
    work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="dvc_models_"))
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    test_quantize()
    test_blp()
    test_kv3_and_clips()
    test_units()
    test_errors(work)
    test_synthetic(work)
    if args.dota:
        test_dota(args.dota, work)
    print(f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
