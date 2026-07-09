#!/usr/bin/env bash
# loop-daemon.test.sh — offline smoke test for loop-daemon.sh (issue #102).
#
# Two kinds of checks:
#   (A) PURE UNIT checks — `source` the REAL loop-daemon.sh directly into
#       this test's own shell (never `main`, thanks to its BASH_SOURCE guard)
#       and call cadence_to_sleep_seconds / ledger_line directly. Sourcing
#       has zero side effects (no mkdir, no network, no forever loop), so
#       this is safe against the real repo tree.
#   (B) INTEGRATION checks — build a throwaway fixture `.claude/scripts/`
#       (mirroring loop-tick.test.sh's convention) containing the REAL
#       loop-daemon.sh + resolve-roots.sh next to a FAKE loop-event.sh, and
#       fake `claude`/`setsid`/`timeout` stubs prepended onto PATH, then run
#       loop-daemon.sh as a real subprocess with LOOP_DAEMON_MAX_ITERATIONS=1
#       so `main` runs exactly one iteration and exits (instead of forever).
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/loop-daemon.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
loop_daemon_src="$script_dir/loop-daemon.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/loop-daemon-test.XXXXXX")"
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

# =============================================================================
# (A) Pure unit checks: source the real script, call its functions directly.
# =============================================================================
# shellcheck source=loop-daemon.sh
. "$loop_daemon_src"

# --- cadence -> sleep seconds mapping ---------------------------------------
s_fast="$(cadence_to_sleep_seconds 'open_prs=0
feedback_prs=0
cadence=FAST cron=* * * * *')"
check "cadence FAST -> 60s" [ "$s_fast" = "60" ]

s_watch="$(cadence_to_sleep_seconds 'open_prs=1
cadence=WATCH cron=*/5 * * * *')"
check "cadence WATCH -> 300s" [ "$s_watch" = "300" ]

s_idle="$(cadence_to_sleep_seconds 'open_prs=0
planned_issues=0
cadence=IDLE cron=*/15 * * * *')"
check "cadence IDLE -> 900s" [ "$s_idle" = "900" ]

s_missing="$(cadence_to_sleep_seconds 'some garbage output with no cadence line at all')"
check "no cadence line -> fallback 300s" [ "$s_missing" = "300" ]

s_env_override="$(LOOP_DAEMON_SLEEP_FAST=5 cadence_to_sleep_seconds 'cadence=FAST cron=* * * * *')"
check "cadence FAST honors LOOP_DAEMON_SLEEP_FAST override" [ "$s_env_override" = "5" ]

# --- ledger line format ------------------------------------------------------
line1="$(ledger_line 12345 sess-abc 'advance issue=42' '2026-07-09T00:00:00Z' 'result=exit rc=0')"
check "ledger line: exact format with all fields" [ "$line1" = "pid=12345 session=sess-abc verdict=advance issue=42 ts=2026-07-09T00:00:00Z result=exit rc=0" ]

line2="$(ledger_line 999 '' 'feedback pr=7' '2026-07-09T01:00:00Z')"
check "ledger line: empty session_id prints 'unknown'" [ "$line2" = "pid=999 session=unknown verdict=feedback pr=7 ts=2026-07-09T01:00:00Z" ]

line3="$(ledger_line 111 sess-x 'advance issue=1' '2026-07-09T02:00:00Z' 'result=timeout rc=124')"
check "ledger line: timeout result recorded verbatim" [ "$line3" = "pid=111 session=sess-x verdict=advance issue=1 ts=2026-07-09T02:00:00Z result=timeout rc=124" ]

# =============================================================================
# (B) Integration checks: real subprocess, fake loop-event.sh + fake claude.
# =============================================================================
new_fixture() {
  # $1=name $2=fake loop-event.sh body (full script text) -> prints fixture root
  local name="$1" body="$2"
  local dir="$work/$name"
  mkdir -p "$dir/.claude/scripts" "$dir/.claude/state" "$dir/bin"
  cp "$loop_daemon_src" "$dir/.claude/scripts/loop-daemon.sh"
  cp "$resolve_roots_src" "$dir/.claude/scripts/resolve-roots.sh"
  printf '%s\n' "$body" > "$dir/.claude/scripts/loop-event.sh"
  chmod +x "$dir/.claude/scripts"/*.sh
  printf '%s\n' "$dir"
}

fake_bin() {
  # $1=fixture root $2=binary name $3=script body -> installs bin/$2 on that fixture's PATH dir
  local dir="$1" name="$2" body="$3"
  printf '%s\n' "$body" > "$dir/bin/$name"
  chmod +x "$dir/bin/$name"
}

run_daemon_once() {
  # $1=fixture root; runs loop-daemon.sh for exactly one iteration.
  ( cd "$1" && PATH="$1/bin:/usr/bin:/bin" LOOP_DAEMON_MAX_ITERATIONS=1 LOOP_DAEMON_SLEEP_FAST=0 LOOP_DAEMON_SLEEP_WATCH=0 LOOP_DAEMON_SLEEP_IDLE=0 LOOP_DAEMON_SLEEP_FALLBACK=0 bash .claude/scripts/loop-daemon.sh )
}

# ---------------------------------------------------------------------------
# 1. action=none: fake loop-event.sh reports nothing actionable. Assert the
#    ledger file is never created/written and no marker any stub would leave
#    behind exists — i.e. ZERO drivers spawned. Note there is deliberately NO
#    'claude' stub installed for this scenario either: if loop-daemon.sh ever
#    tried to spawn one on action=none, the whole run would blow up with
#    "command not found" instead of quietly passing.
# ---------------------------------------------------------------------------
dir1="$(new_fixture scenario1 '#!/usr/bin/env bash
echo "cadence=IDLE cron=*/15 * * * *"
echo "loop-event: action=none"
exit 0')"
run_daemon_once "$dir1" >/dev/null 2>&1
check "scenario 1 (action=none): no ledger file was created" [ ! -f "$dir1/.claude/state/loop-runs.log" ]

# ---------------------------------------------------------------------------
# 2. Broken tick (loop-event.sh exits non-zero): must not spawn a driver
#    either, same as action=none.
# ---------------------------------------------------------------------------
dir2="$(new_fixture scenario2 '#!/usr/bin/env bash
echo "cadence=WATCH cron=*/5 * * * *"
echo "some diagnostic on a broken tick" >&2
exit 1')"
run_daemon_once "$dir2" >/dev/null 2>&1
check "scenario 2 (broken tick): no ledger file was created" [ ! -f "$dir2/.claude/state/loop-runs.log" ]

# ---------------------------------------------------------------------------
# 3. action=advance issue=N: fake claude/setsid/timeout stubs record they ran
#    and emit a fake --output-format json line with a session_id; assert the
#    driver stub actually ran, and the ledger line has the right shape.
# ---------------------------------------------------------------------------
prompt3_dir="$work/scenario3-support"
mkdir -p "$prompt3_dir"
printf 'Run the ADVANCE step of the autonomous PR loop for issue #55.\n' > "$prompt3_dir/prompt.txt"
dir3="$(new_fixture scenario3 "#!/usr/bin/env bash
echo 'cadence=FAST cron=* * * * *'
echo 'loop-event: action=advance issue=55'
echo 'loop-event: model=sonnet'
echo 'loop-event: prompt-file=$prompt3_dir/prompt.txt'
exit 0")"
fake_bin "$dir3" setsid '#!/usr/bin/env bash
# Real setsid re-execs its argv; this stub just execs straight through so the
# fake timeout/claude below still run, but records that it was invoked first.
echo "setsid-ran" >> "'"$dir3"'/setsid.marker"
exec "$@"'
fake_bin "$dir3" timeout '#!/usr/bin/env bash
echo "timeout-ran args=$*" >> "'"$dir3"'/timeout.marker"
# Drop the leading --kill-after=... and the duration positional, exec the rest.
shift # --kill-after=30s
shift # duration (e.g. 90m)
exec "$@"'
fake_bin "$dir3" claude '#!/usr/bin/env bash
echo "claude-ran args=$*" >> "'"$dir3"'/claude.marker"
echo "{\"session_id\":\"sess-fixture-55\",\"result\":\"ok\"}"
exit 0'
run_daemon_once "$dir3" >/dev/null 2>&1
check "scenario 3 (advance): setsid stub was invoked" [ -f "$dir3/setsid.marker" ]
check "scenario 3: timeout stub was invoked" [ -f "$dir3/timeout.marker" ]
check "scenario 3: claude stub was invoked" [ -f "$dir3/claude.marker" ]
check "scenario 3: claude stub received the prompt text" bash -c 'grep -qF "issue #55" "$1"' _ "$dir3/claude.marker"
ledger3="$dir3/.claude/state/loop-runs.log"
check "scenario 3: exactly one ledger line was appended" [ "$(wc -l < "$ledger3" 2>/dev/null || echo 0)" -eq 1 ]
check "scenario 3: ledger line has pid=/session=/verdict=/ts=/result= fields" bash -c '
  grep -Eq "^pid=[0-9]+ session=sess-fixture-55 verdict=advance issue=55 ts=[0-9T:Z-]+ result=exit rc=0$" "$1"
' _ "$ledger3"
check "scenario 3: prompt file was cleaned up after the driver ran" [ ! -f "$prompt3_dir/prompt.txt" ]

# ---------------------------------------------------------------------------
# 4. action=feedback pr=N: same driver path, different verdict text, session
#    id missing from the (malformed) driver output -> ledger records 'unknown'.
# ---------------------------------------------------------------------------
prompt4_dir="$work/scenario4-support"
mkdir -p "$prompt4_dir"
printf 'Run the ADDRESS FEEDBACK step for PR #9.\n' > "$prompt4_dir/prompt.txt"
dir4="$(new_fixture scenario4 "#!/usr/bin/env bash
echo 'cadence=FAST cron=* * * * *'
echo 'loop-event: action=feedback pr=9'
echo 'loop-event: model=sonnet'
echo 'loop-event: prompt-file=$prompt4_dir/prompt.txt'
exit 0")"
fake_bin "$dir4" setsid '#!/usr/bin/env bash
exec "$@"'
fake_bin "$dir4" timeout '#!/usr/bin/env bash
shift; shift
exec "$@"'
fake_bin "$dir4" claude '#!/usr/bin/env bash
echo "not valid json output, no session_id here"
exit 0'
run_daemon_once "$dir4" >/dev/null 2>&1
ledger4="$dir4/.claude/state/loop-runs.log"
check "scenario 4 (feedback, no parseable session_id): ledger records session=unknown" bash -c '
  grep -Eq "^pid=[0-9]+ session=unknown verdict=feedback pr=9 ts=[0-9T:Z-]+ result=exit rc=0$" "$1"
' _ "$ledger4"

# ---------------------------------------------------------------------------
# 5. Driver timeout: fake timeout stub exits 124 (as GNU timeout does on a
#    real kill) without ever invoking claude; ledger must record
#    result=timeout rc=124.
# ---------------------------------------------------------------------------
prompt5_dir="$work/scenario5-support"
mkdir -p "$prompt5_dir"
printf 'Run the ADVANCE step for issue #3.\n' > "$prompt5_dir/prompt.txt"
dir5="$(new_fixture scenario5 "#!/usr/bin/env bash
echo 'cadence=FAST cron=* * * * *'
echo 'loop-event: action=advance issue=3'
echo 'loop-event: model=sonnet'
echo 'loop-event: prompt-file=$prompt5_dir/prompt.txt'
exit 0")"
fake_bin "$dir5" setsid '#!/usr/bin/env bash
exec "$@"'
fake_bin "$dir5" timeout '#!/usr/bin/env bash
# Simulate a real timeout: the wrapped command never gets to run.
exit 124'
fake_bin "$dir5" claude '#!/usr/bin/env bash
echo "claude-should-not-run" >> "'"$dir5"'/claude.should-not-run"
exit 0'
run_daemon_once "$dir5" >/dev/null 2>&1
ledger5="$dir5/.claude/state/loop-runs.log"
check "scenario 5 (timeout): ledger records result=timeout rc=124" bash -c '
  grep -Eq "^pid=[0-9]+ session=unknown verdict=advance issue=3 ts=[0-9T:Z-]+ result=timeout rc=124$" "$1"
' _ "$ledger5"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-daemon.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-daemon.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
