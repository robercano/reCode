# Multi-Agent Orchestrator Template

A **GitHub template** for running an orchestrated "army" of Claude Code agents on a codebase: a lead
**orchestrator** scopes a task and delegates to worktree-isolated **implementers**, whose work is gated by
adversarial **reviewers** — looping until tests, coverage, and review all pass.

The design is **two-tier**: a *generic harness* (portable across any stack) plus a thin *project adapter*
(`.claude/gates.json` + `CLAUDE.md`) that you fill in per project. Onboarding a new repo is a ~20-line
config edit, not a rebuild.

> Status: **v0** — a starting point to iterate on. The underlying Claude Code features (subagents, worktree
> isolation, the workflow engine) are evolving; treat your first runs as calibration.

## Use it
1. Click **“Use this template”** on GitHub → create your repo.
2. Open it in Claude Code and follow **[`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md)** (fill `CLAUDE.md`
   and `.claude/gates.json` — there are copy-paste prompts in [`docs/PROMPTS.md`](docs/PROMPTS.md) that draft
   them for you).
3. Drive it: see **[`docs/USAGE.md`](docs/USAGE.md)**.

## What's in here
```
.claude/
  agents/         orchestrator · implementer (worktree) · reviewer · test-runner   ← generic, portable
  workflows/      feature-fanout.js — deterministic scope→implement→review→loop
  scripts/        gate.sh — runs a gate command from gates.json
  settings.json   hooks (lint on edit, tests on stop) + permissions               ← generic
  gates.json      ★ PROJECT ADAPTER — module map, gate commands, model routing     ← you fill this
CLAUDE.md         ★ project context                                                ← you fill this
.github/          PR template (the per-agent "demo artifact")
docs/
  GETTING_STARTED.md   setup, step by step
  ARCHITECTURE.md      the mental model & the three levers
  USAGE.md             how to drive the orchestrator day to day
  PROMPTS.md           copy-paste prompts to populate files & kick off work
  TOKEN_BUDGET.md      cost control & measurement
```

★ = the only two files you must edit per project.

## The one thing to remember
The orchestrator-worker pattern is powerful but costs **~15× the tokens of a single chat** (per Anthropic's
own research system). Scale effort to task complexity, route cheap models to cheap work, and measure spend.
See [`docs/TOKEN_BUDGET.md`](docs/TOKEN_BUDGET.md).
