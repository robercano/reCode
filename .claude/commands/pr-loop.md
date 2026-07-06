---
description: Arm (or re-arm) the autonomous PR-loop cron and run one tick now
---

You are (re)arming this project's autonomous PR loop. The loop is session-scoped (cron jobs die when Claude Code exits and may not persist across restarts even when durable), so it is lost at the start of each new session. This command restores the whole loop in one step. Do BOTH parts.

The repo is derived from the git remote (`bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh repo view --json nameWithOwner -q .nameWithOwner`); the bot login defaults to `$BOT_LOGIN`. Nothing here is project-specific — it reads `.claude/gates.json`, `.claude/scripts/*`, and `docs/USAGE.md`.

## 1. (Re)arm the cron — idempotent
- Call `CronList`. If a job already exists whose prompt mentions "autonomous PR loop", leave it (do not duplicate) and report its id + schedule.
- Otherwise `CronCreate` with `durable: true`, schedule `*/5 * * * *`, and the EXACT prompt below (STEP 0 will self-adjust the cadence on the first tick).

Prompt to use (the tick logic, with adaptive STEP 0):

> Run one tick of the autonomous PR loop. Resolve the repo with `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh repo view --json nameWithOwner -q .nameWithOwner`. Follow docs/USAGE.md and .claude/agents/*; reviewer lenses + consensus per .claude/gates.json. ALL `gh` interaction (yours and every agent's) MUST run as the bot via `.claude/scripts/bot-gh.sh` — never bare `gh`; only `git` commits/pushes stay as the owner.
>
> STEP 0 — adaptive cadence (every tick is a fresh full-context session, so cadence is the loop's dominant token cost — fire fast ONLY when the loop can act): count open PRs (base = gates.json merge.baseBranch, default main), open issues labelled module:*, and bot PRs with unaddressed CHANGES_REQUESTED (per pr-feedback.sh). Desired cadence = FAST "* * * * *" only if the loop has something to DO right now: ≥1 PR with unaddressed feedback, OR zero open PRs AND ≥1 open module:* issue (ready to advance). WATCH "*/5 * * * *" if PRs are open but merely waiting on human review or CI — the loop can't hurry a human. Else IDLE "*/15 * * * *". If this job's current schedule != desired, CronDelete this job and CronCreate a durable replacement with this SAME prompt at the desired schedule.
>
> Then, in order:
> 1. POLL: run `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/notify-poll.sh`; summarize new issues / PR comments / reviews and the open-PR status section.
> 2. MERGE: run `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/merge-ready.sh`; report each PR merged or why skipped. (It only merges PRs the owner APPROVED that are CI-green & mergeable; never approves.)
> 3. ADDRESS FEEDBACK: run `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/pr-feedback.sh`; for each PR it lists (bot-authored, with unaddressed CHANGES_REQUESTED), run orchestrator→worktree implementer→reviewer-lenses on the SAME branch, push to update the PR in place, and post the `<!-- claude-addressed -->` marker comment via bot-gh.sh. Do NOT merge here.
> 4. ADVANCE: ONLY when there are ZERO open PRs — pick the lowest-numbered open module:* issue with no feat/issue-<n>-* branch; drive it through the orchestrator (scope → worktree implementer → gate.sh gates → reviewer lenses → bot PR). One issue in flight at a time.
> 5. If nothing actionable, reply exactly one line: "No actionable activity."
>
> Token discipline: only read docs/USAGE.md and .claude/agents/* when a step actually orchestrates agents (3–4); poll/merge-only ticks need only the script outputs. Keep the tick report to a few lines — it is telemetry, not documentation.

## 2. Run one tick now
Execute steps 1–5 above immediately so the loop doesn't wait for the next cron fire. Report what happened (polled items, merges, feedback addressed, issue advanced — or "no actionable activity").

Notes: requires the bot machine account set up per docs/USAGE.md (`GH_BOT_TOKEN` in `.env`, bot is a write collaborator) so PRs are bot-authored and the owner can formally Approve them. Cadence is adaptive and biased toward cheap ticks (each tick is a fresh full-context session): FAST (every minute) only while the loop has actionable work — unaddressed PR feedback, or an issue ready to advance with no PR in flight; WATCH (every 5 minutes) while PRs wait on human review/CI; IDLE (every 15 minutes) otherwise. New work is picked up within one WATCH/IDLE interval. For a tighter in-session cadence you can also run `/loop 5m /pr-loop`.
