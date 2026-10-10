"""Generate object data and gameplay constants for the map.

Outputs build/objects.json ({"war3map.w3u": base64, ...}, read by build_map.js)
and src/data/ids.json (raw codes the Lua script looks up by name).
Dota numbers come from src/data/heroes.json; WC3-side choices (stand-in
models, ability object kinds, tooltips) from specs/heroes/<hero>.json.
"""
import base64
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import w3obj  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(ROOT, "src", "data")

ICON = "ReplaceableTextures\\CommandButtons\\BTNDota_{}.blp"
ORDERS = ["acidbomb", "ancestralspirit", "animatedead", "antimagicshell", "blackarrow",
          "breathoffire", "carrionswarm", "chainlightning", "clusterrockets", "controlmagic",
          "cripple", "curse"]
# Dota's keys by command card cell, so a hotkey never repeats on one card
# (M S H A P O belong to the WC3 commands).
CELL_KEYS = {(0, 2): "Q", (1, 2): "W", (2, 2): "E", (3, 2): "R", (1, 1): "D", (2, 1): "F", (0, 1): "G", (3, 1): "T"}
MODELS = {}
STANDINS = True


def load(name):
    with open(os.path.join(DATA, name), encoding="utf-8") as f:
        return json.load(f)


def load_models():
    """specs/models.json: Dota models converted by the launcher on the player's PC,
    {unit key: {"model": <map path of the .mdx>, "scale": 1.0}}. Keys are
    "hero_<hero>" for heroes and the structure/creep keys used in structures()."""
    path = os.path.join(ROOT, "specs", "models.json")
    if not os.path.exists(path):
        return {}
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def apply_model(fields, models, key):
    m = models.get(key)
    if m:
        fields["umdl"] = m["model"]
        # Units/UnitSkin.txt gives buildings and many creeps their own portrait
        # model; without upor the portrait keeps showing the base unit.
        # "portrait" picks another one: the launcher's static <key>_portrait.mdx
        # (neutrals, Roshan, summons, wards: clicking a neutral with its animated
        # model as the portrait hung the game now and then), a WC3 model path,
        # or false for the base unit's own.
        portrait = m.get("portrait", m["model"])
        if portrait:
            fields["upor"] = portrait
        # The Dota textures carry the colours: drop the base unit's tint
        # (Satyr Trickster 255/120/255, Gnoll Assassin 100/100/255, ...).
        fields.update({"uclr": 255, "uclg": 255, "uclb": 255})
        # No WC3 sound set on Dota neutrals and Roshan: the creep sound sets
        # carry FaceFX lip-sync for portraits, the suspect in the selection hangs
        if key.startswith("neutral_") or key == "roshan":
            fields["usnd"] = ""
        if "scale" in m:
            fields["usca"] = m["scale"]
        if "walk" in m:
            fields["uwal"] = m["walk"]      # speed the walk cycle was animated for
            fields["urun"] = m["walk"]      # WC3 keeps run = walk; the models have no Walk Fast
    return fields


def load_specs():
    """specs/heroes/<hero>.json: WC3-side choices for each hero."""
    folder = os.path.join(ROOT, "specs", "heroes")
    out = {}
    for n in sorted(os.listdir(folder)):
        if n.endswith(".json"):
            with open(os.path.join(folder, n), encoding="utf-8") as f:
                out[n[:-5]] = json.load(f)
    return {"heroes": out}


class Ids:
    def __init__(self):
        self.next = {}
        self.out = {"abilities": {}, "heroes": {}, "units": {}, "items": {}, "buffs": {}, "orders": {}}

    def new(self, prefix):
        n = self.next.get(prefix, 0)
        self.next[prefix] = n + 1
        digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        return prefix + digits[n // 36 // 36 % 36] + digits[n // 36 % 36] + digits[n % 36]


def flags_of(ab):
    return set((ab.get("AbilityBehavior") or "").replace("DOTA_ABILITY_BEHAVIOR_", "").replace(" ", "").split("|"))


def is_innate(ab):
    return ab.get("Innate") == "1" or "innate" in ab["name"]


def ability_value(ab, key, level):
    raw = (ab.get("values") or {}).get(key, ab.get(key))
    if raw is None:
        return None
    parts = str(raw).split()
    if not parts:
        return None
    try:
        return float(parts[min(level, len(parts)) - 1])
    except ValueError:
        return None


def levels_of(ab):
    if is_innate(ab):
        return 1
    if ab.get("MaxLevel"):
        return int(ab["MaxLevel"])
    return 3 if "ULTIMATE" in (ab.get("AbilityType") or "") else 4


def tooltip(ab, spec, level, levels):
    title = spec.get("title") or ab.get("title") or ab["name"]
    lines = [spec["desc"]] if spec.get("desc") else []
    shown = 0
    for key, raw in (ab.get("values") or {}).items():
        if key.endswith("@upgrade_only") or key.startswith(("Ability", "special_bonus")) or shown >= 6:
            continue
        v = ability_value(ab, key, level)
        if v is None:
            continue
        lines.append(f"{key.replace('_', ' ').capitalize()}: |cffffcc00{v:g}|r")
        shown += 1
    cd = ability_value(ab, "AbilityCooldown", level)
    mana = ability_value(ab, "AbilityManaCost", level)
    if cd:
        lines.append(f"Cooldown: |cffffcc00{cd:g}|r")
    if mana:
        lines.append(f"Mana: |cffffcc00{mana:g}|r")
    return f"{title} - [|cffffcc00Level {level}|r]", "|n".join(lines)


def ability_object(abils, ids, hero, ab, spec, slot_index, ult, order_index=None):
    """Create the WC3 ability for one Dota ability. Returns its raw code."""
    flags = flags_of(ab)
    levels = levels_of(ab)
    innate = is_innate(ab)
    kind = spec.get("kind")
    if kind is None:
        if "PASSIVE" in flags:
            kind = "passive"
        elif "TOGGLE" in flags:
            kind = "toggle"
        else:
            kind = "active"
    code = ids.new("A")
    ids.out["abilities"][ab["name"]] = code
    # command card: bottom row for the first three, then the free middle-row
    # cells; the ultimate sits bottom right. Learn menu mirrors it.
    if spec.get("cell") or spec.get("_cell"):
        (bx, by) = tuple(spec.get("cell") or spec["_cell"])
        (rx, ry) = tuple(spec.get("learnCell", (0, 2)))
    elif ult:
        (bx, by), (rx, ry) = (3, 2), (3, 0)
    else:
        cells = [(0, 2), (1, 2), (2, 2), (1, 1), (2, 1)]
        bx, by = cells[min(slot_index, len(cells) - 1)]
        rx, ry = (slot_index, 0) if slot_index < 3 else (slot_index - 3, 1)
    title = spec.get("title") or ab.get("title") or ab["name"]
    icon = ICON.format(ab["name"])
    f = {
        "anam": title,
        "aher": 0 if innate else 1,
        "alev": levels,
        "aart": icon, "arar": icon,
        "arlv": 6 if ult else 1,
        "alsk": 6 if ult else 2,
        "aret": f"Learn {title} - [|cffffcc00Level %d|r]",
        "arut": spec.get("desc", title),
        "arhk": spec.get("hotkey") or CELL_KEYS.get((bx, by), ""),
        "ahky": spec.get("hotkey") or CELL_KEYS.get((bx, by), ""),
        "abpx": bx, "abpy": by,
        "arpx": rx, "arpy": ry,
    }
    tips, ubers, cds, manas, ranges, areas = [], [], [], [], [], []
    for lvl in range(1, levels + 1):
        t, u = tooltip(ab, spec, lvl, levels)
        tips.append(t)
        ubers.append(u)
        cds.append(ability_value(ab, "AbilityCooldown", lvl) or 0)
        manas.append(int(ability_value(ab, "AbilityManaCost", lvl) or 0))
        ranges.append(spec.get("range") or ability_value(ab, "AbilityCastRange", lvl) or 0)
        radius = None
        for key in (spec.get("radiusKey"), "radius", "aoe", "area_of_effect", "hook_width"):
            if key:
                radius = ability_value(ab, key, lvl)
                if radius:
                    break
        areas.append(radius or 0)
    f.update({"atp1": tips, "aub1": ubers})

    if kind == "passive":
        base = "AEev"            # Evasion at 0 % as an icon-only passive
        f.update({"Eev1": [0] * levels, "acdn": [0] * levels, "amcs": [0] * levels})
    elif kind == "toggle":
        base = "AEim"            # Immolation: on/off orders, no native effect
        f.update({"Eim1": [0] * levels, "Eim2": [0] * levels, "Eim3": [0] * levels,
                  "acdn": cds, "amcs": manas, "aare": areas, "abuf": [""] * levels,
                  "aub1": ubers, "aut1": tips, "auu1": ubers, "auar": icon})
    elif kind == "native":
        base = spec["base"]
        f.update({"acdn": cds, "amcs": manas, "aran": ranges})
        for fid, vals in (spec.get("fields") or {}).items():
            f[fid] = vals
    else:
        base = "ANcl"            # Channel: configurable targeting, effect in Lua
        if "CHANNELLED" in flags or spec.get("channel"):
            follow = [ability_value(ab, "AbilityChannelTime", l) or spec.get("channel") or 1.0
                      for l in range(1, levels + 1)]
        else:
            follow = [0] * levels
        if "UNIT_TARGET" in flags and "POINT" in flags:
            target = 3
        elif "UNIT_TARGET" in flags:
            target = 1
        elif "POINT" in flags:
            target = 2
        else:
            target = 0
        target = spec.get("target", target)
        options = 1                          # visible
        if target in (2, 3) and any(areas):
            options |= 2                     # area targeting circle
        if spec.get("universal"):
            options |= 8                     # may target spell-immune units
        f.update({
            "Ncl1": follow, "Ncl2": [target] * levels, "Ncl3": [options] * levels,
            # channels never lock the command card: stop/move must interrupt them as in Dota
            "Ncl4": [0] * levels, "Ncl5": [1 if spec.get("lockAbilities") else 0] * levels,
            "Ncl6": [spec.get("order", ORDERS[(slot_index if order_index is None else order_index) % len(ORDERS)])] * levels,
            "acdn": cds, "amcs": manas, "aran": ranges, "aare": areas,
            # no hero/nonhero or ancient flags: both kinds stay targetable
            "atar": [spec.get("targets", "air,ground,enemy,neutral")] * levels,
            "aani": spec.get("anim", "spell"),
            "acat": "", "atat": "", "aeat": "", "asat": "",
        })
        if spec.get("castPoint") is not None:
            f["acas"] = [spec["castPoint"]] * levels       # casting time before the effect
        for fid, vals in (spec.get("fields") or {}).items():
            f[fid] = vals
        if innate and kind == "active":
            f["arlv"], f["alsk"] = 1, 0
    if base == "ANcl":
        ids.out["orders"][ab["name"]] = spec.get("order", ORDERS[(slot_index if order_index is None else order_index) % len(ORDERS)])
    elif spec.get("order"):
        ids.out["orders"][ab["name"]] = spec["order"]
    abils.add(base, code, f)
    if base not in ("ANcl", "AEev"):
        rubick_copy(abils, ids, code, base, f)
    return code, innate


# Spell Steal shows a stolen spell in Dota's D cell. A Channel spell borrows one
# of Rubick's own D slots; any other spell is added as is, and a button's
# hotkey can't change at run time, so each of those gets a copy with the D
# hotkey and cell (src/heroes/rubick.lua, data.ids.rubick_copies).
D_CELL = {"ahky": "D", "auhk": "D", "abpx": 1, "abpy": 1, "aubx": 1, "auby": 1}
COMMANDER_RACES = ("human", "orc", "undead", "nightelf")


def rubick_copy(abils, ids, code, base, fields):
    copy = ids.new("A")
    abils.add(base, copy, dict(fields, **D_CELL))
    ids.out.setdefault("rubick_copies", {})[code] = copy


def commander_spell_copies(abils, ids):
    """D-cell copies of every hero spell of the commander's races."""
    rows = w3obj.parse_slk(os.path.join(w3obj.SLK_DIR, "abilitydata.slk"))
    for r in rows:
        if str(r.get("hero")) == "1" and r.get("race") in COMMANDER_RACES and str(r.get("useInEditor")) == "1":
            rubick_copy(abils, ids, r["alias"], r["alias"], {})


def heroes(units, abils, buffs, ids, herodata, specs):
    for hero, info in herodata.items():
        spec = specs["heroes"][hero]
        s = info["stats"]
        code = ids.new("H")
        ids.out["heroes"][hero] = code
        learnable, innates = [], []
        slot_index = 0
        order_index = 0          # every Channel ability on a hero needs its own order
        plan = []
        for ab in sorted(info["abilities"], key=lambda a: a["slot"]):
            aspec = spec.get("abilities", {}).get(ab["name"], {})
            flags = flags_of(ab)
            if aspec.get("skip"):
                continue
            if ("HIDDEN" in flags or "NOT_LEARNABLE" in flags) and not is_innate(ab) and not aspec.get("include"):
                continue
            plan.append((ab, aspec))
        # Command card: basics take the bottom row then (1,1),(2,1); the
        # ultimate sits at (3,2); innates take whatever cells are left.
        basic_count = sum(1 for ab, a in plan if not is_innate(ab) and not a.get("innateActive")
                          and "ULTIMATE" not in (ab.get("AbilityType") or ""))
        basic_cells = [(0, 2), (1, 2), (2, 2), (1, 1), (2, 1)][:basic_count]
        free_cells = [c for c in [(2, 1), (1, 1), (0, 1)] if c not in basic_cells]
        for ab, aspec in plan:
            if (is_innate(ab) or aspec.get("innateActive")) and "_cell" not in aspec and "cell" not in aspec:
                aspec = dict(aspec, _cell=free_cells.pop(0) if free_cells else (0, 1))
            ult = "ULTIMATE" in (ab.get("AbilityType") or "")
            acode, innate = ability_object(abils, ids, hero, ab, aspec, slot_index, ult, order_index)
            order_index += 1
            if innate or aspec.get("innateActive"):
                innates.append(acode)
            else:
                learnable.append(acode)
                if not ult:
                    slot_index += 1
        dmin, dmax = int(float(s["AttackDamageMin"])), int(float(s["AttackDamageMax"]))
        ranged = s["AttackCapabilities"] == "DOTA_UNIT_CAP_RANGED_ATTACK"
        primary = {"DOTA_ATTRIBUTE_STRENGTH": "STR", "DOTA_ATTRIBUTE_AGILITY": "AGI"}.get(s["AttributePrimary"], "INT")
        f = {
            "unam": spec.get("title", info["title"]), "upro": spec.get("title", info["title"]), "upru": 1,
            # personalized maps answer orders with Dota voice lines instead (game/voice.lua)
            "umdl": spec["model"], "usnd": spec.get("sound", "") if STANDINS else "", "usca": spec.get("scale", 1.0),
            "uico": ICON.format("hero_" + hero),
            "uhab": ",".join(learnable),
            "uabi": "AInv",
            "upra": primary,
            "ustr": int(float(s["AttributeBaseStrength"])), "ustp": float(s["AttributeStrengthGain"]),
            "uagi": int(float(s["AttributeBaseAgility"])), "uagp": float(s["AttributeAgilityGain"]),
            "uint": int(float(s["AttributeBaseIntelligence"])), "uinp": float(s["AttributeIntelligenceGain"]),
            "uhpm": 120, "umpm": 75, "umpi": 75,
            "uhpr": float(s.get("StatusHealthRegen") or 0.25), "umpr": float(s.get("StatusManaRegen") or 0),
            "udef": int(round(float(s.get("ArmorPhysical") or 0))),
            "umvs": int(float(s["MovementSpeed"])),
            "ua1b": dmin - 1, "ua1d": 1, "ua1s": max(1, dmax - dmin + 1),
            "ua1c": float(s["AttackRate"]),
            "ua1r": int(float(s["AttackRange"])) if ranged else 128,
            "uacq": max(600, int(float(s["AttackRange"]))),
            "ua1t": "hero", "udty": "hero",
            "ua1w": "missile" if ranged else "normal",
            "udp1": float(s.get("AttackAnimationPoint") or 0.4),
            "ucpt": 0.3, "ucbs": 0.4,
            "utip": f"Pick {info['title']}",
        }
        if ranged:
            f.update({"ua1m": spec.get("missile", "Abilities\\Weapons\\FireBallMissile\\FireBallMissile.mdl"),
                      "ua1z": int(float(s.get("ProjectileSpeed") or 900))})
        units.add(spec.get("base", "Hpal"), code, apply_model(f, MODELS, "hero_" + hero))
        ids.out["heroes"][hero + "_innates"] = innates
        extras(units, abils, buffs, ids, spec)


def extras(units, abils, buffs, ids, spec):
    """Hero-specific helper objects: summons and dummies (units), dummy-cast
    abilities (abilities_extra) and buffs, addressed in Lua by their key."""
    for key, u in (spec.get("units") or {}).items():
        code = ids.new("n")
        ids.out["units"][key] = code
        units.add(u["base"], code, apply_model(dict(u.get("fields", {})), MODELS, key))
    for key, a in (spec.get("abilities_extra") or {}).items():
        code = ids.new("A")
        ids.out["abilities"][key] = code
        if a.get("order"):
            ids.out["orders"][key] = a["order"]
        abils.add(a["base"], code, a.get("fields", {}))
    for key, b in (spec.get("buffs") or {}).items():
        code = ids.new("B")
        ids.out["buffs"][key] = code
        buffs.add(b["base"], code, b.get("fields", {}))


def helpers(abils):
    hidden = {"aite": 1, "anam": "Bonus"}
    abils.add("AId1", "Zarm", dict(hidden, Idef=[0]))
    abils.add("AItg", "Zdmg", dict(hidden, Iatt=[0]))
    abils.add("AIsx", "Zats", dict(hidden, Isx1=[0.0]))
    abils.add("AIlf", "Zlif", dict(hidden, Ilif=[0]))
    abils.add("AImb", "Zman", dict(hidden, Iman=[0]))
    abils.add("AIx1", "Zatr", dict(hidden, Iagi=[0], Iint=[0], Istr=[0]))


def structures(units, ids):
    def unit(base, key, fields):
        code = ids.new("h")
        ids.out["units"][key] = code
        units.add(base, code, apply_model(dict(fields), MODELS, key))

    tower = {"uabi": "", "uupt": "", "ubui": "", "upgr": "", "ubba": 0, "ubdi": 0, "ubsi": 0,
             "ua1r": 700, "uacq": 700, "ua1c": 0.9, "ua1t": "chaos", "udty": "fort", "usid": 1900, "usin": 800}
    unit("hgtw", "tower1", dict(tower, unam="Dota Tower (Tier 1)", uhpm=1800, udef=12, ua1b=99, ua1d=1, ua1s=21))
    unit("hgtw", "tower2", dict(tower, unam="Dota Tower (Tier 2)", uhpm=2500, udef=16, ua1b=149, ua1d=1, ua1s=21))
    unit("hgtw", "tower3", dict(tower, unam="Dota Tower (Tier 3)", uhpm=2500, udef=16, ua1b=149, ua1d=1, ua1s=21))
    unit("hgtw", "tower4", dict(tower, unam="Dota Tower (Tier 4)", uhpm=2600, udef=21, ua1b=149, ua1d=1, ua1s=21, usca=1.2))
    rax = {"uabi": "", "uupt": "", "utra": "", "ubui": "", "upgr": "", "ubba": 0, "ubdi": 0, "ubsi": 0, "udty": "fort"}
    unit("hbar", "rax_melee", dict(rax, unam="Melee Barracks", uhpm=2200, udef=15))
    unit("hbar", "rax_ranged", dict(rax, unam="Ranged Barracks", uhpm=1300, udef=10, usca=0.8))
    unit("etoe", "ancient", {"unam": "The Ancient", "uhpm": 4500, "udef": 13, "uabi": "", "uupt": "", "utra": "",
                             "ures": "", "uaen": 0, "ubba": 0, "ubdi": 0, "ubsi": 0, "usca": 1.6})
    unit("nfoh", "fountain", {"unam": "Fountain", "uabi": "Avul", "uaen": 1, "ua1b": 189, "ua1d": 1, "ua1s": 3,
                              "ua1c": 0.15, "ua1r": 1200, "uacq": 1200, "ua1t": "chaos", "ua1w": "missile",
                              "ua1m": "Abilities\\Weapons\\FarseerMissile\\FarseerMissile.mdl", "ua1z": 1600,
                              "ua1g": "ground,air,enemy,neutral"})
    unit("ngme", "shop", shop_fields(ids, 0))

    creep = {"uabi": "", "upgr": "", "ubba": 0, "ubdi": 0, "ubsi": 0, "umvs": 325, "udty": "large",
             "ufoo": 0, "ugol": 0, "ulum": 0, "ubld": 0, "utra": "", "urac": "creeps"}
    dota_melee = dict(creep, uhpm=550, udef=2, ua1b=18, ua1d=1, ua1s=5, ua1c=1.0, ua1r=100, uacq=500, ua1t="normal")
    dota_ranged = dict(creep, uhpm=300, udef=0, ua1b=20, ua1d=1, ua1s=6, ua1c=1.0, ua1r=500, uacq=600, ua1t="pierce", ua1z=900)
    dota_siege = dict(creep, uhpm=935, udef=0, ua1b=34, ua1d=1, ua1s=12, ua1c=3.0, ua1r=690, uacq=800, ua1t="siege")
    unit("nfrl", "dota_melee", dict(dota_melee, unam="Radiant Melee Creep"))
    unit("nfrs", "dota_ranged", dict(dota_ranged, unam="Radiant Ranged Creep"))
    unit("nsgg", "dota_siege", dict(dota_siege, unam="Radiant Siege Creep", ua1w="artillery",
                                    ua1m="Abilities\\Weapons\\Mortar\\MortarMissile.mdl", ua1z=700))
    races = {
        "human": ("hfoo", "hrif", "hmtm"), "orc": ("ogru", "ohun", "ocat"),
        "undead": ("ugho", "ucry", "umtw"), "nightelf": ("esen", "earc", "ebal"),
    }
    # Horde creeps keep their race's upgrade list so the commander's research
    # (mirrored onto the Horde player) strengthens them too.
    def horde(fields, name):
        return {k: v for k, v in dict(fields, unam=name).items() if k not in ("upgr", "ua1z")}

    for race, (melee, ranged, siege) in races.items():
        unit(melee, f"{race}_melee", horde(dota_melee, f"Horde Melee ({race})"))
        unit(ranged, f"{race}_ranged", horde(dota_ranged, f"Horde Ranged ({race})"))
        unit(siege, f"{race}_siege", horde(dota_siege, f"Horde Siege ({race})"))


# ---------------------------------------------------------------- Dota items
# Each Dota item (src/data/items.json) becomes two WC3 items: the inventory
# item (ids.items) and a power-up "token" (ids.item_tokens) that the shops
# sell. src/game/items.lua turns a bought token into the real item, using
# owned components and refunding their cost, so buying also works with a full
# inventory. Actives are Channel abilities (ids.item_abilities) with Lua effects.
ITEM_MODEL = "Objects\\InventoryItems\\TreasureChest\\treasurechest.mdl"
SHOP_SHARE = "Zshp"      # Aall (Shop Sharing) with a radius that covers the fountain
TRUE_SIGHT = "Ztru"      # Adt1 detection: Sentry Ward and Dust of Appearance
ILLUSION = "Zill"        # AIil cast by the item dummy: Manta Style images (level 2: ranged)
SHOP_RADIUS = 900.0
# Shop command card: (0, 0) holds the shop's select-hero button.
SHOP_BUTTONS = [(1, 0), (2, 0), (3, 0), (0, 1), (1, 1), (2, 1), (3, 1), (0, 2), (1, 2), (2, 2), (3, 2)]
ALLY = "air,ground,friend,self,vuln,invu"
ENEMY = "air,ground,enemy,neutral,vuln"
# Item actives: Channel targeting (none/unit/point/tree), WC3 targets, the
# preferred order, optional cast range override and the universal flag (may
# target magic-immune units). Orders come from WC3's own ability data
# (research/slk/*abilityfunc.txt, several are item-ability orders) and avoid
# every hero order; item_orders() swaps in a spare if a hero takes one later.
ITEM_ACTIVES = {
    "item_tango": {"target": "tree", "order": "wispheal"},
    "item_flask": {"target": "unit", "targets": ALLY, "order": "restoration"},
    "item_clarity": {"target": "unit", "targets": ALLY, "order": "absorbmana"},
    "item_faerie_fire": {"target": "none", "order": "creepthunderclap"},
    "item_enchanted_mango": {"target": "none", "order": "mindrot"},
    "item_tpscroll": {"target": "point", "order": "darksummoning", "range": 99999, "channel": True},
    "item_ward_observer": {"target": "point", "order": "evileye"},
    "item_ward_sentry": {"target": "point", "order": "ward"},
    "item_dust": {"target": "none", "order": "cloudoffog"},
    "item_quelling_blade": {"target": "tree", "order": "magicleash"},
    "item_magic_stick": {"target": "none", "order": "soulpreservation"},
    "item_magic_wand": {"target": "none", "order": "spiritofvengeance"},
    "item_power_treads": {"target": "none", "order": "unholyfrenzyaoe"},
    "item_phase_boots": {"target": "none", "order": "wateryminion"},
    "item_arcane_boots": {"target": "none", "order": "monsoon"},
    "item_blink": {"target": "point", "order": "darkconversion", "range": 99999},
    "item_black_king_bar": {"target": "none", "order": "creepsleep"},
    "item_force_staff": {"target": "unit", "targets": ENEMY + ",friend,self", "order": "scout",
                         "range": 850, "universal": True},
    "item_cyclone": {"target": "unit", "targets": ENEMY + ",self", "order": "summonphoenix"},
    "item_bfury": {"target": "tree", "order": "unstableconcoction"},
    "item_dagon": {"target": "unit", "targets": ENEMY, "order": "creepthunderbolt"},
    "item_hand_of_midas": {"target": "unit", "targets": ENEMY + ",nonhero,nonancient", "order": "whirlwind",
                           "universal": True},
    "item_refresher": {"target": "none", "order": "darkritual"},
    "item_sheepstick": {"target": "unit", "targets": ENEMY, "order": "deathpact"},
    "item_shivas_guard": {"target": "none", "order": "freezingbreath"},
    "item_satanic": {"target": "none", "order": "drunkenhaze"},
    "item_manta": {"target": "none", "order": "elementalfury"},
    "item_mekansm": {"target": "none", "order": "healingspray"},
}
ITEM_SPARE_ORDERS = ["forkedlightning", "tornado", "summongrizzly", "summonquillbeast", "summonwareagle",
                     "stampede", "robogoblin", "summonfactory", "voodoo", "healingwave", "spiritwolf", "taunt",
                     "unholyfrenzy", "doom", "possession", "parasite", "banish", "renew", "waterelemental"]
STAT_LABELS = [
    ("str", "Strength"), ("agi", "Agility"), ("int", "Intelligence"), ("damage", "Damage"),
    ("damage_melee", "Damage (melee)"), ("damage_ranged", "Damage (ranged)"), ("attack_speed", "Attack Speed"),
    ("attack_speed_pct", "% Attack Speed"), ("armor", "Armor"), ("max_hp", "Health"), ("max_mana", "Mana"),
    ("max_mana_pct", "% Maximum Mana"), ("hp_regen", "Health Regeneration"), ("mana_regen", "Mana Regeneration"),
    ("boots_ms", "Movement Speed"), ("boots_ms_melee", "Movement Speed (melee)"), ("lace_ms", "Movement Speed"),
    ("yasha_pct", "% Movement Speed"), ("magic_resist", "% Magic Resistance"), ("evasion", "% Evasion"),
    ("lifesteal", "% Lifesteal"), ("spell_amp", "% Spell Amplification"),
    ("hp_regen_amp", "% Health Regeneration Amplification"),
    ("mana_regen_amp", "% Mana Regeneration Amplification"), ("cast_range", "Cast Range"),
]
PERCENT_STATS = {"attack_speed_pct", "max_mana_pct", "yasha_pct", "magic_resist", "evasion", "lifesteal",
                 "spell_amp", "hp_regen_amp", "mana_regen_amp"}
ITEM_PLANS = {}


def item_plan(ids):
    """Raw codes of every inventory item and shop token, assigned once per
    build: structures() needs the first shop's tokens before items() runs."""
    plan = ITEM_PLANS.get(id(ids))
    if plan is None:
        path = os.path.join(DATA, "items.json")
        data = load("items.json") if os.path.exists(path) else {"items": {}, "shops": []}
        plan = {"data": data, "real": {}, "token": {}}
        for shop in data["shops"]:
            for name in shop["items"]:
                plan["real"][name] = ids.new("I")
                plan["token"][name] = ids.new("J")
        ITEM_PLANS[id(ids)] = plan
    return plan


def shop_fields(ids, index):
    """Unit fields of the Dota shop selling shop number `index` of items.json."""
    plan = item_plan(ids)
    shops = plan["data"]["shops"]
    if index >= len(shops):
        return {"unam": "Dota Shop", "uabi": "Avul,Apit,Aall"}
    shop = shops[index]
    return {"unam": "Dota Shop: " + shop["title"], "uabi": "Avul,Apit," + SHOP_SHARE,
            "usei": ",".join(plan["token"][n] for n in shop["items"]),
            "upat": "PathTextures\\6x6SimpleSolid.tga", "usca": 0.7}


def item_stat_lines(e):
    stats = dict(e.get("stats") or {})
    lines = []
    if stats.get("str") and stats.get("str") == stats.get("agi") == stats.get("int"):
        lines.append(f"|cffffcc00+{stats['str']:g}|r All Attributes")
        for k in ("str", "agi", "int"):
            stats.pop(k)
    for key, label in STAT_LABELS:
        v = stats.get(key)
        if v:
            v = v * 100 if key in PERCENT_STATS else v
            sep = "" if label.startswith("%") else " "
            lines.append(f"|cffffcc00+{round(v, 2):g}|r{sep}{label}")
    if (e.get("values") or {}).get("bonus_stat"):
        lines.append(f"|cffffcc00+{e['values']['bonus_stat']}|r selected attribute")
    return lines


def item_parts_text(data, e):
    """'Mithril Hammer + Ogre Axe + Recipe (1450)'; variants joined with '/'."""
    recipe = e["recipe"]
    alts = recipe["parts"]
    words = []
    for i, part in enumerate(alts[0]):
        variants = []
        for alt in alts:
            name = alt[i] if i < len(alt) else part
            if data[name]["title"] not in variants:
                variants.append(data[name]["title"])
        words.append(" / ".join(variants))
    if recipe["cost"] > 0:
        words.append(f"Recipe ({recipe['cost']})")
    return " + ".join(words)


def item_tooltip(data, name, for_shop):
    e = data[name]
    if e.get("result"):
        result = data[e["result"]]
        return (f"Completes |cffffcc00{result['title']}|r: {item_parts_text(data, result)}. Buy it while you "
                f"carry the parts and they combine at once.")
    lines = item_stat_lines(e)
    if e.get("desc"):
        lines.append(e["desc"])
    if for_shop and e.get("recipe"):
        lines.append(f"|cff99ccffBuilt from:|r {item_parts_text(data, e)}. Parts you carry are used and their "
                     f"cost is refunded.")
    if e.get("consumable") and e.get("charges", 1) > 1:
        lines.append(f"{e['charges']} charges per purchase.")
    return "|n".join(lines)


def native_orders():
    """{ability code: {order strings}} of WC3's own abilities (func files)."""
    out = {}
    if not os.path.isdir(w3obj.SLK_DIR):
        return out
    for n in os.listdir(w3obj.SLK_DIR):
        if not n.lower().endswith("abilityfunc.txt"):
            continue
        code = None
        with open(os.path.join(w3obj.SLK_DIR, n), encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if line.startswith("[") and line.endswith("]"):
                    code = line[1:-1]
                elif code and "=" in line and line.split("=", 1)[0] in ("Order", "Orderon", "Orderoff", "Unorder"):
                    out.setdefault(code, set()).add(line.split("=", 1)[1].strip().lower())
    return out


def item_orders(abils, ids):
    """Order string per item active: the preferred one unless an ability made
    so far (hero spells, extras) already answers to it, then a free spare.
    Channel abilities are read by their Ncl6 field, others by their base."""
    native = native_orders()
    used = {o.lower() for o in ORDERS} | {str(o).lower() for o in ids.out["orders"].values()}
    # Rubick's Spell Steal and Morph can put any WC3 hero spell on a Dota hero,
    # so items must also avoid the orders of every WC3 hero ability.
    heroes_abils = {r.get("alias") for r in w3obj.parse_slk(os.path.join(w3obj.SLK_DIR, "abilitydata.slk"))
                    if r.get("hero") == "1"}
    for code in heroes_abils:
        used.update(native.get(code, ()))
    for base, _, mods in abils.objects:
        if base == "ANcl":
            used.update(str(m[4]).lower() for m in mods if m[0] == "Ncl6")
        else:
            used.update(native.get(base, ()))
    taken = used | {spec["order"] for spec in ITEM_ACTIVES.values()}
    # extra spares: orders of WC3 creep abilities (AC..) not otherwise taken
    all_orders = {o for orders in native.values() for o in orders}
    # skip autocast/toggle variants such as "curseon"/"curseoff"/"autodispel"
    commands = {"attack", "attackground", "attackonce", "move", "stop", "holdposition", "patrol", "smart", "build", "awaken",
                "harvest", "returnresources", "repair", "humanbuild", "orcbuild", "undeadbuild", "nightelfbuild",
                "nagabuild", "load", "unload", "unloadall", "board", "setrally", "cancel", "gather", "eattree",
                "mount", "dismount", "loadarcher", "loadcorpse", "unloadallcorpses", "revive", "request_hero",
                "manashield", "immolation", "defend", "magicdefense", "berserk", "absorb", "sentinel",
                "coupleinstant", "coupletarget", "decouple", "tankloadpilot", "tankpilot", "tankdroppilot"}
    # extra spares: orders of WC3 non-hero abilities not otherwise taken,
    # minus basic commands and autocast/toggle variants ("curseon", "autodispel")
    creep_orders = sorted({o for code, orders in native.items() if code not in heroes_abils for o in orders
                           if o not in commands and not (o.endswith("off") or o.startswith("auto")
                                                         or (o.endswith("on") and o[:-2] in all_orders))})
    spares = [o for o in dict.fromkeys(ITEM_SPARE_ORDERS + creep_orders) if o not in taken]
    out = {}
    for name, spec in ITEM_ACTIVES.items():
        order = spec["order"]
        if order in used:
            if not spares:
                raise SystemExit(f"no free order for {name}: add spares to ITEM_SPARE_ORDERS")
            order = spares.pop(0)
            print(f"items: {name} uses order {order} ({spec['order']} belongs to a hero ability)")
        out[name] = order
    return out


def item_active_fields(e, spec, order):
    target = {"none": 0, "unit": 1, "tree": 1, "point": 2}[spec["target"]]
    channel = float(e.get("channel") or 0) if spec.get("channel") else 0.0
    rng = float(spec.get("range") or e.get("range") or 0) if target else 0.0
    f = {
        "anam": e["title"], "aite": 1, "aher": 0, "alev": 1, "aart": ICON.format(e["icon_key"]),
        "atp1": [e["title"]], "aub1": [e.get("desc", e["title"])],
        "acdn": [float(e.get("cooldown") or 0)], "amcs": [int(e.get("mana") or 0)], "aran": [rng], "aare": [0.0],
        "Ncl1": [channel], "Ncl2": [target], "Ncl3": [1 | (8 if spec.get("universal") else 0)],
        "Ncl4": [0.0], "Ncl5": [1 if channel else 0], "Ncl6": [order],
        "aani": "", "acat": "", "atat": "", "aeat": "", "asat": "",
    }
    if spec["target"] in ("unit", "tree"):
        f["atar"] = ["tree" if spec["target"] == "tree" else spec["targets"]]
    return f


def items(units, abils, ids):
    """Dota items from src/data/items.json: inventory items, shop tokens, item
    abilities, the extra shop units, wards and the item dummy. Returns the w3t."""
    w3t = w3obj.ObjectFile(w3obj.metas()[0], with_levels=False)
    plan = item_plan(ids)
    data = plan["data"]["items"]
    if not data:
        return w3t
    out = ids.out
    out.setdefault("item_tokens", {})
    out.setdefault("item_abilities", {})

    def value(name, key):
        return float(str(data[name]["values"][key]).split()[0])

    abils.add("Aall", SHOP_SHARE, {"anam": "Dota Shop Sharing", "Neu1": [SHOP_RADIUS], "aran": [SHOP_RADIUS]})
    abils.add("Adt1", TRUE_SIGHT, {"anam": "Dota True Sight", "aran": [value("item_ward_sentry", "true_sight_range")]})
    duration = value("item_manta", "illusion_duration")
    abils.add("AIil", ILLUSION, {
        "anam": "Manta Images", "alev": 2, "aran": [600.0, 600.0], "acdn": [0.0, 0.0], "amcs": [0, 0],
        "Iild": [value("item_manta", "tooltip_damage_outgoing_melee") / 100,
                 value("item_manta", "tooltip_damage_outgoing_ranged") / 100],
        "Iilw": [value("item_manta", "tooltip_damage_incoming_total_pct") / 100] * 2,
        "adur": [duration] * 2, "ahdu": [duration] * 2,
    })
    out["abilities"].update({"items_shopshare": SHOP_SHARE, "items_truesight": TRUE_SIGHT, "items_illusion": ILLUSION})

    for name, e in data.items():
        e["icon_key"] = "item_recipe" if e.get("result") else name
    orders = item_orders(abils, ids)
    for name, spec in ITEM_ACTIVES.items():
        if name in data:
            code = ids.new("A")
            out["item_abilities"][name] = code
            out["orders"][name] = orders[name]
            # the Dota HUD uses items itself (none / unit / point / tree targets)
            out.setdefault("item_targets", {})[name] = spec["target"]
            abils.add("ANcl", code, item_active_fields(data[name], spec, orders[name]))

    for shop in plan["data"]["shops"]:
        for slot, name in enumerate(shop["items"]):
            e = data[name]
            icon = ICON.format(e["icon_key"])
            ability = out["item_abilities"].get(name, "")
            consumable = bool(e.get("consumable"))
            real = {
                "unam": e["title"], "utip": e["title"], "utub": item_tooltip(data, name, False),
                "ides": e.get("desc", e["title"]), "iico": icon, "ifil": ITEM_MODEL, "ureq": "",
                "igol": e["cost"], "ilum": 0, "iabi": ability, "iusa": 1 if ability else 0,
                "iuse": e.get("charges", 0) if consumable else 0,
                "iper": 1 if consumable and name != "item_tpscroll" else 0,
                "ipow": 0, "idro": 1, "idrp": 0, "ipaw": 1, "isel": 0, "iprn": 0,
            }
            if ability:
                real["icid"] = ability
            stock = e.get("stock") or {}
            bx, by = SHOP_BUTTONS[slot]
            token = {
                "unam": e["title"], "utip": f"Purchase |cffffcc00{e['title']}|r",
                "utub": item_tooltip(data, name, True), "ides": e.get("desc", e["title"]), "iico": icon,
                "ifil": ITEM_MODEL, "ureq": "", "igol": e["cost"], "ilum": 0, "iabi": "", "iusa": 1,
                "iper": 1, "ipow": 1, "idro": 1, "idrp": 0, "ipaw": 0, "isel": 1, "iprn": 0,
                "ubpx": bx, "ubpy": by, "isst": 0,
                "isto": stock.get("max", 5), "isit": stock.get("initial", 5), "istr": int(stock.get("time", 1)) or 1,
            }
            out["items"][name] = plan["real"][name]
            out["item_tokens"][name] = plan["token"][name]
            w3t.add("sreg" if consumable else "rat6", plan["real"][name], real)
            w3t.add("tdex", plan["token"][name], token)

    shops = plan["data"]["shops"]
    for index in range(1, len(shops)):
        code = ids.new("h")
        out["units"][f"shop{index + 1}"] = code
        units.add("ngme", code, apply_model(shop_fields(ids, index), MODELS, "shop"))

    ward = {"uhpm": int(value("item_ward_observer", "health")), "umvs": 0, "ufoo": 0, "usca": 0.9}
    observer_sight = int(value("item_ward_observer", "vision_range_tooltip"))
    for key, title, abil, sight, tint in (
            ("wardobserver", "Observer Ward", "Apiv,Aeth", observer_sight, (255, 225, 90)),
            ("wardsentry", "Sentry Ward", "Apiv,Aeth," + TRUE_SIGHT, 150, (110, 170, 255))):
        code = ids.new("n")
        out["units"][key] = code
        # Dota's ward model (models.json ward_observer / ward_sentry) in personalized maps
        units.add("oeye", code, apply_model(dict(ward, unam=title, uabi=abil, usid=sight, usin=sight,
                                                 uclr=tint[0], uclg=tint[1], uclb=tint[2]),
                                            MODELS, "ward_" + key[len("ward"):]))
    code = ids.new("n")
    out["units"]["itemdummy"] = code
    units.add("hfoo", code, {"unam": "Item Dummy", "uabi": "Aloc", "umdl": ".mdl", "usca": 0.01, "ushu": "_",
                             "umvt": "fly", "umvs": 0, "umvr": 3.0, "ucol": 0.0, "uaen": 0, "ucpt": 0.0, "ucbs": 0.0,
                             "usid": 300, "usin": 300, "ufoo": 0, "uhpm": 1000})
    print(f"items: {len(out['items'])} items with shop tokens, {len(out['item_abilities'])} item abilities, "
          f"{len(shops)} shops")
    return w3t


# ---------------------------------------------------------------- Dota world
# Neutral camps, Roshan, runes, Aegis/Cheese and tower helpers. Numbers come
# from src/data/world.json (tools/extract_world.py); the WC3 side (stand-in
# creeps, their few native spells, rune tints) is chosen here. Lua looks the
# codes up under use("data.ids").world. Logic: src/game/world*.lua.
# Dota neutral -> (WC3 creep it is built on, native WC3 creep spells standing
# in for its Dota ones). Spell immunity, reincarnation, devour and the like
# are dropped: Dota neutrals have none of them.
WORLD_CREEPS = {
    "kobold": ("nkob", ""), "kobold_tunneler": ("nkot", ""), "kobold_taskmaster": ("nkol", "SCae"),
    "forest_troll_berserker": ("nftb", ""), "forest_troll_high_priest": ("nfsh", "Anh1"),
    "gnoll_assassin": ("ngns", "ACvs"), "harpy_scout": ("nhar", ""), "harpy_storm": ("nhrh", "ACcl"),
    "ghost": ("ngh1", ""), "fel_beast": ("npfl", ""), "giant_wolf": ("nwlg", ""),
    "alpha_wolf": ("nwld", "ACct,ACac"), "ogre_mauler": ("nogm", ""), "ogre_magi": ("nomg", "ACfa"),
    "satyr_trickster": ("nsat", "ACpu"), "satyr_soulstealer": ("nstl", "Ambd"),
    "satyr_hellcaller": ("nsth", "ACsh,ACua"), "mud_golem": ("ngrk", "ACtb"), "centaur_outrunner": ("ncen", ""),
    "centaur_khan": ("ncnk", "Awrs"), "polar_furbolg_champion": ("nfrg", "SCae"),
    "polar_furbolg_ursa_warrior": ("nfra", "ACtc"), "wildkin": ("nowb", ""), "enraged_wildkin": ("nowe", "ACav"),
    "dark_troll": ("ndtr", ""), "dark_troll_warlord": ("ndtw", ""), "black_drake": ("nbdk", ""),
    "black_dragon": ("nbwm", "ACav"), "rock_golem": ("ngst", ""), "granite_golem": ("nggr", ""),
    "small_thunder_lizard": ("nthl", ""), "big_thunder_lizard": ("nstw", "ACt2"),
}
WORLD_GROUNDED = {"nhar": 40, "nhrh": 40, "nbdk": 110, "nbwm": 130}   # fliers walk: melee heroes hit ground only
WORLD_SPLASH = {"black_dragon"}                                    # Dota's splash attack
WORLD_ACQUIRE = 200       # Dota neutrals mostly wait to be attacked; WC3 creeps still answer attackers
# Rune key -> (name, tooltip, tint): WC3's runic object tinted in Dota's rune colours.
WORLD_RUNES = {
    "doubledamage": ("Amplify Damage Rune", "Base damage +80% and spell amplification +15% for 45 seconds.",
                     (130, 202, 255)),
    "haste": ("Haste Rune", "Maximum movement speed for 22 seconds.", (246, 40, 23)),
    "illusion": ("Illusion Rune", "Two illusions of your hero for 75 seconds.", (255, 215, 0)),
    "invisibility": ("Invisibility Rune", "Invisible for 45 seconds after a 2 second fade. Attacking or casting "
                     "breaks it.", (160, 40, 200)),
    "regeneration": ("Regeneration Rune", "Restores 6% health and mana per second until full, up to 30 seconds.",
                     (127, 255, 0)),
    "arcane": ("Arcane Rune", "Cooldowns -25% and mana costs -30% for 50 seconds.", (253, 58, 251)),
    "shield": ("Shield Rune", "A barrier worth 50% of your maximum health for 75 seconds.", (200, 200, 200)),
    "water": ("Water Rune", "Restores 40 health and 80 mana.", (116, 167, 247)),
    "bounty": ("Bounty Rune", "Gold for every hero of your team.", (255, 120, 0)),
}
RUNE_MODEL = "Objects\\InventoryItems\\runicobject\\runicobject.mdl"
RUNE_ICON = "ReplaceableTextures\\CommandButtons\\BTNRune.blp"


def world(units, abils, ids, w3t):
    """Neutral creeps, Roshan, rune power-ups, Aegis, Cheese and the helper
    abilities of src/game/world*.lua. Skipped without src/data/world.json."""
    if not os.path.exists(os.path.join(DATA, "world.json")):
        return
    data = load("world.json")
    out = ids.out.setdefault("world", {"units": {}, "items": {}, "abilities": {}})

    def creep_fields(d):
        dmin, dmax = int(d["dmg_min"]), int(d["dmg_max"])
        return {
            "unam": d["title"], "uhpm": int(d["hp"]), "uhpr": float(d["hp_regen"]), "uhrt": "always",
            "umpm": int(d["mana"]), "umpi": int(d["mana"]), "umpr": float(d["mana_regen"] or 0),
            # WC3 caps unit levels at 20 (Roshan is 30 in Dota) and logs every query past it
            "udef": int(round(d["armor"])), "udty": "large", "ulev": min(20, int(d["level"])),
            "utyp": "ancient" if d["ancient"] else "",
            "ua1b": dmin - 1, "ua1d": 1, "ua1s": max(1, dmax - dmin + 1), "ua1c": float(d["attack_rate"]),
            "ua1r": int(d["range"]), "ua1t": "normal", "umvs": int(d["move_speed"]),
            "ubba": 0, "ubdi": 0, "ubsi": 0, "ufoo": 0, "ugol": 0, "ulum": 0, "usle": 0,
        }

    for name, (base, spells) in WORLD_CREEPS.items():
        d = data["neutrals"].get(name)
        if not d:
            continue
        f = creep_fields(d)
        f.update({"uabi": spells, "uacq": float(min(WORLD_ACQUIRE, d["acquire"] or WORLD_ACQUIRE))})
        if d["ranged"]:
            f["ua1w"] = "msplash" if name in WORLD_SPLASH else "missile"
            f["ua1z"] = int(d["projectile_speed"] or 900)
        if base in WORLD_GROUNDED:
            f.update({"umvt": "foot", "utar": "ground", "umvh": float(WORLD_GROUNDED[base])})
        code = ids.new("n")
        out["units"]["neutral_" + name] = code
        units.add(base, code, apply_model(f, MODELS, "neutral_" + name))

    r = data["roshan"]
    f = creep_fields(r)
    f.update({"uabi": "", "uacq": float(r["acquire"] or 150), "usid": int(r["vision"]), "usin": int(r["vision"]),
              "usca": 1.9})
    code = ids.new("n")
    out["units"]["roshan"] = code
    units.add("nsqa", code, apply_model(f, MODELS, "roshan"))        # Ancient Sasquatch stand-in

    code = ids.new("n")
    out["units"]["dummy"] = code
    units.add("hfoo", code, {"unam": "World Dummy", "uabi": "Aloc", "umdl": ".mdl", "usca": 0.01, "ushu": "_",
                             "umvt": "fly", "umvs": 0, "umvr": 3.0, "ucol": 0.0, "uaen": 0, "ucpt": 0.0,
                             "ucbs": 0.0, "usid": 300, "usin": 300, "ufoo": 0, "uhpm": 1000})

    def ability(key, base, fields):
        code = ids.new("A")
        out["abilities"][key] = code
        abils.add(base, code, fields)
        return code

    aegis, cheese = data["aegis"], data["cheese"]
    a_aegis = ability("aegis", "AIrc", {"anam": "Aegis Reincarnation", "aite": 1,
                                        "Ircd": [int(aegis["reincarnate_time"])], "irc2": [100000],
                                        "irc3": [100000]})
    a_cheese = ability("cheese", "AIre", {"anam": "Cheese", "aite": 1, "Ihps": [int(cheese["health_restore"])],
                                          "Imps": [int(cheese["mana_restore"])],
                                          "acdn": [float(cheese["cooldown"])]})
    ability("illusion", "AIil", {"anam": "Illusion Rune", "alev": 2, "aran": [600.0, 600.0], "acdn": [0.0, 0.0],
                                 "amcs": [0, 0], "Iild": [0.35, 0.35], "Iilw": [2.0, 3.0],
                                 "adur": [75.0, 75.0], "ahdu": [75.0, 75.0]})
    ability("truesight", "Adt1", {"anam": "Tower True Sight", "aran": [float(data["towers"]["1"]["range"])]})

    def item(key, base, fields):
        code = ids.new("I")
        out["items"][key] = code
        w3t.add(base, code, dict({"igol": 0, "ilum": 0, "ilev": 0, "ilvo": 0, "iprn": 0, "isel": 0, "ipaw": 0,
                                  "ureq": ""}, **fields))

    for key, (title, tip, (red, green, blue)) in WORLD_RUNES.items():
        art = {"ifil": RUNE_MODEL, "isca": 1.3, "iclr": red, "iclg": green, "iclb": blue}
        m = MODELS.get("rune_" + key)
        if m:       # Dota's own rune model (personalized maps): its texture has the colour, no tint
            art = {"ifil": m["model"], "isca": m.get("scale", 1.0), "iclr": 255, "iclg": 255, "iclb": 255}
        item("rune_" + key, "rspd", dict({"unam": title, "utip": title, "utub": tip, "ides": tip, "iico": RUNE_ICON,
                                          "iabi": "", "iusa": 1, "iper": 1, "ipow": 1, "idro": 1, "idrp": 0}, **art))
    tip = (f"Brings its holder back to life where they fell, {aegis['reincarnate_time']:g} seconds after death, "
           f"with full health and mana. Disappears {aegis['disappear_time'] / 60:g} minutes after it is picked up.")
    item("aegis", "ankh", {"unam": "Aegis of the Immortal", "utip": "Aegis of the Immortal", "utub": tip,
                           "ides": tip, "iico": "ReplaceableTextures\\CommandButtons\\BTNAnkh.blp",
                           "ifil": "Objects\\InventoryItems\\Glyph\\Glyph.mdl", "isca": 1.4,
                           "iclr": 255, "iclg": 215, "iclb": 90, "iabi": a_aegis, "iuse": 1, "iper": 1,
                           "iusa": 0, "ipow": 0, "idro": 0, "idrp": 0})
    tip = (f"Instantly restores {cheese['health_restore']} health and {cheese['mana_restore']} mana. "
           f"Cooldown {cheese['cooldown']:g} seconds.")
    item("cheese", "phea", {"unam": "Cheese", "utip": "Cheese", "utub": tip, "ides": tip,
                            "iico": "ReplaceableTextures\\CommandButtons\\BTNCheese.blp", "iabi": a_cheese,
                            "icid": a_cheese, "iuse": 1, "iper": 1, "iusa": 1, "ipow": 0, "idro": 1, "idrp": 0})
    print(f"world: {len(out['units'])} units, {len(out['items'])} items, {len(out['abilities'])} abilities")


MISC = """[Misc]
StrAttackBonus=1
StrHitPointBonus=22
StrRegenBonus=0.1
IntManaBonus=12
IntRegenBonus=0.05
AgiDefenseBonus=0.167
AgiDefenseBase=0
AgiMoveBonus=0
AgiAttackSpeedBonus=0.01
MaxHeroLevel=30
NeedHeroXP=240,640,1160,1760,2440,3200,4000,4900,5900,7000,8200,9500,10900,12400,14000,15700,17500,19400,21400,23600,26000,28600,31400,34400,38400,43400,49400,56400,63900
NeedHeroXPFormulaA=1
NeedHeroXPFormulaB=0
NeedHeroXPFormulaC=0
GrantHeroXP=0
GrantHeroXPFormulaA=0
GrantHeroXPFormulaB=0
GrantHeroXPFormulaC=0
GrantNormalXP=0
GrantNormalXPFormulaA=0
GrantNormalXPFormulaB=0
GrantNormalXPFormulaC=0
HeroExpRange=0
MaxUnitSpeed=550
MinUnitSpeed=100
"""


def main(out_dir=None, standins=False):
    """Writes objects.json and ids.json into out_dir (default: build/ and src/data/).
    standins keeps the WC3 stand-in models: the Dota ones only exist in maps the
    launcher has personalized."""
    global MODELS, STANDINS
    MODELS = {} if standins else load_models()
    STANDINS = standins
    U, A, B, Q = w3obj.metas()
    herodata = load("heroes.json")
    specs = load_specs()
    ids = Ids()
    # The converted Dota models, for Lua that draws one as a special effect
    # (March of the Machines robots); empty with stand-ins.
    ids.out["models"] = {k: {"model": m["model"], "scale": m.get("scale", 1.0)} for k, m in MODELS.items()}
    units = w3obj.ObjectFile(U, with_levels=False)
    abils = w3obj.ObjectFile(A, with_levels=True)
    buffs = w3obj.ObjectFile(B, with_levels=False)
    helpers(abils)
    structures(units, ids)
    heroes(units, abils, buffs, ids, herodata, specs)
    commander_spell_copies(abils, ids)
    item_objects = items(units, abils, ids)
    world(units, abils, ids, item_objects)
    files = {
        "war3map.w3u": units.save(),
        "war3map.w3t": item_objects.save(),
        "war3map.w3a": abils.save(),
        "war3mapMisc.txt": MISC.replace("\n", "\r\n").encode("ascii"),
    }
    if buffs.objects:
        files["war3map.w3h"] = buffs.save()
    objects_path = os.path.join(out_dir or os.path.join(ROOT, "build"), "objects.json")
    ids_path = os.path.join(out_dir or DATA, "ids.json")
    os.makedirs(os.path.dirname(objects_path), exist_ok=True)
    with open(objects_path, "w", encoding="utf-8") as fh:
        json.dump({k: base64.b64encode(v).decode("ascii") for k, v in files.items()}, fh)
    with open(ids_path, "w", encoding="utf-8") as fh:
        json.dump(ids.out, fh, indent=1, sort_keys=True)
    print(f"objects: {len(units.objects)} units, {len(abils.objects)} abilities, {len(buffs.objects)} buffs; "
          f"heroes {len(herodata)}, hero abilities {len(ids.out['abilities'])}")


if __name__ == "__main__":
    main(sys.argv[sys.argv.index("--out-dir") + 1] if "--out-dir" in sys.argv else None,
         standins="--standins" in sys.argv)
