# Token Budget & Cost Control

Orchestration is powerful but expensive: Anthropic's own multi-agent research system used **~15× the tokens of
a single chat**. Treat tokens as a first-class budget. Levers below, roughly by impact.

## 1. Model routing (biggest lever)
Set in `.claude/gates.json` → `budget`, and per-agent via `model:` frontmatter:
- **Opus** — orchestrator + final reviews only.
- **Sonnet** — implementers (the bulk of the work).
- **Haiku** — Explore/search and the test-runner (cheap, high-volume).

Anthropic's large quality gain came specifically from Opus-orchestrator + Sonnet-workers. Don't run Opus
everywhere.

## 2. Scale effort to complexity
The orchestrator is instructed to use ONE worker and no parallelism for small tasks. Hold it to that — the #1
early failure mode in multi-agent systems is spawning many agents for a trivial query. For a one-file change,
skip orchestration entirely.

## 3. Cap parallelism
`max_parallel_workers` bounds concurrent implementers. More workers ≈ more tokens *and* more for you to
review. Start at 1–2.

## 4. Workflow budget guard
The workflow engine exposes a token budget. When you set a target (e.g. type `+500k` style directives), scripts
can scale fan-out / loop depth and HARD-STOP at the ceiling. `feature-fanout.js` also caps review iterations
(`MAX_ITERS`) so a stubborn sub-task can't loop forever.

## 5. Context hygiene
- Keep `CLAUDE.md` lean — it's loaded into every agent.
- Subagents have isolated context: exploration in a worker never pollutes the orchestrator. Lean on that.
- Use pre-processing hooks to shrink inputs (grep a log to its error lines instead of reading 10k lines).

## Measure (you can't control what you don't see)
- **In-session:** `/cost`.
- **Local history:** `npx ccusage` — daily/session/monthly token + cost, broken down by model. Fastest
  feedback loop. → https://github.com/ryoppippi/ccusage
- **Team / dashboards:** Claude Code has native **OpenTelemetry** export — point it at SigNoz/Grafana for
  per-session, per-token tracing across a team. Ready-made stack: https://github.com/ColeMurray/claude-code-otel
- **Official guidance:** https://code.claude.com/docs/en/costs

## A simple budgeting habit
1. Before a big run, estimate: `~workers × (implement + iters × reviewers)` agent-invocations.
2. Run it.
3. `npx ccusage` after — compare actual vs. expectation.
4. Adjust routing / worker count / module granularity for next time (prompt #9 in `PROMPTS.md`).
