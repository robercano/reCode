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
#   planned_issues=N            open issues labelled `planned` AND one of the
#                               adapter's module:* labels, one detail line each:
#     issue=<n> branch=<feat/issue-n-* or none> title=<title>
#   in_flight=<n>                one line PER planned issue that has a
#                               feat/issue-n-* branch (local or remote) but NO
#                               open PR for it yet — i.e. work has started but
#                               hasn't reached PR stage. A tick uses this to
#                               avoid double-spawning an orchestrator for an
#                               issue that already has a worktree in progress.
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
#   advance_ready=<n|none>      lowest-numbered planned issue with no branch,
#                               only when open_prs=0 (the ADVANCE precondition)
#                               AND not blocked by an open "Blocked by #N" edge
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
set -euo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
# Route EVERY gh call through the bot identity (see bot-gh.sh).
gh() { bash "$script_dir/bot-gh.sh" "$@"; }
repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

gates_rel="${GATES_FILE:-.claude/gates.json}"
case "$gates_rel" in /*) gates="$gates_rel" ;; *) gates="$root/$gates_rel" ;; esac

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

# Open `planned` issues carrying any of the adapter's module labels, ascending.
planned=$(gh issue list -R "$repo" --state open --label planned --json number,title,labels \
  --jq '.[] | [.number, ([.labels[].name]|join(",")), .title] | @tsv' | sort -n)

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
while IFS=$'\t' read -r num labels title; do
  [ -z "${num:-}" ] && continue
  hit=0
  while IFS= read -r ml; do
    case ",$labels," in *",$ml,"*) hit=1; break;; esac
  done <<< "$module_labels"
  [ "$hit" -eq 1 ] || continue
  planned_count=$((planned_count + 1))
  # Existing feat/issue-<n>-* branch (local or remote) means it's already in flight.
  # NOTE: `| head -1` can make `git` see SIGPIPE (exit 141) if head closes the
  # pipe before git finishes writing; under `set -euo pipefail` that would abort
  # this whole script. `|| true` on the assignment absorbs that non-fatal
  # pipeline failure — the captured output (head's one line) is unaffected.
  branch=$(git -C "$root" branch -a --list "*feat/issue-$num-*" | head -1 | sed 's/^[* ]*//;s|^remotes/||') || true
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

  # fallback_ready: lowest-numbered otherwise-eligible candidate, IGNORING the
  # blocking-graph gate — used only if the gate leaves advance_ready="none".
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
if [ "$feedback_prs" -ge 1 ] || [ "$ci_fix_prs" -ge 1 ] || { [ "$open_prs" -eq 0 ] && [ "$planned_count" -ge 1 ]; }; then
  echo 'cadence=FAST cron=* * * * *'
elif [ "$open_prs" -ge 1 ]; then
  echo 'cadence=WATCH cron=*/5 * * * *'
else
  echo 'cadence=IDLE cron=*/15 * * * *'
fi
