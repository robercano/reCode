#!/usr/bin/env bash
# cockpit.test.sh — offline smoke test for cockpit.sh (issue #51, extended for
# Phase 2 live progress in issue #52, and Phase 3a serve/theme/filter in
# issue #69).
#
# Runs the generator against controlled FIXTURE issue/PR/events JSON (never
# live gh/network, and never the real event log — see cockpit.sh's
# --fixtures mode), then asserts the produced HTML contains every required
# section (issues-by-module with blocking relationships, PRs with review/CI
# badges, a routing table with a real `model:` value, a worktrees section,
# a live-progress panel deduped to each worker's latest phase, the default
# dark-theme marker) and that the blocking-relationship parser
# (`cockpit.sh --parse-blocking`) produces the expected edges for a known
# fixture body. Also exercises the "gh/network unavailable" degrade path via
# COCKPIT_GH_BIN, entirely offline (no real gh call, no .env), and a serve-mode
# smoke case (cockpit-serve.sh) against the SAME fixtures, over 127.0.0.1 only
# — no real network/gh either way.
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
cleanup() {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" 2>/dev/null || true
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

html="$work/cockpit.html"
bash "$cockpit" --fixtures "$work/fixtures" "$html" >"$work/stdout.log" 2>"$work/stderr.log"
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
# CLAUDE_EVENTS_FILE points at a guaranteed-missing path so this run is fully
# offline/deterministic (never touches the real, gitignored event log) and
# doubles as the "no events file at all" -> "no active workers" assertion.
COCKPIT_GH_BIN="$fake_gh" CLAUDE_EVENTS_FILE="$work/no-such-events.jsonl" bash "$cockpit" "$html_unavail" >/dev/null 2>"$work/stderr-unavail.log"
rc_unavail=$?
check "generator still exits 0 when gh is unavailable" [ "$rc_unavail" -eq 0 ]
check "issues section shows unavailable placeholder" grep -q '<section id="issues"><h2>Open issues</h2><p class="unavailable">unavailable (gh/network)</p>' "$html_unavail"
check "PRs section shows unavailable placeholder" grep -q '<section id="prs"><h2>Open PRs</h2><p class="unavailable">unavailable (gh/network)</p>' "$html_unavail"
check "routing/worktrees sections still render (no crash) despite gh failure" bash -c 'grep -q "routing" "$1" && grep -q "worktrees" "$1"' _ "$html_unavail"
check "missing events file renders 'no active workers' placeholder" grep -q '<section id="live"><h2>Live worker progress</h2><p class="muted">no active workers</p>' "$html_unavail"

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

kill "$server_pid" >/dev/null 2>&1 || true
wait "$server_pid" 2>/dev/null || true
server_pid=""

echo ""
if [ "$fail" -eq 0 ]; then
  echo "cockpit.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "cockpit.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
