"""Tests of the Dota particle -> MDX effect converter (launcher/dvw_launcher/
effects.py, mdx/particles.py, mdx/fxtextures.py).

Offline part (no Dota 2 needed): specs/effects.json against the hero files
and tools/gen_objects.py, a synthetic projectile tree (phases, bursts, model
space, control point remaps), sheet textures, the data.effects patch of
war3map.lua and the fallback missile. Every MDX is read back with
mdx-m3-viewer (tools/check_mdx.js) when node is available.

With --dota, every effect of specs/effects.json is converted twice into
scratch caches (cold both times) and must come out byte-identical, a third
run must hit the cache, every missile must be a converted model (not the
glow), every MDX must pass check_mdx.js, and the total must stay under 5 MB.

Usage: python launcher/tests/test_effects.py [--dota "<Dota 2 root>"] [--work <scratch folder>]
Never starts Warcraft III, Dota 2 or Steam.
"""
import argparse
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "launcher"))

from PIL import Image  # noqa: E402

from dvw_launcher import effects  # noqa: E402
from dvw_launcher.mdx import fxtextures, particles  # noqa: E402

failures = []
BUDGET = 5 * 1048576


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(name)


def check_mdx(folder, names):
    """mdx-m3-viewer's verdict on the MDX files (textures next to them), or None without node."""
    node = shutil.which("node")
    if not node or not names:
        return None
    out = subprocess.run([node, str(ROOT / "tools" / "check_mdx.js")] + [str(folder / n) for n in names],
                         capture_output=True, text=True, timeout=600)
    try:
        report = json.loads(out.stdout)
    except ValueError:
        return {"(check_mdx)": {"ok": False, "problems": [out.stdout[-300:] + out.stderr[-300:]]}}
    return report


def write_tree(folder, files):
    folder.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (folder / name.rsplit("\\", 1)[-1]).write_bytes(data)
    return [n.rsplit("\\", 1)[-1] for n in files if n.endswith(".mdx")]


# ------------------------------------------------------------------ spec

def test_spec():
    spec = effects.load_spec(ROOT / "specs" / "effects.json")
    missiles = {k: e for k, e in spec.items() if e["section"] == "missiles"}
    spells = {k: e for k, e in spec.items() if e["section"] == "effects"}
    check("spec lists missiles and spell effects", len(missiles) >= 11 and len(spells) >= 11,
          f"{len(missiles)} missiles, {len(spells)} effects")
    check("every missile names its units", all(e.get("units") for e in missiles.values()))
    check("every spell effect names a WC3 fallback", all(e.get("fallback", "").endswith(".mdl")
                                                         for e in spells.values()))
    used = set()
    for lua in (ROOT / "src" / "heroes").glob("*.lua"):
        used |= set(re.findall(r'Fx\.model\("([a-z0-9_]+)"', lua.read_text(encoding="utf-8")))
    check("every Fx.model key in src/heroes is in the spec", used <= set(spells), sorted(used - set(spells)))
    check("every spell effect is used by a hero file", set(spells) <= used, sorted(set(spells) - used))
    sys.path.insert(0, str(ROOT / "tools"))
    import gen_objects  # noqa: E402
    table = gen_objects.load_missiles()
    check("gen_objects maps every missile unit", all(table.get(u) == effects.model_path(k)
                                                    for k, e in missiles.items() for u in e["units"]),
          f"{len(table)} units")
    data = json.loads((ROOT / "src" / "data" / "effects.json").read_text(encoding="utf-8"))
    check("the base map's data.effects is empty (WC3 fallbacks)", data == {})
    bad = ("x" * 3, {"source": "a.vpcf", "usage": "sideways"})
    try:
        tmp = Path(tempfile.mkdtemp(prefix="dvw_fxspec_")) / "e.json"
        tmp.write_text(json.dumps({"effects": {"ok_key": bad[1]}}), encoding="utf-8")
        effects.load_spec(tmp)
        check("a bad usage is refused", False)
    except ValueError:
        check("a bad usage is refused", True)


# ------------------------------------------------------------------ synthetic tree

def sprite(texture, **extra):
    r = {"_class": "C_OP_RenderSprites", "m_vecTexturesInput": [{"m_hTexture": texture}],
         "m_nOutputBlendMode": "PARTICLE_OUTPUT_BLEND_MODE_ADD"}
    r.update(extra)
    return r


def synthetic_tree():
    root = "particles/test/proj.vpcf_c"
    return root, {
        root: {"_class": "CParticleSystemDefinition", "m_nMaxParticles": 4, "m_ConstantColor": [100, 200, 50, 255],
               "m_Renderers": [{"_class": "C_OP_RenderTrails", "m_flMaxLength": 48.0, "m_flRadiusScale": 0.5,
                                "m_flOverbrightFactor": 6.0, "m_flAddSelfAmount": 2.0,
                                "m_vecTexturesInput": [{"m_hTexture": "materials/particle/spark.vtex"}]}],
               "m_Emitters": [{"_class": "C_OP_InstantaneousEmitter", "m_nParticlesToEmit": 1}],
               "m_Initializers": [{"_class": "C_INIT_InitFloat", "m_InputValue": 32.0}],
               "m_Operators": [{"_class": "C_OP_BasicMovement"},
                               {"_class": "C_OP_Decay", "m_nOpEndCapState": "PARTICLE_ENDCAP_ENDCAP_ON"}],
               "m_Children": [{"m_ChildRef": "particles/test/proj_hit.vpcf", "m_bEndCap": True},
                              {"m_ChildRef": "particles/test/proj_launch.vpcf"},
                              {"m_ChildRef": "particles/test/proj_trail.vpcf"},
                              {"m_ChildRef": "particles/test/proj_trail.vpcf"},
                              {"m_ChildRef": "particles/test/proj_ring.vpcf"},
                              {"m_ChildRef": "particles/test/proj_missing.vpcf"}]},
        "particles/test/proj_hit.vpcf_c": {
            "m_Renderers": [sprite("materials/particle/glow.vtex")],
            "m_Emitters": [{"_class": "C_OP_InstantaneousEmitter", "m_nParticlesToEmit": 30}],
            "m_Initializers": [{"_class": "C_INIT_InitFloat", "m_nOutputField": 1, "m_InputValue": 0.5},
                               {"_class": "C_INIT_CreateWithinSphere", "m_nControlPointNumber": 3,
                                "m_fSpeedMin": 100.0, "m_fSpeedMax": 200.0}],
            "m_Operators": [{"_class": "C_OP_Decay"}, {"_class": "C_OP_FadeOutSimple"},
                            {"_class": "C_OP_InterpolateRadius", "m_flStartScale": 2.0, "m_flEndScale": 0.0}]},
        "particles/test/proj_launch.vpcf_c": {
            "m_Renderers": [sprite("materials/particle/glow.vtex")],
            "m_Emitters": [{"_class": "C_OP_InstantaneousEmitter", "m_nParticlesToEmit": 8}],
            "m_Initializers": [{"_class": "C_INIT_CreateWithinSphere", "m_nControlPointNumber": 9}],
            "m_Operators": [{"_class": "C_OP_Decay"},
                            {"_class": "C_OP_PositionLock", "m_nControlPointNumber": 9}]},
        "particles/test/proj_trail.vpcf_c": {
            "m_Renderers": [{"_class": "C_OP_RenderRopes", "m_vecTexturesInput": [{"m_hTexture": "materials/particle/beam.vtex"}]}],
            "m_Emitters": [{"_class": "C_OP_ContinuousEmitter", "m_flEmitRate": 16.0}],
            "m_Initializers": [{"_class": "C_INIT_CreateWithinSphere", "m_nControlPointNumber": 3}],
            "m_Operators": [{"_class": "C_OP_Decay"}]},
        "particles/test/proj_ring.vpcf_c": {
            "m_Renderers": [sprite("materials/particle/glow.vtex",
                                   m_nOrientationType="PARTICLE_ORIENTATION_WORLD_Z_ALIGNED")],
            "m_Emitters": [{"_class": "C_OP_InstantaneousEmitter", "m_nParticlesToEmit": 1}],
            "m_Initializers": [{"_class": "C_INIT_InitFloat", "m_InputValue": {
                "m_nType": "PF_TYPE_CONTROL_POINT_COMPONENT", "m_nControlPoint": 1, "m_nVectorComponent": 0,
                "m_nMapType": "PF_MAP_TYPE_REMAP", "m_flInput0": 0.0, "m_flInput1": 1000.0,
                "m_flOutput0": 0.0, "m_flOutput1": 500.0}}],
            "m_Operators": [{"_class": "C_OP_Decay"}]},
    }


def test_synthetic(work):
    root, tree = synthetic_tree()
    logs = []
    nodes = particles.walk(tree, root, "missile", logs.append, cps={"1": [400, 0, 0]})
    names = [n.spec.path.rsplit("/", 1)[-1] for n in nodes]
    check("walk keeps every drawing system once", names == ["proj.vpcf_c", "proj_hit.vpcf_c", "proj_launch.vpcf_c",
                                                           "proj_trail.vpcf_c", "proj_ring.vpcf_c"], names)
    check("a missing child is logged", any("proj_missing" in line for line in logs))
    phases = {n.spec.path.rsplit("/", 1)[-1]: n.phase for n in nodes}
    check("phases: endcap -> death, CP9 burst -> birth", phases["proj_hit.vpcf_c"] == "death"
          and phases["proj_launch.vpcf_c"] == "birth" and phases["proj.vpcf_c"] == "stand", phases)
    trail = next(n for n in nodes if "trail" in n.spec.path)
    check("a child listed twice emits twice as much", trail.spec.rate == 32.0, trail.spec.rate)
    ring = next(n for n in nodes if "ring" in n.spec.path)
    check("control point remaps use the spec's values", abs(ring.spec.radius[0] - 200.0) < 1e-6, ring.spec.radius)
    check("world-Z sprites become XY quads", ring.spec.xy_quad)
    head = nodes[0].spec
    check("overbright keeps the hue", abs(head.colors[0][1] - 1.0) < 1e-6 and head.colors[0][0] < 0.9, head.colors[0])
    check("the projectile particle is sustained", head.sustained and head.kind == "trail")
    textures = {(n.spec.texture, n.spec.sequence, n.spec.kind in ("trail", "rope")): (i, 1, 1, 1)
                for i, n in enumerate(nodes)}
    emitters, layout = particles.build_emitters(nodes, "missile", textures)
    seqs = [s[0] for s in layout.seqs]
    check("missile sequences", seqs == ["Stand", "Birth", "Death"], seqs)
    by = {e.name.split("_", 1)[1]: e for e in emitters}
    check("the projectile streak is a model-space tail", by["proj"].flags & particles.F_MODEL_SPACE
          and by["proj"].head_or_tail == 1)
    check("the launch flash stays in world space", not by["proj_launch"].flags & particles.F_MODEL_SPACE)
    hit = by["proj_hit"]
    death = layout.interval("Death")
    bursts = [(t, v) for tag, keys, _ in hit.tracks if tag == "KP2E" for t, v in keys if v]
    check("the impact burst is a squirt in Death, halved for the High setting",
          hit.squirt == 1 and bursts and all(death[0] <= t < death[1] for t, _ in bursts) and bursts[0][1] == 15.0,
          bursts)
    check("ropes become ribbons", any(e.kind == "ribbon" for e in emitters))
    data = particles.write("proj", emitters, layout, ["war3mapImported\\Dota\\fx\\t0.blp"] * len(nodes))
    again = particles.write("proj", particles.build_emitters(
        particles.walk(tree, root, "missile", cps={"1": [400, 0, 0]}), "missile", textures)[0], layout,
        ["war3mapImported\\Dota\\fx\\t0.blp"] * len(nodes))
    check("byte-identical on repeat", data == again)
    for usage, expect in (("oneshot", ["Stand", "Death"]), ("attached", ["Stand", "Birth", "Death"])):
        n2 = particles.walk(tree, root, usage)
        _e, lay = particles.build_emitters(n2, usage, textures)
        check(f"{usage} sequences", [s[0] for s in lay.seqs] == expect, [s[0] for s in lay.seqs])
    folder = work / "synthetic"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "proj.mdx").write_bytes(data)
    (folder / "t0.blp").write_bytes(fxtextures.glow((200, 255, 120)))
    (folder / "glow_missile.mdx").write_bytes(effects.fallback_model("glow_missile"))
    (folder / "dvw_glow.blp").write_bytes(fxtextures.glow(effects.FALLBACK_COLOR))
    report = check_mdx(folder, ["proj.mdx", "glow_missile.mdx"])
    if report is not None:
        bad = {k: v.get("problems") for k, v in report.items() if not v.get("ok")}
        check("check_mdx.js reads the synthetic and fallback models back", not bad, bad)


def test_textures(work):
    mks = "packmode rgb+a\n\nsequence-a 0\nLOOP\nframe a_seq0_0.png 1\nframe a_seq0_1.png 1\n\nsequence-rgb 0\nframe x.png 1\n" \
          "\nsequence 1\nframe a_seq1.png 1\n"
    sheet = fxtextures.parse_mks(mks)
    check("mks: alpha and rgb halves of one sequence count once", sheet == {0: ["a_seq0_0.png", "a_seq0_1.png"],
                                                                         1: ["a_seq1.png"]}, sheet)
    folder = work / "tex" / "materials" / "particle"
    folder.mkdir(parents=True, exist_ok=True)
    (folder / "a.mks").write_text(mks, encoding="utf-8")
    for i, size in enumerate([(30, 50), (40, 40), (20, 60)]):
        name = ["a_seq0_0.png", "a_seq0_1.png", "a_seq1.png"][i]
        Image.new("RGBA", size, (0, 0, 0, 200)).save(folder / name)
    Image.new("RGBA", (100, 60), (255, 128, 0, 255)).save(folder / "plain.png")
    src = fxtextures.source(work / "tex", "materials/particle/a.vtex_c", 0)
    check("sheet frames of sequence 0", [p.name for p in src] == ["a_seq0_0.png", "a_seq0_1.png"])
    data, rows, cols, n = fxtextures.convert(src)
    check("frames repack into a power-of-two grid", (rows, cols, n) == (1, 2, 2) and data[:4] == b"BLP1",
          (rows, cols, n))
    data, rows, cols, n = fxtextures.convert(fxtextures.source(work / "tex", "materials/particle/a.vtex_c", 1))
    w, h = int.from_bytes(data[12:16], "little"), int.from_bytes(data[16:20], "little")
    check("a one-frame sequence is a square texture", (rows, cols, n) == (1, 1, 1) and w == h, (w, h))
    from dvw_launcher import blp
    level = blp.decode(data)
    px = level.getpixel((w // 2, h // 2))
    check("an alpha-only frame turns white", px[0] > 200 and px[3] > 150, px)
    plain = fxtextures.source(work / "tex", "materials/particle/plain.vtex_c", 0)
    data, *_ = fxtextures.convert(plain, stretched=True)
    level = blp.decode(data)
    check("stretched textures turn a quarter and fade at the ends",
          level.size[1] >= level.size[0] and level.getpixel((0, 0))[3] < 40, level.size)


def test_lua():
    script = ("a = 1\n-- @dvw-data-begin data.effects\ndefine(\"data.effects\", function()\n    return {\n\n    }\n"
              "end)\n-- @dvw-data-end data.effects\nb = 2\n")
    files = {effects.model_path("pudge_rot"): b"x", effects.model_path("attack_tinker"): b"y"}
    spec = {"pudge_rot": {"section": "effects"}, "nevermore_requiem": {"section": "effects"},
            "attack_tinker": {"section": "missiles"}}
    table = effects.converted(spec, files)
    check("data.effects lists only converted spell effects", table == {"pudge_rot": effects.model_path("pudge_rot")})
    out = effects.patch_lua(script, table)
    check("the block is replaced, markers kept", out is not None and out.startswith("a = 1\n")
          and out.endswith("b = 2\n") and 'pudge_rot = "war3mapImported\\\\Dota\\\\fx\\\\pudge_rot.mdx"' in out
          and out.count("@dvw-data-begin data.effects") == 1, out)
    check("patching again gives the same script", effects.patch_lua(out, table) == out)
    check("a script without the block is left alone", effects.patch_lua("a = 1\n", table) is None)


# ------------------------------------------------------------------ with Dota 2

def test_dota(dota, work):
    from dvw_launcher import installs
    vpk = installs.dota_vpk(installs.dota_root(dota))
    vrf_exe = ROOT / "launcher" / "vendor" / "vrf" / "Source2Viewer-CLI.exe"
    spec = effects.load_spec(ROOT / "specs" / "effects.json")
    logs = []
    first = effects.prepare(vpk, vrf_exe, work / "cache1", spec, logs.append)
    second = effects.prepare(vpk, vrf_exe, work / "cache2", spec, logs.append)
    check("two cold runs give the same bytes", first == second, f"{len(first)} files")
    logs.clear()
    third = effects.prepare(vpk, vrf_exe, work / "cache1", spec, logs.append)
    check("a third run hits the cache", third == first and any("cache complete" in line for line in logs))
    glows = [k for k, e in spec.items() if e["section"] == "missiles"
             and b"Glow" in first[effects.model_path(k)][:4000] and len(first[effects.model_path(k)]) < 2000]
    check("every missile converted (no plain glow)", not glows, glows)
    spells = [k for k, e in spec.items() if e["section"] == "effects" and effects.model_path(k) not in first]
    check("every spell effect converted", not spells, spells)
    size = sum(len(d) for d in first.values())
    check("all effects under 5 MB", size < BUDGET, f"{size / 1048576:.2f} MB")
    folder = work / "fx"
    names = write_tree(folder, first)
    report = check_mdx(folder, names)
    if report is not None:
        bad = {k: v.get("problems")[:2] for k, v in report.items() if not v.get("ok")}
        check(f"check_mdx.js accepts all {len(names)} effect models", not bad, bad)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dota")
    ap.add_argument("--work")
    args = ap.parse_args()
    work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="dvw_effects_"))
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    test_spec()
    test_synthetic(work)
    test_textures(work)
    test_lua()
    if args.dota:
        test_dota(args.dota, work)
    print(f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
