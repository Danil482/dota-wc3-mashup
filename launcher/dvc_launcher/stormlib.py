"""Read the base map and write the personalized map with StormLib (MIT,
Ladislav Zezula, https://github.com/ladislav-zezula/StormLib) via ctypes.

The output is a new MPQ v1 archive: every file of the base map is copied
across (same name and locale, same content), then the assets are added with
zlib and MPQ_FILE_COMPRESS | MPQ_FILE_REPLACEEXISTING. StormLib writes the
(listfile) and the (attributes) file itself.

Assets go through SFileCreateFile / SFileWriteFile / SFileFinishFile, the calls
SFileAddFileEx makes after reading a file from disk. The archive bytes are the
same as with SFileAddFileEx (checked), without one temporary file per asset
(SFileAddFileEx took 7 s for 530 files here, this path 0.4 s).

Determinism: (attributes) holds CRC32 only, like maps saved by the Reforged
World Editor, so no file times end up in the archive; files are added in a
fixed order; StormLib's compression and table layout are deterministic. Equal
inputs therefore give byte-identical maps.
"""
import ctypes
import re
from ctypes import wintypes
from pathlib import Path

MPQ_FILE_COMPRESS = 0x00000200
MPQ_FILE_REPLACEEXISTING = 0x80000000
MPQ_FILE_DEFAULT_INTERNAL = 0xFFFFFFFF
MPQ_COMPRESSION_ZLIB = 0x02
MPQ_FORMAT_VERSION_1 = 0
MPQ_ATTRIBUTE_CRC32 = 0x00000001
MPQ_OPEN_READ_ONLY = 0x00000100
SFILE_OPEN_FROM_MPQ = 0
SFILE_VERIFY_FILE_CRC = 0x00000002
VERIFY_FILE_HAS_CHECKSUM = 0x0010
VERIFY_FILE_ERROR_MASK = 0x0001 | 0x0002 | 0x0008 | 0x0020 | 0x0080 | 0x0200
SFILE_MPQ_HEADER_OFFSET = 5        # SFileInfoClass.SFileMpqHeaderOffset
ERROR_NO_MORE_FILES = 18

SECTOR_SIZE = 0x1000
ATTRIBUTE_FLAGS = MPQ_ATTRIBUTE_CRC32
INTERNAL_FILES = {b"(listfile)", b"(attributes)", b"(signature)"}
HANDLE = ctypes.c_void_p
DWORD = wintypes.DWORD


class StormError(Exception):
    pass


class SFILE_FIND_DATA(ctypes.Structure):
    _fields_ = [("cFileName", ctypes.c_char * 260), ("szPlainName", ctypes.c_void_p),
                ("dwHashIndex", DWORD), ("dwBlockIndex", DWORD), ("dwFileSize", DWORD),
                ("dwFileFlags", DWORD), ("dwCompSize", DWORD), ("dwFileTimeLo", DWORD),
                ("dwFileTimeHi", DWORD), ("lcLocale", DWORD)]


class SFILE_CREATE_MPQ(ctypes.Structure):
    _fields_ = [("cbSize", DWORD), ("dwMpqVersion", DWORD), ("pvUserData", ctypes.c_void_p),
                ("cbUserData", DWORD), ("dwStreamFlags", DWORD), ("dwFileFlags1", DWORD),
                ("dwFileFlags2", DWORD), ("dwFileFlags3", DWORD), ("dwAttrFlags", DWORD),
                ("dwSectorSize", DWORD), ("dwRawChunkSize", DWORD), ("dwMaxFileCount", DWORD)]


class StormLib:
    """The StormLib.dll functions used here. The Windows release DLL is a
    Unicode build: on-disk paths are wide strings, archived names are bytes."""

    def __init__(self, dll_path):
        dll_path = Path(dll_path)
        if not dll_path.is_file():
            raise StormError(f"StormLib.dll not found: {dll_path}")
        try:
            self.dll = ctypes.WinDLL(str(dll_path), use_last_error=True)
        except OSError as e:
            raise StormError(f"StormLib.dll could not be loaded: {e}") from e
        P = ctypes.POINTER
        b = ctypes.c_bool
        self._fn("SFileSetLocale", DWORD, DWORD)
        self._fn("SFileOpenArchive", b, ctypes.c_wchar_p, DWORD, DWORD, P(HANDLE))
        self._fn("SFileCreateArchive2", b, ctypes.c_wchar_p, P(SFILE_CREATE_MPQ), P(HANDLE))
        self._fn("SFileCloseArchive", b, HANDLE)
        self._fn("SFileFindFirstFile", HANDLE, HANDLE, ctypes.c_char_p, P(SFILE_FIND_DATA), ctypes.c_wchar_p)
        self._fn("SFileFindNextFile", b, HANDLE, P(SFILE_FIND_DATA))
        self._fn("SFileFindClose", b, HANDLE)
        self._fn("SFileOpenFileEx", b, HANDLE, ctypes.c_char_p, DWORD, P(HANDLE))
        self._fn("SFileGetFileSize", DWORD, HANDLE, P(DWORD))
        self._fn("SFileReadFile", b, HANDLE, ctypes.c_void_p, DWORD, P(DWORD), ctypes.c_void_p)
        self._fn("SFileCloseFile", b, HANDLE)
        self._fn("SFileCreateFile", b, HANDLE, ctypes.c_char_p, ctypes.c_ulonglong, DWORD, DWORD, DWORD, P(HANDLE))
        self._fn("SFileWriteFile", b, HANDLE, ctypes.c_void_p, DWORD, DWORD)
        self._fn("SFileFinishFile", b, HANDLE)
        self._fn("SFileVerifyFile", DWORD, HANDLE, ctypes.c_char_p, DWORD)
        self._fn("SFileGetFileInfo", b, HANDLE, ctypes.c_int, ctypes.c_void_p, DWORD, P(DWORD))

    def _fn(self, name, restype, *argtypes):
        f = getattr(self.dll, name)
        f.restype = restype
        f.argtypes = argtypes
        setattr(self, name, f)

    @staticmethod
    def check(ok, what):
        if not ok:
            raise StormError(f"{what} failed (error {ctypes.get_last_error()})")

    # ------------------------------------------------------------ reading

    def open_archive(self, path):
        h = HANDLE()
        self.check(self.SFileOpenArchive(str(path), 0, MPQ_OPEN_READ_ONLY, ctypes.byref(h)),
                   f"opening {path}")
        return h

    def list_files(self, h):
        """[(name bytes, locale, block index)] for every file in the archive."""
        fd = SFILE_FIND_DATA()
        found = self.SFileFindFirstFile(h, b"*", ctypes.byref(fd), None)
        if not found:
            if ctypes.get_last_error() == ERROR_NO_MORE_FILES:
                return []
            self.check(False, "listing the archive")
        files = []
        try:
            while True:
                files.append((fd.cFileName, fd.lcLocale, fd.dwBlockIndex))
                if not self.SFileFindNextFile(found, ctypes.byref(fd)):
                    break
        finally:
            self.SFileFindClose(found)
        return files

    def read_file(self, h, name, locale=0):
        self.SFileSetLocale(locale)
        hf = HANDLE()
        try:
            self.check(self.SFileOpenFileEx(h, name, SFILE_OPEN_FROM_MPQ, ctypes.byref(hf)),
                       f"opening {name!r}")
        finally:
            self.SFileSetLocale(0)
        try:
            size = self.SFileGetFileSize(hf, None)
            buf = ctypes.create_string_buffer(max(size, 1))
            done = DWORD()
            if size:
                self.check(self.SFileReadFile(hf, buf, size, ctypes.byref(done), None) and done.value == size,
                           f"reading {name!r}")
            return buf.raw[:size]
        finally:
            self.SFileCloseFile(hf)

    def header_offset(self, h):
        value = ctypes.c_ulonglong()
        if self.SFileGetFileInfo(h, SFILE_MPQ_HEADER_OFFSET, ctypes.byref(value), 8, None):
            return value.value
        return 0

    # ------------------------------------------------------------ writing

    def create_archive(self, path, max_files):
        info = SFILE_CREATE_MPQ()
        info.cbSize = ctypes.sizeof(SFILE_CREATE_MPQ)
        info.dwMpqVersion = MPQ_FORMAT_VERSION_1
        info.dwFileFlags1 = MPQ_FILE_DEFAULT_INTERNAL      # (listfile)
        info.dwFileFlags2 = MPQ_FILE_DEFAULT_INTERNAL      # (attributes)
        info.dwFileFlags3 = 0                              # no (signature)
        info.dwAttrFlags = ATTRIBUTE_FLAGS
        info.dwSectorSize = SECTOR_SIZE
        info.dwMaxFileCount = max_files
        h = HANDLE()
        self.check(self.SFileCreateArchive2(str(path), ctypes.byref(info), ctypes.byref(h)),
                   f"creating {path}")
        return h

    def write_file(self, h, name, data, locale=0, file_time=0):
        hf = HANDLE()
        self.check(self.SFileCreateFile(h, name, file_time, len(data), locale,
                                        MPQ_FILE_COMPRESS | MPQ_FILE_REPLACEEXISTING, ctypes.byref(hf)),
                   f"adding {name!r}")
        try:
            if data:
                self.check(self.SFileWriteFile(hf, data, len(data), MPQ_COMPRESSION_ZLIB), f"writing {name!r}")
        finally:
            self.check(self.SFileFinishFile(hf), f"finishing {name!r}")

    def verify_file(self, h, name):
        """True when StormLib reads the file and its CRC32 matches (attributes)."""
        result = self.SFileVerifyFile(h, name, SFILE_VERIFY_FILE_CRC)
        return not result & VERIFY_FILE_ERROR_MASK and bool(result & VERIFY_FILE_HAS_CHECKSUM)


_UNNAMED = re.compile(rb"^File\d{8}\.\w+$")


def build_archive(dll_path, base_path, new_files, work_dir, log):
    """Copy every file of the base map into a new MPQ, add `new_files`
    ({archived name: bytes}) and return the archive bytes."""
    storm = StormLib(dll_path)
    work_dir = Path(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    out_path = work_dir / "map.w3x"
    if out_path.exists():
        out_path.unlink()
    new_names = {name.encode("ascii"): data for name, data in new_files.items()}
    new_upper = {n.upper() for n in new_names}

    base = storm.open_archive(base_path)
    try:
        listed = set()
        try:
            text = storm.read_file(base, b"(listfile)")
            listed = {line.strip().upper() for line in text.replace(b"\r", b"\n").split(b"\n") if line.strip()}
        except StormError:
            pass
        copies = []
        for name, locale, block in sorted(storm.list_files(base), key=lambda f: (f[2], f[1], f[0])):
            if name.lower() in INTERNAL_FILES:
                continue
            if _UNNAMED.match(name) and name.upper() not in listed:
                raise StormError(f"the base map contains a file without a name ({name.decode()})")
            if name.upper() in new_upper:
                log(f"base map file replaced by an asset: {name.decode('utf-8', 'replace')}")
                continue
            copies.append((name, locale))
        prefix_len = storm.header_offset(base)

        count = len(copies) + len(new_names) + len(INTERNAL_FILES)
        archive = storm.create_archive(out_path, max(64, 2 * count))
        closed = False
        try:
            for name, locale in copies:
                storm.write_file(archive, name, storm.read_file(base, name, locale), locale)
            for name in sorted(new_names, key=lambda n: (n.upper(), n)):
                storm.write_file(archive, name, new_names[name])
            closed = True
            storm.check(storm.SFileCloseArchive(archive), "closing the new map")
        finally:
            if not closed:
                storm.SFileCloseArchive(archive)
    finally:
        storm.SFileCloseArchive(base)

    # Self-check with StormLib: every file opens, decompresses and matches
    # the CRC32 stored in (attributes).
    check = storm.open_archive(out_path)
    try:
        entries = copies + [(name, 0) for name in new_names]
        bad = []
        for name, locale in entries:
            storm.SFileSetLocale(locale)
            if not storm.verify_file(check, name):
                bad.append(name.decode("utf-8", "replace"))
        storm.SFileSetLocale(0)
        if bad:
            raise StormError(f"{len(bad)} file(s) failed verification, e.g. {bad[:3]}")
        log(f"StormLib verified {len(entries)} files")
    finally:
        storm.SFileCloseArchive(check)

    data = out_path.read_bytes()
    out_path.unlink()
    if prefix_len:
        # Keep a pre-archive header (e.g. a 512-byte HM3W map header).
        data = Path(base_path).read_bytes()[:prefix_len] + data
    return data, len(copies)
