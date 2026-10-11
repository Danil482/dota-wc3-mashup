---
tags: [debugging, testing, mock]
date: 2026-10-11
---

# The mock missed ERROR lines that left the log's 600-line window

## Symptom

`MOCK RESULT` came from the final log file, which keeps only its last 600 lines. ERROR lines written by
early exercises (items run at 6 s) could scroll out, and a broken build still printed OK.

## Fix

`tools/mock_runtime.lua` records every Preload line containing "ERROR" in `__mock.errorLines`;
`tools/mock_run.py` prints those that left the window and fails the run. A full build after the fix
showed no hidden errors.

Related: `tools/run_test.ps1` now fails only on the log's level tags (`] FAIL ` / `] ERROR `, case-
sensitive): trace lines such as "sound error for p0" had made in-game runs report FAILED.

Related: [[Testing runs offline on a mock and in game with user clicks]]
