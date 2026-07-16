#!/usr/bin/env bash
# loop-ceilings.test.sh — offline smoke test for loop-tick.sh's spend-ceiling
# pre-flight (issue #95): stop-after self-disarm, per-issue advance/feedback
# attempt budget, and the daily action ceiling.
#
# Same fixture strategy as loop-tick.test.sh: a throwaway <fixture>/.claude/
# tree containing the REAL loop-tick.sh + resolve-roots.sh next to FAKE
# loop-census.sh/notify-poll.sh/merge-ready.sh/pr-feedback.sh that print
# canned output, PLUS a fake bot-gh.sh (loop-tick.sh's own `gh` wrapper calls
# it via bot-gh.sh under $script_dir) that logs every invocation to a file
# instead of touching the network — so ceiling-breach scenarios (which DO
# call gh for the one-time notify/label/comment) still need zero network,
# and non-breach scenarios can assert bot-gh.sh was never even created/called.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/loop-ceilings.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
loop_tick_src="$script_dir/loop-tick.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/loop-ceilings-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail=0
ok=0
check() {
  local desc="$1"; shift
  if "$@"; then
    ok=$((ok + 1))
    echo "ok - $desc"
  else
    fail=1
    echo "FAIL - $desc"
  fi
}

# $1=name $2=fake_census $3=fake_feedback (TSV body, may be empty)
# $4=1 to also install a call-logging fake bot-gh.sh (default: no bot-gh.sh at
# all, matching loop-tick.test.sh's own "gh must never be invoked" contract
# for scenarios that expect zero gh side effects).
new_fixture() {
  local name="$1" fake_census="$2" fake_feedback="$3" with_gh="${4:-0}"
  local dir="$work/$name/.claude/scripts"
  mkdir -p "$dir" "$work/$name/.claude/state" 2>/dev/null
  rm -rf "$work/$name/.claude/state"   # loop-tick.sh must mkdir -p it itself
  cp "$loop_tick_src" "$dir/loop-tick.sh"
  cp "$resolve_roots_src" "$dir/resolve-roots.sh"
  # needs-human.sh/notify.sh (issue #99): loop-tick.sh sources needs-human.sh
  # unconditionally when present -- copy the REAL implementations so the
  # attempt-budget escalation scenarios (5, 6) exercise the real seam, with
  # gh calls still landing only in this fixture's own logging bot-gh.sh.
  cp "$script_dir/needs-human.sh" "$dir/needs-human.sh"
  cp "$script_dir/notify.sh" "$dir/notify.sh"

  cat > "$dir/loop-census.sh" <<EOF
#!/usr/bin/env bash
cat <<'CENSUS'
$fake_census
CENSUS
EOF
  cat > "$dir/notify-poll.sh" <<'EOF'
#!/usr/bin/env bash
echo "CURSOR=fake NOW=fake"
EOF
  cat > "$dir/merge-ready.sh" <<'EOF'
#!/usr/bin/env bash
echo "=== merge-ready: merged=0 skipped=0 ==="
EOF
  cat > "$dir/pr-feedback.sh" <<EOF
#!/usr/bin/env bash
cat <<'FEEDBACK'
$fake_feedback
FEEDBACK
EOF
  chmod +x "$dir"/*.sh

  if [ "$with_gh" = "1" ]; then
    # Logs "sub sub2 ... argN" one line per call to gh-calls.log, and returns
    # canned output for the two calls the ceiling code actually reads stdout
    # from: `gh issue create` (needs a URL ending in a number) and
    # `gh issue view --json state --jq .state` (needs OPEN/CLOSED).
    cat > "$dir/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
log="$(dirname "$0")/../state/gh-calls.log"
mkdir -p "$(dirname "$log")"
printf '%s\n' "$*" >> "$log"
case "$1 $2" in
  "issue create") echo "https://github.com/acme/repo/issues/777" ;;
  "issue view") echo "${FAKE_ISSUE_STATE:-OPEN}" ;;
esac
exit 0
EOF
    chmod +x "$dir/bot-gh.sh"
  fi

  printf '%s\n' "$dir"
}

run_tick() {
  # $1 = fixture script_dir; repo passed explicitly so loop-tick.sh's own gh()
  # (bot-gh.sh) never hits real network even when a fake bot-gh.sh IS present.
  bash "$1/loop-tick.sh" "acme/repo"
}

gh_calls() {
  # $1 = fixture script_dir. Prints the fake bot-gh.sh call log (empty/missing
  # is fine -- `cat` on a missing file just prints nothing under `|| true`).
  cat "$1/../state/gh-calls.log" 2>/dev/null || true
}

verdict_of() { printf '%s\n' "$1" | tail -1; }
# Exported so the `check ... bash -c '...' _ "$arg"` pattern below (a FRESH
# bash subprocess, which does not inherit un-exported shell functions) can
# still call these two helpers.
export -f gh_calls verdict_of

CENSUS_READY_42='open_prs=0
feedback_prs=0
planned_issues=1
issue=42 branch=none title=Do the thing
advance_ready=42
cadence=FAST cron=* * * * *'

FEEDBACK_PR_17='17	feat/issue-42-x	owner	2026-01-01T00:00:00Z'

# ---------------------------------------------------------------------------
# 1. Stop-after: expiry in the FUTURE -> advance proceeds normally, no gh
#    calls, and the tick record's `reason` field is empty (no ceiling fired).
# ---------------------------------------------------------------------------
dir1="$(new_fixture scenario1 "$CENSUS_READY_42" "" 0)"
node -e '
  const fs = require("fs");
  const dir = process.argv[1] + "/../state";
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "/loop-arming.json", JSON.stringify({
    armed_at: "2026-01-01T00:00:00Z", expires_at: "2099-01-01T00:00:00Z",
    stop_after_days: 7, notified_expired: false, notice_issue: null,
  }));
' "$dir1"
ticks1="$work/scenario1-ticks.jsonl"
out1="$(CLAUDE_TICKS_FILE="$ticks1" run_tick "$dir1")"
check "scenario 1 (future expiry): advance proceeds" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=advance issue=42" ]' _ "$out1"
check "scenario 1: no gh side effects (no bot-gh.sh exists, and none is needed)" [ ! -f "$dir1/bot-gh.sh" ]
check "scenario 1: tick record reason is empty (no ceiling fired)" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.reason !== "") throw new Error("expected empty reason, got " + JSON.stringify(obj));
' "$ticks1"

# ---------------------------------------------------------------------------
# 2. Stop-after: expiry in the PAST -> action=none reason=expired, ONE-TIME
#    notify (gh issue create), and the notify guard prevents a second call on
#    the very next tick even though the loop stays expired.
# ---------------------------------------------------------------------------
dir2="$(new_fixture scenario2 "$CENSUS_READY_42" "" 1)"
node -e '
  const fs = require("fs");
  const dir = process.argv[1] + "/../state";
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "/loop-arming.json", JSON.stringify({
    armed_at: "2020-01-01T00:00:00Z", expires_at: "2020-01-08T00:00:00Z",
    stop_after_days: 7, notified_expired: false, notice_issue: null,
  }));
' "$dir2"
out2="$(run_tick "$dir2")"
check "scenario 2 (past expiry): verdict is action=none" bash -c '[ "$(verdict_of "$1")" = "action=none" ]' _ "$out2"
check "scenario 2: diagnostic cites the expiry" bash -c 'printf "%s\n" "$1" | grep -q "loop disarmed (stop-after expired"' _ "$out2"
check "scenario 2: exactly one gh call was made (the one-time notify)" bash -c '[ "$(gh_calls "$1" | wc -l | tr -d " ")" -eq 1 ]' _ "$dir2"
check "scenario 2: the notify call is the FULL expected 'issue create' with --label backlog (not just any create)" bash -c 'gh_calls "$1" | grep -qF -- "issue create --title Loop disarmed: stop-after expired --label backlog --body "' _ "$dir2"
check "scenario 2: --label planned is NEVER emitted by the ceiling notify path (self-loop regression guard)" bash -c '! gh_calls "$1" | grep -q -- "--label planned"' _ "$dir2"
check "scenario 2: notified_expired is now persisted true" bash -c '
  node -e "const j=require(process.argv[1]); if(j.notified_expired!==true) process.exit(1); if(j.notice_issue!==777) process.exit(1);" "$1/../state/loop-arming.json"
' _ "$dir2"
# Second tick: still expired, but the guard must suppress a second notify.
out2b="$(run_tick "$dir2")"
check "scenario 2b (still expired, second tick): verdict is still action=none" bash -c '[ "$(verdict_of "$1")" = "action=none" ]' _ "$out2b"
check "scenario 2b: no ADDITIONAL gh call (guard held) -- still exactly 1 total" bash -c '[ "$(gh_calls "$1" | wc -l | tr -d " ")" -eq 1 ]' _ "$dir2"

# ---------------------------------------------------------------------------
# 3. Stop-after: no arming file at all (pre-#95 armed loop) -> loop-tick.sh
#    lazily self-inits one starting NOW, so the FIRST tick still proceeds
#    (not expired) and a ceiling now exists going forward.
# ---------------------------------------------------------------------------
dir3="$(new_fixture scenario3 "$CENSUS_READY_42" "" 0)"
out3="$(run_tick "$dir3")"
check "scenario 3 (no arming file, fallback init): advance proceeds" bash -c '[ "$(verdict_of "$1")" = "action=advance issue=42" ]' _ "$out3"
check "scenario 3: loop-arming.json now exists with a future expires_at" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (!j.expires_at || Date.parse(j.expires_at) <= Date.now()) throw new Error("expected a future expires_at, got " + JSON.stringify(j));
' "$dir3/../state/loop-arming.json"

# ---------------------------------------------------------------------------
# 4. Per-issue attempt budget: UNDER budget (default 5) -> advance proceeds,
#    and the attempt counter increments by exactly one for issue=42.
# ---------------------------------------------------------------------------
dir4="$(new_fixture scenario4 "$CENSUS_READY_42" "" 0)"
node -e '
  const fs = require("fs");
  const dir = process.argv[1] + "/../state";
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "/loop-issue-attempts.json", JSON.stringify({ "42": { attempts: 2, escalated: false } }));
' "$dir4"
out4="$(run_tick "$dir4")"
check "scenario 4 (attempts 2 < budget 5): advance proceeds" bash -c '[ "$(verdict_of "$1")" = "action=advance issue=42" ]' _ "$out4"
check "scenario 4: attempts incremented from 2 to 3 for issue 42" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (j["42"].attempts !== 3) throw new Error("expected 3, got " + JSON.stringify(j));
' "$dir4/../state/loop-issue-attempts.json"

# ---------------------------------------------------------------------------
# 5. Per-issue attempt budget: AT budget -> refused (action=none,
#    reason=attempt-budget), issue is labeled+commented needs-human EXACTLY
#    ONCE (escalated guard), and a second tick makes no further gh calls.
# ---------------------------------------------------------------------------
dir5="$(new_fixture scenario5 "$CENSUS_READY_42" "" 1)"
node -e '
  const fs = require("fs");
  const dir = process.argv[1] + "/../state";
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "/loop-issue-attempts.json", JSON.stringify({ "42": { attempts: 5, escalated: false } }));
' "$dir5"
out5="$(run_tick "$dir5")"
check "scenario 5 (attempts 5 >= budget 5): verdict is action=none" bash -c '[ "$(verdict_of "$1")" = "action=none" ]' _ "$out5"
check "scenario 5: diagnostic cites the attempt budget" bash -c 'printf "%s\n" "$1" | grep -q "attempt budget exceeded for issue=42"' _ "$out5"
check "scenario 5: exactly 3 gh calls (label create, issue edit, issue comment)" bash -c '[ "$(gh_calls "$1" | wc -l | tr -d " ")" -eq 3 ]' _ "$dir5"
check "scenario 5: the issue itself (not a PR) was labeled needs-human" bash -c 'gh_calls "$1" | grep -q "^issue edit 42 --add-label needs-human"' _ "$dir5"
check "scenario 5: escalated is now persisted true, attempts unchanged at 5" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (j["42"].escalated !== true || j["42"].attempts !== 5) throw new Error("got " + JSON.stringify(j));
' "$dir5/../state/loop-issue-attempts.json"
out5b="$(run_tick "$dir5")"
check "scenario 5b (still over budget, second tick): verdict is still action=none" bash -c '[ "$(verdict_of "$1")" = "action=none" ]' _ "$out5b"
check "scenario 5b: no additional gh calls (escalated guard held) -- still exactly 3" bash -c '[ "$(gh_calls "$1" | wc -l | tr -d " ")" -eq 3 ]' _ "$dir5"

# ---------------------------------------------------------------------------
# 6. Per-issue attempt budget applies across advance AND feedback phases of
#    the SAME issue: a PR (17) cut from feat/issue-42-x inherits issue 42's
#    existing attempt count and is refused/escalated as PR 17 (not issue 42).
# ---------------------------------------------------------------------------
dir6="$(new_fixture scenario6 "$CENSUS_READY_42" "$FEEDBACK_PR_17" 1)"
node -e '
  const fs = require("fs");
  const dir = process.argv[1] + "/../state";
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "/loop-issue-attempts.json", JSON.stringify({ "42": { attempts: 5, escalated: false } }));
' "$dir6"
out6="$(run_tick "$dir6")"
check "scenario 6 (feedback for issue 42's PR, budget already exhausted): verdict is action=none" bash -c '[ "$(verdict_of "$1")" = "action=none" ]' _ "$out6"
check "scenario 6: the PR (17), not the issue, was labeled/commented needs-human" bash -c 'gh_calls "$1" | grep -q "^pr edit 17 --add-label needs-human" && gh_calls "$1" | grep -q "^pr comment 17"' _ "$dir6"

# ---------------------------------------------------------------------------
# 7. Daily action ceiling: UNDER the ceiling (default 50) -> advance
#    proceeds, count increments by exactly one for today.
# ---------------------------------------------------------------------------
dir7="$(new_fixture scenario7 "$CENSUS_READY_42" "" 0)"
today="$(date -u +%Y-%m-%d)"
CLAUDE_TODAY="$today" node -e '
  const fs = require("fs");
  const dir = process.argv[1] + "/../state";
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "/loop-daily-ceiling.json", JSON.stringify({ date: process.env.CLAUDE_TODAY, count: 10, halted: false, issue_number: null }));
' "$dir7"
out7="$(CLAUDE_TODAY="$today" run_tick "$dir7")"
check "scenario 7 (count 10 < ceiling 50): advance proceeds" bash -c '[ "$(verdict_of "$1")" = "action=advance issue=42" ]' _ "$out7"
check "scenario 7: daily count incremented from 10 to 11" env CLAUDE_TODAY="$today" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (j.count !== 11 || j.date !== process.env.CLAUDE_TODAY) throw new Error("got " + JSON.stringify(j));
' "$dir7/../state/loop-daily-ceiling.json"

# ---------------------------------------------------------------------------
# 8. Daily action ceiling: AT the ceiling -> action=none reason=daily-ceiling,
#    a SINGLE tracking issue is filed, and a second same-day tick makes no
#    additional gh calls (halted guard) even though the breach persists.
# ---------------------------------------------------------------------------
dir8="$(new_fixture scenario8 "$CENSUS_READY_42" "" 1)"
CLAUDE_TODAY="$today" node -e '
  const fs = require("fs");
  const dir = process.argv[1] + "/../state";
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "/loop-daily-ceiling.json", JSON.stringify({ date: process.env.CLAUDE_TODAY, count: 50, halted: false, issue_number: null }));
' "$dir8"
out8="$(CLAUDE_TODAY="$today" run_tick "$dir8")"
check "scenario 8 (count 50 >= ceiling 50): verdict is action=none" bash -c '[ "$(verdict_of "$1")" = "action=none" ]' _ "$out8"
check "scenario 8: diagnostic cites the daily ceiling" bash -c 'printf "%s\n" "$1" | grep -q "daily action ceiling reached"' _ "$out8"
check "scenario 8: exactly one gh call (the tracking-issue file)" bash -c '[ "$(gh_calls "$1" | wc -l | tr -d " ")" -eq 1 ]' _ "$dir8"
check "scenario 8: the notify call is the FULL expected 'issue create' with --label backlog (not just any create)" bash -c 'gh_calls "$1" | grep -qF -- "issue create --title Loop budget exceeded: daily action ceiling --label backlog --body "' _ "$dir8"
check "scenario 8: --label planned is NEVER emitted by the ceiling notify path (self-loop regression guard)" bash -c '! gh_calls "$1" | grep -q -- "--label planned"' _ "$dir8"
check "scenario 8: halted persisted true with the filed issue number recorded" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (j.halted !== true || j.issue_number !== 777) throw new Error("got " + JSON.stringify(j));
' "$dir8/../state/loop-daily-ceiling.json"
out8b="$(CLAUDE_TODAY="$today" run_tick "$dir8")"
check "scenario 8b (still halted, second same-day tick): verdict is still action=none" bash -c '[ "$(verdict_of "$1")" = "action=none" ]' _ "$out8b"
check "scenario 8b: no additional gh call (halted guard held) -- still exactly 1" bash -c '[ "$(gh_calls "$1" | wc -l | tr -d " ")" -eq 1 ]' _ "$dir8"

# ---------------------------------------------------------------------------
# 9. Daily action ceiling resets automatically on a calendar-date change, and
#    REUSES (refreshes) the same tracking issue rather than filing a dupe.
# ---------------------------------------------------------------------------
dir9="$(new_fixture scenario9 "$CENSUS_READY_42" "" 1)"
node -e '
  const fs = require("fs");
  const dir = process.argv[1] + "/../state";
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "/loop-daily-ceiling.json", JSON.stringify({ date: "2020-01-01", count: 999, halted: true, issue_number: 555 }));
' "$dir9"
out9="$(CLAUDE_TODAY="$today" run_tick "$dir9")"
check "scenario 9 (stale date from a prior day): advance proceeds -- counter reset" bash -c '[ "$(verdict_of "$1")" = "action=advance issue=42" ]' _ "$out9"
check "scenario 9: today's count is now 1 (fresh day), issue_number 555 preserved for future refresh" env CLAUDE_TODAY="$today" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (j.count !== 1 || j.date !== process.env.CLAUDE_TODAY || j.issue_number !== 555) throw new Error("got " + JSON.stringify(j));
' "$dir9/../state/loop-daily-ceiling.json"
check "scenario 9: no gh calls (a normal dispatch never itself calls gh)" bash -c '[ -z "$(gh_calls "$1")" ]' _ "$dir9"

# ---------------------------------------------------------------------------
# 10. budget_notify_issue() reuse/refresh path (loop-tick.sh:313-318), which
#     had ZERO coverage before this scenario: a SECOND breach after an issue
#     is already on file must NOT file a duplicate -- it must `gh issue view`
#     the tracked issue and either comment on it (still OPEN) or file a fresh
#     one (CLOSED). Drives three ticks against the SAME fixture, manually
#     resetting `halted` back to false between them to simulate independent
#     breach events without grinding through 50 real ticks per UTC day
#     (halted is what suppresses gh calls WITHIN a single breach -- see
#     scenario 8 -- so clearing it directly is how this isolates the reuse
#     branch on demand). The fake bot-gh.sh's `issue view` reply is
#     configurable via FAKE_ISSUE_STATE (see new_fixture above). CLAUDE_TODAY
#     pins "today" across every tick so none of this depends on wall-clock
#     date (loop-tick.sh's CLAUDE_TODAY override was added alongside this
#     coverage -- see loop-tick.sh:408).
# ---------------------------------------------------------------------------
dir10="$(new_fixture scenario10 "$CENSUS_READY_42" "" 1)"
CLAUDE_TODAY="$today" node -e '
  const fs = require("fs");
  const dir = process.argv[1] + "/../state";
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(dir + "/loop-daily-ceiling.json", JSON.stringify({ date: process.env.CLAUDE_TODAY, count: 50, halted: false, issue_number: null }));
' "$dir10"

# --- 10a: first breach files a fresh tracking issue (no existing to reuse) --
out10a="$(CLAUDE_TODAY="$today" run_tick "$dir10")"
check "scenario 10a (first breach, no existing issue): verdict is action=none" bash -c '[ "$(verdict_of "$1")" = "action=none" ]' _ "$out10a"
check "scenario 10a: exactly one gh call, a full 'issue create' with --label backlog" bash -c '
  [ "$(gh_calls "$1" | wc -l | tr -d " ")" -eq 1 ] &&
  gh_calls "$1" | grep -qF -- "issue create --title Loop budget exceeded: daily action ceiling --label backlog --body "
' _ "$dir10"
check "scenario 10a: issue_number 777 now tracked" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (j.issue_number !== 777) throw new Error("got " + JSON.stringify(j));
' "$dir10/../state/loop-daily-ceiling.json"

# --- 10b: SECOND breach, tracked issue still OPEN -> comment, no duplicate --
CLAUDE_TODAY="$today" node -e '
  const fs = require("fs");
  const file = process.argv[1] + "/../state/loop-daily-ceiling.json";
  const j = JSON.parse(fs.readFileSync(file, "utf8"));
  j.halted = false; // simulate a fresh breach event; tracking issue preserved
  fs.writeFileSync(file, JSON.stringify(j));
' "$dir10"
out10b="$(CLAUDE_TODAY="$today" FAKE_ISSUE_STATE=OPEN run_tick "$dir10")"
check "scenario 10b (second breach, tracked issue OPEN): verdict is action=none" bash -c '[ "$(verdict_of "$1")" = "action=none" ]' _ "$out10b"
check "scenario 10b: no duplicate 'issue create' (still exactly 1 total) -- instead 'issue view' then 'issue comment 777'" bash -c '
  [ "$(gh_calls "$1" | wc -l | tr -d " ")" -eq 3 ] &&
  [ "$(gh_calls "$1" | grep -c "^issue create")" -eq 1 ] &&
  gh_calls "$1" | grep -qF -- "issue view 777 --json state --jq .state" &&
  gh_calls "$1" | grep -qF -- "issue comment 777 --body "
' _ "$dir10"
check "scenario 10b: issue_number still 777 (reused, not replaced)" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (j.issue_number !== 777) throw new Error("got " + JSON.stringify(j));
' "$dir10/../state/loop-daily-ceiling.json"

# --- 10c: THIRD breach, tracked issue now CLOSED -> a fresh issue is filed --
CLAUDE_TODAY="$today" node -e '
  const fs = require("fs");
  const file = process.argv[1] + "/../state/loop-daily-ceiling.json";
  const j = JSON.parse(fs.readFileSync(file, "utf8"));
  j.halted = false;
  fs.writeFileSync(file, JSON.stringify(j));
' "$dir10"
out10c="$(CLAUDE_TODAY="$today" FAKE_ISSUE_STATE=CLOSED run_tick "$dir10")"
check "scenario 10c (third breach, tracked issue CLOSED): verdict is action=none" bash -c '[ "$(verdict_of "$1")" = "action=none" ]' _ "$out10c"
check "scenario 10c: a SECOND 'issue create' fires (closed tracked issue is not reused); comment count still 1" bash -c '
  [ "$(gh_calls "$1" | grep -c "^issue create")" -eq 2 ] &&
  [ "$(gh_calls "$1" | grep -c "^issue comment")" -eq 1 ]
' _ "$dir10"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-ceilings.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-ceilings.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
