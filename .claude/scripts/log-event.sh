#!/usr/bin/env bash
# log-event.sh — append one progress event to the local, unattended-run event
# log (issue #52). Called by the orchestrator/implementer/reviewer agents at
# each phase transition (e.g. "implementing", "gate-running", "reviewing",
# "done") so cockpit.sh can render live per-worker state. This is
# OBSERVABILITY ONLY: it never gates anything, never affects control flow, and
# must never break the caller — always exits 0, even on odd/missing input.
#
# Usage:
#   log-event.sh --role R --task T --phase P [--model M] [--lens L] [--detail D]
#
# Appends exactly ONE JSON object per line (JSONL) to the log, schema:
#   {"ts":"<ISO-8601 UTC>","role":"...","model":"...","task":"...",
#    "phase":"...","lens":"...","detail":"..."}
# Missing optional args (model/lens/detail) serialize as empty strings. The
# JSON line is built with `node` (never hand-rolled string interpolation) so
# values are always safely escaped, including quotes/backslashes/HTML.
#
# Log file: defaults to <repo-root>/.claude/state/events.jsonl. Override with
# CLAUDE_EVENTS_FILE=<absolute path> (used by tests to point at a temp file
# instead of the real, gitignored state dir). The parent directory is created
# if missing.
#
# Rotation/retention: after appending, the file is capped to the last
# ${EVENTS_MAX_LINES:-2000} lines (oldest dropped first), via a temp file +
# atomic `mv`, so unattended multi-day runs never grow the log unbounded and a
# crash mid-rotation never leaves a truncated/corrupt log in place.
set -u

role=""
model=""
task=""
phase=""
lens=""
detail=""

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --role) role="${2:-}" ;;
    --model) model="${2:-}" ;;
    --task) task="${2:-}" ;;
    --phase) phase="${2:-}" ;;
    --lens) lens="${2:-}" ;;
    --detail) detail="${2:-}" ;;
    *) ;;
  esac
  # Always shift exactly one — a dangling flag with no value (e.g. trailing
  # `--role`) must never stall the loop; best-effort parsing, never hang.
  shift || break
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || exit 0
root="$(cd "$script_dir/../.." 2>/dev/null && pwd)" || exit 0

events_file="${CLAUDE_EVENTS_FILE:-$root/.claude/state/events.jsonl}"
max_lines="${EVENTS_MAX_LINES:-2000}"

mkdir -p "$(dirname "$events_file")" 2>/dev/null || exit 0

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || ts=""

CLAUDE_EVENT_TS="$ts" \
CLAUDE_EVENT_ROLE="$role" \
CLAUDE_EVENT_MODEL="$model" \
CLAUDE_EVENT_TASK="$task" \
CLAUDE_EVENT_PHASE="$phase" \
CLAUDE_EVENT_LENS="$lens" \
CLAUDE_EVENT_DETAIL="$detail" \
node -e '
  const line = JSON.stringify({
    ts: process.env.CLAUDE_EVENT_TS || "",
    role: process.env.CLAUDE_EVENT_ROLE || "",
    model: process.env.CLAUDE_EVENT_MODEL || "",
    task: process.env.CLAUDE_EVENT_TASK || "",
    phase: process.env.CLAUDE_EVENT_PHASE || "",
    lens: process.env.CLAUDE_EVENT_LENS || "",
    detail: process.env.CLAUDE_EVENT_DETAIL || "",
  });
  process.stdout.write(line + "\n");
' >>"$events_file" 2>/dev/null || exit 0

# ---- rotation: cap to the last $max_lines lines, atomically -----------------
node -e '
  const fs = require("fs");
  const file = process.argv[1];
  const max = parseInt(process.argv[2], 10);
  const tmp = process.argv[3];
  try {
    if (!Number.isFinite(max) || max <= 0) process.exit(0);
    const text = fs.readFileSync(file, "utf8");
    const lines = text.split("\n");
    // drop a single trailing empty string from the final newline, if present
    if (lines.length && lines[lines.length - 1] === "") lines.pop();
    if (lines.length <= max) process.exit(0);
    const kept = lines.slice(lines.length - max);
    fs.writeFileSync(tmp, kept.join("\n") + "\n");
    fs.renameSync(tmp, file);
  } catch (e) {
    process.exit(0);
  }
' "$events_file" "$max_lines" "$events_file.tmp.$$" 2>/dev/null

exit 0
