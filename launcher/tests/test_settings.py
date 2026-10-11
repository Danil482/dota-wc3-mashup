"""Tests of the Dota settings export (launcher/dvw_launcher/dota_settings.py).

Offline and synthetic: a fake Steam folder with three accounts and a tiny VPK
holding a cut-down cfg/dotakeys.lst are written to a scratch folder. Checked:
the KeyValues reader (comments, conditionals, a backslash key name), reading
one file from a VPK (inline data, preload data, a missing file), the account
choice (the running Steam's user, else the MostRecent login of
config/loginusers.vdf, else the newest settings), the player's keys over the
template (quick cast, modifiers, a key moved away from a template action, an
unbound action, an unknown key, another template), the settings, the exact
Preload script and its string contract, the same defaults as the map
(S.DEFAULTS in src/ui/dota_settings.lua), an unchanged file on a second run,
and no file when Dota has no settings. Never reads the real Steam folder.

Usage: python -I launcher/tests/test_settings.py [--work <scratch folder>]
"""
import argparse
import os
import re
import shutil
import struct
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "launcher"))

from dvw_launcher import dota_settings as ds  # noqa: E402

failures = []


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(name)


# ------------------------------------------------------------------ fixtures

TEMPLATES = """// cut-down cfg/dotakeys.lst
"DOTAKeys"
{
    "Commands" { "Ability" { "AbilityPrimary1" { "Action" "dota_ability_execute 0 1" } } }
    "Templates"
    {
        "ARROW"
        {
            "Name"  "ARROW"
            "Keys"
            {
                "HeroSelect"        { "Key" "F1" }
                "AbilityPrimary1"   { "Key" "Q" }
                "AbilityPrimary2"   { "Key" "W" }
                "AbilityPrimary3"   { "Key" "E" }
                "AbilitySecondary1" { "Key" "D" }
                "AbilitySecondary2" { "Key" "F" }
                "AbilityUltimate"   { "Key" "R" }
                "Inventory1" { "Key" "Z" }
                "Inventory2" { "Key" "X" }
                "Inventory3" { "Key" "C" }
                "Inventory4" { "Key" "V" }
                "Inventory5" { "Key" "B" }
                "Inventory6" { "Key" "N" }
                "InventoryTP" { "Key" "T" }
                "ShopToggle" { "Key" "F4" }
                "CourierSelect" { "Key" "F2" }
                "CourierDeliver" { "Key" "F3" }
            }
        }
        "LOL"
        {
            "Name"  "LOL"
            "Keys"
            {
                "AbilityPrimary1" { "Key" "Q" "Mode" "1" }
                "Inventory1" { "Key" "1" }
                "ShopToggle" { "Key" "P" }
                "HeroSelect" { "Key" "SPACE" }
            }
        }
    }
}
"""

# Quick cast on Q (the template's normal Q goes), D and F swapped, Alt+B for
# slot 5, slot 6 unbound but quick on Space, TP on B, shop on F5, hero on 1,
# the courier's Speed Burst on F7 and Grab All on F8 (the courier's select
# and deliver keys stay the template's F2 and F3), an unknown key on slot 3,
# a WC3-only key name and a conditional.
PERSONAL = """"KeyBindings"
{
    "Name"      "ARROW"
    "Version"   "12"
    "Keys"
    {
        "AbilityPrimary1QuickCast"   { "Key" "Q"  "Mode" "-1" }
        "AbilitySecondary1QuickCast" { "Key" "F"  "Mode" "-1" }
        "AbilitySecondary2QuickCast" { "Key" "D"  "Mode" "-1" }
        "Inventory3"                 { "Key" "MOUSE4" }
        "Inventory5"                 { "Key" "B"  "Modifier" "ALT"  "Mode" "0" }
        "Inventory6"                 { "Mode" "0" }
        "Inventory6QuickCast"        { "Key" "SPACE"  "Mode" "1" }
        "InventoryTP"                { "Key" "B"  "Mode" "0" }
        "ShopToggle"                 { "Key" "F5" }   // moved off F4
        "HeroSelect"                 { "Key" "1"  "Mode" "0" }  [$WIN32]
        "CourierBurst"               { "Key" "F7" }
        "GrabStashItems"             { "Key" "F8" }
        "Console"                    { "Key" "\\" }
    }
    "Items" { "item_blink" { "Mode" "1" } }
}
"""

CONVARS = """"config"
{
    "convars"
    {
        "\\"                                     "toggleconsole"
        "dota_player_units_auto_attack_mode"    "0"
        "dota_ability_quick_cast"               "true"
        "dota_item_double_tap_self_cast"        "false"
        "dota_ability_self_cast_timeout"        "1.250000"
        "dota_camera_disable_zoom"              "true"
        "dota_reset_camera_on_spawn"            "false"
        "dota_camera_speed"                     "3000.000000"
        "dota_quickcast_onkeydown"              "false"
        "dota_summoned_units_auto_attack_mode_2" "-1"
        "dota_disable_autoattack_during_stop"   "true"
        "dota_toggle_autoattack_automatically_during_orders" "false"
        "dota_force_right_click_attack"         "2"
    }
}
"""

EXPECTED = ("v=1;a1=81q;a2=87;a3=69;a4=70q;a5=68q;a6=82;i1=90;i2=88;i3=;i4=86;i5=66-4;i6=32q;tp=66;"
            "sh=116;hs=49;cs=113;cv=114;cb=118;ch=;gs=119;aa=0;as=-1;ds=1;ta=0;fr=2;dt=1;di=0;to=1.25;qd=0;zl=1;rs=0")


def make_vpk(path, files, inline=True):
    """A VPK v2 directory file; with inline=False the data is preload data."""
    tree = bytearray()
    blob = bytearray()
    by_ext = {}
    for name, data in files.items():
        folder, _, base = name.rpartition("/")
        base, _, ext = base.rpartition(".")
        by_ext.setdefault(ext, {}).setdefault(folder or " ", []).append((base, data))
    for ext, folders in by_ext.items():
        tree += ext.encode() + b"\0"
        for folder, entries in folders.items():
            tree += folder.encode() + b"\0"
            for base, data in entries:
                tree += base.encode() + b"\0"
                if inline:
                    tree += struct.pack("<IHHIIH", 0, 0, 0x7FFF, len(blob), len(data), 0xFFFF)
                    blob += data
                else:
                    tree += struct.pack("<IHHIIH", 0, len(data), 0x7FFF, 0, 0, 0xFFFF) + data
            tree += b"\0"
        tree += b"\0"
    tree += b"\0"
    header = struct.pack("<IIIIIII", 0x55AA1234, 2, len(tree), len(blob), 0, 0, 0)
    Path(path).write_bytes(header + bytes(tree) + bytes(blob))


def write(path, text, mtime=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    if mtime:
        os.utime(path, (mtime, mtime))


def make_steam(work):
    """Fake Steam: account 101 (old settings), 202 (newest), 303 (no Dota)."""
    steam = work / "Steam"
    now = time.time()
    old = steam / "userdata" / "101" / "570"
    write(old / "remote" / "cfg" / "dotakeys_personal.lst", '"KeyBindings" { "Name" "LOL" "Keys" { } }', now - 3600)
    new = steam / "userdata" / "202" / "570"
    write(new / "remote" / "cfg" / "dotakeys_personal.lst", PERSONAL, now - 60)
    write(new / "remote" / "user_convars.vcfg", CONVARS, now - 60)
    # an older local copy with other values: the newest file wins
    write(new / "local" / "cfg" / "user_convars_0_slot0.vcfg", CONVARS.replace('"0"', '"2"', 1), now - 7200)
    (steam / "userdata" / "303" / "7").mkdir(parents=True)
    dota = steam / "steamapps" / "common" / "dota 2 beta"
    (dota / "game" / "dota").mkdir(parents=True)
    vpk = dota / "game" / "dota" / "pak01_dir.vpk"
    make_vpk(vpk, {"cfg/dotakeys.lst": TEMPLATES.encode(), "scripts/other.txt": b"x"})
    return steam, dota, vpk


# ------------------------------------------------------------------ tests

def test_kv():
    root = ds.parse_kv(PERSONAL + CONVARS)
    keys = ds.get(ds.get(root, "KeyBindings"), "Keys")
    check("kv: nested sections", ds.get(ds.get(keys, "ShopToggle"), "Key") == "F5")
    check("kv: conditional and comment skipped", ds.get(ds.get(keys, "HeroSelect"), "Mode") == "0")
    check("kv: backslash key name", ds.get(ds.get(keys, "Console"), "Key") == "\\")
    convars = ds.get(ds.get(root, "config"), "convars")
    check("kv: backslash key keeps the next pair", ds.get(convars, "\\") == "toggleconsole"
          and ds.get(convars, "dota_camera_speed") == "3000.000000")
    check("kv: case-insensitive lookup", ds.get(root, "keybindings") is not None)


def test_vpk(work):
    vpk = work / "inline_dir.vpk"
    make_vpk(vpk, {"cfg/a.lst": b"alpha", "cfg/b.lst": b"beta", "root.txt": b"top"})
    check("vpk: inline data", ds.vpk_file(vpk, "cfg/b.lst") == b"beta")
    check("vpk: root folder", ds.vpk_file(vpk, "root.txt") == b"top")
    check("vpk: missing file", ds.vpk_file(vpk, "cfg/c.lst") is None)
    pre = work / "preload_dir.vpk"
    make_vpk(pre, {"cfg/dotakeys.lst": b"gamma"}, inline=False)
    check("vpk: preload data", ds.vpk_file(pre, "cfg/dotakeys.lst") == b"gamma")
    bad = work / "bad_dir.vpk"
    bad.write_bytes(b"\0" * 32)
    try:
        ds.vpk_file(bad, "cfg/a.lst")
        check("vpk: bad signature refused", False)
    except ValueError:
        check("vpk: bad signature refused", True)


def write_logins(steam, recent, key="MostRecent"):
    """A synthetic config/loginusers.vdf: accounts 101, 202 and 303, `recent` marked."""
    users = "".join(f'    "{ds.STEAMID64_BASE + a}" {{ "AccountName" "user{a}" "{key}" "{int(a == recent)}" '
                    f'"Timestamp" "{1700000000 + a}" }}\n' for a in (101, 202, 303))
    write(steam / "config" / "loginusers.vdf", '"users"\n{\n' + users + "}\n")


def test_accounts(steam):
    check("account: newest settings", ds.find_account([steam]).parent.name == "202")
    write_logins(steam, 101)
    check("account: the MostRecent login, not the newest settings", ds.find_account([steam]).parent.name == "101")
    check("account: MostRecent read as an account id", ds.recent_account(steam) == 101, ds.recent_account(steam))
    write_logins(steam, 101, key="mostrecent")
    check("account: MostRecent in any case", ds.find_account([steam]).parent.name == "101")
    ds._registry = lambda path, name: 202 if name == "ActiveUser" else None
    check("account: the running Steam's user before MostRecent", ds.find_account([steam]).parent.name == "202")
    ds._registry = lambda path, name: 0 if name == "ActiveUser" else None
    check("account: Steam not running, MostRecent", ds.find_account([steam]).parent.name == "101")
    write_logins(steam, 303)
    check("account: MostRecent without Dota settings, the newest", ds.find_account([steam]).parent.name == "202")
    write_logins(steam, 101, key="AutoLogin")
    check("account: AutoLogin of current Steam clients", ds.find_account([steam]).parent.name == "101")
    write_logins(steam, None)
    check("account: else the newest login timestamp", ds.recent_account(steam) == 303
          and ds.find_account([steam]).parent.name == "202")
    (steam / "config" / "loginusers.vdf").unlink()
    ds._registry = lambda path, name: None
    ds._registry = lambda path, name: 101 if name == "ActiveUser" else None
    check("account: the signed-in user first", ds.find_account([steam]).parent.name == "101")
    ds._registry = lambda path, name: 303 if name == "ActiveUser" else None
    check("account: signed-in user without Dota settings", ds.find_account([steam]).parent.name == "202")
    ds._registry = lambda path, name: None
    check("account: none without userdata", ds.find_account([steam / "steamapps"]) is None)


def test_roots(steam, dota):
    saved = os.environ.get("ProgramFiles(x86)")
    os.environ["ProgramFiles(x86)"] = str(steam.parent / "nowhere")
    try:
        check("roots: the library Dota is in", ds.steam_roots(dota) == [steam], len(ds.steam_roots(dota)))
        ds._registry = lambda path, name: str(steam).replace("\\", "/") if name == "SteamPath" else None
        check("roots: Steam's own path, once", ds.steam_roots(dota) == [Path(str(steam).replace("\\", "/"))])
    finally:
        ds._registry = lambda path, name: None
        if saved is None:
            os.environ.pop("ProgramFiles(x86)", None)
        else:
            os.environ["ProgramFiles(x86)"] = saved


def test_keys(steam, vpk):
    app = steam / "userdata" / "202" / "570"
    keys, name, from_vpk = ds.read_keybinds(app, vpk)
    check("keys: template from the VPK", name == "ARROW" and from_vpk)
    check("keys: quick cast replaces the template's normal key", keys["a1"] == "81q", keys["a1"])
    check("keys: swapped D and F", keys["a4"] == "70q" and keys["a5"] == "68q", (keys["a4"], keys["a5"]))
    check("keys: modifier", keys["i5"] == "66-4", keys["i5"])
    check("keys: unbound normal, quick on Space", keys["i6"] == "32q", keys["i6"])
    check("keys: unknown key unbinds", keys["i3"] == "", keys["i3"])
    check("keys: TP moved to B", keys["tp"] == "66" and keys["sh"] == "116" and keys["hs"] == "49")
    check("keys: courier select and deliver from the template", keys["cs"] == "113" and keys["cv"] == "114",
          (keys["cs"], keys["cv"]))
    check("keys: Speed Burst and Grab All bound, Shield unbound", keys["cb"] == "118" and keys["gs"] == "119"
          and keys["ch"] == "", (keys["cb"], keys["gs"], keys["ch"]))
    lol, name, _ = ds.read_keybinds(steam / "userdata" / "101" / "570", vpk)
    check("keys: another template", name == "LOL" and lol["i1"] == "49" and lol["i2"] == "", (lol["i1"], lol["i2"]))
    check("keys: template mode 1 is quick cast", lol["a1"] == "81q", lol["a1"])
    fallback, _, from_vpk = ds.read_keybinds(app, None)
    check("keys: built-in ARROW without the VPK", not from_vpk and fallback["i6"] == "32q" and fallback["a2"] == "87")


def test_defaults_match_map(vpk):
    defaults, _ = ds.template_keys(vpk, "ARROW")
    ours = ds.key_fields(ds.resolve(defaults, {}))
    builtin = ds.key_fields(ds.resolve(ds.template_keys(None, "ARROW")[0], {}))
    text = (ROOT / "src" / "ui" / "dota_settings.lua").read_text(encoding="utf-8")
    m = re.search(r'S\.DEFAULTS = "([^"]*)"\s*\.\.\s*"([^"]*)"', text)
    lua = dict(kv.split("=", 1) for kv in (m.group(1) + m.group(2)).strip(";").split(";")) if m else {}
    check("defaults: the map's S.DEFAULTS keys are Dota's ARROW layout",
          all(lua.get(f) == ours[f] for f in ds.KEY_FIELDS), {f: (lua.get(f), ours[f]) for f in ds.KEY_FIELDS
                                                               if lua.get(f) != ours[f]})
    check("defaults: built-in copy equals the template", builtin == ours)


def test_export(steam, dota, vpk, work):
    out = work / "CustomMapData" / "DotaVsWarcraft"
    summary = ds.export(dota, vpk, out, roots=[steam])
    path = out / ds.FILE_NAME
    check("export: summary without the account", summary is not None and "202" not in summary, summary)
    raw = path.read_bytes()
    check("export: ASCII only", raw.decode("ascii", "replace").encode("ascii") == raw)
    text = raw.decode("ascii")
    calls = re.findall(r'call BlzSetAbilityTooltip\((\d+), "([^"]*)", (\d+)\)', text)
    check("export: one stash call", len(calls) == 1 and calls[0][0] == "1095656547" and calls[0][2] == "0", calls)
    check("export: exact Preload script", text == ("function PreloadFiles takes nothing returns nothing\r\n\r\n"
                                                    "\tcall PreloadStart()\r\n"
                                                    f'\tcall BlzSetAbilityTooltip(1095656547, "{EXPECTED}", 0)\r\n'
                                                    "\tcall PreloadEnd( 0.0 )\r\n\r\nendfunction\r\n"))
    data = calls[0][1] if calls else ""
    check("export: settings string", data == EXPECTED, data)
    check("export: string contract", re.fullmatch(r"[A-Za-z0-9=;.\-]*", data) is not None and len(data) <= 250)
    before = path.stat().st_mtime_ns
    time.sleep(0.05)
    ds.export(dota, vpk, out, roots=[steam])
    check("export: unchanged file kept", path.stat().st_mtime_ns == before)
    check("export: no temporary files", [p.name for p in out.iterdir()] == [ds.FILE_NAME])
    empty = work / "empty"
    (empty / "userdata").mkdir(parents=True)
    out2 = work / "none"
    check("export: no Dota settings, no file", ds.export(dota, vpk, out2, roots=[empty]) is None
          and not out2.exists())
    try:
        ds.encode({"v": "1", "a1": 'x"'})
        check("export: quote refused", False)
    except ValueError:
        check("export: quote refused", True)
    # every key on its longest binding: the file still takes it, and what the
    # map sends to the other players (dota_settings.lua syncPayload: the key
    # fields and aa as ds ta fr di to qd) fits BlzSendSyncData's 255 bytes
    worst = {"v": "1", **{f: "222-7q" for f in ds.KEY_FIELDS}, "aa": "2", "as": "-1", "ds": "1", "ta": "1",
             "fr": "2", "dt": "1", "di": "1", "to": "1.25", "qd": "1", "zl": "1", "rs": "1", "cd": "2500"}
    try:
        full = ds.encode(worst)
        check("export: the longest bindings fit the file", len(full) <= ds.MAX_DATA, len(full))
    except ValueError as e:
        check("export: the longest bindings fit the file", False, e)
    synced = ";".join(f"{k}={worst[k]}" for k in ["v", *ds.KEY_FIELDS, "aa", "as", "ds", "ta", "fr", "di", "to", "qd"])
    check("export: the synced part fits one sync message", len(synced) <= 255, len(synced))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work", help="scratch folder (default: a temporary one)")
    args = ap.parse_args()
    work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="dvw_settings_"))
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    ds._registry = lambda path, name: None          # never the real Steam
    try:
        steam, dota, vpk = make_steam(work)
        test_kv()
        test_vpk(work)
        test_accounts(steam)
        test_roots(steam, dota)
        test_keys(steam, vpk)
        test_defaults_match_map(vpk)
        test_export(steam, dota, vpk, work)
    finally:
        if not args.work:
            shutil.rmtree(work, ignore_errors=True)
    print(f"{len(failures)} failed" if failures else "all passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
