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
  local verdict="$1" cadence="$2" reason="${3:-}"
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
feedback_line="$(printf '%s\n' "$feedback_out" | awk -F'\t' 'NF>=2 && $1 ~ /^[0-9]+$/ {print $1"\t"$2}' | sort -t $'\t' -k1,1n | head -1)"
feedback_pr="$(printf '%s\n' "$feedback_line" | awk -F'\t' '{print $1}')"
feedback_branch="$(printf '%s\n' "$feedback_line" | awk -F'\t' '{print $2}')"
# The issue this PR's branch was cut from (feat/issue-N-*), used to key the
# per-issue attempt budget (issue #95) so advance-phase and feedback-phase
# dispatches for the SAME issue share one counter. Falls back to the PR
# number itself when the branch doesn't follow that convention.
feedback_issue="$(printf '%s\n' "$feedback_branch" | sed -n 's#.*feat/issue-\([0-9][0-9]*\)-.*#\1#p')"

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
today="$(date -u +%Y-%m-%d)"
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

# --- 3) per-issue advance/feedback attempt budget ----------------------------
# .claude/state/loop-issue-attempts.json: { "<issue>": {attempts,escalated} }.
# Keyed by the ORIGINATING issue number (advance_ready directly; feedback via
# feedback_issue, parsed from the PR's feat/issue-N-* branch) so advance-phase
# and feedback-phase dispatches for the same issue share one counter -- the
# candidate mirrors the SAME preconditions the verdict decision below applies
# (feedback beats advance; in_flight/lock-held candidates are never charged).
attempts_file="$state_dir/loop-issue-attempts.json"
attempt_issue="" attempt_escalate_kind="" attempt_escalate_num=""
if [ -n "$feedback_pr" ]; then
  attempt_issue="${feedback_issue:-$feedback_pr}"
  attempt_escalate_kind="pr"
  attempt_escalate_num="$feedback_pr"
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
      gh label create "needs-human" --color b60205 --description "Loop attempt budget exhausted -- needs a human" --force >/dev/null 2>&1 || true
      body="This ${attempt_escalate_kind} has ping-ponged through $attempts_now advance/feedback dispatches for issue #$attempt_issue without landing (budget.per_issue_attempts=$per_issue_attempts). The loop will not retry it automatically -- labeling \`needs-human\`. Address it by hand, then either close it out or clear its entry in .claude/state/loop-issue-attempts.json to let the loop resume."
      if [ "$attempt_escalate_kind" = "pr" ]; then
        gh pr edit "$attempt_escalate_num" --add-label needs-human >/dev/null 2>&1 || true
        gh pr comment "$attempt_escalate_num" --body "$body" >/dev/null 2>&1 || true
      else
        gh issue edit "$attempt_escalate_num" --add-label needs-human >/dev/null 2>&1 || true
        gh issue comment "$attempt_escalate_num" --body "$body" >/dev/null 2>&1 || true
      fi
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

# --- Spend-ceiling bookkeeping: increment counts on an ACTUAL dispatch ------
# Only runs when the verdict just decided is a genuine advance/feedback
# dispatch (never on action=none, ceiling-blocked or not) -- so a blocked
# tick never itself grows the very counters that blocked it.
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
