---
description: Arm (or re-arm) the self-hosted PR-loop cron and run one tick now
---

You are (re)arming this project's self-hosted PR loop — the loop that works THIS repo's own
`.claude`/`docs`/`examples`/`.github` backlog instead of a downstream project's. The loop is session-scoped
(cron jobs die when Claude Code exits and may not persist across restarts even when durable), so it is lost at
the start of each new session. This command restores the whole loop in one step. Do BOTH parts.

The repo is derived from the git remote (`bash .claude/scripts/bot-gh.sh repo view --json nameWithOwner -q .nameWithOwner`); the bot login defaults to `$BOT_LOGIN`. This command is self-hosting only: it always points every gate and every agent at `GATES_FILE=.claude/self/gates.json` (see `.claude/self/README.md`), never the placeholder root `.claude/gates.json`.

## 1. (Re)arm the cron — idempotent
- Call `CronList`. If a job already exists whose prompt mentions "self-hosted PR loop", leave it (do not duplicate) and report its id + schedule. (This job's armed prompt never contains the base loop's exact marker substring "autonomous PR loop" — it says "self-hosted PR loop" instead — so `/pr-loop`'s idempotency check, which matches on "autonomous PR loop", will never match this job. Conversely, the base loop's armed prompt never contains "self-hosted PR loop", so this command's idempotency check will never match the base loop's job. The two loops therefore never cross-match in either direction.)
- Otherwise `CronCreate` with `durable: true`, schedule `*/5 * * * *`, and the EXACT prompt below (STEP 0 will self-adjust the cadence on the first tick).

Prompt to use (the tick logic, with adaptive STEP 0):

> Run one tick of the self-hosted PR loop. Resolve the repo with `bash .claude/scripts/bot-gh.sh repo view --json nameWithOwner -q .nameWithOwner`. Export `GATES_FILE=.claude/self/gates.json` for every gate/orchestration step, and instruct every spawned agent (orchestrator, implementers, reviewers) to read `.claude/self/gates.json` — NOT the placeholder root `.claude/gates.json` — as its adapter (module map, gates, review lenses). Follow docs/USAGE.md and .claude/agents/* for mechanics; reviewer lenses + consensus per `.claude/self/gates.json` (`correctness`, `tests`; consensus `all`). Every `gate.sh` invocation MUST be run as `GATES_FILE=.claude/self/gates.json bash .claude/scripts/gate.sh <name>`. ALL `gh` interaction (yours and every agent's) MUST run as the bot via `.claude/scripts/bot-gh.sh` — never bare `gh`; only `git` commits/pushes stay as the owner.
>
> STEP 0 — adaptive cadence: count open PRs (base = `.claude/self/gates.json` merge.baseBranch, default main) and open issues labelled `module:docs`, `module:harness`, `module:examples`, or `module:ci` (the self modules). Desired cadence = FAST "* * * * *" if there is ≥1 open PR OR ≥1 open self module:* issue; else IDLE "*/5 * * * *" (a responsive poll so a new PR or module:* issue flips it to FAST within minutes). If this job's current schedule != desired, CronDelete this job and CronCreate a durable replacement with this SAME prompt at the desired schedule.
>
> Then, in order:
> 1. POLL: run `bash .claude/scripts/notify-poll.sh`; summarize new issues / PR comments / reviews and the open-PR status section.
> 2. MERGE: run `bash .claude/scripts/merge-ready.sh`; report each PR merged or why skipped. (It only merges PRs the owner APPROVED that are CI-green & mergeable; never approves.)
> 3. ADDRESS FEEDBACK: run `bash .claude/scripts/pr-feedback.sh`; for each PR it lists (bot-authored, with unaddressed CHANGES_REQUESTED), run orchestrator→worktree implementer→reviewer-lenses (self adapter: `GATES_FILE=.claude/self/gates.json`, lenses `correctness`/`tests`, consensus `all`) on the SAME branch, push to update the PR in place, and post the `<!-- claude-addressed -->` marker comment via bot-gh.sh. Do NOT merge here.
> 4. ADVANCE: ONLY when there are ZERO open PRs — pick the lowest-numbered open self `module:*` issue (`module:docs`, `module:harness`, `module:examples`, `module:ci`) with no feat/issue-<n>-* branch; drive it through the orchestrator using `.claude/self/gates.json` as the adapter (scope → worktree implementer → `GATES_FILE=.claude/self/gates.json gate.sh` gates → reviewer lenses `correctness`/`tests` consensus `all` → bot PR). One issue in flight at a time.
> 5. If nothing actionable, reply exactly one line: "No actionable activity."

## 2. Run one tick now
Execute steps 1–5 above immediately so the loop doesn't wait for the next cron fire. Report what happened (polled items, merges, feedback addressed, issue advanced — or "no actionable activity").

Notes: requires the bot machine account set up per docs/USAGE.md (`GH_BOT_TOKEN` in `.env`, bot is a write collaborator) so PRs are bot-authored and the owner can formally Approve them. Cadence is adaptive: FAST (every minute) whenever there's ≥1 open PR or ≥1 open self `module:*` issue, else a responsive IDLE poll (every 5 minutes) that flips to FAST within minutes of new work. For a tighter in-session cadence you can also run `/loop 5m /pr-loop-self`.
