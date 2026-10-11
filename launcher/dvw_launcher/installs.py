"""Locate the Dota 2 and Warcraft III installs given on the command line."""
import re
from pathlib import Path

WC3_EXE = Path("_retail_") / "x86_64" / "Warcraft III.exe"
DOTA_VPK = Path("game") / "dota" / "pak01_dir.vpk"


class InstallError(Exception):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def dota_root(path):
    """Accept the Dota 2 root ('dota 2 beta') or its game / game\\dota folder."""
    p = Path(path)
    if not p.is_dir():
        raise InstallError("dota_missing", f"Dota 2 folder not found: {p}")
    for candidate in (p, p.parent, p.parent.parent):
        if (candidate / "game" / "dota").is_dir():
            return candidate
    raise InstallError("dota_missing", f"This is not a Dota 2 folder (no game\\dota inside): {p}")


def dota_vpk(root):
    vpk = root / DOTA_VPK
    if not vpk.is_file():
        raise InstallError("vpk_missing", f"Dota 2 game data not found: {vpk}")
    return vpk


def _sanitize(build):
    return re.sub(r"[^A-Za-z0-9._-]", "_", build)[:64]


def dota_build_id(root):
    """Steam build id from steamapps\\appmanifest_570.acf; falls back to the
    client version in game\\dota\\steam.inf. Returns (id, source)."""
    for steamapps in (root.parent.parent, root.parent, root.parent.parent.parent):
        acf = steamapps / "appmanifest_570.acf"
        if acf.is_file():
            text = acf.read_text(encoding="utf-8", errors="replace")
            m = re.search(r'"buildid"\s+"(\d+)"', text)
            if m:
                return m.group(1), str(acf)
    inf = root / "game" / "dota" / "steam.inf"
    if inf.is_file():
        values = dict(re.findall(r"^\s*(\w+)\s*=\s*(.*?)\s*$", inf.read_text(encoding="utf-8", errors="replace"),
                                 re.MULTILINE))
        version = values.get("ClientVersion") or values.get("PatchVersion")
        if version:
            revision = values.get("SourceRevision", "")
            return _sanitize(f"inf-{version}" + (f"-{revision}" if revision else "")), str(inf)
    return None, None


def wc3_root(path):
    """Accept the Warcraft III root or its _retail_ / _retail_\\x86_64 folder."""
    p = Path(path)
    if p.is_file() and p.name.lower() == "warcraft iii.exe":
        p = p.parent
    for candidate in (p, p.parent, p.parent.parent):
        if (candidate / WC3_EXE).is_file():
            return candidate
    raise InstallError("wc3_missing", f"Warcraft III not found (no {WC3_EXE} in {p})")


def is_inside(child, parent):
    try:
        child = Path(child).resolve()
        parent = Path(parent).resolve()
    except OSError:
        return False
    return child == parent or parent in child.parents
