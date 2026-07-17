# <PROJECT NAME>

> Fill this in per project. Keep it lean — project-WIDE context only. Task-specific detail belongs in the
> task prompt, not here. See `docs/PROMPTS.md` for a prompt that drafts this file for you.

## What this project is
<1–3 sentences: domain, what it does, who uses it.>

## Stack & layout
- Language / runtime:
- Package manager:
- Key directories (mirror `.claude/gates.json` → `modules`):
  - `path/` — what lives here

## Conventions
- Code style / lint rules of note:
- Testing approach (frameworks, where tests live):
- Definition of done: <e.g. builds, lints, types pass, tests + coverage ≥ threshold, reviewers approve>

## Multi-agent orchestration (this template)
This repo is set up for orchestrated multi-agent development. See `docs/USAGE.md`.
- **Agents:** `.claude/agents/` — orchestrator, implementer (worktree-isolated), reviewer, test-runner.
- **Adapter:** `.claude/gates.json` — module map, gate commands, model routing. **This is the file to keep current.**
- **Gates run via** `.claude/scripts/gate.sh <name>` and the hooks in `.claude/settings.json`. Keep the
  `orchestrator` plugin **disabled** outside of running `/orchestrator:setup`/`/orchestrator:sync` — its own
  `hooks/hooks.json` registers the same hooks, and if both the plugin and this file are active at once every
  gate (notably the `Stop` `test_affected` check) runs twice per turn.
- **Workflow:** `.claude/workflows/feature-fanout.js` for deterministic fan-out.

### Module boundaries (hard rule)
A worker assigned to a module MUST NOT edit files outside that module's `path`. Cross-module work is
re-scoped by the orchestrator, never reached across by a worker.

### Merge policy
<pr-per-agent | orchestrated-sequential-merge> — base branch `main`. (Mirror in `gates.json` → `merge`.)

## Don'ts
- Don't put secrets in the repo.
- Don't bypass the gates.
- Don't `git add -A` / `git add .` / `git commit -a` — **stage explicit paths by name.** Under the sandbox,
  masked config paths (`.mcp.json`, `.gitconfig`, `.claude/{launch.json,routines,…}`, editor dirs) appear as
  `/dev/null` character-device nodes; git can't index a device node, so a blanket add aborts the whole commit
  (`can only add regular files, symbolic links or git-directories`). Ignore any `crw-` entries in `git status`
  — they're sandbox masks, not your changes. See `docs/HARDENING.md` → Caveats.
- <project-specific landmines>
