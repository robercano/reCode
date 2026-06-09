# Using the Orchestrator (after setup)

Two ways to drive it: **conversational** (the orchestrator subagent — flexible) or **workflow** (deterministic
fan-out). Plus the human checkpoints that keep you in the loop.

## A. Conversational — the orchestrator subagent
Best for one-off or exploratory tasks where the shape isn't known up front.

**Kick off:**
```
Use the orchestrator agent. Task: <describe the goal>.
Scope it into non-overlapping sub-tasks by module, show me the plan, and WAIT for approval.
```
The orchestrator reads `gates.json` + `CLAUDE.md`, decomposes, and presents a plan in plan mode.

**Approve / adjust the plan** — this is your *planning checkpoint*. Check: are sub-tasks truly independent? Is
each inside one module? Too many workers for the size? Then approve.

**Let it run.** Each sub-task goes to an `implementer` in its own worktree/branch; on "done" the orchestrator
fans the change to `reviewer`s (one per lens); rejects loop back to the implementer until clean.

**Mid-run controls:**
- "Status?" → orchestrator emits the standup block (done/in-progress/blocked, branches, gates, risks).
- "Pause worker B / drop sub-task C / re-scope D."
- "Show me worker A's diff before it opens a PR."

## B. Workflow — deterministic fan-out
Best for repeatable, known-shape work (a feature with clear parts, a migration, a sweep). Token-heavy, so it's
gated behind explicit opt-in.

```
ultracode run the feature-fanout workflow with task: "<your task>"
```
or ask: *"Run the `feature-fanout` workflow, args.task = '…'"*. It runs `Scope → Implement → Review → loop`
(up to 3 iterations/sub-task) and returns approved vs. needs-human results. Watch live with `/workflows`.

Tune `.claude/workflows/feature-fanout.js`: `LENSES`, `MAX_ITERS`, model per stage, worktree isolation.

## The human checkpoints (your agile cadence)
| Ceremony | Mechanism | What you do |
|---|---|---|
| **Sprint planning** | Plan mode (`ExitPlanMode`) | Approve/adjust the decomposition before any code |
| **Daily standup** | `/workflows` board · "Status?" · `TodoWrite` list | Glance at progress; unblock |
| **Sprint demo** | PR-per-agent + `/review` + `verify`/`run` skills | Review each branch; see features actually work |
| **Retro** | `npx ccusage` + run notes | Tune routing, worker count, prompts for next run |

## The iteration loop (how "done" is enforced)
```
implementer ──done──▶ gates (build/lint/types/test/coverage via gate.sh + hooks)
                          │ red → implementer keeps working (Stop hook blocks finish)
                          ▼ green
                     reviewers (1 per lens, adversarial)
                          │ any reject → reasons fed back → implementer iterates
                          ▼ consensus approve (per gates.json review.consensus)
                     PR / merge (per gates.json merge.policy)
```

## Merge discipline
- **`pr-per-agent`** (default): each worker → branch → PR. You (or a merge step) integrate; conflicts surface
  at PR time. Cleanest/auditable.
- **`orchestrated-sequential-merge`**: a coordinator merges branches in dependency order, re-running gates
  after each. Faster when many finish together, but needs careful ordering.

After merging a branch, clean its worktree:
```bash
git worktree list
git worktree remove <path>
```

## Scaling up
Start at `max_parallel_workers: 1–2`. Raise it only when your review+merge throughput proves it can keep up.
If workers stall or collide, the fix is almost always a sharper **module map** in `gates.json`, not more agents.

## When NOT to orchestrate
Trivial or single-file changes: just do them directly. The 15× token multiplier isn't worth it. The
orchestrator itself is told to use one worker and no parallelism for small tasks — hold it to that.
