---
description: Arm (or re-arm) the autonomous PR-loop cron and run one tick now
---

**LEGACY path (issue #102).** This is the session-scoped cron. The RECOMMENDED replacement is the cron-less
daemon: `systemd --user` supervises `.claude/scripts/loop-daemon.sh` forever, independent of any Claude Code
session, and spawns a driver only on an actionable verdict (never on `action=none`). Install it with
`bash .claude/scripts/arm-loop.sh` (run in a real terminal outside Claude Code — see `docs/HARDENING.md` →
Caveats), or via `/orchestrator:setup`'s "arm the loop" step. **Never run both the cron and the daemon against
the same repo at once** — `loop-tick.sh`'s spawn lock makes it *safe* (no double-spawn), merely wasteful (two
firing sources burning ticks against the same state). Keep reading below only if you're intentionally using
the legacy cron (no systemd available, or as a fallback).

You are (re)arming this project's autonomous PR loop. The loop is session-scoped (cron jobs die when Claude Code exits and may not persist across restarts even when durable), so it is lost at the start of each new session. This command restores the whole loop in one step. Do BOTH parts.

The repo is derived from the git remote (`bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/bot-gh.sh repo view --json nameWithOwner -q .nameWithOwner`); the bot login defaults to `$BOT_LOGIN`. Nothing here is project-specific — it reads `.claude/gates.json`, `.claude/scripts/*`, and `docs/USAGE.md`.

## 1. (Re)arm the cron — idempotent
- Call `CronList`. If a job already exists whose prompt mentions "autonomous PR loop", leave it (do not duplicate) and report its id + schedule.
- Otherwise `CronCreate` with `durable: true`, schedule `*/5 * * * *`, and the EXACT prompt below (STEP 0 will self-adjust the cadence on the first tick).

Prompt to use (the tick logic, with adaptive STEP 0):

> Run one tick of the autonomous PR loop. ALL `gh` interaction (yours and every agent's) MUST run as the bot via `.claude/scripts/bot-gh.sh` — never bare `gh`; only `git` commits/pushes stay as the owner.
>
> STEP 0 — run the tick. Invoke, as a REAL bash tool call, exactly: `bash ${CLAUDE_PLUGIN_ROOT:-.claude}/scripts/loop-tick.sh`. This one script runs census, then notify-poll.sh, merge-ready.sh, and pr-feedback.sh, IN ORDER, with their full output, and ends with exactly one machine-readable verdict line as the LAST line of output: `action=none`, `action=advance issue=N`, or `action=feedback pr=N`. That verdict line is the SOLE source of truth for what to do next: never hand-count open PRs, planned issues, or feedback PRs yourself, and never skip this invocation because the tick "looks quiet" — it must run, and its output must be read, on every single tick with no exceptions.
>
> CADENCE: the script's `=== 1/4 loop-census.sh ===` section includes a line `cadence=FAST|WATCH|IDLE cron=<expr>` — this is the desired cadence; consume it as-is, do NOT re-derive it from counts. If this cron job's current schedule differs from that `cron=<expr>`, CronDelete this job and CronCreate a durable replacement with this SAME prompt at the desired schedule.
>
> Then obey the verdict line (the tick already ran poll/merge/feedback-detection above — do not re-run those scripts):
> - `action=feedback pr=N` → address PR N's feedback: run orchestrator → worktree implementer → reviewer lenses (per .claude/gates.json) on the SAME branch, push to update the PR in place, and post the `<!-- claude-addressed -->` marker comment via bot-gh.sh. Do NOT merge.
> - `action=advance issue=N` → advance issue N through the orchestrator (scope → worktree implementer → gate.sh gates → reviewer lenses → bot PR). One issue in flight at a time. `backlog` issues are owner-unapproved: never pick them, and if you file an issue yourself, label it `backlog` — NEVER `planned` (that label is the owner's formal approval and is assigned by the owner alone; see docs/USAGE.md → "Autonomous loop & the issue queue").
> - `action=none` → reply exactly one line: "No actionable activity." This is the ONLY path to that phrase — never reply it without loop-tick.sh having actually been invoked (and its output read) earlier in this same turn.
>
> Token discipline: only read docs/USAGE.md and .claude/agents/* when the verdict actually requires orchestrating agents (advance/feedback); an `action=none` tick needs only the script's own output. Keep the tick report to a few lines — it is telemetry, not documentation.

## 2. Run one tick now
Execute the tick logic above immediately so the loop doesn't wait for the next cron fire. Report what happened (polled items, merges, feedback addressed, issue advanced — or "No actionable activity").

Notes: requires the bot machine account set up per docs/USAGE.md (`GH_BOT_TOKEN` in `.env`, bot is a write collaborator) so PRs are bot-authored and the owner can formally Approve them. Cadence is adaptive and biased toward cheap ticks (each tick is a fresh full-context session): FAST (every minute) only while the loop has actionable work — unaddressed PR feedback, or a `planned` module:* issue ready to advance with no PR in flight; WATCH (every 5 minutes) while PRs wait on human review/CI; IDLE (every 15 minutes) otherwise. New work is picked up within one WATCH/IDLE interval. For a tighter in-session cadence you can also run `/loop 5m /pr-loop`.
