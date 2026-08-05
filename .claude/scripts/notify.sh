#!/usr/bin/env bash
# notify.sh — generic push-notification seam for the loop (issue #99).
#
# Reads an adapter-configured shell command from gates.json's `notify` key
# (same GATES_FILE override + empty-means-skip convention as every other
# gate/budget knob — see gate.sh and loop-tick.sh's STEP 0). When that
# command is empty (the default in BOTH shipped adapters — the owner picks
# their own notifier), this is a SILENT no-op that exits 0: offline/CI-safe
# by construction, and the hard acceptance criterion for this issue.
#
# Usage:
#   notify.sh <severity> <title> <body-line> [--kind <kind>] [--target <target>] [--window <seconds>]
#   notify.sh --clear --kind <kind> --target <target>
#
# Contract with the configured command: severity/title/body reach it BOTH
# ways, so a one-liner (`notify-send "$1" "$2"`) and an env-reading script
# (`curl ... -d "$NOTIFY_BODY"`) are equally easy to wire up:
#   - positional args $1/$2/$3 = severity/title/body-line
#   - env vars NOTIFY_SEVERITY / NOTIFY_TITLE / NOTIFY_BODY = the same three
# Example commands (all empty by default; pick ONE in your adapter):
#   ntfy:          "curl -s -d \"$NOTIFY_BODY\" -H \"Title: $NOTIFY_TITLE\" -H \"Priority: $NOTIFY_SEVERITY\" https://ntfy.sh/<your-topic>"
#   notify-send:   "notify-send \"$NOTIFY_TITLE\" \"$NOTIFY_BODY\""
#   webhook curl:  "curl -s -X POST -H 'Content-Type: application/json' -d \"{\\\"severity\\\":\\\"$NOTIFY_SEVERITY\\\",\\\"title\\\":\\\"$NOTIFY_TITLE\\\",\\\"body\\\":\\\"$NOTIFY_BODY\\\"}\" https://example.invalid/hook"
#
# Throttling: at most one notification per (kind, target) per cadence window
# (default ${NOTIFY_THROTTLE_SECONDS:-1800}s = 30 minutes; override per-call
# with --window, or globally with $NOTIFY_THROTTLE_SECONDS), so a WATCH-cadence
# loop re-checking a still-blocked condition every few minutes doesn't nag.
# State: <root>/.claude/state/notify-throttle.json (gitignored, mirrors every
# other loop state file), keyed by "<kind>:<target>" -> last-fired timestamp.
# Override the state file with CLAUDE_NOTIFY_THROTTLE_FILE (tests). kind/target
# default to "general"/the title when the caller doesn't pass them, so
# throttling always has SOME key rather than silently never throttling.
#
# --clear --kind K --target T: removes the (kind,target) throttle entry with
# NO notification sent — used by needs-human.sh's needs_human_clear so a
# FUTURE re-flag of the same (kind,target) notifies immediately instead of
# staying throttled from the episode that just cleared.
#
# Guards state read/write failures (missing/read-only .claude/state/) so a
# broken state dir degrades to "always notify" rather than crashing — this
# must never break the calling script, matching log-event.sh's contract.
# Every side effect below is best-effort; the configured command's own exit
# status is never propagated (a flaky notifier must never fail the loop).
set -uo pipefail

# Two-root derivation (issue #63): script_dir = sibling scripts, root =
# consumer project. Never fails (log-event.sh-style — this script must not
# block the caller even if resolve-roots.sh is somehow missing).
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -f "$script_dir/resolve-roots.sh" ]; then
  # shellcheck source=resolve-roots.sh
  . "$script_dir/resolve-roots.sh" 2>/dev/null || true
fi
root="${root:-$(pwd)}"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
clear_mode=0
severity="" title="" body=""
kind="" target="" window=""

if [ "${1:-}" = "--clear" ]; then
  clear_mode=1
  shift
else
  severity="${1:-}"; title="${2:-}"; body="${3:-}"
  # Consume up to 3 positional args (whichever actually exist) before parsing
  # flags — avoids `shift 3` erroring out when fewer than 3 were passed.
  for _ in 1 2 3; do
    [ $# -gt 0 ] && shift
  done
fi

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --kind) kind="${2:-}"; shift 2 ;;
    --target) target="${2:-}"; shift 2 ;;
    --window) window="${2:-}"; shift 2 ;;
    *) shift ;;
  esac
done

case "$window" in ''|*[!0-9]*) window="${NOTIFY_THROTTLE_SECONDS:-1800}" ;; esac
case "$window" in ''|*[!0-9]*) window=1800 ;; esac

throttle_key="${kind:-general}:${target:-${title:-untitled}}"

state_dir="$root/.claude/state"
throttle_file="${CLAUDE_NOTIFY_THROTTLE_FILE:-$state_dir/notify-throttle.json}"

now_iso="${NOTIFY_NOW:-$(date -u +%FT%TZ 2>/dev/null)}"

# ---------------------------------------------------------------------------
# --clear: drop the throttle entry, no notification, always exit 0.
# ---------------------------------------------------------------------------
if [ "$clear_mode" -eq 1 ]; then
  if [ -f "$throttle_file" ]; then
    tmp="$(mktemp "$state_dir/.notify-throttle.json.XXXXXX" 2>/dev/null || true)"
    if [ -n "$tmp" ] && CLAUDE_NH_KEY="$throttle_key" node -e '
      const fs = require("fs");
      const file = process.argv[1], tmp = process.argv[2];
      const key = process.env.CLAUDE_NH_KEY;
      let j = {};
      try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {}
      delete j[key];
      fs.writeFileSync(tmp, JSON.stringify(j, null, 2) + "\n");
    ' "$throttle_file" "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$throttle_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
      [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null
    fi
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# Read the adapter-configured command. Empty (both shipped adapters ship it
# empty by default) -> silent no-op, exit 0. This is the hard offline/CI-safe
# acceptance criterion for issue #99.
# ---------------------------------------------------------------------------
gates_rel="${GATES_FILE:-.claude/gates.json}"
case "$gates_rel" in /*) gates_path="$gates_rel" ;; *) gates_path="$root/$gates_rel" ;; esac

cmd="$(node -e '
  const fs = require("fs");
  try {
    const g = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    process.stdout.write((g && typeof g.notify === "string") ? g.notify : "");
  } catch (e) { process.stdout.write(""); }
' "$gates_path" 2>/dev/null)"

[ -n "$cmd" ] || exit 0

# ---------------------------------------------------------------------------
# Throttle check: skip (silently, exit 0) when this (kind,target) fired within
# the window. A missing/unreadable/unwritable state dir degrades to "always
# notify" (never throttled) rather than blocking the notification.
# ---------------------------------------------------------------------------
if [ -f "$throttle_file" ]; then
  should_skip="$(CLAUDE_NH_KEY="$throttle_key" CLAUDE_NH_NOW="$now_iso" CLAUDE_NH_WINDOW="$window" node -e '
    const fs = require("fs");
    const key = process.env.CLAUDE_NH_KEY;
    // NOTE: `|| 1800` would treat a legitimate --window 0 as falsy and
    // silently override it back to 1800 -- use Number.isFinite instead so
    // 0 (never throttle) is respected.
    const windowParsed = parseInt(process.env.CLAUDE_NH_WINDOW, 10);
    const window = Number.isFinite(windowParsed) && windowParsed >= 0 ? windowParsed : 1800;
    let j = {};
    try { j = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch (e) { j = {}; }
    const last = j[key];
    if (!last) { console.log("0"); process.exit(0); }
    const lastMs = Date.parse(last);
    const nowMs = Date.parse(process.env.CLAUDE_NH_NOW);
    if (!Number.isFinite(lastMs) || !Number.isFinite(nowMs)) { console.log("0"); process.exit(0); }
    console.log((nowMs - lastMs) < window * 1000 ? "1" : "0");
  ' "$throttle_file" 2>/dev/null || echo "0")"
  if [ "$should_skip" = "1" ]; then
    exit 0
  fi
fi

# ---------------------------------------------------------------------------
# Fire: run the configured command with severity/title/body available both as
# positional args ($1/$2/$3) and as NOTIFY_SEVERITY/NOTIFY_TITLE/NOTIFY_BODY
# env vars. Never propagate its exit status — a flaky/misconfigured notifier
# must never fail the caller.
# ---------------------------------------------------------------------------
NOTIFY_SEVERITY="$severity" NOTIFY_TITLE="$title" NOTIFY_BODY="$body" \
  bash -c "$cmd" -- "$severity" "$title" "$body" >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
# Record the fire so the throttle window applies to the NEXT call. Best
# effort: a failure here (read-only/missing state dir) never affects the exit
# status — the notification already fired above.
# ---------------------------------------------------------------------------
mkdir -p "$state_dir" 2>/dev/null || exit 0
tmp="$(mktemp "$state_dir/.notify-throttle.json.XXXXXX" 2>/dev/null || true)"
if [ -n "$tmp" ] && CLAUDE_NH_KEY="$throttle_key" CLAUDE_NH_NOW="$now_iso" node -e '
  const fs = require("fs");
  const file = process.argv[1], tmp = process.argv[2];
  const key = process.env.CLAUDE_NH_KEY;
  let j = {};
  try { j = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) {}
  j[key] = process.env.CLAUDE_NH_NOW;
  fs.writeFileSync(tmp, JSON.stringify(j, null, 2) + "\n");
' "$throttle_file" "$tmp" 2>/dev/null; then
  mv -f "$tmp" "$throttle_file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
else
  [ -n "$tmp" ] && rm -f "$tmp" 2>/dev/null
fi

exit 0
