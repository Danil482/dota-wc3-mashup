---
tags: [pattern, agents, workflow]
date: 2026-10-10
---

# Parallel agents split the repo by file ownership

The lead session hands self-contained parts to background agents: heroes, items, launcher
assets, models, world systems, the HUD.

## Rules for agents

- **Own files.** Each brief names the files the agent owns. Shared files (`tools/gen_objects.py`,
  `launcher/dvc_launcher/cli.py`, `launcher/build.ps1`, `launcher/tests/test_dist.py`) are
  re-read right before every edit, and the edits stay small and local.
- **Own build folders.** Each agent builds into its own `--work build\work_<name>`.
- **Hook lines.** Agents return the init and hook lines for `game.lua`; the lead pastes them in
  and rebuilds.
- **No game, no git.** Agents never launch WC3 (the user clicks through in-game tests) and
  never commit.
- **Full brief.** Briefs carry the rules: agents do not inherit `CLAUDE.md`.

## Lessons

- A contract change by one agent breaks everyone else. When `specs/models.json` switched to
  Dota paths, test builds turned invisible. Make such switches opt-in build flags.
- An agent's partial edit can break someone else's build. Before integrating, check that the
  agent printed `MOCK RESULT: OK`.
