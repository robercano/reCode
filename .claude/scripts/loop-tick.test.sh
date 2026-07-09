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
# census_out and feedback_out are captured into shell variables and re-printed
# via `printf '%s\n' "$census_out"` / `"$feedback_out"` (loop-tick.sh) — assert
# a BODY line from each fake fixture (not just the "N/4 ..." header banner
# above it) survives verbatim, so silently deleting either printf (which
# would swallow exactly the output a human needs to debug a wrong verdict)
# fails this test loudly. Mutation-checked: removing either printf line from
# loop-tick.sh makes the corresponding check below fail while all the header
# checks above stay green.
check "loop-census.sh full BODY line passed through, not swallowed" bash -c 'printf "%s\n" "$1" | grep -qF "cadence=IDLE cron=*/15 * * * *"' _ "$out1"
check "pr-feedback.sh full BODY line passed through, not swallowed" bash -c 'printf "%s\n" "$1" | grep -qF "9	feat/issue-9-x	owner	2026-01-01T00:00:00Z"' _ "$out4"

# ---------------------------------------------------------------------------
# 8. TTL self-heal: a lock for the SAME issue that's older than LOCK_TTL_SECONDS
#    and STILL advance_ready (no branch ever showed up) must be treated as a
#    crashed spawn — cleared and re-advanced — not kept forever the way a
#    fresh same-issue lock correctly is (scenario 3).
# ---------------------------------------------------------------------------
dir8="$(new_fixture scenario8 'open_prs=0
feedback_prs=0
planned_issues=1
issue=9 branch=none title=Fresh issue
advance_ready=9
cadence=FAST cron=* * * * *' '')"
lock8="$dir8/../state/loop-advance.lock"
mkdir -p "$(dirname "$lock8")"
printf 'issue=9 ts=2020-01-01T00:00:00Z\n' > "$lock8"
out8="$(run_tick "$dir8")"
check "scenario 8 (TTL self-heal): stale same-issue lock past TTL is cleared and re-advanced" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=advance issue=9" ]' _ "$out8"
check "scenario 8: diagnostic cites a crashed spawn (TTL expiry), not just self-heal" bash -c 'printf "%s\n" "$1" | grep -q "crashed spawn"' _ "$out8"
check "scenario 8: lock file now has a FRESH ts, not the stale 2020 one" bash -c '! grep -q "2020-01-01" "$1"' _ "$lock8"

# ---------------------------------------------------------------------------
# 9. Concurrent-tick TOCTOU (issue #81 re-review): two ticks fired back to
#    back, before either has written the lock, must not BOTH pass the
#    check-then-write and both emit action=advance for the same issue — the
#    exact double-spawn bug #81 exists to kill. Fire them as real overlapping
#    background processes against the SAME fixture/state dir; `flock` must
#    serialize the read-check-write so exactly one advances and the other
#    backs off having observed the first tick's lock.
# ---------------------------------------------------------------------------
dir9="$(new_fixture scenario9 'open_prs=0
feedback_prs=0
planned_issues=1
issue=42 branch=none title=Concurrent thing
advance_ready=42
cadence=FAST cron=* * * * *' '')"
outA_file="$work/scenario9.a.out"
outB_file="$work/scenario9.b.out"
run_tick "$dir9" > "$outA_file" &
pidA=$!
run_tick "$dir9" > "$outB_file" &
pidB=$!
wait "$pidA"
wait "$pidB"
verdictA="$(tail -1 "$outA_file")"
verdictB="$(tail -1 "$outB_file")"
advances=0
[ "$verdictA" = "action=advance issue=42" ] && advances=$((advances + 1))
[ "$verdictB" = "action=advance issue=42" ] && advances=$((advances + 1))
check "scenario 9 (concurrent ticks): exactly ONE of two overlapping ticks advances issue=42" bash -c '[ "$1" -eq 1 ]' _ "$advances"
check "scenario 9: the other tick backs off with action=none instead of double-advancing" bash -c '[ "$1" = "action=none" ] || [ "$2" = "action=none" ]' _ "$verdictA" "$verdictB"

# ---------------------------------------------------------------------------
# 10. Tick record (issue #85): every run appends exactly ONE JSONL line to
#     CLAUDE_TICKS_FILE with the expected fields, and — critically — writing
#     that record never disturbs the invariant that the verdict stays the
#     LAST line of stdout (the daemon/tick parser reads the last line).
# ---------------------------------------------------------------------------
dir10="$(new_fixture scenario10 'open_prs=0
feedback_prs=0
planned_issues=1
issue=55 branch=none title=Tick record thing
advance_ready=55
cadence=FAST cron=* * * * *' '')"
ticks10="$work/scenario10-ticks.jsonl"
out10="$(CLAUDE_TICKS_FILE="$ticks10" run_tick "$dir10")"
check "scenario 10: verdict is still the LAST stdout line when tick recording is on" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=advance issue=55" ]' _ "$out10"
check "scenario 10: tick record file has exactly 1 line" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 1 ]' _ "$ticks10"
check "scenario 10: tick record is valid JSON with the expected fields" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.verdict !== "action=advance issue=55") throw new Error("verdict mismatch: " + JSON.stringify(obj));
  if (obj.action !== "advance") throw new Error("action mismatch: " + JSON.stringify(obj));
  if (obj.issue !== "55") throw new Error("issue mismatch: " + JSON.stringify(obj));
  if (obj.cadence !== "FAST") throw new Error("cadence mismatch: " + JSON.stringify(obj));
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(obj.ts)) throw new Error("ts not ISO-8601 UTC: " + obj.ts);
' "$ticks10"

# action=none tick record: issue/pr must serialize as empty strings.
dir11="$(new_fixture scenario11 'open_prs=0
feedback_prs=0
planned_issues=0
advance_ready=none
cadence=IDLE cron=*/15 * * * *' '')"
ticks11="$work/scenario11-ticks.jsonl"
out11="$(CLAUDE_TICKS_FILE="$ticks11" run_tick "$dir11")"
check "scenario 11: verdict is still the LAST stdout line for action=none" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=none" ]' _ "$out11"
check "scenario 11: action=none tick record parses issue/pr as empty" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.action !== "none") throw new Error("action mismatch: " + JSON.stringify(obj));
  if (obj.issue !== "" || obj.pr !== "") throw new Error("expected empty issue/pr, got " + JSON.stringify(obj));
' "$ticks11"

# action=feedback tick record: pr number captured, cadence round-trips.
dir12="$(new_fixture scenario12 'open_prs=0
feedback_prs=1
planned_issues=0
advance_ready=none
cadence=WATCH cron=*/5 * * * *' "$(printf '3\tfeat/issue-3-x\towner\t2026-01-01T00:00:00Z')")"
ticks12="$work/scenario12-ticks.jsonl"
out12="$(CLAUDE_TICKS_FILE="$ticks12" run_tick "$dir12")"
check "scenario 12: verdict is still the LAST stdout line for action=feedback" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=feedback pr=3" ]' _ "$out12"
check "scenario 12: action=feedback tick record captures pr number and cadence" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.action !== "feedback") throw new Error("action mismatch: " + JSON.stringify(obj));
  if (obj.pr !== "3") throw new Error("pr mismatch: " + JSON.stringify(obj));
  if (obj.cadence !== "WATCH") throw new Error("cadence mismatch: " + JSON.stringify(obj));
' "$ticks12"

# ---------------------------------------------------------------------------
# 11. Rotation: LOOP_TICKS_MAX_LINES caps the tick log to the last N lines
#     across repeated ticks (mirrors log-event.sh's rotation, log-event.test.sh
#     lines ~87-115).
#
#     Each iteration below gets a DISTINCT advance_ready/issue so every
#     retained JSONL line is byte-DIFFERENT (not the same static fixture
#     replayed N times) -- otherwise line-count + JSON-validity checks alone
#     cannot tell "kept the last N" apart from e.g. "kept the FIRST N" or any
#     other N lines. We assert the exact retained `issue` values, in order,
#     mirroring log-event.test.sh's `want` array.
# ---------------------------------------------------------------------------
ticks13="$work/scenario13-ticks.jsonl"
for i in 1 2 3 4 5 6 7; do
  dir13="$(new_fixture "scenario13-$i" "open_prs=0
feedback_prs=0
planned_issues=1
issue=$i branch=none title=Rotation issue $i
advance_ready=$i
cadence=FAST cron=* * * * *" '')"
  LOOP_TICKS_MAX_LINES=3 CLAUDE_TICKS_FILE="$ticks13" run_tick "$dir13" >/dev/null
done
check "scenario 13: rotation caps the tick log to exactly 3 lines" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 3 ]' _ "$ticks13"
check "scenario 13: every remaining line is still valid JSON after rotation" node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
  for (const l of lines) JSON.parse(l);
' "$ticks13"
check "scenario 13: rotation keeps the LAST 3 ticks (issues 5,6,7), in order" node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
  const issues = lines.map((l) => JSON.parse(l).issue);
  const want = ["5", "6", "7"];
  if (JSON.stringify(issues) !== JSON.stringify(want)) {
    throw new Error("got " + JSON.stringify(issues) + " want " + JSON.stringify(want));
  }
' "$ticks13"

# Rotation boundary: writing EXACTLY LOOP_TICKS_MAX_LINES ticks must leave
# exactly that many lines -- i.e. rotation must not trigger (or drop
# anything) right at the boundary, only once the count exceeds the cap.
ticks13b="$work/scenario13b-ticks.jsonl"
for i in 1 2 3; do
  dir13b="$(new_fixture "scenario13b-$i" "open_prs=0
feedback_prs=0
planned_issues=1
issue=$i branch=none title=Boundary issue $i
advance_ready=$i
cadence=FAST cron=* * * * *" '')"
  LOOP_TICKS_MAX_LINES=3 CLAUDE_TICKS_FILE="$ticks13b" run_tick "$dir13b" >/dev/null
done
check "scenario 13b: writing exactly LOOP_TICKS_MAX_LINES ticks leaves exactly that many lines" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 3 ]' _ "$ticks13b"
check "scenario 13b: boundary case keeps all 3 ticks in order (no spurious drop)" node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
  const issues = lines.map((l) => JSON.parse(l).issue);
  const want = ["1", "2", "3"];
  if (JSON.stringify(issues) !== JSON.stringify(want)) {
    throw new Error("got " + JSON.stringify(issues) + " want " + JSON.stringify(want));
  }
' "$ticks13b"

# ---------------------------------------------------------------------------
# 12. Best-effort: tick recording must never disturb the verdict or exit
#     status, even when the ticks file cannot be written at all (its parent
#     dir path collides with a plain file, so mkdir -p fails).
# ---------------------------------------------------------------------------
dir14="$(new_fixture scenario14 'open_prs=0
feedback_prs=0
planned_issues=0
advance_ready=none
cadence=IDLE cron=*/15 * * * *' '')"
blocker="$work/scenario14-blocker"
: > "$blocker"   # a plain FILE where the ticks file's PARENT DIR needs to be
out14="$(CLAUDE_TICKS_FILE="$blocker/loop-ticks.jsonl" run_tick "$dir14" 2>/dev/null)"
rc14=$?
check "scenario 14: tick-record write failure never changes the exit status" [ "$rc14" -eq 0 ]
check "scenario 14: verdict is still the LAST stdout line despite the write failure" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=none" ]' _ "$out14"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-tick.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-tick.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
