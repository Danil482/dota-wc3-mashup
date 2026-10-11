"""Read files from the local CASC storage of Warcraft III Reforged (TVFS root).

Standard library only, read-only. A path goes through the TVFS manifests to an
encoded key (EKey); the local index gives its place in Data/data/data.###,
and the BLTE blob there is checked against that key, chunk by chunk, before it
is decoded. CascLib publishes no binaries, hence this reader.

Paths are case-insensitive and look like "war3.w3mod:units/unitdata.slk":
":" enters a nested manifest, "/" (or "\\") separates folders.
"""
import hashlib
import os
import struct
import zlib

TVFS_FOLDER = 0x80000000
LOCAL_HEADER = 30           # EKey (reversed), size, flags and checksums before each blob


class CascError(Exception):
    pass


def build_info(root):
    """The active row of <root>/.build.info as {column name: value}."""
    path = os.path.join(root, ".build.info")
    with open(path, encoding="utf-8") as f:
        lines = [line.rstrip("\r\n") for line in f if line.strip()]
    if len(lines) < 2:
        raise CascError(f"{path} lists no build")
    names = [column.split("!")[0] for column in lines[0].split("|")]
    rows = [dict(zip(names, line.split("|"))) for line in lines[1:]]
    return next((row for row in rows if row.get("Active") == "1"), rows[0])


def read_config(data_dir, key):
    path = os.path.join(data_dir, "config", key[0:2], key[2:4], key)
    values = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            name, sep, value = line.partition("=")
            if sep and not line.startswith("#"):
                values[name.strip()] = value.split()
    return values


def read_indices(data_dir):
    """{9-byte EKey: (archive number, offset, size)} from the newest .idx of each bucket."""
    newest = {}
    for name in os.listdir(data_dir):
        if len(name) == 14 and name.lower().endswith(".idx"):
            bucket, version = name[:2], int(name[2:10], 16)
            if version > newest.get(bucket, (-1, ""))[0]:
                newest[bucket] = (version, name)
    if not newest:
        raise CascError(f"no local index (.idx) in {data_dir}")
    entries = {}
    for _, name in newest.values():
        with open(os.path.join(data_dir, name), "rb") as f:
            raw = f.read()
        header_len = struct.unpack_from("<I", raw, 0)[0]
        version, _bucket, _extra, size_len, offset_len, key_len, offset_bits = struct.unpack_from("<HBBBBBB", raw, 8)
        if version != 7:
            raise CascError(f"{name}: unsupported index version {version}")
        pos = (8 + header_len + 15) & ~15
        entries_len = struct.unpack_from("<I", raw, pos)[0]
        pos += 8
        step = key_len + offset_len + size_len
        mask = (1 << offset_bits) - 1
        for p in range(pos, pos + entries_len - step + 1, step):
            location = int.from_bytes(raw[p + key_len:p + key_len + offset_len], "big")
            size = int.from_bytes(raw[p + key_len + offset_len:p + step], "little")
            entries.setdefault(raw[p:p + key_len], (location >> offset_bits, location & mask, size))
    return entries


def decode_blte(blob, ekey):
    """Content of a BLTE blob whose encoded key starts with `ekey`."""
    if blob[:4] != b"BLTE":
        raise CascError(f"{ekey.hex()}: not a BLTE blob")
    header_len = struct.unpack_from(">I", blob, 4)[0]
    if header_len == 0:
        if hashlib.md5(blob).digest()[:len(ekey)] != ekey:
            raise CascError(f"{ekey.hex()}: blob does not match its key")
        return _chunk(blob[8:], ekey)
    if hashlib.md5(blob[:header_len]).digest()[:len(ekey)] != ekey:
        raise CascError(f"{ekey.hex()}: BLTE header does not match its key")
    flags, count = blob[8], int.from_bytes(blob[9:12], "big")
    if flags != 0x0F or header_len != 12 + 24 * count:
        raise CascError(f"{ekey.hex()}: unsupported BLTE header (flags {flags:#x})")
    parts, pos = [], header_len
    for i in range(count):
        encoded_len, decoded_len = struct.unpack_from(">II", blob, 12 + 24 * i)
        chunk = blob[pos:pos + encoded_len]
        if hashlib.md5(chunk).digest() != blob[20 + 24 * i:36 + 24 * i]:
            raise CascError(f"{ekey.hex()}: chunk {i} fails its MD5 check")
        part = _chunk(chunk, ekey)
        if len(part) != decoded_len:
            raise CascError(f"{ekey.hex()}: chunk {i} has the wrong size")
        parts.append(part)
        pos += encoded_len
    return b"".join(parts)


def _chunk(chunk, ekey):
    mode = chunk[:1]
    if mode == b"N":
        return chunk[1:]
    if mode == b"Z":
        return zlib.decompress(chunk[1:])
    raise CascError(f"{ekey.hex()}: unsupported BLTE chunk mode {mode!r}")


class Storage:
    """A Warcraft III install: the folder holding .build.info and Data\\."""

    def __init__(self, root):
        self.root = root
        self.data_dir = os.path.join(root, "Data")
        info = build_info(root)
        self.version = info.get("Version", "")
        config = read_config(self.data_dir, info["Build Key"])
        if "vfs-root" not in config:
            raise CascError("the build has no TVFS root (not Warcraft III Reforged?)")
        self.index = read_indices(os.path.join(self.data_dir, "data"))
        self.manifests = {bytes.fromhex(v[1])[:9]: bytes.fromhex(v[0])
                          for k, v in config.items() if k.startswith("vfs-") and not k.endswith("-size")}
        root_ckey, root_ekey = (bytes.fromhex(v) for v in config["vfs-root"])
        self.files = {}
        self._walk_manifest(self._read_ekey(root_ekey[:9], root_ckey), "")

    def read(self, path):
        spans = self.files.get(path.replace("\\", "/").lower())
        if spans is None:
            raise CascError(f"{path} is not in the storage")
        data = b"".join(self._read_ekey(ekey) for ekey, _ in spans)
        if len(data) != sum(size for _, size in spans):
            raise CascError(f"{path}: wrong content size")
        return data

    def _read_ekey(self, ekey, ckey=None):
        location = self.index.get(ekey)
        if location is None:
            raise CascError(f"{ekey.hex()} is not in the local storage (incomplete install?)")
        archive, offset, size = location
        with open(os.path.join(self.data_dir, "data", f"data.{archive:03d}"), "rb") as f:
            f.seek(offset)
            blob = f.read(size)
        if len(blob) != size or blob[15::-1][:len(ekey)] != ekey:
            raise CascError(f"{ekey.hex()}: local data entry is damaged")
        data = decode_blte(blob[LOCAL_HEADER:], ekey)
        if ckey is not None and hashlib.md5(data).digest() != ckey:
            raise CascError(f"{ekey.hex()}: content does not match its content key")
        return data

    def _walk_manifest(self, data, prefix):
        if data[:4] != b"TVFS":
            raise CascError(f"{prefix or 'vfs-root'}: not a TVFS manifest")
        _version, _header_len, ekey_len, _pkey_len, _flags = struct.unpack_from(">BBBBI", data, 4)
        path_off, path_len, vfs_off, vfs_len, cft_off, cft_len = struct.unpack_from(">6I", data, 12)
        vfs = data[vfs_off:vfs_off + vfs_len]
        cft = data[cft_off:cft_off + cft_len]
        cft_offset_len = 1 if cft_len <= 0xFF else 2 if cft_len <= 0xFFFF else 3 if cft_len <= 0xFFFFFF else 4

        def spans(offset):
            count = vfs[offset]
            if not 1 <= count <= 224:       # 225-255: other or deleted files
                return []
            result, p = [], offset + 1
            for _ in range(count):
                size = struct.unpack_from(">I", vfs, p + 4)[0]
                at = int.from_bytes(vfs[p + 8:p + 8 + cft_offset_len], "big")
                result.append((cft[at:at + ekey_len], size))
                p += 8 + cft_offset_len
            return result

        def walk(pos, end, base):
            # A path table entry: [0 = separator before] [length, name] [0 = separator after]
            # [0xFF, value]. A name followed by another entry instead of a value
            # also ends with a separator; the value is a folder size or a file.
            path = base
            while pos < end:
                before = after = False
                name, value = "", None
                if data[pos] == 0:
                    before = True
                    pos += 1
                if pos < end and data[pos] != 0xFF:
                    n = data[pos]
                    name = data[pos + 1:pos + 1 + n].decode("utf-8")
                    pos += 1 + n
                if pos < end and data[pos] == 0:
                    after = True
                    pos += 1
                if pos < end:
                    if data[pos] == 0xFF:
                        value = struct.unpack_from(">I", data, pos + 1)[0]
                        pos += 5
                    else:
                        after = True
                path += ("/" if before else "") + name + ("/" if after else "")
                if value is None:
                    continue
                if value & TVFS_FOLDER:
                    folder_end = pos + (value & ~TVFS_FOLDER) - 4
                    walk(pos, folder_end, path)
                    pos = folder_end
                else:
                    found = spans(value)
                    if len(found) == 1 and found[0][0] in self.manifests:
                        ekey = found[0][0]
                        self._walk_manifest(self._read_ekey(ekey, self.manifests[ekey]), path + ":")
                    elif found:
                        self.files[path.lower()] = found
                path = base

        walk(path_off, path_off + path_len, prefix)
