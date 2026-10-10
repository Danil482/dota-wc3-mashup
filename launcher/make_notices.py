"""Write THIRD_PARTY_NOTICES.txt for dist/DotaVsCommander/.

Licence texts come from launcher/licenses/ (VRF, StormLib) and from the
installed packages that PyInstaller bundles (PyInstaller, Pillow, Python), so
the notices always match the versions actually shipped.

Usage: python make_notices.py <output file>
"""
import sys
from importlib import metadata
from pathlib import Path

HERE = Path(__file__).resolve().parent

VRF_VERSION = "20.0"
VRF_SHA256 = "d32ab327b8bbb42a2528866afb03bb582bdb779d0005488da32b90292afd3ff5"
STORMLIB_VERSION = "9.40"
STORMLIB_SHA256 = "b2c9635e7b63edee1bd7c82e7dc180d739f3accb2b8994804c7774e464ce89ae"

BSD_3_CLAUSE = """\
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

  * Redistributions of source code must retain the above copyright notice,
    this list of conditions and the following disclaimer.
  * Redistributions in binary form must reproduce the above copyright notice,
    this list of conditions and the following disclaimer in the documentation
    and/or other materials provided with the distribution.
  * Neither the name of the copyright holder nor the names of its contributors
    may be used to endorse or promote products derived from this software
    without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
"""


def dist_license(package, *names):
    files = metadata.distribution(package).files or []
    for f in files:
        if f.name in names and ("licenses" in f.parts or f.parent.name.endswith(".dist-info")):
            return Path(f.locate()).read_text(encoding="utf-8", errors="replace")
    raise SystemExit(f"licence file of {package} not found")


def section(title, body):
    bar = "=" * 79
    return f"{bar}\n{title}\n{bar}\n\n{body.strip()}\n\n"


def main(out_path):
    pyinstaller = metadata.version("pyinstaller")
    pillow = metadata.version("pillow")
    python = sys.version.split()[0]
    python_license = Path(sys.base_prefix, "LICENSE.txt").read_text(encoding="utf-8", errors="replace")
    vrf_license = (HERE / "licenses" / "ValveResourceFormat-LICENSE.txt").read_text(encoding="utf-8")
    storm_license = (HERE / "licenses" / "StormLib-LICENSE.txt").read_text(encoding="utf-8")

    parts = [f"""\
THIRD-PARTY NOTICES - Dota vs Commander launcher
================================================

This folder redistributes the third-party software listed below. No Dota 2 or
Warcraft III content is included: hero icons and voice lines are read from the
player's own Dota 2 installation on the player's PC.

  vrf\\Source2Viewer-CLI.exe  Source 2 Viewer CLI (ValveResourceFormat) {VRF_VERSION}   MIT
  vrf\\libSkiaSharp.dll       SkiaSharp native library (from the VRF CLI release)  MIT; Skia: BSD-3-Clause
  vrf\\spirv-cross.dll        SPIRV-Cross (from the VRF CLI release)               Apache-2.0
  StormLib.dll               StormLib {STORMLIB_VERSION}, by Ladislav Zezula                   MIT
  DotaVsCommander.exe        built with PyInstaller {pyinstaller}                   GPL-2.0+ with bootloader exception
                             contains Python {python}                            PSF License (+ bundled libraries)
                             contains Pillow {pillow}                            MIT-CMU (+ bundled libraries)

Powered by Source 2 Viewer (https://s2v.app)
(ValveResourceFormat, https://github.com/ValveResourceFormat/ValveResourceFormat).

"""]
    parts.append(section(
        f"Source 2 Viewer CLI / ValveResourceFormat (VRF) {VRF_VERSION}",
        f"""Authors: ValveResourceFormat Contributors
Project: https://github.com/ValveResourceFormat/ValveResourceFormat  (https://s2v.app)
Binary:  https://github.com/ValveResourceFormat/ValveResourceFormat/releases/download/{VRF_VERSION}/cli-windows-x64.zip
         SHA256 {VRF_SHA256}, redistributed unmodified in the vrf folder.

{vrf_license.strip()}

The VRF CLI release also contains native libraries of other projects, each
under its own licence:
  libSkiaSharp.dll  SkiaSharp (https://github.com/mono/SkiaSharp), MIT License,
                    Copyright (c) Microsoft Corporation and Xamarin Inc.;
                    built on Skia (https://skia.org), BSD 3-Clause License,
                    Copyright (c) Google LLC. BSD 3-Clause text:

{BSD_3_CLAUSE}
  spirv-cross.dll   SPIRV-Cross (https://github.com/KhronosGroup/SPIRV-Cross),
                    Apache License 2.0, Copyright Arm Limited and contributors.
                    The full Apache License 2.0 text is part of the PyInstaller
                    section below.
The VRF CLI itself is a self-contained .NET application; see the VRF project
for the licences of the .NET runtime and libraries compiled into it."""))
    parts.append(section(
        f"StormLib {STORMLIB_VERSION}",
        f"""Author:  Ladislav Zezula
Project: https://github.com/ladislav-zezula/StormLib
Binary:  https://github.com/ladislav-zezula/StormLib/releases/download/v{STORMLIB_VERSION}/stormlib_dll.zip
         (x64\\StormLib.dll), SHA256 of the zip {STORMLIB_SHA256}

{storm_license.strip()}"""))
    parts.append(section(
        f"PyInstaller {pyinstaller} (bootloader)",
        "DotaVsCommander.exe is a PyInstaller one-file executable. Its bootloader is\n"
        "covered by the GPL bootloader exception quoted below, which allows\n"
        "distribution of the combined executable without restriction.\n\n"
        + dist_license("pyinstaller", "COPYING.txt")))
    parts.append(section(f"Pillow {pillow}", dist_license("pillow", "LICENSE")))
    parts.append(section(f"Python {python}", python_license))

    text = "".join(parts).replace("\r\n", "\n")
    Path(out_path).write_text(text, encoding="utf-8", newline="\r\n")
    print(f"notices: {out_path} ({len(text.splitlines())} lines)")


if __name__ == "__main__":
    main(sys.argv[1])
