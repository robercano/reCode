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
#   advance_ready=<n|none>      lowest-numbered planned issue with no branch,
#                               only when open_prs=0 (the ADVANCE precondition)
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

open_prs=$(gh pr list -R "$repo" --state open --base "$base" --json number --jq 'length')
echo "open_prs=$open_prs"

# Head branch names of every open PR (against base) — used below to tell
# in_flight (branch exists, no PR yet) apart from already-at-PR-stage.
open_pr_branches=$(gh pr list -R "$repo" --state open --base "$base" --json headRefName --jq '.[].headRefName')

feedback_prs=$(bash "$script_dir/pr-feedback.sh" "$repo" | grep -c . || true)
echo "feedback_prs=$feedback_prs"

# Open `planned` issues carrying any of the adapter's module labels, ascending.
planned=$(gh issue list -R "$repo" --state open --label planned --json number,title,labels \
  --jq '.[] | [.number, ([.labels[].name]|join(",")), .title] | @tsv' | sort -n)

planned_count=0
advance_ready="none"
detail=""
in_flight=""
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
  if [ "$advance_ready" = "none" ] && [ "$branch" = "none" ] && [ "$open_prs" -eq 0 ]; then
    advance_ready="$num"
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

echo "planned_issues=$planned_count"
[ -n "$detail" ] && printf '%s' "$detail"
[ -n "$in_flight" ] && printf '%s' "$in_flight"
echo "advance_ready=$advance_ready"

# Desired cadence per the loop policy: FAST only when the loop can ACT now.
if [ "$feedback_prs" -ge 1 ] || { [ "$open_prs" -eq 0 ] && [ "$planned_count" -ge 1 ]; }; then
  echo 'cadence=FAST cron=* * * * *'
elif [ "$open_prs" -ge 1 ]; then
  echo 'cadence=WATCH cron=*/5 * * * *'
else
  echo 'cadence=IDLE cron=*/15 * * * *'
fi
