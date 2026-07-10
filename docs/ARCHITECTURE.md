# Architecture

## The topology
```
        YOU  — plan approval (planning) · /workflows glance (standup) · PR review (demo)
                       │
              ┌────────▼─────────┐
              │   ORCHESTRATOR   │  Opus. Scopes + delegates. Holds no implementation detail.
              └────────┬─────────┘
        ┌──────────────┼──────────────┐
   ┌────▼────┐    ┌────▼────┐    ┌────▼────┐
   │implementer│  │implementer│  │implementer│   Sonnet. Each in its OWN git worktree + branch.
   │  module A │  │  module B │  │  module C │   Delegates exploration to Explore (Haiku).
   └────┬─────┘   └────┬─────┘   └────┬─────┘
        └──────────────┼──────────────┘
                  ┌─────▼─────┐
                  │ reviewers │  Opus. One per lens, adversarial. approve/reject → loop.
                  └───────────┘
```

## The three levers (know which to reach for)
| Lever | Mechanism | Use for |
|---|---|---|
| **Subagents** (`.claude/agents/*.md`) | Model-*decided* delegation | Open-ended "break this down"; specialized roles |
| **Workflows** (`.claude/workflows/*.js`) | *Deterministic* JS: `pipeline`/`parallel`/`agent`, loops, schemas | Repeatable fan-out where YOU control control-flow |
| **Worktrees** (`isolation: worktree`) | Each agent → own dir + branch | Preventing file clashes between parallel workers |

Subagents = flexible, model-driven. Workflows = repeatable, you-driven. They compose: a workflow can spawn the
same role agents; an orchestrator subagent can decide to invoke a workflow.

## Two-tier design (why this is a reusable framework, not a one-off)
- **Generic harness (portable):** the four agents, the workflow, `gate.sh`, the hooks, the topology, model
  routing, the adversarial-review pattern, the human checkpoints. None of it hardcodes a stack.
- **Project adapter (swappable):** `.claude/gates.json` (module map + gate commands + routing) and `CLAUDE.md`
  (context). This is the only per-project layer.

The agents are written to **read the adapter at runtime** ("run the commands in `gates.json`", "stay inside
your module's `path`"), so the same harness drives a Solidity monorepo, a Next.js app, or a Rust service —
only the adapter changes.

> In a personal setup you can push the generic tier up to `~/.claude/` (shared across all repos) and keep only
> the adapter in-repo. For a GitHub *template*, everything ships in-repo so each generated project is
> self-contained — that's what this template does.

## Why each design choice
- **Worktree isolation** is the real fix for clashes — physical separation, not politeness. Module boundaries
  + merge discipline are the logical/integration backstops.
- **Adversarial, one-lens-per-reviewer** beats a single "looks good?" pass: a reviewer told to *refute* through
  a specific lens (correctness/tests/security/perf) catches what a generic approver rubber-stamps.
- **Hard gate via Stop hook**: a failing test gate is enforced outside the model, so it can't be argued around.
- **Model routing** (Opus orchestrate/review · Sonnet build · Haiku explore) mirrors Anthropic's own finding —
  Opus-orchestrator + Sonnet-workers gave a large quality gain at the cost of ~15× tokens.

## Limits to respect
- **2–4 parallel workers** is the practical ceiling before human review/merge becomes the bottleneck.
- Token cost scales with agent count — see [`TOKEN_BUDGET.md`](TOKEN_BUDGET.md).
- Remove worktrees on merge (`git worktree list` / `git worktree remove`).

## Cockpit (read-only dashboard)
`.claude/scripts/cockpit.sh` regenerates a static local HTML snapshot of this topology in practice: open
issues by module with their blocking graph, open PR review/CI state, per-role model/skill routing, and active
worker worktrees. Run it, then open `.claude/state/cockpit.html`. No server, no new dependency — see the
script header for usage (`--fixtures`, `GATES_FILE` override) and `docs/COCKPIT_EVALUATION.md` for the
design rationale.

For a live, auto-refreshing view, `.claude/scripts/cockpit-serve.sh` wraps the same renderer behind a small
HTTP server (127.0.0.1 only, node built-ins only). Run it via `pnpm cockpit` (default port 8090), or
`pnpm cockpit -- <port>` to override the port.

### Concurrent config-write safety
This template fans out to **parallel worktree-isolated workers**, and upstream
[anthropics/claude-code#29217](https://github.com/anthropics/claude-code/issues/29217) reported that
`~/.claude.json` (global config) can be **corrupted by non-atomic concurrent writes** from multiple
processes. That's the access pattern the template encourages, so it's worth naming — with the caveat that it's
an **upstream Claude Code** concern the template can only document + mitigate, not fix:

- **What was measured:** a probe on v2.1.153/WSL2 (6+ parallel subagents, ~50 tool calls in a few seconds) did
  **not** reproduce it — `~/.claude.json` stayed valid JSON, zero `.corrupted.*` files. #29217 was a
  v2.1.59–62 / Windows report, now closed-stale. So it appears safe at modest concurrency but is
  version/platform-dependent.
- **Mitigations:** keep `max_parallel_workers` at the low end of the **2–4** ceiling advised above (the
  self-adapter ships `2`); don't run other Claude Code sessions / the Desktop app from the same home dir
  during a run; keep Claude Code updated.
- **Residual risk this template owns:** the harness rewrites the *working-tree* `.claude/settings.json` mid-run
  with its session grant list, so a worker doing `git add -A` could stage a grant-drifted `settings.json` into
  its PR. Mitigated by the pre-approved allow-list **and** the implementer rule to stage explicit paths only
  (never `git add -A`) — see `.claude/agents/implementer.md`.
