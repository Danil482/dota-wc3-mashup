"""Fast reader for the directory tree of a Valve VPK (v1/v2) archive.

Only the index is read; file data is extracted by VRF. The tree is parsed from
one in-memory buffer, which is several times faster than per-entry file reads.
"""
import struct

VPK_SIGNATURE = 0x55AA1234


class VpkError(Exception):
    pass


def read_tree(path, prefixes=None):
    """Return {vpk path: size in bytes} for every file whose path starts with
    one of `prefixes` (all files when prefixes is None)."""
    with open(path, "rb") as f:
        head = f.read(28)
        if len(head) < 12:
            raise VpkError(f"{path}: file too small for a VPK header")
        signature, version, tree_length = struct.unpack_from("<III", head)
        if signature != VPK_SIGNATURE:
            raise VpkError(f"{path}: not a VPK file (bad signature)")
        if version == 1:
            header_length = 12
        elif version == 2:
            header_length = 28
        else:
            raise VpkError(f"{path}: unsupported VPK version {version}")
        f.seek(header_length)
        tree = f.read(tree_length)
    if len(tree) != tree_length:
        raise VpkError(f"{path}: truncated directory tree")

    prefixes = tuple(prefixes) if prefixes else None
    result = {}
    pos = 0
    unpack = struct.unpack_from

    def cstring(start):
        end = tree.find(b"\0", start)
        if end < 0:
            raise VpkError(f"{path}: corrupt directory tree (unterminated string)")
        return tree[start:end], end + 1

    try:
        while True:
            ext, pos = cstring(pos)
            if not ext:
                break
            ext = ext.decode("utf-8")
            while True:
                folder, pos = cstring(pos)
                if not folder:
                    break
                folder = folder.decode("utf-8")
                folder = "" if folder == " " else folder + "/"
                # Skip whole folders that cannot match any prefix.
                wanted_folder = prefixes is None or any(
                    folder.startswith(p) or p.startswith(folder) for p in prefixes)
                while True:
                    name, pos = cstring(pos)
                    if not name:
                        break
                    _crc, preload, _archive, _offset, length, term = unpack("<IHHIIH", tree, pos)
                    if term != 0xFFFF:
                        raise VpkError(f"{path}: corrupt directory entry")
                    pos += 18 + preload
                    if wanted_folder:
                        full = folder + name.decode("utf-8") + "." + ext
                        if prefixes is None or full.startswith(prefixes):
                            result[full] = preload + length
    except (struct.error, UnicodeDecodeError) as e:
        raise VpkError(f"{path}: corrupt directory tree ({e})") from e
    return result
