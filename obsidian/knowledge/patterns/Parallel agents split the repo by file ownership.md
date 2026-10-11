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

## Starting, continuing, stopping (the user's rules, 2026-10-10)

- **Continue unfinished work with a new agent and a fresh brief,** never by resuming the old
  one. The brief states what the previous agent left (git diff, files) and what remains.
- **Pick the library agent** from the table in CLAUDE.md before reaching for
  `general-purpose`.
- **When limits run low, ask agents to wrap up** instead of killing them. A killed agent can
  leave half-edited shared files. A wrap-up asks them to finish or revert within a couple of
  steps and report.
- **At most three agents at a time** (2026-10-11). The rest wait in a queue, and the next one
  starts when a running agent finishes. The seven wave 1 agents started that day were allowed
  to finish.

## Lessons

- A contract change by one agent breaks everyone else. When `specs/models.json` switched to
  Dota paths, test builds turned invisible. Make such switches opt-in build flags.
- An agent's partial edit can break someone else's build. Before integrating, check that the
  agent printed `MOCK RESULT: OK`.
- A network drop kills every running agent (2026-10-11). Briefs ask for small, complete steps,
  so a dead agent never leaves a half-made edit in a shared file.
- Some library agents (Senior Python Developer) have no SendMessage tool. They can't report
  mid-task, so an "early report" request makes them stop at their hand-back.
- Parallel launcher runs need separate caches: each agent sets `DVC_USER_DIR`, and only the
  lead rebuilds `dist`.
- When an agent stops early, its research goes into the next brief and the session note, so the
  next agent starts where it stopped.
