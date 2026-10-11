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
- The log is in `Documents\Warcraft III\CustomMapData\DotaVsCommander\log.txt`. Documents may
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
  (`launcher\build.ps1`) or run the launcher from source with `DVC_USER_DIR`.

Related: [[The map is built from source with one build.py command]]
