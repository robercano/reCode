#!/usr/bin/env bash
# loop-tick.sh — one-shot orchestration tick for the autonomous PR loop.
#
# Runs the loop's seven step scripts, IN ORDER, with their FULL output
# preserved (never swallowed or `tail -1`'d), then emits exactly one
# machine-readable verdict line as the LAST line of output:
#   action=none
#   action=advance issue=N
#   action=feedback pr=N
#   action=comment-fix pr=N   (issue #96 part 2 -- see PRECEDENCE below)
#   action=ci-fix pr=N
#   action=rebase pr=N   (issue #96 part 3 -- see PRECEDENCE below)
#   action=resume issue=N branch=<name>   (issue #98 -- see STEP 0.5 below)
#
# WHY THIS EXISTS (issue #81): the tick used to be a multi-step PROMPT
# (.claude/commands/pr-loop.md) that a model re-derived, from scratch, every
# firing. Repetition is exactly where smaller/cheaper models drift — a
# Haiku-driven tick has been observed to stop invoking the step scripts and
# fabricate their output, and to double-spawn an orchestrator for the same
# issue because it misread an in-flight worktree as hung. Collapsing the
# whole tick to ONE script plus one conditional spawn (of the ADVANCE/FEEDBACK/
# CI-FIX work itself) makes the protocol immune to that drift: the verdict
# line is computed by shell/node logic, not recalled by the model from a
# prompt.
#
# This script does NOT reimplement census, polling, merge, feedback-detection,
# or CI-fix-detection logic — it calls the existing sibling scripts and only
# adds the verdict arithmetic + the spawn lock (see
# .claude/state/loop-advance.lock below).
#
# Precedence (issue #96): feedback > comment-fix > ci-fix > rebase > advance >
# resume.
#   - unaddressed CHANGES_REQUESTED feedback (pr-feedback.sh) always wins over
#     everything else — a human is waiting on a reply. When multiple PRs need
#     feedback addressed, the lowest-numbered PR is picked.
#   - COMMENT-FIX (pr-comment-fix.sh, issue #96 part 2) wins over CI-FIX,
#     REBASE, and ADVANCE, but never over feedback: a PR that is BOTH a
#     feedback candidate AND has an unresolved qualifying review-comment
#     thread is handled as feedback, never comment-fix (pr-comment-fix.sh
#     itself already excludes feedback candidates from its own output, so
#     this precedence is enforced twice — belt and suspenders). When multiple
#     PRs need a comment fix, the lowest-numbered PR is picked, same tie-break
#     as feedback.
#   - CI-FIX (pr-ci-fix.sh) wins over REBASE and ADVANCE, but never over
#     feedback or comment-fix: a PR that is BOTH a comment-fix candidate AND
#     has failing CI is handled as comment-fix first (the reopened review
#     conversation is addressed before chasing a possibly-unrelated CI
#     failure). pr-ci-fix.sh does NOT itself exclude comment-fix candidates
#     (the two conditions are independent signals on the SAME PR, unlike
#     feedback's stronger "human is waiting" precedence) — this ordering is
#     enforced solely at the verdict-decision level below. When multiple PRs
#     need a CI fix, the lowest-numbered PR is picked, same tie-break as
#     feedback.
#   - REBASE (pr-rebase.sh, issue #96 part 3) wins over ADVANCE, but never
#     over feedback, comment-fix, or ci-fix: a PR that went CONFLICTING
#     against base (typically because a sibling PR merged first) is the
#     LOWEST of the four PR-event reactions — a merge conflict alone is not
#     proof that something is WRONG with this PR's own change, unlike
#     unaddressed feedback, an unresolved review thread, or red CI, so it only
#     gets attention once none of those three apply. pr-rebase.sh itself
#     already excludes feedback/comment-fix/ci-fix candidates from its own
#     output (belt and suspenders, mirroring the other two siblings). When
#     multiple PRs need a rebase, the lowest-numbered PR is picked, same
#     tie-break as feedback.
#   - ADVANCE additionally requires: census says advance_ready=N (already
#     means zero open PRs + a planned+module issue + no existing branch), N is
#     not census's in_flight=N (a feat/issue-N-* branch with no open PR —
#     someone/something is already mid-flight on it), and the spawn lock
#     (below) is not already held for N.
#   - RESUME (issue #98, see STEP 0.5 below) is lowest precedence: it only
#     fires when neither FEEDBACK, COMMENT-FIX, CI-FIX, REBASE, nor a fresh
#     ADVANCE claimed the tick (advance_ready=none), and picks the
#     lowest-numbered in_flight issue that census's stall clock or debris
#     classifier flags as stuck.
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

# needs_human_flag/needs_human_clear (issue #99) — the ONE shared label+notify
# seam every block-on-owner point below routes through, instead of hand-rolled
# `gh label create` + `gh issue/pr edit --add-label` + a raw comment. Sourced
# AFTER the `gh` wrapper above so both functions call the bot identity.
# shellcheck source=needs-human.sh
if [ -f "$script_dir/needs-human.sh" ]; then . "$script_dir/needs-human.sh"; fi

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
  local verdict="$1" cadence="$2" reason="${3:-}"
  local ticks_file="${CLAUDE_TICKS_FILE:-$root/.claude/state/loop-ticks.jsonl}"
  local max_lines="${LOOP_TICKS_MAX_LINES:-2000}"
  local action="" issue="" pr=""
  case "$verdict" in
    "action=advance issue="*) action="advance"; issue="${verdict#action=advance issue=}" ;;
    "action=feedback pr="*) action="feedback"; pr="${verdict#action=feedback pr=}" ;;
    "action=comment-fix pr="*) action="comment-fix"; pr="${verdict#action=comment-fix pr=}" ;;
    "action=ci-fix pr="*) action="ci-fix"; pr="${verdict#action=ci-fix pr=}" ;;
    "action=rebase pr="*) action="rebase"; pr="${verdict#action=rebase pr=}" ;;
    "action=resume issue="*)
      action="resume"
      issue="${verdict#action=resume issue=}"
      issue="${issue%% *}"
      ;;
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
  CLAUDE_TICK_REASON="$reason" \
  node -e '
    const line = JSON.stringify({
      ts: process.env.CLAUDE_TICK_TS || "",
      verdict: process.env.CLAUDE_TICK_VERDICT || "",
      cadence: process.env.CLAUDE_TICK_CADENCE || "",
      action: process.env.CLAUDE_TICK_ACTION || "",
      issue: process.env.CLAUDE_TICK_ISSUE || "",
      pr: process.env.CLAUDE_TICK_PR || "",
      // Spend-ceiling diagnostic (issue #95): empty unless a ceiling forced
      // the verdict to action=none -- one of
      // expired|daily-ceiling|attempt-budget. Surfaced by cockpit.sh.
      reason: process.env.CLAUDE_TICK_REASON || "",
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

echo "=== 1/7 loop-census.sh ==="
census_out="$(bash "$script_dir/loop-census.sh" "$repo")"
printf '%s\n' "$census_out"

echo "=== 2/7 notify-poll.sh ==="
bash "$script_dir/notify-poll.sh" "$repo"

echo "=== 3/7 merge-ready.sh ==="
bash "$script_dir/merge-ready.sh" "$repo"

echo "=== 4/7 pr-feedback.sh ==="
feedback_out="$(bash "$script_dir/pr-feedback.sh" "$repo")"
printf '%s\n' "$feedback_out"

echo "=== 5/7 pr-comment-fix.sh ==="
commentfix_out="$(bash "$script_dir/pr-comment-fix.sh" "$repo")"
printf '%s\n' "$commentfix_out"

echo "=== 6/7 pr-ci-fix.sh ==="
cifix_out="$(bash "$script_dir/pr-ci-fix.sh" "$repo")"
printf '%s\n' "$cifix_out"

echo "=== 7/7 pr-rebase.sh ==="
rebase_out="$(bash "$script_dir/pr-rebase.sh" "$repo")"
printf '%s\n' "$rebase_out"

echo "=== verdict ==="

# --- Parse census telemetry needed for the verdict -------------------------
advance_ready="$(printf '%s\n' "$census_out" | sed -n 's/^advance_ready=//p' | tail -1)"
advance_ready="${advance_ready:-none}"
# Plan-gate mode (issue #100): census emits advance_mode=plan|implement-gated|
# implement alongside a non-"none" advance_ready ONLY when plan.gate != "off"
# — absent (default "implement") reproduces today's ungated single-pass
# behavior. Only meaningful for an actual action=advance verdict below; see
# where it's echoed into this tick's own stdout, scoped to that branch only.
advance_mode="$(printf '%s\n' "$census_out" | sed -n 's/^advance_mode=//p' | tail -1)"
advance_mode="${advance_mode:-implement}"
in_flight_issues="$(printf '%s\n' "$census_out" | sed -n 's/^in_flight=//p')"
# Cadence (FAST/WATCH/IDLE), for the tick record (issue #85) -- census emits
# e.g. "cadence=FAST cron=* * * * *"; keep only the leading token.
cadence="$(printf '%s\n' "$census_out" | sed -n 's/^cadence=\([A-Za-z]*\).*/\1/p' | tail -1)"

# --- Parse pr-feedback.sh's TSV (num, branch, reviewer, changes_requested_at) --
# Lowest-numbered PR wins when several need feedback addressed.
feedback_line="$(printf '%s\n' "$feedback_out" | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1"\t"$2}' | sort -t $'\t' -k1,1n | head -1)"
feedback_pr="$(printf '%s\n' "$feedback_line" | awk -F'\t' '{print $1}')"
feedback_branch="$(printf '%s\n' "$feedback_line" | awk -F'\t' '{print $2}')"
# The issue this PR's branch was cut from (feat/issue-N-*), used to key the
# per-issue attempt budget (issue #95) so advance-phase and feedback-phase
# dispatches for the SAME issue share one counter. Falls back to the PR
# number itself when the branch doesn't follow that convention.
feedback_issue="$(printf '%s\n' "$feedback_branch" | sed -n 's#.*feat/issue-\([0-9][0-9]*\)-.*#\1#p')"

# --- Parse pr-comment-fix.sh's TSV (num, branch, thread_ids:attempts_csv,
# head_sha) --- Lowest-numbered PR wins when several need a comment fix, same
# tie-break as feedback above. pr-comment-fix.sh already excludes feedback
# candidates from its own output (precedence, issue #96 part 2), so no
# additional filtering is needed here beyond the verdict decision below.
commentfix_line="$(printf '%s\n' "$commentfix_out" | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1"\t"$2}' | sort -t $'\t' -k1,1n | head -1)"
commentfix_pr="$(printf '%s\n' "$commentfix_line" | awk -F'\t' '{print $1}')"
commentfix_branch="$(printf '%s\n' "$commentfix_line" | awk -F'\t' '{print $2}')"
# Same #95 per-issue attempt budget key derivation as feedback_issue above —
# comment-fix dispatches for issue N share the SAME counter as
# advance/feedback/ci-fix dispatches for issue N (do NOT invent a new counter
# file for THIS budget; the separate per-THREAD retry budget is tracked
# entirely inside pr-comment-fix.sh itself via the claude-comment-addressed
# marker's embedded attempt number — see that script's header doc).
commentfix_issue="$(printf '%s\n' "$commentfix_branch" | sed -n 's#.*feat/issue-\([0-9][0-9]*\)-.*#\1#p')"

# --- Parse pr-ci-fix.sh's TSV (num, branch, failing_checks_csv, head_sha) ---
# Lowest-numbered PR wins when several need a CI fix, same tie-break as
# feedback above. pr-ci-fix.sh already excludes feedback AND comment-fix
# candidates from its own output (precedence, issue #96), so no additional
# filtering is needed here beyond the verdict decision below.
cifix_line="$(printf '%s\n' "$cifix_out" | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1"\t"$2}' | sort -t $'\t' -k1,1n | head -1)"
cifix_pr="$(printf '%s\n' "$cifix_line" | awk -F'\t' '{print $1}')"
cifix_branch="$(printf '%s\n' "$cifix_line" | awk -F'\t' '{print $2}')"
# Same #95 per-issue attempt budget key derivation as feedback_issue above —
# ci-fix dispatches for issue N share the SAME counter as advance/feedback
# dispatches for issue N (do NOT invent a new counter file).
cifix_issue="$(printf '%s\n' "$cifix_branch" | sed -n 's#.*feat/issue-\([0-9][0-9]*\)-.*#\1#p')"

# --- Parse pr-rebase.sh's TSV (num, branch, head_sha, base_sha, attempt) ---
# Lowest-numbered PR wins when several need a rebase, same tie-break as
# feedback above. pr-rebase.sh already excludes feedback/comment-fix/ci-fix
# candidates from its own output (precedence, issue #96 part 3), so no
# additional filtering is needed here beyond the verdict decision below.
rebase_line="$(printf '%s\n' "$rebase_out" | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1"\t"$2}' | sort -t $'\t' -k1,1n | head -1)"
rebase_pr="$(printf '%s\n' "$rebase_line" | awk -F'\t' '{print $1}')"
rebase_branch="$(printf '%s\n' "$rebase_line" | awk -F'\t' '{print $2}')"
# Same #95 per-issue attempt budget key derivation as feedback_issue above —
# rebase dispatches for issue N share the SAME counter as advance/feedback/
# comment-fix/ci-fix dispatches for issue N (do NOT invent a new counter
# file for THIS budget; the separate per-BASE-COMMIT retry budget is tracked
# entirely inside pr-rebase.sh itself via the claude-rebase-attempted marker's
# embedded attempt number — see that script's header doc).
rebase_issue="$(printf '%s\n' "$rebase_branch" | sed -n 's#.*feat/issue-\([0-9][0-9]*\)-.*#\1#p')"

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

# ---------------------------------------------------------------------------
# STEP 0: spend-ceiling pre-flight (issue #95). Three independent, adapter-
# configurable ceilings (defaults documented in docs/TOKEN_BUDGET.md ->
# "Loop spend ceilings"):
#   budget.stop_after_days       self-disarm horizon (armed_at + Nd)
#   budget.per_issue_attempts    advance/feedback dispatch budget PER ISSUE
#   budget.daily_action_ceiling  dispatches (advance+feedback) per UTC day
# A breach sets ceiling_block (non-empty), which forces the verdict decided
# below to action=none WITHOUT the spawn-lock side effect, and ceiling_reason
# (persisted on the tick record for the cockpit): one of
# expired|daily-ceiling|attempt-budget. Every gh side effect below (notify /
# label / comment) is best-effort and ONCE-guarded via small state files
# under .claude/state/ -- a failure here can never break a tick, and normal
# ticks (no breach) never call gh at all.
# ---------------------------------------------------------------------------
gates_rel="${GATES_FILE:-.claude/gates.json}"
case "$gates_rel" in /*) gates_path="$gates_rel" ;; *) gates_path="$root/$gates_rel" ;; esac
budget_cfg="$(node -e '
  const fs = require("fs");
  let g = null;
  try { g = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { g = null; }
  const b = (g && g.budget) || {};
  const num = (v, d) => (Number.isFinite(v) && v > 0 ? v : d);
  console.log([num(b.stop_after_days, 7), num(b.per_issue_attempts, 5), num(b.daily_action_ceiling, 50)].join(" "));
' "$gates_path" 2>/dev/null)"
stop_after_days="$(printf '%s\n' "$budget_cfg" | awk '{print $1}')"
per_issue_attempts="$(printf '%s\n' "$budget_cfg" | awk '{print $2}')"
daily_action_ceiling="$(printf '%s\n' "$budget_cfg" | awk '{print $3}')"
case "$stop_after_days" in ''|*[!0-9.]*) stop_after_days=7 ;; esac
case "$per_issue_attempts" in ''|*[!0-9]*) per_issue_attempts=5 ;; esac
case "$daily_action_ceiling" in ''|*[!0-9]*) daily_action_ceiling=50 ;; esac

# File-or-refresh-ONE-issue helper, shared by the expiry and daily-ceiling
# notices below. $1 = existing tracked issue number (may be empty), $2 =
# title (used only when filing new), $3 = body. Prints the issue number that
# now tracks this notice (existing/refreshed, or freshly filed) -- empty on
# total gh failure (offline), which callers treat as "nothing to persist".
budget_notify_issue() {
  local existing="$1" title="$2" body="$3"
  if [ -n "$existing" ]; then
    local st
    st="$(gh issue view "$existing" --json state --jq .state 2>/dev/null || true)"
    if [ "$st" = "OPEN" ]; then
      gh issue comment "$existing" --body "$body" >/dev/null 2>&1 || true
      printf '%s' "$existing"
      return 0
    fi
  fi
  local out num
  out="$(gh issue create --title "$title" --label backlog --body "$body" 2>/dev/null || true)"
  num="$(printf '%s\n' "$out" | grep -oE '[0-9]+$' | tail -1)"
  printf '%s' "$num"
}

ceiling_block=""
ceiling_reason=""

# --- 1) stop-after self-disarm ----------------------------------------------
# .claude/state/loop-arming.json is normally written by arm-loop.sh at arm
# time (armed_at/expires_at/stop_after_days/notified_expired/notice_issue).
# Fallback: an already-armed loop from before this feature existed never had
# arm-loop.sh write one -- lazily create one starting NOW on first tick, so
# it still gets a ceiling instead of running forever unnoticed.
arming_file="$state_dir/loop-arming.json"
now_iso="$(date -u +%FT%TZ)"
if [ ! -f "$arming_file" ]; then
  tmp_arm="$(mktemp "$state_dir/.loop-arming.json.XXXXXX")"
  if CLAUDE_ARM_NOW="$now_iso" CLAUDE_ARM_DAYS="$stop_after_days" node -e '
    const fs = require("fs");
    const now = process.env.CLAUDE_ARM_NOW;
    const days = parseFloat(process.env.CLAUDE_ARM_DAYS) || 7;
    const expires = new Date(Date.parse(now) + days * 86400000).toISOString();
    fs.writeFileSync(process.argv[1], JSON.stringify({
      armed_at: now, expires_at: expires, stop_after_days: days,
      notified_expired: false, notice_issue: null,
    }, null, 2) + "\n");
  ' "$tmp_arm" 2>/dev/null; then
    mv -f "$tmp_arm" "$arming_file"
  else
    rm -f "$tmp_arm"
  fi
fi

expired=0
expires_at="" notified_expired="0" arming_notice_issue=""
if [ -f "$arming_file" ]; then
  arm_read="$(node -e '
    const fs = require("fs");
    try {
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      console.log((j.expires_at||"") + "\t" + (j.notified_expired?1:0) + "\t" + (j.notice_issue||""));
    } catch (e) { console.log("\t0\t"); }
  ' "$arming_file" 2>/dev/null || printf '\t0\t')"
  IFS=$'\t' read -r expires_at notified_expired arming_notice_issue <<<"$arm_read"
  case "$notified_expired" in ''|*[!01]*) notified_expired=0 ;; esac
  if [ -n "$expires_at" ]; then
    now_epoch="$(date -u +%s)"
    expires_epoch="$(date -u -d "$expires_at" +%s 2>/dev/null || echo 0)"
    if [ "$expires_epoch" -gt 0 ] && [ "$now_epoch" -gt "$expires_epoch" ]; then
      expired=1
    fi
  fi
fi

if [ "$expired" -eq 1 ]; then
  ceiling_block="1"; ceiling_reason="expired"
  echo "# pre-flight: loop disarmed (stop-after expired at $expires_at)"
  if [ "$notified_expired" != "1" ]; then
    body="The armed loop's stop-after horizon (armed_at + ${stop_after_days}d) expired at $expires_at. It stays disarmed -- no further advance/feedback dispatches -- until re-armed. Re-arm with \`/pr-loop\` or \`bash .claude/scripts/arm-loop.sh\`."
    new_issue="$(budget_notify_issue "$arming_notice_issue" "Loop disarmed: stop-after expired" "$body")"
    # needs-human (issue #99, deliberately NOT wired here): this ceiling
    # already files/refreshes its OWN tracking issue (above) as its signal,
    # and re-arming (the success point that clears it) lives in arm-loop.sh --
    # templated/managed machinery re-stamped by /orchestrator:setup, out of
    # this change's scope. Layering the needs-human label on top would need
    # a matching clear call there and would perturb loop-ceilings.test.sh's
    # precise gh-call-count assertions for comparatively little signal value
    # (the tracking issue IS the visible signal). See needs-human.sh + this
    # issue's PR notes for the fuller reasoning.
    tmp_arm="$(mktemp "$state_dir/.loop-arming.json.XXXXXX")"
    if CLAUDE_NEW_ISSUE="${new_issue:-}" node -e '
      const fs = require("fs");
      let j = {};
      try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) {}
      j.notified_expired = true;
      const ni = process.env.CLAUDE_NEW_ISSUE;
      if (ni) j.notice_issue = parseInt(ni, 10);
      fs.writeFileSync(process.argv[2], JSON.stringify(j, null, 2) + "\n");
    ' "$arming_file" "$tmp_arm" 2>/dev/null; then
      mv -f "$tmp_arm" "$arming_file"
    else
      rm -f "$tmp_arm"
    fi
  fi
fi

# --- 2) daily action ceiling -------------------------------------------------
# .claude/state/loop-daily-ceiling.json: {date,count,halted,issue_number}.
# count/halted reset automatically once `date` no longer matches today;
# issue_number persists ACROSS the reset so a re-breach on a later day
# refreshes the same tracking issue instead of filing a duplicate.
daily_file="$state_dir/loop-daily-ceiling.json"
# CLAUDE_TODAY (mirrors cockpit.sh's COCKPIT_NOW override pattern): lets tests
# pin "today" instead of relying on `date -u` at the exact instant this script
# runs -- without it there's a narrow UTC-midnight race between a test writing
# daily-ceiling fixture state and this script reading it moments later, where
# the two could disagree on the calendar date. Unset/empty in production (and
# in every real invocation) -> falls back to the real UTC date, unchanged.
today="${CLAUDE_TODAY:-$(date -u +%Y-%m-%d)}"
daily_read="$(node -e '
  const fs = require("fs");
  let j = {};
  try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) {}
  const today = process.argv[2];
  const count = j.date === today ? (j.count||0) : 0;
  const halted = j.date === today ? !!j.halted : false;
  console.log(count + "\t" + (halted?1:0) + "\t" + (j.issue_number||""));
' "$daily_file" "$today" 2>/dev/null || printf '0\t0\t')"
IFS=$'\t' read -r daily_count daily_halted daily_issue_num <<<"$daily_read"
case "$daily_count" in ''|*[!0-9]*) daily_count=0 ;; esac
case "$daily_halted" in ''|*[!01]*) daily_halted=0 ;; esac

if [ -z "$ceiling_block" ] && [ "$daily_count" -ge "$daily_action_ceiling" ]; then
  ceiling_block="1"; ceiling_reason="daily-ceiling"
  echo "# pre-flight: daily action ceiling reached ($daily_count >= $daily_action_ceiling actions on $today)"
  if [ "$daily_halted" != "1" ]; then
    body="The autonomous loop hit its daily action ceiling (budget.daily_action_ceiling=$daily_action_ceiling) after $daily_count dispatched actions on $today (UTC). It halts for the rest of today and resumes automatically at UTC midnight. Raise budget.daily_action_ceiling in the adapter if this volume is expected."
    new_issue="$(budget_notify_issue "$daily_issue_num" "Loop budget exceeded: daily action ceiling" "$body")"
    [ -n "$new_issue" ] && daily_issue_num="$new_issue"
    # needs-human (issue #99, deliberately NOT wired here): same reasoning as
    # the stop-after expiry block above -- this ceiling already files/
    # refreshes its own tracking issue as its signal and self-resolves at UTC
    # midnight with no in-tick clear point, so layering the needs-human label
    # here would only perturb loop-ceilings.test.sh's exact gh-call-count
    # assertions for comparatively little added signal.
    tmp_daily="$(mktemp "$state_dir/.loop-daily-ceiling.json.XXXXXX")"
    if CLAUDE_TODAY="$today" CLAUDE_COUNT="$daily_count" CLAUDE_ISSUE="${daily_issue_num:-}" node -e '
      const fs = require("fs");
      const issue = process.env.CLAUDE_ISSUE ? parseInt(process.env.CLAUDE_ISSUE, 10) : null;
      fs.writeFileSync(process.argv[1], JSON.stringify({
        date: process.env.CLAUDE_TODAY,
        count: parseInt(process.env.CLAUDE_COUNT, 10) || 0,
        halted: true,
        issue_number: issue,
      }, null, 2) + "\n");
    ' "$tmp_daily" 2>/dev/null; then
      mv -f "$tmp_daily" "$daily_file"
    else
      rm -f "$tmp_daily"
    fi
  fi
fi

# --- 3) per-issue advance/feedback/comment-fix/ci-fix/rebase attempt budget --
# .claude/state/loop-issue-attempts.json: { "<issue>": {attempts,escalated} }.
# Keyed by the ORIGINATING issue number (advance_ready directly; feedback/
# comment-fix/ci-fix/rebase via feedback_issue/commentfix_issue/cifix_issue/
# rebase_issue, parsed from the PR's feat/issue-N-* branch) so advance-phase,
# feedback-phase, comment-fix-phase, ci-fix-phase, and rebase-phase
# dispatches for the same issue share ONE counter (issue #96 reuses the SAME
# #95 counter, no new state file) -- the candidate mirrors the SAME
# precedence the verdict decision below applies (feedback beats comment-fix
# beats ci-fix beats rebase beats advance; in_flight/lock-held advance
# candidates are never charged). This is INDEPENDENT of pr-comment-fix.sh's
# own per-THREAD retry budget (2 attempts/thread, tracked via the
# claude-comment-addressed marker) and pr-rebase.sh's own per-BASE-COMMIT
# retry budget (2 attempts/base commit, tracked via the
# claude-rebase-attempted marker) -- this counter bounds how many TIMES issue
# N gets dispatched across ANY reaction, those bound how many times ONE
# THREAD/BASE-COMMIT gets retried.
attempts_file="$state_dir/loop-issue-attempts.json"
attempt_issue="" attempt_escalate_kind="" attempt_escalate_num=""
if [ -n "$feedback_pr" ]; then
  attempt_issue="${feedback_issue:-$feedback_pr}"
  attempt_escalate_kind="pr"
  attempt_escalate_num="$feedback_pr"
elif [ -n "$commentfix_pr" ]; then
  attempt_issue="${commentfix_issue:-$commentfix_pr}"
  attempt_escalate_kind="pr"
  attempt_escalate_num="$commentfix_pr"
elif [ -n "$cifix_pr" ]; then
  attempt_issue="${cifix_issue:-$cifix_pr}"
  attempt_escalate_kind="pr"
  attempt_escalate_num="$cifix_pr"
elif [ -n "$rebase_pr" ]; then
  attempt_issue="${rebase_issue:-$rebase_pr}"
  attempt_escalate_kind="pr"
  attempt_escalate_num="$rebase_pr"
elif [ "$advance_ready" != "none" ] && [ -n "$advance_ready" ] \
     && ! printf '%s\n' "$in_flight_issues" | grep -qx "$advance_ready" \
     && [ "$lock_issue" != "$advance_ready" ]; then
  attempt_issue="$advance_ready"
  attempt_escalate_kind="issue"
  attempt_escalate_num="$advance_ready"
fi

if [ -z "$ceiling_block" ] && [ -n "$attempt_issue" ]; then
  attempt_read="$(CLAUDE_ATT_KEY="$attempt_issue" node -e '
    const fs = require("fs");
    const key = process.env.CLAUDE_ATT_KEY;
    try {
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const e = j[key] || {};
      console.log((e.attempts||0) + "\t" + (e.escalated?1:0));
    } catch (e) { console.log("0\t0"); }
  ' "$attempts_file" 2>/dev/null || printf '0\t0')"
  IFS=$'\t' read -r attempts_now attempts_escalated <<<"$attempt_read"
  case "$attempts_now" in ''|*[!0-9]*) attempts_now=0 ;; esac
  case "$attempts_escalated" in ''|*[!01]*) attempts_escalated=0 ;; esac

  if [ "$attempts_now" -ge "$per_issue_attempts" ]; then
    ceiling_block="1"; ceiling_reason="attempt-budget"
    echo "# pre-flight: attempt budget exceeded for issue=$attempt_issue ($attempts_now >= $per_issue_attempts)"
    if [ "$attempts_escalated" != "1" ]; then
      body="This ${attempt_escalate_kind} has ping-ponged through $attempts_now advance/feedback dispatches for issue #$attempt_issue without landing (budget.per_issue_attempts=$per_issue_attempts). The loop will not retry it automatically -- labeling \`needs-human\`. Address it by hand, then either close it out or clear its entry in .claude/state/loop-issue-attempts.json to let the loop resume."
      needs_human_flag "${attempt_escalate_kind}:${attempt_escalate_num}" "attempt-budget" "high" \
        "Loop attempt budget exhausted for issue #$attempt_issue" "$body"
      tmp_att="$(mktemp "$state_dir/.loop-issue-attempts.json.XXXXXX")"
      if CLAUDE_ATT_KEY="$attempt_issue" CLAUDE_ATT_COUNT="$attempts_now" node -e '
        const fs = require("fs");
        const file = process.argv[1], tmp = process.argv[2];
        const key = process.env.CLAUDE_ATT_KEY;
        let j = {};
        try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {}
        j[key] = { attempts: parseInt(process.env.CLAUDE_ATT_COUNT, 10) || 0, escalated: true };
        fs.writeFileSync(tmp, JSON.stringify(j, null, 2) + "\n");
      ' "$attempts_file" "$tmp_att" 2>/dev/null; then
        mv -f "$tmp_att" "$attempts_file"
      else
        rm -f "$tmp_att"
      fi
    fi
  fi
fi

# ---------------------------------------------------------------------------
# STEP 0.5: stall/resume machinery (issue #98). An `in_flight` candidate (a
# feat/issue-N-* branch exists, no open PR yet) used to be refused OUTRIGHT,
# FOREVER -- exactly the incident issue #111's post-exit debris classifier
# deals with AFTER a driver exits cleanly, but with no equivalent for a
# driver that's still nominally "in flight" per the ledger yet has gone quiet
# mid-session (hung, or its session died before loop-daemon.sh's own exit
# handler ever ran verify_and_classify_post_exit on it). This closes that
# gap: an in_flight candidate is RESUMED (verdict points at its existing
# branch instead of refusing) when EITHER of two independent signals fires,
# neither reimplemented here:
#   - loop-census.sh's own stall clock (`stalled=N age_min=M`, driven by
#     events.jsonl inactivity -- issue #98 pt 1), or
#   - the branch's debris classifies as "half-done" via loop-daemon.sh's
#     classify_debris (issue #111) -- called VERBATIM in a subshell below so
#     the absent/empty/publishable/half-done state vocabulary never diverges
#     between the two call sites.
#
# REACHABILITY (post-review correction): the first cut of this feature gated
# the whole resume path on "advance_ready equals an issue ALSO reported
# in_flight" -- but loop-census.sh makes those mutually exclusive for any
# single issue: advance_ready only ever names a candidate with branch=none
# (eligible=1 requires it), while in_flight only ever names a candidate whose
# branch is NOT none. No real census snapshot can ever satisfy both for the
# same issue, so that gate was dead code -- a genuinely stalled in_flight
# issue was NEVER resumed or escalated in production. Fixed by consuming
# in_flight=/stalled= DIRECTLY off the fresh census output below, entirely
# independent of advance_ready. This block only runs once advance_ready has
# resolved to "none" for this tick (see the verdict decision below) -- i.e.
# a genuinely fresh, branchless advance candidate still has first claim on
# the tick ("fresh advance beats resume", mirroring the existing
# feedback-beats-advance precedence). Among several in_flight candidates
# that qualify (stalled OR half-done debris), the LOWEST-numbered one that
# is not YET escalated is picked (mirrors feedback's "lowest PR wins"); one
# already escalated to needs-human is skipped in favor of a later candidate
# rather than refusing the whole tick.
#
# Bounded to 2 resume attempts PER ISSUE, tracked in a SIBLING state file
# (.claude/state/loop-resume-attempts.json, {count,escalated} shape +
# mktemp/atomic-mv discipline mirroring loop-issue-attempts.json) rather than
# folded into loop-issue-attempts.json itself: that file counts advance/
# feedback DISPATCHES against issue #95's spend ceiling -- a different budget
# than "how many times has THIS stalled branch been resumed"; conflating the
# two would let a resume silently eat into (or be eaten by) the dispatch
# budget (see the dispatch-bookkeeping block near the bottom of this script,
# which deliberately does NOT charge action=resume against
# loop-issue-attempts.json/the daily ceiling). The 3rd stall does not resume
# again: it escalates to needs-human (mirroring the attempt-budget
# escalation block above -- label create + issue edit + issue comment) and
# sets escalated:true so the loop never auto-retries it again.
#
# NOTE (latent risk, acknowledged, follow-up out of scope): driver-side
# resume DISPATCH -- actually reconnecting to / resuming work in the stalled
# branch's worktree -- does not exist yet; this script only emits the
# verdict. Until that dispatch exists, a resume verdict burns one of the 2
# attempts with no actual resume happening, so a stalled issue whose driver
# is never manually restarted will still escalate to needs-human within 3
# stalled ticks once this fix makes the path reachable. That is the correct,
# safe default for an unresumable stall (it surfaces to a human instead of
# wedging forever, the bug this fix closes), and the accounting stays
# coherent because an "attempt" is only counted when a resume verdict is
# ACTUALLY emitted below -- never speculatively on a tick that took some
# other action.
# ---------------------------------------------------------------------------
resume_attempts_file="$state_dir/loop-resume-attempts.json"

# Best-effort telemetry only (issue #98) -- must never affect the tick, and
# must never explode in a test fixture that doesn't ship log-event.sh.
log_loop_event() {
  [ -f "$script_dir/log-event.sh" ] || return 0
  bash "$script_dir/log-event.sh" --role orchestrator --task "$1" --phase "$2" --detail "${3:-}" >/dev/null 2>&1 || true
}

# Is issue $1 named on one of census's own `stalled=N age_min=M` lines?
is_census_stalled() {
  printf '%s\n' "$census_out" | grep -q "^stalled=$1 "
}

# The bare branch name census printed for issue $1 on its
# "issue=$1 branch=<name> title=..." detail line -- stripped of any
# "origin/" remote-tracking prefix census may report (classify_debris and
# loop-daemon.sh's worktree_for_branch both expect the BARE local branch
# name). Prints nothing when the issue has no branch, or census's fixture
# output never emitted a detail line for it.
branch_for_issue() {
  local b
  b="$(printf '%s\n' "$census_out" | sed -n "s/^issue=$1 branch=\([^ ]*\) .*/\1/p" | head -1)"
  [ -n "$b" ] && [ "$b" != "none" ] && printf '%s' "${b#origin/}"
  return 0
}

# classify_debris for issue $1's branch, reusing loop-daemon.sh's classifier
# VERBATIM (issue #111) -- sourced in a SUBSHELL so its top-level state
# (state_dir, ledger, etc.) never leaks into this script's own variables.
# Prints "absent" when there's no branch to classify, or when loop-daemon.sh
# isn't sitting next to this script (a test fixture that never copied it in
# -- guarded so those fixtures degrade to the pre-#98 in_flight-refuses
# behavior instead of erroring).
classify_debris_for_issue() {
  local branch; branch="$(branch_for_issue "$1")"
  [ -n "$branch" ] || { printf 'absent'; return 0; }
  [ -f "$script_dir/loop-daemon.sh" ] || { printf 'absent'; return 0; }
  (
    # shellcheck source=loop-daemon.sh
    . "$script_dir/loop-daemon.sh"
    wt="$(worktree_for_branch "$branch")"
    classify_debris "$branch" "$wt"
  )
}

# $1=issue. Prints "<count>\t<escalated 0|1>" from resume_attempts_file.
read_resume_state() {
  local key="$1"
  CLAUDE_RES_KEY="$key" node -e '
    const fs = require("fs");
    const key = process.env.CLAUDE_RES_KEY;
    try {
      const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      const e = j[key] || {};
      console.log((e.count||0) + "\t" + (e.escalated?1:0));
    } catch (e) { console.log("0\t0"); }
  ' "$resume_attempts_file" 2>/dev/null || printf '0\t0'
}

# $1=issue $2=count $3=escalated(0|1). Atomic temp+mv, mirroring every other
# state-file writer in this script.
write_resume_state() {
  local key="$1" count="$2" escalated="$3"
  local tmp; tmp="$(mktemp "$state_dir/.loop-resume-attempts.json.XXXXXX")"
  if CLAUDE_RES_KEY="$key" CLAUDE_RES_COUNT="$count" CLAUDE_RES_ESC="$escalated" node -e '
    const fs = require("fs");
    const file = process.argv[1], tmp = process.argv[2];
    const key = process.env.CLAUDE_RES_KEY;
    let j = {};
    try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {}
    j[key] = { count: parseInt(process.env.CLAUDE_RES_COUNT, 10) || 0, escalated: process.env.CLAUDE_RES_ESC === "1" };
    fs.writeFileSync(tmp, JSON.stringify(j, null, 2) + "\n");
  ' "$resume_attempts_file" "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$resume_attempts_file"
  else
    rm -f "$tmp"
  fi
}

# --- Decide the verdict -----------------------------------------------------
# The verdict string is captured into a variable (rather than echoed inline)
# so it can ALSO be persisted to the tick log below without disturbing the
# invariant that the verdict line is the LAST line of stdout. A spend-ceiling
# breach above (ceiling_block) short-circuits straight to action=none,
# WITHOUT the spawn-lock write the advance branch below would otherwise do.
verdict=""
if [ -n "$ceiling_block" ]; then
  verdict="action=none"
elif [ -n "$feedback_pr" ]; then
  verdict="action=feedback pr=$feedback_pr"
elif [ -n "$commentfix_pr" ]; then
  verdict="action=comment-fix pr=$commentfix_pr"
elif [ -n "$cifix_pr" ]; then
  verdict="action=ci-fix pr=$cifix_pr"
elif [ -n "$rebase_pr" ]; then
  verdict="action=rebase pr=$rebase_pr"
elif [ "$advance_ready" != "none" ] && [ -n "$advance_ready" ]; then
  if printf '%s\n' "$in_flight_issues" | grep -qx "$advance_ready"; then
    # Defensive only: real census can never report the SAME issue as both
    # advance_ready (requires branch=none) and in_flight (requires branch!=
    # none) -- see the STEP 0.5 comment above. Kept as a belt-and-suspenders
    # refusal in case a future census bug (or a hand-built test fixture)
    # ever produces this combination; it must never fall through to a fresh
    # action=advance for an issue that also looks in_flight.
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
    # advance_mode telemetry (issue #100): only for a GENUINE advance dispatch
    # (never on a refused/downgraded verdict above) -- loop-event.sh greps
    # this out of the tick's full stdout (not the tail-1 verdict) to pick the
    # right driver prompt variant. Printed BEFORE the final verdict line
    # below, so it never disturbs the "verdict is the last stdout line"
    # invariant.
    echo "advance_mode=$advance_mode"
  fi
else
  # --- stall/resume path (issue #98, reworked) -----------------------------
  # No fresh, branchless candidate is ready this tick (advance_ready=none) --
  # scan census's in_flight= issues DIRECTLY (independent of advance_ready;
  # see the reachability note in the STEP 0.5 comment above) for the lowest-
  # numbered one that's genuinely stalled (census's own clock) or whose
  # branch classifies as half-done debris, and that hasn't already been
  # escalated to needs-human.
  resume_issue="" resume_branch="" resume_stalled_now=0 resume_debris_now="none"
  # Lowest-numbered qualifying candidate that's ALREADY escalated -- tracked
  # only so a tick where every qualifying candidate happens to be escalated
  # still emits the specific "already escalated" diagnostic below rather than
  # the generic in_flight refusal (matches this feature's pre-rework
  # behavior for the single-candidate case).
  escalated_issue=""
  for cand in $(printf '%s\n' "$in_flight_issues" | sort -n -u); do
    [ -n "$cand" ] || continue
    cand_stalled=0
    is_census_stalled "$cand" && cand_stalled=1
    cand_debris="none"
    if [ "$cand_stalled" -eq 0 ]; then
      cand_debris="$(classify_debris_for_issue "$cand")"
    fi
    [ "$cand_stalled" -eq 1 ] || [ "$cand_debris" = "half-done" ] || continue
    IFS=$'\t' read -r cand_count cand_escalated <<<"$(read_resume_state "$cand")"
    case "$cand_escalated" in ''|*[!01]*) cand_escalated=0 ;; esac
    if [ "$cand_escalated" = "1" ]; then
      [ -n "$escalated_issue" ] || escalated_issue="$cand"
      continue
    fi
    resume_issue="$cand"
    resume_stalled_now="$cand_stalled"
    resume_debris_now="$cand_debris"
    resume_branch="$(branch_for_issue "$cand")"
    break
  done

  if [ -n "$resume_issue" ]; then
    log_loop_event "$resume_issue" "stall-detected" "in_flight issue=$resume_issue flagged stalled=$resume_stalled_now debris=$resume_debris_now"
    IFS=$'\t' read -r resume_count resume_escalated <<<"$(read_resume_state "$resume_issue")"
    case "$resume_count" in ''|*[!0-9]*) resume_count=0 ;; esac
    case "$resume_escalated" in ''|*[!01]*) resume_escalated=0 ;; esac
    if [ "$resume_escalated" = "1" ]; then
      # Unreachable given the loop above already skips escalated candidates,
      # kept for defense in depth against a race between the read above and
      # here (state file changed underneath us mid-tick).
      echo "# advance refused: issue=$resume_issue is in_flight and stalled, but already escalated to needs-human -- not retrying"
      verdict="action=none"
    elif [ "$resume_count" -lt 2 ]; then
      new_resume_count=$((resume_count + 1))
      write_resume_state "$resume_issue" "$new_resume_count" "0"
      echo "# resume: issue=$resume_issue is in_flight and stalled (attempt $new_resume_count/2) -- resuming the existing branch/worktree instead of refusing"
      log_loop_event "$resume_issue" "resume-attempt" "resume attempt $new_resume_count/2 for issue=$resume_issue"
      if [ -n "$resume_branch" ]; then
        verdict="action=resume issue=$resume_issue branch=$resume_branch"
      else
        verdict="action=resume issue=$resume_issue"
      fi
    else
      write_resume_state "$resume_issue" "$resume_count" "1"
      body="Issue #$resume_issue's feat/issue-$resume_issue-* branch has stalled and already been resumed $resume_count times without landing a PR. The loop will not retry it automatically -- labeling \`needs-human\`. Address it by hand, then either close it out or clear its entry in .claude/state/loop-resume-attempts.json to let the loop resume."
      needs_human_flag "issue:$resume_issue" "stall" "high" \
        "Issue #$resume_issue stalled -- resume attempts exhausted" "$body"
      echo "# advance refused: issue=$resume_issue exhausted its 2 resume attempts -- escalated to needs-human"
      log_loop_event "$resume_issue" "escalated-to-needs-human" "issue=$resume_issue escalated to needs-human after $resume_count resumes"
      verdict="action=none"
    fi
  elif [ -n "$escalated_issue" ]; then
    # Every stalled/half-done candidate this tick is already escalated to
    # needs-human -- do not resume, and do not re-touch its state.
    echo "# advance refused: issue=$escalated_issue is in_flight and stalled, but already escalated to needs-human -- not retrying"
    verdict="action=none"
  else
    # No in_flight candidate qualifies for resume this tick (none are
    # stalled/half-done, or there are no in_flight issues at all) -- refuse
    # each in_flight issue individually, matching the pre-#98 diagnostic
    # verbatim so operators/tests can still tell WHICH issue(s) are sitting
    # in_flight-but-untouched this tick.
    for cand in $(printf '%s\n' "$in_flight_issues" | sort -n -u); do
      [ -n "$cand" ] || continue
      echo "# advance refused: issue=$cand is in_flight (a feat/issue-$cand-* branch already exists with no open PR)"
    done
    verdict="action=none"
  fi
fi

# --- Spend-ceiling bookkeeping: increment counts on an ACTUAL dispatch ------
# Only runs when the verdict just decided is a genuine advance/feedback/
# comment-fix/ci-fix/rebase dispatch (never on action=none, ceiling-blocked or
# not) -- so a blocked tick never itself grows the very counters that blocked
# it. action=resume is
# DELIBERATELY excluded here: resume attempts are tracked in the SIBLING
# loop-resume-attempts.json (written above, alongside the verdict decision),
# precisely so a resume never charges issue #95's advance/feedback dispatch
# budget (loop-issue-attempts.json) or its daily action ceiling -- see the
# STEP 0.5 comment above.
dispatch_issue=""
case "$verdict" in
  "action=advance issue="*) dispatch_issue="${verdict#action=advance issue=}" ;;
  "action=feedback pr="*)
    dispatch_pr="${verdict#action=feedback pr=}"
    if [ "$dispatch_pr" = "$feedback_pr" ] && [ -n "${feedback_issue:-}" ]; then
      dispatch_issue="$feedback_issue"
    else
      dispatch_issue="$dispatch_pr"
    fi
    ;;
  "action=comment-fix pr="*)
    dispatch_pr="${verdict#action=comment-fix pr=}"
    if [ "$dispatch_pr" = "$commentfix_pr" ] && [ -n "${commentfix_issue:-}" ]; then
      dispatch_issue="$commentfix_issue"
    else
      dispatch_issue="$dispatch_pr"
    fi
    ;;
  "action=ci-fix pr="*)
    dispatch_pr="${verdict#action=ci-fix pr=}"
    if [ "$dispatch_pr" = "$cifix_pr" ] && [ -n "${cifix_issue:-}" ]; then
      dispatch_issue="$cifix_issue"
    else
      dispatch_issue="$dispatch_pr"
    fi
    ;;
  "action=rebase pr="*)
    dispatch_pr="${verdict#action=rebase pr=}"
    if [ "$dispatch_pr" = "$rebase_pr" ] && [ -n "${rebase_issue:-}" ]; then
      dispatch_issue="$rebase_issue"
    else
      dispatch_issue="$dispatch_pr"
    fi
    ;;
esac

if [ -n "$dispatch_issue" ]; then
  tmp_att="$(mktemp "$state_dir/.loop-issue-attempts.json.XXXXXX")"
  if CLAUDE_ATT_KEY="$dispatch_issue" node -e '
    const fs = require("fs");
    const file = process.argv[1], tmp = process.argv[2];
    const key = process.env.CLAUDE_ATT_KEY;
    let j = {};
    try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {}
    const cur = j[key] || { attempts: 0, escalated: false };
    j[key] = { attempts: (cur.attempts || 0) + 1, escalated: !!cur.escalated };
    fs.writeFileSync(tmp, JSON.stringify(j, null, 2) + "\n");
  ' "$attempts_file" "$tmp_att" 2>/dev/null; then
    mv -f "$tmp_att" "$attempts_file"
  else
    rm -f "$tmp_att"
  fi

  tmp_daily="$(mktemp "$state_dir/.loop-daily-ceiling.json.XXXXXX")"
  if CLAUDE_TODAY="$today" node -e '
    const fs = require("fs");
    const file = process.argv[1], tmp = process.argv[2];
    const today = process.env.CLAUDE_TODAY;
    let j = {};
    try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {}
    const count = (j.date === today) ? (j.count || 0) + 1 : 1;
    fs.writeFileSync(tmp, JSON.stringify({
      date: today, count, halted: (j.date === today) ? !!j.halted : false,
      issue_number: j.issue_number || null,
    }, null, 2) + "\n");
  ' "$daily_file" "$tmp_daily" 2>/dev/null; then
    mv -f "$tmp_daily" "$daily_file"
  else
    rm -f "$tmp_daily"
  fi
fi

echo "$verdict"

# Persist the tick record (issue #85) AFTER the verdict has been echoed, and
# writing to the FILE ONLY -- never stdout -- so the verdict line above stays
# the last line of this script's stdout. Best-effort: never allowed to affect
# the exit status set below.
write_tick_record "$verdict" "$cadence" "$ceiling_reason" || true
