---
tags: [pattern, ui, testing]
date: 2026-10-10
---

# UI probe logs show which frames get the mouse

The offline mock can't show what the engine does with mouse input, so test builds log it.

- **`Kit.probe(frame, label)`** registers MOUSE_ENTER and CONTROL_CLICK on a separate trigger
  and logs and flushes `ui probe <label> event <id>`. Event 2 is a hover, 1 is a click. The
  frame's own handlers keep their behaviour.
- **`-uiprobe`** shows a panel of button variants with numbered captions. The user hovers and
  clicks each one, and the log says which constructions work in this game version.
- **Shop and HUD actions** log and flush their decisions (`shop buy ... near true`), so one
  in-game test answers "did the click arrive" and "why was it refused".

Summarize the log by label and event type: everything that received nothing at all stands out
at once.

Related: [[Text labels on custom buttons swallow the mouse even when disabled]],
[[Testing runs offline on a mock and in game with user clicks]]
