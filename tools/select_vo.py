"""Choose the Dota 2 voice lines the map uses (dev tool, run against a local
Dota 2 install whenever the roster changes).

Writes
  src/data/sounds.json       {hero: {event: ["Sound\\Dota\\<hero>\\<event>_<n>.mp3", ...]}}
                             read by the map script at build time;
  launcher/vo_manifest.json  target path -> VPK source path (+ spare lines),
                             bundled into the launcher, which extracts the
                             lines from the player's own Dota 2 install.

Nothing from Dota 2 is written to the repo: only file names.

Usage: select_vo.py --dota "<Dota 2 root>" [--vrf <Source2Viewer-CLI.exe>]
--vrf extracts the chosen lines to a temp folder to check they are MP3.
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "launcher"))

from dvc_launcher import vpkdir  # noqa: E402

# Lines per event: order responses play most often, so they get the most variety.
MAX_PER_EVENT = {"move": 8, "attack": 8, "kill": 4, "death": 4, "spawn": 4, "levelup": 4, "laugh": 4}
MAX_PER_CAST = 3            # per cast_<ability> event
MAX_PER_HERO = 64           # safety cap; the per-event caps give about 40-55
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
}
# Stems that are about items, chat, match flow or other heroes, never a spell.
NOT_ABILITY = {
    "spawn", "respawn", "respawn_ssa", "kill", "death", "level", "levelup", "laugh", "move", "attack",
    "anger", "deny", "pain", "lasthit", "notyet", "nomana", "rival", "ally", "happy", "items", "item",
    "itemcommon", "itemmoderate", "itemrare", "purch", "rare", "win", "lose", "thanks", "bottle",
    "haste", "invis", "illus", "regen", "doubdam", "immort", "scepter", "blink", "arcane", "bounty",
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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dota", required=True)
    ap.add_argument("--vrf")
    args = ap.parse_args()

    pak = os.path.join(args.dota, "game", "dota", "pak01_dir.vpk")
    files = vpkdir.read_tree(pak, ["sounds/vo/"])
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

    manifest = {
        "format": 1,
        "selected_from_build": build,
        "max_lines_per_event": dict(MAX_PER_EVENT, cast=MAX_PER_CAST),
        "max_lines_per_hero": MAX_PER_HERO,
        "files": dict(sorted(targets.items())),
        "spares": spares_out,
    }
    with open(os.path.join(ROOT, "src", "data", "sounds.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(sounds, f, indent=1, sort_keys=True)
        f.write("\n")
    with open(os.path.join(ROOT, "launcher", "vo_manifest.json"), "w", encoding="utf-8", newline="\n") as f:
        json.dump(manifest, f, indent=1)
        f.write("\n")
    for hero, folder, prefix, total, per_event, missing in report:
        print(f"{hero:10} folder={folder:10} prefix={prefix:7} lines={total:2} {per_event}")
        print(f"{'':10} no spell lines: {', '.join(missing) or '-'}")
    print(f"total lines: {len(targets)}, {sum(files[s] for s in targets.values()) / 1048576:.1f} MB of vsnd_c")


if __name__ == "__main__":
    main()
