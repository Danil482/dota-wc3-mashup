"""Run the bundled VRF CLI (Source2Viewer-CLI, MIT) to export files from a VPK."""
import os
import subprocess
from pathlib import Path

CREATE_NO_WINDOW = 0x08000000
# Each -f filter is one comma-separated list; keep command lines far below
# the 32767-character CreateProcess limit.
MAX_FILTER_CHARS = 24000


class VrfError(Exception):
    pass


def output_path(vpk_path):
    """Where VRF writes a decompiled file, relative to its output folder."""
    if vpk_path.endswith(".vtex_c"):
        return vpk_path[:-len(".vtex_c")] + ".png"
    if vpk_path.endswith(".vsnd_c"):
        return vpk_path[:-len(".vsnd_c")] + ".mp3"
    raise ValueError(f"unsupported resource type: {vpk_path}")


def batches(paths):
    batch, length = [], 0
    for p in paths:
        if batch and length + len(p) + 1 > MAX_FILTER_CHARS:
            yield batch
            batch, length = [], 0
        batch.append(p)
        length += len(p) + 1
    if batch:
        yield batch


def extract(vrf_exe, vpk, paths, out_dir, work_dir, log, threads=4):
    """Export `paths` (VPK paths) from `vpk` into `out_dir`. VRF runs with its
    working directory set to `work_dir`, a scratch folder."""
    vrf_exe = Path(vrf_exe)
    if not vrf_exe.is_file():
        raise VrfError(f"VRF CLI not found: {vrf_exe}")
    Path(out_dir).mkdir(parents=True, exist_ok=True)
    Path(work_dir).mkdir(parents=True, exist_ok=True)
    env = dict(os.environ)
    env["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
    for n, batch in enumerate(batches(sorted(paths)), 1):
        cmd = [str(vrf_exe), "-i", str(vpk), "-d", "-o", str(out_dir), "--threads", str(threads),
               "-f", ",".join(batch)]
        log(f"VRF batch {n}: {len(batch)} files")
        try:
            proc = subprocess.run(cmd, cwd=str(work_dir), env=env, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                  creationflags=CREATE_NO_WINDOW, timeout=900)
        except (OSError, subprocess.TimeoutExpired) as e:
            raise VrfError(f"VRF could not run: {e}") from e
        text = proc.stdout.decode("utf-8", "replace")
        errors = [line for line in text.splitlines() if "exception" in line.lower() or "error" in line.lower()]
        for line in errors[:20]:
            log(f"VRF: {line.strip()}")
        if proc.returncode != 0:
            tail = "\n".join(text.splitlines()[-15:])
            raise VrfError(f"VRF exited with code {proc.returncode}:\n{tail}")
