"""Dota's trees on the personalized map.

Every tree stays a Warcraft III tree destructable: pathing, vision, the
Warcraft player's harvesting and the tree abilities (Tango, Quelling Blade,
Sprout, Force of Nature, Blast Off) all rely on that. Only the models change:
war3map.w3b (object data) points three standard tree types at Dota's own tree
models, converted from the player's game/dota/pak01_dir.vpk to MDX 800, the
format both graphics modes draw.

  LTlt  Summer Tree Wall  Dota trees in their default material (pines, oaks,
                          bamboo). Sprout (src/heroes/furion.lua) creates
                          this type with any of its 10 variations.
  FTtw  Fall Tree Wall    oaks in their other material groups (autumn
                          leaves, white, pink and red blossoms)
  BTtw  Barrens Tree Wall the Dire's dead trees

A variation is one Dota (model, skin) pair, the skin being the entity's
material group. Each type takes up to 10, the most common first; rarer kinds
borrow the nearest variation (same skin, else same model). Map files:
  war3mapImported\\DotaTrees\\<type><variation>.mdx
  war3mapImported\\DotaTrees\\<texture>.blp
  war3map.w3b, merged into the base map's when it has one.

A model holds the tree and Dota's own stump mesh on two bones, and the
sequences Stand, Stand Hit (a shake), Death (it falls; only the stump stays)
and Birth (it grows back over the stump). Bone scales hide whichever part is
not shown. Everything is deterministic (no trigonometry at run time), so
players with the same Dota build get byte-identical maps.
"""
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import time
from collections import Counter
from pathlib import Path

from PIL import Image

from .. import vpkdir, vrf
from ..mdx import gltf, kv3, textures, writer
from ..mdx.mathutil import mat_apply, mat_apply_dir, mat_mul, normalize

TYPES = ("LTlt", "FTtw", "BTtw")
SLOTS = 10
MAP_DIR = "war3mapImported\\DotaTrees\\"
CACHE_PREFIX = "trees-"
# Bump on any change that alters the produced bytes (models, textures, w3b).
TREES_VERSION = 1
TEXTURE_LIMIT = 512
VPK_PREFIXES = ("models/props_tree/", "materials/models/props_tree/")
METRES = 1.0 / 0.0254                 # VRF's glTF is in metres, Y up
SKIP_MESH = re.compile(r"inspector|hitbox|physics|nodraw", re.IGNORECASE)
# Minimap dot colour of every replaced type (Dota's minimap draws trees dark green).
MINIMAP_RGB = (24, 64, 24)
HIDDEN = (0.001, 0.001, 0.001)        # bone scale that hides a part
SHOWN = (1.0, 1.0, 1.0)
# Rotations as constants (unit quaternions x, y, z, w), so no sin/cos runs here.
FALLEN = (0.0, 0.6755902076156602, 0.0, 0.7372773368101241)       # 85 degrees about y
SHAKE_A = (0.026176948307873153, 0.0, 0.0, 0.9996573249755573)    # 3 degrees about x
SHAKE_B = (-0.01745240643728351, 0.0, 0.0, 0.9998476951563913)    # -2 degrees about x
UPRIGHT = (0.0, 0.0, 0.0, 1.0)
# Sequence timeline (ms): Stand, Stand Hit, Death, Birth.
SEQUENCES = (("Stand", 0, 1000, True), ("Stand Hit", 1100, 1400, False), ("Death", 1500, 3000, False),
             ("Birth", 3100, 5100, False))


class TreeError(Exception):
    pass


# ------------------------------------------------------------------ plan

def family(model, skin):
    """The WC3 tree type a Dota (model, skin) belongs to."""
    if model.rsplit("/", 1)[-1].startswith("dire_"):
        return "BTtw"
    return "LTlt" if skin == "0" else "FTtw"


def plan_trees(desc):
    """{"types": {type: [[model, skin] per variation]}, "kinds": [[type,
    variation] per description tree kind]} for the map's trees. Types
    without trees are left out; LTlt always has SLOTS variations."""
    e = desc["entities"]
    kinds = [tuple(k) for k in e.get("tree_kinds", [])]
    counts = Counter(row[2] for row in e.get("trees", []) if len(row) > 2)
    order = sorted((k for k in range(len(kinds)) if kinds[k][0]), key=lambda k: (-counts[k], kinds[k]))
    slots = {tid: [] for tid in TYPES}
    for k in order:
        tid = family(*kinds[k])
        if len(slots[tid]) < SLOTS:
            slots[tid].append(k)
    if order and not slots["LTlt"]:
        slots["LTlt"].append(order[0])
    if slots["LTlt"]:
        base = list(slots["LTlt"])
        while len(slots["LTlt"]) < SLOTS:              # Sprout creates any of 10 variations
            slots["LTlt"].append(base[len(slots["LTlt"]) % len(base)])
    where = {}
    for tid in TYPES:
        for var, k in enumerate(slots[tid]):
            where.setdefault(k, (tid, var))
    out = []
    for k, (model, skin) in enumerate(kinds):
        if k in where:
            out.append(list(where[k]))
            continue
        tid = family(model, skin)
        pick = (next((where[s] for s in slots[tid] if kinds[s][1] == skin), None)
                or next((where[s] for t in TYPES for s in slots[t] if kinds[s][0] == model), None)
                or (where[slots[tid][0]] if slots[tid] else None)
                or (where[slots["LTlt"][0]] if slots["LTlt"] else None))
        out.append(list(pick) if pick else None)
    return {"types": {tid: [list(kinds[k]) for k in slots[tid]] for tid in TYPES if slots[tid]}, "kinds": out}


# Decorative trees on the map's raised border (convert.place_decor): two
# doodad types (Corn, Scorched Grain; the map uses neither) whose models
# become the tree models of a tree type, the same files.
DECOR = {"radiant": ("LPcr", "LTlt"), "dire": ("LPcw", "BTtw")}
DECOR_VISIBILITY = 450.0           # doodad visibility radius: big models must not pop at the screen edge


def decor_kinds(plan):
    """{side: (doodad id, variations)} for convert.place_decor."""
    return {side: (doodad, len(plan["types"][tid])) for side, (doodad, tid) in DECOR.items()
            if plan.get("types", {}).get(tid)}


def model_path(tid, variation):
    return f"{MAP_DIR}{tid}{variation}.mdx"


def expected_files(plan):
    return {model_path(tid, v) for tid, variations in plan["types"].items() for v in range(len(variations))}


# ------------------------------------------------------------------ object data (war3map.w3b)

def _mods(tid, count):
    """(field, type, value) of one replaced tree type. Types: 0 int, 2 unreal, 3 string."""
    return [("bfil", 3, MAP_DIR + tid), ("bvar", 0, count), ("bfxr", 2, -1.0),
            ("bmmr", 0, MINIMAP_RGB[0]), ("bmmg", 0, MINIMAP_RGB[1]), ("bmmb", 0, MINIMAP_RGB[2])]


def _read_value(data, pos, vtype):
    if vtype == 0:
        return struct.unpack_from("<i", data, pos)[0], pos + 4
    if vtype in (1, 2):
        return struct.unpack_from("<f", data, pos)[0], pos + 4
    end = data.index(b"\0", pos)
    return data[pos:end].decode("utf-8", "replace"), end + 1


def read_object_file(data):
    """war3map.w3b (version 1-3) -> (version, originals, customs), each
    [(base id, new id, [sets: (flag, [(field, type, value)])])]."""
    version = struct.unpack_from("<i", data, 0)[0]
    if version not in (1, 2, 3):
        raise TreeError(f"war3map.w3b version {version} is not supported")
    pos = 4
    tables = []
    for _table in range(2):
        count = struct.unpack_from("<i", data, pos)[0]
        pos += 4
        objects = []
        for _o in range(count):
            base, new = data[pos:pos + 4].decode("latin-1"), data[pos + 4:pos + 8].decode("latin-1")
            pos += 8
            sets = 1
            if version >= 3:
                sets = struct.unpack_from("<i", data, pos)[0]
                pos += 4
            groups = []
            for _s in range(sets):
                flag = 0
                if version >= 3:
                    flag = struct.unpack_from("<i", data, pos)[0]
                    pos += 4
                n = struct.unpack_from("<i", data, pos)[0]
                pos += 4
                mods = []
                for _m in range(n):
                    field = data[pos:pos + 4].decode("latin-1")
                    vtype = struct.unpack_from("<i", data, pos + 4)[0]
                    value, pos = _read_value(data, pos + 8, vtype)
                    pos += 4                                  # end marker
                    mods.append((field, vtype, value))
                groups.append((flag, mods))
            objects.append((base, new, groups))
        tables.append(objects)
    return version, tables[0], tables[1]


def _pack_value(vtype, value):
    if vtype == 0:
        return struct.pack("<i", int(value))
    if vtype in (1, 2):
        return struct.pack("<f", float(value))
    return str(value).encode("utf-8") + b"\0"


def write_object_file(version, originals, customs):
    out = bytearray(struct.pack("<i", version))
    for objects in (originals, customs):
        out += struct.pack("<i", len(objects))
        for base, new, groups in objects:
            out += base.encode("latin-1") + new.encode("latin-1")
            if version >= 3:
                out += struct.pack("<i", len(groups))
            for flag, mods in groups[:1] if version < 3 else groups:
                if version >= 3:
                    out += struct.pack("<i", flag)
                out += struct.pack("<i", len(mods))
                for field, vtype, value in mods:
                    out += field.encode("latin-1") + struct.pack("<i", vtype) + _pack_value(vtype, value)
                    out += b"\0\0\0\0"
    return bytes(out)


def object_file(plan, base=None):
    """war3map.w3b with the replaced tree types: the base map's file (if any)
    with these types' fields set, or a new version 2 file."""
    version, originals, customs = read_object_file(base) if base else (2, [], [])
    ours = {tid: _mods(tid, len(variations)) for tid, variations in sorted(plan["types"].items())}
    merged = []
    for b, n, groups in originals:
        if b in ours:
            fields = {m[0] for m in ours[b]}
            kept = [(flag, [m for m in mods if m[0] not in fields]) for flag, mods in groups]
            kept[0] = (kept[0][0], kept[0][1] + ours.pop(b))
            merged.append((b, n, kept))
        else:
            merged.append((b, n, groups))
    for tid, mods in ours.items():
        merged.append((tid, "\0\0\0\0", [(0, mods)]))
    return write_object_file(version, merged, customs)


def read_level_file(data):
    """war3map.w3d (doodads, version 1-3: modifications carry a variation and
    a data column) -> (version, originals, customs) as read_object_file, mods
    as (field, type, variation, column, value)."""
    version = struct.unpack_from("<i", data, 0)[0]
    if version not in (1, 2, 3):
        raise TreeError(f"war3map.w3d version {version} is not supported")
    pos = 4
    tables = []
    for _table in range(2):
        count = struct.unpack_from("<i", data, pos)[0]
        pos += 4
        objects = []
        for _o in range(count):
            base, new = data[pos:pos + 4].decode("latin-1"), data[pos + 4:pos + 8].decode("latin-1")
            pos += 8
            sets = 1
            if version >= 3:
                sets = struct.unpack_from("<i", data, pos)[0]
                pos += 4
            groups = []
            for _s in range(sets):
                flag = 0
                if version >= 3:
                    flag = struct.unpack_from("<i", data, pos)[0]
                    pos += 4
                n = struct.unpack_from("<i", data, pos)[0]
                pos += 4
                mods = []
                for _m in range(n):
                    field = data[pos:pos + 4].decode("latin-1")
                    vtype, level, column = struct.unpack_from("<iii", data, pos + 4)
                    value, pos = _read_value(data, pos + 16, vtype)
                    pos += 4
                    mods.append((field, vtype, level, column, value))
                groups.append((flag, mods))
            objects.append((base, new, groups))
        tables.append(objects)
    return version, tables[0], tables[1]


def write_level_file(version, originals, customs):
    out = bytearray(struct.pack("<i", version))
    for objects in (originals, customs):
        out += struct.pack("<i", len(objects))
        for base, new, groups in objects:
            out += base.encode("latin-1") + new.encode("latin-1")
            if version >= 3:
                out += struct.pack("<i", len(groups))
            for flag, mods in groups[:1] if version < 3 else groups:
                if version >= 3:
                    out += struct.pack("<i", flag)
                out += struct.pack("<i", len(mods))
                for field, vtype, level, column, value in mods:
                    out += field.encode("latin-1") + struct.pack("<iii", vtype, level, column)
                    out += _pack_value(vtype, value) + b"\0\0\0\0"
    return bytes(out)


def doodad_file(plan, base=None):
    """war3map.w3d with the decorative tree doodads (DECOR) pointed at the
    tree models: the base map's file (if any) with these fields set, or a new
    version 2 file. Fields: dfil model, dvar variations, dvis visibility
    radius, dfxr fixed rotation (none), dshd shadow (none: Dota trees cast no
    blob)."""
    version, originals, customs = read_level_file(base) if base else (2, [], [])
    ours = {}
    for doodad, variations in sorted(decor_kinds(plan).values()):
        tid = next(t for d, t in DECOR.values() if d == doodad)
        ours[doodad] = [("dfil", 3, 0, 0, MAP_DIR + tid), ("dvar", 0, 0, 0, variations),
                        ("dvis", 2, 0, 0, DECOR_VISIBILITY), ("dfxr", 2, 0, 0, -1.0), ("dshd", 0, 0, 0, 0)]
    merged = []
    for b, n, groups in originals:
        if b in ours:
            fields = {m[0] for m in ours[b]}
            kept = [(flag, [m for m in mods if m[0] not in fields]) for flag, mods in groups]
            kept[0] = (kept[0][0], kept[0][1] + ours.pop(b))
            merged.append((b, n, kept))
        else:
            merged.append((b, n, groups))
    for doodad, mods in ours.items():
        merged.append((doodad, "\0\0\0\0", [(0, mods)]))
    return write_level_file(version, merged, customs)


# ------------------------------------------------------------------ VRF

def _run_vrf(vrf_exe, args, work_dir, what):
    env = dict(os.environ)
    env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
    Path(work_dir).mkdir(parents=True, exist_ok=True)
    try:
        proc = subprocess.run([str(vrf_exe)] + args, cwd=str(work_dir), env=env, stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              creationflags=vrf.CREATE_NO_WINDOW, timeout=900)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise TreeError(f"VRF could not run ({what}): {e}") from e
    text = proc.stdout.decode("utf-8", "replace")
    if proc.returncode != 0:
        tail = "\n".join(text.splitlines()[-15:])
        raise TreeError(f"VRF failed ({what}), exit code {proc.returncode}:\n{tail}")
    return text


def _blocks(vrf_exe, vpk, paths, work_dir, what):
    """{vpk path: parsed DATA block} of compiled resources."""
    text = _run_vrf(vrf_exe, ["-i", str(vpk), "-b", "DATA", "-f", ",".join(sorted(paths))], work_dir, what)
    out = {}
    for path, blocks in kv3.split_dump(text).items():
        try:
            out[path] = kv3.loads(blocks[0])
        except (kv3.Kv3Error, IndexError) as e:
            raise TreeError(f"{path}: unreadable DATA block: {e}") from e
    return out


def _exported(folder, vtex):
    """The non-empty PNG VRF wrote for a texture, or None."""
    p = Path(folder) / vrf.output_path(vtex)
    try:
        return p if p.stat().st_size > 0 else None
    except OSError:
        return None


def _resource(value):
    """'materials/x.vmat' or 'materials/y.vtex' -> compiled VPK path."""
    value = str(value or "").strip().replace("\\", "/")
    return value + "_c" if value and not value.endswith("_c") else value


def material_groups(model_data):
    """{skin name: [compiled vmat paths]} of a model's DATA block."""
    out = {}
    for g in model_data.get("m_materialGroups") or []:
        name = str(g.get("m_name", ""))
        out[name] = [_resource(m) for m in g.get("m_materials") or []]
    return out


def material_info(mat_data):
    """Colour texture, tint mask, tints and alpha test of a material's DATA block."""
    tex = {str(p.get("m_name")): _resource(p.get("m_pValue")) for p in mat_data.get("m_textureParams") or []}
    vec = {str(p.get("m_name")): p.get("m_value") for p in mat_data.get("m_vectorParams") or []}
    ints = {str(p.get("m_name")): p.get("m_nValue") for p in mat_data.get("m_intParams") or []}

    def tint(name):
        v = vec.get(name)
        return tuple(float(c) for c in v[:3]) if isinstance(v, list) and len(v) >= 3 else (1.0, 1.0, 1.0)
    return {"color": tex.get("g_tColor"), "mask": tex.get("g_tTintMask") if ints.get("F_TINT_MASK") else None,
            "tint": tint("g_vColorTint"), "tint2": tint("g_vColorTint2"),
            "alpha_test": bool(ints.get("F_ALPHA_TEST")) or bool(ints.get("F_TRANSLUCENT"))}


# ------------------------------------------------------------------ textures

def texture_bytes(color_png, info, mask_png=None):
    """BLP1 (palette) of a tree material: the colour texture tinted where Dota
    tints it (g_vColorTint where the tint mask is set, g_vColorTint2 elsewhere)."""
    mode = "MASK" if info["alpha_test"] else "OPAQUE"
    tint, tint2 = info["tint"], info["tint2"]
    if mask_png is None or (tint == (1.0, 1.0, 1.0) and tint2 == (1.0, 1.0, 1.0)):
        return textures.convert(color_png, mode, limit=TEXTURE_LIMIT, encoding="palette")
    image = Image.open(color_png)
    image.load()
    image = image.convert("RGBA")
    mask = Image.open(mask_png)
    mask.load()
    mask = mask.convert("RGBA").getchannel("G").resize(image.size, Image.Resampling.BILINEAR)
    bands = []
    for n, band in enumerate(image.split()[:3]):
        hi = band.point(lambda v, f=tint[n]: min(255, int(v * f + 0.5)))
        lo = band.point(lambda v, f=tint2[n]: min(255, int(v * f + 0.5)))
        bands.append(Image.composite(hi, lo, mask))
    image = Image.merge("RGBA", bands + [image.getchannel("A")])
    # textures.convert reads a file: the tinted image goes through a scratch PNG beside the export.
    tmp = Path(color_png).with_name(Path(color_png).stem + "_dvw_tinted.png")
    try:
        image.save(tmp)
        return textures.convert(tmp, mode, limit=TEXTURE_LIMIT, encoding="palette")
    finally:
        try:
            tmp.unlink()
        except OSError:
            pass


def texture_name(color_vtex, info):
    stem = Path(color_vtex).name
    stem = re.sub(r"\.vtex_c$", "", stem)
    stem = re.sub(r"_(psd|tga|png|jpg|tif)_[0-9a-f]+$", "", stem, flags=re.IGNORECASE)
    stem = re.sub(r"_color$", "", stem)
    stem = re.sub(r"[^A-Za-z0-9_]", "_", stem)[:40] or "tree"
    if info["mask"] and (info["tint"] != (1.0, 1.0, 1.0) or info["tint2"] != (1.0, 1.0, 1.0)):
        digest = hashlib.sha256(json.dumps([info["tint"], info["tint2"]]).encode()).hexdigest()[:6]
        stem = f"{stem}_t{digest}"
    return f"{MAP_DIR}{stem}.blp"


# ------------------------------------------------------------------ models

def _wc3(p):
    return (p[2] * METRES, p[0] * METRES, p[1] * METRES)


def _wc3_dir(n):
    return (n[2], n[0], n[1])


def _blend(mats, influences):
    total = sum(w for _j, w in influences) or 1.0
    out = [0.0] * 12
    for j, w in influences:
        m = mats[j]
        f = w / total
        for k in range(12):
            out[k] += m[k] * f
    return tuple(out)


def mesh_parts(glb):
    """{"tree": [...], "stump": [...]}: (material index, [(pos, normal, uv)], faces)
    in WC3 space, the rest pose of every mesh (skinned meshes blended)."""
    world = glb.world_matrices()
    skins = glb.skins()
    parts = {"tree": [], "stump": []}
    for node, mesh, skin in glb.mesh_nodes():
        name = glb.json["meshes"][mesh].get("name", "")
        short = name.rsplit(".", 1)[-1]
        if SKIP_MESH.search(short):
            continue
        part = "stump" if "stump" in short.lower() else "tree"
        joint_mats = None
        if skin is not None:
            joints, ibm = skins[skin]
            joint_mats = [mat_mul(world[j], m) for j, m in zip(joints, ibm)]
        for prim in glb.primitives(mesh):
            pos, nrm, uv = prim["POSITION"], prim.get("NORMAL"), prim.get("TEXCOORD_0")
            js, ws = prim.get("JOINTS_0"), prim.get("WEIGHTS_0")
            verts = []
            for i, p in enumerate(pos):
                if joint_mats is not None and js and ws:
                    infl = [(j, w) for j, w in zip(js[i], ws[i]) if w > 0.0] or [(js[i][0], 1.0)]
                    m = _blend(joint_mats, infl)
                else:
                    m = world[node]
                n = nrm[i] if nrm else (0.0, 1.0, 0.0)
                verts.append((_wc3(mat_apply(m, p)), normalize(_wc3_dir(mat_apply_dir(m, n))),
                              tuple(uv[i]) if uv else (0.0, 0.0)))
            idx = prim["indices"]
            faces = []
            for t in range(0, len(idx) - 2, 3):
                a, b, c = idx[t], idx[t + 1], idx[t + 2]
                if a != b and b != c and a != c:
                    faces += [a, b, c]
            if faces:
                parts[part].append((prim["material"], verts, faces))
    return parts


def _box(points, box=None):
    mn, mx = box or ((1e30, 1e30, 1e30), (-1e30, -1e30, -1e30))
    for p in points:
        mn = (min(mn[0], p[0]), min(mn[1], p[1]), min(mn[2], p[2]))
        mx = (max(mx[0], p[0]), max(mx[1], p[1]), max(mx[2], p[2]))
    return mn, mx


def _geosets(material_id, bone, pieces, out):
    """Geosets of one material and bone, split below the classic limits."""
    g, remap = None, None
    for verts, faces in pieces:
        for t in range(0, len(faces), 3):
            tri = faces[t:t + 3]
            new = sum(1 for i in tri if (id(verts), i) not in remap) if g is not None else 3
            if g is None or len(g.vertices) + new > 7000 or len(g.faces) + 3 > 16200:
                g = writer.Geoset(material_id)
                g.matrix_groups = [(bone,)]
                remap = {}
                out.append(g)
            for i in tri:
                key = (id(verts), i)
                if key not in remap:
                    remap[key] = len(g.vertices)
                    p, n, uv = verts[i]
                    g.vertices.append(p)
                    g.normals.append(n)
                    g.uvs.append(uv)
                    g.vertex_groups.append(0)
                g.faces.append(remap[key])


def build_model(name, glb_path, texture_for):
    """writer.Model of one tree. texture_for(material index, glTF material)
    -> (map path of its BLP, alpha tested)."""
    glb = gltf.Glb(glb_path)
    parts = mesh_parts(glb)
    if not parts["tree"]:
        raise TreeError(f"{Path(glb_path).name}: no tree mesh")
    model = writer.Model(name)
    tex_index, mat_index = {}, {}
    geosets = []
    boxes = {}
    for bone, part in ((0, "tree"), (1, "stump")):
        by_mat = {}
        for mat, verts, faces in parts[part]:
            path, alpha = texture_for(mat, glb.material(mat))
            if path not in tex_index:
                tex_index[path] = len(model.textures)
                model.textures.append(writer.Texture(path))
            key = (tex_index[path], alpha)
            if key not in mat_index:
                mat_index[key] = len(model.materials)
                model.materials.append(writer.Material([writer.Layer(
                    key[0], writer.FILTER_TRANSPARENT if alpha else writer.FILTER_NONE, writer.SHADE_TWO_SIDED)]))
            by_mat.setdefault(mat_index[key], []).append((verts, faces))
            boxes[part] = _box((v[0] for v in verts), boxes.get(part))
        for mi in sorted(by_mat):
            _geosets(mi, bone, by_mat[mi], geosets)
    for g in geosets:
        g.extent = writer.Extent(*_box(g.vertices))
    model.geosets = geosets
    tree_box = boxes["tree"]
    # The fallen tree reaches out along x by its height: grow the box to hold it.
    height = tree_box[1][2] - tree_box[0][2]
    whole = _box([tree_box[0], tree_box[1], (tree_box[1][0] + height, tree_box[1][1], tree_box[1][2]),
                  (tree_box[0][0], tree_box[0][1], -200.0)] + (list(boxes["stump"]) if "stump" in boxes else []))
    extent = writer.Extent(*whole)
    model.extent = extent
    for seq_name, start, end, loop in SEQUENCES:
        model.sequences.append(writer.Sequence(seq_name, start, end, loop, 0.0, 0.0, extent))
    for g in geosets:
        g.sequence_extents = [extent] * len(model.sequences)
    tree = writer.Bone("Tree", -1, (0.0, 0.0, 0.0))
    tree.tracks = [
        writer.Track("KGTR", [(0, (0.0, 0.0, 0.0)), (1000, (0.0, 0.0, 0.0)), (1100, (0.0, 0.0, 0.0)),
                              (1400, (0.0, 0.0, 0.0)), (1500, (0.0, 0.0, 0.0)), (2400, (0.0, 0.0, 0.0)),
                              (3000, (0.0, 0.0, -200.0)), (3100, (0.0, 0.0, 0.0)), (5100, (0.0, 0.0, 0.0))]),
        writer.Track("KGRT", [(0, UPRIGHT), (1000, UPRIGHT), (1100, UPRIGHT), (1200, SHAKE_A), (1300, SHAKE_B),
                              (1400, UPRIGHT), (1500, UPRIGHT), (2400, FALLEN), (3000, FALLEN), (3100, UPRIGHT),
                              (5100, UPRIGHT)]),
        writer.Track("KGSC", [(0, SHOWN), (1000, SHOWN), (1100, SHOWN), (1400, SHOWN), (1500, SHOWN),
                              (2600, SHOWN), (3000, HIDDEN), (3100, (0.05, 0.05, 0.05)), (5100, SHOWN)]),
    ]
    stump = writer.Bone("Stump", -1, (0.0, 0.0, 0.0))
    stump.tracks = [writer.Track("KGSC", [(0, HIDDEN), (1000, HIDDEN), (1100, HIDDEN), (1400, HIDDEN),
                                          (1500, SHOWN), (3000, SHOWN), (3100, SHOWN), (4900, SHOWN),
                                          (5100, HIDDEN)])]
    model.bones = [tree, stump]
    info = {"vertices": sum(len(g.vertices) for g in geosets), "triangles": sum(len(g.faces) for g in geosets) // 3,
            "height": round(height, 1), "stump": "stump" in boxes, "geosets": len(geosets)}
    return model, info


# ------------------------------------------------------------------ cache

def _sha(data):
    return hashlib.sha256(data).hexdigest()


def plan_digest(plan):
    blob = json.dumps({"version": TREES_VERSION, "types": plan["types"], "texture": [TEXTURE_LIMIT],
                       "minimap": MINIMAP_RGB}, sort_keys=True)
    return _sha(blob.encode("utf-8"))


def read_cache(folder, expected):
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
        if _sha(data) != digest:
            return None
        files[name] = data
    return files if expected <= set(files) else None


def write_cache(folder, files, info):
    tmp = folder.with_name(folder.name + f".tmp{os.getpid()}")
    shutil.rmtree(tmp, ignore_errors=True)
    for name, data in files.items():
        p = tmp / "files" / name.replace("\\", "/")
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    manifest = {"version": TREES_VERSION, "files": {n: _sha(d) for n, d in sorted(files.items())}, "models": info}
    (tmp / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True), encoding="utf-8")
    shutil.rmtree(folder, ignore_errors=True)
    os.replace(tmp, folder)


# ------------------------------------------------------------------ all of it

def convert_models(pak_vpk, vrf_exe, plan, work, log):
    """{map path: bytes} of every variation's model and texture, and info."""
    pairs = sorted({tuple(p) for variations in plan["types"].values() for p in variations})
    try:
        listing = vpkdir.read_tree(pak_vpk, VPK_PREFIXES)
    except (OSError, vpkdir.VpkError) as e:
        raise TreeError(f"Dota 2 game data could not be read: {e}") from e
    models = sorted({m for m, _s in pairs if m + "_c" in listing})
    for m in sorted({m for m, _s in pairs} - set(models)):
        log(f"trees: {m} is not in this Dota build; its variations borrow another tree")
    if not models:
        raise TreeError("none of Dota's tree models is in this Dota build")
    t0 = time.perf_counter()
    model_data = _blocks(vrf_exe, pak_vpk, [m + "_c" for m in models], work / "vrf", "tree models")
    groups = {m: material_groups(model_data.get(m + "_c", {})) for m in models}
    wanted = {}
    for m, skin in pairs:
        if m in groups:
            mats = groups[m].get(skin) or groups[m].get("0") or next(iter(groups[m].values()), [])
            wanted[(m, skin)] = mats
    vmats = sorted({p for mats in wanted.values() for p in mats if p in listing})
    mat_data = _blocks(vrf_exe, pak_vpk, vmats, work / "vrf", "tree materials") if vmats else {}
    infos = {p: material_info(mat_data[p]) for p in vmats if p in mat_data}
    vtex = sorted({x for i in infos.values() for x in (i["color"], i["mask"]) if x and x in listing})
    out_dir = work / "export"
    _run_vrf(vrf_exe, ["-i", str(pak_vpk), "-d", "-o", str(out_dir), "--gltf_export_format", "glb",
                       "-f", ",".join(m + "_c" for m in models)], work / "vrf", "tree model export")
    if vtex:
        try:
            vrf.extract(vrf_exe, pak_vpk, vtex, out_dir, work / "vrf", lambda s: None, threads=2)
        except vrf.VrfError as e:
            raise TreeError(f"tree textures: {e}") from e
    log(f"trees: VRF exported {len(models)} models, {len(vmats)} materials, {len(vtex)} textures in "
        f"{time.perf_counter() - t0:.1f} s")

    files, made, info = {}, {}, {}

    def texture(vmat):
        i = infos.get(vmat)
        if not i or not i["color"]:
            return None
        png = _exported(out_dir, i["color"])
        if png is None:
            return None
        path = texture_name(i["color"], i)
        if path not in files:
            mask = _exported(out_dir, i["mask"]) if i["mask"] else None
            files[path] = texture_bytes(png, i, mask)
        return path, i["alpha_test"]

    for m, skin in pairs:
        if (m, skin) not in wanted:
            continue
        glb_path = out_dir / (m[:-len(".vmdl")] + ".glb")
        if not glb_path.is_file():
            log(f"trees: VRF did not export {m}")
            continue
        default = groups[m].get("0") or []
        mats = wanted[(m, skin)]

        def texture_for(index, gltf_mat, default=default, mats=mats):
            vmat = _resource(((gltf_mat.get("extras") or {}).get("vmat") or {}).get("Name"))
            if vmat in default and default.index(vmat) < len(mats):
                vmat = mats[default.index(vmat)]
            elif len(mats) == 1:
                vmat = mats[0]
            hit = texture(vmat)
            if hit is None:
                placeholder = MAP_DIR + "missing.blp"
                files.setdefault(placeholder, textures.placeholder((60, 90, 40), encoding="palette"))
                return placeholder, False
            return hit
        try:
            model, minfo = build_model(Path(m).stem + (f"_{skin}" if skin != "0" else ""), glb_path, texture_for)
            made[(m, skin)] = writer.write(model)
            info[f"{m}#{skin}"] = minfo
        except (TreeError, gltf.GltfError, ValueError, KeyError, IndexError, OSError) as e:
            log(f"trees: {m} (skin {skin}) not converted: {e}")
    if not made:
        raise TreeError("no tree model could be converted")
    fallback = made[sorted(made)[0]]
    for tid, variations in plan["types"].items():
        first = next((made[tuple(p)] for p in variations if tuple(p) in made), fallback)
        for v, pair in enumerate(variations):
            files[model_path(tid, v)] = made.get(tuple(pair), first)
    return files, info


def prepare(dota_root, vrf_exe, build_dir, plan, base_w3b, log, base_w3d=None):
    """Map files of Dota's trees ({map path: bytes}: models, textures,
    war3map.w3b and war3map.w3d), from the cache of this Dota build when
    complete. Raises TreeError; the caller then keeps the WC3 trees."""
    if not plan.get("types"):
        return {}
    pak = Path(dota_root) / "game" / "dota" / "pak01_dir.vpk"
    if not pak.is_file():
        raise TreeError(f"Dota 2's game data is missing: {pak}")
    build_dir = Path(build_dir).resolve()
    folder = build_dir / f"{CACHE_PREFIX}{TREES_VERSION}-{plan_digest(plan)[:16]}"
    files = read_cache(folder, expected_files(plan))
    if files is not None:
        log(f"trees: cache complete ({len(files)} files, {folder.name})")
    else:
        work = build_dir / f"trees-work-{os.getpid()}"
        shutil.rmtree(work, ignore_errors=True)
        t = time.perf_counter()
        try:
            files, info = convert_models(pak.resolve(), Path(vrf_exe).resolve(), plan, work, log)
        finally:
            shutil.rmtree(work, ignore_errors=True)
        log(f"trees: {len(info)} Dota tree models for {sum(len(v) for v in plan['types'].values())} variations, "
            f"{sum(len(d) for d in files.values()) / 1048576:.1f} MB in {time.perf_counter() - t:.1f} s")
        try:
            write_cache(folder, files, info)
        except OSError as e:
            log(f"trees: could not write the cache {folder}: {e}")
        for old in build_dir.glob(CACHE_PREFIX + "*"):
            if old.is_dir() and old.name != folder.name and re.fullmatch(r"trees-\d+-[0-9a-f]{16}", old.name):
                shutil.rmtree(old, ignore_errors=True)
    out = dict(files)
    out["war3map.w3b"] = object_file(plan, base_w3b)
    if decor_kinds(plan):
        out["war3map.w3d"] = doodad_file(plan, base_w3d)
    return out
