"""Choose the Dota 2 voice lines, music, announcer lines and effects the map
uses (dev tool, run against a local Dota 2 install whenever the roster or the
sound selection changes).

Writes
  src/data/sounds.json       {hero: {event: ["Sound\\Dota\\<hero>\\<event>_<n>.mp3", ...]}}
                             read by the map script at build time;
  src/data/audio.json        {music|announcer|sfx: {key: {path, duration, volume, ...}}}:
                             the default music pack, the default announcer and
                             the game's effects, with Dota's own durations,
                             volumes and loop points (from the sound event
                             scripts); read by music.lua, announcer.lua and
                             gamesounds.lua;
  launcher/vo_manifest.json  target path -> VPK source path (+ spare lines) for
                             the voice lines, and "audio": target ->
                             {source, mono}; bundled into the launcher, which
                             extracts the files from the player's own Dota 2.

Nothing from Dota 2 is written to the repo: only file names and numbers.

Usage: select_vo.py --dota "<Dota 2 root>" --vrf <Source2Viewer-CLI.exe>
--vrf decompiles the sound event scripts and extracts the chosen files to a
temp folder, to check the voice lines are MP3 and to learn each effect's
format (MP3 or WAV).
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import wave

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "launcher"))

from dvc_launcher import vpkdir  # noqa: E402

# Lines per event: order responses play most often, so they get the most variety.
MAX_PER_EVENT = {"move": 8, "attack": 8, "kill": 4, "death": 4, "spawn": 4, "levelup": 4, "laugh": 4,
                 "respawn": 2, "battlebegins": 1, "notyet": 2, "nomana": 2, "firstblood": 1, "aegis": 1,
                 "rune_doubledamage": 1, "rune_haste": 1, "rune_illusion": 1, "rune_invisibility": 1,
                 "rune_regeneration": 1, "rune_arcane": 1, "rune_bounty": 1}
MAX_PER_CAST = 3            # per cast_<ability> event
MAX_PER_HERO = 80           # safety cap; the per-event caps give about 55-70
# vsnd_c size limit: about 6 s of 64 kbit/s MP3 plus resource headers.
MAX_LINE_BYTES = 52_000
# Sub-voices inside the default VO prefix (e.g. "pud_arc_..." when the arcana
# family has no spawn lines of its own): never used.
COSMETIC_STEMS = ("arc_", "arcana_", "persona_")

# Generic events and the VO stems (after the hero's VO prefix) that feed them.
GENERIC_EVENTS = {
    "move": ["move"],
    "attack": ["attack"],
    "kill": ["kill"],
    "death": ["death"],
    "spawn": ["spawn"],
    "levelup": ["levelup", "level"],
    "laugh": ["laugh"],
    # Dota's other hero responses (src/game/gamesounds.lua, voice.lua, announcer.lua)
    "respawn": ["respawn"],
    "battlebegins": ["battlebegins", "begin"],     # the horn at 0:00
    "notyet": ["notyet"],                          # cast while on cooldown
    "nomana": ["nomana"],                          # cast without the mana
    "firstblood": ["firstblood"],
    "aegis": ["immort"],                           # picked up the Aegis of the Immortal
    "rune_doubledamage": ["doubdam", "doubledam"],
    "rune_haste": ["haste"],
    "rune_illusion": ["illus"],
    "rune_invisibility": ["invis"],
    "rune_regeneration": ["regen"],
    "rune_arcane": ["arcane"],
    "rune_bounty": ["bounty"],
}
# Stems that are about items, chat, match flow or other heroes, never a spell.
NOT_ABILITY = {
    "spawn", "respawn", "respawn_ssa", "kill", "death", "level", "levelup", "laugh", "move", "attack",
    "anger", "deny", "pain", "lasthit", "notyet", "nomana", "rival", "ally", "happy", "items", "item",
    "itemcommon", "itemmoderate", "itemrare", "purch", "rare", "win", "lose", "thanks", "bottle",
    "haste", "invis", "illus", "regen", "doubdam", "doubledam", "immort", "scepter", "blink", "arcane", "bounty",
    "crumwiz", "shiwiz", "shitwiz", "inthebag", "firstblood", "fastres", "fastressuicide", "begin",
    "battlebegins", "underattack", "cast", "failure", "ability_failure", "ability_test", "lane_missing",
    "missing_lane", "lanemissing", "drop_common", "drop_medium", "drop_rare", "acknow", "taunt",
    "magicuser", "manta", "rapier", "resist", "relic", "travel", "first", "equipping", "set_complete",
    "view_victory", "view_defeat", "nomnom", "getoff", "cool", "castsstolenspell", "spellstealends",
    "detonatekill", "minekill", "mineblowsup", "trapgoesoff", "ability_hook_miss", "ability_repfriend",
    "ability_multi_hit", "nullfield",
}
# Spell lines whose stem does not resemble the current ability name.
ALIASES = {
    "pudge_dismember": ["ability_devour"],
    "nevermore_dark_lord": ["ability_presence"],
    "nevermore_necromastery": ["ability_mastery"],
    "techies_land_mines": ["setmine"],
}
STOPWORDS = {"of", "the", "a"}


def stem_tokens(text):
    return [t for t in re.split(r"[_\d]+", text) if t and t not in STOPWORDS]


def matches(ability_key, stem):
    """Heuristic match between an ability name (hero prefix removed) and a VO
    stem: 'meat_hook'~'ability_hook', 'holy_persuasion'~'ability_holyp',
    'telekinesis'~'telekinesis_up', 'suicide'~'suicidesquad'."""
    s = stem[len("ability_"):] if stem.startswith("ability_") else stem
    tokens = stem_tokens(ability_key)
    # 'hand_of_god' -> 'handgod' and 'handofgod'
    keys = {"".join(tokens), re.sub(r"[_\d]+", "", ability_key)}
    compact_stem = "".join(stem_tokens(s))
    if not tokens or not compact_stem:
        return False
    for key in keys:
        if len(compact_stem) >= 4 and key.startswith(compact_stem):
            return True
        if len(key) >= 5 and compact_stem.startswith(key):
            return True
    return len(compact_stem) >= 3 and any(t.startswith(compact_stem) for t in tokens)


def parse_line(name):
    """'pud_spawn_01' -> ('pud_spawn', (1, '')); 'mrph_move_01a' -> ('mrph_move', (1, 'a'))."""
    m = re.match(r"^(?P<stem>.+?)_(?P<num>\d+)(?P<sfx>[a-z]?)$", name)
    if not m:
        return None
    return m.group("stem"), (int(m.group("num")), m.group("sfx"))


def vo_folder(pak, files, hero):
    """The VO folder comes from the hero's VoiceFile; falls back to the hero name."""
    path = f"scripts/npc/heroes/npc_dota_hero_{hero}.txt"
    try:
        import vpk  # dev-only dependency, used to read one text file
        text = vpk.open(pak).get_file(path).read().decode("utf-8", "replace")
        m = re.search(r'"VoiceFile"\s+"soundevents/voscripts/game_sounds_vo_(\w+)\.vsndevts"', text)
        if m and any(p.startswith(f"sounds/vo/{m.group(1)}/") for p in files):
            return m.group(1)
    except (ImportError, KeyError, OSError):
        pass
    return hero


def hero_lines(files, folder):
    """{prefix: {stem: [(order, vpk path, size)]}} grouped by VO prefix."""
    lines = {}
    base = f"sounds/vo/{folder}/"
    for path, size in files.items():
        if not path.startswith(base) or not path.endswith(".vsnd_c") or "/" in path[len(base):]:
            continue
        parsed = parse_line(path[len(base):-len(".vsnd_c")])
        if parsed:
            full_stem, order = parsed
            lines.setdefault(full_stem, []).append((order, path, size))
    for v in lines.values():
        v.sort()
    return lines


def voice_families(lines):
    """VO prefixes that have '<P>spawn_NN' lines, e.g. 'pud_', 'pud_arc_'
    (arcana), 'toy_pug_' (persona). The shortest one is the default voice."""
    prefixes = [stem[:-len("spawn")] for stem in lines if stem.endswith("spawn") and stem != "spawn"]
    prefixes = sorted({p for p in prefixes if p.endswith("_")}, key=lambda p: (len(p), p))
    if not prefixes:
        raise SystemExit("no spawn lines found")
    return prefixes


def select_hero(hero, abilities, lines, prefix, families):
    # Only the default voice: other families (arcana, persona) are left out.
    other = [f for f in families if f != prefix and f.startswith(prefix)]
    stems = {s[len(prefix):]: v for s, v in lines.items()
             if s.startswith(prefix) and not any(s.startswith(f) for f in other)
             and not s[len(prefix):].startswith(COSMETIC_STEMS)}

    def pool(stem_names):
        out = []
        for s in stem_names:
            out += [p for _, p, size in stems.get(s, []) if size <= MAX_LINE_BYTES]
        return out

    events = []    # (event, candidate list) in priority order
    for event, stem_names in GENERIC_EVENTS.items():
        candidates = pool(stem_names)
        if candidates:
            events.append((event, candidates))

    spell_stems = sorted(s for s in stems if s not in NOT_ABILITY)
    cast = []      # (ability, stems)
    for ability in abilities:
        key = ability[len(hero) + 1:] if ability.startswith(hero + "_") else ability
        found = [s for s in ALIASES.get(ability, []) if s in stems]
        found += [s for s in spell_stems if s not in found and matches(key, s)]
        if found:
            cast.append((ability, tuple(found)))
    # Abilities that share the same lines (shadowraze 1/2/3) split them.
    groups = {}
    for ability, found in cast:
        groups.setdefault(found, []).append(ability)
    for ability, found in cast:
        members = groups[found]
        candidates = pool(found)[members.index(ability)::len(members)]
        if candidates:
            events.append((f"cast_{ability}", candidates))

    chosen = {e: [] for e, _ in events}
    total = 0
    for round_index in range(max(MAX_PER_EVENT.values())):
        for event, candidates in events:
            if total >= MAX_PER_HERO:
                break
            if round_index < min(len(candidates), MAX_PER_EVENT.get(event, MAX_PER_CAST)):
                chosen[event].append(candidates[round_index])
                total += 1
    spares = {e: c[len(chosen[e]):len(chosen[e]) + 4] for e, c in events}
    return {e: v for e, v in chosen.items() if v}, spares, [a for a, _ in cast]


def check_mp3(vrf, pak, sources):
    """Extract the chosen lines with VRF and return those that are not MP3."""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "out")
        batch = []
        batches = []
        for s in sorted(sources):
            if sum(len(x) + 1 for x in batch) + len(s) > 7000:
                batches.append(batch)
                batch = []
            batch.append(s)
        batches.append(batch)
        for b in batches:
            subprocess.run([vrf, "-i", pak, "-d", "-o", out, "-f", ",".join(b)], cwd=tmp,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)
        bad = []
        for s in sources:
            mp3 = os.path.join(out, s[:-len(".vsnd_c")] + ".mp3")
            if not os.path.isfile(mp3):
                bad.append(s)
        return bad


# ------------------------------------------------------------------ audio
# The default music pack, the default announcer and the game's own effects,
# by Dota sound event name. Durations, volumes and loop points come from the
# events (soundevents/*.vsndevts_c); the map path's extension from the file
# VRF exports (MP3 or WAV). "mono": effects are folded to one channel by the
# launcher (smaller, and Warcraft III places mono sounds in 3D).
MUSIC_PACK = "valve_dota_001"
SOUND_EVENT_FILES = [
    f"soundevents/music/{MUSIC_PACK}/soundevents_music.vsndevts_c",
    f"soundevents/music/{MUSIC_PACK}/soundevents_stingers.vsndevts_c",
    "soundevents/music/game_sounds_stingers_main.vsndevts_c",
    "soundevents/voscripts/game_sounds_vo_announcer.vsndevts_c",
    "soundevents/voscripts/game_sounds_vo_announcer_killing_spree.vsndevts_c",
    "soundevents/game_sounds.vsndevts_c",
    "soundevents/game_sounds_ui_imported.vsndevts_c",
]
LANES = ("top", "mid", "bot")
AUDIO = {
    "music": {
        "countdown": f"{MUSIC_PACK}.music.countdown",           # pre-game, stopped by the horn
        # laning: layer 1 is the full arrangement (layers 2 and 3 are quiet accents)
        "laning_01": f"{MUSIC_PACK}.music.laning_01_layer_01",
        "laning_02": f"{MUSIC_PACK}.music.laning_02_layer_01",
        "laning_03": f"{MUSIC_PACK}.music.laning_03_layer_01",
        **{f"battle_0{n}": f"{MUSIC_PACK}.music.battle_0{n}" for n in (1, 2, 3)},
        **{f"battle_0{n}_end": f"{MUSIC_PACK}.music.battle_0{n}_end" for n in (1, 2, 3)},
        "roshan": f"{MUSIC_PACK}.music.roshan",
        "roshan_end": f"{MUSIC_PACK}.music.roshan_end",
        "killed": f"{MUSIC_PACK}.music.killed",
        "respawn": f"{MUSIC_PACK}.stinger.respawn",
        "buy_back": f"{MUSIC_PACK}.stinger.buy_back_player",
        "radiant_win": f"{MUSIC_PACK}.stinger.radiant_win",
        "radiant_lose": f"{MUSIC_PACK}.stinger.radiant_lose",
    },
    "announcer": {
        **{k: f"announcer_announcer_{k}" for k in ("count_battle_30", "count_battle_10", "anc_attack_yr",
                                                   "roshan_fallen_rad", "roshan_fallen_dire", "victory_rad",
                                                   "victory_dire", "fort_rad", "cour_kill_rad")},
        "battle_prepare": "announcer_announcer_battle_prepare_01",
        "battle_begin": "announcer_announcer_battle_begin_01",
        "scan_rad": "announcer_announcer_scan_rad_01",
        "tower_fallen": "announcer_announcer_tower_fallen_01",           # T4: "Your tower has fallen."
        "tower_enemy_fallen": "announcer_announcer_tower_enemy_fallen_01",
        "tower_attack": "announcer_announcer_tower_attack_01",
        **{f"{kind}_{lane}": f"announcer_announcer_{kind}_{lane}" for lane in LANES
           for kind in ("twr_fall_yr", "twr_deny_yr", "twr_attack_yr", "rax_fall_yr", "rax_attack_yr")},
        "first_blood": "announcer_killing_spree_announcer_1stblood_01",
        **{f"kill_{k}": f"announcer_killing_spree_announcer_kill_{k}_01"
           for k in ("double", "triple", "ultra", "rampage", "spree", "dominate", "mega", "unstop", "wicked",
                     "monster", "godlike", "holy")},
    },
    "sfx": {
        "horn": "GameStart.RadiantAncient",
        "coins": "General.Coins",                  # last hits, bounties and sells
        "deny": "UI.Deny.Melee",
        "buy": "General.Buy",
        "combine": "General.Combine",
        "levelup": "General.LevelUp",
        "learn": "General.AbilityLearned",
        "fail_mana": "General.CastFail_NoMana",
        "fail_cooldown": "General.CastFail_AbilityInCooldown",
        "error": "General.NoGold",                 # Dota's generic "no" click
        "rune_doubledamage": "Rune.DD",
        "rune_haste": "Rune.Haste",
        "rune_illusion": "Rune.Illusion",
        "rune_invisibility": "Rune.Invis",
        "rune_regeneration": "Rune.Regen",
        "rune_arcane": "Rune.Arcane",
        "rune_bounty": "Rune.Bounty",
        "rune_water": "Rune.Water",
        "rune_shield": "Rune.Shield",
        "tp_loop_dest": "Portal.Loop_Appear",      # at the target while the scroll channels
        "tp_loop_origin": "Portal.Loop_Disappear",  # at the hero while it channels
        "tp_appear": "Portal.Hero_Appear",
        "tp_disappear": "Portal.Hero_Disappear",
        "roshan_death": "Roshan.Death",
        "reincarnate": "DOTAMusic_Hero.Reincarnate",   # the Aegis revive, a 3D stinger at the hero
    },
}
# Event fields copied into audio.json (as start/stop/sync/restart).
LOOP_FIELDS = {"start_point": "start", "end_point": "stop", "syncpoints": "sync", "restart_time": "restart"}

_KV3_TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|[{}\[\]=,]|[^\s{}\[\]=,"]+')


def parse_kv3(text):
    """The KV3 text VRF writes for sound event files: objects, arrays,
    strings, numbers and booleans."""
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    tokens = _KV3_TOKEN.findall(text)
    pos = 0

    def value():
        nonlocal pos
        tok = tokens[pos]
        pos += 1
        if tok == "{":
            obj = {}
            while tokens[pos] != "}":
                key = tokens[pos].strip('"')
                if tokens[pos + 1] != "=":
                    raise ValueError(f"KV3: expected '=' after {key}")
                pos += 2
                obj[key] = value()
            pos += 1
            return obj
        if tok == "[":
            arr = []
            while tokens[pos] != "]":
                if tokens[pos] == ",":
                    pos += 1
                    continue
                arr.append(value())
            pos += 1
            return arr
        if tok.startswith('"'):
            return tok[1:-1].replace("\\\\", "\\")
        if tok in ("true", "false"):
            return tok == "true"
        try:
            return float(tok)
        except ValueError:
            return tok

    return value()


def vrf_export(vrf, pak, sources, out):
    """VRF -d export of VPK paths into `out` (batched command lines)."""
    os.makedirs(out, exist_ok=True)
    batch, batches = [], []
    for s in sorted(sources):
        if sum(len(x) + 1 for x in batch) + len(s) > 7000:
            batches.append(batch)
            batch = []
        batch.append(s)
    batches.append(batch)
    for b in batches:
        if b:
            subprocess.run([vrf, "-i", pak, "-d", "-o", out, "-f", ",".join(b)], cwd=os.path.dirname(out),
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)


def sound_events(vrf, pak, tmp):
    """{event name: fields} merged from SOUND_EVENT_FILES."""
    out = os.path.join(tmp, "events")
    vrf_export(vrf, pak, SOUND_EVENT_FILES, out)
    events = {}
    for f in SOUND_EVENT_FILES:
        path = os.path.join(out, f[:-len("_c")])
        with open(path, encoding="utf-8") as fh:
            events.update(parse_kv3(fh.read()))
    return events


def vsnd_source(event):
    files = event.get("vsnd_files")
    first = files[0] if isinstance(files, list) else files
    return first.replace("\\", "/") + "_c" if first else None


def select_audio(vrf, pak, files, tmp):
    """(audio.json data, manifest "audio" section, report lines)."""
    events = sound_events(vrf, pak, tmp)
    chosen = {}                          # (group, key) -> (event, source)
    report = []
    for group, entries in AUDIO.items():
        for key, name in entries.items():
            ev = events.get(name)
            source = vsnd_source(ev) if ev else None
            if not source or source not in files:
                report.append(f"missing: {group}.{key} ({name})")
                continue
            chosen[(group, key)] = (ev, source)
    out = os.path.join(tmp, "audio")
    vrf_export(vrf, pak, {s for _, s in chosen.values()}, out)
    data, section, total = {g: {} for g in AUDIO}, {}, 0
    for (group, key), (ev, source) in sorted(chosen.items()):
        stem = os.path.join(out, source[:-len(".vsnd_c")])
        if os.path.isfile(stem + ".mp3"):
            ext, mono, size = "mp3", False, os.path.getsize(stem + ".mp3")
        elif os.path.isfile(stem + ".wav"):
            with wave.open(stem + ".wav", "rb") as w:
                stereo = w.getnchannels() == 2 and w.getsampwidth() == 2
            ext, mono = "wav", group == "sfx" and stereo
            size = os.path.getsize(stem + ".wav") // (2 if mono else 1)
        else:
            report.append(f"not exported: {group}.{key} ({source})")
            continue
        target = f"Sound\\Dota\\{group}\\{key}.{ext}"
        entry = {"path": target, "duration": round(float(ev.get("vsnd_duration", 0)), 3),
                 "volume": round(float(ev.get("volume", 1.0)), 3)}
        for field, name in LOOP_FIELDS.items():
            if field in ev:
                v = ev[field]
                entry[name] = [round(float(x), 3) for x in v] if isinstance(v, list) else round(float(v), 3)
        data[group][key] = entry
        section[target] = {"source": source, "mono": mono}
        total += size
    report.append(f"audio: {len(section)} files, about {total / 1048576:.1f} MB in the map")
    return data, section, report


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dota", required=True)
    ap.add_argument("--vrf", required=True)
    args = ap.parse_args()
    args.vrf = os.path.abspath(args.vrf)   # VRF runs from a temp folder

    pak = os.path.join(args.dota, "game", "dota", "pak01_dir.vpk")
    files = vpkdir.read_tree(pak, ["sounds/"])
    with open(os.path.join(ROOT, "src", "data", "heroes.json"), encoding="utf-8") as f:
        roster = json.load(f)
    build = ""
    acf = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(args.dota))), "appmanifest_570.acf")
    if os.path.isfile(acf):
        m = re.search(r'"buildid"\s+"(\d+)"', open(acf, encoding="utf-8", errors="replace").read())
        build = m.group(1) if m else ""

    sounds, targets, spares_out, report = {}, {}, {}, []
    excluded = set()
    for _attempt in range(3):
        sounds, targets, spares_out, report = {}, {}, {}, []
        for hero, info in roster.items():
            abilities = [a["name"] for a in info["abilities"]]
            folder = vo_folder(pak, files, hero)
            lines = hero_lines({p: s for p, s in files.items() if p not in excluded}, folder)
            families = voice_families(lines)
            prefix = families[0]
            chosen, spares, cast_abilities = select_hero(hero, abilities, lines, prefix, families)
            sounds[hero] = {}
            for event in sorted(chosen):
                paths = []
                for n, source in enumerate(chosen[event], 1):
                    target = f"Sound\\Dota\\{hero}\\{event}_{n}.mp3"
                    paths.append(target)
                    targets[target] = source
                sounds[hero][event] = paths
            spares_out[hero] = {e: v for e, v in sorted(spares.items()) if v and e in chosen}
            missing = [a for a in abilities if a not in cast_abilities]
            report.append((hero, folder, prefix, sum(len(v) for v in chosen.values()),
                           {e: len(v) for e, v in sorted(chosen.items())}, missing))
        if not args.vrf:
            break
        bad = check_mp3(args.vrf, pak, set(targets.values()))
        if not bad:
            break
        print(f"not MP3, excluded: {bad}")
        excluded.update(bad)

    with tempfile.TemporaryDirectory() as tmp:
        audio, audio_section, audio_report = select_audio(args.vrf, pak, files, tmp)
    audio["pack"] = MUSIC_PACK
    audio["selected_from_build"] = build

    manifest = {
        "format": 1,
        "selected_from_build": build,
        "max_lines_per_event": dict(MAX_PER_EVENT, cast=MAX_PER_CAST),
        "max_lines_per_hero": MAX_PER_HERO,
        "files": dict(sorted(targets.items())),
        "spares": spares_out,
        "audio": dict(sorted(audio_section.items())),
    }
    with open(os.path.join(ROOT, "src", "data", "sounds.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(sounds, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(ROOT, "src", "data", "audio.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(audio, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(ROOT, "launcher", "vo_manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")
    for hero, folder, prefix, total, per_event, missing in report:
        print(f"{hero:10} folder={folder:10} prefix={prefix:7} lines={total:2} {per_event}")
        print(f"{'':10} no spell lines: {', '.join(missing) or '-'}")
    print(f"total lines: {len(targets)}, {sum(files[s] for s in targets.values()) / 1048576:.1f} MB of vsnd_c")
    for line in audio_report:
        print(line)


if __name__ == "__main__":
    main()
