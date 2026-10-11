---
tags: [decision, testing, victory]
date: 2026-10-11
---

# Test builds end the game like release builds

## Decision

`src/game/victory.lua` used to skip the game end in test builds, so in-game tests never showed a
victory or defeat, and a Warcraft base that died at 4:00 left no "game over". Since 2026-10-11 test
builds end the game like release builds: the Ancient's death or the loss of every Warcraft town hall
decides it. The user chose this.

The chat cheat `-noend` (test builds and solo games) toggles `V.setNoEnd`: while it is on, a decided
game goes on with a one-time message; turning it off ends a game that was decided meanwhile.

Related: [[Testing runs offline on a mock and in game with user clicks]]
