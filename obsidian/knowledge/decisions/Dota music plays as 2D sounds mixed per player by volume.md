---
tags: [decision, sound, music]
date: 2026-10-11
---

# Dota music plays as 2D sounds mixed per player by volume

## Decision

`src/game/music.lua` plays Dota's default music pack (valve_dota_001) for Dota players. The
tracks are 2D sounds created on every client at moments decided from synced state only. Each
client sets the volumes for its own player's state, with crossfades.

States:
- pre-game countdown;
- laning tracks with silences between them;
- battle music when the player's hero fights the Warcraft player's own units or heroes (not
  their creep waves);
- Roshan;
- death and respawn;
- buyback;
- Radiant win or lose.

The Warcraft player keeps the WC3 music.

`src/game/announcer.lua` plays Dota's default announcer for Dota players. Lines queue by
priority, never overlap, and duck the music:
- the horn with the first lane wave;
- first blood, streaks and multi-kills;
- towers and barracks;
- Roshan;
- victory.

`src/game/gamesounds.lua` plays the small sounds:
- the last-hit coin;
- deny;
- level-up;
- rune pickups;
- the Aegis;
- the hero's "not yet" and "no mana" lines on failed casts.

## Why

- `PlayMusic` replays only the first track it was given.
- Handles must match on every client.
- Each player has their own music state.
- Timing comes from Dota's sound-event data (durations, loop and sync points), never from
  `GetSoundDuration`. That call is asynchronous and returns 0 when a player has sound off, and
  timing decides when handles are created, so using it would desync.

## Notes

- The launcher extracts effects as WAV (mono) and music and voices as MP3 (`vo_manifest.json`
  "audio" section, `src/data/audio.json`).
- Audio adds about 28.7 MB to the personalized map.
- The multi-kill window (18 s) is from the Dota 2 wiki.
- Test commands: `-music`, `-musicgain`, `-ann <line>`, `-horn`, `-gg dota|warcraft`.

Related: [[A sound for one player is created for all and muted by volume]],
[[Hero responses are Dota voice lines played from Lua]]
