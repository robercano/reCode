# Getting Started

From a fresh repo created off this template to a working orchestrator, in 6 steps. Budget ~20 minutes.

## Prerequisites
- Claude Code installed and authenticated (`claude` runs).
- `node` and `git` on PATH (the gate script uses `node` to read `gates.json`).
- Your project's actual build/test tooling installed (so the gate commands work).

## Step 1 — Create your repo
On GitHub, **Use this template → Create a new repository**. Clone it and open it in Claude Code.
(The template ships agents and config under `.claude/`; Claude Code picks them up automatically.)

## Step 2 — Fill in `CLAUDE.md`
This is project-wide context every agent reads. Either edit it by hand, or paste the **"Draft CLAUDE.md"**
prompt from [`PROMPTS.md`](PROMPTS.md) into Claude Code and let it propose a draft from your codebase, then
trim. Keep it lean — project-wide only.

## Step 3 — Fill in `.claude/gates.json` (the adapter — the important one)
This is the *only* file that makes the generic agents work on YOUR stack. Set:
- **`project`** — name, language, package manager.
- **`modules`** — the map of independent areas + their paths. This is what the orchestrator uses to give each
  worker a non-overlapping boundary. Get this right and clashes mostly disappear.
- **`gates`** — the exact shell commands for `build`, `lint`, `typecheck`, `test`, `test_affected`,
  `coverage`, `e2e`, `security`. Leave any you don't have as `""` (it's skipped, not failed).
- **`coverage_threshold`**, **`review.lenses`**, **`budget`** (model routing + `max_parallel_workers`),
  **`merge.policy`**.

Use the **"Fill gates.json"** prompt in [`PROMPTS.md`](PROMPTS.md) to have Claude infer most of this from your
`package.json` / `Makefile` / CI config, then verify each command runs.

**Sanity-check the gates manually:**
```bash
bash .claude/scripts/gate.sh build
bash .claude/scripts/gate.sh lint
bash .claude/scripts/gate.sh test
```
Each should run the right command (or say "not configured — skipping").

## Step 4 — Review the agents (usually no change needed)
Skim `.claude/agents/*.md`. They're generic and read `gates.json`, so they typically need no edits. Adjust
`model:` per agent if your routing differs, or add project review skills (e.g. a security/audit skill) and
reference them in `gates.json` → `review.skills`. Run `/agents` in Claude Code to confirm they're detected.

## Step 5 — Decide on hooks
`.claude/settings.json` wires two gates as hooks:
- **PostToolUse (Edit|Write)** → `gate.sh lint` after every edit.
- **Stop** → `gate.sh test_affected` when an agent tries to finish — a **red test blocks completion**, forcing
  iteration.

These are inert until you configure the matching commands in `gates.json`. Disable/adjust if you don't want a
hard test gate yet. (The `update-config` skill can help edit settings safely.)

## Step 6 — Pilot run
Don't unleash the whole army first. Run ONE real task end-to-end:

```
Use the orchestrator agent. Task: <one small, real, self-contained feature/fix>.
Scope it, show me the plan, and wait for my approval before writing code.
```

Approve the plan, let one implementer run in its worktree, watch the reviewers gate it, review the PR. Then
read [`USAGE.md`](USAGE.md) to scale up, and [`TOKEN_BUDGET.md`](TOKEN_BUDGET.md) before you go parallel.

## Verification checklist
- [ ] `CLAUDE.md` describes the project and lists modules.
- [ ] `.claude/gates.json` has real commands; `gate.sh build|lint|test` behave correctly.
- [ ] `/agents` lists orchestrator, implementer, reviewer, test-runner.
- [ ] A pilot task produced a branch/PR that passed gates + review.
- [ ] You've checked spend with `/cost` or `npx ccusage`.
