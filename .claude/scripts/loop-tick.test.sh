#!/usr/bin/env bash
# loop-tick.test.sh — offline smoke test for loop-tick.sh (issue #81).
#
# loop-tick.sh's own logic is just: run its five sibling step scripts, parse
# census/pr-feedback/pr-ci-fix output, and emit one verdict line (plus the
# spawn lock). So this test doesn't touch real gh/network — it builds a
# throwaway .claude/scripts/ directory containing the REAL loop-tick.sh +
# resolve-roots.sh next to FAKE loop-census.sh / notify-poll.sh /
# merge-ready.sh / pr-feedback.sh / pr-ci-fix.sh (issue #96) that print
# canned, scripted output, then asserts the final verdict line and the
# spawn-lock file behavior for each scenario.
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
# fake_census / fake_feedback / fake_cifix / fake_commentfix / fake_rebase are
# the exact stdout the corresponding real script would print; notify-poll.sh
# and merge-ready.sh are stubbed to just print a marker line (their output is
# passed through, never parsed). fake_cifix/fake_commentfix/fake_rebase
# default to empty (no candidates) so every existing 3/4/5-arg call site keeps
# working unchanged.
new_fixture() {
  local name="$1" fake_census="$2" fake_feedback="$3" fake_cifix="${4:-}" fake_commentfix="${5:-}" fake_rebase="${6:-}"
  local dir="$work/$name/.claude/scripts"
  mkdir -p "$dir" "$work/$name/.claude/state" 2>/dev/null
  rm -rf "$work/$name/.claude/state"   # loop-tick.sh must mkdir -p it itself
  cp "$loop_tick_src" "$dir/loop-tick.sh"
  cp "$resolve_roots_src" "$dir/resolve-roots.sh"
  # needs-human.sh/notify.sh (issue #99): loop-tick.sh sources needs-human.sh
  # unconditionally if present; copy the REAL implementations so escalation
  # scenarios exercise the real seam (gh calls still land in the fixture's
  # own fake/logging bot-gh.sh, never real network).
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
  cat > "$dir/pr-ci-fix.sh" <<EOF
#!/usr/bin/env bash
cat <<'CIFIX'
$fake_cifix
CIFIX
EOF
  cat > "$dir/pr-comment-fix.sh" <<EOF
#!/usr/bin/env bash
cat <<'COMMENTFIX'
$fake_commentfix
COMMENTFIX
EOF
  cat > "$dir/pr-rebase.sh" <<EOF
#!/usr/bin/env bash
cat <<'REBASE'
$fake_rebase
REBASE
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
# 7. All seven step scripts' full output is preserved (never swallowed).
# ---------------------------------------------------------------------------
check "all seven labeled step headers appear in the tick's output" bash -c '
  printf "%s\n" "$1" | grep -q "1/7 loop-census.sh" &&
  printf "%s\n" "$1" | grep -q "2/7 notify-poll.sh" &&
  printf "%s\n" "$1" | grep -q "3/7 merge-ready.sh" &&
  printf "%s\n" "$1" | grep -q "4/7 pr-feedback.sh" &&
  printf "%s\n" "$1" | grep -q "5/7 pr-comment-fix.sh" &&
  printf "%s\n" "$1" | grep -q "6/7 pr-ci-fix.sh" &&
  printf "%s\n" "$1" | grep -q "7/7 pr-rebase.sh"
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
# 12b. CI-fix candidate present, no feedback, nothing advance_ready -> picked
#      as action=ci-fix pr=N, and (mirroring scenario 4's "no spawn lock" for
#      feedback) never writes the advance spawn lock (issue #96).
# ---------------------------------------------------------------------------
dir12b="$(new_fixture scenario12b 'open_prs=1
feedback_prs=0
planned_issues=0
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '' "$(printf '9	feat/issue-9-x	build	sha9
4	feat/issue-4-y	build	sha4')")"
out12b="$(run_tick "$dir12b")"
check "scenario 12b (ci-fix, lowest-numbered PR wins): verdict is action=ci-fix pr=4" bash -c '[ "$(printf "%s
" "$1" | tail -1)" = "action=ci-fix pr=4" ]' _ "$out12b"
check "scenario 12b: no spawn lock written (advance never attempted)" [ ! -e "$dir12b/../state/loop-advance.lock" ]

# ---------------------------------------------------------------------------
# 12c. CI-fix wins over an ALSO-ready advance (issue #96 precedence: ci-fix >
#      advance), same shape as scenario 4's feedback-beats-advance check.
# ---------------------------------------------------------------------------
dir12c="$(new_fixture scenario12c 'open_prs=0
feedback_prs=0
planned_issues=1
issue=7 branch=none title=Some issue
advance_ready=7
cadence=FAST cron=* * * * *' '' "$(printf '11	feat/issue-11-x	build	sha11')")"
out12c="$(run_tick "$dir12c")"
check "scenario 12c (ci-fix beats an also-ready advance): verdict is action=ci-fix pr=11" bash -c '[ "$(printf "%s
" "$1" | tail -1)" = "action=ci-fix pr=11" ]' _ "$out12c"
check "scenario 12c: no spawn lock written (advance never attempted)" [ ! -e "$dir12c/../state/loop-advance.lock" ]

# action=ci-fix tick record: pr number captured, cadence round-trips.
dir12d="$(new_fixture scenario12d 'open_prs=1
feedback_prs=0
planned_issues=0
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '' "$(printf '5	feat/issue-5-x	build	sha5')")"
ticks12d="$work/scenario12d-ticks.jsonl"
out12d="$(CLAUDE_TICKS_FILE="$ticks12d" run_tick "$dir12d")"
check "scenario 12d: verdict is still the LAST stdout line for action=ci-fix" bash -c '[ "$(printf "%s
" "$1" | tail -1)" = "action=ci-fix pr=5" ]' _ "$out12d"
check "scenario 12d: action=ci-fix tick record captures pr number and cadence" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.action !== "ci-fix") throw new Error("action mismatch: " + JSON.stringify(obj));
  if (obj.pr !== "5") throw new Error("pr mismatch: " + JSON.stringify(obj));
  if (obj.cadence !== "WATCH") throw new Error("cadence mismatch: " + JSON.stringify(obj));
' "$ticks12d"

# ---------------------------------------------------------------------------
# 12e. Comment-fix candidate present, no feedback, nothing advance_ready, no
#      ci-fix -> picked as action=comment-fix pr=N (issue #96 part 2), lowest-
#      numbered PR wins among comment-fix candidates, and (mirroring scenario
#      12b's "no spawn lock" for ci-fix) never writes the advance spawn lock.
# ---------------------------------------------------------------------------
dir12e="$(new_fixture scenario12e 'open_prs=1
feedback_prs=0
planned_issues=0
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '' '' "$(printf '9\tfeat/issue-9-x\tTABC:1\tsha9
4\tfeat/issue-4-y\tTDEF:1\tsha4')")"
out12e="$(run_tick "$dir12e")"
check "scenario 12e (comment-fix, lowest-numbered PR wins): verdict is action=comment-fix pr=4" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=comment-fix pr=4" ]' _ "$out12e"
check "scenario 12e: no spawn lock written (advance never attempted)" [ ! -e "$dir12e/../state/loop-advance.lock" ]

# ---------------------------------------------------------------------------
# 12f. Comment-fix wins over an ALSO-ready ci-fix AND an also-ready advance
#      (issue #96 part 2 precedence: comment-fix > ci-fix > advance).
# ---------------------------------------------------------------------------
dir12f="$(new_fixture scenario12f 'open_prs=0
feedback_prs=0
planned_issues=1
issue=7 branch=none title=Some issue
advance_ready=7
cadence=FAST cron=* * * * *' '' "$(printf '20\tfeat/issue-20-x\tbuild\tsha20')" "$(printf '11\tfeat/issue-11-x\tTABC:1\tsha11')")"
out12f="$(run_tick "$dir12f")"
check "scenario 12f (comment-fix beats an also-ready ci-fix and advance): verdict is action=comment-fix pr=11" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=comment-fix pr=11" ]' _ "$out12f"
check "scenario 12f: no spawn lock written (advance never attempted)" [ ! -e "$dir12f/../state/loop-advance.lock" ]

# ---------------------------------------------------------------------------
# 12g. Feedback still wins over an also-ready comment-fix (issue #96 part 2
#      precedence: feedback > comment-fix), same shape as scenario 4's
#      feedback-beats-advance check.
# ---------------------------------------------------------------------------
dir12g="$(new_fixture scenario12g 'open_prs=1
feedback_prs=1
planned_issues=0
advance_ready=none
cadence=FAST cron=* * * * *' "$(printf '3\tfeat/issue-3-x\towner\t2026-01-01T00:00:00Z')" '' "$(printf '6\tfeat/issue-6-x\tTABC:1\tsha6')")"
out12g="$(run_tick "$dir12g")"
check "scenario 12g (feedback beats an also-ready comment-fix): verdict is action=feedback pr=3" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=feedback pr=3" ]' _ "$out12g"

# action=comment-fix tick record: pr number captured, cadence round-trips.
dir12h="$(new_fixture scenario12h 'open_prs=1
feedback_prs=0
planned_issues=0
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '' '' "$(printf '8\tfeat/issue-8-x\tTABC:1\tsha8')")"
ticks12h="$work/scenario12h-ticks.jsonl"
out12h="$(CLAUDE_TICKS_FILE="$ticks12h" run_tick "$dir12h")"
check "scenario 12h: verdict is still the LAST stdout line for action=comment-fix" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=comment-fix pr=8" ]' _ "$out12h"
check "scenario 12h: action=comment-fix tick record captures pr number and cadence" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.action !== "comment-fix") throw new Error("action mismatch: " + JSON.stringify(obj));
  if (obj.pr !== "8") throw new Error("pr mismatch: " + JSON.stringify(obj));
  if (obj.cadence !== "WATCH") throw new Error("cadence mismatch: " + JSON.stringify(obj));
' "$ticks12h"

# ---------------------------------------------------------------------------
# 12i. Rebase candidate present, no feedback/comment-fix/ci-fix, nothing
#      advance_ready -> picked as action=rebase pr=N (issue #96 part 3),
#      lowest-numbered PR wins among rebase candidates, and (mirroring
#      scenario 12b's "no spawn lock" for ci-fix) never writes the advance
#      spawn lock.
# ---------------------------------------------------------------------------
dir12i="$(new_fixture scenario12i 'open_prs=1
feedback_prs=0
planned_issues=0
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '' '' '' "$(printf '9\tfeat/issue-9-x\tsha9\tbase9\t1
4\tfeat/issue-4-y\tsha4\tbase4\t1')")"
out12i="$(run_tick "$dir12i")"
check "scenario 12i (rebase, lowest-numbered PR wins): verdict is action=rebase pr=4" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=rebase pr=4" ]' _ "$out12i"
check "scenario 12i: no spawn lock written (advance never attempted)" [ ! -e "$dir12i/../state/loop-advance.lock" ]

# ---------------------------------------------------------------------------
# 12j. Rebase wins over an ALSO-ready advance (issue #96 part 3 precedence:
#      rebase > advance), same shape as scenario 12c's ci-fix-beats-advance
#      check.
# ---------------------------------------------------------------------------
dir12j="$(new_fixture scenario12j 'open_prs=0
feedback_prs=0
planned_issues=1
issue=7 branch=none title=Some issue
advance_ready=7
cadence=FAST cron=* * * * *' '' '' '' "$(printf '11\tfeat/issue-11-x\tsha11\tbase11\t1')")"
out12j="$(run_tick "$dir12j")"
check "scenario 12j (rebase beats an also-ready advance): verdict is action=rebase pr=11" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=rebase pr=11" ]' _ "$out12j"
check "scenario 12j: no spawn lock written (advance never attempted)" [ ! -e "$dir12j/../state/loop-advance.lock" ]

# ---------------------------------------------------------------------------
# 12k. CI-fix wins over an ALSO-ready rebase (issue #96 part 3 precedence:
#      ci-fix > rebase), same shape as scenario 12f's comment-fix-beats-ci-fix
#      check.
# ---------------------------------------------------------------------------
dir12k="$(new_fixture scenario12k 'open_prs=0
feedback_prs=0
planned_issues=1
issue=7 branch=none title=Some issue
advance_ready=7
cadence=FAST cron=* * * * *' '' "$(printf '20\tfeat/issue-20-x\tbuild\tsha20')" '' "$(printf '11\tfeat/issue-11-x\tsha11\tbase11\t1')")"
out12k="$(run_tick "$dir12k")"
check "scenario 12k (ci-fix beats an also-ready rebase and advance): verdict is action=ci-fix pr=20" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=ci-fix pr=20" ]' _ "$out12k"
check "scenario 12k: no spawn lock written (advance never attempted)" [ ! -e "$dir12k/../state/loop-advance.lock" ]

# action=rebase tick record: pr number captured, cadence round-trips.
dir12l="$(new_fixture scenario12l 'open_prs=1
feedback_prs=0
planned_issues=0
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '' '' '' "$(printf '15\tfeat/issue-15-x\tsha15\tbase15\t2')")"
ticks12l="$work/scenario12l-ticks.jsonl"
out12l="$(CLAUDE_TICKS_FILE="$ticks12l" run_tick "$dir12l")"
check "scenario 12l: verdict is still the LAST stdout line for action=rebase" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=rebase pr=15" ]' _ "$out12l"
check "scenario 12l: action=rebase tick record captures pr number and cadence" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.action !== "rebase") throw new Error("action mismatch: " + JSON.stringify(obj));
  if (obj.pr !== "15") throw new Error("pr mismatch: " + JSON.stringify(obj));
  if (obj.cadence !== "WATCH") throw new Error("cadence mismatch: " + JSON.stringify(obj));
' "$ticks12l"

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

# ---------------------------------------------------------------------------
# 13. Stall/resume machinery (issue #98). An in_flight candidate that census
# flags stalled=N (or whose branch classifies as half-done debris) must get a
# `action=resume issue=N branch=...` verdict instead of a flat refusal, bounded
# to 2 resume attempts before escalating to needs-human on the 3rd stall.
# ---------------------------------------------------------------------------

# Like new_fixture, but also copies in the REAL log-event.sh (issue #98
# telemetry) -- needed only by scenarios that actually reach the stall/resume
# path; every earlier scenario above never calls log_loop_event at all
# (in_flight-without-stall short-circuits before it), so this never disturbs
# them.
new_fixture_with_events() {
  local dir
  dir="$(new_fixture "$@")"
  cp "$script_dir/log-event.sh" "$dir/log-event.sh"
  chmod +x "$dir/log-event.sh"
  printf '%s\n' "$dir"
}

# Scenario 15: census's own stall clock (stalled=42) fires -> 1st resume
# attempt. Verdict points at the existing branch; resume-attempts.json now
# records count=1; both a stall-detected and a resume-attempt event land in
# events.jsonl.
#
# NOTE (post-review correction): advance_ready is "none" here, NOT "42" --
# real loop-census.sh can NEVER report the SAME issue as both advance_ready
# (requires branch=none) and in_flight (requires branch!=none); the earlier
# version of this fixture set advance_ready=42 alongside in_flight=42, which
# is a combination the real census cannot produce and made the resume path
# unreachable in production (it was gated on advance_ready being found
# inside in_flight_issues). See scenario 21 below for an end-to-end
# reachability check driven by the REAL loop-census.sh.
ticks15_events="$work/scenario15-events.jsonl"
dir15="$(new_fixture_with_events scenario15 'open_prs=0
feedback_prs=0
planned_issues=1
issue=42 branch=feat/issue-42-x title=Stalled thing
in_flight=42
stalled=42 age_min=45
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '')"
out15="$(CLAUDE_EVENTS_FILE="$ticks15_events" run_tick "$dir15")"
check "scenario 15 (resume via census stall clock): verdict is action=resume issue=42 branch=feat/issue-42-x" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=resume issue=42 branch=feat/issue-42-x" ]' _ "$out15"
resume15="$dir15/../state/loop-resume-attempts.json"
check "scenario 15: resume-attempts file records count=1, escalated=false for issue 42" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (!j["42"] || j["42"].count !== 1 || j["42"].escalated !== false) throw new Error("got " + JSON.stringify(j));
' "$resume15"
check "scenario 15: stall-detected event logged (task=42)" bash -c 'grep -q "\"phase\":\"stall-detected\"" "$1" && grep -q "\"task\":\"42\"" "$1"' _ "$ticks15_events"
check "scenario 15: resume-attempt event logged" bash -c 'grep -q "\"phase\":\"resume-attempt\"" "$1"' _ "$ticks15_events"
check "scenario 15: no spawn lock written (resume is not a fresh advance)" [ ! -e "$dir15/../state/loop-advance.lock" ]

# Scenario 16: SAME fixture/state, tick fires again while still stalled ->
# 2nd resume attempt (bound not yet exhausted).
out16="$(CLAUDE_EVENTS_FILE="$ticks15_events" run_tick "$dir15")"
check "scenario 16 (2nd resume attempt): verdict is still action=resume issue=42" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=resume issue=42 branch=feat/issue-42-x" ]' _ "$out16"
check "scenario 16: resume-attempts file now records count=2" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (!j["42"] || j["42"].count !== 2 || j["42"].escalated !== false) throw new Error("got " + JSON.stringify(j));
' "$resume15"

# Scenario 17: 3rd stall (count already at 2) -> escalate to needs-human
# instead of resuming again: label create + label add + issue comment (all
# via bot-gh.sh, captured here into a plain log file), escalated:true
# persisted, and an escalated-to-needs-human event logged.
#
# Issue #169: needs-human.sh's label reads/writes now go through `gh api`
# (REST). This stub simulates GitHub's own label state via a marker FILE the
# REST add touches, so the post-add CONFIRM read (issue #169's
# comment-gating invariant) sees the label actually "stuck" and the episode
# comment posts.
gh_calls17="$work/scenario17-gh-calls.log"
label_marker17="$work/scenario17-label.marker"
cat > "$dir15/bot-gh.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_calls17"
case "\$1" in
  api)
    case "\$*" in
      *"-X POST"*"/issues/42/labels --input -")
        touch "$label_marker17"
        ;;
      *"-q .labels[].name"*)
        [ -f "$label_marker17" ] && printf 'needs-human\n'
        ;;
      *) : ;;
    esac
    ;;
  *) : ;;
esac
exit 0
EOF
chmod +x "$dir15/bot-gh.sh"
out17="$(CLAUDE_EVENTS_FILE="$ticks15_events" run_tick "$dir15")"
check "scenario 17 (3rd stall, bound exhausted): verdict is action=none (does not resume again)" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=none" ]' _ "$out17"
check "scenario 17: resume-attempts file now escalated=true (count stays 2)" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (!j["42"] || j["42"].count !== 2 || j["42"].escalated !== true) throw new Error("got " + JSON.stringify(j));
' "$resume15"
check "scenario 17: needs-human label create + label add (REST) + issue comment all dispatched via bot-gh.sh" bash -c '
  grep -qF -- "-X POST repos/acme/repo/labels " "$1" &&
  grep -qF -- "-X POST repos/acme/repo/issues/42/labels --input -" "$1" &&
  grep -q "^issue comment 42 " "$1"
' _ "$gh_calls17"
check "scenario 17: escalated-to-needs-human event logged" bash -c 'grep -q "\"phase\":\"escalated-to-needs-human\"" "$1"' _ "$ticks15_events"

# Scenario 18: a 4th tick, still stalled, AFTER escalation -> must not retry
# automatically anymore (no further gh calls, no further resume).
gh_calls_before18="$(wc -l < "$gh_calls17" | tr -d ' ')"
out18="$(CLAUDE_EVENTS_FILE="$ticks15_events" run_tick "$dir15")"
check "scenario 18 (already escalated): verdict stays action=none" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=none" ]' _ "$out18"
check "scenario 18: diagnostic cites the prior escalation (not a fresh resume)" bash -c 'printf "%s\n" "$1" | grep -q "already escalated to needs-human"' _ "$out18"
check "scenario 18: no additional gh calls were dispatched (stopped retrying automatically)" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq "$2" ]' _ "$gh_calls17" "$gh_calls_before18"

# Scenario 19: debris-based resume (issue #111's classify_debris reused
# verbatim) -- NO census stalled= line at all, but the branch is genuinely
# "half-done" (uncommitted work sitting in the worktree). Needs a REAL git
# repo (loop-daemon.sh's classify_debris/worktree_for_branch shell out to
# `git`) plus the real loop-daemon.sh copied alongside loop-tick.sh.
new_git_backed_fixture() {
  local name="$1" fake_census="$2" fake_feedback="$3"
  local dir
  dir="$(new_fixture_with_events "$name" "$fake_census" "$fake_feedback")"
  cp "$script_dir/loop-daemon.sh" "$dir/loop-daemon.sh"
  chmod +x "$dir/loop-daemon.sh"
  local root_dir="${dir%/.claude/scripts}"
  git -C "$root_dir" init -q -b main
  git -C "$root_dir" config user.email t@e.st
  git -C "$root_dir" config user.name t
  git -C "$root_dir" commit -q --allow-empty -m init
  printf '%s\n' "$dir"
}

dir19="$(new_git_backed_fixture scenario19 'open_prs=0
feedback_prs=0
planned_issues=1
issue=55 branch=feat/issue-55-x title=Debris thing
in_flight=55
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '')"
root19="${dir19%/.claude/scripts}"
# A SEPARATE linked worktree, not the main checkout -- mirrors real production
# topology (an implementer's branch always lives in its own `.claude/worktrees/`
# checkout, distinct from the root's own `.claude/state/`) and avoids tick's
# OWN bookkeeping files (flock/lock/attempts, written into "$root/.claude/state"
# moments before this classify call) being mistaken for a dirty worktree if the
# candidate branch were checked out directly in root instead.
git -C "$root19" branch feat/issue-55-x main
wt19="$work/scenario19-wt"
git -C "$root19" worktree add -q "$wt19" feat/issue-55-x
echo "wip" > "$wt19/scratch.txt"   # uncommitted -> dirty worktree, 0 commits ahead -> half-done
ticks19_events="$work/scenario19-events.jsonl"
out19="$(CLAUDE_EVENTS_FILE="$ticks19_events" run_tick "$dir19")"
check "scenario 19 (resume via half-done debris, no census stall clock): verdict is action=resume issue=55 branch=feat/issue-55-x" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=resume issue=55 branch=feat/issue-55-x" ]' _ "$out19"
check "scenario 19: stall-detected event records debris=half-done" bash -c 'grep -q "debris=half-done" "$1"' _ "$ticks19_events"
resume19="$dir19/../state/loop-resume-attempts.json"
check "scenario 19: resume-attempts file records count=1 for issue 55" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (!j["55"] || j["55"].count !== 1) throw new Error("got " + JSON.stringify(j));
' "$resume19"

# Scenario 20 (negative control): in_flight, no census stall clock, and the
# branch's debris is "publishable" (clean, committed, just no PR yet) rather
# than half-done -- must NOT resume; the plain pre-#98 in_flight refusal
# still applies unchanged.
dir20="$(new_git_backed_fixture scenario20 'open_prs=0
feedback_prs=0
planned_issues=1
issue=66 branch=feat/issue-66-x title=Publishable thing
in_flight=66
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '')"
root20="${dir20%/.claude/scripts}"
# Same separate-worktree topology as scenario 19's fixture above.
git -C "$root20" branch feat/issue-66-x main
wt20="$work/scenario20-wt"
git -C "$root20" worktree add -q "$wt20" feat/issue-66-x
( cd "$wt20" && echo "done" > f.txt && git add f.txt && git -c user.email=t@e.st -c user.name=t commit -q -m work )
out20="$(run_tick "$dir20")"
check "scenario 20 (in_flight, publishable debris, no stall): still refused, no resume" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=none" ]' _ "$out20"
check "scenario 20: diagnostic is the plain pre-#98 in_flight refusal" bash -c 'printf "%s\n" "$1" | grep -qF "is in_flight (a feat/issue-66-* branch already exists with no open PR)"' _ "$out20"
check "scenario 20: no resume-attempts entry created for issue 66" bash -c '! grep -q "\"66\"" "$1" 2>/dev/null' _ "$dir20/../state/loop-resume-attempts.json"

# ---------------------------------------------------------------------------
# 21. Precedence: a FRESH branchless advance candidate (advance_ready=7) still
# wins over a SEPARATE, genuinely stalled in_flight issue (42) in the same
# census snapshot -- matches the documented "fresh advance beats resume"
# precedence and the real invariant that advance_ready and in_flight never
# name the SAME issue (they can, of course, both be populated for DIFFERENT
# issues in one census run).
# ---------------------------------------------------------------------------
dir21="$(new_fixture_with_events scenario21 'open_prs=0
feedback_prs=0
planned_issues=2
issue=7 branch=none title=Fresh branchless issue
issue=42 branch=feat/issue-42-x title=Stalled thing
in_flight=42
stalled=42 age_min=45
advance_ready=7
cadence=FAST cron=* * * * *' '')"
out21="$(run_tick "$dir21")"
check "scenario 21 (fresh advance beats resume): verdict is action=advance issue=7" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=advance issue=7" ]' _ "$out21"
check "scenario 21: no resume-attempts entry created for the stalled-but-deferred issue 42" bash -c '! grep -q "\"42\"" "$1" 2>/dev/null' _ "$dir21/../state/loop-resume-attempts.json"

# ---------------------------------------------------------------------------
# 22. Lowest-numbered-wins: TWO in_flight issues both stalled (30 and 20) with
# no fresh advance candidate -- resume must pick the LOWER-numbered one (20),
# mirroring feedback's "lowest PR wins" rule.
# ---------------------------------------------------------------------------
dir22="$(new_fixture_with_events scenario22 'open_prs=0
feedback_prs=0
planned_issues=2
issue=30 branch=feat/issue-30-x title=Stalled thing higher
issue=20 branch=feat/issue-20-x title=Stalled thing lower
in_flight=30
in_flight=20
stalled=30 age_min=99
stalled=20 age_min=50
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '')"
out22="$(run_tick "$dir22")"
check "scenario 22 (lowest-numbered wins): verdict is action=resume issue=20, not 30" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=resume issue=20 branch=feat/issue-20-x" ]' _ "$out22"

# ---------------------------------------------------------------------------
# 23. Escalated candidate is SKIPPED in favor of a later, not-yet-escalated
# candidate, instead of refusing the whole tick: issue 10 is stalled but
# already escalated (pre-seeded loop-resume-attempts.json); issue 20 is
# ALSO stalled and not yet escalated -- resume must pick 20, and must NOT
# re-touch issue 10's already-escalated state.
# ---------------------------------------------------------------------------
dir23="$(new_fixture_with_events scenario23 'open_prs=0
feedback_prs=0
planned_issues=2
issue=10 branch=feat/issue-10-x title=Already escalated
issue=20 branch=feat/issue-20-x title=Not yet escalated
in_flight=10
in_flight=20
stalled=10 age_min=200
stalled=20 age_min=50
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '')"
resume23="$dir23/../state/loop-resume-attempts.json"
mkdir -p "$(dirname "$resume23")"
cat > "$resume23" <<'EOF'
{ "10": { "count": 2, "escalated": true } }
EOF
out23="$(run_tick "$dir23")"
check "scenario 23 (escalated candidate skipped): verdict is action=resume issue=20, not the already-escalated 10" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=resume issue=20 branch=feat/issue-20-x" ]' _ "$out23"
check "scenario 23: issue 10's escalated state is untouched (still count=2, escalated=true)" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (!j["10"] || j["10"].count !== 2 || j["10"].escalated !== true) throw new Error("got " + JSON.stringify(j));
' "$resume23"
check "scenario 23: issue 20 now has a fresh resume entry (count=1, escalated=false)" node -e '
  const fs = require("fs");
  const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (!j["20"] || j["20"].count !== 1 || j["20"].escalated !== false) throw new Error("got " + JSON.stringify(j));
' "$resume23"

# ---------------------------------------------------------------------------
# 24. BLOCKER 2 regression guard: a resume verdict must NOT charge issue #95's
# advance/feedback dispatch budget (loop-issue-attempts.json) or its daily
# action ceiling -- those are tracked ONLY in the sibling
# loop-resume-attempts.json (already asserted above). Drive a resume verdict
# and assert loop-issue-attempts.json / loop-daily-ceiling.json are BOTH
# left untouched (absent -- this fixture's state dir starts empty).
# ---------------------------------------------------------------------------
dir24="$(new_fixture_with_events scenario24 'open_prs=0
feedback_prs=0
planned_issues=1
issue=88 branch=feat/issue-88-x title=Resume must not charge issue 95 budget
in_flight=88
stalled=88 age_min=60
advance_ready=none
cadence=WATCH cron=*/5 * * * *' '')"
out24="$(run_tick "$dir24")"
check "scenario 24: verdict is action=resume issue=88" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=resume issue=88 branch=feat/issue-88-x" ]' _ "$out24"
check "scenario 24: loop-issue-attempts.json (issue #95's dispatch budget) was never created" [ ! -e "$dir24/../state/loop-issue-attempts.json" ]
check "scenario 24: loop-daily-ceiling.json (issue #95's daily ceiling) was never created" [ ! -e "$dir24/../state/loop-daily-ceiling.json" ]

# ---------------------------------------------------------------------------
# 25. REACHABILITY (the bug this fix closes): drive loop-tick.sh against the
# REAL loop-census.sh (not a hand-fabricated fixture) so the resume path is
# proven reachable through the actual integration, not just a census snapshot
# that respects the invariant by construction. A single planned issue (77)
# already has a real local git branch (so census reports it in_flight, never
# advance_ready -- the SAME mutual exclusivity the earlier fixtures above
# were reworked to respect) and a stale events.jsonl entry old enough to trip
# census's own stall clock (default budget.stall_minutes=30).
#
# SABOTAGE CHECK (do this by hand when reviewing, not asserted by the test
# itself): reverting loop-tick.sh's verdict decision to the old
# `if printf '%s\n' "$in_flight_issues" | grep -qx "$advance_ready"` gate
# makes this scenario's verdict regress to action=none, since advance_ready
# is (correctly, per the real census) "none" and can never equal in_flight's
# "77" -- proving this test is non-vacuous.
# ---------------------------------------------------------------------------
build_real_census_fixture() {
  local name="$1"
  local dir="$work/$name"
  local scripts="$dir/.claude/scripts"
  mkdir -p "$scripts"
  cp "$script_dir/loop-tick.sh" "$scripts/loop-tick.sh"
  cp "$script_dir/loop-census.sh" "$scripts/loop-census.sh"
  cp "$script_dir/resolve-roots.sh" "$scripts/resolve-roots.sh"
  cp "$script_dir/loop-daemon.sh" "$scripts/loop-daemon.sh"
  cp "$script_dir/log-event.sh" "$scripts/log-event.sh"
  cp "$script_dir/needs-human.sh" "$scripts/needs-human.sh"
  cp "$script_dir/notify.sh" "$scripts/notify.sh"
  cat > "$dir/.claude/gates.json" <<'EOF'
{
  "modules": [{ "name": "test", "path": ".", "description": "", "owner": "" }],
  "merge": { "baseBranch": "main" }
}
EOF
  cat > "$scripts/pr-feedback.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/pr-ci-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/pr-comment-fix.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/pr-rebase.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$scripts/notify-poll.sh" <<'EOF'
#!/usr/bin/env bash
echo "=== fake notify-poll output ==="
EOF
  cat > "$scripts/merge-ready.sh" <<'EOF'
#!/usr/bin/env bash
echo "=== merge-ready: merged=0 skipped=0 ==="
EOF
  # Fake bot-gh.sh: real loop-census.sh's ACTUAL gh call shapes -- one open
  # planned issue (77), zero open PRs, no open-issue set needed (issue 77 has
  # a branch so it's never eligible and its body/blockers are never fetched).
  cat > "$scripts/bot-gh.sh" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  repo) echo "acme/repo" ;;
  pr)
    if printf '%s\n' "$*" | grep -q 'headRefName'; then
      : # no open PRs -> no branches
    else
      echo 0
    fi
    ;;
  issue)
    if printf '%s\n' "$*" | grep -q -- '--label'; then
      printf '77\tplanned,module:test\tStalled real thing\n'
    else
      : # open_issue_set -- unused by this fixture (issue 77 is never eligible)
    fi
    ;;
  *) echo "fake-bot-gh.sh: unhandled args: $*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$scripts"/*.sh
  git -C "$dir" init -q -b main
  git -C "$dir" -c user.email=t@e.st -c user.name=t commit -q --allow-empty -m init
  git -C "$dir" branch feat/issue-77-x main
  printf '%s\n' "$scripts"
}

dir25="$(build_real_census_fixture scenario25)"
events25="$work/scenario25-events.jsonl"
printf '%s\n' '{"ts":"2020-01-01T00:00:00Z","task":"77","phase":"driver-start","role":"orchestrator"}' > "$events25"
out25="$(env -u GATES_FILE CLAUDE_EVENTS_FILE="$events25" bash "$dir25/loop-tick.sh" "acme/repo")"
check "scenario 25 (real loop-census.sh reports advance_ready=none, issue 77 in_flight+stalled)" bash -c 'printf "%s\n" "$1" | grep -qx "advance_ready=none" && printf "%s\n" "$1" | grep -qx "in_flight=77" && printf "%s\n" "$1" | grep -q "^stalled=77 "' _ "$out25"
check "scenario 25 (end-to-end reachability via REAL census): verdict is action=resume issue=77 branch=feat/issue-77-x" bash -c '[ "$(printf "%s\n" "$1" | tail -1)" = "action=resume issue=77 branch=feat/issue-77-x" ]' _ "$out25"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "loop-tick.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "loop-tick.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
