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

## Tickets: GitHub Issues (optional)
A clean way to feed the orchestrator one task at a time is a module-labeled **GitHub Issues** backlog. The
template ships `.claude/scripts/seed-issues.sh` as a starting point: it derives `module:<name>` labels from the
`modules` in `gates.json` (plus `type:feature`/`type:infra`), and bulk-creates issues idempotently (re-running
reuses labels and skips titles that already exist). Replace the placeholder `TICKETS` section with your backlog,
then:
```bash
gh auth login                      # once
bash .claude/scripts/seed-issues.sh
```
Drive one issue at a time: *"Use the orchestrator agent. Task: implement issue #N. Scope it within its module,
show the plan, and WAIT for approval."* Keep each ticket scoped to ONE module so workers get non-overlapping
boundaries.

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

## The PR feedback loop (ticket → PR → review → merge)
With `pr-per-agent`, the standing loop per ticket looks like:
1. **Plan** — tickets are the backlog (GitHub Issues work well — see the seeder example), planned with the
   orchestrator or added manually.
2. **Build** — orchestrator scopes → implementers (isolated worktrees) → reviewer lenses → gates green.
3. **PR** — created with `.claude/scripts/bot-gh.sh pr create …` so the PR author is a **bot machine
   account**, not the repo owner. GitHub hard-blocks PR authors from approving their own PRs, so PRs created
   under the owner's `gh` auth can never receive a formal Approve. One-time setup lives at the top of
   `bot-gh.sh` (free machine account → collaborator → classic `repo`-scope PAT → `GH_BOT_TOKEN` in `.env`).
   Reuse ONE generically-named bot across all your repos — GitHub ToS allows one free machine account per
   person. Only `pr create` uses the bot; commits/pushes stay on the owner's auth.
   **Per-repo grant (easy to miss):** the bot must be a **collaborator on every (private) repo** it opens PRs
   in — adding it once to one repo does *not* cover the rest. Without it, `gh` fails with an opaque
   `Could not resolve to a Repository with the name '<owner>/<repo>'` (looks like a typo, is actually a
   missing grant). `bot-gh.sh` preflights this and prints the fix; the one-time setup is, as the **owner**:
   `gh api -X PUT repos/<owner>/<repo>/collaborators/<bot> -f permission=push`, then **accept as the bot**:
   `bot-gh.sh api -X PATCH user/repository_invitations/<id>` (private-repo invites require acceptance).
4. **Review** — the owner reviews on GitHub. To address comments, feed them back through the orchestrator
   (*"address the comments on PR #N"*): same implementer loop, same branch, push updates the PR in place.
5. **Merge** — owner approves, merge per `gates.json.merge`, clean the worktree (below).

**Closing the loop automatically:** webhooks rarely reach a dev box, so poll. Either a Claude Code cron
(`CronCreate`, durable) or an in-session `/loop` that every ~10–15 min runs the three loop scripts in order
— each is a single stable command to pre-approve in `settings.json`, since an inline compound command
(loops, `$()`, redirects) never matches a permission rule and would block on a prompt every firing:

1. **`bash .claude/scripts/notify-poll.sh`** — prints new issues and PR comments/reviews since a cursor file
   (`.claude/state/notify-cursor`, gitignored), plus a cursor-independent **`open pr status`** section (per
   open PR: latest owner review, CI rollup, mergeable) so the loop sees merge-readiness, which is a *state*,
   not an event. Summarize new items.
2. **`bash .claude/scripts/pr-feedback.sh`** — lists open bot PRs with *unaddressed* `CHANGES_REQUESTED`
   feedback (deduped via a `<!-- claude-addressed -->` marker). For each, dispatch the orchestrator to
   address the comments on the same branch and push — the implementer posts the marker after pushing.
3. **`bash .claude/scripts/merge-ready.sh`** — merges every open PR the owner has **APPROVED** that is
   mergeable and CI-green, then deletes the branch. The human Approve is the only merge gate; the script
   never approves. **Safety:** it merges only if the approval was submitted *at/after* the PR's last commit,
   so a free private repo (no branch protection to dismiss stale approvals) never auto-merges commits you
   haven't reviewed — pushing after approval requires re-approval. Uses ambient `gh` auth (merging is an
   owner action; only PR *creation* uses the bot).

With all three wired, the loop runs hands-off: **add issues → review → approve → it merges and advances**.
A natural step 4 is to start the next `module:*` issue only when **no PRs are open**, so work stays
serialized (one issue in flight) and bounded. Caveats: cron jobs fire only while Claude Code is running,
auto-expire after 7 days, and may be session-scoped on some versions — re-arm at session start.

**Running it fully hands-off?** Polling still leaves a human approving each tool call. To let the loop
run unattended (Claude Code `bypassPermissions`), first harden the environment so the prompt is replaced
by always-enforced guardrails — see **[`HARDENING.md`](HARDENING.md)** (deny list + OS sandbox + host
isolation). Don't enable bypass without it.

## Autonomous loop & the issue queue
Each `/pr-loop` tick runs, in order: **poll → merge → address-feedback → advance** — this per-tick order,
canonically defined in `.claude/commands/pr-loop.md`, is authoritative; the poll / address-feedback /
merge scripts described above are the mechanism it runs. Two human control points
decide what the loop actually touches:

- **The `module:*` label is an explicit opt-in work queue.** The ADVANCE step only picks up **open issues
  labelled `module:<name>`** — lowest-numbered first, one at a time, and only when there are zero open PRs.
  An unlabelled issue is never touched, no matter what its title or body say. Two reasons:
  - **Intent gate** — most issues are discussions, questions, or half-scoped bugs; a bot shouldn't
    auto-implement them. The label is you saying "this is scoped and ready for an autonomous worker."
  - **Mechanism** — the label maps issue → module → the worker's `path` boundary (`gates.json.modules[]`).
    No module ⇒ no boundary ⇒ nothing safe to hand a worker.
- **Owner-approval merge gate.** Workers author PRs as the **bot** (`bot-gh.sh`); the MERGE step (above)
  only merges PRs the repo **owner** has Approved on GitHub that are CI-green and mergeable. It never
  approves on the owner's behalf.

**Corollary:** non-module (docs/infra) work is not loop-eligible until (a) its area exists as a module in
`gates.json.modules[]`, and (b) the issue carries the matching `module:*` label. Commenting "approved" on an
issue does nothing — nothing watches issue text.

New project? Wire this up with the **[new-project configuration
checklist](GETTING_STARTED.md#new-project-configuration-checklist)**.

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
