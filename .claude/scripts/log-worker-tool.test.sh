#!/usr/bin/env bash
# log-worker-tool.test.sh — offline smoke test for log-worker-tool.sh
# (issue #71, Cockpit 3c SPIKE; enabled by default as of issue #84).
#
# Asserts: Bash/Edit/Write tool calls yield exactly one valid-JSON record
# each with the expected tool/summary/path fields; non-mirrored tools (Read,
# Grep) and malformed/empty stdin produce NO record and still exit 0;
# multi-line Bash commands collapse to a single-line summary; quotes/
# backslashes in a command still round-trip as valid JSON; and rotation caps
# the log to the last WORKER_TOOLS_MAX_LINES lines.
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/log-worker-tool.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_worker_tool="$script_dir/log-worker-tool.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/log-worker-tool-test.XXXXXX")"
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

emit() {
  # emit <log_file> <event_json>
  printf '%s' "$2" | CLAUDE_WORKER_TOOLS_FILE="$1" bash "$log_worker_tool" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# 1. Bash tool call -> one record, tool=Bash, summary=command, path=cwd.
# ---------------------------------------------------------------------------
bash_file="$work/bash.jsonl"
emit "$bash_file" '{"tool_name":"Bash","tool_input":{"command":"echo hello world"},"cwd":"/wt/task-1"}'

check "bash call yields exactly 1 line" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 1 ]' _ "$bash_file"
check "bash record has expected fields" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.tool !== "Bash") throw new Error("tool mismatch: " + obj.tool);
  if (obj.summary !== "echo hello world") throw new Error("summary mismatch: " + obj.summary);
  if (obj.path !== "/wt/task-1") throw new Error("path mismatch: " + obj.path);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(obj.ts)) throw new Error("ts not ISO-8601 UTC: " + obj.ts);
' "$bash_file"

# ---------------------------------------------------------------------------
# 2. Edit and Write -> record with correct tool + path=file_path.
# ---------------------------------------------------------------------------
edit_file="$work/edit.jsonl"
emit "$edit_file" '{"tool_name":"Edit","tool_input":{"file_path":"/wt/task-1/src/foo.js","old_string":"a","new_string":"b"},"cwd":"/wt/task-1"}'
check "edit record has correct tool + path" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.tool !== "Edit") throw new Error("tool mismatch: " + obj.tool);
  if (obj.path !== "/wt/task-1/src/foo.js") throw new Error("path mismatch: " + obj.path);
' "$edit_file"

write_file="$work/write.jsonl"
emit "$write_file" '{"tool_name":"Write","tool_input":{"file_path":"/wt/task-1/src/bar.js","content":"..."},"cwd":"/wt/task-1"}'
check "write record has correct tool + path" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.tool !== "Write") throw new Error("tool mismatch: " + obj.tool);
  if (obj.path !== "/wt/task-1/src/bar.js") throw new Error("path mismatch: " + obj.path);
' "$write_file"

# ---------------------------------------------------------------------------
# 3. A non-target tool (Read, Grep) -> NO record appended, exit 0.
# ---------------------------------------------------------------------------
nontarget_file="$work/nontarget.jsonl"
printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/wt/task-1/src/foo.js"},"cwd":"/wt/task-1"}' | \
  CLAUDE_WORKER_TOOLS_FILE="$nontarget_file" bash "$log_worker_tool" >/dev/null 2>&1
check "Read call exits 0" [ "$?" -eq 0 ]
printf '%s' '{"tool_name":"Grep","tool_input":{"pattern":"foo"},"cwd":"/wt/task-1"}' | \
  CLAUDE_WORKER_TOOLS_FILE="$nontarget_file" bash "$log_worker_tool" >/dev/null 2>&1
check "Grep call exits 0" [ "$?" -eq 0 ]
check "no record written for non-target tools" bash -c '[ ! -s "$1" ]' _ "$nontarget_file"

# ---------------------------------------------------------------------------
# 4. Empty stdin / malformed JSON -> exit 0 AND no spurious line written.
# ---------------------------------------------------------------------------
malformed_file="$work/malformed.jsonl"
printf '' | CLAUDE_WORKER_TOOLS_FILE="$malformed_file" bash "$log_worker_tool" >/dev/null 2>&1
check "empty stdin exits 0" [ "$?" -eq 0 ]
printf 'not json at all {{{' | CLAUDE_WORKER_TOOLS_FILE="$malformed_file" bash "$log_worker_tool" >/dev/null 2>&1
check "malformed JSON exits 0" [ "$?" -eq 0 ]
check "no spurious line written for empty/malformed stdin" bash -c '[ ! -s "$1" ]' _ "$malformed_file"

# ---------------------------------------------------------------------------
# 5. Multi-line Bash command -> summary collapsed to a single line.
# ---------------------------------------------------------------------------
multiline_file="$work/multiline.jsonl"
multiline_event="$(node -e '
  process.stdout.write(JSON.stringify({
    tool_name: "Bash",
    tool_input: { command: "echo one\necho two\necho three" },
    cwd: "/wt/task-1",
  }));
')"
printf '%s' "$multiline_event" | CLAUDE_WORKER_TOOLS_FILE="$multiline_file" bash "$log_worker_tool" >/dev/null 2>&1
check "multi-line command yields exactly 1 line in the log" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 1 ]' _ "$multiline_file"
check "multi-line command collapsed to single-line summary (no raw newline)" node -e '
  const fs = require("fs");
  const raw = fs.readFileSync(process.argv[1], "utf8");
  if (raw.split("\n").filter(Boolean).length !== 1) throw new Error("expected exactly 1 non-empty line, got: " + JSON.stringify(raw));
  const obj = JSON.parse(raw.trim());
  if (obj.summary.includes("\n")) throw new Error("summary contains raw newline: " + JSON.stringify(obj.summary));
  if (obj.summary !== "echo one echo two echo three") throw new Error("summary mismatch: " + obj.summary);
' "$multiline_file"

# ---------------------------------------------------------------------------
# 6. JSON escaping: quotes/backslashes in a command still produce valid JSON.
# ---------------------------------------------------------------------------
escapes_file="$work/escapes.jsonl"
escapes_event="$(node -e '
  process.stdout.write(JSON.stringify({
    tool_name: "Bash",
    tool_input: { command: String.raw`echo "hi" \ then </script> tags` },
    cwd: "/wt/task-1",
  }));
')"
printf '%s' "$escapes_event" | CLAUDE_WORKER_TOOLS_FILE="$escapes_file" bash "$log_worker_tool" >/dev/null 2>&1
check "command with quotes/backslashes yields valid parseable JSON" node -e '
  const fs = require("fs");
  const line = fs.readFileSync(process.argv[1], "utf8").trim();
  const obj = JSON.parse(line); // throws (fails the check) if not valid JSON
  if (!obj.summary.includes(String.raw`"hi"`)) throw new Error("summary missing expected content: " + obj.summary);
' "$escapes_file"

# ---------------------------------------------------------------------------
# 7. Rotation: WORKER_TOOLS_MAX_LINES small caps the file to the last N lines.
# ---------------------------------------------------------------------------
rotate_file="$work/rotate.jsonl"
for i in $(seq 1 12); do
  event="$(node -e "process.stdout.write(JSON.stringify({tool_name:'Bash',tool_input:{command:'echo t-$i'},cwd:'/wt/task-1'}))")"
  WORKER_TOOLS_MAX_LINES=5 CLAUDE_WORKER_TOOLS_FILE="$rotate_file" bash "$log_worker_tool" <<<"$event" >/dev/null 2>&1
done

check "rotation caps the file to exactly 5 lines" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 5 ]' _ "$rotate_file"
check "rotation keeps the LAST 5 records (most recent), in order" node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
  const summaries = lines.map((l) => JSON.parse(l).summary);
  const want = ["echo t-8", "echo t-9", "echo t-10", "echo t-11", "echo t-12"];
  if (JSON.stringify(summaries) !== JSON.stringify(want)) {
    throw new Error("got " + JSON.stringify(summaries) + " want " + JSON.stringify(want));
  }
' "$rotate_file"

# ---------------------------------------------------------------------------
# 8. Best-effort: never blocks the caller (always exits 0).
# ---------------------------------------------------------------------------
best_effort_file="$work/best-effort.jsonl"
printf '{"tool_name":"Bash"' | CLAUDE_WORKER_TOOLS_FILE="$best_effort_file" bash "$log_worker_tool" >/dev/null 2>&1
check "truncated JSON still exits 0" [ "$?" -eq 0 ]

CLAUDE_WORKER_TOOLS_FILE="/nonexistent/unwritable/dir/log.jsonl" bash "$log_worker_tool" <<<'{"tool_name":"Bash","tool_input":{"command":"x"},"cwd":"/"}' >/dev/null 2>&1
check "unwritable log directory still exits 0" [ "$?" -eq 0 ]

echo ""
if [ "$fail" -eq 0 ]; then
  echo "log-worker-tool.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "log-worker-tool.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
