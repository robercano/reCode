#!/usr/bin/env bash
# cockpit.test.sh — offline smoke test for cockpit.sh (issue #51, extended for
# Phase 2 live progress in issue #52, Phase 3a serve/theme/filter in issue #69,
# and the "Loop health" panel in issue #85).
#
# Runs the generator against controlled FIXTURE issue/PR/events/loop-ticks
# JSON (never live gh/network, and never the real event/tick logs — see
# cockpit.sh's --fixtures mode), then asserts the produced HTML contains every
# required section (issues-by-module with blocking relationships, PRs with
# review/CI badges, a routing table with a real `model:` value, a worktrees
# section, a live-progress panel deduped to each worker's latest phase, the
# default dark-theme marker, and a loop-health panel showing the last tick +
# cadence + a verdict history capped to the last COCKPIT_VERDICT_HISTORY_N
# ticks (newest first) + a STALLED banner once a tick is overdue) and that
# the blocking-relationship parser (`cockpit.sh
# --parse-blocking`) produces the expected edges for a known fixture body.
# Also exercises the "gh/network unavailable" / "no log at all" degrade paths
# via COCKPIT_GH_BIN / missing CLAUDE_EVENTS_FILE / CLAUDE_TICKS_FILE, entirely
# offline (no real gh call, no .env), and a serve-mode smoke case
# (cockpit-serve.sh) against the SAME fixtures, over 127.0.0.1 only — no real
# network/gh either way.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/cockpit.test.sh
set -uo pipefail

# Isolate from the CALLER's environment: this test is now wired into
# .claude/self/checks.sh's `test` case, which itself typically runs under
# `GATES_FILE=.claude/self/gates.json` (the self-host loop). Since env vars
# set before a command propagate to every child process it spawns, an
# ambient GATES_FILE would silently redirect the DEFAULT-adapter assertions
# below (section 2) onto the self-adapter. Section 3 sets GATES_FILE
# explicitly where it actually wants the override; everywhere else must see
# the default (.claude/gates.json).
unset GATES_FILE

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cockpit="$script_dir/cockpit.sh"
cockpit_serve="$script_dir/cockpit-serve.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/cockpit-test.XXXXXX")"
# server_pid is set once the serve-mode smoke case (section 5, below) starts
# cockpit-serve.sh in the background -- declared here so the SAME EXIT trap
# cleans it up no matter where in the script a later assertion fails.
server_pid=""
# alias_npm_pid/alias_node_pid: same idea, for the `npm run cockpit` alias
# smoke (section 5b) -- npm wraps the real node server behind npm -> sh ->
# node, so cleanup needs to reach the actual node PID too, not just npm's.
alias_npm_pid=""
alias_node_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
  fi
  if [ -n "$alias_node_pid" ]; then
    kill "$alias_node_pid" >/dev/null 2>&1 || true
  fi
  if [ -n "$alias_npm_pid" ]; then
    kill "$alias_npm_pid" >/dev/null 2>&1 || true
    wait "$alias_npm_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

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

# ---------------------------------------------------------------------------
# 1. Blocking-graph parser: exact edges for a known fixture body.
# ---------------------------------------------------------------------------
parsed="$(printf 'Blocked by #10, #11\nBlocks #20\n- [ ] #30 subtask\n- [x] #31 done\n' | bash "$cockpit" --parse-blocking)"
check "parse-blocking produces exactly the expected edges" node -e '
  const got = JSON.parse(process.argv[1]);
  const want = { blockedBy: [10, 11], blocks: [20], taskRefs: [30, 31] };
  if (JSON.stringify(got) !== JSON.stringify(want)) {
    console.error("got", got, "want", want);
    process.exit(1);
  }
' "$parsed"

# A second fixture: no relationships at all should parse to empty arrays,
# and "blocked by" text should not leak into "blocks".
parsed2="$(printf 'Nothing to see here. Blocks #99.\n' | bash "$cockpit" --parse-blocking)"
check "parser finds only 'blocks' edge, no false blockedBy" node -e '
  const got = JSON.parse(process.argv[1]);
  if (JSON.stringify(got.blockedBy) !== "[]") process.exit(1);
  if (JSON.stringify(got.blocks) !== "[99]") process.exit(1);
' "$parsed2"

# ---------------------------------------------------------------------------
# 2. Fixture-driven full generator run (no gh/network).
# ---------------------------------------------------------------------------
mkdir -p "$work/fixtures"
cat > "$work/fixtures/issues.json" <<'EOF'
[
  {"number":100,"title":"Issue A <script>alert(1)</script>","url":"https://example.com/100","labels":[{"name":"module:harness"}],"body":"Blocked by #101, #102\nBlocks #103\n- [ ] #104 subtask\n- [x] #105 done subtask"},
  {"number":101,"title":"Issue B","url":"https://example.com/101","labels":[{"name":"module:docs"}],"body":""},
  {"number":103,"title":"Issue C","url":"https://example.com/103","labels":[],"body":""}
]
EOF
cat > "$work/fixtures/prs.json" <<'EOF'
[
  {"number":200,"title":"PR A","url":"https://example.com/pr/200","headRefName":"feat/x","reviewDecision":"APPROVED","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED","name":"build"}]},
  {"number":201,"title":"PR B","url":"https://example.com/pr/201","headRefName":"feat/y","reviewDecision":"CHANGES_REQUESTED","statusCheckRollup":[{"conclusion":"FAILURE","status":"COMPLETED","name":"test"}]}
]
EOF
# Live progress fixture (issue #52): two events for the SAME (role,task) —
# only the LATER phase ("gate-running") must win the dedup — plus a second
# worker ("reviewer"/task 52b) in a different phase, to prove both distinct
# workers render. Also folds in, per the "tests" review lens:
#  - a malformed JSON line (unparsable) and a blank line, which readEvents()
#    must silently skip rather than crash the whole render;
#  - a JSON *array* line ("[1,2,3]") -- typeof [] === "object" too, so this
#    guards the Array.isArray() exclusion in readEvents() (a regression here
#    would produce a phantom worker row);
#  - a third legitimate worker ("52c") whose role contains a <script> tag and
#    a quote, to prove the live section runs esc() on every field (a stored-
#    XSS regression guard, mirroring the issue-title escaping check below).
cat > "$work/fixtures/events.jsonl" <<'EOF'
{"ts":"2026-01-01T00:00:00Z","role":"implementer","model":"sonnet","task":"52","phase":"implementing","lens":"","detail":""}
{ this is not json

[1,2,3]
{"ts":"2026-01-01T00:05:00Z","role":"implementer","model":"sonnet","task":"52","phase":"gate-running","lens":"","detail":""}
{"ts":"2026-01-01T00:02:00Z","role":"reviewer","model":"opus","task":"52b","phase":"reviewing","lens":"correctness","detail":""}
{"ts":"2026-01-01T00:03:00Z","role":"<script>xss()</script>\"","model":"sonnet","task":"52c","phase":"scoped","lens":"","detail":""}
EOF
# Loop tick fixture (issue #85, "Loop health" panel): two ticks, file order =
# chronological, so the LAST line (FAST/advance) is the most recent tick and
# must render as "Last tick" while BOTH rows appear in the verdict history,
# newest first.
cat > "$work/fixtures/loop-ticks.jsonl" <<'EOF'
{"ts":"2026-01-01T00:00:00Z","verdict":"action=none","cadence":"IDLE","action":"none","issue":"","pr":""}
{"ts":"2026-01-01T00:15:00Z","verdict":"action=advance issue=7","cadence":"FAST","action":"advance","issue":"7","pr":""}
EOF

html="$work/cockpit.html"
# COCKPIT_NOW pins "now" to 90s after the last tick above -- inside FAST's
# 120s stall threshold, so this run must NOT show the STALLED banner (that
# path is exercised separately in section 2b below).
COCKPIT_NOW="2026-01-01T00:16:30Z" bash "$cockpit" --fixtures "$work/fixtures" "$html" >"$work/stdout.log" 2>"$work/stderr.log"
rc=$?
check "generator exits 0 on fixture run" [ "$rc" -eq 0 ]
check "generator prints the output path" grep -qF "$html" "$work/stdout.log"
check "output HTML file was created" [ -s "$html" ]

# Issues-by-module + blocking relationships.
check "issues section present" grep -q '<section id="issues"' "$html"
check "module:harness group heading present" grep -q '<h3>module:harness</h3>' "$html"
check "module:docs group heading present" grep -q '<h3>module:docs</h3>' "$html"
check "unlabeled group heading present (issue with no module label)" grep -q '<h3>unlabeled</h3>' "$html"
check "issue title is HTML-escaped, not raw" bash -c '! grep -qF "<script>alert(1)</script>" "$1" && grep -qF "&lt;script&gt;alert(1)&lt;/script&gt;" "$1"' _ "$html"
check "blocked-by relationship rendered, linked to known issue #101" grep -qF 'Blocked by <a href="#issue-101">#101</a>, #102' "$html"
check "blocks relationship rendered, linked to known issue #103" grep -qF 'Blocks <a href="#issue-103">#103</a>' "$html"
check "subtasks (task-list refs) rendered" grep -qF 'Subtasks #104, #105' "$html"

# PRs with review + CI status.
check "PRs section present" grep -q '<section id="prs"' "$html"
check "approved review badge rendered" grep -q 'review: approved' "$html"
check "changes-requested review badge rendered" grep -q 'review: changes requested' "$html"
check "passing CI badge rendered" grep -q 'CI: passing' "$html"
check "failing CI badge rendered" grep -q 'CI: failing' "$html"

# Routing table with a real model: value read from .claude/agents/*.md frontmatter.
check "routing section present" grep -q '<section id="routing"' "$html"
check "routing table contains a real agent role" grep -q '<td>orchestrator</td>' "$html"
check "routing table contains a real model: value" grep -qE '<code>(opus|sonnet|haiku)</code>' "$html"
check "adapter path shown in routing section" grep -q 'Adapter: <code>.claude/gates.json</code>' "$html"

# Worktrees section (state may vary, so only assert the section exists).
check "worktrees section present" grep -q '<section id="worktrees"' "$html"

# Live worker progress (issue #52): dedup-to-latest-phase + multiple workers.
check "live section present" grep -q '<section id="live"' "$html"
check "implementer/task 52 shows the LATEST phase (gate-running), not the earlier one (implementing)" bash -c '
  grep -qF "gate-running" "$1" || exit 1
  # the earlier "implementing" phase for the SAME worker must not also appear
  # as its own row — count rows for task "52": exactly one, and it must be gate-running.
  rows=$(grep -o "<td>implementer</td><td>52</td>[^<]*<td><code>sonnet</code></td><td><span class=\"badge[^>]*>[a-z-]*</span></td>" "$1" | wc -l)
  [ "$rows" -eq 1 ]
' _ "$html"
check "reviewer/task 52b renders with role/model/phase/lens" bash -c '
  grep -qF "<td>reviewer</td><td>52b</td>" "$1" &&
  grep -qF "<code>opus</code>" "$1" &&
  grep -qF "badge warn\">reviewing</span>" "$1" &&
  grep -qF "<td>correctness</td>" "$1"
' _ "$html"

# Malformed-line tolerance (guards the readEvents() try/catch skip path): the
# fixture above folds in an unparsable line and a blank line among otherwise
# valid ones. Regressing this would blow up the whole dashboard on one bad
# line, silently -- so assert BOTH the process still exits 0 (already checked
# above, re-asserted here for intent) AND a known-good worker row from a
# valid line still renders despite the bad lines sitting right next to it.
check "malformed/blank JSON lines are skipped without crashing the render" [ "$rc" -eq 0 ]
check "a known-good worker row still renders alongside malformed/blank lines" grep -qF '<td>implementer</td><td>52</td>' "$html"

# Array-line guard (correctness lens): typeof [] === "object" too, so a
# top-level JSON array line must NOT produce a phantom worker row. The
# fixture has exactly 3 legitimate workers (52 deduped to its latest phase,
# 52b, 52c) -- assert the live table has exactly 3 data rows, i.e. the
# malformed/blank/array lines contributed zero phantom rows.
check "JSON-array line produces no phantom worker row (exact row count == legitimate workers)" node -e '
  const fs = require("fs");
  const html = fs.readFileSync(process.argv[1], "utf8");
  const m = html.match(/<section id="live">[\s\S]*?<\/section>/);
  if (!m) throw new Error("live section not found");
  const rows = (m[0].match(/<tr><td>/g) || []).length;
  if (rows !== 3) throw new Error("expected 3 live-worker rows, got " + rows);
' "$html"

# Live-section HTML-escaping (stored-XSS regression guard): worker 52c's
# role contains a <script> tag and a quote -- mirror the issue-title escaping
# check above, but for the live-progress panel, which has its own esc() calls.
check "live-section field escaping: raw <script> absent, escaped form present" bash -c '
  ! grep -qF "<script>xss()</script>" "$1" &&
  grep -qF "&lt;script&gt;xss()&lt;/script&gt;&quot;" "$1"
' _ "$html"

# Dark theme by default (issue #69): stable marker a consumer/test can grep
# for, plus the client-side module-filter hook (data-module on issue <li>s).
check "dark theme marker present by default" grep -qF 'data-theme="dark"' "$html"
check "theme-toggle button present" grep -q 'id="theme-toggle"' "$html"
check "issue rows carry data-module for the client-side filter" grep -q 'data-module="module:harness"' "$html"

# Loop health panel (issue #85): last tick, cadence, verdict history newest
# first, and NO stall banner (COCKPIT_NOW above is only 90s past the last
# tick, inside FAST's 120s threshold).
check "loop health section present" grep -q '<section id="loop-health"' "$html"
check "last tick's ts and verdict are rendered" grep -qF '<code>2026-01-01T00:15:00Z</code> &middot; verdict <code>action=advance issue=7</code>' "$html"
check "current cadence (FAST) is rendered" grep -qF '<span class="badge muted">FAST</span>' "$html"
check "no STALLED banner when the last tick is within the cadence threshold" bash -c '! grep -q "STALLED" "$1"' _ "$html"
check "verdict history renders BOTH ticks, newest first" node -e '
  const fs = require("fs");
  const html = fs.readFileSync(process.argv[1], "utf8");
  const m = html.match(/<section id="loop-health">[\s\S]*?<\/section>/);
  if (!m) throw new Error("loop-health section not found");
  const rows = [...m[0].matchAll(/<tr><td>([^<]*)<\/td><td><code>([^<]*)<\/code><\/td>/g)].map((r) => r[2]);
  const want = ["action=advance issue=7", "action=none"];
  if (JSON.stringify(rows) !== JSON.stringify(want)) {
    throw new Error("got " + JSON.stringify(rows) + " want " + JSON.stringify(want));
  }
' "$html"

# ---------------------------------------------------------------------------
# 2b. Loop health STALLED banner: a last tick far older than 2x its cadence's
#     expected interval must render the STALLED banner. Reuses the SAME
#     fixtures dir (issues/prs/events unrelated) but pins COCKPIT_NOW well
#     past the FAST tick's 120s threshold.
# ---------------------------------------------------------------------------
html_stalled="$work/cockpit-stalled.html"
COCKPIT_NOW="2026-01-01T01:00:00Z" bash "$cockpit" --fixtures "$work/fixtures" "$html_stalled" >/dev/null 2>"$work/stderr-stalled.log"
check "STALLED banner renders once the last tick exceeds 2x its cadence interval" grep -qF 'STALLED — no tick in over 120s (cadence FAST)' "$html_stalled"

# ---------------------------------------------------------------------------
# 2c. Verdict-history cap (review fix for issue #85): the panel must show only
#     the last N verdict lines, newest first -- NOT every retained tick (the
#     ticks file itself may hold up to LOOP_TICKS_MAX_LINES/2000 rows). Uses a
#     dedicated fixtures dir with 5 DISTINGUISHABLE ticks (unique issue= per
#     line, mirroring the loop-tick.test.sh rotation fix) and
#     COCKPIT_VERDICT_HISTORY_N=3 so the cap is exercised deterministically
#     without needing a huge fixture.
# ---------------------------------------------------------------------------
mkdir -p "$work/fixtures-history"
echo "[]" >"$work/fixtures-history/issues.json"
echo "[]" >"$work/fixtures-history/prs.json"
: >"$work/fixtures-history/events.jsonl"
cat > "$work/fixtures-history/loop-ticks.jsonl" <<'EOF'
{"ts":"2026-01-01T00:00:00Z","verdict":"action=advance issue=1","cadence":"FAST","action":"advance","issue":"1","pr":""}
{"ts":"2026-01-01T00:01:00Z","verdict":"action=advance issue=2","cadence":"FAST","action":"advance","issue":"2","pr":""}
{"ts":"2026-01-01T00:02:00Z","verdict":"action=advance issue=3","cadence":"FAST","action":"advance","issue":"3","pr":""}
{"ts":"2026-01-01T00:03:00Z","verdict":"action=advance issue=4","cadence":"FAST","action":"advance","issue":"4","pr":""}
{"ts":"2026-01-01T00:04:00Z","verdict":"action=advance issue=5","cadence":"FAST","action":"advance","issue":"5","pr":""}
EOF
html_history="$work/cockpit-history.html"
COCKPIT_NOW="2026-01-01T00:04:30Z" COCKPIT_VERDICT_HISTORY_N=3 bash "$cockpit" --fixtures "$work/fixtures-history" "$html_history" >/dev/null 2>"$work/stderr-history.log"
check "verdict-history cap: last tick is still the most recent (issue=5)" grep -qF '<code>2026-01-01T00:04:00Z</code> &middot; verdict <code>action=advance issue=5</code>' "$html_history"
check "verdict-history cap: table renders exactly COCKPIT_VERDICT_HISTORY_N=3 rows, newest first" node -e '
  const fs = require("fs");
  const html = fs.readFileSync(process.argv[1], "utf8");
  const m = html.match(/<section id="loop-health">[\s\S]*?<\/section>/);
  if (!m) throw new Error("loop-health section not found");
  const rows = [...m[0].matchAll(/<tr><td>([^<]*)<\/td><td><code>([^<]*)<\/code><\/td>/g)].map((r) => r[2]);
  const want = ["action=advance issue=5", "action=advance issue=4", "action=advance issue=3"];
  if (JSON.stringify(rows) !== JSON.stringify(want)) {
    throw new Error("got " + JSON.stringify(rows) + " want " + JSON.stringify(want));
  }
' "$html_history"

# Default (COCKPIT_VERDICT_HISTORY_N unset) with only 5 ticks retained must
# still render all 5 -- the default cap (10) must not truncate BELOW what's
# actually there.
html_history_default="$work/cockpit-history-default.html"
COCKPIT_NOW="2026-01-01T00:04:30Z" bash "$cockpit" --fixtures "$work/fixtures-history" "$html_history_default" >/dev/null 2>"$work/stderr-history-default.log"
check "verdict-history default cap (10) does not truncate a shorter (5-tick) history" node -e '
  const fs = require("fs");
  const html = fs.readFileSync(process.argv[1], "utf8");
  const m = html.match(/<section id="loop-health">[\s\S]*?<\/section>/);
  if (!m) throw new Error("loop-health section not found");
  const rows = [...m[0].matchAll(/<tr><td>([^<]*)<\/td><td><code>([^<]*)<\/code><\/td>/g)].map((r) => r[2]);
  const want = ["action=advance issue=5", "action=advance issue=4", "action=advance issue=3", "action=advance issue=2", "action=advance issue=1"];
  if (JSON.stringify(rows) !== JSON.stringify(want)) {
    throw new Error("got " + JSON.stringify(rows) + " want " + JSON.stringify(want));
  }
' "$html_history_default"

# ---------------------------------------------------------------------------
# 3. GATES_FILE override is honored (self-host adapter), still with fixtures
#    (no gh/network either way).
# ---------------------------------------------------------------------------
html_self="$work/cockpit-self.html"
GATES_FILE=.claude/self/gates.json bash "$cockpit" --fixtures "$work/fixtures" "$html_self" >/dev/null 2>"$work/stderr-self.log"
check "GATES_FILE override honored in generator output" grep -q 'Adapter: <code>.claude/self/gates.json</code>' "$html_self"

# ---------------------------------------------------------------------------
# 4. Graceful degrade when gh is unavailable — stub COCKPIT_GH_BIN so this is
#    fully offline (no real gh call, no dependency on .env/auth/network).
# ---------------------------------------------------------------------------
fake_gh="$work/fake-gh-fail.sh"
cat > "$fake_gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$fake_gh"
html_unavail="$work/cockpit-unavail.html"
# CLAUDE_EVENTS_FILE/CLAUDE_TICKS_FILE point at guaranteed-missing paths so
# this run is fully offline/deterministic (never touches the real,
# gitignored logs) and doubles as the "no log at all" degrade assertions for
# both the live-progress panel ("no active workers") and the loop-health
# panel ("loop not armed", issue #85) -- neither must crash the render.
COCKPIT_GH_BIN="$fake_gh" CLAUDE_EVENTS_FILE="$work/no-such-events.jsonl" CLAUDE_TICKS_FILE="$work/no-such-ticks.jsonl" bash "$cockpit" "$html_unavail" >/dev/null 2>"$work/stderr-unavail.log"
rc_unavail=$?
check "generator still exits 0 when gh is unavailable" [ "$rc_unavail" -eq 0 ]
check "issues section shows unavailable placeholder" grep -q '<section id="issues"><h2>Open issues</h2><p class="unavailable">unavailable (gh/network)</p>' "$html_unavail"
check "PRs section shows unavailable placeholder" grep -q '<section id="prs"><h2>Open PRs</h2><p class="unavailable">unavailable (gh/network)</p>' "$html_unavail"
check "routing/worktrees sections still render (no crash) despite gh failure" bash -c 'grep -q "routing" "$1" && grep -q "worktrees" "$1"' _ "$html_unavail"
check "missing events file renders 'no active workers' placeholder" grep -q '<section id="live"><h2>Live worker progress</h2><p class="muted">no active workers</p>' "$html_unavail"
check "missing loop-ticks log renders 'loop not armed' placeholder, no crash" grep -qF '<section id="loop-health"><h2>Loop health</h2><p class="muted">loop not armed</p></section>' "$html_unavail"

# ---------------------------------------------------------------------------
# 5. Serve mode (cockpit-serve.sh, issue #69): dashboard over HTTP + SSE live
#    updates, entirely offline against the SAME fixtures used above (127.0.0.1
#    only, no gh, no real network). server_pid + the EXIT trap declared near
#    the top of this file guarantee the port/process are reclaimed even if an
#    assertion below fails.
# ---------------------------------------------------------------------------
port="$(node -e '
  const s = require("net").createServer();
  s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });
')"

# 3a-followup fix (a) regression baseline (issue #70): count any leftover
# cockpit-serve temp HTML files BEFORE this server ever runs, so the
# after-shutdown check below only flags a NEW leak, not pre-existing debris.
tmp_glob="${TMPDIR:-/tmp}"/cockpit-serve.*.html
tmp_before=0
for f in $tmp_glob; do [ -e "$f" ] && tmp_before=$((tmp_before + 1)); done

serve_log="$work/serve.log"
: > "$serve_log"
bash "$cockpit_serve" "$port" --fixtures "$work/fixtures" >"$serve_log" 2>&1 &
server_pid=$!

ready=0
for _ in $(seq 1 50); do
  grep -q "cockpit serving" "$serve_log" 2>/dev/null && { ready=1; break; }
  kill -0 "$server_pid" 2>/dev/null || break # server died early -- stop polling
  sleep 0.2
done
check "cockpit-serve.sh prints a startup line within the readiness timeout" [ "$ready" -eq 1 ]

resp="$(curl -s -o - -w '%{http_code}' "http://127.0.0.1:$port/" 2>/dev/null)"
serve_code="${resp: -3}"
serve_body="${resp%???}"
check "GET / returns HTTP 200" [ "$serve_code" = "200" ]
check "GET / serves the dashboard (issues section present)" bash -c 'printf "%s" "$1" | grep -qF '"'"'<section id="issues"'"'"'' _ "$serve_body"
check "GET / carries the dark-theme marker" bash -c 'printf "%s" "$1" | grep -qF '"'"'data-theme="dark"'"'"'' _ "$serve_body"
check "GET / injects the SSE client script (EventSource)" bash -c 'printf "%s" "$1" | grep -q "EventSource"' _ "$serve_body"

# Append a fresh event line to the SAME fixtures events.jsonl the server is
# watching, then assert an /events subscriber sees it arrive within a few
# seconds (fs.watch + poll fallback, see cockpit-serve.sh).
printf '{"ts":"2026-01-01T00:10:00Z","role":"implementer","model":"sonnet","task":"69","phase":"implementing","lens":"","detail":""}\n' >>"$work/fixtures/events.jsonl"
sse_out="$work/sse.out"
: > "$sse_out"
timeout 6 curl -sN "http://127.0.0.1:$port/events" >"$sse_out" 2>/dev/null &
sse_pid=$!
deadline=$((SECONDS + 5))
sse_seen=0
while [ "$SECONDS" -lt "$deadline" ]; do
  grep -q '"task":"69"' "$sse_out" 2>/dev/null && { sse_seen=1; break; }
  sleep 0.2
done
kill "$sse_pid" >/dev/null 2>&1 || true
wait "$sse_pid" 2>/dev/null || true
check "SSE /events delivers the newly appended events.jsonl line within the timeout" [ "$sse_seen" -eq 1 ]

# 3a-followup fix (b) regression (issue #70): log-event.sh's rotation caps
# events.jsonl to its last N lines via a temp-file + atomic mv, which can
# shrink the file below a subscriber's current read offset. Start a fresh
# subscriber, let it read the CURRENT (larger) file at least once so its
# offset advances past 0, then simulate rotation by replacing the file with a
# much SMALLER one containing a brand-new marker line -- a subscriber whose
# offset never resets would sit past EOF forever and never see it.
rot_out="$work/sse-rotation.out"
: > "$rot_out"
timeout 6 curl -sN "http://127.0.0.1:$port/events" >"$rot_out" 2>/dev/null &
rot_pid=$!
sleep 1.5
printf '{"ts":"2026-01-01T00:20:00Z","role":"implementer","model":"sonnet","task":"rot70","phase":"implementing","lens":"","detail":"post-rotation line"}\n' >"$work/fixtures/events.jsonl"
deadline=$((SECONDS + 5))
rot_seen=0
while [ "$SECONDS" -lt "$deadline" ]; do
  grep -q '"task":"rot70"' "$rot_out" 2>/dev/null && { rot_seen=1; break; }
  sleep 0.2
done
kill "$rot_pid" >/dev/null 2>&1 || true
wait "$rot_pid" 2>/dev/null || true
check "SSE /events resumes tailing after events.jsonl shrinks/rotates (3a-followup fix)" [ "$rot_seen" -eq 1 ]

kill "$server_pid" >/dev/null 2>&1 || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

# 3a-followup fix (a) regression (issue #70): after the server above exits,
# its mktemp'd HTML temp file must be gone -- proves cleanup now happens in
# node's own 'exit' handler rather than the dead bash EXIT trap that used to
# sit after `exec node` (never fired, since exec replaces the shell).
tmp_after=0
for f in $tmp_glob; do [ -e "$f" ] && tmp_after=$((tmp_after + 1)); done
check "cockpit-serve.sh does not leak its temp HTML file after exit (3a-followup fix)" [ "$tmp_after" -eq "$tmp_before" ]

# ---------------------------------------------------------------------------
# 5b. `pnpm cockpit` alias smoke (issue #90 review fix): exercises the ROOT
#     package.json's `scripts.cockpit` entry itself -- not cockpit-serve.sh
#     directly -- via `npm run cockpit`. npm (not pnpm) is used here
#     deliberately: npm ships with node, so it needs no extra toolchain
#     (corepack/pnpm) in CI, and it reads the SAME scripts.cockpit entry pnpm
#     would resolve, so this validates the alias wiring end-to-end. Same
#     offline --fixtures seam and 127.0.0.1-only contract as section 5's
#     cockpit-serve.sh smoke, on a fresh free port, against the SAME
#     fixtures dir used above.
# ---------------------------------------------------------------------------
# shellcheck source=resolve-roots.sh
. "$script_dir/resolve-roots.sh"

check "root package.json has a cockpit script wired to cockpit-serve.sh" node -e '
  const p = require(process.argv[1]);
  const s = p.scripts && p.scripts.cockpit;
  if (typeof s !== "string" || s.indexOf("cockpit-serve.sh") === -1) {
    console.error("scripts.cockpit =", s);
    process.exit(1);
  }
' "$root/package.json"

alias_port="$(node -e '
  const s = require("net").createServer();
  s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });
')"

# --prefix (rather than a `cd`) so the script'"'"'s own relative path
# (.claude/scripts/cockpit-serve.sh) resolves against the repo root
# regardless of this test'"'"'s own cwd.
alias_log="$work/npm-run-cockpit.log"
: > "$alias_log"
npm --prefix "$root" run cockpit -- "$alias_port" --fixtures "$work/fixtures" >"$alias_log" 2>&1 &
alias_npm_pid=$!

alias_ready=0
for _ in $(seq 1 50); do
  grep -q "cockpit serving" "$alias_log" 2>/dev/null && { alias_ready=1; break; }
  kill -0 "$alias_npm_pid" 2>/dev/null || break # npm exited early -- stop polling
  sleep 0.2
done
check "npm run cockpit (the scripts.cockpit alias) prints a startup line within the readiness timeout" [ "$alias_ready" -eq 1 ]

alias_resp="$(curl -s -o - -w '%{http_code}' "http://127.0.0.1:$alias_port/" 2>/dev/null)"
alias_code="${alias_resp: -3}"
alias_body="${alias_resp%???}"
check "npm run cockpit: GET / returns HTTP 200" [ "$alias_code" = "200" ]
check "npm run cockpit: GET / serves the dashboard (issues section present)" bash -c 'printf "%s" "$1" | grep -qF '"'"'<section id="issues"'"'"'' _ "$alias_body"

# npm wraps the real node server behind npm -> sh -> (bash exec) node, so
# killing only npm's own PID can leave the node process (and the listening
# port) orphaned. Find the actual PID bound to the port and kill it
# directly (lsof, falling back to ss if lsof isn't installed), then npm's
# own PID as a best-effort belt-and-braces cleanup.
if command -v lsof >/dev/null 2>&1; then
  alias_node_pid="$(lsof -ti tcp:"$alias_port" 2>/dev/null | head -1)"
elif command -v ss >/dev/null 2>&1; then
  alias_node_pid="$(ss -ltnp 2>/dev/null | grep ":$alias_port " | grep -oP 'pid=\K[0-9]+' | head -1)"
fi
[ -n "$alias_node_pid" ] && kill "$alias_node_pid" >/dev/null 2>&1 || true
kill "$alias_npm_pid" >/dev/null 2>&1 || true
wait "$alias_npm_pid" 2>/dev/null || true
alias_node_pid=""
alias_npm_pid=""

# ---------------------------------------------------------------------------
# 6. Worker inspector endpoint (GET /api/worker/<role>/<task>, issue #70):
#    event timeline + latest breadcrumbs + live worktree forensics, entirely
#    offline. Forensics are computed by cockpit-serve.sh shelling out to git
#    against a SYNTHETIC temp git repo/worktree built here under $TMPDIR
#    (mirrors .claude/self/smoke-fanout.sh's own git-init/worktree-add
#    pattern) -- never against this checkout, so this stays deterministic and
#    isolated. Covers BOTH worktree-lookup strategies documented in
#    cockpit-serve.sh: by conventional directory name
#    (.claude/worktrees/issue-<task>) and by branch-name fallback
#    (feat/issue-<task>-*, worktree living anywhere else on disk), plus the
#    graceful "no worktree found" degrade path.
# ---------------------------------------------------------------------------
insp_root="$work/inspector-repo"
IG() { git -C "$insp_root" -c user.name=insp -c user.email=insp@local -c commit.gpgsign=false "$@"; }
mkdir -p "$insp_root"
IG init -q -b main .
IG commit -q --allow-empty -m "inspector fixture: initial"

# Worker "implementer"/"70a": worktree found by CONVENTIONAL DIRECTORY NAME.
mkdir -p "$insp_root/.claude/worktrees"
IG worktree add -q -b feat/issue-70a-inspector "$insp_root/.claude/worktrees/issue-70a" main
git -C "$insp_root/.claude/worktrees/issue-70a" -c user.name=insp -c user.email=insp@local -c commit.gpgsign=false \
  commit -q --allow-empty -m "feat: inspector work for 70a"

# Worker "reviewer"/"70b": worktree lives OUTSIDE .claude/worktrees/ entirely
# -- only discoverable via the BRANCH-NAME FALLBACK (feat/issue-70b-*).
insp_wt_70b="$work/inspector-wt-elsewhere"
IG worktree add -q -b feat/issue-70b-other-branch "$insp_wt_70b" main
git -C "$insp_wt_70b" -c user.name=insp -c user.email=insp@local -c commit.gpgsign=false \
  commit -q --allow-empty -m "feat: other work for 70b"

mkdir -p "$work/fixtures-inspector"
echo "[]" >"$work/fixtures-inspector/issues.json"
echo "[]" >"$work/fixtures-inspector/prs.json"
cat >"$work/fixtures-inspector/events.jsonl" <<'EOF'
{"ts":"2026-01-01T01:00:00Z","role":"implementer","model":"sonnet","task":"70a","phase":"implementing","lens":"","detail":"scoped the inspector work"}
{"ts":"2026-01-01T01:05:00Z","role":"implementer","model":"sonnet","task":"70a","phase":"gate-running","lens":"","detail":"running gates"}
{"ts":"2026-01-01T01:02:00Z","role":"reviewer","model":"opus","task":"70b","phase":"reviewing","lens":"tests","detail":""}
EOF

insp_port="$(node -e '
  const s = require("net").createServer();
  s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });
')"
insp_serve_log="$work/serve-inspector.log"
: > "$insp_serve_log"
# CLAUDE_WORKER_TOOLS_FILE (issue #84) deliberately points at a file that
# does not exist, so this primary server instance also covers the
# "no worker-tools log present" case below -- activity must come back as an
# empty array, never missing/an error, and never accidentally pick up this
# checkout's own real (gitignored) worker-tools.jsonl.
COCKPIT_SERVE_WORKTREES_ROOT="$insp_root" \
CLAUDE_WORKER_TOOLS_FILE="$work/no-such-worker-tools.jsonl" \
  bash "$cockpit_serve" "$insp_port" --fixtures "$work/fixtures-inspector" >"$insp_serve_log" 2>&1 &
server_pid=$!

insp_ready=0
for _ in $(seq 1 50); do
  grep -q "cockpit serving" "$insp_serve_log" 2>/dev/null && { insp_ready=1; break; }
  kill -0 "$server_pid" 2>/dev/null || break
  sleep 0.2
done
check "worker-inspector server (custom WORKTREES_ROOT) starts within the readiness timeout" [ "$insp_ready" -eq 1 ]

resp_70a="$(curl -s "http://127.0.0.1:$insp_port/api/worker/implementer/70a" 2>/dev/null)"
check "worker-inspector 70a: timeline has both events, NEWEST FIRST, plus breadcrumbs + forensics fields" node -e '
  const got = JSON.parse(process.argv[1]);
  if (!Array.isArray(got.timeline) || got.timeline.length !== 2) throw new Error("expected 2 timeline entries, got " + JSON.stringify(got.timeline));
  if (got.timeline[0].phase !== "gate-running") throw new Error("expected newest-first (gate-running first), got " + got.timeline[0].phase);
  if (got.timeline[1].phase !== "implementing") throw new Error("expected implementing second, got " + got.timeline[1].phase);
  if (!Array.isArray(got.breadcrumbs) || got.breadcrumbs.length !== 2) throw new Error("expected 2 breadcrumbs, got " + JSON.stringify(got.breadcrumbs));
  if (got.breadcrumbs[0].detail !== "running gates") throw new Error("expected latest breadcrumb first, got " + JSON.stringify(got.breadcrumbs[0]));
  const wt = got.worktree;
  if (!wt || wt.found !== true) throw new Error("expected worktree found via directory-name lookup, got " + JSON.stringify(wt));
  if (wt.branch !== "feat/issue-70a-inspector") throw new Error("unexpected branch " + wt.branch);
  if (typeof wt.status !== "string") throw new Error("status field missing/wrong type");
  if (!Array.isArray(wt.commits) || wt.commits.length === 0) throw new Error("commits field missing/empty");
  if (typeof wt.diffstat !== "string") throw new Error("diffstat field missing/wrong type");
' "$resp_70a"

# Activity (issue #84), no-log-file case: CLAUDE_WORKER_TOOLS_FILE for this
# server points at a nonexistent file -- activity must be an empty array
# (not missing, not an error), and the rest of the response (timeline,
# worktree) must still be intact.
check "worker-inspector 70a: no worker-tools log present -> activity is [] (not missing/error), timeline/worktree intact" node -e '
  const got = JSON.parse(process.argv[1]);
  if (!Array.isArray(got.activity)) throw new Error("expected activity to be an array, got " + JSON.stringify(got.activity));
  if (got.activity.length !== 0) throw new Error("expected empty activity with no log file, got " + JSON.stringify(got.activity));
  if (!Array.isArray(got.timeline) || got.timeline.length !== 2) throw new Error("timeline should still be intact");
  if (!got.worktree || got.worktree.found !== true) throw new Error("worktree should still be intact");
' "$resp_70a"

resp_70b="$(curl -s "http://127.0.0.1:$insp_port/api/worker/reviewer/70b" 2>/dev/null)"
check "worker-inspector 70b: worktree found via BRANCH-NAME fallback (not conventional dir name)" node -e '
  const got = JSON.parse(process.argv[1]);
  const wt = got.worktree;
  if (!wt || wt.found !== true) throw new Error("expected worktree found via branch fallback, got " + JSON.stringify(wt));
  if (wt.branch !== "feat/issue-70b-other-branch") throw new Error("unexpected branch " + wt.branch);
  if (!Array.isArray(wt.commits) || wt.commits.length === 0) throw new Error("commits field missing/empty");
  if (typeof wt.diffstat !== "string") throw new Error("diffstat field missing/wrong type");
' "$resp_70b"

resp_missing="$(curl -s "http://127.0.0.1:$insp_port/api/worker/nobody/999999" 2>/dev/null)"
check "worker-inspector degrades gracefully: no matching worktree returns found:false, not an error" node -e '
  const got = JSON.parse(process.argv[1]);
  if (got.worktree.found !== false) throw new Error("expected found:false, got " + JSON.stringify(got.worktree));
  if (Array.isArray(got.timeline) && got.timeline.length !== 0) throw new Error("expected empty timeline for an unknown worker");
' "$resp_missing"

# Crash-fix regression (issue #70 correctness review, BLOCKING): a malformed
# percent-escape used to reach decodeURIComponent() OUTSIDE
# handleWorkerInspector's try/catch and throw an uncaught URIError, killing
# the whole node process (no process.on("uncaughtException") handler
# existed, or was meant to). Assert the endpoint now responds 400 instead of
# dropping the connection, AND that the server is still alive/serving
# afterward -- that second assertion is what actually proves the crash is
# fixed, since a dead server would also fail every check after it.
resp_malformed="$(curl -s -o - -w '%{http_code}' "http://127.0.0.1:$insp_port/api/worker/%/1" 2>/dev/null)"
malformed_code="${resp_malformed: -3}"
check "worker-inspector: malformed percent-escape (%2F.../1) returns 400, not a dropped connection" [ "$malformed_code" = "400" ]

# Path-traversal / separator-injection hardening (both reviewers flagged):
# `task` is interpolated into path.join(...) and a RegExp scan, so a decoded
# value containing "/" or ".." must be rejected up front rather than reaching
# findWorktree().
resp_traversal="$(curl -s -o - -w '%{http_code}' "http://127.0.0.1:$insp_port/api/worker/implementer/..%2f.." 2>/dev/null)"
traversal_code="${resp_traversal: -3}"
check "worker-inspector: task containing '..' + encoded separator (traversal attempt) returns 400" [ "$traversal_code" = "400" ]

resp_after_attack="$(curl -s -o - -w '%{http_code}' "http://127.0.0.1:$insp_port/api/worker/implementer/70a" 2>/dev/null)"
after_attack_code="${resp_after_attack: -3}"
check "worker-inspector: server still serves a valid request after malformed/traversal attempts (proves no crash)" [ "$after_attack_code" = "200" ]

kill "$server_pid" >/dev/null 2>&1 || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

# ---------------------------------------------------------------------------
# 6b. Worker inspector "activity" field (issue #84): a populated worker-tools
#     mirror log (log-worker-tool.sh's JSONL), pointed at via
#     CLAUDE_WORKER_TOOLS_FILE. Records under 70a's worktree path must come
#     back NEWEST FIRST; a record under a DIFFERENT path (70b's worktree)
#     must be excluded.
# ---------------------------------------------------------------------------
insp_wtools_file="$work/inspector-worker-tools.jsonl"
insp_wt_70a="$insp_root/.claude/worktrees/issue-70a"
cat >"$insp_wtools_file" <<EOF
{"ts":"2026-01-01T02:00:00Z","tool":"Bash","summary":"git status","path":"$insp_wt_70a"}
{"ts":"2026-01-01T02:01:00Z","tool":"Edit","summary":"$insp_wt_70a/src/foo.js","path":"$insp_wt_70a/src/foo.js"}
{"ts":"2026-01-01T02:02:00Z","tool":"Bash","summary":"git status","path":"$insp_wt_70b"}
{"ts":"2026-01-01T02:03:00Z","tool":"Write","summary":"$insp_wt_70a/src/bar.js","path":"$insp_wt_70a/src/bar.js"}
EOF

insp_port2="$(node -e '
  const s = require("net").createServer();
  s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });
')"
insp_serve_log2="$work/serve-inspector-activity.log"
: > "$insp_serve_log2"
COCKPIT_SERVE_WORKTREES_ROOT="$insp_root" \
CLAUDE_WORKER_TOOLS_FILE="$insp_wtools_file" \
  bash "$cockpit_serve" "$insp_port2" --fixtures "$work/fixtures-inspector" >"$insp_serve_log2" 2>&1 &
server_pid2=$!

insp_ready2=0
for _ in $(seq 1 50); do
  grep -q "cockpit serving" "$insp_serve_log2" 2>/dev/null && { insp_ready2=1; break; }
  kill -0 "$server_pid2" 2>/dev/null || break
  sleep 0.2
done
check "worker-inspector (activity) server starts within the readiness timeout" [ "$insp_ready2" -eq 1 ]

resp_70a_activity="$(curl -s "http://127.0.0.1:$insp_port2/api/worker/implementer/70a" 2>/dev/null)"
check "worker-inspector 70a: activity present, is an array, NEWEST FIRST, excludes records under a different worktree path" node -e '
  const got = JSON.parse(process.argv[1]);
  if (!Array.isArray(got.activity)) throw new Error("expected activity to be an array, got " + JSON.stringify(got.activity));
  if (got.activity.length !== 3) throw new Error("expected 3 activity records (70a-scoped only), got " + JSON.stringify(got.activity));
  const summaries = got.activity.map((r) => r.summary);
  const wantOrder = [got.activity[0], got.activity[1], got.activity[2]].map((r) => r.ts);
  if (wantOrder[0] !== "2026-01-01T02:03:00Z") throw new Error("expected newest (bar.js write) first, got " + JSON.stringify(got.activity));
  if (wantOrder[1] !== "2026-01-01T02:01:00Z") throw new Error("expected foo.js edit second, got " + JSON.stringify(got.activity));
  if (wantOrder[2] !== "2026-01-01T02:00:00Z") throw new Error("expected git status last (oldest), got " + JSON.stringify(got.activity));
  if (summaries.some((s) => String(s).indexOf("bar.js") === -1 && String(s).indexOf("foo.js") === -1 && s !== "git status")) {
    throw new Error("unexpected summary content: " + JSON.stringify(summaries));
  }
  if (got.activity.some((r) => r.path && r.path.indexOf("issue-70a") === -1)) {
    throw new Error("activity leaked a record outside 70a worktree: " + JSON.stringify(got.activity));
  }
' "$resp_70a_activity"

kill "$server_pid2" >/dev/null 2>&1 || true
wait "$server_pid2" 2>/dev/null || true
server_pid2=""

IG worktree remove --force "$insp_root/.claude/worktrees/issue-70a" >/dev/null 2>&1 || true
IG worktree remove --force "$insp_wt_70b" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# 7. Live-progress task GROUPING (issue #92): workers grouped by normalized
#    task id (taskGroupKey), newest-issue-first ordering, an issue-linked
#    group header (taskIssueLink), and a PR badge on the group header
#    (findPRForIssue + prBadge). Uses an ISOLATED fixtures dir (does not
#    reuse/mutate the shared "$work/fixtures" from section 2, so none of that
#    section's exact-row-count/order assertions are perturbed by these extra
#    task ids).
#
#    Fixture shape: four distinct raw task ids across four groups —
#      "91"         -> group #91 (issue #91 is a KNOWN fixture issue, so its
#                       header must render a real <a href> link; also has an
#                       OPEN PR via headRefName feat/issue-91-groups)
#      "88"         -> group #88 (unknown issue -> plain "#88", no link)
#      "issue-88-x" -> SAME group #88 as above (taskGroupKey normalization:
#                       first \d+ run == 88) -- a second worker, different
#                       raw task id, must nest under the SAME single header
#      "70"         -> group #70 (unknown issue -> plain "#70"; has a MERGED
#                       PR via headRefName feat/issue-70-merged-thing, to
#                       cover the merged-state pill since prBadge's state
#                       check is driven entirely by the fixture's pr.state)
#      "50"         -> group #50 (lowest number, no issue/PR match)
#    Expected group order (numeric groups, descending by issue number):
#      91, 88, 70, 50.
# ---------------------------------------------------------------------------
mkdir -p "$work/fixtures-groups"
cat > "$work/fixtures-groups/issues.json" <<'EOF'
[
  {"number":91,"title":"Live progress task groups","url":"https://example.com/91","labels":[],"body":""}
]
EOF
cat > "$work/fixtures-groups/prs.json" <<'EOF'
[
  {"number":300,"title":"PR for 91","url":"https://example.com/pr/300","headRefName":"feat/issue-91-groups","state":"OPEN"},
  {"number":301,"title":"PR for 70 (merged)","url":"https://example.com/pr/301","headRefName":"feat/issue-70-merged-thing","state":"MERGED"}
]
EOF
cat > "$work/fixtures-groups/events.jsonl" <<'EOF'
{"ts":"2026-01-01T00:00:00Z","role":"implementer","model":"sonnet","task":"91","phase":"implementing","lens":"","detail":""}
{"ts":"2026-01-01T00:01:00Z","role":"implementer","model":"sonnet","task":"88","phase":"implementing","lens":"","detail":""}
{"ts":"2026-01-01T00:02:00Z","role":"reviewer","model":"opus","task":"issue-88-x","phase":"reviewing","lens":"tests","detail":""}
{"ts":"2026-01-01T00:03:00Z","role":"implementer","model":"sonnet","task":"50","phase":"implementing","lens":"","detail":""}
{"ts":"2026-01-01T00:04:00Z","role":"implementer","model":"sonnet","task":"70","phase":"implementing","lens":"","detail":""}
EOF

html_groups="$work/cockpit-groups.html"
bash "$cockpit" --fixtures "$work/fixtures-groups" "$html_groups" >/dev/null 2>"$work/stderr-groups.log"
rc_groups=$?
check "task-grouping fixture run exits 0" [ "$rc_groups" -eq 0 ]

# (1) Multi-group + ordering: exactly 4 numeric groups, newest issue first.
check "live progress renders one task-group header per distinct group, newest issue number first (91, 88, 70, 50)" node -e '
  const fs = require("fs");
  const html = fs.readFileSync(process.argv[1], "utf8");
  const m = html.match(/<section id="live">[\s\S]*?<\/section>/);
  if (!m) throw new Error("live section not found");
  const section = m[0];
  const headers = [...section.matchAll(/<tr class="task-group"><td colspan="7"><strong>Task ([\s\S]*?)<\/strong><\/td><\/tr>/g)].map((r) => r[1]);
  if (headers.length !== 4) throw new Error("expected 4 task-group headers, got " + headers.length + ": " + JSON.stringify(headers));
  const nums = headers.map((h) => {
    const mm = h.match(/#(\d+)/);
    if (!mm) throw new Error("could not find an issue number in header: " + h);
    return parseInt(mm[1], 10);
  });
  const want = [91, 88, 70, 50];
  if (JSON.stringify(nums) !== JSON.stringify(want)) {
    throw new Error("expected group order " + JSON.stringify(want) + " (newest issue first), got " + JSON.stringify(nums));
  }
' "$html_groups"

# (2) taskIssueLink: task #91 is a known fixture issue -> its group header
# must render a real <a href="..."> link, not plain "#91" text.
check "task-group header links to the known fixture issue via taskIssueLink" grep -qF '<a href="https://example.com/91">#91</a>' "$html_groups"

# (3) findPRForIssue + prBadge: task #91's OPEN PR (matched via headRefName
# feat/issue-91-groups) renders an open-state pill on the group header; task
# #70's MERGED PR (feat/issue-70-merged-thing) renders a merged-state pill --
# both driven purely through the fixture's pr.state, since findPRForIssue
# only fetches --state open PRs live but prBadge's state check is generic.
check "task-group header renders an OPEN PR badge (findPRForIssue + prBadge)" grep -qF '&middot; PR <a href="https://example.com/pr/300">#300</a> <span class="badge warn">open</span>' "$html_groups"
check "task-group header renders a MERGED PR badge (findPRForIssue + prBadge)" grep -qF '&middot; PR <a href="https://example.com/pr/301">#301</a> <span class="badge good">merged</span>' "$html_groups"

# (4) taskGroupKey normalization: raw task ids "88" and "issue-88-x" both
# normalize to group key "88" -> exactly ONE "Task #88" header (already
# proven by the 4-header count above), with BOTH workers nested under that
# single header (not scattered into their own groups).
check "taskGroupKey normalizes \"88\" and \"issue-88-x\" into the SAME single group, both workers nested under it" node -e '
  const fs = require("fs");
  const html = fs.readFileSync(process.argv[1], "utf8");
  const m = html.match(/<section id="live">[\s\S]*?<\/section>/);
  if (!m) throw new Error("live section not found");
  const section = m[0];
  const idx88 = section.indexOf("Task #88");
  if (idx88 === -1) throw new Error("could not find the #88 group header");
  const nextGroupIdx = section.indexOf(String.raw`<tr class="task-group">`, idx88 + 1);
  const segment = nextGroupIdx === -1 ? section.slice(idx88) : section.slice(idx88, nextGroupIdx);
  if (!segment.includes("<td>implementer</td><td>88</td>")) throw new Error("implementer/88 row not nested under the #88 group header");
  if (!segment.includes("<td>reviewer</td><td>issue-88-x</td>")) throw new Error("reviewer/issue-88-x row not nested under the SAME #88 group header (normalization failed)");
' "$html_groups"

# (5) Self-contained + client-side sort hooks: the live-progress <th>s carry
# data-sort-key attributes, and the whole document stays self-contained HTML
# (no external <script src=...> or <link href=...> — see the file header's
# "self-contained HTML" contract).
check "live-progress table headers carry data-sort-key attributes for the client-side sort script" bash -c '
  grep -qF "<th data-sort-key=\"role\">Role</th>" "$1" &&
  grep -qF "<th data-sort-key=\"task\">Task</th>" "$1" &&
  grep -qF "<th data-sort-key=\"model\">Model</th>" "$1" &&
  grep -qF "<th data-sort-key=\"phase\">Phase</th>" "$1" &&
  grep -qF "<th data-sort-key=\"lens\">Lens</th>" "$1" &&
  grep -qF "<th data-sort-key=\"updated\">Updated</th>" "$1"
' _ "$html_groups"
check "output HTML has no external <script src=...> (self-contained-HTML constraint)" bash -c '! grep -q "<script src=" "$1"' _ "$html_groups"
check "output HTML has no external <link href=...> (self-contained-HTML constraint)" bash -c '! grep -q "<link href=" "$1"' _ "$html_groups"

echo ""
if [ "$fail" -eq 0 ]; then
  echo "cockpit.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "cockpit.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
