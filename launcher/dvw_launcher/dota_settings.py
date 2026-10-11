"""The player's Dota 2 settings for the map: keybinds, quick cast, double-tap
self cast, camera and auto attack.

Dota keeps them per Steam account, read here and never changed:
    <Steam>\\userdata\\<account>\\570\\remote\\cfg\\dotakeys_personal.lst   keybinds (KeyValues)
    <Steam>\\userdata\\<account>\\570\\remote\\user_convars.vcfg            settings (KeyValues)
    (local\\cfg\\user_convars_0_slot0.vcfg is the same file before Steam Cloud)
The keybind file lists the player's entries over a template (its "Name",
usually ARROW) from cfg/dotakeys.lst in the Dota 2 VPK.

Output contract, read by src/ui/dota_settings.lua. It is never part of the
map, since every player in a lobby needs the same map file:
    Documents\\Warcraft III\\CustomMapData\\DotaVsWarcraft\\dota_settings.txt
A Preload script, shaped like the files the game writes itself, that stores
the settings in the tooltip of the unused ability 'ANdc':
    function PreloadFiles takes nothing returns nothing
        call PreloadStart()
        call BlzSetAbilityTooltip(1095656547, "v=1;a1=81q;...", 0)
        call PreloadEnd( 0.0 )
    endfunction
The string is ';'-separated key=value pairs of letters, digits, '.' and '-':
    v       format version (1)
    a1..a6  Dota's ability slots Q W E D F R (Primary1-3, Secondary1-2, Ultimate)
    i1..i6  inventory slots; tp TP scroll; sh shop; hs select hero
    cs, cv  select the courier, deliver items; cb, ch the courier's Speed
            Burst and Shield; gs the stash's Grab All
            "<vk>[-<meta>][q]": Windows virtual-key code (the WC3 oskeytype),
            WC3 meta bits (1 shift, 2 ctrl, 4 alt), q quick cast; empty: unbound
    aa      auto attack: 0 never, 1 standard, 2 always
    as      summoned units' auto attack: -1 same as the hero, else as aa
    ds      no auto attack while Stop is held (0 or 1)
    ta      Hold forces Never, Stop forces Always until an attack order (0 or 1)
    fr      right-click on allies: 0 follow, 1 attack, 2 deny when deniable
    dt, di  double-tap self cast for abilities / items (0 or 1)
    to      double-tap timeout, seconds
    qd      quick cast fires on key press (1) or on key release (0)
    zl      camera zoom disabled (0 or 1)
    rs      centre the camera on the hero at respawn (0 or 1)
    cd      camera distance, only when the player set one
A missing key means Dota's default.
"""
import os
import re
import struct
import winreg
from pathlib import Path

FILE_NAME = "dota_settings.txt"
VERSION = "1"
STASH = 1095656547          # FourCC('ANdc'), Dark Conversion: not in the map
# The launcher writes the Preload file itself, so the game's cut of long
# Preload lines does not apply; the part of the string the map sends to the
# other players (src/ui/dota_settings.lua syncPayload) stays within
# BlzSendSyncData's 255 bytes even when every key has modifiers.
MAX_DATA = 300

# map field -> Dota's normal action, quick-cast action
KEY_FIELDS = {
    "a1": ("AbilityPrimary1", "AbilityPrimary1QuickCast"),
    "a2": ("AbilityPrimary2", "AbilityPrimary2QuickCast"),
    "a3": ("AbilityPrimary3", "AbilityPrimary3QuickCast"),
    "a4": ("AbilitySecondary1", "AbilitySecondary1QuickCast"),
    "a5": ("AbilitySecondary2", "AbilitySecondary2QuickCast"),
    "a6": ("AbilityUltimate", "AbilityUltimateQuickCast"),
    "i1": ("Inventory1", "Inventory1QuickCast"),
    "i2": ("Inventory2", "Inventory2QuickCast"),
    "i3": ("Inventory3", "Inventory3QuickCast"),
    "i4": ("Inventory4", "Inventory4QuickCast"),
    "i5": ("Inventory5", "Inventory5QuickCast"),
    "i6": ("Inventory6", "Inventory6QuickCast"),
    "tp": ("InventoryTP", "InventoryTPQuickCast"),
    "sh": ("ShopToggle", None),
    "hs": ("HeroSelect", None),
    "cs": ("CourierSelect", None),
    "cv": ("CourierDeliver", None),
    "cb": ("CourierBurst", None),
    "ch": ("CourierShield", None),
    "gs": ("GrabStashItems", None),
}
# Names and labels as in Dota's settings panel (panorama popup_settings_reborn)
FLAGS = {"dt": "dota_ability_quick_cast",            # "Double Tap Ability to Self Cast", not quick cast
         "di": "dota_item_double_tap_self_cast",
         "qd": "dota_quickcast_onkeydown",           # "Quickcast triggers on key press by default"
         "ds": "dota_disable_autoattack_during_stop",
         "ta": "dota_toggle_autoattack_automatically_during_orders",
         "zl": "dota_camera_disable_zoom",
         "rs": "dota_reset_camera_on_spawn"}
MODES = {"aa": ("dota_player_units_auto_attack_mode", (0, 1, 2)),
         "as": ("dota_summoned_units_auto_attack_mode_2", (-1, 0, 1, 2)),
         "fr": ("dota_force_right_click_attack", (0, 1, 2))}
ORDER = ["v", *KEY_FIELDS, "aa", "as", "ds", "ta", "fr", "dt", "di", "to", "qd", "zl", "rs", "cd"]
STEAMID64_BASE = 76561197960265728

# Dota's ARROW template for the actions above, when the VPK's copy is unreadable
ARROW = {"AbilityPrimary1": "Q", "AbilityPrimary2": "W", "AbilityPrimary3": "E", "AbilitySecondary1": "D",
         "AbilitySecondary2": "F", "AbilityUltimate": "R", "Inventory1": "Z", "Inventory2": "X",
         "Inventory3": "C", "Inventory4": "V", "Inventory5": "B", "Inventory6": "N", "InventoryTP": "T",
         "ShopToggle": "F4", "HeroSelect": "F1", "CourierSelect": "F2", "CourierDeliver": "F3"}

# Dota (Source 2) key names -> Windows virtual-key codes. Enter, Escape, mouse
# buttons and lone modifiers are left out: the map never binds them.
VK = {**{c: ord(c) for c in "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"},
      **{f"F{i}": 0x6F + i for i in range(1, 13)},
      **{f"KP_{i}": 0x60 + i for i in range(10)},
      "KP_INS": 0x60, "KP_END": 0x61, "KP_DOWNARROW": 0x62, "KP_PGDN": 0x63, "KP_LEFTARROW": 0x64,
      "KP_RIGHTARROW": 0x66, "KP_HOME": 0x67, "KP_UPARROW": 0x68, "KP_PGUP": 0x69,
      "KP_MULTIPLY": 0x6A, "KP_PLUS": 0x6B, "KP_MINUS": 0x6D, "KP_DEL": 0x6E, "KP_SLASH": 0x6F,
      "SPACE": 0x20, "TAB": 0x09, "BACKSPACE": 0x08, "CAPSLOCK": 0x14, "PAUSE": 0x13,
      "INS": 0x2D, "DEL": 0x2E, "HOME": 0x24, "END": 0x23, "PGUP": 0x21, "PGDN": 0x22,
      "UPARROW": 0x26, "DOWNARROW": 0x28, "LEFTARROW": 0x25, "RIGHTARROW": 0x27,
      "SEMICOLON": 0xBA, ";": 0xBA, "=": 0xBB, ",": 0xBC, "-": 0xBD, ".": 0xBE, "/": 0xBF,
      "`": 0xC0, "KEY_CYRILLIC_IO": 0xC0, "[": 0xDB, "\\": 0xDC, "]": 0xDD, "'": 0xDE, "APOSTROPHE": 0xDE}
META = {"SHIFT": 1, "CTRL": 2, "ALT": 4}

SETTINGS_FILES = (Path("remote") / "cfg" / "dotakeys_personal.lst", Path("remote") / "user_convars.vcfg",
                  Path("local") / "cfg" / "user_convars_0_slot0.vcfg")


# ------------------------------------------------------------------ KeyValues

_TOKEN = re.compile(r'\s+|//[^\n]*|"([^"]*)"|(\{)|(\})|\[[^\]\n]*\]|([^\s{}"\[\]]+)')


def parse_kv(text):
    """KeyValues text -> [(key, value)], each value a str or such a list.
    Valve's files are read without escape sequences: "\\" is a key name."""
    stack = [[]]
    key = None
    for m in _TOKEN.finditer(text):
        quoted, opened, closed, bare = m.groups()
        if opened:
            node = []
            stack[-1].append((key or "", node))
            stack.append(node)
            key = None
        elif closed:
            if len(stack) > 1:
                stack.pop()
            key = None
        elif quoted is not None or bare is not None:
            token = quoted if quoted is not None else bare
            if key is None:
                key = token
            else:
                stack[-1].append((key, token))
                key = None
    return stack[0]


def get(node, name):
    if not isinstance(node, list):
        return None
    name = name.lower()
    for key, value in node:
        if key.lower() == name:
            return value
    return None


def read_text(path):
    return Path(path).read_bytes().decode("utf-8", "replace")


# ------------------------------------------------------------------ VPK

def vpk_file(vpk, wanted):
    """Bytes of one file from a VPK (v1/v2) and its archives, or None."""
    vpk = Path(vpk)
    with open(vpk, "rb") as f:
        signature, version, tree_length = struct.unpack("<III", f.read(12))
        if signature != 0x55AA1234 or version not in (1, 2):
            raise ValueError(f"{vpk.name}: not a VPK")
        header = 28 if version == 2 else 12
        f.seek(header)
        tree = f.read(tree_length)
    folder, _, name = wanted.rpartition("/")
    name, _, ext = name.rpartition(".")
    want = (ext, folder or " ", name)

    def cstring(p):
        end = tree.index(b"\0", p)
        return tree[p:end].decode("utf-8", "replace"), end + 1

    pos = 0
    while True:
        e, pos = cstring(pos)
        if not e:
            return None
        while True:
            d, pos = cstring(pos)
            if not d:
                break
            while True:
                n, pos = cstring(pos)
                if not n:
                    break
                _crc, preload, archive, offset, length, _end = struct.unpack_from("<IHHIIH", tree, pos)
                start, pos = pos + 18, pos + 18 + preload
                if (e, d, n) != want:
                    continue
                data = tree[start:pos]
                if length:
                    if archive == 0x7FFF:
                        source, offset = vpk, header + tree_length + offset
                    else:
                        source = vpk.with_name(vpk.name.replace("_dir.vpk", f"_{archive:03d}.vpk"))
                    with open(source, "rb") as f:
                        f.seek(offset)
                        data += f.read(length)
                return data


# ------------------------------------------------------------------ Steam account

def _registry(path, name):
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, path) as key:
            return winreg.QueryValueEx(key, name)[0]
    except OSError:
        return None


def steam_roots(dota_root):
    """Steam installs that may hold userdata: Steam's own path, the library
    Dota is in, the default folder."""
    candidates = [_registry(r"Software\Valve\Steam", "SteamPath"), *Path(dota_root).parents,
                  Path(os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")) / "Steam"]
    roots, seen = [], set()
    for c in candidates:
        if not c or not (Path(c) / "userdata").is_dir():
            continue
        key = os.path.normcase(os.path.abspath(c))
        if key not in seen:
            seen.add(key)
            roots.append(Path(c))
    return roots


def _newest(app):
    times = [(app / f).stat().st_mtime for f in SETTINGS_FILES if (app / f).is_file()]
    return max(times) if times else None


def recent_account(root):
    """Account id (SteamID64 - 76561197960265728) of the user who signed in to
    Steam last, from config\\loginusers.vdf: MostRecent=1 (older clients), else
    AutoLogin=1 (current clients), else the newest login timestamp. None
    without the file."""
    path = Path(root) / "config" / "loginusers.vdf"
    if not path.is_file():
        return None
    best = None
    for steamid, entry in get(parse_kv(read_text(path)), "users") or []:
        if isinstance(entry, list) and steamid.isdigit() and int(steamid) > STEAMID64_BASE:
            rank = (bool(_bool(get(entry, "MostRecent"))), bool(_bool(get(entry, "AutoLogin"))),
                    _int(get(entry, "Timestamp"), 0))
            if best is None or rank > best[0]:
                best = (rank, int(steamid) - STEAMID64_BASE)
    return best[1] if best else None


def find_account(roots):
    """Dota's folder (userdata\\<account>\\570) of the Steam user signed in: the
    running Steam's active user, else the last login. Only when neither has
    Dota settings, the account whose settings changed last."""
    wanted = [_registry(r"Software\Valve\Steam\ActiveProcess", "ActiveUser"), *map(recent_account, roots)]
    found, by_account = [], {}
    for root in roots:
        for app in sorted((Path(root) / "userdata").glob("*/570")):
            t = _newest(app)
            if t is not None:
                found.append((t, str(app), app))
                by_account.setdefault(app.parent.name, app)
    for account in wanted:
        if account and str(account) in by_account:
            return by_account[str(account)]
    return max(found)[2] if found else None


# ------------------------------------------------------------------ keybinds

def _entries(node):
    return {k: {f: v for f, v in e if isinstance(v, str)} for k, e in (node or []) if isinstance(e, list)}


def _int(v, default=None):
    try:
        return int(float(v))
    except (TypeError, ValueError):
        return default


def _combo(entry):
    """(vk, meta, mode) of one binding, None when it has no usable key."""
    vk = VK.get((entry.get("Key") or "").upper())
    if vk is None:
        return None
    meta = sum(bit for name, bit in META.items() if name in (entry.get("Modifier") or "").upper())
    return vk, meta, _int(entry.get("Mode"), -1)


def template_keys(vpk, name):
    """Actions of a keybind template from the VPK's cfg/dotakeys.lst; Dota's
    ARROW layout when the file cannot be read."""
    data = None
    if vpk:
        try:
            data = vpk_file(vpk, "cfg/dotakeys.lst")
        except (OSError, ValueError, struct.error):
            data = None
    if data:
        templates = get(get(parse_kv(data.decode("utf-8", "replace")), "DOTAKeys"), "Templates")
        keys = _entries(get(get(templates, name) or get(templates, "ARROW"), "Keys"))
        if keys:
            return keys, True
    return {action: {"Key": key} for action, key in ARROW.items()}, False


def resolve(template, personal):
    """{action: (vk, meta, mode)}: the player's entries over the template. An
    entry without a key unbinds its action; a key the player bound leaves the
    template action that had it."""
    out = {action: (_combo(e), False) for action, e in template.items()}
    out.update({action: (_combo(e), True) for action, e in personal.items()})
    explicit = {combo[:2] for combo, mine in out.values() if mine and combo}
    return {a: combo for a, (combo, mine) in out.items() if combo and (mine or combo[:2] not in explicit)}


def key_fields(bindings):
    """Map fields from resolved bindings: the quick-cast binding or the normal
    one, preferring a key without modifiers."""
    out = {}
    for field, (normal, quick) in KEY_FIELDS.items():
        options = []
        if quick and quick in bindings:
            vk, meta, _ = bindings[quick]
            options.append((meta != 0, 0, vk, meta, True))
        if normal in bindings:
            vk, meta, mode = bindings[normal]
            options.append((meta != 0, 1, vk, meta, mode in (1, 2)))
        if options:
            _, _, vk, meta, q = min(options)
            out[field] = f"{vk}" + (f"-{meta}" if meta else "") + ("q" if q else "")
        else:
            out[field] = ""
    return out


def read_keybinds(app, vpk):
    """(fields, template name, template read from the VPK)."""
    path = app / "remote" / "cfg" / "dotakeys_personal.lst"
    root = get(parse_kv(read_text(path)), "KeyBindings") if path.is_file() else None
    name = get(root, "Name")
    name = name if isinstance(name, str) and name else "ARROW"
    template, from_vpk = template_keys(vpk, name)
    return key_fields(resolve(template, _entries(get(root, "Keys")))), name, from_vpk


# ------------------------------------------------------------------ settings

def read_convars(app):
    paths = [p for p in (app / "remote" / "user_convars.vcfg", app / "local" / "cfg" / "user_convars_0_slot0.vcfg")
             if p.is_file()]
    if not paths:
        return {}
    newest = max(paths, key=lambda p: p.stat().st_mtime)
    convars = get(get(parse_kv(read_text(newest)), "config"), "convars")
    return {k: v for k, v in (convars or []) if isinstance(v, str)}


def _bool(v):
    v = (v or "").strip().lower()
    if v in ("1", "true"):
        return True
    if v in ("0", "false"):
        return False
    return None


def _float(v):
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def setting_fields(convars):
    out = {}
    for field, (name, allowed) in MODES.items():
        v = _int(convars.get(name))
        if v in allowed:
            out[field] = str(v)
    for field, name in FLAGS.items():
        b = _bool(convars.get(name))
        if b is not None:
            out[field] = "1" if b else "0"
    t = _float(convars.get("dota_ability_self_cast_timeout"))
    if t is not None:
        out["to"] = f"{round(min(2.0, max(0.0, t)), 2):g}"
    d = _float(convars.get("dota_camera_distance"))
    if d is not None:
        out["cd"] = str(round(min(2500.0, max(600.0, d))))
    return out


# ------------------------------------------------------------------ output

def encode(values):
    data = ";".join(f"{k}={values[k]}" for k in ORDER if k in values)
    if not re.fullmatch(r"[A-Za-z0-9=;.\-]*", data) or len(data) > MAX_DATA:
        raise ValueError(f"settings string out of contract ({len(data)} chars)")
    return data


def preload_script(data):
    """The statements of a file the game writes with PreloadGenEnd, around ours."""
    return ("function PreloadFiles takes nothing returns nothing\r\n\r\n\tcall PreloadStart()\r\n"
            f'\tcall BlzSetAbilityTooltip({STASH}, "{data}", 0)\r\n'
            "\tcall PreloadEnd( 0.0 )\r\n\r\nendfunction\r\n")


def export(dota_root, vpk, out_dir, roots=None):
    """Writes out_dir\\dota_settings.txt from the player's Dota settings.
    Returns a one-line summary, or None when no Dota settings were found."""
    app = find_account(steam_roots(dota_root) if roots is None else roots)
    if app is None:
        return None
    keys, template, from_vpk = read_keybinds(app, vpk)
    values = {"v": VERSION, **keys, **setting_fields(read_convars(app))}
    script = preload_script(encode(values)).encode("ascii")
    path = Path(out_dir) / FILE_NAME
    path.parent.mkdir(parents=True, exist_ok=True)
    if not (path.is_file() and path.read_bytes() == script):
        tmp = path.with_name(f"{path.name}.tmp{os.getpid()}")
        tmp.write_bytes(script)
        os.replace(tmp, path)
    bound = sum(1 for f in KEY_FIELDS if keys[f])
    settings = len(values) - 1 - len(KEY_FIELDS)
    return (f"{bound} keys over the {template} layout{'' if from_vpk else ' (built-in copy)'}, "
            f"{settings} settings -> {FILE_NAME}")
