"""Writer for Warcraft III MDX models, version 800 (the classic format).

Version 800 is the format Reforged 2.0.1 renders in both graphics modes:
classic (SD) mode does not load the HD formats (900/1000/1100), while HD mode
draws 800 models with the SD shader. Skinning uses vertex groups: each vertex
points at one matrix group, a list of up to four bones whose matrices the
game averages (a bone listed twice counts twice).

Chunk layout follows mdx-m3-viewer's parser (parsers/mdlx, MIT), which the
tests use to read every written model back:
  MDLX VERS MODL SEQS MTLS TEXS GEOS BONE ATCH PIVT CAMS CLID
Object ids: bones first, then attachments, then collision shapes; PIVT holds
one pivot per object in object-id order.
"""
import struct
from array import array

VERSION = 800

# Generic object type flags
FLAG_HELPER = 0x0
FLAG_BONE = 0x100
FLAG_ATTACHMENT = 0x800
FLAG_COLLISION = 0x2000

# Layer filter modes and shading flags
FILTER_NONE = 0
FILTER_TRANSPARENT = 1   # alpha test (cut-off 0.75)
FILTER_BLEND = 2
FILTER_ADDITIVE = 3
SHADE_UNSHADED = 0x1
SHADE_TWO_SIDED = 0x10
SHADE_UNFOGGED = 0x20

# Texture wrap flags
WRAP_WIDTH = 1
WRAP_HEIGHT = 2

INTERP_NONE = 0
INTERP_LINEAR = 1

COLLISION_BOX = 0
COLLISION_SPHERE = 2


class Extent:
    __slots__ = ("radius", "min", "max")

    def __init__(self, mn=(0.0, 0.0, 0.0), mx=(0.0, 0.0, 0.0), radius=None):
        self.min = tuple(mn)
        self.max = tuple(mx)
        if radius is None:
            dx, dy, dz = (self.max[i] - self.min[i] for i in range(3))
            radius = 0.5 * (dx * dx + dy * dy + dz * dz) ** 0.5
        self.radius = radius

    def pack(self):
        return struct.pack("<7f", self.radius, *self.min, *self.max)


class Sequence:
    def __init__(self, name, start, end, looping=True, rarity=0.0, move_speed=0.0, extent=None):
        self.name = name
        self.start = start
        self.end = end
        self.looping = looping
        self.rarity = rarity
        self.move_speed = move_speed
        self.extent = extent or Extent()


class Layer:
    def __init__(self, texture_id, filter_mode=FILTER_NONE, shading=0, alpha=1.0):
        self.texture_id = texture_id
        self.filter_mode = filter_mode
        self.shading = shading
        self.alpha = alpha


class Material:
    def __init__(self, layers, priority_plane=0, flags=0):
        self.layers = layers
        self.priority_plane = priority_plane
        self.flags = flags


class Texture:
    def __init__(self, path, wrap=WRAP_WIDTH | WRAP_HEIGHT, replaceable_id=0):
        self.path = path
        self.wrap = wrap
        self.replaceable_id = replaceable_id


class Geoset:
    """vertices/normals: [(x, y, z)], uvs: [(u, v)], faces: flat index list,
    vertex_groups: per-vertex matrix group index, matrix_groups: [(bone
    object ids...)]"""

    def __init__(self, material_id):
        self.material_id = material_id
        self.vertices = []
        self.normals = []
        self.uvs = []
        self.faces = []
        self.vertex_groups = []
        self.matrix_groups = []
        self.extent = Extent()
        self.sequence_extents = []
        self.selection_group = 0


class Track:
    """Keyframes of one animated property: [(frame ms, value tuple)]."""

    def __init__(self, tag, keys, interpolation=INTERP_LINEAR):
        self.tag = tag
        self.keys = keys
        self.interpolation = interpolation

    def pack(self):
        width = len(self.keys[0][1]) if self.keys else 0
        out = [self.tag.encode("ascii"), struct.pack("<IIi", len(self.keys), self.interpolation, -1)]
        fmt = struct.Struct(f"<i{width}f")
        out += [fmt.pack(frame, *value) for frame, value in self.keys]
        return b"".join(out)


class Node:
    def __init__(self, name, parent=-1, pivot=(0.0, 0.0, 0.0), flags=0):
        self.name = name
        self.parent = parent
        self.pivot = tuple(pivot)
        self.flags = flags
        self.tracks = []          # KGTR, KGRT, KGSC


class Bone(Node):
    def __init__(self, name, parent=-1, pivot=(0.0, 0.0, 0.0)):
        super().__init__(name, parent, pivot, FLAG_BONE)


class Attachment(Node):
    def __init__(self, name, parent=-1, pivot=(0.0, 0.0, 0.0), attachment_id=0):
        super().__init__(name, parent, pivot, FLAG_ATTACHMENT)
        self.attachment_id = attachment_id


class CollisionShape(Node):
    def __init__(self, name, parent=-1, pivot=(0.0, 0.0, 0.0), shape=COLLISION_SPHERE,
                 vertices=((0.0, 0.0, 0.0),), radius=0.0):
        super().__init__(name, parent, pivot, FLAG_COLLISION)
        self.shape = shape
        self.vertices = vertices
        self.radius = radius


class Camera:
    def __init__(self, name, position, target, fov=0.7854, near=8.0, far=2000.0):
        self.name = name
        self.position = tuple(position)
        self.target = tuple(target)
        self.fov = fov
        self.near = near
        self.far = far


class Model:
    def __init__(self, name):
        self.name = name
        self.extent = Extent()
        self.sequences = []
        self.materials = []
        self.textures = []
        self.geosets = []
        self.bones = []
        self.attachments = []
        self.collisions = []
        self.cameras = []

    def objects(self):
        """Generic objects in object-id order."""
        return list(self.bones) + list(self.attachments) + list(self.collisions)


# ------------------------------------------------------------------ writing

def _name(text, size):
    raw = text.encode("ascii", "replace")[:size - 1]
    return raw + b"\0" * (size - len(raw))


def _chunk(tag, body):
    return tag.encode("ascii") + struct.pack("<I", len(body)) + body


def _floats(values):
    a = array("f", values)
    return a.tobytes()


def _generic(node, object_id):
    tracks = b"".join(t.pack() for t in node.tracks if t.keys)
    return struct.pack("<I", 96 + len(tracks)) + _name(node.name, 80) + struct.pack(
        "<iiI", object_id, node.parent, node.flags) + tracks


def _geoset(g, sequence_count):
    nv = len(g.vertices)
    if nv > 65535:
        raise ValueError(f"geoset has {nv} vertices (max 65535)")
    if nv >= 7433 or len(g.faces) >= 16386:
        raise ValueError(f"geoset too large for classic rendering ({nv} vertices, {len(g.faces)} indices)")
    if len(g.matrix_groups) > 256:
        raise ValueError(f"geoset has {len(g.matrix_groups)} matrix groups (max 256)")
    if len(g.sequence_extents) != sequence_count:
        raise ValueError("geoset needs one extent per sequence")
    flat_mats = [b for group in g.matrix_groups for b in group]
    parts = [
        b"VRTX", struct.pack("<I", nv), _floats(c for v in g.vertices for c in v),
        b"NRMS", struct.pack("<I", nv), _floats(c for v in g.normals for c in v),
        b"PTYP", struct.pack("<II", 1, 4),
        b"PCNT", struct.pack("<II", 1, len(g.faces)),
        b"PVTX", struct.pack("<I", len(g.faces)), array("H", g.faces).tobytes(),
        b"GNDX", struct.pack("<I", nv), bytes(g.vertex_groups),
        b"MTGC", struct.pack("<I", len(g.matrix_groups)), array("I", [len(m) for m in g.matrix_groups]).tobytes(),
        b"MATS", struct.pack("<I", len(flat_mats)), array("I", flat_mats).tobytes(),
        struct.pack("<III", g.material_id, g.selection_group, 0),
        g.extent.pack(),
        struct.pack("<I", len(g.sequence_extents)), b"".join(e.pack() for e in g.sequence_extents),
        b"UVAS", struct.pack("<I", 1),
        b"UVBS", struct.pack("<I", nv), _floats(c for uv in g.uvs for c in uv),
    ]
    body = b"".join(parts)
    return struct.pack("<I", 4 + len(body)) + body


def write(model):
    """Serialize a Model as MDX version 800 bytes."""
    if array("f").itemsize != 4 or array("H").itemsize != 2 or array("I").itemsize != 4:
        raise RuntimeError("unexpected array item sizes")
    out = [b"MDLX", _chunk("VERS", struct.pack("<I", VERSION))]
    out.append(_chunk("MODL", _name(model.name, 80) + _name("", 260) + model.extent.pack()
                      + struct.pack("<I", 150)))
    if model.sequences:
        body = b"".join(
            _name(s.name, 80) + struct.pack("<IIfIfI", s.start, s.end, s.move_speed, 0 if s.looping else 1,
                                            s.rarity, 0) + s.extent.pack()
            for s in model.sequences)
        out.append(_chunk("SEQS", body))
    if model.materials:
        mats = []
        for m in model.materials:
            layers = b"".join(
                struct.pack("<IIIiiIf", 28, layer.filter_mode, layer.shading, layer.texture_id, -1, 0, layer.alpha)
                for layer in m.layers)
            body = struct.pack("<iI", m.priority_plane, m.flags) + b"LAYS" + struct.pack("<I", len(m.layers)) + layers
            mats.append(struct.pack("<I", 4 + len(body)) + body)
        out.append(_chunk("MTLS", b"".join(mats)))
    if model.textures:
        out.append(_chunk("TEXS", b"".join(
            struct.pack("<I", t.replaceable_id) + _name(t.path, 260) + struct.pack("<I", t.wrap)
            for t in model.textures)))
    if model.geosets:
        out.append(_chunk("GEOS", b"".join(_geoset(g, len(model.sequences)) for g in model.geosets)))
    object_id = 0
    if model.bones:
        body = []
        for b in model.bones:
            body.append(_generic(b, object_id) + struct.pack("<ii", -1, -1))
            object_id += 1
        out.append(_chunk("BONE", b"".join(body)))
    if model.attachments:
        body = []
        for a in model.attachments:
            inner = _generic(a, object_id) + _name("", 260) + struct.pack("<i", a.attachment_id)
            body.append(struct.pack("<I", 4 + len(inner)) + inner)
            object_id += 1
        out.append(_chunk("ATCH", b"".join(body)))
    objects = model.objects()
    if objects:
        out.append(_chunk("PIVT", _floats(c for o in objects for c in o.pivot)))
    if model.cameras:
        body = []
        for c in model.cameras:
            inner = (_name(c.name, 80) + struct.pack("<3f", *c.position)
                     + struct.pack("<fff", c.fov, c.far, c.near) + struct.pack("<3f", *c.target))
            body.append(struct.pack("<I", 4 + len(inner)) + inner)
        out.append(_chunk("CAMS", b"".join(body)))
    if model.collisions:
        body = []
        for c in model.collisions:
            shape = struct.pack("<I", c.shape) + _floats(x for v in c.vertices for x in v)
            if c.shape in (COLLISION_SPHERE, 3):
                shape += struct.pack("<f", c.radius)
            body.append(_generic(c, object_id) + shape)
            object_id += 1
        out.append(_chunk("CLID", b"".join(body)))
    return b"".join(out)
