---
tags: [decision, strings, localization, launcher]
date: 2026-10-11
---

# Player-facing strings are keyed by Dota localization tokens

## Decision

Lines the map shows to Dota players go into one table, `src/data/strings.json`, which builds
into the `data.strings` module. That covers error lines, chat lines and button tooltips. Each key
is Dota's own localization token, such as `dota_hud_error_cant_deny_health_too_high` or
`DOTA_Chat_GlyphUsedGood`. Each value is a short English fallback in our own words, using Dota's
`%s1` placeholders. Code reads them through `Lane.text(token, ...)`.

The lane module was the first to use it (2026-10-11). The inventory agent's error lines still
use their own wording outside the table.

## Why

- Dota's exact text lives in the player's install (`resource/localization/dota_english.txt`).
  Copying it into the repo is an open question with the user.
- Keying by Dota's token lets the launcher fill the table later from the player's own
  localization file, in the player's language, the same way it fills `data.mapdata` between
  markers ([[Dota's map layout is ported 1 to 1 by the launcher]]). A Russian Dota player would
  then see Dota's Russian lines.

## Open

- The user hasn't decided between the launcher fill (the lead's recommendation) and Dota's exact
  words as the fallbacks.
- The launcher doesn't fill the table yet.

Related: [[Dota content reaches the map only through the launcher]],
[[Lane rules run in lane.lua on top of WC3 combat]]
