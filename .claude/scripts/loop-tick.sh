#!/usr/bin/env bash
# loop-tick.sh — one-shot orchestration tick for the autonomous PR loop.
#
# Runs the loop's four step scripts, IN ORDER, with their FULL output
# preserved (never swallowed or `tail -1`'d), then emits exactly one
# machine-readable verdict line as the LAST line of output:
#   action=none
#   action=advance issue=N
#   action=feedback pr=N
#
# WHY THIS EXISTS (issue #81): the tick used to be a multi-step PROMPT
# (.claude/commands/pr-loop.md) that a model re-derived, from scratch, every
# firing. Repetition is exactly where smaller/cheaper models drift — a
# Haiku-driven tick has been observed to stop invoking the step scripts and
# fabricate their output, and to double-spawn an orchestrator for the same
# issue because it misread an in-flight worktree as hung. Collapsing the
# whole tick to ONE script plus one conditional spawn (of the ADVANCE/FEEDBACK
# work itself) makes the protocol immune to that drift: the verdict line is
# computed by shell/node logic, not recalled by the model from a prompt.
#
# This script does NOT reimplement census, polling, merge, or feedback-detection
# logic — it calls the existing sibling scripts and only adds the verdict
# arithmetic + the spawn lock (see .claude/state/loop-advance.lock below).
#
# Precedence: unaddressed CHANGES_REQUESTED feedback (pr-feedback.sh) always
# wins over ADVANCE — a human is waiting on a reply. When multiple PRs need
# feedback addressed, the lowest-numbered PR is picked. ADVANCE additionally
# requires: census says advance_ready=N (already means zero open PRs + a
# planned+module issue + no existing branch), N is not census's in_flight=N
# (a feat/issue-N-* branch with no open PR — someone/something is already
# mid-flight on it), and the spawn lock (below) is not already held for N.
#
# Spawn lock: .claude/state/loop-advance.lock (root-relative; .claude/state/
# is already gitignored). Written the moment this script emits
# `action=advance issue=N`, so a SECOND tick — fired before the first
# implementer has even pushed a branch — is refused by this script's own
# logic rather than by model discipline. Format: one line,
# `issue=N ts=<UTC ISO-8601>`. INVARIANT: the lock for issue N is considered
# released once EITHER (a) an open PR now exists for N, or (b) no
# feat/issue-N-* branch exists at all — i.e. census no longer reports N as
# advance_ready or in_flight. This script self-heals: on every run it checks
# the held lock (if any) against the FRESH census output and clears it if it
# no longer qualifies, so a stale lock (e.g. left behind by a crashed
# orchestrator) never permanently blocks the issue. Written atomically
# (temp file + mv) to avoid a torn read from a concurrent tick.
#
# Repo derived from the git remote; override with $1. Bot login via
# $BOT_LOGIN (passed through to the step scripts). Honors $GATES_FILE exactly
# like the sibling scripts (loop-census.sh reads it directly; the others fall
# back to the default adapter).
#
# Invoke as `bash .claude/scripts/loop-tick.sh` (pre-approve that exact
# command). Safe to run: this script itself only reads and computes a
# verdict + lock file — its only SIDE EFFECTS are the ones already documented
# on the step scripts it calls (notify-poll.sh advances its cursor;
# merge-ready.sh merges owner-approved, CI-green PRs and fast-forwards a
# clean local checkout on main). It never itself opens a PR, merges, or
# spawns an agent — it only tells the caller which single action to take.
set -uo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root = consumer project.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/resolve-roots.sh"
# Route EVERY gh call (ours and the step scripts') through the bot identity.
gh() { bash "$script_dir/bot-gh.sh" "$@"; }
repo="${1:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"

echo "=== 1/4 loop-census.sh ==="
census_out="$(bash "$script_dir/loop-census.sh" "$repo")"
printf '%s\n' "$census_out"

echo "=== 2/4 notify-poll.sh ==="
bash "$script_dir/notify-poll.sh" "$repo"

echo "=== 3/4 merge-ready.sh ==="
bash "$script_dir/merge-ready.sh" "$repo"

echo "=== 4/4 pr-feedback.sh ==="
feedback_out="$(bash "$script_dir/pr-feedback.sh" "$repo")"
printf '%s\n' "$feedback_out"

echo "=== verdict ==="

# --- Parse census telemetry needed for the verdict -------------------------
advance_ready="$(printf '%s\n' "$census_out" | sed -n 's/^advance_ready=//p' | tail -1)"
advance_ready="${advance_ready:-none}"
in_flight_issues="$(printf '%s\n' "$census_out" | sed -n 's/^in_flight=//p')"

# --- Parse pr-feedback.sh's TSV (num, branch, reviewer, changes_requested_at) --
# Lowest-numbered PR wins when several need feedback addressed.
feedback_pr="$(printf '%s\n' "$feedback_out" | awk -F'\t' 'NF>=1 && $1 ~ /^[0-9]+$/ {print $1}' | sort -n | head -1)"

# --- Spawn lock: read + self-heal against the FRESH census above -----------
state_dir="$root/.claude/state"
lock_file="$state_dir/loop-advance.lock"
mkdir -p "$state_dir"

lock_issue=""
if [ -f "$lock_file" ]; then
  lock_issue="$(sed -n 's/^issue=\([0-9][0-9]*\).*/\1/p' "$lock_file" | head -1)"
fi

if [ -n "$lock_issue" ]; then
  still_qualifies=0
  [ "$lock_issue" = "$advance_ready" ] && still_qualifies=1
  printf '%s\n' "$in_flight_issues" | grep -qx "$lock_issue" && still_qualifies=1
  if [ "$still_qualifies" -eq 0 ]; then
    echo "# lock self-heal: cleared stale spawn lock for issue=$lock_issue (no longer advance_ready/in_flight — open PR exists or branch is gone)"
    rm -f "$lock_file"
    lock_issue=""
  fi
fi

# --- Decide the verdict -----------------------------------------------------
if [ -n "$feedback_pr" ]; then
  echo "action=feedback pr=$feedback_pr"
elif [ "$advance_ready" != "none" ] && [ -n "$advance_ready" ]; then
  if printf '%s\n' "$in_flight_issues" | grep -qx "$advance_ready"; then
    echo "# advance refused: issue=$advance_ready is in_flight (a feat/issue-$advance_ready-* branch already exists with no open PR)"
    echo "action=none"
  elif [ "$lock_issue" = "$advance_ready" ]; then
    echo "# advance refused: spawn lock already held for issue=$advance_ready ($(cat "$lock_file" 2>/dev/null))"
    echo "action=none"
  else
    tmp="$(mktemp "$state_dir/.loop-advance.lock.XXXXXX")"
    printf 'issue=%s ts=%s\n' "$advance_ready" "$(date -u +%FT%TZ)" > "$tmp"
    mv -f "$tmp" "$lock_file"
    echo "action=advance issue=$advance_ready"
  fi
else
  echo "action=none"
fi
