"""Small ctypes wrappers for the Windows APIs the launcher needs."""
import ctypes
import os
import uuid
from ctypes import wintypes
from pathlib import Path

FOLDERID_DOCUMENTS = "{FDD39AD0-238F-46AF-ADB4-6C85480369C7}"
FOLDERID_LOCAL_APP_DATA = "{F1B32785-6FBA-4FCF-9D55-7B8E7F157091}"

MB_OK = 0x0
MB_ICONERROR = 0x10
MB_ICONWARNING = 0x30
MB_SETFOREGROUND = 0x10000
MB_TOPMOST = 0x40000


class _GUID(ctypes.Structure):
    _fields_ = [("Data1", wintypes.DWORD), ("Data2", wintypes.WORD),
                ("Data3", wintypes.WORD), ("Data4", ctypes.c_ubyte * 8)]


def known_folder(folder_id):
    """SHGetKnownFolderPath: follows folder redirection (OneDrive, moved
    Documents) and returns the real, possibly non-ASCII, path."""
    guid = _GUID.from_buffer_copy(uuid.UUID(folder_id).bytes_le)
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    ole32 = ctypes.WinDLL("ole32")
    fn = shell32.SHGetKnownFolderPath
    fn.argtypes = [ctypes.POINTER(_GUID), wintypes.DWORD, wintypes.HANDLE,
                   ctypes.POINTER(ctypes.c_void_p)]
    fn.restype = ctypes.HRESULT
    ole32.CoTaskMemFree.argtypes = [ctypes.c_void_p]
    ole32.CoTaskMemFree.restype = None
    ptr = ctypes.c_void_p()
    try:
        fn(ctypes.byref(guid), 0, None, ctypes.byref(ptr))
        return Path(ctypes.wstring_at(ptr.value))
    finally:
        if ptr.value:
            ole32.CoTaskMemFree(ptr)


def documents_dir():
    return known_folder(FOLDERID_DOCUMENTS)


def local_app_data_dir():
    try:
        return known_folder(FOLDERID_LOCAL_APP_DATA)
    except OSError:
        env = os.environ.get("LOCALAPPDATA")
        if env:
            return Path(env)
        raise


def message_box(text, title, error=True):
    flags = MB_OK | MB_SETFOREGROUND | MB_TOPMOST | (MB_ICONERROR if error else MB_ICONWARNING)
    try:
        user32 = ctypes.WinDLL("user32")
        user32.MessageBoxW.argtypes = [wintypes.HWND, wintypes.LPCWSTR, wintypes.LPCWSTR, wintypes.UINT]
        user32.MessageBoxW.restype = ctypes.c_int
        user32.MessageBoxW(None, text, title, flags)
    except OSError:
        pass
