---
tags: [debugging, ui, frames]
date: 2026-10-10
---

# Text labels on custom buttons swallow the mouse even when disabled

## Symptom

- No custom HUD button reacted: SHOP, shop items, tabs, "+".
- A full-panel catcher BUTTON got every hover.

## Finding

The `-uiprobe` panel showed which construction gets the mouse in 2.0.1:

| Variant | Construction | Mouse |
|---|---|---|
| 1 | Plain BUTTON | Yes |
| 2 | BUTTON + BACKDROP | Yes |
| 3 | BUTTON + BACKDROP + label | No |
| 4 | GLUEBUTTON (ScoreScreenTabButtonTemplate) + BACKDROP | Yes |
| 5 | GLUEBUTTON + BACKDROP + label | No |
| 6 | ScriptDialogButton | Yes |

The label is a FRAME box with a TEXT inside, both `BlzFrameSetEnable(false)`. It still takes
the mouse from its button.

## Fix

`Kit.label` adds a transparent GLUEBUTTON click layer above the button's children (level 9).
Events, tooltips and enable toggles use `Kit.hit(button)`. The catcher behind the shop and
the stretched ConsoleUIBackdrop blocker are gone.

Related: [[UI probe logs show which frames get the mouse]]
