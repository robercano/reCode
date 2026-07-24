#!/usr/bin/env bash
# loop-census.sh — one-shot STEP 0 census for the PR loop (base and self-hosted).
# Prints, as stable key=value telemetry, everything a tick needs to decide
# whether it can ACT — so the actionability check is a single pre-approvable
# command instead of a discipline the tick can silently skip:
#
#   open_prs=N                  open PRs against the adapter's base branch
#   feedback_prs=N              bot PRs with unaddressed CHANGES_REQUESTED (pr-feedback.sh)
#   ci_fix_prs=N                 bot PRs with a failing CI check on the current
#                               head, not already a feedback candidate, not
#                               already addressed for that head (pr-ci-fix.sh,
#                               issue #96)
#   comment_fix_prs=N            bot PRs with an unresolved, qualifying (owner
#                               or allowlisted-bot) review-comment thread, not
#                               already a feedback candidate, not already
#                               addressed for its current state
#                               (pr-comment-fix.sh, issue #96 part 2)
#   rebase_prs=N                 bot PRs that went unmergeable (mergeable=
#                               CONFLICTING) against base, not already a
#                               feedback/comment-fix/ci-fix candidate, not
#                               already rebased for the current base commit
#                               (pr-rebase.sh, issue #96 part 3)
#   planned_issues=N            open issues labelled `planned` AND one of the
#                               adapter's module:* labels, one detail line each
#                               (candidates are ordered — see PRIORITY ORDERING
#                               below — before this loop, in that same order):
#     issue=<n> branch=<feat/issue-n-* or none> title=<title>
#   in_flight=<n>                one line PER planned issue that has a
#                               feat/issue-n-* branch (local or remote) but NO
#                               open PR for it yet — i.e. work has started but
#                               hasn't reached PR stage. A tick uses this to
#                               avoid double-spawning an orchestrator for an
#                               issue that already has a worktree in progress.
#                               A REMOTE-ONLY branch match (no local branch of
#                               the same name) that turns out to be a stale
#                               ref for an issue whose PR already MERGED is
#                               ignored (branch=none) instead of counting as
#                               in_flight forever — see STALE-MERGED-REMOTE
#                               below (issue #158).
#   stalled=<n> age_min=<m>      one line PER in_flight issue whose most recent
#                               events.jsonl activity is older than the stall
#                               threshold (issue #98) — see STALL DETECTION
#                               below. A tick uses this to RESUME a hung/dead
#                               in_flight issue instead of refusing it forever.
#   blocked=<n> by=<N>          one line per candidate that would otherwise be
#                               advance_ready but is skipped because its body
#                               says "Blocked by #N" and issue N is still OPEN
#                               (issue #97). Only the first open blocker per
#                               candidate is reported — one is enough to
#                               explain the skip; a candidate may have more.
#   advance_ready=<n|none>      highest-priority, then lowest-numbered, planned
#                               issue with no branch, only when open_prs=0 (the
#                               ADVANCE precondition) AND not blocked by an
#                               open "Blocked by #N" edge — see PRIORITY
#                               ORDERING below (issue #173)
#   plan_wait=<n>                one line per candidate that would otherwise be
#                               advance_ready but is awaiting owner review of a
#                               posted plan (labelled `plan-review`, no
#                               `plan-approved` yet) — issue #100's plan gate,
#                               see PLAN GATE below. Only emitted when
#                               plan.gate != "off".
#   advance_mode=plan|implement-gated|implement   only emitted alongside a
#                               non-"none" advance_ready when plan.gate !=
#                               "off" (issue #100) — tells the tick which
#                               driver prompt variant to build.
#   milestone=<title>            the CURRENT open milestone in scope (issue
#   milestone_open=<n>          #174) — see MILESTONE SCOPING below. Emitted
#                               ONLY when a milestone is actually in scope
#                               (immediately after `planned_issues=`, before
#                               the per-issue `issue=`/detail lines — see
#                               MILESTONE SCOPING for why this position was
#                               chosen). Absent entirely on the fallback path
#                               (no qualifying open milestone, or no
#                               milestones at all), so census output for a
#                               repo that doesn't use milestones stays
#                               byte-identical to before this feature.
#   main_dirty=yes|no           `git -C $root status --porcelain` is non-empty
#                               AFTER excluding (a) sandbox-mask phantom paths
#                               (device-node masks, see below) and (b) the
#                               read-only-mounted `.claude/agents/` and
#                               `.claude/skills/setup/templates/` paths, which
#                               can legitimately lag behind HEAD in sandboxed
#                               sessions — i.e. the MAIN checkout has real
#                               uncommitted state. Surfaces issue #106's failure
#                               mode: a worker mutated the shared main checkout
#                               instead of its own worktree.
#   main_head=<branch>|detached   the MAIN checkout's current HEAD: the branch
#                               name, or literally `detached` when HEAD isn't
#                               on any branch. Surfaces the 2026-07-16 incident
#                               where a driver's `git checkout` failed mid-op
#                               on a read-only-mounted agent file and left main
#                               in a DETACHED HEAD on an unmerged commit for
#                               ~12h — a state a clean working tree alone
#                               (main_dirty=no) would NOT reveal.
#   cadence=FAST|WATCH|IDLE cron=<expr>   desired cadence per the loop policy
#
# --- PLAN GATE (issue #100) -------------------------------------------------
# Optional, adapter-configured via plan.gate ("off" default | "label" |
# "always"; see gates.json). When enabled, each candidate's labels classify it
# as needs-plan (no plan posted yet — advance_mode=plan gates it into a
# PLAN-ONLY driver turn), awaiting-owner (`plan-review` label present, no
# `plan-approved` yet — treated like an open "Blocked by" edge: skipped for
# BOTH advance_ready and fallback_ready, reported via plan_wait=<n>),
# gated-approved (`plan-approved` present — advance_mode=implement-gated, the
# approved plan comment is injected into the implementer/reviewers as
# authoritative scope), or ungated (advance_mode=implement, today's behavior).
# plan.gate="off" makes every line above a no-op — census output stays
# byte-identical to pre-#100 behavior.
#
# The module label set is derived from $GATES_FILE (default .claude/gates.json)
# → modules[].name, so the same script serves the self-hosted loop
# (GATES_FILE=.claude/self/gates.json) and downstream adopters.
#
# WHY THIS EXISTS (issue: loop stalled 13h with two planned issues): ticks that
# "optimized" STEP 0 away — or piped the cursor-advancing notify-poll.sh through
# `tail -1` — reported "No actionable activity" while ADVANCE work sat ready.
# A tick may claim "No actionable activity" ONLY when this census prints zeros.
#
# --- PRIORITY ORDERING (issue #173) -----------------------------------------
# The planned-candidate TSV is ordered by (priority rank, issue number) before
# advance_ready/detail/blocking/in_flight ever iterate it. Priority rank comes
# straight from the labels already fetched (2nd TSV field) — critical=0,
# high=1, medium=2, low=3, and NO priority:* label ranks LAST (4). Issue
# number is the tiebreaker within a rank (and the sole ordering when every
# candidate is unlabeled), so a label-free backlog sorts identically to the
# pre-#173 `sort -n` and every downstream line (issue=/in_flight=/blocked=/
# advance_ready=) is byte-identical to before this feature. Priority is
# PREFERENCE only: the blocking-graph gate below still overrides it — a
# blocked candidate is skipped regardless of how high its priority is; edges
# are semantics, priority is just iteration order among what's unblocked.
#
# --- MILESTONE SCOPING (issue #174) -----------------------------------------
# Milestones represent versions (SCRUM sprints): the loop must drain the
# CURRENT milestone before it wanders into a future one. "Current" is derived
# FRESH every run (no persistent cursor) as: among the repo's OPEN milestones
# (state=open), the one with the lowest version-ish title (natural/`sort -V`
# semantics — v1.0 < v1.1 < v2.0, "Sprint 1" < "Sprint 2") that has AT LEAST
# ONE open candidate — same predicate the census already uses (planned label
# + a module: label). When that milestone drains (0 qualifying candidates),
# THIS SAME re-derivation picks the next-lowest qualifying open milestone as
# current on the very next tick automatically — no bookkeeping. An idle gap
# after a milestone drains, before the owner labels the next milestone's
# issues `planned`, is intended: the owner controls phase boundaries by when
# they add that label.
#
# SCOPE: the candidate set for ADVANCE (planned_issues/issue=/in_flight=/
# stalled=/blocked=/plan_wait=/advance_ready=) is filtered down to ONLY the
# current milestone's issues — applied as a FILTER on top of the existing
# (priority, number) ordering (issue #173), never disturbing it. Feedback/
# merge-phase counts (open_prs/feedback_prs/ci_fix_prs/comment_fix_prs/
# rebase_prs) are completely UNAFFECTED: open PRs are always serviced
# regardless of milestone.
#
# FALLBACK (graceful degradation): if NO open milestone has a qualifying
# candidate — including the common case of a repo that doesn't use
# milestones at all, where the REST fetch below returns an empty set — census
# falls back to TODAY'S unscoped behavior (every planned+module candidate,
# repo-wide). This is why `milestone=`/`milestone_open=` are emitted ONLY
# when a milestone is actually in scope: it keeps output for a
# milestone-less repo byte-identical to before this feature, rather than
# printing an empty/sentinel milestone line every tick.
#
# WHERE milestone=/milestone_open= SIT: immediately after `planned_issues=`,
# before the per-candidate `issue=` detail lines — grouped with the other
# scope-summary fact (planned_issues is already the SCOPED count once a
# milestone is in play) rather than interleaved among per-issue lines.
#
# gh 2.4.0 CONSTRAINT: this gh version has no `gh milestone` subcommand and no
# `gh api graphql` — milestone data is fetched with a plain REST `gh api`
# call (`repos/{owner}/{repo}/milestones?state=open`), always routed through
# bot-gh.sh like every other gh call here. Per-issue milestone association
# reuses the EXISTING `gh issue list --json ...` call that already fetches
# the planned+module candidates — a `milestone` field is simply added to its
# --json/--jq, rather than issuing a second per-milestone issue query.
#
# MILESTONE-COMPLETE EVENT: the milestones REST response already reports
# `open_issues`/`closed_issues` per milestone, so "the last issue in a
# milestone closes" is detected directly (open_issues==0 with closed_issues
# >= 1, i.e. genuinely drained rather than never-populated) without any extra
# gh call. This is the ONE deliberate exception to this script's read-only /
# re-run-safe contract (see the file-level comment below): it appends to
# events.jsonl via log-event.sh. A drained milestone typically stays
# state=open for days (the idle gap after it drains IS the PO-feedback
# phase), so census re-observes the SAME drained milestone on every tick
# through that whole window — idempotency has to survive that. events.jsonl
# itself is NOT a valid ledger for that check: log-event.sh caps it to the
# last EVENTS_MAX_LINES (default 2000) lines, oldest-first, so a scan-based
# "is it already in events.jsonl" guard eventually loses its own marker line
# to rotation and re-logs a duplicate. Idempotency is instead tracked in a
# small, NEVER-rotated sidecar file (`.claude/state/milestone-complete-
# logged.json`, keyed by milestone NUMBER — stable, unlike a title an owner
# could edit), with the whole check-then-log critical section serialized by
# a real `flock` (same TOCTOU class loop-tick.sh's advance lock closes,
# issue #81) so two overlapping census/cockpit invocations can't both
# observe "not yet logged" and both append.
#
# --- BLOCKING-GRAPH GATE (issue #97) ----------------------------------------
# advance_ready additionally skips any otherwise-eligible candidate (branch=
# none, open_prs=0, no active driver) whose body contains an explicit
# "Blocked by #N" edge to an issue that is STILL OPEN. We reuse cockpit.sh's
# ONE `--parse-blocking` parser (shelled out to, never reimplemented here) to
# extract that edge — we deliberately do NOT gate on task-list/parent-child
# refs (`- [ ] #N`): those are cosmetic tracker structure, and tracking issues
# stay in `backlog` forever precisely so the loop works the chain and never
# the tracker (see docs/USAGE.md). Because this census re-runs every tick, a
# blocker closing makes the previously-blocked issue eligible again for free
# — no extra bookkeeping needed.
#
# CYCLE SAFETY: bash has no cheap topological-sort/cycle-detection story, and
# this script doesn't attempt one. If, after applying the blocker filter, NO
# planned candidate qualifies as advance_ready — which is exactly what a
# "Blocked by" cycle among planned issues produces, as well as the
# genuinely-all-blocked case — we fall back to the lowest-numbered otherwise-
# eligible candidate (branch=none, open_prs=0, no active driver — ignoring
# the block) and log that fallback to stderr. This only fires when at least
# one candidate was otherwise eligible; with zero eligible candidates,
# advance_ready stays "none" exactly as before this feature.
#
# --- STALE-MERGED-REMOTE (issue #158) ---------------------------------------
# `git branch -a --list "*feat/issue-N-*"` matches BOTH local branches and
# remote-tracking refs (`remotes/origin/...`). After a PR merges — even with
# `gh pr merge --delete-branch` — the MAIN checkout's local remote-tracking
# ref for that branch can survive until pruned (`git fetch --prune` /
# `git remote prune`). Without this guard, a still-open issue whose partial
# PR already merged would keep matching that stale ref FOREVER, so census
# would report it in_flight forever — wedging advance_ready and eventually
# tripping stall/escalation for an issue that in truth has no active branch.
#
# Fix: when the ONLY match for an issue is a remote-tracking ref (no local
# branch of the same name), look up whether a MERGED PR exists for that bare
# branch name. If one does, treat the issue as branch=none (ignore the stale
# ref) — it neither counts as in_flight nor blocks advance_ready. If no
# merged PR is found (the common case: work genuinely in progress, only
# pushed, local branch since deleted), remote-only in_flight is preserved
# exactly as before this fix. A genuine LOCAL branch match is unaffected —
# it always wins over a remote-only one, so this only changes behavior for
# the specific remote-only-and-already-merged case.
#
# --- STALL DETECTION (issue #98) --------------------------------------------
# An `in_flight` issue (feat/issue-N-* branch exists, no open PR yet) can sit
# forever if the driver that created it hung or died without ever reaching
# loop-daemon.sh's post-exit verification (issue #111) — e.g. the daemon
# process itself was restarted/killed mid-drive. This census can't see driver
# health directly, but it CAN see whether anything has logged progress for
# that issue recently: log-event.sh (issue #52) appends one JSONL line per
# phase transition to events.jsonl, with a `task` field that's been observed
# in BOTH a bare issue number ("42") and an "issue-42" form across this
# project's real history — an in_flight issue is STALLED when the newest
# event naming it (by either form) is older than `budget.stall_minutes`
# (adapter-configurable, default 30; see gates.json).
#
# CONSERVATIVE FALSE-POSITIVE RULE: an issue with ZERO events at all is NEVER
# reported stalled — a branch/worktree just created by a driver that hasn't
# logged its first event yet looks identical to a permanently-abandoned one
# from events.jsonl's point of view alone; treating "no data yet" as "stalled"
# would kill fresh work. Only a issue with AT LEAST ONE event, whose newest is
# past the threshold, is reported.
#
# Events file: defaults to <root>/.claude/state/events.jsonl; override with
# $CLAUDE_EVENTS_FILE (same env var log-event.sh itself honors) for
# testability without touching the real, gitignored state dir.
#
# Repo derived from the git remote; override with $1. Bot login via $BOT_LOGIN.
# Invoke as `bash .claude/scripts/loop-census.sh` (pre-approve that exact
# command). Read-only: advances no cursor, mutates nothing — safe to re-run.
# The SOLE exception is the milestone-complete event append (issue #174, see
# MILESTONE SCOPING above) — an events.jsonl write guarded to fire once per
# milestone by a separate, never-rotated sidecar ledger, never a stdout/
# behavior change; every other line above stays a pure read.
set -euo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
# Route EVERY gh call through the bot identity (see bot-gh.sh).
gh() { bash "$script_dir/bot-gh.sh" "$@"; }
repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

gates_rel="${GATES_FILE:-.claude/gates.json}"
case "$gates_rel" in /*) gates="$gates_rel" ;; *) gates="$root/$gates_rel" ;; esac

# main_dirty (issue #106): is the MAIN checkout ($root) dirty? A `git status
# --porcelain` line is only real dirt if its path is NOT one of:
#   (a) one of the sandbox's `/dev/null` character-device masks (`.mcp.json`,
#       `.claude/routines`, `.idea`, `.vscode`, `.gitmodules`,
#       `.claude/launch.json` — see docs/HARDENING.md -> Caveats), or
#   (b) under the read-only-mounted `.claude/agents/` or
#       `.claude/skills/setup/templates/` trees, which can legitimately lag
#       behind HEAD in sandboxed sessions (the bind-mount, not a real edit).
# Those are expected artifacts, not a worker's or owner's real uncommitted
# work, so they must never flip main_dirty to "yes".
main_dirty="no"
status_lines=$(git -C "$root" status --porcelain 2>/dev/null || true)
if [ -n "$status_lines" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    path="${line:3}"
    case "$path" in
      *" -> "*) path="${path##* -> }" ;;  # rename: "old -> new" -> take new
    esac
    # git quotes paths containing unusual characters in double quotes; strip
    # a matched leading/trailing quote pair if present.
    case "$path" in
      \"*\") path="${path#\"}"; path="${path%\"}" ;;
    esac
    if [ -c "$root/$path" ]; then
      continue  # sandbox-mask phantom path — not real dirt, skip
    fi
    case "$path" in
      .claude/agents/*|.claude/skills/setup/templates/*)
        continue  # read-only-mount path that can legitimately lag HEAD, skip
        ;;
    esac
    main_dirty="yes"
    break
  done <<< "$status_lines"
fi
echo "main_dirty=$main_dirty"

# main_head (issue #106): the MAIN checkout's current HEAD — the branch name,
# or literally "detached" when HEAD isn't on any branch. Companion signal to
# main_dirty: the 2026-07-16 incident left main on a DETACHED HEAD with a
# CLEAN working tree (main_dirty=no would have missed it entirely), so this
# must be reported independently rather than folded into main_dirty.
main_head=$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$main_head" ] || main_head="detached"
echo "main_head=$main_head"

# Adapter-derived facts: base branch + the module:* label set.
base=$(node -e 'const g=require(process.argv[1]); console.log((g.merge&&g.merge.baseBranch)||"main")' "$gates")
module_labels=$(node -e 'const g=require(process.argv[1]); console.log(g.modules.map(m=>"module:"+m.name).join("\n"))' "$gates")

# Stall threshold (issue #98), adapter-overridable via budget.stall_minutes;
# same node -e / require(gates) pattern as base/module_labels above.
stall_minutes=$(node -e '
  const g = require(process.argv[1]);
  const v = g.budget && g.budget.stall_minutes;
  console.log((Number.isFinite(v) && v > 0) ? v : 30);
' "$gates" 2>/dev/null)
case "$stall_minutes" in ''|*[!0-9]*) stall_minutes=30 ;; esac

# Plan gate mode (issue #100), adapter-configurable via plan.gate: "off"
# (default — this whole feature is a no-op, census output stays byte-identical
# to pre-#100 behavior) | "label" (gate only candidates that ALSO carry the
# plan-first label) | "always" (gate every planned+module candidate). Unknown/
# missing value falls back to "off". Read ONCE, same node -e / require(gates)
# pattern as base/module_labels/stall_minutes above.
plan_mode=$(node -e '
  const g = require(process.argv[1]);
  const v = (g.plan && g.plan.gate) || "off";
  console.log(["off", "label", "always"].includes(v) ? v : "off");
' "$gates" 2>/dev/null)
case "$plan_mode" in off|label|always) ;; *) plan_mode=off ;; esac

events_file="${CLAUDE_EVENTS_FILE:-$root/.claude/state/events.jsonl}"

# --- milestone REST fetch (issue #174) ---------------------------------------
# gh 2.4.0 has no `gh milestone` subcommand and no `gh api graphql` — plain
# REST, always through the bot-gh.sh wrapper. `2>/dev/null || true` degrades
# gracefully (empty $milestones_tsv) on ANY failure — a repo with no
# milestones, a stubbed bot-gh.sh in tests that doesn't implement `api`, or a
# transient gh error — which is exactly the FALLBACK path (see MILESTONE
# SCOPING above): census must never abort, and an empty result here makes
# every downstream milestone check a no-op, falling back to today's unscoped
# behavior.
milestones_tsv=$(gh api --paginate "repos/$repo/milestones?state=open" \
  --jq '.[] | [.number, .title, .open_issues, .closed_issues] | @tsv' 2>/dev/null) || true

# Version-sort ascending by title (2nd TSV field) — natural/`sort -V`
# semantics (v1.0 < v1.1 < v2.0, "Sprint 1" < "Sprint 2"). GNU coreutils sort
# supports "V" as a per-key modifier (`-k2,2V`), so this needs no manual
# swap-sort-swap dance.
milestones_sorted=""
if [ -n "$milestones_tsv" ]; then
  milestones_sorted=$(printf '%s\n' "$milestones_tsv" | sort -t $'\t' -k2,2V)
fi

# --- milestone-complete event (issue #174) — THE ONE read-only exception ----
# A milestone is "complete" when the REST fetch's own open_issues/
# closed_issues counters show it fully drained (open_issues==0) AND it
# genuinely had issues to drain (closed_issues>=1 — never fires for an empty/
# never-populated milestone). Idempotency is tracked in a dedicated,
# never-rotated sidecar file (NOT events.jsonl — see the MILESTONE-COMPLETE
# EVENT note above for why a rotation-subject log can't be the ledger),
# keyed by milestone number, with the check-then-log critical section
# serialized by flock against concurrent census/cockpit invocations.
milestone_state_file="${CLAUDE_MILESTONE_STATE_FILE:-$root/.claude/state/milestone-complete-logged.json}"
milestone_lock_file="${CLAUDE_MILESTONE_LOCK_FILE:-$root/.claude/state/milestone-complete.flock}"
if [ -n "$milestones_tsv" ]; then
  mkdir -p "$(dirname "$milestone_state_file")" 2>/dev/null || true
  while IFS=$'\t' read -r ms_num ms_title ms_open ms_closed; do
    [ -z "${ms_title:-}" ] && continue
    case "$ms_num" in ''|*[!0-9]*) continue ;; esac
    case "$ms_open" in ''|*[!0-9]*) continue ;; esac
    case "$ms_closed" in ''|*[!0-9]*) continue ;; esac
    if [ "$ms_open" -eq 0 ] && [ "$ms_closed" -ge 1 ]; then
      (
        exec 8>"$milestone_lock_file"
        flock -x 8
        already_logged=$(CLAUDE_MS_STATE_FILE="$milestone_state_file" CLAUDE_MS_NUM="$ms_num" node -e '
          const fs = require("fs");
          const file = process.env.CLAUDE_MS_STATE_FILE;
          const num = process.env.CLAUDE_MS_NUM;
          let logged = [];
          try { logged = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { logged = []; }
          if (!Array.isArray(logged)) logged = [];
          console.log(logged.includes(num) ? "yes" : "no");
        ' 2>/dev/null) || already_logged="no"
        if [ "$already_logged" != "yes" ]; then
          CLAUDE_EVENTS_FILE="$events_file" bash "$script_dir/log-event.sh" \
            --role census --task "$ms_title" --phase milestone-complete \
            --detail "milestone drained (all issues closed)" >/dev/null 2>&1 || true
          CLAUDE_MS_STATE_FILE="$milestone_state_file" CLAUDE_MS_NUM="$ms_num" node -e '
            const fs = require("fs");
            const file = process.env.CLAUDE_MS_STATE_FILE;
            const num = process.env.CLAUDE_MS_NUM;
            let logged = [];
            try { logged = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { logged = []; }
            if (!Array.isArray(logged)) logged = [];
            if (!logged.includes(num)) logged.push(num);
            const tmp = file + ".tmp." + process.pid;
            fs.writeFileSync(tmp, JSON.stringify(logged));
            fs.renameSync(tmp, file);
          ' 2>/dev/null || true
        fi
      )
    fi
  done <<< "$milestones_tsv"
fi

# --- stall detection helper (issue #98) --------------------------------------
# $1 = issue number. Prints the age in whole minutes of the NEWEST
# events.jsonl line whose `task` field is either "$1" or "issue-$1" (both
# forms occur in this project's real log), or nothing when there is no such
# event at all — callers must treat empty as "do not report stalled" (see the
# conservative false-positive rule in the header comment above), never as 0.
last_event_age_minutes() {
  CLAUDE_STALL_EVENTS_FILE="$events_file" CLAUDE_STALL_ISSUE="$1" node -e '
    const fs = require("fs");
    const file = process.env.CLAUDE_STALL_EVENTS_FILE;
    const num = process.env.CLAUDE_STALL_ISSUE;
    let latest = null;
    try {
      const text = fs.readFileSync(file, "utf8");
      for (const line of text.split("\n")) {
        if (!line.trim()) continue;
        let o;
        try { o = JSON.parse(line); } catch (e) { continue; }
        if (o.task !== num && o.task !== ("issue-" + num)) continue;
        const t = Date.parse(o.ts);
        if (!Number.isFinite(t)) continue;
        if (latest === null || t > latest) latest = t;
      }
    } catch (e) { /* no file / unreadable -> latest stays null */ }
    if (latest === null) process.exit(0);
    console.log(Math.floor((Date.now() - latest) / 60000));
  ' 2>/dev/null
}

# --- driver-unit guard (issue #119): never advance an issue whose transient
# driver unit (pr-loop-driver-issue<N>, spawned by loop-daemon.sh's run_driver)
# is currently active — e.g. the driver hasn't reached `git checkout -b` yet,
# so it has no branch for the in_flight check below to catch. No-op (always
# "not active") when systemd/`systemctl --user` is unavailable.
driver_unit_active() {
  command -v systemctl >/dev/null 2>&1 || return 1
  local st
  st="$(systemctl --user is-active "pr-loop-driver-issue$1" 2>/dev/null || true)"
  case "$st" in active|activating) return 0 ;; *) return 1 ;; esac
}

# --- blocking-graph helpers (issue #97) -------------------------------------
# is_open_issue: is issue number $1 present in the pre-fetched open-issue set?
is_open_issue() {
  [ -n "$open_issue_set" ] || return 1
  printf '%s\n' "$open_issue_set" | grep -qx "$1"
}

# get_blocked_by: given the JSON emitted by `cockpit.sh --parse-blocking`
# (or an empty string), print each blockedBy issue number on its own line.
# Guarded against empty/malformed input — never aborts the caller.
get_blocked_by() {
  local json="$1"
  [ -n "$json" ] || return 0
  node -e '
    try {
      const o = JSON.parse(process.argv[1] || "{}");
      (o.blockedBy || []).forEach((n) => console.log(n));
    } catch (e) { /* malformed/empty — print nothing */ }
  ' "$json" 2>/dev/null || true
}

open_prs=$(gh pr list -R "$repo" --state open --base "$base" --json number --jq 'length')
echo "open_prs=$open_prs"

# Head branch names of every open PR (against base) — used below to tell
# in_flight (branch exists, no PR yet) apart from already-at-PR-stage.
open_pr_branches=$(gh pr list -R "$repo" --state open --base "$base" --json headRefName --jq '.[].headRefName')

# All open issue numbers (bounded --limit, matching cockpit.sh's own --state
# open fetch) — used to decide whether a candidate's "Blocked by #N" target
# is still open. `|| true` guards a transient gh failure from wedging the
# whole census; an empty set just makes is_open_issue always report false,
# i.e. the blocking gate degrades to a no-op (same as before this feature).
open_issue_set=$(gh issue list -R "$repo" --state open --json number --jq '.[].number' --limit 200 2>/dev/null) || true

# PR_FEEDBACK_COUNT_ONLY=1 (issue #99 re-review finding #2): census is a
# read-only report -- it must NEVER mutate GitHub state. pr-feedback.sh's own
# per-PR loop calls needs_human_flag/needs_human_clear (label/comment/notify)
# as a side effect of its real dispatch role; count-only mode suppresses all
# of that while still printing the identical TSV this line counts. The real,
# side-effecting invocation stays in loop-tick.sh, which actually dispatches
# fixes for the PRs this counts.
feedback_prs=$(PR_FEEDBACK_COUNT_ONLY=1 bash "$script_dir/pr-feedback.sh" "$repo" | grep -c . || true)
echo "feedback_prs=$feedback_prs"

ci_fix_prs=$(bash "$script_dir/pr-ci-fix.sh" "$repo" | grep -c . || true)
echo "ci_fix_prs=$ci_fix_prs"

comment_fix_prs=$(bash "$script_dir/pr-comment-fix.sh" "$repo" | grep -c . || true)
echo "comment_fix_prs=$comment_fix_prs"

rebase_prs=$(bash "$script_dir/pr-rebase.sh" "$repo" | grep -c . || true)
echo "rebase_prs=$rebase_prs"

# Open `planned` issues carrying any of the adapter's module labels, ordered
# by (priority rank, issue number) — see PRIORITY ORDERING above (issue
# #173). Rank is derived from the labels field already in the TSV (no extra
# gh call): prepend a rank column, sort numerically on (rank, number), then
# strip the rank column back off so the downstream `while IFS=$'\t' read -r
# num labels milestone_title title` loop is unchanged. The `milestone` field
# (issue #174) is fetched via the SAME --json/--jq as the rest of this TSV
# (never a separate per-milestone issue query — see the gh 2.4.0 note in
# MILESTONE SCOPING above), placed BEFORE title so title stays the LAST TSV
# field (may contain spaces) and is left untouched by this transform.
planned=$(gh issue list -R "$repo" --state open --label planned --json number,title,labels,milestone \
  --jq '.[] | [.number, ([.labels[].name]|join(",")), (.milestone.title // ""), .title] | @tsv' \
  | awk -F'\t' 'BEGIN { OFS = "\t" }
    {
      labels = $2
      rank = 4
      if (labels ~ /(^|,)priority:critical(,|$)/) rank = 0
      else if (labels ~ /(^|,)priority:high(,|$)/) rank = 1
      else if (labels ~ /(^|,)priority:medium(,|$)/) rank = 2
      else if (labels ~ /(^|,)priority:low(,|$)/) rank = 3
      print rank OFS $0
    }' \
  | sort -t $'\t' -k1,1n -k2,2n \
  | cut -f2-)

# --- current-milestone detection (issue #174) -------------------------------
# Walk the version-sorted open milestones ascending; the FIRST one with at
# least one qualifying candidate (module-label hit, same predicate as the
# main loop below) becomes "current". Stays empty (fallback: unscoped, exactly
# today's behavior) when $milestones_sorted is empty (no milestones at all —
# byte-identical output) or when no open milestone has a qualifying candidate.
current_milestone=""
if [ -n "$milestones_sorted" ]; then
  while IFS=$'\t' read -r ms_num ms_title ms_open ms_closed; do
    [ -z "${ms_title:-}" ] && continue
    qualifying=0
    while IFS=$'\t' read -r pnum plabels pmilestone ptitle; do
      [ -z "${pnum:-}" ] && continue
      [ "$pmilestone" = "$ms_title" ] || continue
      hit=0
      while IFS= read -r ml; do
        case ",$plabels," in *",$ml,"*) hit=1; break;; esac
      done <<< "$module_labels"
      [ "$hit" -eq 1 ] && qualifying=$((qualifying + 1))
    done <<< "$planned"
    if [ "$qualifying" -ge 1 ]; then
      current_milestone="$ms_title"
      break
    fi
  done <<< "$milestones_sorted"
fi

planned_count=0
advance_ready="none"
fallback_ready="none"
detail=""
in_flight=""
stalled_lines=""
blocked_lines=""
plan_wait_lines=""
advance_plan_state=""
fallback_plan_state=""
while IFS=$'\t' read -r num labels milestone_title title; do
  [ -z "${num:-}" ] && continue
  # Milestone scoping (issue #174): when a current milestone is in scope,
  # the ADVANCE candidate set is filtered down to ONLY its issues — a plain
  # skip here, applied on top of the (priority, number) ordering already
  # established above, never disturbing it. A no-op when current_milestone
  # is empty (fallback: unscoped, today's behavior).
  if [ -n "$current_milestone" ] && [ "$milestone_title" != "$current_milestone" ]; then
    continue
  fi
  hit=0
  while IFS= read -r ml; do
    case ",$labels," in *",$ml,"*) hit=1; break;; esac
  done <<< "$module_labels"
  [ "$hit" -eq 1 ] || continue
  planned_count=$((planned_count + 1))
  # Existing feat/issue-<n>-* branch: a LOCAL branch means genuinely in_flight
  # (branch #158) regardless of GitHub state. A REMOTE-ONLY match
  # (`remotes/origin/...`, no local branch of the same name) is only treated
  # as "existing" if it is NOT a stale ref left over from an already-merged
  # PR (issue #158): `git branch -a --list` matches BOTH local branches and
  # remote-tracking refs, and after a PR merges (even with
  # `gh pr merge --delete-branch`) the MAIN checkout's local remote-tracking
  # ref for it can survive until pruned — so a still-open issue whose partial
  # PR already merged would otherwise match that stale ref FOREVER and never
  # advance (wedges advance_ready, triggers false stall/escalation). A local
  # match, when present, always wins over a remote-only one.
  local_branch=""
  remote_branch=""
  branch_lines=$(git -C "$root" branch -a --list "*feat/issue-$num-*" | sed 's/^[* ]*//') || true
  if [ -n "$branch_lines" ]; then
    while IFS= read -r bl; do
      [ -z "$bl" ] && continue
      case "$bl" in
        remotes/*) [ -z "$remote_branch" ] && remote_branch="$bl" ;;
        *) [ -z "$local_branch" ] && local_branch="$bl" ;;
      esac
    done <<< "$branch_lines"
  fi

  if [ -n "$local_branch" ]; then
    branch="$local_branch"
  elif [ -n "$remote_branch" ]; then
    # Bare branch name (strip the "remotes/<remote>/" prefix, e.g.
    # "remotes/origin/feat/issue-158-x" -> "feat/issue-158-x") to query gh
    # for a merged PR under it. Only done on this remote-only path — never on
    # the common local-branch path above — to avoid the extra gh call there.
    # Guarded with `|| true` (transient gh failure degrades gracefully to "no
    # merged PR found", i.e. the prior remote-only-stays-in_flight behavior;
    # it must never abort the census under `set -euo pipefail`).
    bare_branch="${remote_branch#remotes/*/}"
    merged_count=$(gh pr list -R "$repo" --state merged --head "$bare_branch" --json number --jq 'length' 2>/dev/null) || true
    case "$merged_count" in ''|*[!0-9]*) merged_count=0 ;; esac
    if [ "$merged_count" -ge 1 ]; then
      branch="none"  # stale remote-tracking ref for an already-merged PR — ignore it (issue #158)
    else
      branch="${remote_branch#remotes/}"
    fi
  else
    branch="none"
  fi
  [ -n "$branch" ] || branch="none"
  detail+="issue=$num branch=$branch title=$title"$'\n'

  eligible=0
  if [ "$branch" = "none" ] && [ "$open_prs" -eq 0 ] && ! driver_unit_active "$num"; then
    eligible=1
  fi

  # --- plan gate (issue #100): derive this candidate's plan state from its
  # labels. When gated (mode==always, or mode==label+plan-first) and not yet
  # plan-reviewed/approved, an "awaiting-owner" candidate (plan posted, owner
  # hasn't approved/rejected it yet) is NOT eligible for advance — the same
  # treatment as a "Blocked by" dependency: it's blocked on a human, not ready
  # to advance. Entirely a no-op (plan_state stays "ungated", eligible
  # untouched) when plan_mode=off, so this feature costs nothing on the
  # default path and census output stays byte-identical.
  plan_state="ungated"
  if [ "$plan_mode" != "off" ]; then
    case ",$labels," in
      *",plan-approved,"*) plan_state="gated-approved" ;;
      *",plan-review,"*) plan_state="awaiting-owner" ;;
      *)
        gated=0
        if [ "$plan_mode" = "always" ]; then
          gated=1
        else
          case ",$labels," in *",plan-first,"*) gated=1 ;; esac
        fi
        [ "$gated" -eq 1 ] && plan_state="needs-plan"
        ;;
    esac
    if [ "$plan_state" = "awaiting-owner" ]; then
      eligible=0
      plan_wait_lines+="plan_wait=$num"$'\n'
    fi
  fi

  # fallback_ready: first otherwise-eligible candidate in (priority, number)
  # order, IGNORING the blocking-graph gate — used only if the gate leaves
  # advance_ready="none".
  if [ "$eligible" -eq 1 ] && [ "$fallback_ready" = "none" ]; then
    fallback_ready="$num"
    fallback_plan_state="$plan_state"
  fi
  if [ "$eligible" -eq 1 ] && [ "$advance_ready" = "none" ]; then
    # Fetch this candidate's body only now — we're actually considering it.
    body=$(gh issue view "$num" -R "$repo" --json body --jq '.body // ""' 2>/dev/null) || true
    parse_json=""
    if [ -n "$body" ]; then
      parse_json=$(printf '%s' "$body" | bash "$script_dir/cockpit.sh" --parse-blocking 2>/dev/null) || true
    fi
    first_open_blocker=""
    if [ -n "$parse_json" ]; then
      while IFS= read -r bnum; do
        [ -n "$bnum" ] || continue
        if is_open_issue "$bnum"; then
          first_open_blocker="$bnum"
          break
        fi
      done <<< "$(get_blocked_by "$parse_json")"
    fi
    if [ -n "$first_open_blocker" ]; then
      blocked_lines+="blocked=$num by=$first_open_blocker"$'\n'
    else
      advance_ready="$num"
      advance_plan_state="$plan_state"
    fi
  fi

  # in_flight: a branch exists for this issue but no open PR carries it yet
  # (branch may be printed with a "origin/" remote prefix above; strip it —
  # or match it as a "/"-suffix — before comparing against headRefName, which
  # is always the bare branch name).
  if [ "$branch" != "none" ]; then
    has_open_pr=0
    while IFS= read -r b; do
      [ -z "$b" ] && continue
      case "$branch" in
        "$b"|*"/$b") has_open_pr=1; break ;;
      esac
    done <<< "$open_pr_branches"
    if [ "$has_open_pr" -eq 1 ]; then
      : # already has an open PR -- never in_flight, never stalled
    else
      in_flight+="in_flight=$num"$'\n'
      # --- stall detection (issue #98): only for genuinely in_flight issues,
      # and only when at least one event exists (see the conservative
      # false-positive rule in the header comment above) ---
      age_min="$(last_event_age_minutes "$num")"
      if [ -n "$age_min" ] && [ "$age_min" -ge "$stall_minutes" ]; then
        stalled_lines+="stalled=$num age_min=$age_min"$'\n'
      fi
    fi
  fi
done <<< "$planned"

# Cycle / all-blocked fallback (issue #97): only trips when at least one
# candidate was otherwise eligible but every one of them got blocked.
if [ "$advance_ready" = "none" ] && [ "$fallback_ready" != "none" ]; then
  echo "census: all planned candidates blocked (possible cycle); falling back to lowest-number #$fallback_ready" >&2
  advance_ready="$fallback_ready"
  advance_plan_state="$fallback_plan_state"
fi

echo "planned_issues=$planned_count"
# milestone=/milestone_open= (issue #174): only when a milestone is actually
# in scope — see the position rationale in MILESTONE SCOPING above. Absent
# entirely on the fallback path, preserving byte-identical output for repos
# that don't use milestones. milestone_open reuses $planned_count directly:
# once a milestone is in scope, planned_count IS that milestone's qualifying
# count (the filter above already scoped it), so no separate count is kept.
if [ -n "$current_milestone" ]; then
  echo "milestone=$current_milestone"
  echo "milestone_open=$planned_count"
fi
[ -n "$detail" ] && printf '%s' "$detail"
[ -n "$in_flight" ] && printf '%s' "$in_flight"
[ -n "$stalled_lines" ] && printf '%s' "$stalled_lines"
[ -n "$blocked_lines" ] && printf '%s' "$blocked_lines"
[ -n "$plan_wait_lines" ] && printf '%s' "$plan_wait_lines"
# advance_mode (issue #100): only emitted when the plan gate is on AND a
# candidate was actually chosen — a tick reading this defaults to "implement"
# when the line is absent (plan_mode=off, or advance_ready=none), which is
# exactly today's ungated single-pass behavior.
if [ "$plan_mode" != "off" ] && [ "$advance_ready" != "none" ]; then
  case "$advance_plan_state" in
    needs-plan) echo "advance_mode=plan" ;;
    gated-approved) echo "advance_mode=implement-gated" ;;
    *) echo "advance_mode=implement" ;;
  esac
fi
echo "advance_ready=$advance_ready"

# Desired cadence per the loop policy: FAST only when the loop can ACT now.
if [ "$feedback_prs" -ge 1 ] || [ "$comment_fix_prs" -ge 1 ] || [ "$ci_fix_prs" -ge 1 ] || [ "$rebase_prs" -ge 1 ] || { [ "$open_prs" -eq 0 ] && [ "$planned_count" -ge 1 ]; }; then
  echo 'cadence=FAST cron=* * * * *'
elif [ "$open_prs" -ge 1 ]; then
  echo 'cadence=WATCH cron=*/5 * * * *'
else
  echo 'cadence=IDLE cron=*/15 * * * *'
fi
