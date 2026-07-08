#!/usr/bin/env bash
# loop-tick.test.sh — offline smoke test for loop-tick.sh (issue #81).
#
# loop-tick.sh's own logic is just: run its four sibling step scripts, parse
# census/pr-feedback output, and emit one verdict line (plus the spawn lock).
# So this test doesn't touch real gh/network — it builds a throwaway
# .claude/scripts/ directory containing the REAL loop-tick.sh + resolve-roots.sh
# next to FAKE loop-census.sh / notify-poll.sh / merge-ready.sh / pr-feedback.sh
# that print canned, scripted output, then asserts the final verdict line and
# the spawn-lock file behavior for each scenario.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/loop-tick.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
loop_tick_src="$script_dir/loop-tick.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/loop-tick-test.XXXXXX")"
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

# Build one fresh fake "consumer project" per scenario: <fixture>/.claude/scripts/.
# fake_census / fake_feedback are the exact stdout the corresponding real
# script would print; notify-poll.sh and merge-ready.sh are stubbed to just
# print a marker line (their output is passed through, never parsed).
new_fixture() {
  local name="$1" fake_census="$2" fake_feedback="$3"
  local dir="$work/$name/.claude/scripts"
  mkdir -p "$dir" "$work/$name/.claude/state" 2>/dev/null
  rm -rf "$work/$name/.claude/state"   # loop-tick.sh must mkdir -p it itself
  cp "$loop_tick_src" "$dir/loop-tick.sh"
  cp "$resolve_roots_src" "$dir/resolve-roots.sh"

  cat > "$dir/loop-census.sh" <<EOF
#!/usr/bin/env bash
cat <<'CENSUS'
$fake_census
CENSUS
EOF
  cat > "$dir/notify-poll.sh" <<'EOF'
#!/usr/bin/env bash
echo "CURSOR=fake NOW=fake"
echo "=== fake notify-poll output ==="
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
  printf '%s\n' "$dir"
}

run_tick() {
  # $1 = fixture script_dir; repo passed explicitly so loop-tick.sh's own gh()
  # (bot-gh.sh) is never invoked (bot-gh.sh doesn't even exist in the fixture).
  bash "$1/loop-tick.sh" "acme/repo"
}

last_line() { tail -1; }

# ---------------------------------------------------------------------------
# 1. Nothing actionable -> action=none.
# ---------------------------------------------------------------------------
dir1="$(new_fixture scenario1 'open_prs=0
feedback_prs=0
planned_issues=0
advance_ready=none
cadence=IDLE cron=*/15 * * * *' '')"
out1="$(run_tick "$dir1")"
check "scenario 1 (nothing actionable): verdict is action=none" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=none" ]' _ "$out1"
check "scenario 1: no spawn lock left behind" [ ! -e "$dir1/../state/loop-advance.lock" ]

# ---------------------------------------------------------------------------
# 2. Advance-ready issue, no feedback, nothing in flight, no lock held ->
#    action=advance issue=N, and the lock file is written.
# ---------------------------------------------------------------------------
dir2="$(new_fixture scenario2 'open_prs=0
feedback_prs=0
planned_issues=1
issue=42 branch=none title=Do the thing
advance_ready=42
cadence=FAST cron=* * * * *' '')"
out2="$(run_tick "$dir2")"
check "scenario 2 (advance ready): verdict is action=advance issue=42" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=advance issue=42" ]' _ "$out2"
lock2="$dir2/../state/loop-advance.lock"
check "scenario 2: spawn lock file was written" [ -f "$lock2" ]
check "scenario 2: lock file records issue=42" grep -q '^issue=42 ts=' "$lock2"

# ---------------------------------------------------------------------------
# 3. Same fixture, SECOND tick while the lock from scenario 2's issue is still
#    held -> downgraded to action=none (never re-emits action=advance for the
#    same issue while a first spawn is still in flight).
# ---------------------------------------------------------------------------
out3="$(run_tick "$dir2")"
check "scenario 3 (lock already held): verdict downgrades to action=none" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=none" ]' _ "$out3"
check "scenario 3: a diagnostic line explains the refusal" bash -c 'printf "%s\n" "$1" | grep -q "spawn lock already held for issue=42"' _ "$out3"
check "scenario 3: the lock file is untouched (still issue=42)" grep -q '^issue=42 ts=' "$lock2"

# ---------------------------------------------------------------------------
# 4. Feedback PR present takes priority over an ALSO-ready advance -> pick the
#    LOWEST-numbered feedback PR, never action=advance.
# ---------------------------------------------------------------------------
dir4="$(new_fixture scenario4 'open_prs=0
feedback_prs=1
planned_issues=1
issue=7 branch=none title=Some issue
advance_ready=7
cadence=FAST cron=* * * * *' "9	feat/issue-9-x	owner	2026-01-01T00:00:00Z
5	feat/issue-5-y	owner	2026-01-01T00:00:00Z")"
out4="$(run_tick "$dir4")"
check "scenario 4 (feedback beats advance): verdict is action=feedback pr=5 (lowest)" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=feedback pr=5" ]' _ "$out4"
check "scenario 4: no spawn lock written (advance never attempted)" [ ! -e "$dir4/../state/loop-advance.lock" ]

# ---------------------------------------------------------------------------
# 5. in_flight refusal: advance_ready=N but census ALSO reports N as in_flight
#    (defensive check — real census never produces both for the same issue,
#    but loop-tick.sh must still refuse rather than double-spawn).
# ---------------------------------------------------------------------------
dir5="$(new_fixture scenario5 'open_prs=0
feedback_prs=0
planned_issues=1
issue=8 branch=feat/issue-8-x title=In flight thing
in_flight=8
advance_ready=8
cadence=FAST cron=* * * * *' '')"
out5="$(run_tick "$dir5")"
check "scenario 5 (in_flight): verdict downgrades to action=none" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=none" ]' _ "$out5"
check "scenario 5: diagnostic cites in_flight" bash -c 'printf "%s\n" "$1" | grep -q "in_flight"' _ "$out5"
check "scenario 5: no spawn lock written" [ ! -e "$dir5/../state/loop-advance.lock" ]

# ---------------------------------------------------------------------------
# 6. Self-heal: a stale lock for issue 3 (no longer advance_ready/in_flight in
#    the fresh census — e.g. its PR landed) must be cleared automatically, and
#    a DIFFERENT now-ready issue can still be picked up in the SAME tick.
# ---------------------------------------------------------------------------
dir6="$(new_fixture scenario6 'open_prs=0
feedback_prs=0
planned_issues=1
issue=9 branch=none title=Fresh issue
advance_ready=9
cadence=FAST cron=* * * * *' '')"
lock6="$dir6/../state/loop-advance.lock"
mkdir -p "$(dirname "$lock6")"
printf 'issue=3 ts=2020-01-01T00:00:00Z\n' > "$lock6"
out6="$(run_tick "$dir6")"
check "scenario 6 (self-heal): verdict advances the NEW issue 9" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=advance issue=9" ]' _ "$out6"
check "scenario 6: self-heal diagnostic mentions the cleared stale issue=3" bash -c 'printf "%s\n" "$1" | grep -q "cleared stale spawn lock for issue=3"' _ "$out6"
check "scenario 6: lock file now records the NEW issue=9, not the stale 3" grep -q '^issue=9 ts=' "$lock6"

# ---------------------------------------------------------------------------
# 7. All four step scripts' full output is preserved (never swallowed).
# ---------------------------------------------------------------------------
check "all four labeled step headers appear in the tick's output" bash -c '
  printf "%s\n" "$1" | grep -q "1/4 loop-census.sh" &&
  printf "%s\n" "$1" | grep -q "2/4 notify-poll.sh" &&
  printf "%s\n" "$1" | grep -q "3/4 merge-ready.sh" &&
  printf "%s\n" "$1" | grep -q "4/4 pr-feedback.sh"
' _ "$out1"
check "notify-poll.sh full output line passed through, not swallowed" bash -c 'printf "%s\n" "$1" | grep -qF "fake notify-poll output"' _ "$out1"
check "merge-ready.sh full output line passed through, not swallowed" bash -c 'printf "%s\n" "$1" | grep -qF "merge-ready: merged=0 skipped=0"' _ "$out1"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-tick.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-tick.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
