# Contributing to reCode

reCode dogfoods itself: this repo's own backlog runs through the same orchestrator/implementer/reviewer
pipeline it ships to consumers, using a self-hosted adapter (`.claude/self/gates.json`) instead of the
placeholder `.claude/gates.json` that downstream projects fill in. Understanding that loop is most of what
you need to contribute here. See [`docs/USAGE.md`](docs/USAGE.md) for the full mechanics; this file is the
short, contributor-facing version plus the boundaries specific to this repo.

## How work gets approved (two-label workflow)
Every issue starts as **`backlog`** — filed, not yet approved. The loop, and any agent working this repo's
queue, **never** picks up a `backlog` issue.

- **`backlog`** — default state for every new issue, including ones filed by agents/bots. If you file an
  issue (or an agent files one on your behalf), it MUST be labelled `backlog`, never `planned`.
- **`planned`** — the repo owner's formal approval: "scoped, reviewed, do it." **Only the repo owner adds
  this label** — no contributor, agent, or bot ever assigns it, to their own issue or anyone else's.
  Commenting "approved" on an issue does nothing; nothing watches issue text, only the label.
- **`module:<name>`** — routing, not approval. It maps an issue to one of this repo's self-hosted modules
  (`docs`, `harness` → `.claude`, `examples`, `ci` → `.github` — see `.claude/self/gates.json`) and therefore
  to a worker's non-overlapping boundary. No module label ⇒ nothing safe to hand a worker, `planned` or not.

**If you want to propose work:** open an issue describing it, labelled `backlog` (+ a `module:*` label if you
know which area it touches). The owner reviews and, if it's a good fit, adds `planned` — that's what makes it
loop-eligible.

## How a change actually lands
1. **Scope** — an orchestrator reads the issue and this repo's self-adapter, and splits it into
   non-overlapping sub-tasks by module.
2. **Build** — each sub-task goes to an `implementer`, isolated in its own git worktree/branch. Implementers
   must stay inside their assigned module's `path` — cross-module work gets re-scoped, never reached across.
3. **Gate** — before anything is called done it must pass this repo's self-hosted gates
   (`GATES_FILE=.claude/self/gates.json bash .claude/scripts/gate.sh <build|lint|test>`), enforced by a `Stop`
   hook, not by asking the model nicely.
4. **Review** — gated changes go to reviewer lenses (`correctness`, `tests` per `.claude/self/gates.json` →
   `review.lenses`), adversarial and one-per-lens. Consensus mode is `all`: every lens must approve.
5. **PR** — opened by a **bot machine account** (`.claude/scripts/bot-gh.sh`), never under the owner's own
   `gh` auth — GitHub blocks a PR author from approving their own PR, and the owner's approval is the only
   merge gate. Commits/pushes stay on the human contributor's (or the worker's) own git identity; only PR
   *creation* goes through the bot.
6. **Merge** — the repo owner reviews and formally Approves on GitHub. Merge happens only once CI is green
   and the approval is at/after the PR's last commit (so a later push always requires re-approval).

If you're opening a PR by hand rather than through the loop, the same gates and review expectations apply —
run the self-hosted gates yourself before requesting review (see [Running the gates](#running-the-gates)
below).

## What NOT to touch
- **`.claude/self/`** — this repo's own self-hosting adapter and loop config (module map, gate commands,
  review/merge settings for reCode's *own* backlog). It is deliberately kept separate from the shipped
  `.claude/gates.json` placeholder so that a downstream project cloning/installing this plugin never inherits
  reCode's own configuration (see `.claude/self/README.md`). Treat it as owner-maintained; if a change to the
  self-adapter is genuinely part of your task, call it out explicitly rather than editing it incidentally.
- **MANAGED files** — templates under `.claude/skills/setup/templates/` (`feature-fanout.js`,
  `pr-loop.service`, `claude-rc.service`, `arm-loop.sh`) each carry an `@orchestrator-managed <name> vN`
  marker comment. These are the source of truth that `/orchestrator:setup` scaffolds into consumer repos and
  `/orchestrator:sync` re-stamps on plugin updates (see `.claude/skills/sync/SKILL.md`). If you change one,
  bump its version marker **and** `.claude/.claude-plugin/plugin.json`'s `version` in the same PR — otherwise
  every already-installed consumer's cached copy silently never updates (this bit the project once already,
  see `docs/USAGE.md` → "Maintainer note").
- **`LICENSE`** — already MIT (Copyright (c) 2026 Roberto Cano). Don't re-add or modify it.
- **The module-boundary rule** — an implementer (human or agent) assigned one module must not edit files
  outside that module's `path`. If a task genuinely spans modules, split it into per-module sub-tasks or flag
  it for re-scoping; don't reach across the boundary from inside a single worker/PR.

## Running the gates
This repo's own gates run through the self-adapter, not the placeholder `.claude/gates.json`:
```bash
GATES_FILE=.claude/self/gates.json bash .claude/scripts/gate.sh build
GATES_FILE=.claude/self/gates.json bash .claude/scripts/gate.sh lint
GATES_FILE=.claude/self/gates.json bash .claude/scripts/gate.sh test
```
`build`/`lint` are static checks (every adapter JSON is well-shaped; every shell script parses; every
workflow `.js` type-checks with `node --check`). `test` additionally runs a deterministic end-to-end smoke of
the fan-out scaffold against a fixture — no agents, no tokens, no network. All three must be green before a
PR is considered done.

## Hygiene expectations
Don't commit secrets, tokens, or personal machine paths. `.gitignore` already covers the sensitive local-only
paths for this repo (`.claude/state/`, `.claude/settings.local.json`, `.env*` other than `.env.example`,
common editor dirs, `__pycache__/`) — if your change adds a new kind of local-only artifact, extend
`.gitignore` rather than relying on `git status` staying clean by luck.

## Questions
Read [`docs/USAGE.md`](docs/USAGE.md) for the full loop mechanics and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
for the design rationale. If something here and the docs disagree, the docs under `docs/` are the source of
truth — this file is a contributor-facing summary, not a spec.
