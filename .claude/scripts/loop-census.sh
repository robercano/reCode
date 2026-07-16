#!/usr/bin/env bash
# loop-census.sh — one-shot STEP 0 census for the PR loop (base and self-hosted).
# Prints, as stable key=value telemetry, everything a tick needs to decide
# whether it can ACT — so the actionability check is a single pre-approvable
# command instead of a discipline the tick can silently skip:
#
#   open_prs=N                  open PRs against the adapter's base branch
#   feedback_prs=N              bot PRs with unaddressed CHANGES_REQUESTED (pr-feedback.sh)
#   planned_issues=N            open issues labelled `planned` AND one of the
#                               adapter's module:* labels, one detail line each:
#     issue=<n> branch=<feat/issue-n-* or none> title=<title>
#   in_flight=<n>                one line PER planned issue that has a
#                               feat/issue-n-* branch (local or remote) but NO
#                               open PR for it yet — i.e. work has started but
#                               hasn't reached PR stage. A tick uses this to
#                               avoid double-spawning an orchestrator for an
#                               issue that already has a worktree in progress.
#   blocked=<n> by=<N>          one line per candidate that would otherwise be
#                               advance_ready but is skipped because its body
#                               says "Blocked by #N" and issue N is still OPEN
#                               (issue #97). Only the first open blocker per
#                               candidate is reported — one is enough to
#                               explain the skip; a candidate may have more.
#   advance_ready=<n|none>      lowest-numbered planned issue with no branch,
#                               only when open_prs=0 (the ADVANCE precondition)
#                               AND not blocked by an open "Blocked by #N" edge
#   cadence=FAST|WATCH|IDLE cron=<expr>   desired cadence per the loop policy
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

feedback_prs=$(bash "$script_dir/pr-feedback.sh" "$repo" | grep -c . || true)
echo "feedback_prs=$feedback_prs"

# Open `planned` issues carrying any of the adapter's module labels, ascending.
planned=$(gh issue list -R "$repo" --state open --label planned --json number,title,labels \
  --jq '.[] | [.number, ([.labels[].name]|join(",")), .title] | @tsv' | sort -n)

planned_count=0
advance_ready="none"
fallback_ready="none"
detail=""
in_flight=""
blocked_lines=""
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
  # fallback_ready: lowest-numbered otherwise-eligible candidate, IGNORING the
  # blocking-graph gate — used only if the gate leaves advance_ready="none".
  if [ "$eligible" -eq 1 ] && [ "$fallback_ready" = "none" ]; then
    fallback_ready="$num"
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
    [ "$has_open_pr" -eq 1 ] || in_flight+="in_flight=$num"$'\n'
  fi
done <<< "$planned"

# Cycle / all-blocked fallback (issue #97): only trips when at least one
# candidate was otherwise eligible but every one of them got blocked.
if [ "$advance_ready" = "none" ] && [ "$fallback_ready" != "none" ]; then
  echo "census: all planned candidates blocked (possible cycle); falling back to lowest-number #$fallback_ready" >&2
  advance_ready="$fallback_ready"
fi

echo "planned_issues=$planned_count"
[ -n "$detail" ] && printf '%s' "$detail"
[ -n "$in_flight" ] && printf '%s' "$in_flight"
[ -n "$blocked_lines" ] && printf '%s' "$blocked_lines"
echo "advance_ready=$advance_ready"

# Desired cadence per the loop policy: FAST only when the loop can ACT now.
if [ "$feedback_prs" -ge 1 ] || { [ "$open_prs" -eq 0 ] && [ "$planned_count" -ge 1 ]; }; then
  echo 'cadence=FAST cron=* * * * *'
elif [ "$open_prs" -ge 1 ]; then
  echo 'cadence=WATCH cron=*/5 * * * *'
else
  echo 'cadence=IDLE cron=*/15 * * * *'
fi
