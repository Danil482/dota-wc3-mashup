---
tags: [atlas, testing]
date: 2026-10-10
---

# Testing runs offline on a mock and in game with user clicks

## Offline

- `tools/gen_mock.py` turns jassdoc's `common.j` and `Blizzard.j` into Lua stubs, and
  `tools/mock_runtime.lua` adds unit state.
- `tools/mock_run.py` runs the built `war3map.lua` on Lua 5.3 (lupa).
- Exercises in `tools/mock/<hero>.lua`, `items.lua` and `world.lua` cast every ability and
  check the effects. The build fails unless it prints `MOCK RESULT: OK`.
- Autotest lines like "tier protection" or "heroes gain experience" print FAIL on the mock.
  That is expected: the mock has no real units or combat.
- `__mock.humans` and `__mock.computers` (slot → true) set who is playing, so an exercise can try
  lobby setups such as a game started straight from the map.

## In game

- `tools\run_test.ps1 -Map <w3x> -Timeout 3000 -Keep` launches
  `_retail_\x86_64\Warcraft III.exe -launch -windowmode windowed -nowfpause -loadfile <map>`
  from the game root. It screenshots only the game window, through PrintWindow.
- On the user's WC3 2.0.1 a VPN notice and an offline screen appear on every launch, and the
  user clicks "OK" and "Play offline" ("Играть вне сети") themselves. Never simulate input,
  and never capture the whole screen.
- The log is in `Documents\Warcraft III\CustomMapData\DotaVsWarcraft\log.txt`. Documents may
  be redirected, for example to OneDrive.
- Test builds start a human's hero at level 30 with every skill learned.
- Chat cheats:
  - `-lvl N`
  - `-gold N`
  - `-refresh`
  - `-wtf`
  - `-respawn`
  - `-spells`: an enemy Mountain King storm-bolts you every 4 s, for testing spell blocks
    and reflects.
- Immortal dummies near the Dota fountain (a hero and a creep) show the last hit and DPS.
- **Test-build diagnostics** go into the log and are flushed at once:
  - every new HUD focus;
  - shop decisions;
  - UI probes (`-uiprobe`);
  - quick-cast decisions.

  See [[UI probe logs show which frames get the mouse]].
- **A freeze vs a crash:** WC3 writes no log for a freeze. Windows' Application event log
  separates Application Hang (1002) from a crash.
- **Engine probes:** `-uiprobe` and the controls probe (`controls_probe.txt`) answer what the
  mock can't; see [[Test-build engine probes answer what the mock can't]].
- **The log keeps only the last 600 lines.** Answers that must survive go into their own
  CustomMapData file.
- **A test map needs a matching launcher.** After launcher changes, rebuild `dist`
  (`launcher\build.ps1`) or run the launcher from source with `DVW_USER_DIR`.

Related: [[The map is built from source with one build.py command]]

## Update (2026-10-11, night)

- Test builds end the game like release builds; `-noend` keeps a decided game going
  ([[Test builds end the game like release builds]]).
- More chat cheats: `-noend`, `-item NAME` (`shard`, `scepter`, or any item name), `-log` (log lines on
  screen; by default they go to the file only), and the audio agent's `-sfx`, `-sfxch`, `-wc3ui`.
- The mock fails on ERROR lines that left the log's 600-line window, and `run_test.ps1` only on the
  log's level tags ([[The mock missed ERROR lines that left the log's 600-line window]]).
- Live tests without the user's clicks: allowed only when the user says so in that session, through
  `run_test.ps1 -AutoStart` (the click positions still need calibrating); agents never launch WC3.
- A freeze is diagnosed from Windows' Application Hang event (1002) plus the log's last lines; a
  black box file is planned ([[A freeze is suspected from own lane creeps with animated portraits and WC3 voices]]).
