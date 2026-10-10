"""Pack a folder into a Warcraft III map archive with StormLib.

Usage: mpq_pack.py <out.w3x> <folder>
Every file under <folder> is added under its relative path (backslashes),
zlib-compressed. StormLib also writes (listfile) and (attributes); attributes
hold CRC32 and MD5 only and file times are zero, so identical input gives an
identical archive.
"""
import ctypes
import os
import sys
from ctypes import wintypes

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DLL_PATH = os.path.join(ROOT, "tools", "vendor", "stormlib", "StormLib.dll")

MPQ_CREATE_ARCHIVE_V1 = 0x00000000
MPQ_CREATE_LISTFILE = 0x00100000
MPQ_CREATE_ATTRIBUTES = 0x00200000
MPQ_FILE_COMPRESS = 0x00000200
MPQ_FILE_REPLACEEXISTING = 0x80000000
MPQ_COMPRESSION_ZLIB = 0x02
MPQ_ATTRIBUTE_CRC32 = 0x01
MPQ_ATTRIBUTE_MD5 = 0x04


def load():
    dll = ctypes.WinDLL(DLL_PATH)
    H = wintypes.HANDLE
    dll.SFileCreateArchive.argtypes = [ctypes.c_wchar_p, wintypes.DWORD, wintypes.DWORD, ctypes.POINTER(H)]
    dll.SFileCreateArchive.restype = ctypes.c_bool
    dll.SFileSetAttributes.argtypes = [H, wintypes.DWORD]
    dll.SFileSetAttributes.restype = ctypes.c_bool
    dll.SFileCreateFile.argtypes = [H, ctypes.c_char_p, ctypes.c_uint64, wintypes.DWORD, wintypes.DWORD,
                                    wintypes.DWORD, ctypes.POINTER(H)]
    dll.SFileCreateFile.restype = ctypes.c_bool
    dll.SFileWriteFile.argtypes = [H, ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD]
    dll.SFileWriteFile.restype = ctypes.c_bool
    dll.SFileFinishFile.argtypes = [H]
    dll.SFileFinishFile.restype = ctypes.c_bool
    dll.SFileCloseArchive.argtypes = [H]
    dll.SFileCloseArchive.restype = ctypes.c_bool
    return dll


def pack(out_path, files):
    """files: list of (archived name, bytes)."""
    dll = load()
    if os.path.exists(out_path):
        os.remove(out_path)
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    h = wintypes.HANDLE()
    count = max(64, 1 << (len(files) + 8).bit_length())
    if not dll.SFileCreateArchive(os.path.abspath(out_path),
                                  MPQ_CREATE_ARCHIVE_V1 | MPQ_CREATE_LISTFILE | MPQ_CREATE_ATTRIBUTES,
                                  count, ctypes.byref(h)):
        raise OSError(f"SFileCreateArchive failed: {ctypes.get_last_error() or ctypes.GetLastError()}")
    try:
        dll.SFileSetAttributes(h, MPQ_ATTRIBUTE_CRC32 | MPQ_ATTRIBUTE_MD5)
        for name, data in sorted(files, key=lambda f: f[0].lower()):
            fh = wintypes.HANDLE()
            if not dll.SFileCreateFile(h, name.encode("utf-8"), 0, len(data), 0,
                                       MPQ_FILE_COMPRESS | MPQ_FILE_REPLACEEXISTING, ctypes.byref(fh)):
                raise OSError(f"SFileCreateFile failed for {name}: {ctypes.GetLastError()}")
            buf = ctypes.create_string_buffer(data, len(data))
            if len(data) and not dll.SFileWriteFile(fh, buf, len(data), MPQ_COMPRESSION_ZLIB):
                raise OSError(f"SFileWriteFile failed for {name}: {ctypes.GetLastError()}")
            if not dll.SFileFinishFile(fh):
                raise OSError(f"SFileFinishFile failed for {name}: {ctypes.GetLastError()}")
    finally:
        dll.SFileCloseArchive(h)


def main(out_path, folder):
    files = []
    for dirpath, _, names in os.walk(folder):
        for n in names:
            full = os.path.join(dirpath, n)
            rel = os.path.relpath(full, folder).replace("/", "\\")
            with open(full, "rb") as f:
                files.append((rel, f.read()))
    pack(out_path, files)
    print(f"packed {len(files)} files into {out_path} ({os.path.getsize(out_path)} bytes)")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
