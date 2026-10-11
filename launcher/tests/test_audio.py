"""Tests of the launcher's music, announcer and effect sounds
(launcher/dvc_launcher/assets.py "audio", vrf.find_output) and of the
repo's selection (launcher/vo_manifest.json "audio", src/data/audio.json).

Offline and synthetic: a fake VRF output folder holds a stereo 16-bit WAV, a
mono WAV, an MP3 and a WAV where an MP3 is expected. Checked: the VPK folders
and the expected map paths include the audio; the plan lists every target with
its source or "missing"; .wav exports are found next to .mp3 ones; a stereo
effect is folded to mono (same length and rate, the mean of both channels);
a source in the wrong format or missing gives a silent file of the target's
format; the conversion is byte-identical on repeat; every audio.json path is
a manifest target with the same extension, and every manifest target is in
audio.json. Never reads Dota 2.

Usage: python -I launcher/tests/test_audio.py [--work <scratch folder>]
"""
import argparse
import array
import json
import shutil
import struct
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "launcher"))

from dvc_launcher import assets, vrf  # noqa: E402

failures = []


def check(name, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f": {detail}" if detail else ""))
    if not ok:
        failures.append(name)


def stereo_wav(frames, rate=44100):
    pcm = array.array("h")
    for i in range(frames):
        pcm.extend((1000 + i, -1000 - 3 * i))
    if sys.byteorder != "little":
        pcm.byteswap()
    return assets.wav_bytes(pcm.tobytes(), rate, channels=2)


def mono_samples(data):
    pcm = array.array("h")
    pcm.frombytes(data[44:])
    if sys.byteorder != "little":
        pcm.byteswap()
    return pcm


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--work")
    args = ap.parse_args()
    work = Path(args.work) if args.work else Path(tempfile.mkdtemp(prefix="dvc_audio_"))
    shutil.rmtree(work, ignore_errors=True)
    raw = work / "raw"

    manifest = {"files": {}, "spares": {}, "audio": {
        "Sound\\Dota\\sfx\\horn.wav": {"source": "sounds/ambient/horn_radiant.vsnd_c", "mono": True},
        "Sound\\Dota\\sfx\\coins.wav": {"source": "sounds/ui/coins.vsnd_c", "mono": True},
        "Sound\\Dota\\music\\battle_01.mp3": {"source": "sounds/music/x/battle_01.vsnd_c", "mono": False},
        "Sound\\Dota\\music\\killed.mp3": {"source": "sounds/music/x/killed.vsnd_c", "mono": False},
        "Sound\\Dota\\announcer\\first_blood.mp3": {"source": "sounds/vo/announcer_x/fb.vsnd_c", "mono": False},
    }}
    files = {s["source"]: 1 for t, s in manifest["audio"].items() if "first_blood" not in t}

    # VPK folders and expected map paths
    prefixes = assets.vpk_prefixes(manifest)
    check("audio folders are listed", all(any(s.startswith(p) for p in prefixes) for s in files), prefixes)
    expected = assets.expected_map_files([], manifest)
    check("audio targets are expected in the map", set(manifest["audio"]) <= set(expected))

    # the plan
    plan = assets.make_plan(files, [], manifest, "test")
    notes = {a["target"]: a["note"] for a in plan["audio"]}
    check("plan lists every audio target", sorted(notes) == sorted(manifest["audio"]))
    check("missing source noted", notes["Sound\\Dota\\announcer\\first_blood.mp3"] == "missing")
    check("audio sources extracted", set(files) <= set(plan["extract"]))

    # a fake VRF export: WAV, WAV, MP3, and a WAV where an MP3 is expected
    horn = stereo_wav(4410)
    mp3 = assets.SILENT_MP3 * 3
    exported = {
        "sounds/ambient/horn_radiant.wav": horn,
        "sounds/ui/coins.wav": assets.silent_wav(),
        "sounds/music/x/battle_01.mp3": mp3,
        "sounds/music/x/killed.wav": stereo_wav(100),
    }
    for rel, data in exported.items():
        p = raw / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
    check("find_output finds a .wav export", vrf.find_output(raw, "sounds/ui/coins.vsnd_c") == raw / "sounds/ui/coins.wav")
    check("find_output prefers nothing that is not there", vrf.find_output(raw, "sounds/none.vsnd_c") is None)
    check("find_output keeps textures", vrf.output_candidates("a/b_png.vtex_c") == ("a/b_png.png",))

    out, report = assets.build_files(plan, raw, print)
    folded = out["Sound\\Dota\\sfx\\horn.wav"]
    ch, rate = struct.unpack_from("<HI", folded, 22)
    check("stereo effect folded to mono", ch == 1 and rate == 44100, f"ch={ch} rate={rate}")
    samples = mono_samples(folded)
    check("mono keeps the length", len(samples) == 4410, len(samples))
    check("mono is the mean of both channels", samples[0] == 0 and samples[10] == (1010 - 1030) >> 1,
          f"{samples[0]} {samples[10]}")
    check("a mono WAV stays as it is", out["Sound\\Dota\\sfx\\coins.wav"] == assets.silent_wav())
    check("MP3 copied as is", out["Sound\\Dota\\music\\battle_01.mp3"] == mp3)
    check("WAV where an MP3 is expected -> silent MP3", out["Sound\\Dota\\music\\killed.mp3"] == assets.SILENT_MP3)
    check("missing source -> silent MP3", out["Sound\\Dota\\announcer\\first_blood.mp3"] == assets.SILENT_MP3)
    check("report names them", report["audio_format"] == ["Sound\\Dota\\music\\killed.mp3"]
          and report["audio_silent"] == ["Sound\\Dota\\announcer\\first_blood.mp3"], report)
    again, _ = assets.build_files(plan, raw, print)
    check("byte-identical on repeat", again == out)
    check("a broken WAV is refused", assets.audio_file(b"RIFF\x00\x00\x00\x00WAVEjunk", "x.wav", True) is None)

    # the repo's selection: audio.json and the manifest agree
    real = assets.load_json(ROOT / "launcher" / "vo_manifest.json")
    data = assets.load_json(ROOT / "src" / "data" / "audio.json")
    paths = {e["path"] for g in ("music", "announcer", "sfx") for e in data.get(g, {}).values()}
    check("every audio.json path is a manifest target", paths <= set(real.get("audio", {})),
          sorted(paths - set(real.get("audio", {})))[:3])
    check("every manifest target is in audio.json", set(real.get("audio", {})) <= paths)
    check("targets live in the launcher's sound folder",
          all(t.startswith("Sound\\Dota\\") for t in real.get("audio", {})))
    loops = [k for k, e in data.get("music", {}).items() if e.get("sync")]
    check("loop tracks carry sync points", all(data["music"][k]["sync"] == sorted(data["music"][k]["sync"])
                                               for k in loops) and len(loops) >= 4, loops)
    json.dumps(data)

    shutil.rmtree(work, ignore_errors=True)
    print("all passed" if not failures else f"{len(failures)} failed: {failures}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
