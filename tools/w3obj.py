"""Warcraft III object data: SLK metadata lookup and v2 object file writer.

Fields are addressed by their 4-char metadata ID (e.g. 'acdn', 'Ncl1'); the
metadata decides the value type, whether the field is per level and which
DataA..DataI pointer it uses, so callers never hand-encode those.
"""
import os
import struct

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SLK_DIR = os.path.join(ROOT, "research", "slk")


def parse_slk(path):
    """Minimal SYLK reader: returns a list of row dicts keyed by header names."""
    cells, x, y = {}, 0, 0
    with open(path, encoding="latin-1") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if not line.startswith(("C;", "F;")):
                continue
            value = None
            for part in line.split(";")[1:]:
                if not part:
                    continue
                k, v = part[0], part[1:]
                if k == "X":
                    x = int(v)
                elif k == "Y":
                    y = int(v)
                elif k == "K" and line.startswith("C;"):
                    value = v
            if value is not None:
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                cells[(y, x)] = value
    if not cells:
        return []
    max_y = max(k[0] for k in cells)
    max_x = max(k[1] for k in cells)
    header = [cells.get((1, c)) for c in range(1, max_x + 1)]
    rows = []
    for r in range(2, max_y + 1):
        row = {}
        for c in range(1, max_x + 1):
            name = header[c - 1]
            if name is not None and (r, c) in cells:
                row[name] = cells[(r, c)]
        if row:
            rows.append(row)
    return rows


# Fields of the 2.0.1 game metadata (CASC War3.w3mod:Units/UnitMetaData.slk)
# that the older research/slk copy lacks. upor is the unit portrait model:
# Units/UnitSkin.txt gives buildings and many creeps an explicit portrait,
# so a unit with a new umdl also needs upor or it shows the old portrait.
NEWER_FIELDS = {"unitmetadata.slk": {"upor": {"ID": "upor", "field": "portrait", "slk": "Profile", "type": "model"}}}


class Meta:
    """Field metadata for one object kind (units, abilities, ...)."""

    def __init__(self, filename):
        self.fields = {}
        for row in parse_slk(os.path.join(SLK_DIR, filename)):
            fid = row.get("ID")
            if fid:
                self.fields[fid] = row
        for fid, row in NEWER_FIELDS.get(filename, {}).items():
            self.fields.setdefault(fid, row)

    def info(self, fid):
        row = self.fields.get(fid)
        if row is None:
            raise KeyError(f"unknown field {fid}")
        typ = row.get("type", "string")
        if typ in ("int", "bool", "attackBits", "deathType", "defenseTypeInt", "detectionType",
                   "spellDetail", "teamColor", "techAvail", "versionFlags", "channelType",
                   "channelFlags", "morphFlags", "pickFlags", "silenceFlags", "stackFlags",
                   "interactionFlags", "fullFlags", "itemClass"):
            vtype = 0
        elif typ == "real":
            vtype = 1
        elif typ == "unreal":
            vtype = 2
        else:
            vtype = 3
        repeat = int(row.get("repeat", "0") or 0)
        data = int(row.get("data", "0") or 0)
        return vtype, repeat > 0, data


UNIT_META = None
ABIL_META = None
BUFF_META = None
UPGR_META = None


def metas():
    global UNIT_META, ABIL_META, BUFF_META, UPGR_META
    if UNIT_META is None:
        UNIT_META = Meta("unitmetadata.slk")      # units and items share it
        ABIL_META = Meta("abilitymetadata.slk")
        BUFF_META = Meta("abilitybuffmetadata.slk")
        UPGR_META = Meta("upgrademetadata.slk")
    return UNIT_META, ABIL_META, BUFF_META, UPGR_META


class ObjectFile:
    """Collects custom objects for one file (w3u/w3t/w3b/w3h or w3a/w3d/w3q)."""

    def __init__(self, meta, with_levels):
        self.meta = meta
        self.with_levels = with_levels
        self.objects = []   # (base_id, new_id, [(fid, vtype, level, data, value)])

    def add(self, base_id, new_id, fields):
        """fields: {fid: value} or {fid: [v_level1, v_level2, ...]} for leveled fields."""
        mods = []
        for fid, value in fields.items():
            vtype, leveled, data = self.meta.info(fid)
            if leveled and isinstance(value, (list, tuple)):
                for lvl, v in enumerate(value, start=1):
                    mods.append((fid, vtype, lvl, data, v))
            else:
                mods.append((fid, vtype, 1 if leveled else 0, data, value))
        self.objects.append((base_id, new_id, mods))

    def save(self):
        out = bytearray(struct.pack("<i", 2))
        out += struct.pack("<i", 0)             # no original-object modifications
        out += struct.pack("<i", len(self.objects))
        for base_id, new_id, mods in self.objects:
            out += base_id.encode("ascii") + new_id.encode("ascii")
            out += struct.pack("<i", len(mods))
            for fid, vtype, level, data, value in mods:
                out += fid.encode("ascii") + struct.pack("<i", vtype)
                if self.with_levels:
                    out += struct.pack("<ii", level, data)
                if vtype == 0:
                    out += struct.pack("<i", int(value))
                elif vtype in (1, 2):
                    out += struct.pack("<f", float(value))
                else:
                    out += str(value).encode("utf-8") + b"\0"
                out += b"\0\0\0\0"
        return bytes(out)
