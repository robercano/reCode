#!/usr/bin/env bash
# log-worker-tool.sh — PostToolUse mirror hook (issue #71, Cockpit 3c SPIKE).
#
# NOT ENABLED BY DEFAULT — see the "Wiring (disabled by default)" section
# below for the copy-paste snippet that turns it on. This is a spike to
# gather evidence on signal/noise and log growth before committing to always-
# on tool mirroring.
#
# Reads the PostToolUse hook event JSON on STDIN and mirrors ONLY the tools
# Bash, Edit, Write (every other tool — Read, Grep, Glob, ... — is silently
# ignored, no record written). This is OBSERVABILITY ONLY: it never gates
# anything, never affects control flow, and must never break the caller —
# always exits 0, even on malformed/empty stdin, missing node, missing
# fields, or an unwritable log directory.
#
# Appends exactly ONE JSON object per line (JSONL) to the log, schema:
#   {"ts":"<ISO-8601 UTC>","tool":"Bash|Edit|Write","summary":"<one-line>",
#    "path":"<file path for Edit/Write, or cwd for Bash>"}
# - summary: for Bash, the command (collapsed to one line, truncated to a
#   sane cap); for Edit/Write, the target file path.
# - path: for Bash, the hook event's `cwd` (the worktree-path attribution
#   key — workers are worktree-isolated); for Edit/Write, `tool_input.file_path`.
# The JSON line is built with `node` (never hand-rolled string
# interpolation), mirroring log-event.sh EXACTLY, so quotes/backslashes/
# newlines/HTML are always safely escaped and the summary is collapsed to a
# single line.
#
# Log file: defaults to <repo-root>/.claude/state/worker-tools.jsonl.
# Override with CLAUDE_WORKER_TOOLS_FILE=<absolute path> (used by tests to
# point at a temp file instead of the real, gitignored state dir). The parent
# directory is created if missing.
#
# Rotation/retention: after appending, the file is capped to the last
# ${WORKER_TOOLS_MAX_LINES:-2000} lines (oldest dropped first), via a temp
# file + atomic `mv`, mirroring log-event.sh's rotation node block exactly —
# so unattended multi-day runs never grow the log unbounded and a crash
# mid-rotation never leaves a truncated/corrupt log in place.
#
# Zero-token / harness-side rationale: this hook is invoked by the Claude
# Code harness itself (PostToolUse), OUTSIDE the agent's sandbox and context
# window — it reads the tool-call event off stdin and writes a log line; the
# agent never sees this happen and it costs zero agent tokens.
#
# ---------------------------------------------------------------------------
# Wiring (DISABLED by default — copy into .claude/settings.json to enable):
#
#   "PostToolUse": [
#     {
#       "matcher": "Bash|Edit|Write",
#       "hooks": [
#         {
#           "type": "command",
#           "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/log-worker-tool.sh\""
#         }
#       ]
#     }
#   ]
#
# A "go" decision is this one array entry — nothing else to wire up.
# ---------------------------------------------------------------------------
set -u

# Two-root derivation (issue #63) — resolve-roots.sh never fails, matching
# this script's never-block contract.
# shellcheck source=resolve-roots.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/resolve-roots.sh" 2>/dev/null || exit 0

worker_tools_file="${CLAUDE_WORKER_TOOLS_FILE:-$root/.claude/state/worker-tools.jsonl}"
max_lines="${WORKER_TOOLS_MAX_LINES:-2000}"

# Read the hook event JSON off stdin once; never let a hang or huge payload
# block the caller.
event_json="$(cat 2>/dev/null)" || exit 0

mkdir -p "$(dirname "$worker_tools_file")" 2>/dev/null || exit 0

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" || ts=""

CLAUDE_WT_TS="$ts" \
CLAUDE_WT_EVENT="$event_json" \
node -e '
  let event;
  try {
    event = JSON.parse(process.env.CLAUDE_WT_EVENT || "");
  } catch (e) {
    process.exit(0); // malformed/empty stdin — silent no-op
  }
  if (!event || typeof event !== "object") process.exit(0);

  const toolName = event.tool_name;
  if (toolName !== "Bash" && toolName !== "Edit" && toolName !== "Write") {
    process.exit(0); // not a mirrored tool — silent no-op
  }

  const input = event.tool_input || {};
  const collapse = (s) =>
    String(s == null ? "" : s)
      .replace(/\r?\n/g, " ")
      .replace(/\s+/g, " ")
      .trim();
  const truncate = (s, cap) => (s.length > cap ? s.slice(0, cap) : s);

  let summary = "";
  let path = "";
  if (toolName === "Bash") {
    summary = truncate(collapse(input.command), 200);
    path = event.cwd || "";
  } else {
    // Edit or Write
    path = input.file_path || "";
    summary = collapse(path);
  }

  const line = JSON.stringify({
    ts: process.env.CLAUDE_WT_TS || "",
    tool: toolName,
    summary,
    path,
  });
  process.stdout.write(line + "\n");
' >>"$worker_tools_file" 2>/dev/null || exit 0

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
' "$worker_tools_file" "$max_lines" "$worker_tools_file.tmp.$$" 2>/dev/null

exit 0
