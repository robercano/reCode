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
- **Gates run via** `.claude/scripts/gate.sh <name>` and the hooks in `.claude/settings.json`.
- **Workflow:** `.claude/workflows/feature-fanout.js` for deterministic fan-out.

### Module boundaries (hard rule)
A worker assigned to a module MUST NOT edit files outside that module's `path`. Cross-module work is
re-scoped by the orchestrator, never reached across by a worker.

### Merge policy
<pr-per-agent | orchestrated-sequential-merge> — base branch `main`. (Mirror in `gates.json` → `merge`.)

## Don'ts
- Don't put secrets in the repo.
- Don't bypass the gates.
- <project-specific landmines>
