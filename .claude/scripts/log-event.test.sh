#!/usr/bin/env bash
# log-event.test.sh — offline smoke test for log-event.sh (issue #52).
#
# Asserts: N appended events yield N valid-JSON lines with the expected
# fields (round-tripped, including safe escaping of quotes/backslashes/HTML),
# that rotation caps the log to the last EVENTS_MAX_LINES lines (most recent
# kept, oldest dropped), and that a weird/missing-arg call is still best
# effort — it never breaks the caller (always exits 0).
#
# Exit 0 on success, non-zero if any assertion fails. Runnable bare:
#   bash .claude/scripts/log-event.test.sh
set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log_event="$script_dir/log-event.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/log-event-test.XXXXXX")"
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

# ---------------------------------------------------------------------------
# 1. Appending N events yields N lines, each a valid JSON object.
# ---------------------------------------------------------------------------
events_file="$work/events.jsonl"
for i in 1 2 3; do
  CLAUDE_EVENTS_FILE="$events_file" bash "$log_event" \
    --role implementer --task "task-$i" --phase implementing --model sonnet >/dev/null 2>&1
done

check "log file has exactly 3 lines" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 3 ]' _ "$events_file"

check "every line is valid JSON" node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
  for (const l of lines) JSON.parse(l);
' "$events_file"

# ---------------------------------------------------------------------------
# 2. Required fields present with expected values (round-trip role/task/phase),
#    and unsafe characters are safely escaped (proves node-built JSON, not
#    hand-rolled interpolation).
# ---------------------------------------------------------------------------
escapes_file="$work/escapes.jsonl"
weird_detail='He said "hi" \ then </script> tags'
CLAUDE_EVENTS_FILE="$escapes_file" bash "$log_event" \
  --role reviewer --task "issue-52" --phase reviewing --model opus --lens correctness \
  --detail "$weird_detail" >/dev/null 2>&1

check "required fields round-trip and unsafe chars are safely escaped" node -e '
  const fs = require("fs");
  const line = fs.readFileSync(process.argv[1], "utf8").trim();
  const obj = JSON.parse(line); // throws (fails the check) if not valid JSON
  if (obj.role !== "reviewer") throw new Error("role mismatch: " + obj.role);
  if (obj.task !== "issue-52") throw new Error("task mismatch: " + obj.task);
  if (obj.phase !== "reviewing") throw new Error("phase mismatch: " + obj.phase);
  if (obj.model !== "opus") throw new Error("model mismatch: " + obj.model);
  if (obj.lens !== "correctness") throw new Error("lens mismatch: " + obj.lens);
  if (obj.detail !== process.argv[2]) throw new Error("detail mismatch: " + obj.detail);
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/.test(obj.ts)) throw new Error("ts not ISO-8601 UTC: " + obj.ts);
' "$escapes_file" "$weird_detail"

# Missing optional args (model/lens/detail) serialize as empty strings.
optional_file="$work/optional.jsonl"
CLAUDE_EVENTS_FILE="$optional_file" bash "$log_event" \
  --role orchestrator --task "issue-52" --phase scoped >/dev/null 2>&1
check "missing optional args serialize as empty strings" node -e '
  const fs = require("fs");
  const obj = JSON.parse(fs.readFileSync(process.argv[1], "utf8").trim());
  if (obj.model !== "" || obj.lens !== "" || obj.detail !== "") {
    throw new Error("expected empty optional fields, got " + JSON.stringify(obj));
  }
' "$optional_file"

# ---------------------------------------------------------------------------
# 3. Rotation: EVENTS_MAX_LINES=5, writing 12 events leaves exactly the LAST 5.
# ---------------------------------------------------------------------------
rotate_file="$work/rotate.jsonl"
for i in $(seq 1 12); do
  EVENTS_MAX_LINES=5 CLAUDE_EVENTS_FILE="$rotate_file" bash "$log_event" \
    --role implementer --task "t-$i" --phase implementing >/dev/null 2>&1
done

check "rotation caps the file to exactly 5 lines" bash -c '[ "$(wc -l < "$1" | tr -d " ")" -eq 5 ]' _ "$rotate_file"

check "rotation keeps the LAST 5 events (most recent), in order" node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean);
  const tasks = lines.map((l) => JSON.parse(l).task);
  const want = ["t-8", "t-9", "t-10", "t-11", "t-12"];
  if (JSON.stringify(tasks) !== JSON.stringify(want)) {
    throw new Error("got " + JSON.stringify(tasks) + " want " + JSON.stringify(want));
  }
' "$rotate_file"

# ---------------------------------------------------------------------------
# 4. Best-effort: a call with a weird/missing arg still exits 0.
# ---------------------------------------------------------------------------
best_effort_file="$work/best-effort.jsonl"
CLAUDE_EVENTS_FILE="$best_effort_file" bash "$log_event" --this-flag-does-not-exist >/dev/null 2>&1
check "unknown/weird flag still exits 0" [ "$?" -eq 0 ]

CLAUDE_EVENTS_FILE="$best_effort_file" bash "$log_event" >/dev/null 2>&1
check "no args at all still exits 0" [ "$?" -eq 0 ]

CLAUDE_EVENTS_FILE="$best_effort_file" bash "$log_event" --role >/dev/null 2>&1
check "dangling flag with no value still exits 0" [ "$?" -eq 0 ]

echo ""
if [ "$fail" -eq 0 ]; then
  echo "log-event.test.sh: PASS ($ok checks)"
  exit 0
else
  echo "log-event.test.sh: FAIL (see FAIL lines above)"
  exit 1
fi
