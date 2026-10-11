"""Reader for the binary glTF 2.0 (.glb) files that VRF writes.

Only what the converter needs: nodes, skins, triangle meshes, materials with
external images, and linear/step animation channels. Pure Python (struct and
array), no numpy.
"""
import json
import struct
from array import array
from pathlib import Path

from .mathutil import IDENTITY, QUAT_IDENTITY, mat_from_gltf, mat_from_trs, mat_mul, quat_nlerp

GLB_MAGIC = 0x46546C67
CHUNK_JSON = 0x4E4F534A
CHUNK_BIN = 0x004E4942
COMPONENTS = {5120: ("b", 1, 127.0), 5121: ("B", 1, 255.0), 5122: ("h", 2, 32767.0),
              5123: ("H", 2, 65535.0), 5125: ("I", 4, None), 5126: ("f", 4, None)}
WIDTH = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT2": 4, "MAT3": 9, "MAT4": 16}
MODE_TRIANGLES = 4


class GltfError(Exception):
    pass


class Glb:
    def __init__(self, path):
        self.path = Path(path)
        data = self.path.read_bytes()
        if len(data) < 20:
            raise GltfError(f"{self.path.name}: too small for a GLB file")
        magic, version, length = struct.unpack_from("<III", data, 0)
        if magic != GLB_MAGIC or version != 2:
            raise GltfError(f"{self.path.name}: not a glTF 2.0 binary file")
        pos, self.json, self.bin = 12, None, b""
        while pos + 8 <= min(length, len(data)):
            size, kind = struct.unpack_from("<II", data, pos)
            chunk = data[pos + 8:pos + 8 + size]
            if kind == CHUNK_JSON:
                self.json = json.loads(chunk.decode("utf-8"))
            elif kind == CHUNK_BIN and not self.bin:
                self.bin = chunk
            pos += 8 + size
        if self.json is None:
            raise GltfError(f"{self.path.name}: no JSON chunk")
        j = self.json
        self.nodes = j.get("nodes", [])
        self.parent = [-1] * len(self.nodes)
        for i, n in enumerate(self.nodes):
            for c in n.get("children", []):
                self.parent[c] = i
        self.names = [n.get("name", f"node{i}") for i, n in enumerate(self.nodes)]
        self.rest = [self._node_trs(n) for n in self.nodes]
        self._cache = {}

    # ---------------------------------------------------------- accessors

    def accessor(self, index):
        """Values of an accessor: a flat list for SCALAR, else a list of tuples.
        Normalized integer data is returned as floats in [0, 1]."""
        if index in self._cache:
            return self._cache[index]
        acc = self.json["accessors"][index]
        if "sparse" in acc:
            raise GltfError(f"{self.path.name}: sparse accessors are not supported")
        code, size, norm = COMPONENTS[acc["componentType"]]
        width = WIDTH[acc["type"]]
        count = acc["count"]
        if "bufferView" not in acc:
            values = [0] * (count * width)
        else:
            view = self.json["bufferViews"][acc["bufferView"]]
            if view.get("buffer", 0) != 0:
                raise GltfError(f"{self.path.name}: external buffers are not supported")
            start = view.get("byteOffset", 0) + acc.get("byteOffset", 0)
            elem = size * width
            stride = view.get("byteStride") or elem
            if stride == elem:
                values = array(code)
                values.frombytes(self.bin[start:start + count * elem])
            else:
                values = array(code)
                for k in range(count):
                    values.frombytes(self.bin[start + k * stride:start + k * stride + elem])
            if len(values) != count * width:
                raise GltfError(f"{self.path.name}: accessor {index} runs past the buffer")
        if norm is not None and acc.get("normalized"):
            values = [v / norm for v in values]
        else:
            values = list(values)
        out = values if width == 1 else list(zip(*[iter(values)] * width))
        self._cache[index] = out
        return out

    # ---------------------------------------------------------- hierarchy

    @staticmethod
    def _node_trs(n):
        if "matrix" in n:
            return ("matrix", mat_from_gltf(n["matrix"]))
        return (tuple(n.get("translation", (0.0, 0.0, 0.0))),
                tuple(n.get("rotation", QUAT_IDENTITY)),
                tuple(n.get("scale", (1.0, 1.0, 1.0))))

    @staticmethod
    def trs_matrix(trs):
        if trs[0] == "matrix":
            return trs[1]
        return mat_from_trs(*trs)

    def world_matrices(self, local=None):
        """World matrix of every node. `local` optionally overrides node
        transforms: {node index: (t, q, s)}."""
        local = local or {}
        out = [None] * len(self.nodes)

        def world(i):
            if out[i] is None:
                m = self.trs_matrix(local.get(i, self.rest[i]))
                p = self.parent[i]
                out[i] = m if p < 0 else mat_mul(world(p), m)
            return out[i]

        for i in range(len(self.nodes)):
            world(i)
        return out

    # ---------------------------------------------------------- content

    def skins(self):
        """[(joint node indices, inverse bind matrices as affine 3x4)]"""
        out = []
        for s in self.json.get("skins", []):
            joints = list(s["joints"])
            if "inverseBindMatrices" in s:
                ibm = [mat_from_gltf(m) for m in self.accessor(s["inverseBindMatrices"])]
            else:
                ibm = [IDENTITY] * len(joints)
            out.append((joints, ibm))
        return out

    def mesh_nodes(self):
        """[(node index, mesh index, skin index or None)] in node order."""
        return [(i, n["mesh"], n.get("skin")) for i, n in enumerate(self.nodes) if "mesh" in n]

    def primitives(self, mesh_index):
        """Triangle primitives of a mesh as dicts of attribute lists."""
        mesh = self.json["meshes"][mesh_index]
        out = []
        for p in mesh["primitives"]:
            if p.get("mode", MODE_TRIANGLES) != MODE_TRIANGLES:
                continue
            attrs = p["attributes"]
            if "POSITION" not in attrs:
                continue
            prim = {"material": p.get("material"), "name": mesh.get("name", "")}
            for key in ("POSITION", "NORMAL", "TEXCOORD_0", "JOINTS_0", "WEIGHTS_0", "JOINTS_1", "WEIGHTS_1"):
                if key in attrs:
                    prim[key] = self.accessor(attrs[key])
            count = len(prim["POSITION"])
            prim["indices"] = self.accessor(p["indices"]) if "indices" in p else list(range(count))
            out.append(prim)
        return out

    def material(self, index):
        if index is None:
            return {}
        return self.json["materials"][index]

    def texture_path(self, texture_index):
        """Path of the image file behind a texture (VRF writes images next to
        the .glb), or None."""
        tex = self.json["textures"][texture_index]
        image = self.json["images"][tex["source"]]
        uri = image.get("uri")
        if not uri:
            return None
        return self.path.parent / uri

    # ---------------------------------------------------------- animation

    def animation_names(self):
        return [a.get("name", f"anim{i}") for i, a in enumerate(self.json.get("animations", []))]

    def animation(self, name):
        """{node: {path: (times, values, interpolation)}} and the duration."""
        for a in self.json.get("animations", []):
            if a.get("name") == name:
                break
        else:
            raise GltfError(f"{self.path.name}: no animation {name!r}")
        channels = {}
        duration = 0.0
        for ch in a["channels"]:
            target = ch["target"]
            if "node" not in target or target["path"] not in ("translation", "rotation", "scale"):
                continue
            sampler = a["samplers"][ch["sampler"]]
            times = self.accessor(sampler["input"])
            values = self.accessor(sampler["output"])
            interp = sampler.get("interpolation", "LINEAR")
            if interp == "CUBICSPLINE":
                values = values[1::3]  # keep the keyframe values, drop tangents
                interp = "LINEAR"
            if times:
                duration = max(duration, times[-1])
            channels.setdefault(target["node"], {})[target["path"]] = (times, values, interp)
        return channels, duration


def sample_channel(channel, t, default):
    """Value of one channel at time t (seconds)."""
    if channel is None:
        return default
    times, values, interp = channel
    n = len(times)
    if n == 0:
        return default
    if t <= times[0]:
        return values[0]
    if t >= times[-1]:
        return values[-1]
    lo, hi = 0, n - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if times[mid] <= t:
            lo = mid
        else:
            hi = mid
    t0, t1 = times[lo], times[hi]
    a, b = values[lo], values[hi]
    if interp == "STEP" or t1 <= t0:
        return a
    u = (t - t0) / (t1 - t0)
    if len(a) == 4:
        return quat_nlerp(a, b, u)
    return tuple(x + (y - x) * u for x, y in zip(a, b))


def key_times(channels):
    """Sorted union of the key times of all channels of an animation."""
    times = set()
    for paths in channels.values():
        for times_, _values, _interp in paths.values():
            times.update(times_)
    return sorted(times)
