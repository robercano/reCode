# Token Budget & Cost Control

Orchestration is powerful but expensive: Anthropic's own multi-agent research system used **~15× the tokens of
a single chat**. Treat tokens as a first-class budget. Levers below, roughly by impact.

The one mental model that explains every lever: **cost scales with context size, and context is paid on every
message**. A long conversation, a bloated CLAUDE.md, a pasted log — you pay for them again with each turn.
Everything here is a way of keeping context small or routing work to a cheaper model.

## 1. Model routing (biggest lever)
Set in `.claude/gates.json` → `budget`, and per-agent via `model:` frontmatter:
- **Opus** — orchestrator + the review lenses where misses are expensive (`correctness`, `security`).
- **Sonnet** — implementers (the bulk of the work) and the remaining review lenses (`tests`, `performance`).
- **Haiku** — Explore/search and the test-runner (cheap, high-volume).

Reviews route **per lens** via `budget.reviewer_models` (fallback: `budget.reviewer_model`, default sonnet).
Anthropic's large quality gain came specifically from Opus-orchestrator + Sonnet-workers. Don't run Opus
everywhere — and don't let an Explore call default to the session's model instead of `explorer_model`.

## 2. Scale effort to complexity
The orchestrator is instructed to use ONE worker and no parallelism for small tasks. Hold it to that — the #1
early failure mode in multi-agent systems is spawning many agents for a trivial query. For a one-file change,
skip orchestration entirely. This out-saves every other lever combined.

## 3. Loop cadence (the recurring bill)
Every PR-loop cron tick is a **fresh full-context session** — it pays CLAUDE.md + agent definitions + scripts
each fire. The loop self-adjusts (STEP 0 in `/pr-loop`): FAST (1 min) only while it has actionable work
(unaddressed PR feedback, or an issue ready to advance), WATCH (5 min) while PRs wait on human review/CI,
IDLE (15 min) otherwise. A PR waiting on you does not burn a session a minute. If you'll be away for hours,
consider disarming the cron entirely (`CronDelete`) and re-arming with `/pr-loop` when you're back.

## 4. Review iterations
- Re-reviews only re-run the lenses that **rejected** — an approval stands (orchestrator rule +
  `feature-fanout.js` v2). With 4 lenses and 1 rejection, iteration 2 costs 1 review, not 4.
- `MAX_ITERS` caps the loop so a stubborn sub-task can't spiral.
- Trim `review.lenses` per project: `security`/`performance` earn their cost on some modules, not all.
- Cap parallelism: `max_parallel_workers` bounds concurrent implementers (default 2). More workers ≈ more
  tokens *and* more for you to review.

## 5. Context hygiene
- **Long conversations are the silent cost.** Context is re-sent (cached, but not free) with every message,
  and each turn makes the next one dearer. `/clear` between unrelated tasks; `/rename` first so `/resume`
  can find the session later. `/compact <focus>` when you must keep going in-place.
- Keep `CLAUDE.md` lean (aim <200 lines) — it's loaded into **every** agent, every tick. Workflow-specific
  instructions belong in skills (loaded on demand), not CLAUDE.md.
- **Reference, don't paste** when delegating: point workers at a branch/path/issue and let them read what
  they need in their own (isolated, disposable) context. Subagent isolation is the feature — exploration in
  a worker never pollutes the orchestrator.
- Shrink tool output before it enters context: `gate.sh` buffers gate runs and prints a 5-line tail on pass
  / last 100 lines on fail (`GATE_VERBOSE=1` or CI restores full streaming; `GATE_TAIL_PASS`/`GATE_TAIL_FAIL`
  tune it). Do the same manually for raw commands: `| grep -A5 -E 'FAIL|ERROR' | head -100` beats ingesting
  a 10k-line log.
- Disable MCP servers you aren't using (`/mcp`); prefer CLIs (`gh`, `aws`, …) over MCP equivalents — they
  add zero per-tool context.

## 6. Thinking & effort
Extended thinking is billed as output tokens and defaults generous. For routine work, lower it with
`/effort` (or in `/model`); on fixed-budget models, `MAX_THINKING_TOKENS=8000` in the environment. Keep full
effort for the orchestrator's scoping and the correctness/security reviews — that's where reasoning pays.

## 7. Workflow budget guard
The workflow engine exposes a token budget. When you set a target (e.g. type `+500k` style directives), scripts
can scale fan-out / loop depth and HARD-STOP at the ceiling.

## Measure (you can't control what you don't see)
- **In-session:** `/usage` — plan usage bars plus a breakdown attributing recent usage to skills, subagents,
  plugins, and MCP servers (`d`/`w` toggles 24h vs 7-day). `/context` shows what's occupying the window;
  a [status line](https://code.claude.com/docs/en/statusline) can display context usage continuously.
- **Local history:** `npx ccusage` — daily/session/monthly token + cost, broken down by model. Fastest
  feedback loop. → https://github.com/ryoppippi/ccusage
- **Team / dashboards:** Claude Code has native **OpenTelemetry** export — point it at SigNoz/Grafana for
  per-session, per-token tracing across a team. Ready-made stack: https://github.com/ColeMurray/claude-code-otel
- **Official guidance:** https://code.claude.com/docs/en/costs and
  https://support.claude.com/en/articles/9797557-usage-limit-best-practices

## A simple budgeting habit
1. Before a big run, estimate: `~workers × (implement + iters × rejected-lens reviews)` agent-invocations.
2. Run it.
3. `npx ccusage` after — compare actual vs. expectation.
4. Adjust routing / worker count / lens list / module granularity for next time (prompt #9 in `PROMPTS.md`).
