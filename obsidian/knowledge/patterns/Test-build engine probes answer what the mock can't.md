---
tags: [pattern, testing, engine]
date: 2026-10-11
---

# Test-build engine probes answer what the mock can't

The mock runs our script but not the engine. When a fix depends on what the engine accepts,
build a probe that asks the engine itself, and read its answer from one in-game run.

## Examples

- **UI probe** (`-uiprobe`): which frame constructions get the mouse; see
  [[UI probe logs show which frames get the mouse]]. Variants 9 and 10 test blockers with child
  buttons.
- **Controls probe** (`src/ui/controls_probe.lua`). At game start in test builds:
  - it gave neutral footmen 18 synthetic probe Channels and issued instant, unit and point
    orders by string and by id, each followed by a stop. That part answered and was removed on
    2026-10-11, along with its objects in `gen_objects.py`;
  - it issues every hero Channel's real order, so the next run checks new orders such as Poof's;
  - it reads back acquisition range writes and tests adding the worker type.

  The table goes to `CustomMapData\DotaVsCommander\controls_probe.txt`, which survives the
  log's 600-line rollover. It settled two questions in one run:
  [[Point quick casts failed on Channel orders the engine refuses]] and
  [[SetUnitAcquireRange ignores 0, so a zero range can't stop auto-attacks]].
- **Diagnostic summaries.** The AI commander logs its state every 30 s in test builds, which
  showed at once that its slot was empty
  ([[The AI commander idles because its computer slot is empty in single player]]).

## Rules

- Probes run only in test builds and create handles for every player.
- Keep the output compact (one line per case, `+` taken / `-` refused) and flushed.
- Include a control row, such as an order the unit has no ability for, so a broken probe shows
  itself.
- Remove probe objects once the answer is recorded.

Related: [[Testing runs offline on a mock and in game with user clicks]]
