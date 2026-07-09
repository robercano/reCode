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
# `issue=N ts=<UTC ISO-8601>`.
#
# INVARIANT (corrected — see issue #81 re-review): a lock for issue N is
# held to cover exactly the narrow window between "this tick just emitted
# action=advance issue=N" and "an orchestrator has pushed feat/issue-N-*".
# While that window is open, census reports N as advance_ready (no branch
# yet) — the SAME signal that means "N still needs advancing" — so the two
# cannot be told apart by advance_ready alone. The lock is released as soon
# as EITHER:
#   (a) an open PR now exists for N (census no longer reports N as
#       advance_ready — feedback/merge scripts own N from here), OR
#   (b) a feat/issue-N-* branch now exists with no open PR yet (census
#       reports N as in_flight) — the orchestrator got at least as far as
#       pushing a branch, so the pre-branch race this lock guards against is
#       over; a second tick would refuse to re-advance N anyway once it's
#       in_flight, OR
#   (c) the lock is older than LOCK_TTL_SECONDS and N is STILL
#       advance_ready with no branch — this can only mean the spawn that
#       should have created the branch crashed (or never started) before
#       reaching (b), so a lock stuck in this state is treated as a crashed
#       spawn and cleared to let a later tick re-advance N.
# This script self-heals: on every run it checks the held lock (if any)
# against the FRESH census output plus the TTL above and clears it whenever
# it no longer qualifies, so a crashed orchestrator never permanently wedges
# the issue. Written atomically (temp file + mv) to avoid a torn read, and
# the whole read-check-write critical section is additionally serialized
# with `flock` (a separate .claude/state/loop-advance.flock) so two ticks
# racing each other cannot both observe "no lock" and both emit
# `action=advance issue=N` (a TOCTOU double-spawn — atomic temp+mv alone only
# prevents a torn READ, not two processes interleaving read-then-write).
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

# ---------------------------------------------------------------------------
# Tick record (issue #85): append ONE record per firing to
# .claude/state/loop-ticks.jsonl, so the cockpit's "Loop health" panel can
# show the last tick, current cadence, verdict history, and detect a stalled
# loop. Mirrors log-event.sh's EXACT pattern: the JSON line is built with
# `node` (never hand-rolled string interpolation) so values are safely
# escaped, and the file is rotated to the last N lines via temp-file + atomic
# `mv` (crash-safe).
#
# CRITICAL INVARIANT: this must NEVER print to stdout and must NEVER change
# this script's exit status or verdict -- the verdict line printed at the end
# of this script MUST remain the LAST line of stdout (the daemon/tick parser
# reads the last line). Best-effort/never-break, exactly like log-event.sh:
# every step below is guarded so a failure here can never affect the tick.
#
# Log file: defaults to <root>/.claude/state/loop-ticks.jsonl. Override with
# CLAUDE_TICKS_FILE=<absolute path> (used by tests to point at a temp file
# instead of the real, gitignored state dir). Override the rotation cap with
# LOOP_TICKS_MAX_LINES (default 2000), matching log-event.sh's
# EVENTS_MAX_LINES.
write_tick_record() {
  local verdict="$1" cadence="$2"
  local ticks_file="${CLAUDE_TICKS_FILE:-$root/.claude/state/loop-ticks.jsonl}"
  local max_lines="${LOOP_TICKS_MAX_LINES:-2000}"
  local action="" issue="" pr=""
  case "$verdict" in
    "action=advance issue="*) action="advance"; issue="${verdict#action=advance issue=}" ;;
    "action=feedback pr="*) action="feedback"; pr="${verdict#action=feedback pr=}" ;;
    "action=none") action="none" ;;
    *)
      action="${verdict#action=}"
      action="${action%% *}"
      ;;
  esac

  mkdir -p "$(dirname "$ticks_file")" 2>/dev/null || return 0

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || ts=""

  CLAUDE_TICK_TS="$ts" \
  CLAUDE_TICK_VERDICT="$verdict" \
  CLAUDE_TICK_CADENCE="$cadence" \
  CLAUDE_TICK_ACTION="$action" \
  CLAUDE_TICK_ISSUE="$issue" \
  CLAUDE_TICK_PR="$pr" \
  node -e '
    const line = JSON.stringify({
      ts: process.env.CLAUDE_TICK_TS || "",
      verdict: process.env.CLAUDE_TICK_VERDICT || "",
      cadence: process.env.CLAUDE_TICK_CADENCE || "",
      action: process.env.CLAUDE_TICK_ACTION || "",
      issue: process.env.CLAUDE_TICK_ISSUE || "",
      pr: process.env.CLAUDE_TICK_PR || "",
    });
    process.stdout.write(line + "\n");
  ' >>"$ticks_file" 2>/dev/null || return 0

  # ---- rotation: cap to the last $max_lines lines, atomically -------------
  node -e '
    const fs = require("fs");
    const file = process.argv[1];
    const max = parseInt(process.argv[2], 10);
    const tmp = process.argv[3];
    try {
      if (!Number.isFinite(max) || max <= 0) process.exit(0);
      const text = fs.readFileSync(file, "utf8");
      const lines = text.split("\n");
      // drop a single trailing empty string from the final newline, if present
      if (lines.length && lines[lines.length - 1] === "") lines.pop();
      if (lines.length <= max) process.exit(0);
      const kept = lines.slice(lines.length - max);
      fs.writeFileSync(tmp, kept.join("\n") + "\n");
      fs.renameSync(tmp, file);
    } catch (e) {
      process.exit(0);
    }
  ' "$ticks_file" "$max_lines" "$ticks_file.tmp.$$" 2>/dev/null

  return 0
}

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
# Cadence (FAST/WATCH/IDLE), for the tick record (issue #85) -- census emits
# e.g. "cadence=FAST cron=* * * * *"; keep only the leading token.
cadence="$(printf '%s\n' "$census_out" | sed -n 's/^cadence=\([A-Za-z]*\).*/\1/p' | tail -1)"

# --- Parse pr-feedback.sh's TSV (num, branch, reviewer, changes_requested_at) --
# Lowest-numbered PR wins when several need feedback addressed.
feedback_pr="$(printf '%s\n' "$feedback_out" | awk -F'\t' 'NF>=1 && $1 ~ /^[0-9]+$/ {print $1}' | sort -n | head -1)"

# --- Spawn lock: read + self-heal against the FRESH census above -----------
# TTL rationale: this lock is written the instant a tick emits
# `action=advance issue=N`, before the orchestrator that will push
# `feat/issue-N-*` even exists yet. A real orchestrator reaches that push
# within at most a few minutes of being spawned. 15 minutes is comfortably
# above that, so a lock that is STILL "no branch, still advance_ready" past
# this TTL can only mean the spawn crashed (or was never launched) before
# creating a branch — self-heal by clearing it rather than wedging the issue
# forever (see INVARIANT (c) in the header comment above).
LOCK_TTL_SECONDS=900

state_dir="$root/.claude/state"
lock_file="$state_dir/loop-advance.lock"
flock_file="$state_dir/loop-advance.flock"
mkdir -p "$state_dir"

# Concurrent-tick guard (issue #81 re-review, TOCTOU): two overlapping ticks
# must not both observe "no lock held for N" and both emit
# `action=advance issue=N` — exactly the double-spawn bug #81 exists to kill.
# Atomic temp+mv (below) only prevents a torn READ of the lock file; it does
# not make "read lock -> self-heal -> decide -> write lock" atomic ACROSS two
# processes. Serialize that whole critical section with a real file lock so
# only one tick at a time can be inside it (released automatically when this
# script exits and fd 9 closes).
exec 9>"$flock_file"
flock -x 9

lock_issue=""
if [ -f "$lock_file" ]; then
  lock_issue="$(sed -n 's/^issue=\([0-9][0-9]*\).*/\1/p' "$lock_file" | head -1)"
fi

if [ -n "$lock_issue" ]; then
  still_qualifies=0
  reason=""
  if printf '%s\n' "$in_flight_issues" | grep -qx "$lock_issue"; then
    # (b): a branch now exists — the pre-branch window this lock guards is
    # closed (a second tick would refuse to advance N anyway once in_flight).
    reason="branch now exists (in_flight) — lock's purpose is served"
  elif [ "$lock_issue" = "$advance_ready" ]; then
    # Still no branch. Either the spawn just started (keep the lock) or it
    # crashed before ever pushing a branch (clear it) — (c): use the
    # recorded ts as a bounded TTL to tell the two apart.
    lock_ts="$(sed -n 's/^issue=[0-9][0-9]* ts=\(.*\)$/\1/p' "$lock_file" | head -1)"
    lock_epoch="$(date -u -d "$lock_ts" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    age=$(( now_epoch - lock_epoch ))
    if [ "$lock_epoch" -eq 0 ] || [ "$age" -gt "$LOCK_TTL_SECONDS" ]; then
      reason="lock is older than ${LOCK_TTL_SECONDS}s with still no branch — treating as a crashed spawn"
    else
      still_qualifies=1
    fi
  else
    # (a): no longer advance_ready and no branch -> an open PR must exist now.
    reason="no longer advance_ready/in_flight — open PR exists or branch is gone"
  fi
  if [ "$still_qualifies" -eq 0 ]; then
    echo "# lock self-heal: cleared stale spawn lock for issue=$lock_issue ($reason)"
    rm -f "$lock_file"
    lock_issue=""
  fi
fi

# --- Decide the verdict -----------------------------------------------------
# The verdict string is captured into a variable (rather than echoed inline)
# so it can ALSO be persisted to the tick log below without disturbing the
# invariant that the verdict line is the LAST line of stdout.
verdict=""
if [ -n "$feedback_pr" ]; then
  verdict="action=feedback pr=$feedback_pr"
elif [ "$advance_ready" != "none" ] && [ -n "$advance_ready" ]; then
  if printf '%s\n' "$in_flight_issues" | grep -qx "$advance_ready"; then
    echo "# advance refused: issue=$advance_ready is in_flight (a feat/issue-$advance_ready-* branch already exists with no open PR)"
    verdict="action=none"
  elif [ "$lock_issue" = "$advance_ready" ]; then
    echo "# advance refused: spawn lock already held for issue=$advance_ready ($(cat "$lock_file" 2>/dev/null))"
    verdict="action=none"
  else
    tmp="$(mktemp "$state_dir/.loop-advance.lock.XXXXXX")"
    printf 'issue=%s ts=%s\n' "$advance_ready" "$(date -u +%FT%TZ)" > "$tmp"
    mv -f "$tmp" "$lock_file"
    verdict="action=advance issue=$advance_ready"
  fi
else
  verdict="action=none"
fi

echo "$verdict"

# Persist the tick record (issue #85) AFTER the verdict has been echoed, and
# writing to the FILE ONLY -- never stdout -- so the verdict line above stays
# the last line of this script's stdout. Best-effort: never allowed to affect
# the exit status set below.
write_tick_record "$verdict" "$cadence" || true
