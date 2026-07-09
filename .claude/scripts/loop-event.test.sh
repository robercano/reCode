#!/usr/bin/env bash
# loop-event.test.sh — offline smoke test for loop-event.sh (issue #102).
#
# loop-event.sh's job is: run loop-tick.sh, parse its LAST-line verdict, and
# print a `loop-event: ...` decision block WITHOUT ever touching claude,
# setsid, or timeout itself. So this test builds a throwaway
# .claude/scripts/ directory containing the REAL loop-event.sh +
# resolve-roots.sh next to a FAKE loop-tick.sh that prints canned, scripted
# output — and deliberately does NOT put a `claude` binary anywhere on PATH.
# If loop-event.sh ever tried to spawn a driver directly, every scenario
# below would fail with "command not found" instead of the assertions it
# actually makes — that absence is itself part of the "action=none spawns
# zero drivers" contract this test enforces for ALL verdicts, not just none.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/loop-event.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
loop_event_src="$script_dir/loop-event.sh"
resolve_roots_src="$script_dir/resolve-roots.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/loop-event-test.XXXXXX")"
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
# fake_tick_out is the exact stdout+verdict the corresponding real loop-tick.sh
# would print (last line = the verdict); fake_tick_rc is its exit code.
new_fixture() {
  local name="$1" fake_tick_out="$2" fake_tick_rc="${3:-0}"
  local dir="$work/$name/.claude/scripts"
  mkdir -p "$dir" "$work/$name/.claude/state"
  cp "$loop_event_src" "$dir/loop-event.sh"
  cp "$resolve_roots_src" "$dir/resolve-roots.sh"
  cat > "$dir/loop-tick.sh" <<EOF
#!/usr/bin/env bash
cat <<'TICK'
$fake_tick_out
TICK
exit $fake_tick_rc
EOF
  chmod +x "$dir"/*.sh
  # Deliberately NO 'claude', 'setsid', or 'timeout' anywhere on this fixture's
  # PATH — loop-event.sh must never need them.
  printf '%s\n' "$work/$name"
}

run_event() {
  # $1 = fixture project root. Run with a PATH stripped of this shell's own
  # dirs so a stray 'claude'/'timeout' on the real machine can't mask a bug.
  ( cd "$1" && PATH="/usr/bin:/bin" bash .claude/scripts/loop-event.sh )
}

last_line() { tail -1; }

# ---------------------------------------------------------------------------
# 1. action=none -> no prompt-file, no driver spawned, exit 0.
# ---------------------------------------------------------------------------
dir1="$(new_fixture scenario1 'cadence=IDLE cron=*/15 * * * *
action=none')"
out1="$(run_event "$dir1")"; rc1=$?
check "scenario 1 (action=none): exits 0" [ "$rc1" -eq 0 ]
check "scenario 1: emits loop-event: action=none" bash -c 'printf "%s\n" "$1" | grep -qxF "loop-event: action=none"' _ "$out1"
check "scenario 1: emits NO prompt-file line" bash -c '! printf "%s\n" "$1" | grep -q "^loop-event: prompt-file="' _ "$out1"
check "scenario 1: no prompt file left on disk" bash -c '! ls "$1"/.claude/state/.loop-event-prompt.* >/dev/null 2>&1' _ "$dir1"

# ---------------------------------------------------------------------------
# 2. action=advance issue=N -> action/model/prompt-file lines, file exists and
#    mentions the issue number; exit 0.
# ---------------------------------------------------------------------------
dir2="$(new_fixture scenario2 'cadence=FAST cron=* * * * *
action=advance issue=42')"
out2="$(run_event "$dir2")"; rc2=$?
check "scenario 2 (advance): exits 0" [ "$rc2" -eq 0 ]
check "scenario 2: emits loop-event: action=advance issue=42" bash -c 'printf "%s\n" "$1" | grep -qxF "loop-event: action=advance issue=42"' _ "$out2"
check "scenario 2: emits a model= line (default sonnet)" bash -c 'printf "%s\n" "$1" | grep -qxF "loop-event: model=sonnet"' _ "$out2"
pf2="$(printf '%s\n' "$out2" | sed -n 's/^loop-event: prompt-file=//p')"
check "scenario 2: prompt-file line points at a real file" bash -c '[ -n "$1" ] && [ -f "$1" ]' _ "$pf2"
check "scenario 2: prompt file mentions issue #42" bash -c 'grep -q "issue #42" "$1"' _ "$pf2"
check "scenario 2: prompt file says ADVANCE, not feedback" bash -c 'grep -q "ADVANCE step" "$1"' _ "$pf2"

# ---------------------------------------------------------------------------
# 3. action=feedback pr=N -> same contract, feedback wording, LOOP_MODEL honored.
# ---------------------------------------------------------------------------
dir3="$(new_fixture scenario3 'cadence=FAST cron=* * * * *
action=feedback pr=7')"
out3="$(cd "$dir3" && PATH="/usr/bin:/bin" LOOP_MODEL=opus bash .claude/scripts/loop-event.sh)"; rc3=$?
check "scenario 3 (feedback): exits 0" [ "$rc3" -eq 0 ]
check "scenario 3: emits loop-event: action=feedback pr=7" bash -c 'printf "%s\n" "$1" | grep -qxF "loop-event: action=feedback pr=7"' _ "$out3"
check "scenario 3: LOOP_MODEL is honored (model=opus)" bash -c 'printf "%s\n" "$1" | grep -qxF "loop-event: model=opus"' _ "$out3"
pf3="$(printf '%s\n' "$out3" | sed -n 's/^loop-event: prompt-file=//p')"
check "scenario 3: prompt file mentions PR #7" bash -c 'grep -q "PR #7" "$1"' _ "$pf3"
check "scenario 3: prompt file says ADDRESS FEEDBACK, and Do NOT merge" bash -c 'grep -q "ADDRESS FEEDBACK" "$1" && grep -q "Do NOT merge" "$1"' _ "$pf3"

# ---------------------------------------------------------------------------
# 4. Garbage verdict line -> non-zero exit, action=none fallback line, no
#    prompt-file (never spawns on a verdict it can't parse).
# ---------------------------------------------------------------------------
dir4="$(new_fixture scenario4 'cadence=IDLE cron=*/15 * * * *
action=something-else')"
out4="$(run_event "$dir4")"; rc4=$?
check "scenario 4 (garbage verdict): exits non-zero" [ "$rc4" -ne 0 ]
check "scenario 4: falls back to loop-event: action=none" bash -c 'printf "%s\n" "$1" | grep -qxF "loop-event: action=none"' _ "$out4"
check "scenario 4: no prompt-file line emitted" bash -c '! printf "%s\n" "$1" | grep -q "^loop-event: prompt-file="' _ "$out4"

# ---------------------------------------------------------------------------
# 5. loop-tick.sh itself fails (nonzero exit) -> loop-event.sh propagates
#    non-zero, still ends on action=none, never spawns.
# ---------------------------------------------------------------------------
dir5="$(new_fixture scenario5 'error: network blip' 3)"
out5="$(run_event "$dir5")"; rc5=$?
check "scenario 5 (tick failure): exits with the tick's own rc (3)" [ "$rc5" -eq 3 ]
check "scenario 5: falls back to loop-event: action=none" bash -c 'printf "%s\n" "$1" | grep -qxF "loop-event: action=none"' _ "$out5"
check "scenario 5: no prompt-file line emitted" bash -c '! printf "%s\n" "$1" | grep -q "^loop-event: prompt-file="' _ "$out5"

# ---------------------------------------------------------------------------
# 6. GATES_FILE is threaded into the driver prompt's adapter clause (so a
#    spawned agent points every gate.sh call at the right adapter).
# ---------------------------------------------------------------------------
dir6="$(new_fixture scenario6 'cadence=FAST cron=* * * * *
action=advance issue=9')"
out6="$(cd "$dir6" && PATH="/usr/bin:/bin" GATES_FILE=.claude/self/gates.json bash .claude/scripts/loop-event.sh)"; rc6=$?
pf6="$(printf '%s\n' "$out6" | sed -n 's/^loop-event: prompt-file=//p')"
check "scenario 6 (GATES_FILE): exits 0" [ "$rc6" -eq 0 ]
check "scenario 6: prompt file exports the adapter's GATES_FILE" bash -c 'grep -q "GATES_FILE=.claude/self/gates.json" "$1"' _ "$pf6"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-event.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-event.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
