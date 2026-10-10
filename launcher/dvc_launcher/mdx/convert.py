"""Convert a Dota 2 model exported by VRF as glTF (.glb), plus its default
cosmetic items, into a Warcraft III MDX (version 800) model.

Steps:
  1. Skeleton: the joints of the hero's skins. Item meshes are skinned to the
     same bone names; their vertices are re-bound to the hero's bind pose
     per bone, so an item bound in a different pose still sits right.
  2. Space: glTF metres (Y up, +Z forward) -> Dota/WC3 units (Z up, +X
     forward, which is WC3 facing 0): (x, y, z)_wc3 = (z, x, y)_gltf / 0.0254.
  3. Skinning: up to 4 weights per vertex are quantized to quarters and stored
     as a vertex group listing each bone once per quarter (WC3 averages the
     matrices of a group).
  4. Animation: every chosen clip is sampled at its key times; each bone gets
     the WC3 local transform that reproduces its glTF skinning matrix
     (pivot = bind position), keyframes are thinned within tolerances, and
     all clips are laid out on one timeline as named sequences.
  5. Attachments, a portrait camera and collision shapes are added; extents
     are computed per sequence from per-bone bounding boxes.

Everything here is deterministic (see mathutil): the same inputs give the
same bytes on every PC.
"""
import re
from math import gcd

from . import gltf, units, writer
from .mathutil import (IDENTITY, QUAT_IDENTITY, decompose, mat_apply, mat_apply_dir, mat_from_trs, mat_inv,
                       mat_max_abs_diff, mat_mul, normalize, quat_nlerp)

METRES_TO_UNITS = 1.0 / 0.0254
FRAME_MS = 1000.0
SEQUENCE_GAP_MS = 100
MAX_GROUP_BONES = 4
MAX_GROUPS = 256
# Classic (SD) geosets render garbled in Warcraft III from about 7430 vertices
# or 16386 triangle indices (mdx-m3-viewer's sanity test, measured in game);
# larger meshes are split into several geosets below these limits.
MAX_VERTICES = 7000
MAX_FACE_INDICES = 16200
TOL_TRANSLATION = 0.05      # WC3 units
TOL_ROTATION = 0.002        # quaternion component (about 0.2 degrees)
TOL_SCALE = 0.001
SKIP_MESH = re.compile(r"hitbox|invisible|nodraw", re.IGNORECASE)
# 80 degree tip-over for the synthesized "topple" death: (0, sin 40, 0, cos 40)
TOPPLE_QUAT = (0.0, 0.6427876096865393, 0.0, 0.766044443118978)


class ConvertError(Exception):
    pass


class Clip:
    """Per-frame skinning matrices of every WC3 bone for one sequence."""

    def __init__(self, times, mats):
        self.times = times      # [ms from sequence start]
        self.mats = mats        # [frame][bone] -> affine 3x4 (WC3 space)


# ------------------------------------------------------------------ helpers

def _quantize(weights):
    """[(bone, w)] -> sorted tuple of bones, each repeated once per quarter
    of weight (largest-remainder rounding), reduced by the common divisor."""
    total = sum(w for _b, w in weights)
    if total <= 0.0:
        return None
    ws = sorted(((w / total, b) for b, w in weights if w > 0.0), key=lambda x: (-x[0], x[1]))
    counts = [int(w * MAX_GROUP_BONES) for w, _b in ws]
    rest = MAX_GROUP_BONES - sum(counts)
    order = sorted(range(len(ws)), key=lambda i: (-(ws[i][0] * MAX_GROUP_BONES - counts[i]), i))
    for i in order[:rest]:
        counts[i] += 1
    pairs = [(b, c) for (_w, b), c in zip(ws, counts) if c > 0]
    g = 0
    for _b, c in pairs:
        g = gcd(g, c)
    group = []
    for b, c in sorted(pairs):
        group += [b] * (c // g)
    return tuple(group)


def _box_corners(mn, mx):
    return [(x, y, z) for x in (mn[0], mx[0]) for y in (mn[1], mx[1]) for z in (mn[2], mx[2])]


def _grow(box, p):
    mn, mx = box
    return ((min(mn[0], p[0]), min(mn[1], p[1]), min(mn[2], p[2])),
            (max(mx[0], p[0]), max(mx[1], p[1]), max(mx[2], p[2])))


EMPTY_BOX = ((1e30, 1e30, 1e30), (-1e30, -1e30, -1e30))


def _reduce(keys, tol, rotation=False):
    """Drop keys that linear interpolation of the kept neighbours reproduces
    within tol. keys: [(frame, value)], first and last always kept."""
    if len(keys) <= 2:
        return keys
    out = [keys[0]]
    i = 0
    n = len(keys)
    while i < n - 1:
        j = i + 1
        # extend the segment i..j+1 while every key in between still fits
        while j + 1 < n:
            f0, v0 = keys[i]
            f1, v1 = keys[j + 1]
            ok = True
            for k in range(i + 1, j + 1):
                fk, vk = keys[k]
                u = (fk - f0) / (f1 - f0)
                if rotation:
                    p = quat_nlerp(v0, v1, u)
                else:
                    p = tuple(a + (b - a) * u for a, b in zip(v0, v1))
                if max(abs(a - b) for a, b in zip(p, vk)) > tol:
                    ok = False
                    break
            if not ok:
                break
            j += 1
        out.append(keys[j])
        i = j
    return out


# ------------------------------------------------------------------ converter

class Converter:
    def __init__(self, key, unit, main_glb, item_glbs, clips, attachments, log=None):
        """clips: {WC3 sequence name: Dota clip name or None}; attachments:
        {dota attachment name: (bone name, offset (x, y, z) in Dota units)}"""
        self.key = key
        self.unit = unit
        self.kind = unit["kind"]
        self.log = log or (lambda msg: None)
        self.hero = gltf.Glb(main_glb)
        self.items = [gltf.Glb(p) for p in item_glbs]
        self.clip_names = clips
        self.dota_attachments = attachments
        self.notes = []

    # ---------------------------------------------------------- skeleton

    def build_skeleton(self):
        h = self.hero
        joints, ibm = [], {}
        for skin_joints, skin_ibm in h.skins():
            for j, m in zip(skin_joints, skin_ibm):
                if j not in ibm:
                    joints.append(j)
                    ibm[j] = m
        if not joints:
            # Unskinned model: one bone at the origin carries everything.
            root = next((i for i, p in enumerate(h.parent) if p < 0), 0)
            joints = [root]
            ibm[root] = mat_inv(h.world_matrices()[root])
        self.joints = joints
        self.ibm = ibm
        self.bind = {j: mat_inv(ibm[j]) for j in joints}
        self.joint_set = set(joints)
        names = [h.names[j] for j in joints]
        self.joint_by_name = {n: j for n, j in zip(names, joints)}
        self.joint_by_lower = {}
        for n, j in zip(names, joints):
            self.joint_by_lower.setdefault(n.lower(), j)

    def joint_parent(self, j):
        p = self.hero.parent[j]
        while p >= 0 and p not in self.joint_set:
            p = self.hero.parent[p]
        return p

    def match_joint(self, glb, node):
        """Hero joint for a node of an item model: same name, then the same
        name ignoring case, then the nearest matching ancestor."""
        n = node
        while n >= 0:
            name = glb.names[n]
            if name in self.joint_by_name:
                return self.joint_by_name[name]
            if name.lower() in self.joint_by_lower:
                return self.joint_by_lower[name.lower()]
            n = glb.parent[n]
        return self.joints[0]

    # ---------------------------------------------------------- space

    def set_space(self, offset=(0.0, 0.0, 0.0)):
        k = METRES_TO_UNITS
        self.C = (0.0, 0.0, k, offset[0],
                  k, 0.0, 0.0, offset[1],
                  0.0, k, 0.0, offset[2])
        self.Cinv = mat_inv(self.C)

    def to_wc3_mat(self, m):
        return mat_mul(mat_mul(self.C, m), self.Cinv)

    def to_wc3_point(self, v):
        return mat_apply(self.C, v)

    @staticmethod
    def to_wc3_dir(v):
        return (v[2], v[0], v[1])

    # ---------------------------------------------------------- geometry

    def collect_geometry(self):
        """Triangles of the hero and items in hero bind space (glTF units).
        Returns [(material key, [vertex dicts], faces)]."""
        out = []
        sources = [(self.hero, True)] + [(g, False) for g in self.items]
        for src_index, (glb, is_hero) in enumerate(sources):
            skins = glb.skins()
            world = None
            for node, mesh, skin in glb.mesh_nodes():
                mesh_name = glb.json["meshes"][mesh].get("name", "")
                if SKIP_MESH.search(mesh_name.rsplit(".", 1)[-1]):
                    continue
                if skin is None:
                    world = world or glb.world_matrices()
                    targets = [self.match_joint(glb, node) if not is_hero else self.joints[0]]
                    rebind = [world[node]]
                else:
                    sj, sibm = skins[skin]
                    targets, rebind = [], []
                    for j, m in zip(sj, sibm):
                        t = j if is_hero and j in self.joint_set else self.match_joint(glb, j)
                        targets.append(t)
                        rebind.append(mat_mul(self.bind[t], m))
                identity = all(mat_max_abs_diff(r, IDENTITY) < 1e-5 for r in rebind)
                for prim in glb.primitives(mesh):
                    mat = glb.material(prim["material"])
                    if SKIP_MESH.search(mat.get("name", "")):
                        continue
                    verts, faces = self._primitive(prim, targets, rebind, identity, skin is None)
                    if faces:
                        out.append(((src_index, prim["material"]), glb, mat, verts, faces))
        return out

    def _primitive(self, prim, targets, rebind, identity, rigid):
        pos = prim["POSITION"]
        nrm = prim.get("NORMAL")
        uv = prim.get("TEXCOORD_0")
        js = prim.get("JOINTS_0")
        ws = prim.get("WEIGHTS_0")
        js1 = prim.get("JOINTS_1")
        ws1 = prim.get("WEIGHTS_1")
        indices = prim["indices"]
        remap = {}
        verts = []
        faces = []
        for t in range(0, len(indices) - 2, 3):
            tri = indices[t:t + 3]
            if tri[0] == tri[1] or tri[1] == tri[2] or tri[0] == tri[2]:
                continue
            for i in tri:
                if i not in remap:
                    remap[i] = len(verts)
                    verts.append(self._vertex(i, pos, nrm, uv, js, ws, js1, ws1, targets, rebind, identity, rigid))
                faces.append(remap[i])
        return verts, faces

    def _vertex(self, i, pos, nrm, uv, js, ws, js1, ws1, targets, rebind, identity, rigid):
        p = pos[i]
        n = nrm[i] if nrm else (0.0, 1.0, 0.0)
        if rigid:
            influences = [(0, 1.0)]
        else:
            influences = [(j, w) for j, w in zip(js[i], ws[i]) if w > 0.0]
            if js1 and ws1:
                influences += [(j, w) for j, w in zip(js1[i], ws1[i]) if w > 0.0]
            if not influences:
                influences = [(js[i][0], 1.0)]
        weights = {}
        for j, w in influences:
            b = targets[j]
            weights[b] = weights.get(b, 0.0) + w
        if identity:
            pw, nw = p, n
        else:
            total = sum(w for _j, w in influences)
            px = py = pz = nx = ny = nz = 0.0
            for j, w in influences:
                m = rebind[j]
                a = mat_apply(m, p)
                d = mat_apply_dir(m, n)
                f = w / total
                px += a[0] * f
                py += a[1] * f
                pz += a[2] * f
                nx += d[0] * f
                ny += d[1] * f
                nz += d[2] * f
            pw, nw = (px, py, pz), (nx, ny, nz)
        return {"p": self.to_wc3_point(pw), "n": normalize(self.to_wc3_dir(nw)),
                "uv": tuple(uv[i]) if uv else (0.0, 0.0), "w": sorted(weights.items())}

    # ---------------------------------------------------------- animation

    def sample_clip(self, name):
        """Skinning matrices (WC3 space) of every joint at the clip's key times."""
        h = self.hero
        channels, duration = h.animation(name)
        times = gltf.key_times(channels) or [0.0]
        ms = []
        for t in times:
            v = int(round(t * FRAME_MS))
            if not ms or v > ms[-1]:
                ms.append(v)
        if len(ms) == 1:
            # A single pose: hold it for one second.
            ms = [0, 1000]
            times = [times[0], times[0]]
        else:
            # Re-sample at the rounded millisecond times for exact keys.
            times = [m / FRAME_MS for m in ms]
            ms = [m - ms[0] for m in ms]
        frames = []
        for t in times:
            local = {}
            for node, paths in channels.items():
                rest = h.rest[node]
                if rest[0] == "matrix":
                    continue
                local[node] = (gltf.sample_channel(paths.get("translation"), t, rest[0]),
                               gltf.sample_channel(paths.get("rotation"), t, rest[1]),
                               gltf.sample_channel(paths.get("scale"), t, rest[2]))
            world = h.world_matrices(local)
            frames.append([self.to_wc3_mat(mat_mul(world[j], self.ibm[j])) for j in self.bone_joints])
        return Clip(ms, frames)

    def synth(self, kind, base, duration_ms):
        """Synthesized motion on top of a pose (list of per-bone matrices)."""
        steps = 10
        times = [round(duration_ms * i / steps) for i in range(steps + 1)]
        frames = []
        height = max(1.0, self.bind_box[1][2] - self.bind_box[0][2])
        center = ((self.bind_box[0][0] + self.bind_box[1][0]) * 0.5,
                  (self.bind_box[0][1] + self.bind_box[1][1]) * 0.5, 0.0)
        for i in range(steps + 1):
            u = i / steps
            if kind == "rise":
                x = (1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, -height * (1.0 - u) * (1.0 - u))
            elif kind == "sink":
                x = (1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0, 1.0, -height * 0.9 * u * u)
            elif kind == "topple":
                q = quat_nlerp(QUAT_IDENTITY, TOPPLE_QUAT, min(1.0, u * 1.5))
                r = mat_from_trs((0.0, 0.0, 0.0), q, (1.0, 1.0, 1.0))
                # rotate about the ground point under the model's centre, then sink
                to = (1.0, 0.0, 0.0, -center[0], 0.0, 1.0, 0.0, -center[1], 0.0, 0.0, 1.0, 0.0)
                back = (1.0, 0.0, 0.0, center[0], 0.0, 1.0, 0.0, center[1], 0.0, 0.0, 1.0,
                        -height * 0.35 * max(0.0, u - 0.4) / 0.6)
                x = mat_mul(back, mat_mul(r, to))
            elif kind == "hold":
                x = IDENTITY
            else:
                raise ValueError(kind)
            # The motion applies to the whole model: every bone's skinning
            # matrix is moved, so child bones keep their local transforms.
            frames.append([mat_mul(x, m) for m in base])
        return Clip(times, frames)

    # ---------------------------------------------------------- main

    def convert(self, texture_path_for):
        """Build the WC3 model. texture_path_for(image path, material) ->
        (map path of the texture, alpha mode used). Returns (writer.Model, info)."""
        self.build_skeleton()
        self.set_space()
        geometry = self.collect_geometry()
        if not geometry:
            raise ConvertError("the model has no visible geometry")

        # Drop triangles that lie wholly below the ground plane (props whose
        # base reaches deep under the terrain).
        clip = self.unit.get("clip_below")
        if clip is not None:
            kept = []
            for k, g, m, verts, faces in geometry:
                tris = [faces[t:t + 3] for t in range(0, len(faces), 3)]
                tris = [tri for tri in tris if max(verts[i]["p"][2] for i in tri) >= clip]
                used = sorted({i for tri in tris for i in tri})
                remap = {old: new for new, old in enumerate(used)}
                if tris:
                    kept.append((k, g, m, [verts[i] for i in used], [remap[i] for tri in tris for i in tri]))
            geometry = kept

        # Structures: centre on the footprint, optionally put the base on the ground.
        if self.kind == units.STRUCTURE:
            box = EMPTY_BOX
            for _k, _g, _m, verts, _f in geometry:
                for v in verts:
                    box = _grow(box, v["p"])
            dz = -box[0][2] if self.unit.get("ground") else 0.0
            offset = (-(box[0][0] + box[1][0]) * 0.5, -(box[0][1] + box[1][1]) * 0.5, dz)
            if any(abs(c) > 1e-6 for c in offset):
                for _k, _g, _m, verts, _f in geometry:
                    for v in verts:
                        p = v["p"]
                        v["p"] = (p[0] + offset[0], p[1] + offset[1], p[2] + offset[2])
                self.set_space(offset)

        # Bones: joints that carry weight or an attachment, parented to the
        # nearest kept ancestor.
        used = set()
        for _k, _g, _m, verts, _f in geometry:
            for v in verts:
                group = _quantize(v["w"])
                v["g"] = group
                used.update(group)
        attach = self.resolve_attachments()
        for a in attach.values():
            if a["joint"] is not None:
                used.add(a["joint"])
        keep = [j for j in self.joints if j in used] or [self.joints[0]]
        index = {j: i for i, j in enumerate(keep)}
        self.bone_joints = keep
        self.bone_parent = []
        for j in keep:
            p = self.joint_parent(j)
            while p >= 0 and p not in index:
                p = self.joint_parent(p)
            self.bone_parent.append(index[p] if p >= 0 else -1)
        pivots = [mat_apply(self.C, (self.bind[j][3], self.bind[j][7], self.bind[j][11])) for j in keep]
        self.pivots = pivots

        model = writer.Model(self.key)
        bone_boxes = [EMPTY_BOX] * len(keep)
        box = EMPTY_BOX

        # Materials, textures, geosets
        tex_index, mat_index = {}, {}
        tri_lists = {}
        for (src_mat_key, glb, mat, verts, faces) in geometry:
            image = None
            bc = mat.get("pbrMetallicRoughness", {}).get("baseColorTexture")
            if bc is not None:
                image = glb.texture_path(bc["index"])
            alpha_mode = mat.get("alphaMode", "OPAQUE")
            tex_path, alpha_mode = texture_path_for(image, mat, alpha_mode)
            if tex_path not in tex_index:
                tex_index[tex_path] = len(model.textures)
                model.textures.append(writer.Texture(tex_path))
            filter_mode = {"MASK": writer.FILTER_TRANSPARENT, "BLEND": writer.FILTER_BLEND}.get(
                alpha_mode, writer.FILTER_NONE)
            shading = writer.SHADE_TWO_SIDED if mat.get("doubleSided") else 0
            mkey = (tex_index[tex_path], filter_mode, shading)
            if mkey not in mat_index:
                mat_index[mkey] = len(model.materials)
                model.materials.append(writer.Material([writer.Layer(mkey[0], filter_mode, shading)]))
            mi = mat_index[mkey]
            tri_lists.setdefault(mi, []).append((verts, faces))
            for v in verts:
                p = v["p"]
                box = _grow(box, p)
                main = max(v["w"], key=lambda bw: (bw[1], -bw[0]))[0]
                b = index.get(main)
                if b is None:
                    b = index[v["g"][0]]
                bone_boxes[b] = _grow(bone_boxes[b], p)
        self.bind_box = box
        for mi in sorted(tri_lists):
            for g in self._geosets(mi, tri_lists[mi], index):
                model.geosets.append(g)

        # Sequences
        clips = self.build_clips()
        frame = 0
        bone_keys = [{"t": [], "r": [], "s": []} for _ in keep]
        all_box = box
        for name, looping, rarity, clip in clips:
            start = frame
            end = start + clip.times[-1]
            seq_box = EMPTY_BOX
            step = max(1, len(clip.times) // 12)
            for fi in list(range(0, len(clip.times), step)) + [len(clip.times) - 1]:
                mats = clip.mats[fi]
                for b, (mn, mx) in enumerate(bone_boxes):
                    if mn[0] > mx[0]:
                        continue
                    for c in _box_corners(mn, mx):
                        seq_box = _grow(seq_box, mat_apply(mats[b], c))
            if seq_box[0][0] > seq_box[1][0]:
                seq_box = box
            all_box = _grow(_grow(all_box, seq_box[0]), seq_box[1])
            move = self.move_speed(clip) if name == "Walk" else 0.0
            model.sequences.append(writer.Sequence(name, start, end, looping, rarity, move,
                                                   writer.Extent(seq_box[0], seq_box[1])))
            self._bone_keys(clip, start, pivots, bone_keys)
            frame = end + SEQUENCE_GAP_MS
        model.extent = writer.Extent(all_box[0], all_box[1])
        for g in model.geosets:
            g.sequence_extents = [s.extent for s in model.sequences]

        # Bones
        for b, j in enumerate(keep):
            bone = writer.Bone(self.hero.names[j], self.bone_parent[b], pivots[b])
            keys = bone_keys[b]
            for tag, k in (("KGTR", keys["t"]), ("KGRT", keys["r"]), ("KGSC", keys["s"])):
                if k:
                    bone.tracks.append(writer.Track(tag, k))
            model.bones.append(bone)

        self.add_attachments(model, attach, index, box)
        self.add_camera_and_collision(model, attach, index, box)
        info = {"bones": len(keep), "geosets": len(model.geosets),
                "vertices": sum(len(g.vertices) for g in model.geosets),
                "triangles": sum(len(g.faces) for g in model.geosets) // 3,
                "sequences": {s.name: [s.start, s.end] for s in model.sequences},
                "clips": {name: src for name, src in self.clip_sources.items()},
                "height": round(box[1][2] - box[0][2], 1), "notes": self.notes}
        return model, info

    def _geosets(self, material_id, parts, index):
        out = []
        g, groups, vmap = None, None, None
        for verts, faces in parts:
            for t in range(0, len(faces), 3):
                tri = faces[t:t + 3]
                keys = [tuple(index[b] for b in verts[i]["g"]) for i in tri]
                if g is not None:
                    new_groups = {k for k in keys if k not in groups}
                    new_verts = sum(1 for i in tri if (id(verts), i) not in vmap)
                    if (len(groups) + len(new_groups) > MAX_GROUPS or len(g.vertices) + new_verts > MAX_VERTICES
                            or len(g.faces) + 3 > MAX_FACE_INDICES):
                        g = None
                if g is None:
                    g = writer.Geoset(material_id)
                    groups, vmap = {}, {}
                    out.append(g)
                for i, k in zip(tri, keys):
                    vk = (id(verts), i)
                    if vk not in vmap:
                        if k not in groups:
                            groups[k] = len(groups)
                            g.matrix_groups.append(k)
                        vmap[vk] = len(g.vertices)
                        v = verts[i]
                        g.vertices.append(v["p"])
                        g.normals.append(v["n"])
                        g.uvs.append(v["uv"])
                        g.vertex_groups.append(groups[k])
                    g.faces.append(vmap[vk])
        for g in out:
            box = EMPTY_BOX
            for p in g.vertices:
                box = _grow(box, p)
            g.extent = writer.Extent(box[0], box[1])
        return out

    def _bone_keys(self, clip, start, pivots, bone_keys):
        nb = len(self.bone_joints)
        inv_cache = {}
        last_local = [IDENTITY] * nb
        series = [([], [], []) for _ in range(nb)]
        for fi, (t, mats) in enumerate(zip(clip.times, clip.mats)):
            frame = start + t
            for b in range(nb):
                p = self.bone_parent[b]
                m = mats[b]
                if p >= 0:
                    key = (fi, p)
                    if key not in inv_cache:
                        try:
                            inv_cache[key] = mat_inv(mats[p])
                        except ValueError:
                            # Dota hides parts by scaling a bone to zero: the
                            # parent collapses everything below it, so the
                            # child keeps its last local transform meanwhile.
                            inv_cache[key] = None
                    m = last_local[b] if inv_cache[key] is None else mat_mul(inv_cache[key], m)
                last_local[b] = m
                tr, q, sc = decompose(m)
                pv = pivots[b]
                # local = T(tr') T(pivot) R S T(-pivot)  =>  tr' = t - pivot + R S pivot
                rs_p = mat_apply_dir(m, pv)
                tr = (tr[0] - pv[0] + rs_p[0], tr[1] - pv[1] + rs_p[1], tr[2] - pv[2] + rs_p[2])
                s_t, s_r, s_s = series[b]
                if s_r and (s_r[-1][1][0] * q[0] + s_r[-1][1][1] * q[1] + s_r[-1][1][2] * q[2]
                            + s_r[-1][1][3] * q[3]) < 0.0:
                    q = (-q[0], -q[1], -q[2], -q[3])
                s_t.append((frame, tr))
                s_r.append((frame, q))
                s_s.append((frame, sc))
        for b in range(nb):
            s_t, s_r, s_s = series[b]
            for keys, out, tol, rot in ((s_t, bone_keys[b]["t"], TOL_TRANSLATION, False),
                                        (s_r, bone_keys[b]["r"], TOL_ROTATION, True),
                                        (s_s, bone_keys[b]["s"], TOL_SCALE, False)):
                ident = QUAT_IDENTITY if rot else ((1.0, 1.0, 1.0) if out is bone_keys[b]["s"] else (0.0, 0.0, 0.0))
                if rot:
                    is_ident = all(max(abs(v[0]), abs(v[1]), abs(v[2])) <= tol for _f, v in keys)
                else:
                    is_ident = all(max(abs(a - c) for a, c in zip(v, ident)) <= tol for _f, v in keys)
                if is_ident:
                    continue        # no keys: the sequence uses the default (bind) value
                first = keys[0][1]
                if all(max(abs(a - c) for a, c in zip(v, first)) <= tol for _f, v in keys):
                    reduced = [keys[0], (keys[-1][0], first)]
                else:
                    reduced = _reduce(keys, tol, rot)
                out.extend(reduced)

    def move_speed(self, clip):
        """Ground speed the clip was animated for (units per second), measured
        before its root motion was removed. 0 if it was in place."""
        return getattr(clip, "speed", 0.0)

    def remove_root_motion(self, clip):
        """Dota locomotion clips move the whole skeleton forward (root
        motion); WC3 animations play in place while the engine moves the
        unit. Subtract the straight-line horizontal drift of the bones'
        centroid from start to end, so the clip loops on the spot."""
        n = len(self.bone_joints)

        def centroid(mats):
            sx = sy = 0.0
            for b in range(n):
                p = mat_apply(mats[b], self.pivots[b])
                sx += p[0]
                sy += p[1]
            return sx / n, sy / n

        x0, y0 = centroid(clip.mats[0])
        x1, y1 = centroid(clip.mats[-1])
        dx, dy = x1 - x0, y1 - y0
        dist = (dx * dx + dy * dy) ** 0.5
        duration = clip.times[-1] - clip.times[0]
        if dist < 2.0 or duration <= 0:
            return clip
        frames = []
        for t, mats in zip(clip.times, clip.mats):
            u = (t - clip.times[0]) / duration
            x = (1.0, 0.0, 0.0, -dx * u, 0.0, 1.0, 0.0, -dy * u, 0.0, 0.0, 1.0, 0.0)
            frames.append([mat_mul(x, m) for m in mats])
        out = Clip(clip.times, frames)
        out.speed = dist * FRAME_MS / duration
        return out

    # ---------------------------------------------------------- clips

    def build_clips(self):
        """[(sequence name, looping, rarity, Clip)] in timeline order."""
        out = []
        cache = {}
        self.clip_sources = {}
        rest_pose = [IDENTITY] * len(self.bone_joints)
        if self.kind == units.STRUCTURE:
            plan = [(n, n == "Stand", 0.0, units.STRUCTURE_FALLBACKS[n]) for n in units.STRUCTURE_SEQUENCES]
        else:
            plan = [(s[0], s[3], s[4], units.FALLBACKS.get(s[0])) for s in units.SEQUENCES]
        made = {}
        exported = set(self.hero.animation_names())
        for name, looping, rarity, fallback in plan:
            clip_name = self.clip_names.get(name)
            if clip_name and clip_name not in exported:
                self.notes.append(f"{name}: clip {clip_name} is not in the export")
                clip_name = None
            if clip_name:
                if clip_name not in cache:
                    cache[clip_name] = self.sample_clip(clip_name)
                clip, source = cache[clip_name], clip_name
                if looping:
                    if (clip_name, "inplace") not in cache:
                        cache[(clip_name, "inplace")] = self.remove_root_motion(clip)
                    clip = cache[(clip_name, "inplace")]
                    if clip is not cache[clip_name]:
                        self.notes.append(f"{name}: root motion removed ({clip.speed:.0f} units/s)")
            elif name in units.OPTIONAL:
                continue
            elif fallback in made:
                clip, source = made[fallback], f"={fallback}"
                self.notes.append(f"{name}: no Dota clip, plays {fallback}")
            elif fallback == "static":
                clip, source = Clip([0, 1000], [rest_pose, rest_pose]), "static"
            elif fallback in ("rise", "topple"):
                stand = made.get("Stand")
                pose = stand.mats[0] if stand is not None else rest_pose
                clip = self.synth(fallback, pose, 1000 if fallback == "rise" else 1500)
                source = f"synth:{fallback}"
            elif fallback == "sink":
                stand = made.get("Stand")
                pose = stand.mats[-1] if stand is not None else rest_pose
                clip, source = self.synth("sink", pose, 2500), "synth:sink"
            else:
                raise ConvertError(f"no source for sequence {name}")
            made[name] = clip
            self.clip_sources[name] = source
            out.append((name, looping, rarity, clip))
        if self.kind != units.STRUCTURE and "Death" in made:
            last = made["Death"].mats[-1]
            out.append(("Decay Flesh", False, 0.0, Clip([0, 2000], [last, last])))
            out.append(("Decay Bone", False, 0.0, self.synth("sink", last, 2000)))
            self.clip_sources["Decay Flesh"] = "hold:Death"
            self.clip_sources["Decay Bone"] = "synth:sink"
        return out

    # ---------------------------------------------------------- attachments

    def resolve_attachments(self):
        """Dota attachments -> {wc3 name: {"joint": hero joint or None, "pos": wc3 point}}"""
        found = {}
        lower = {k.lower(): v for k, v in self.dota_attachments.items()}

        def dota(*names):
            for n in names:
                a = lower.get(n.lower())
                if a is None:
                    continue
                bone, offset = a
                j = self.joint_by_name.get(bone) or self.joint_by_lower.get(bone.lower())
                if j is None:
                    continue
                o = tuple(c / METRES_TO_UNITS for c in offset)
                return j, mat_apply(self.C, mat_apply(self.bind[j], o))
            return None

        def bone(*patterns):
            for pat in patterns:
                rx = re.compile(pat, re.IGNORECASE)
                for j in self.joints:
                    if rx.search(self.hero.names[j]):
                        return j, mat_apply(self.C, (self.bind[j][3], self.bind[j][7], self.bind[j][11]))
            return None

        def put(name, hit):
            if hit is not None and name not in found:
                found[name] = {"joint": hit[0], "pos": hit[1]}

        put("Head Ref", dota("attach_head", "attach_head_1", "attach_head1", "attach_head2"))
        put("Head Ref", bone(r"^head", r"head"))
        put("Chest Ref", dota("attach_hitloc"))
        put("Chest Ref", bone(r"spine_?3|spine_?2|chest|spine"))
        put("Weapon Ref", dota("attach_attack1", "attach_weapon", "attach_attack2"))
        put("Hand Right Ref", bone(r"^(wrist|hand)_?(a_)?r$", r"(wrist|hand).*_r$", r"right.*(wrist|hand)",
                                   r"^r.*(wrist|hand)"))
        put("Hand Right Ref", dota("attach_attack1", "attach_hand1"))
        put("Hand Left Ref", bone(r"^(wrist|hand)_?(a_)?l$", r"(wrist|hand).*_l$", r"left.*(wrist|hand)",
                                  r"^l.*(wrist|hand)"))
        put("Hand Left Ref", dota("attach_attack2", "attach_hand2"))
        put("Foot Right Ref", bone(r"^(ankle|foot)_?r$", r"(ankle|foot).*_r$", r"right.*(ankle|foot)"))
        put("Foot Left Ref", bone(r"^(ankle|foot)_?l$", r"(ankle|foot).*_l$", r"left.*(ankle|foot)"))
        return found

    def add_attachments(self, model, attach, index, box):
        height = box[1][2] - box[0][2]
        entries = [("Origin Ref", None, (0.0, 0.0, 0.0))]
        head = attach.get("Head Ref")
        if self.kind == units.STRUCTURE:
            entries.append(("Overhead Ref", None, (0.0, 0.0, box[1][2] + 30.0)))
        elif head is not None:
            entries.append(("Overhead Ref", head["joint"], (head["pos"][0], head["pos"][1], box[1][2] + 30.0)))
        else:
            entries.append(("Overhead Ref", None, (0.0, 0.0, box[1][2] + 30.0)))
        for name in ("Head Ref", "Chest Ref", "Hand Left Ref", "Hand Right Ref", "Weapon Ref",
                     "Foot Left Ref", "Foot Right Ref"):
            a = attach.get(name)
            if a is not None:
                entries.append((name, a["joint"], a["pos"]))
            elif name == "Chest Ref":
                entries.append((name, None, (0.0, 0.0, box[0][2] + height * 0.5)))
        for i, (name, joint, pos) in enumerate(entries):
            parent = -1
            if joint is not None:
                j = joint
                while j >= 0 and j not in index:
                    j = self.joint_parent(j)
                parent = index[j] if j >= 0 else -1
            model.attachments.append(writer.Attachment(name, parent, pos, i))

    def add_camera_and_collision(self, model, attach, index, box):
        mn, mx = box
        height = max(1.0, mx[2] - mn[2])
        width = max(mx[0] - mn[0], mx[1] - mn[1])
        fov = 0.6
        half_tan = 0.30933624960962325      # tan(0.3)
        if self.kind == units.STRUCTURE:
            target = ((mn[0] + mx[0]) * 0.5, (mn[1] + mx[1]) * 0.5, mn[2] + height * 0.5)
            span = max(height, width) * 1.15
            dist = span / (2.0 * half_tan)
            position = (target[0] + dist * 0.8, target[1], target[2] + dist * 0.6)
            model.collisions.append(writer.CollisionShape("Collision Box", -1, target, writer.COLLISION_BOX,
                                                          (mn, mx)))
        else:
            head = attach.get("Head Ref")
            target = head["pos"] if head else (0.0, 0.0, mn[2] + height * 0.8)
            target = (target[0], target[1], target[2] - height * 0.08)
            span = height * 0.62
            dist = span / (2.0 * half_tan)
            position = (target[0] + dist, target[1], target[2] + dist * 0.12)
            chest = attach.get("Chest Ref")
            if chest is not None:
                j = chest["joint"]
                while j >= 0 and j not in index:
                    j = self.joint_parent(j)
                parent = index[j] if j >= 0 else -1
                center = chest["pos"]
            else:
                parent, center = -1, (0.0, 0.0, mn[2] + height * 0.5)
            radius = max(24.0, height * 0.32)
            model.collisions.append(writer.CollisionShape("Collision Sphere", parent, center,
                                                          writer.COLLISION_SPHERE, (center,), radius))
        model.cameras.append(writer.Camera("Portrait", position, target, fov, 4.0, dist * 6.0))
