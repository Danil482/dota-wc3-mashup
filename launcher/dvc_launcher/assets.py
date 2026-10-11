"""Asset plan (which Dota 2 files feed which map files) and conversion.

Naming contract with the map script:
  ReplaceableTextures\\CommandButtons\\BTNDota_<ability>.blp            64x64 BLP1
  ReplaceableTextures\\CommandButtonsDisabled\\DISBTNDota_<ability>.blp desaturated, darker
  ReplaceableTextures\\PassiveButtons\\PASBTNDota_<ability>.blp
  ... and the same three for BTNDota_hero_<hero>.blp
  BTNDota_<key>.blp and DISBTNDota_<key>.blp (no PASBTN) for every "icons"
  entry of src/data/items.json (item_tpscroll, item_recipe, ...)
  Sound\\Dota\\<hero>\\<event>_<n>.mp3                                   see vo_manifest.json
  Sound\\Dota\\{music,announcer,sfx}\\<key>.{mp3,wav}                     see below
  <target> of every entry of specs/hud_assets.json                      see below

Music, announcer and effects. vo_manifest.json "audio" maps each map path to
  {"source": "<VPK path of the .vsnd_c>", "mono": true|false}
(tools/select_vo.py writes it together with src/data/audio.json, the map
script's list of the same paths with durations and loop points). The target's
extension is the format the script expects: .mp3 targets take the MP3 that
VRF exports as is (music, announcer), .wav targets the WAV (16-bit PCM
effects); "mono" folds a stereo WAV to one channel, so Warcraft III can place
it in 3D and the map stays smaller. A source missing from the player's Dota 2
or in the other format gives a short silent file of the target's format, so
every path of audio.json exists in the map (logged: audio_silent,
audio_format).

HUD images. specs/hud_assets.json is optional; build.ps1 bundles it when it
exists. It is a JSON list of entries:
  {"target":  "war3mapImported\\Hud\\minimap_frame.blp",
   "sources": ["panorama/images/hud/reborn/minimap_frame_psd.vtex_c", ...],
   "size":    [256, 256],
   "fit":     "stretch",
   "kind":    "hud"}
  target   required. Map path: ASCII, backslashes, relative, ends in .blp,
           unique (case-insensitive). Use war3mapImported\\Hud\\<name>.blp.
           Paths in the icon, voice and model folders the launcher fills
           (BTNDota_, DISBTNDota_, PASBTNDota_, Sound\\Dota\\,
           war3mapImported\\Dota\\) are refused.
  sources  required, at least one. Dota texture paths (.vtex_c, forward
           slashes, as listed in pak01_dir.vpk), tried in order: the first
           one in the player's Dota 2 files is used, later ones are
           fallbacks. Their folders are listed and exported automatically.
           If none exists or decodes, a dark translucent placeholder is
           written, so the target always exists in the map; the launcher
           logs it (hud_placeholders, hud_fallbacks).
  size     optional [width, height] in pixels (1..4096). The image is resized
           to it; the aspect ratio is not kept. Default: the source's own
           size (64x64 for a placeholder).
  fit      optional, "stretch" (default) or "pad". Warcraft III's classic
           graphics need power-of-two BLP1 sides, so every side is rounded
           up to the next power of two, at most 1024 (a longer side is first
           scaled down to 1024):
             stretch  the image is resized to the power-of-two size; a frame
                      of the requested size shows it undistorted.
             pad      the image keeps the requested size in the top-left
                      corner, the rest is transparent; show it with texture
                      coordinates (0, 0)-(width/W, height/H).
           Every adjusted target is logged (hud_resized). Give power-of-two
           sizes (64..512) to avoid both.
  kind     optional, "hud" (the only kind so far).
  note     optional free text, ignored.
  Output: BLP1 with a 256-colour palette and an 8-bit alpha plane (alpha is
  kept) and a full mipmap chain. The map script uses only the target paths.
"""
import array
import difflib
import hashlib
import io
import json
import struct
import sys

from PIL import Image

from . import PLAN_VERSION, blp
from .vrf import find_output

ICON_SIZE = 64
SPELLICONS = "panorama/images/spellicons/"
ITEMICONS = "panorama/images/items/"
# Folders listed whole, because the close-name searches look through them.
# Everything else is listed per folder of the sources named in the inputs.
SEARCHED_FOLDERS = (SPELLICONS, "panorama/images/heroes/", ITEMICONS)
HERO_IMAGES = (
    "panorama/images/heroes/npc_dota_hero_{hero}_png.vtex_c",            # 128x72 portrait card
    "panorama/images/heroes/selection/npc_dota_hero_{hero}_png.vtex_c",  # 142x188 selection art
    "panorama/images/heroes/icons/npc_dota_hero_{hero}_png.vtex_c",      # 32x32 minimap icon
)
# Cosmetic icon variants are never picked by the close-name search.
COSMETIC_MARKERS = ("arcana", "immortal", "persona", "gold", "style", "_alt", "scavenger", "carnival",
                    "crimson", "secondary", "cosmic", "ti7", "ti8", "ti9", "ti10", "_20", "frostivus")
CLOSE_NAME_MIN_RATIO = 0.75

BTN = "ReplaceableTextures\\CommandButtons\\BTNDota_{key}.blp"
DISBTN = "ReplaceableTextures\\CommandButtonsDisabled\\DISBTNDota_{key}.blp"
PASBTN = "ReplaceableTextures\\PassiveButtons\\PASBTNDota_{key}.blp"

HUD_KIND = "hud"
HUD_FITS = ("stretch", "pad")
HUD_FIELDS = {"target", "sources", "size", "fit", "kind", "note"}
HUD_MAX_SIDE = 1024
HUD_PLACEHOLDER = (24, 24, 28, 192)
# Map folders the launcher fills itself (icons, voices, unit models).
RESERVED_PREFIXES = ("REPLACEABLETEXTURES\\COMMANDBUTTONS\\BTNDOTA_",
                     "REPLACEABLETEXTURES\\COMMANDBUTTONSDISABLED\\DISBTNDOTA_",
                     "REPLACEABLETEXTURES\\PASSIVEBUTTONS\\PASBTNDOTA_", "SOUND\\DOTA\\", "WAR3MAPIMPORTED\\DOTA\\")

# One second of silence (MPEG-1 Layer III, 32 kbit/s, 44.1 kHz, mono): used
# only when a voice line cannot be extracted, so every path in sounds.json
# exists in the map.
SILENT_MP3 = (b"\xff\xfb\x10\xc0" + bytes(100)) * 38
SILENT_WAV_RATE = 22050         # a tenth of a second of mono silence for a .wav target


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def roster_from_heroes(heroes):
    """[(hero, [ability names])] in heroes.json order."""
    return [(hero, [a["name"] for a in info["abilities"]]) for hero, info in heroes.items()]


def load_hud_specs(path):
    """Checked entries of specs/hud_assets.json, [] when the file does not
    exist. Raises ValueError when it breaks the contract above."""
    try:
        data = load_json(path)
    except FileNotFoundError:
        return []
    return check_hud_specs(data)


def _is_vpk_texture(s):
    return (isinstance(s, str) and s.isascii() and s.endswith(".vtex_c") and "\\" not in s and "," not in s
            and not s.startswith("/") and ".." not in s.split("/"))


def check_hud_specs(data):
    if not isinstance(data, list):
        raise ValueError("hud_assets.json: expected a JSON list of entries")
    out, seen = [], set()
    for n, e in enumerate(data):
        where = f"hud_assets.json entry {n}"
        if not isinstance(e, dict):
            raise ValueError(f"{where}: expected an object")
        unknown = sorted(set(e) - HUD_FIELDS)
        if unknown:
            raise ValueError(f"{where}: unknown field(s) {unknown}")
        target = e.get("target")
        if not (isinstance(target, str) and target.isascii() and target.lower().endswith(".blp")
                and "/" not in target and ":" not in target
                and all(part not in ("", ".", "..") for part in target.split("\\"))):
            raise ValueError(f"{where}: target must be a relative map path with backslashes ending in .blp, "
                             f"got {target!r}")
        if target.upper().startswith(RESERVED_PREFIXES):
            raise ValueError(f"{where}: {target} is in a folder the launcher fills itself")
        if target.upper() in seen:
            raise ValueError(f"{where}: duplicate target {target}")
        seen.add(target.upper())
        sources = e.get("sources")
        if not (isinstance(sources, list) and sources and all(_is_vpk_texture(s) for s in sources)):
            raise ValueError(f"{where}: sources must be a non-empty list of VPK texture paths (.vtex_c)")
        size = e.get("size")
        if size is not None and not (isinstance(size, list) and len(size) == 2
                                     and all(type(v) is int and 1 <= v <= 4096 for v in size)):
            raise ValueError(f"{where}: size must be [width, height] in pixels, got {size!r}")
        fit = e.get("fit", "stretch")
        if fit not in HUD_FITS:
            raise ValueError(f"{where}: fit must be one of {list(HUD_FITS)}, got {fit!r}")
        if e.get("kind", HUD_KIND) != HUD_KIND:
            raise ValueError(f"{where}: kind must be {HUD_KIND!r}")
        out.append({"target": target, "sources": list(sources), "size": list(size) if size else None,
                    "fit": fit, "kind": HUD_KIND})
    return out


def inputs_digest(roster, manifest, item_icons=(), hud=()):
    blob = json.dumps({"plan": PLAN_VERSION, "roster": roster, "vo": manifest, "items": list(item_icons),
                       "hud": list(hud)}, sort_keys=True)
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def vpk_prefixes(manifest, item_icons=(), hud=()):
    """VPK folders to list: the folders searched by name, plus the folder of
    every source the voice manifest, items.json and hud_assets.json name."""
    sources = list(manifest["files"].values())
    sources += [s for events in manifest.get("spares", {}).values() for lines in events.values() for s in lines]
    sources += [e["source"] for e in manifest.get("audio", {}).values() if e.get("source")]
    sources += [s for entry in list(item_icons) + list(hud) for s in entry.get("sources") or []]
    folders = set(SEARCHED_FOLDERS) | {s.rsplit("/", 1)[0] + "/" for s in sources if "/" in s}
    return tuple(sorted(f for f in folders if not any(f != g and f.startswith(g) for g in folders)))


def icon_paths(key, kind="ability"):
    """BTN, DISBTN and (heroes and abilities only) PASBTN map paths."""
    paths = (BTN.format(key=key), DISBTN.format(key=key))
    return paths if kind == "item" else paths + (PASBTN.format(key=key),)


def expected_map_files(roster, manifest, item_icons=(), hud=()):
    """Every path the map script may reference."""
    names = []
    for hero, abilities in roster:
        for key in [f"hero_{hero}"] + abilities:
            names += icon_paths(key)
    names += [p for entry in item_icons for p in icon_paths(entry["key"], "item")]
    names += list(manifest["files"])
    names += list(manifest.get("audio", {}))
    names += [entry["target"] for entry in hud]
    return names


# ---------------------------------------------------------------- planning

def _resolve_ability_icon(hero, ability, files, spellicons):
    """Exact icon, else the same name in a cosmetic subfolder, else the most
    similar icon name of the same hero, else None (the hero icon is used)."""
    exact = f"{SPELLICONS}{ability}_png.vtex_c"
    if exact in files:
        return exact, "exact"
    suffix = f"/{ability}_png.vtex_c"
    in_subfolder = sorted((p for p in spellicons if p.endswith(suffix)), key=lambda p: (p.count("/"), p))
    if in_subfolder:
        return in_subfolder[0], "subfolder"
    stem = ability[len(hero) + 1:] if ability.startswith(hero + "_") else ability
    best = None
    for p in spellicons:
        if "/" in p[len(SPELLICONS):] or not p.endswith("_png.vtex_c"):
            continue
        name = p[len(SPELLICONS):-len("_png.vtex_c")]
        if not name.startswith(hero + "_"):
            continue
        other = name[len(hero) + 1:]
        if any(m in other for m in COSMETIC_MARKERS):
            continue
        ratio = difflib.SequenceMatcher(None, stem, other).ratio()
        if best is None or (ratio, name) > (best[0], best[1]):
            best = (ratio, name, p)
    if best and best[0] >= CLOSE_NAME_MIN_RATIO:
        return best[2], f"close:{best[1]}"
    return None, "hero_icon"


def _icon_name(vpk_path):
    """'panorama/images/items/tpscroll_png.vtex_c' -> 'tpscroll'"""
    name = vpk_path.rsplit("/", 1)[-1]
    for suffix in ("_png.vtex_c", ".vtex_c"):
        if name.endswith(suffix):
            return name[:-len(suffix)]
    return name


def _resolve_item_icon(entry, files, itemicons):
    """The listed sources that exist, else the most similar item icon name,
    else none (a placeholder icon is drawn)."""
    listed = entry.get("sources") or []
    present = [s for s in listed if s in files]
    if present:
        return present, "exact" if present[0] == listed[0] else f"alternate:{_icon_name(present[0])}"
    want = _icon_name(listed[0]) if listed else entry["key"].removeprefix("item_")
    best = None
    for p in itemicons:
        if "/" in p[len(ITEMICONS):] or not p.endswith("_png.vtex_c"):
            continue
        name = p[len(ITEMICONS):-len("_png.vtex_c")]
        if any(m in name for m in COSMETIC_MARKERS):
            continue
        ratio = difflib.SequenceMatcher(None, want, name).ratio()
        if best is None or (ratio, name) > (best[0], best[1]):
            best = (ratio, name, p)
    if best and best[0] >= CLOSE_NAME_MIN_RATIO:
        return [best[2]], f"close:{best[1]}"
    return [], "placeholder"


def make_plan(files, roster, manifest, build, item_icons=(), hud=()):
    """Decide the VPK source of every map file. `files` is the VPK listing."""
    icons, sounds = [], []
    spellicons = sorted(p for p in files if p.startswith(SPELLICONS))
    for hero, abilities in roster:
        hero_sources = [p.format(hero=hero) for p in HERO_IMAGES if p.format(hero=hero) in files]
        icons.append({"key": f"hero_{hero}", "hero": hero, "kind": "hero", "sources": hero_sources,
                      "note": "exact" if hero_sources else "missing"})
        for ability in abilities:
            source, note = _resolve_ability_icon(hero, ability, files, spellicons)
            icons.append({"key": ability, "hero": hero, "kind": "ability",
                          "sources": ([source] if source else []) + hero_sources, "note": note})
    itemicons = sorted(p for p in files if p.startswith(ITEMICONS))
    for entry in item_icons:
        sources, note = _resolve_item_icon(entry, files, itemicons)
        icons.append({"key": entry["key"], "kind": "item", "sources": sources, "note": note})

    images = []
    for entry in hud:
        present = [s for s in entry["sources"] if s in files]
        note = ("exact" if present and present[0] == entry["sources"][0]
                else f"fallback:{_icon_name(present[0])}" if present else "missing")
        images.append(dict(entry, sources=present, note=note))

    used = set()
    for target in sorted(manifest["files"]):
        source = manifest["files"][target]
        hero, rest = target.split("\\")[2], target.split("\\")[3]
        event = rest.rsplit("_", 1)[0]
        note = "manifest"
        if source not in files:
            spares = manifest.get("spares", {}).get(hero, {}).get(event, [])
            source = next((s for s in spares if s in files and s not in used), None)
            note = "spare" if source else "missing"
        if source:
            used.add(source)
        sounds.append({"target": target, "hero": hero, "event": event, "source": source, "note": note})

    audio = []
    for target in sorted(manifest.get("audio", {})):
        entry = manifest["audio"][target]
        source = entry.get("source") if entry.get("source") in files else None
        audio.append({"target": target, "source": source, "mono": bool(entry.get("mono")),
                      "note": "manifest" if source else "missing"})

    extract = sorted({s for i in icons + images for s in i["sources"]} | {s["source"] for s in sounds if s["source"]}
                     | {a["source"] for a in audio if a["source"]})
    return {"plan_version": PLAN_VERSION, "build": build, "icons": icons, "hud": images, "sounds": sounds,
            "audio": audio, "extract": extract, "failed": []}


# -------------------------------------------------------------- conversion

def square(image):
    """Square crop: centre for wide images (hero portrait cards), upper part
    for tall ones (hero selection art, where the face sits)."""
    w, h = image.size
    if w == h:
        return image
    if w > h:
        x = (w - h) // 2
        return image.crop((x, 0, x + h, h))
    side = round(w * 0.85)
    x = (w - side) // 2
    y = min(round(h * 0.125), h - side)
    return image.crop((x, y, x + side, y + side))


_DISABLED_LUT = [round(v * 0.55) for v in range(256)]


def disabled(image):
    """Desaturated and darkened, like Warcraft III's DISBTN icons."""
    gray = image.convert("L").point(_DISABLED_LUT)
    return Image.merge("RGBA", (gray, gray, gray, image.getchannel("A")))


def load_rgba(png_bytes):
    image = Image.open(io.BytesIO(png_bytes))
    image.load()
    return image.convert("RGBA")


def icon_image(png_bytes):
    image = square(load_rgba(png_bytes))
    return image.resize((ICON_SIZE, ICON_SIZE), Image.Resampling.LANCZOS)


def placeholder_icon():
    image = Image.new("RGBA", (ICON_SIZE, ICON_SIZE), (40, 40, 48, 255))
    inner = Image.new("RGBA", (ICON_SIZE - 8, ICON_SIZE - 8), (70, 70, 84, 255))
    image.paste(inner, (4, 4))
    return image


def pot_side(v):
    """Next power of two >= v (v <= HUD_MAX_SIDE)."""
    return 1 << max(0, v - 1).bit_length()


def hud_image(image, size, fit):
    """Power-of-two RGBA image of a HUD entry (see the contract above); None
    gives the placeholder. Returns (image, note on a size change or None)."""
    if image is None:
        image = Image.new("RGBA", tuple(size) if size else (ICON_SIZE, ICON_SIZE), HUD_PLACEHOLDER)
    requested = tuple(size) if size else image.size
    want = tuple(min(v, HUD_MAX_SIDE) for v in requested)
    pot = tuple(pot_side(v) for v in want)
    if fit == "pad":
        if image.size != want:
            image = image.resize(want, Image.Resampling.LANCZOS)
        if pot != want:
            canvas = Image.new("RGBA", pot, (0, 0, 0, 0))
            canvas.paste(image, (0, 0))
            image = canvas
    elif image.size != pot:
        image = image.resize(pot, Image.Resampling.LANCZOS)
    note = None if pot == requested else f"{requested[0]}x{requested[1]} -> {pot[0]}x{pot[1]} ({fit})"
    return image, note


def is_mp3(data):
    return data[:3] == b"ID3" or (len(data) > 2 and data[0] == 0xFF and data[1] & 0xE0 == 0xE0)


def is_wav(data):
    return data[:4] == b"RIFF" and data[8:12] == b"WAVE"


def wav_bytes(pcm, rate, channels=1, bits=16):
    """A canonical 44-byte-header PCM WAV around raw little-endian samples."""
    block = channels * bits // 8
    return (b"RIFF" + struct.pack("<I", 36 + len(pcm)) + b"WAVEfmt "
            + struct.pack("<IHHIIHH", 16, 1, channels, rate, rate * block, block, bits)
            + b"data" + struct.pack("<I", len(pcm)) + pcm)


def silent_wav():
    return wav_bytes(bytes(SILENT_WAV_RATE // 10 * 2), SILENT_WAV_RATE)


def wav_to_mono(data):
    """Stereo 16-bit PCM WAV -> mono (the mean of both channels). Anything else
    comes back unchanged. Raises ValueError on a broken RIFF file."""
    chunks, pos = {}, 12
    while pos + 8 <= len(data):
        cid, size = data[pos:pos + 4], struct.unpack_from("<I", data, pos + 4)[0]
        chunks.setdefault(cid, (pos + 8, size))
        pos += 8 + size + (size & 1)
    if b"fmt " not in chunks or b"data" not in chunks:
        raise ValueError("WAV without fmt or data chunk")
    fmt_at = chunks[b"fmt "][0]
    tag, channels, rate, _, _, bits = struct.unpack_from("<HHIIHH", data, fmt_at)
    if tag != 1 or bits != 16 or channels != 2:
        return data
    at, size = chunks[b"data"]
    pcm = array.array("h")
    pcm.frombytes(data[at:at + min(size, len(data) - at) // 4 * 4])
    if sys.byteorder != "little":
        pcm.byteswap()
    mono = array.array("h", [(left + right) >> 1 for left, right in zip(pcm[0::2], pcm[1::2])])
    if sys.byteorder != "little":
        mono.byteswap()
    return wav_bytes(mono.tobytes(), rate)


def audio_file(data, target, mono):
    """Map bytes for an audio target from the exported file, or None when the
    file is not in the format the target's extension names."""
    if target.lower().endswith(".wav"):
        if not data or not is_wav(data):
            return None
        try:
            return wav_to_mono(data) if mono else data
        except (ValueError, struct.error):
            return None
    return data if data and is_mp3(data) else None


def build_files(plan, raw_dir, log):
    """Convert extracted files into map files. Returns ({map path: bytes}, report)."""
    out = {}
    report = {"icon_fallbacks": [], "icon_placeholders": [], "hud_fallbacks": [], "hud_placeholders": [],
              "hud_resized": [], "sound_substitutes": [], "sound_silent": [], "audio_format": [],
              "audio_silent": []}

    def read(vpk_path):
        p = find_output(raw_dir, vpk_path)      # .png, or a sound's .mp3 / .wav
        try:
            return p.read_bytes() if p else None
        except OSError:
            return None

    for icon in plan["icons"]:
        image = None
        used = None
        for source in icon["sources"]:
            data = read(source)
            if not data:
                continue
            try:
                image = icon_image(data)
                used = source
                break
            except (OSError, ValueError) as e:
                log(f"cannot decode {source}: {e}")
        if image is None:
            image = placeholder_icon()
            report["icon_placeholders"].append(icon["key"])
        elif icon["kind"] in ("ability", "item") and (icon["note"] != "exact" or used != icon["sources"][0]):
            report["icon_fallbacks"].append(f"{icon['key']} <- {used.rsplit('/', 1)[-1]}")
        normal = blp.encode(image)
        paths = icon_paths(icon["key"], icon["kind"])
        out[paths[0]] = normal
        out[paths[1]] = blp.encode(disabled(image))
        if len(paths) > 2:
            out[paths[2]] = normal

    for entry in plan.get("hud", []):
        image = used = None
        for source in entry["sources"]:
            data = read(source)
            if not data:
                continue
            try:
                image = load_rgba(data)
                used = source
                break
            except (OSError, ValueError) as e:
                log(f"cannot decode {source}: {e}")
        if image is None:
            report["hud_placeholders"].append(entry["target"])
        elif entry["note"] != "exact" or used != entry["sources"][0]:
            report["hud_fallbacks"].append(f"{entry['target']} <- {used.rsplit('/', 1)[-1]}")
        image, note = hud_image(image, entry["size"], entry["fit"])
        if note:
            report["hud_resized"].append(f"{entry['target']} {note}")
        out[entry["target"]] = blp.encode(image)

    available = {}
    for sound in plan["sounds"]:
        data = read(sound["source"]) if sound["source"] else None
        if data and is_mp3(data):
            available.setdefault((sound["hero"], sound["event"]), []).append(data)
            out[sound["target"]] = data
    for sound in plan["sounds"]:
        if sound["target"] in out:
            if sound["note"] == "spare":
                report["sound_substitutes"].append(sound["target"])
            continue
        same_event = available.get((sound["hero"], sound["event"]))
        if same_event:
            out[sound["target"]] = same_event[0]
            report["sound_substitutes"].append(sound["target"])
        else:
            out[sound["target"]] = SILENT_MP3
            report["sound_silent"].append(sound["target"])

    for entry in plan.get("audio", []):
        target = entry["target"]
        data = read(entry["source"]) if entry["source"] else None
        made = audio_file(data, target, entry["mono"])
        if made is None:
            report["audio_format" if data else "audio_silent"].append(target)
            made = silent_wav() if target.lower().endswith(".wav") else SILENT_MP3
        out[target] = made
    return out, report
